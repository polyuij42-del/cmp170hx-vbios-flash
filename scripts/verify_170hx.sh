#!/bin/bash
# Post-flash verification for CMP 170HX VBIOS swap. Run AFTER reboot.
set -u
PASS=0; FAIL=0
ok()  { echo "  ✅ $*"; PASS=$((PASS+1)); }
bad() { echo "  ❌ $*"; FAIL=$((FAIL+1)); }

echo "=== 1) VBIOS version ==="
nvidia-smi --query-gpu=pci.bus_id,vbios_version --format=csv,noheader | while IFS=, read -r bdf ver; do
    echo "  $bdf -> $ver"
done
NEW=$(nvidia-smi --query-gpu=pci.bus_id,vbios_version --format=csv,noheader | grep -c "92.00.6D.00.0A")
[ "$NEW" -ge 1 ] && ok "new 300W VBIOS active on $NEW card(s)" || bad "no card reports 92.00.6D.00.0A"

echo "=== 2) Memory clock ceiling (expect 1728 MHz on flashed cards) ==="
nvidia-smi --query-gpu=pci.bus_id,clocks.max.memory --format=csv,noheader
nvidia-smi --query-gpu=clocks.max.memory --format=csv,noheader | grep -q "1728" && ok "1728 MHz present" || bad "no 1728 MHz"

echo "=== 3) Power limit ceiling (expect max adj range up to 300W) ==="
for i in $(nvidia-smi --query-gpu=index --format=csv,noheader); do
    nvidia-smi -i "$i" -q -d POWER | grep -E "Power Limit|Default Power|Max Power|Min Power" | head -4
done

echo "=== 4) 64GB unlock (cmpunlocker PLM) ==="
nvidia-smi --query-gpu=pci.bus_id,memory.total --format=csv,noheader
nvidia-smi --query-gpu=memory.total --format=csv,noheader | grep -q "65536" && ok "65536 MiB exposed" || bad "64GB unlock lost!"
sudo dmesg | grep -c "SEC2_DEBUG" >/dev/null && sudo dmesg | grep "SEC2_DEBUG: PLM" | head -3

echo "=== 5) Quick memory bandwidth sanity (optional, needs torch) ==="
echo "  skip unless you have a bench script; tg (decode) scales with bandwidth."

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo "ALL GOOD" || echo "CHECK FAILURES ABOVE"
