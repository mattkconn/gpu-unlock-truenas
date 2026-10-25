#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# gpu-unlock for TrueNAS: boot hook.
#
# modprobe runs this right before it loads the NVIDIA driver, because of
# /etc/modprobe.d/gpu-unlock.conf. It loads gpu_unlock.ko, which unlocks the
# card and resets it, and then modprobe loads nvidia as usual.
#
# The NVIDIA driver must load whatever happens here, so this script never
# fails: every problem is logged (journalctl -b -t gpu-unlock) and skipped.

D=/root/gpu-unlock
K=$(uname -r)
KO="$D/modules/$K/gpu_unlock.ko"
FWP=/sys/module/firmware_class/parameters/path

log() { logger -t gpu-unlock "$*" 2>/dev/null || true; }

# One-off skip: add gpu_unlock.off to the kernel command line in GRUB.
if grep -q 'gpu_unlock\.off' /proc/cmdline 2>/dev/null; then
	log "gpu_unlock.off is on the kernel command line; skipping the unlock"
	exit 0
fi

if [ -e "$D/disabled" ]; then
	log "disabled ($D/disabled exists); skipping the unlock"
	exit 0
fi

if grep -q '^gpu_unlock ' /proc/modules 2>/dev/null; then
	exit 0
fi

if [ ! -f "$KO" ]; then
	log "no gpu_unlock module built for kernel $K; skipping the unlock (run the install again after a TrueNAS update)"
	exit 0
fi

TARGETS=$(cat "$D/targets" 2>/dev/null)
[ -n "$TARGETS" ] || TARGETS=all

# The module asks for its firmware by name; /lib/firmware is read-only on
# TrueNAS, so point the firmware loader at our copy first.
OLD=$(cat "$FWP" 2>/dev/null)
printf '%s' "$D/firmware" > "$FWP" 2>/dev/null || log "could not set the firmware search path"

if OUT=$(/sbin/insmod "$KO" "targets=$TARGETS" 2>&1); then
	log "gpu_unlock loaded (targets=$TARGETS). Result: journalctl -k -b | grep gpu_unlock"
else
	log "insmod gpu_unlock failed: $OUT"
fi

if [ -n "$OLD" ]; then
	printf '%s' "$OLD" > "$FWP" 2>/dev/null || true
fi

exit 0
