#!/bin/bash
# =============================================================================
# CMP 170HX 8GB VBIOS flash (250W 92.00.67.00.01 -> 300W 92.00.6D.00.0A)
# 2026-09-26 proven recipe. Run as root on the target machine.
#
# Usage:
#   sudo ./flash_170hx_300w.sh              # flash nvflash adapter <0>
#   sudo INDEX=1 ./flash_170hx_300w.sh      # flash adapter <1>
#
# BEFORE running, edit the variables below. Read docs/01-falcon-window.md
# so you understand why the order of operations is what it is.
# =============================================================================
set -x

# ------------------------- EDIT THESE ---------------------------------------
INDEX="${INDEX:-0}"                                   # nvflash adapter index (see: nvflash --list)
BDF_SELF="${BDF_SELF:-0000:02:00.0}"                  # PCI address of the SAME card (for rescan unwedge)
BDF_OTHER="${BDF_OTHER:-0000:81:00.0}"                # PCI address of the other card (if any, else leave same)
ROM="${ROM:-/data/vbios/GA100[CMP170HX8GB]-64G-92.00.6D.00.0A.rom}"
NV="${NV:-/opt/flash170hx/x64/nvflash}"               # nvflash 5.867 binary
LOGDIR="${LOGDIR:-/data/vbios/logs}"                  # PERSISTENT location (NOT /tmp - wiped on reboot)
# -----------------------------------------------------------------------------

Y_PROMPT_DELAY="${Y_PROMPT_DELAY:-45}"                # seconds before feeding 'y' (EEPROM read takes ~30s)
BK="$LOGDIR/backup_$(date -u +%Y%m%dT%H%M%SZ)_idx${INDEX}.rom"
TS="$LOGDIR/flash_ts_idx${INDEX}.log"
WLOG="$LOGDIR/flash_write_idx${INDEX}.log"
RB="$LOGDIR/readback_idx${INDEX}.rom"

mkdir -p "$LOGDIR"
exec > "$LOGDIR/flash_main.log" 2>&1

die() { echo "FATAL: $*"; exit 1; }
[ -x "$NV" ]   || die "nvflash not found at $NV"
[ -f "$ROM" ]  || die "ROM not found at $ROM"
[ "$(id -u)" -eq 0 ] || die "run as root"

# sanity: the ROM must be for THIS card family (10DE:20C2 / 10DE:1585)
"$NV" --version "$ROM" 2>&1 | grep -q "Version               : 92.00" || die "ROM version unreadable"
"$NV" --version "$ROM" 2>&1 | grep -q "Device ID             : 0x20C2" || die "ROM Device ID != 0x20C2"
"$NV" --version "$ROM" 2>&1 | grep -q "Subsystem ID          : 0x1585" || die "ROM Subsystem ID != 0x1585"
echo "ROM sanity OK"

# ---------------------------------------------------------------------------
echo "===== [A] GUARD: freeze everything that could reload the driver ====="
printf "install nvidia /bin/false\ninstall nvidia_modeset /bin/false\ninstall nvidia_drm /bin/false\ninstall nvidia_uvm /bin/false\n" \
    > /etc/modprobe.d/zz-flash-window.conf
systemctl stop systemd-udevd-control.socket systemd-udevd-kernel.socket systemd-udevd-varlink.socket systemd-udevd.service 2>/dev/null
systemctl stop gdm3 2>/dev/null
systemctl stop nvidia-persistenced 2>/dev/null
pkill -9 Xorg 2>/dev/null
sleep 2

# ---------------------------------------------------------------------------
echo "===== [B] KILL HOLDERS, THEN UNBIND + UNLOAD ====="
# ORDER MATTERS (2026-09-26 GPU1 lesson): unbinding while ANY process holds
# /dev/nvidia* wedges the driver's remove callback in nv_pci_remove_helper
# -> os_delay forever ("NVRM: Attempting to remove device ... non-zero usage
# count"). Killing the holder afterwards does NOT unstick it - only a reboot
# does. So: kill every holder FIRST, verify zero handles, THEN unbind.
fuser -k /dev/nvidia* 2>/dev/null
sleep 3
fuser -k /dev/nvidia* 2>/dev/null
sleep 2
HELD=$(lsof /dev/nvidia* 2>/dev/null | tail -n +2 | wc -l)
[ "$HELD" -eq 0 ] || die "$HELD handles still open on /dev/nvidia* - do NOT unbind; find and stop the holder first"
# unbind BOTH GPUs, otherwise rmmod fails with "in use".
# NOTE: if this write hangs in D state, the card's Falcon is wedged -> cold
# power cycle is the only way out (see docs/01-falcon-window.md).
for BDF in "$BDF_SELF" "$BDF_OTHER"; do
    echo "$BDF" > /sys/bus/pci/drivers/nvidia/unbind 2>/dev/null || echo "unbind $BDF failed (maybe not bound)"
done
sleep 2
for i in 1 2 3 4 5 6 7 8; do
    rmmod nvidia_uvm 2>/dev/null; rmmod nvidia_drm 2>/dev/null
    rmmod nvidia_modeset 2>/dev/null; rmmod nvidia 2>/dev/null
    lsmod | grep -q "^nvidia" || break
    sleep 2
done
lsmod | grep -q "^nvidia" && die "driver still loaded after 8 attempts"
echo "UNLOADED-OK"
sleep 2

# ---------------------------------------------------------------------------
echo "===== [C] ROLLBACK CHECK (NOT a backup!) ====="
# DO NOT run `--save` here. Backup and write cannot share one Falcon window:
# op#1 --save + op#2 write => write dies with "Falcon In HALT or STOP state"
# (docs/01-falcon-window.md). Your rollback ROM must already exist from an
# EARLIER boot window, or use a same-version ROM from the twin card (verify
# the static region <0xC2000 matches, then it is equivalent for rollback).
ROLLBACK="${ROLLBACK:-}"
if [ -n "$ROLLBACK" ] && [ -f "$ROLLBACK" ]; then
    echo "rollback ROM present: $ROLLBACK"
else
    die "no rollback ROM - get one from an earlier boot window first (ABORT)"
fi

# ---------------------------------------------------------------------------
echo "===== [D] WRITE (first Falcon op of a fresh window, timed 'y' via pty) ====="
# nvflash 5.867 ignores -y; the confirm prompt needs a REAL tty.
# The (sleep 45; echo y; sleep N) subshell feeds 'y' right after the
# "Reading EEPROM (up to 30 seconds)" phase, through script's pty.
rm -f "$TS"
( sleep "$Y_PROMPT_DELAY"; echo y; sleep 500 ) | \
    timeout 600 script -qec "$NV -i $INDEX $ROM" "$TS" > /dev/null 2>&1
RC=$?
echo "FLASH-WRITE-RC=$RC"
echo "--- typescript ---"
tr -d "\r" < "$TS" | grep -vE "^y$|^$" | tail -25
# success marker: "A reboot is required for the update to take effect." + rc 0
tr -d "\r" < "$TS" | grep -q "A reboot is required" || die "no success marker in typescript (rc=$RC) - see docs/03"

# ---------------------------------------------------------------------------
echo "===== [E] READBACK (best-effort; needs a new Falcon window) ====="
# after a successful write the Falcon is busy again; a PCIe remove+rescan
# sometimes re-opens a window. This check is advisory, not required.
echo remove | tee "/sys/bus/pci/devices/$BDF_SELF/remove" >/dev/null 2>&1 || true
sleep 2
echo 1 | tee /sys/bus/pci/rescan >/dev/null 2>&1
sleep 12
if timeout 120 "$NV" -i "$INDEX" --save "$RB" 2>/dev/null; then
    python3 - "$ROM" "$RB" <<'EOF'
import hashlib, sys
s = open(sys.argv[1], "rb").read(); r = open(sys.argv[2], "rb").read()
d = [i for i in range(min(len(s), len(r))) if s[i] != r[i]]
print("readback diff:", len(d), "bytes;",
      "in VBIOS proper (<0xC0000):", len([i for i in d if i < 0xC0000]),
      "(small count here = OK; nvflash preserves per-card fields and the")
print("0xC2000+ region is per-boot dynamic data - it never matches)")
EOF
else
    echo "readback skipped (Falcon busy) - verify after reboot instead"
fi

# ---------------------------------------------------------------------------
echo "===== [F] CLEANUP (restore normal boot) ====="
rm -f /etc/modprobe.d/zz-flash-window.conf
systemctl start systemd-udevd.service systemd-udevd-control.socket systemd-udevd-kernel.socket systemd-udevd-varlink.socket 2>/dev/null
echo "=== DONE. Reboot now, then run verify_170hx.sh ==="
