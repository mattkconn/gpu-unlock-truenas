#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# gpu-unlock for TrueNAS SCALE 25.10 (and later, untested).
#
# Builds the upstream gpu_unlock kernel module in a throwaway Debian 12
# container against the TrueNAS kernel headers, installs it with its firmware
# under /root/gpu-unlock, and adds a modprobe hook so it runs right before the
# NVIDIA driver loads at boot. Nothing under /usr is changed and Developer
# Mode is not needed.
#
# Run as root:
#   bash gpu-unlock.sh install     build and install (again after every TrueNAS update)
#   bash gpu-unlock.sh status      show whether the unlock ran on this boot
#   bash gpu-unlock.sh disable     skip the unlock from the next boot on
#   bash gpu-unlock.sh enable      undo disable
#   bash gpu-unlock.sh uninstall   remove everything this script installed
#   bash gpu-unlock.sh bench MODEL measure Ollama prompt speed (MODEL as listed by bench with no name)

set -euo pipefail

REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
STATE=/root/gpu-unlock
HOOK=/etc/modprobe.d/gpu-unlock.conf
KVER="$(uname -r)"
NV=610.43.03
IMAGE=debian:bookworm
FIRMWARE_FILES="booter_load_ga102.bin gsp_ga10x.bin gsp_boot_ga102.bin gsp_boot_desc_ga102.bin v67-ga102-$NV.bin"
OLLAMA_URL="${OLLAMA_URL:-http://127.0.0.1:30068}"

say() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

need_root() {
	[ "$(id -u)" -eq 0 ] || die "Run this as root. Type: sudo -i   and then run the command again."
}

preflight() {
	say "Checking this system"
	[ -r /etc/version ] || die "This does not look like TrueNAS (no /etc/version)."
	echo "TrueNAS $(cat /etc/version), kernel $KVER"
	HDR="$(readlink -f "/lib/modules/$KVER/build" || true)"
	[ -n "$HDR" ] && [ -f "$HDR/Makefile" ] || die "Kernel headers for $KVER not found at /lib/modules/$KVER/build."
	echo "Kernel headers: $HDR"
	[ -x /sbin/insmod ] && [ -x /sbin/modprobe ] || die "/sbin/insmod or /sbin/modprobe is missing."
	[ -w /sys/module/firmware_class/parameters/path ] || die "The firmware search path cannot be set on this kernel."
	command -v docker >/dev/null || die "docker was not found. Apps must be set up (a pool chosen for Apps)."
	docker info >/dev/null 2>&1 || die "Docker is not running. Check Apps in the TrueNAS web UI."
	echo "NVIDIA GPUs:"
	lspci -Dnn -d 10de::0300 || true
	[ -f "$REPO/kernel/gpu_unlock/main.c" ] || die "Upstream source not found in $REPO. Run this from inside the cloned repository."
}

build() {
	say "Building the module and firmware in a temporary $IMAGE container (downloads about 400 MB; takes a few minutes)"
	WORK="$(mktemp -d /tmp/gpu-unlock-build.XXXXXX)"
	docker run --rm -i \
		-v "$REPO":/src:ro \
		-v "$HDR":"$HDR":ro \
		-v "$WORK":/out \
		-e HDR="$HDR" \
		-e FIRMWARE_FILES="$FIRMWARE_FILES" \
		"$IMAGE" bash -s <<'EOS'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
echo "-- installing build tools"
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
	gcc make libc6-dev libelf1 libssl3 python3 ca-certificates xz-utils zstd >/dev/null
gcc --version | head -n 1
cp -a /src /work
cd /work
echo "-- downloading and checking the pinned NVIDIA files, generating firmware"
make assets CACHE=/cache
echo "-- building gpu_unlock.ko against $HDR"
make -C kernel/gpu_unlock KDIR="$HDR"
mkdir -p /out/firmware
cp kernel/gpu_unlock/gpu_unlock.ko /out/
for f in $FIRMWARE_FILES; do cp "/cache/assets/$f" /out/firmware/; done
cp /cache/assets/NVIDIA-LICENSE /out/ 2>/dev/null || true
EOS
	[ -f "$WORK/gpu_unlock.ko" ] || die "The build finished without producing gpu_unlock.ko."
	echo "Built: $WORK/gpu_unlock.ko"
}

check_module() {
	say "Checking the new module matches this kernel"
	local vm_new vm_nv
	vm_new="$(modinfo -F vermagic "$WORK/gpu_unlock.ko")"
	echo "gpu_unlock vermagic: $vm_new"
	[ "${vm_new%% *}" = "$KVER" ] || die "The module was built for '${vm_new%% *}', not '$KVER'. Nothing was installed."
	vm_nv="$(modinfo -F vermagic nvidia 2>/dev/null || true)"
	if [ -n "$vm_nv" ] && [ "$vm_nv" != "$vm_new" ]; then
		die "vermagic differs from the NVIDIA module ('$vm_nv'). Nothing was installed."
	fi

	if grep -q '^gpu_unlock ' /proc/modules; then
		echo "gpu_unlock is already loaded from an earlier boot; skipping the test load."
		return
	fi
	# Without targets= the module returns straight away and touches no card,
	# so this only proves it loads into this kernel.
	say "Test-loading the module (it does nothing to the GPU without targets=)"
	if ! /sbin/insmod "$WORK/gpu_unlock.ko"; then
		dmesg | tail -n 15
		die "The module would not load into this kernel. Nothing was installed."
	fi
	/sbin/rmmod gpu_unlock
	echo "Test load OK (a 'tainting kernel' line in the kernel log is expected: the module is not signed)."
}

install_files() {
	say "Installing to $STATE and $HOOK"
	install -d -m 700 "$STATE" "$STATE/modules/$KVER" "$STATE/firmware/gpu-unlock/$NV"
	install -m 644 "$WORK/gpu_unlock.ko" "$STATE/modules/$KVER/gpu_unlock.ko"
	for f in $FIRMWARE_FILES; do
		install -m 644 "$WORK/firmware/$f" "$STATE/firmware/gpu-unlock/$NV/$f"
	done
	[ -f "$WORK/NVIDIA-LICENSE" ] && install -m 644 "$WORK/NVIDIA-LICENSE" "$STATE/NVIDIA-LICENSE"
	install -m 755 "$REPO/truenas/load.sh" "$STATE/load.sh"
	[ -s "$STATE/targets" ] || echo all > "$STATE/targets"
	cat > "$HOOK" <<EOF
# Added by gpu-unlock-truenas (truenas/gpu-unlock.sh). Runs the BF16 unlock
# right before the NVIDIA driver loads. Remove this file to stop it.
install nvidia /bin/sh $STATE/load.sh; /sbin/modprobe --ignore-install nvidia \$CMDLINE_OPTS
EOF
	chmod 644 "$HOOK"
	rm -rf "$WORK"
	echo "Installed. Targets: $(cat "$STATE/targets")"
	echo
	echo "Reboot to apply. After the reboot, run:  bash $REPO/truenas/gpu-unlock.sh status"
}

cmd_install() {
	need_root
	preflight
	build
	check_module
	install_files
}

cmd_status() {
	need_root
	say "Install state"
	echo "Kernel: $KVER"
	if [ -f "$HOOK" ]; then echo "Boot hook $HOOK: present"; else echo "Boot hook $HOOK: MISSING"; fi
	if [ -f "$STATE/modules/$KVER/gpu_unlock.ko" ]; then
		echo "Module for this kernel: present"
	else
		echo "Module for this kernel: MISSING (run install; normal after a TrueNAS update)"
	fi
	if [ -e "$STATE/disabled" ]; then echo "Switch: DISABLED"; else echo "Switch: enabled"; fi
	echo "Targets: $(cat "$STATE/targets" 2>/dev/null || echo none)"
	if grep -q '^gpu_unlock ' /proc/modules; then echo "gpu_unlock loaded now: yes"; else echo "gpu_unlock loaded now: no"; fi

	say "Hook log for this boot (journalctl -b -t gpu-unlock)"
	journalctl -b -t gpu-unlock --no-pager 2>/dev/null || true

	local klog
	klog="$(journalctl -k -b --no-pager 2>/dev/null | grep -i 'gpu_unlock' || true)"
	say "Module log for this boot (lines with gpu_unlock)"
	if [ -n "$klog" ]; then echo "$klog"; else echo "(none)"; fi

	say "Result"
	if grep -q 'gpu_unlock: unlocked' <<<"$klog"; then
		echo "UNLOCKED on this boot."
	elif grep -q 'gpu_unlock: .*failed' <<<"$klog"; then
		echo "The unlock ran but FAILED (see above). The GPU still works at normal speed."
	else
		echo "The unlock did not run on this boot."
	fi

	say "GPU"
	lspci -Dnnk -d 10de::0300 || true
	nvidia-smi --query-gpu=name,driver_version,power.limit,clocks.max.sm --format=csv 2>/dev/null || true
}

cmd_disable() {
	need_root
	[ -d "$STATE" ] || die "Not installed."
	touch "$STATE/disabled"
	echo "Disabled. The unlock will be skipped from the next boot on. Do a full shutdown and power on to return the card to normal speed."
}

cmd_enable() {
	need_root
	rm -f "$STATE/disabled"
	echo "Enabled. The unlock will run on the next boot."
}

cmd_uninstall() {
	need_root
	rm -f "$HOOK"
	rm -rf "$STATE"
	echo "Removed $HOOK and $STATE."
	echo "Do a full shutdown and power on to return the card to normal speed."
}

cmd_bench() {
	command -v curl >/dev/null || die "curl not found."
	command -v jq >/dev/null || die "jq not found."
	local model="${1:-}"
	if [ -z "$model" ]; then
		echo "Models in Ollama at $OLLAMA_URL:"
		curl -fsS "$OLLAMA_URL/api/tags" | jq -r '.models[].name' || die "Could not reach Ollama at $OLLAMA_URL."
		echo
		echo "Run again with one of these names, for example:  bash $0 bench NAME"
		return
	fi
	# About 2,000 tokens of filler, so the prompt-processing (prefill) step dominates.
	local para="The quick brown fox jumps over the lazy dog near the river bank while the farmer counts sheep in the green valley and the sun sets behind the distant mountains. "
	local filler="" _
	for _ in $(seq 1 60); do filler+="$para"; done
	say "Benchmarking prompt processing for $model (1 warm-up + 3 runs)"
	local run body result count dur rate
	for run in 0 1 2 3; do
		# A random number at the start stops Ollama reusing a cached prompt.
		body="$(jq -n --arg m "$model" --arg p "Run $RANDOM$RANDOM. $filler Summarize." \
			'{model:$m, prompt:$p, stream:false, options:{num_predict:1}}')"
		result="$(curl -fsS "$OLLAMA_URL/api/generate" -d "$body")" || die "The request to Ollama failed."
		count="$(jq -r '.prompt_eval_count' <<<"$result")"
		dur="$(jq -r '.prompt_eval_duration' <<<"$result")"
		rate="$(awk -v c="$count" -v d="$dur" 'BEGIN { if (d > 0) printf "%.0f", c / (d / 1e9); else print "n/a" }')"
		if [ "$run" -eq 0 ]; then
			echo "warm-up: $count prompt tokens, $rate tokens/s"
		else
			echo "run $run:   $count prompt tokens, $rate tokens/s"
		fi
	done
}

case "${1:-}" in
	install) cmd_install ;;
	status) cmd_status ;;
	disable) cmd_disable ;;
	enable) cmd_enable ;;
	uninstall) cmd_uninstall ;;
	bench) shift; cmd_bench "${1:-}" ;;
	*)
		echo "Usage: bash $0 {install|status|disable|enable|uninstall|bench [MODEL]}"
		exit 1
		;;
esac
