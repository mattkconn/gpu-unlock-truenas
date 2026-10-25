# gpu-unlock on TrueNAS SCALE

A TrueNAS wrapper around the upstream `gpu_unlock` kernel module in this
repository. It does not change the module's code.

Tested target: TrueNAS 25.10.7, kernel 6.12.105-production+truenas, NVIDIA
open driver 580.173.02 (TrueNAS sysext), RTX 3090.

## Why the upstream install doesn't work on TrueNAS

- `/usr` (including `/lib/modules` and `/lib/firmware`) is read-only, and apt/dpkg are locked.
- There is no compiler on the host.
- TrueNAS loads the NVIDIA driver from middlewared (`modprobe -a nvidia ...`)
  about 30 s into boot, before data pools are imported and before Pre Init
  scripts run. That rules out Init scripts and files stored on pools.

## What this does instead

- `gpu-unlock.sh install` builds `gpu_unlock.ko` and the firmware in a
  throwaway `debian:bookworm` container (the same gcc 12.2.0 the TrueNAS kernel
  was built with), against `/lib/modules/$(uname -r)/build`.
- It checks the module's vermagic and test-loads it without `targets=` (which touches no card).
- It installs the module and firmware under `/root/gpu-unlock` (boot pool, readable early in boot).
- It adds `/etc/modprobe.d/gpu-unlock.conf` with an `install nvidia` hook.
  When middlewared loads nvidia, the hook runs `load.sh` first, which points
  the firmware loader at `/root/gpu-unlock/firmware` and runs `insmod gpu_unlock.ko targets=all`.
  Then nvidia loads as usual.
- `load.sh` always exits 0, so the NVIDIA driver loads even if the unlock is skipped or fails.

## Commands (as root)

```
bash truenas/gpu-unlock.sh install
bash truenas/gpu-unlock.sh status
bash truenas/gpu-unlock.sh disable
bash truenas/gpu-unlock.sh enable
bash truenas/gpu-unlock.sh uninstall
bash truenas/gpu-unlock.sh bench MODEL
```

## After a TrueNAS update

Each update boots a new boot environment with a new `/etc` and `/root` and
usually a new kernel. Until `install` is run again, the hook is gone or finds
no module for the new kernel, and the GPU runs at normal speed.

## If a boot goes wrong

- Pick the previous boot environment in the GRUB menu; it has no hook.
- Or, in GRUB, press `e` and add `gpu_unlock.off` to the `linux` line for one boot.
