#!/bin/bash
# fan-speed-test.sh - Test fan speed control via WMI and EC
# Monitors EC registers while changing fan speeds
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Must run as root: sudo $0"
    exit 1
fi

modprobe ec_sys write_support=1 2>/dev/null || true
EC="/sys/kernel/debug/ec/ec0/io"

HP_HWMON=""
for f in /sys/class/hwmon/*/name; do
    if [[ "$(cat $f)" == "hp" ]]; then
        HP_HWMON="$(dirname $f)"
        break
    fi
done

read_ec() {
    local offset=$1
    dd if="$EC" bs=1 count=1 skip=$((offset)) 2>/dev/null | xxd -p
}

read_fan_regs() {
    local label="$1"
    local fan1=$(cat ${HP_HWMON}/fan1_input)
    local fan2=$(cat ${HP_HWMON}/fan2_input)
    local r2e=$(read_ec 0x2E)
    local r2f=$(read_ec 0x2F)
    local rb0=$(read_ec 0xB0)
    local rb1=$(read_ec 0xB1)
    local rb2=$(read_ec 0xB2)
    local rb3=$(read_ec 0xB3)
    local rec=$(read_ec 0xEC)
    printf "  %-20s Fan1=%4d Fan2=%4d | 0x2E=%s 0x2F=%s | 0xB0=%s 0xB1=%s 0xB2=%s 0xB3=%s | 0xEC=%s\n" \
        "$label" "$fan1" "$fan2" "$r2e" "$r2f" "$rb0" "$rb1" "$rb2" "$rb3" "$rec"
}

echo "=== Fan Speed Control Test ==="
echo ""

# Baseline
echo "[1] Baseline readings (3 samples, 1s apart)"
for i in 1 2 3; do
    read_fan_regs "auto-$i"
    sleep 1
done
echo ""

# Save baseline EC for later comparison
dd if="$EC" bs=1 count=256 of=/tmp/ec-baseline.bin 2>/dev/null

# Test: Write specific values to 0xEC to see if it controls fan mode
echo "[2] Testing 0xEC as fan mode register"
echo "  Writing 0xEC = 0x0C (max fan mode trigger)..."
printf '\x0c' | dd of="$EC" bs=1 count=1 seek=$((0xEC)) 2>/dev/null
sleep 2
read_fan_regs "EC=0x0C"

echo "  Writing 0xEC = 0x00 (auto mode)..."
printf '\x00' | dd of="$EC" bs=1 count=1 seek=$((0xEC)) 2>/dev/null
sleep 2
read_fan_regs "EC=0x00"
echo ""

# Test: Try different 0xB0 values to see if it controls fan1 speed
echo "[3] Testing 0xB0 as fan1 speed register"
echo "  First, set 0xEC = 0x0C (manual mode)..."
printf '\x0c' | dd of="$EC" bs=1 count=1 seek=$((0xEC)) 2>/dev/null
sleep 1

BASELINE_B0=$(read_ec 0xB0)
echo "  Current 0xB0 = 0x${BASELINE_B0}"

for val in 40 80 C0 FF; do
    echo "  Writing 0xB0 = 0x${val}..."
    printf "\\x${val}" | dd of="$EC" bs=1 count=1 seek=$((0xB0)) 2>/dev/null
    sleep 2
    read_fan_regs "B0=0x${val}"
done
echo ""

# Test: Try different 0xB2 values to see if it controls fan2 speed
echo "[4] Testing 0xB2 as fan2 speed register"
BASELINE_B2=$(read_ec 0xB2)
echo "  Current 0xB2 = 0x${BASELINE_B2}"

for val in 40 80 C0 FF; do
    echo "  Writing 0xB2 = 0x${val}..."
    printf "\\x${val}" | dd of="$EC" bs=1 count=1 seek=$((0xB2)) 2>/dev/null
    sleep 2
    read_fan_regs "B2=0x${val}"
done
echo ""

# Restore auto mode
echo "[5] Restoring auto fan mode..."
printf '\x00' | dd of="$EC" bs=1 count=1 seek=$((0xEC)) 2>/dev/null
# Also restore via hwmon to be safe
echo 2 > ${HP_HWMON}/pwm1_enable 2>/dev/null || true
sleep 2
read_fan_regs "restored"
echo ""

# Alternative: Test WMI fan speed set with non-zero values
echo "[6] Testing WMI FAN_SPEED_SET (query 0x2E) with custom values"
echo "  Note: WMI 0x2E accepts [fan0_speed, fan1_speed] as 2-byte buffer"
echo "  Saving EC state before WMI test..."
dd if="$EC" bs=1 count=256 of=/tmp/ec-pre-wmi.bin 2>/dev/null

# Try setting fan speeds to a medium value (0x32 = 50%)
echo "  Setting fans to 50% (0x32, 0x32) via hwmon max then monitoring..."
echo 0 > ${HP_HWMON}/pwm1_enable
sleep 1
dd if="$EC" bs=1 count=256 of=/tmp/ec-wmi-max.bin 2>/dev/null

echo "  EC diff (pre-WMI → max via hwmon):"
python3 -c "
pre = open('/tmp/ec-pre-wmi.bin','rb').read()
post = open('/tmp/ec-wmi-max.bin','rb').read()
for i in range(min(len(pre), len(post))):
    if pre[i] != post[i]:
        print(f'    0x{i:02X}: 0x{pre[i]:02X} → 0x{post[i]:02X}')
" 2>/dev/null
echo ""

# Now try writing a mid-range value to the identified fan speed registers
echo "  Testing mid-range fan speed via EC direct write..."
echo "  Setting 0xEC=0x0C (manual), 0xB0=0x80 (fan1 mid), 0xB2=0x80 (fan2 mid)..."
printf '\x0c' | dd of="$EC" bs=1 count=1 seek=$((0xEC)) 2>/dev/null
printf '\x80' | dd of="$EC" bs=1 count=1 seek=$((0xB0)) 2>/dev/null
printf '\x80' | dd of="$EC" bs=1 count=1 seek=$((0xB2)) 2>/dev/null
sleep 3
read_fan_regs "mid-range"

# Check if values stuck
echo "  Checking if values held..."
sleep 2
read_fan_regs "mid-range+2s"
echo ""

# Final restore
echo "[7] Final restore to auto mode"
echo 2 > ${HP_HWMON}/pwm1_enable 2>/dev/null || true
printf '\x00' | dd of="$EC" bs=1 count=1 seek=$((0xEC)) 2>/dev/null
sleep 2
read_fan_regs "final"
echo ""

echo "=== Test Complete ==="
echo "Check if fan RPMs changed in response to 0xB0/0xB2 writes."
echo "If 0xB0/0xB2 control fans, we can build a custom fan curve controller."
