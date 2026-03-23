#!/bin/bash
# fan-control-test.sh - Probe and test fan control on HP Omen Transcend 14
# This script is exploratory - it reads EC registers and tests WMI fan queries
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Must run as root: sudo $0"
    exit 1
fi

modprobe ec_sys write_support=1 2>/dev/null || true

echo "=== Fan Control Probe (HP Omen Transcend 14 - 8C58) ==="
echo ""

# 1. Current fan speeds via hwmon
echo "[1] Current fan speeds (hwmon)"
for f in /sys/class/hwmon/*/name; do
    if [[ "$(cat $f)" == "hp" ]]; then
        HP_HWMON="$(dirname $f)"
        echo "  Fan 1: $(cat ${HP_HWMON}/fan1_input) RPM"
        echo "  Fan 2: $(cat ${HP_HWMON}/fan2_input) RPM"
        echo "  PWM mode: $(cat ${HP_HWMON}/pwm1_enable) (0=max, 2=auto)"
        break
    fi
done
echo ""

# 2. EC register dump - fan-related regions
echo "[2] EC register dump (fan-related regions)"
if [[ -f /sys/kernel/debug/ec/ec0/io ]]; then
    echo "  0x30-0x3F (possible fan targets):"
    dd if=/sys/kernel/debug/ec/ec0/io bs=1 count=16 skip=$((0x30)) 2>/dev/null | xxd -o 0x30
    echo "  0x40-0x4F:"
    dd if=/sys/kernel/debug/ec/ec0/io bs=1 count=16 skip=$((0x40)) 2>/dev/null | xxd -o 0x40
    echo "  0x50-0x5F:"
    dd if=/sys/kernel/debug/ec/ec0/io bs=1 count=16 skip=$((0x50)) 2>/dev/null | xxd -o 0x50
    echo "  0x60-0x6F (0x62=flags, 0x63=timer):"
    dd if=/sys/kernel/debug/ec/ec0/io bs=1 count=16 skip=$((0x60)) 2>/dev/null | xxd -o 0x60
    echo "  0x70-0x7F:"
    dd if=/sys/kernel/debug/ec/ec0/io bs=1 count=16 skip=$((0x70)) 2>/dev/null | xxd -o 0x70
    echo "  0x80-0x8F:"
    dd if=/sys/kernel/debug/ec/ec0/io bs=1 count=16 skip=$((0x80)) 2>/dev/null | xxd -o 0x80
    echo "  0x90-0x9F (0x95=thermal profile):"
    dd if=/sys/kernel/debug/ec/ec0/io bs=1 count=16 skip=$((0x90)) 2>/dev/null | xxd -o 0x90
    echo "  0xA0-0xAF:"
    dd if=/sys/kernel/debug/ec/ec0/io bs=1 count=16 skip=$((0xA0)) 2>/dev/null | xxd -o 0xA0
    echo "  0xB0-0xBF (possible fan mode):"
    dd if=/sys/kernel/debug/ec/ec0/io bs=1 count=16 skip=$((0xB0)) 2>/dev/null | xxd -o 0xB0
    echo "  0xC0-0xCF:"
    dd if=/sys/kernel/debug/ec/ec0/io bs=1 count=16 skip=$((0xC0)) 2>/dev/null | xxd -o 0xC0
    echo "  0xD0-0xDF:"
    dd if=/sys/kernel/debug/ec/ec0/io bs=1 count=16 skip=$((0xD0)) 2>/dev/null | xxd -o 0xD0
    echo "  0xE0-0xEF:"
    dd if=/sys/kernel/debug/ec/ec0/io bs=1 count=16 skip=$((0xE0)) 2>/dev/null | xxd -o 0xE0
    echo "  0xF0-0xFF:"
    dd if=/sys/kernel/debug/ec/ec0/io bs=1 count=16 skip=$((0xF0)) 2>/dev/null | xxd -o 0xF0
else
    echo "  Cannot access EC debugfs"
fi
echo ""

# 3. Full EC dump for comparison (save to file)
echo "[3] Saving full EC dump to /tmp/ec-dump-auto.bin"
if [[ -f /sys/kernel/debug/ec/ec0/io ]]; then
    dd if=/sys/kernel/debug/ec/ec0/io bs=1 count=256 of=/tmp/ec-dump-auto.bin 2>/dev/null
    echo "  Saved. Current fan mode: auto"
fi
echo ""

# 4. Set fans to max and dump EC again to find which registers change
echo "[4] Setting fans to MAX and capturing EC changes..."
echo "  Current RPM: Fan1=$(cat ${HP_HWMON}/fan1_input), Fan2=$(cat ${HP_HWMON}/fan2_input)"
echo 0 > ${HP_HWMON}/pwm1_enable
sleep 3
echo "  Max RPM:     Fan1=$(cat ${HP_HWMON}/fan1_input), Fan2=$(cat ${HP_HWMON}/fan2_input)"

if [[ -f /sys/kernel/debug/ec/ec0/io ]]; then
    dd if=/sys/kernel/debug/ec/ec0/io bs=1 count=256 of=/tmp/ec-dump-max.bin 2>/dev/null
    echo "  Saved EC dump to /tmp/ec-dump-max.bin"
    echo ""
    echo "  EC registers that CHANGED (auto → max):"
    python3 -c "
auto = open('/tmp/ec-dump-auto.bin','rb').read()
maxf = open('/tmp/ec-dump-max.bin','rb').read()
for i in range(min(len(auto), len(maxf))):
    if auto[i] != maxf[i]:
        print(f'    0x{i:02X}: 0x{auto[i]:02X} → 0x{maxf[i]:02X}')
" 2>/dev/null || echo "  (python3 not available for comparison)"
fi
echo ""

# 5. Restore auto mode
echo "[5] Restoring auto fan mode..."
echo 2 > ${HP_HWMON}/pwm1_enable
sleep 2
echo "  Restored. RPM: Fan1=$(cat ${HP_HWMON}/fan1_input), Fan2=$(cat ${HP_HWMON}/fan2_input)"
echo ""

# 6. Save auto dump again for 3-way comparison
if [[ -f /sys/kernel/debug/ec/ec0/io ]]; then
    dd if=/sys/kernel/debug/ec/ec0/io bs=1 count=256 of=/tmp/ec-dump-auto2.bin 2>/dev/null
    echo "  EC registers that CHANGED (max → auto restored):"
    python3 -c "
maxf = open('/tmp/ec-dump-max.bin','rb').read()
auto2 = open('/tmp/ec-dump-auto2.bin','rb').read()
for i in range(min(len(maxf), len(auto2))):
    if maxf[i] != auto2[i]:
        print(f'    0x{i:02X}: 0x{maxf[i]:02X} → 0x{auto2[i]:02X}')
" 2>/dev/null || echo "  (python3 not available for comparison)"
fi
echo ""

echo "=== Done ==="
echo "EC dumps saved to /tmp/ec-dump-auto.bin, /tmp/ec-dump-max.bin, /tmp/ec-dump-auto2.bin"
echo "Compare with: xxd /tmp/ec-dump-auto.bin > /tmp/ec-auto.hex && xxd /tmp/ec-dump-max.bin > /tmp/ec-max.hex && diff /tmp/ec-auto.hex /tmp/ec-max.hex"
