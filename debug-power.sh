#!/bin/bash
# debug-power.sh - Deep diagnosis of GPU power negotiation
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Must run as root: sudo $0${NC}"
    exit 1
fi

echo -e "${BOLD}=== GPU Power Debug (HP Omen Transcend 14 - 8C58) ===${NC}"
echo ""

# 1. Platform profile
echo -e "${BOLD}[1] Platform Profile${NC}"
if [[ -f /sys/firmware/acpi/platform_profile ]]; then
    PROFILE=$(cat /sys/firmware/acpi/platform_profile)
    echo -e "  Current: ${BOLD}${PROFILE}${NC}"
    echo -e "  Choices: $(cat /sys/firmware/acpi/platform_profile_choices)"
else
    echo -e "  ${RED}NOT AVAILABLE${NC}"
fi
echo ""

# 2. EC register - the ground truth
echo -e "${BOLD}[2] EC Register 0x95 (Thermal Profile)${NC}"
modprobe ec_sys write_support=1 2>/dev/null || true
if [[ -f /sys/kernel/debug/ec/ec0/io ]]; then
    EC_VAL=$(dd if=/sys/kernel/debug/ec/ec0/io bs=1 count=1 skip=$((0x95)) 2>/dev/null | xxd -p)
    echo -e "  EC 0x95 = ${BOLD}0x${EC_VAL}${NC}"
    case "$EC_VAL" in
        30) echo -e "  Mode: ${YELLOW}V1 Balanced (35W GPU)${NC}" ;;
        31) echo -e "  Mode: ${GREEN}V1 Performance (65W GPU)${NC}" ;;
        50) echo -e "  Mode: ${CYAN}V1 Cool${NC}" ;;
        *)  echo -e "  Mode: ${RED}Unknown${NC}" ;;
    esac

    # Also read nearby EC registers for context
    echo -e "\n  EC register dump (0x90-0x9F):"
    dd if=/sys/kernel/debug/ec/ec0/io bs=1 count=16 skip=$((0x90)) 2>/dev/null | xxd -o 0x90
else
    echo -e "  ${RED}Cannot read EC (debugfs not mounted or ec_sys failed)${NC}"
fi
echo ""

# 3. NPCF ACPI device
echo -e "${BOLD}[3] NPCF ACPI Device (NVDA0820)${NC}"
NPCF_PATH="/sys/bus/acpi/devices/NVDA0820:00"
if [[ -d "$NPCF_PATH" ]]; then
    echo -e "  Status: $(cat ${NPCF_PATH}/status)"
    echo -e "  Path: $(cat ${NPCF_PATH}/path)"
    echo -e "  UID: $(cat ${NPCF_PATH}/uid 2>/dev/null || echo 'N/A')"
else
    echo -e "  ${RED}NPCF device NOT found${NC}"
fi
echo ""

# 4. nvidia-powerd verbose
echo -e "${BOLD}[4] nvidia-powerd Verbose (3 seconds)${NC}"
# Stop the service temporarily
systemctl stop nvidia-powerd 2>/dev/null || true
sleep 0.5
# Run with verbosity and capture output
POWERD_LOG=$(timeout 3 nvidia-powerd -v 2>&1 || true)
echo "$POWERD_LOG" | head -50
# Restart service
systemctl start nvidia-powerd 2>/dev/null || true
echo ""

# 5. GPU power details
echo -e "${BOLD}[5] GPU Power State${NC}"
nvidia-smi -q -d POWER,PERFORMANCE 2>/dev/null | grep -E "Performance State|Power|SW Power|HW Slow|Clock.*Reason|Enforced" | head -20
echo ""

# 6. Try forcing EC to performance directly
echo -e "${BOLD}[6] Force EC 0x95 = 0x31 (Performance)${NC}"
if [[ -f /sys/kernel/debug/ec/ec0/io ]]; then
    printf '\x31' | dd of=/sys/kernel/debug/ec/ec0/io bs=1 count=1 seek=$((0x95)) 2>/dev/null
    sleep 0.5
    EC_AFTER=$(dd if=/sys/kernel/debug/ec/ec0/io bs=1 count=1 skip=$((0x95)) 2>/dev/null | xxd -p)
    echo -e "  EC 0x95 after write: ${BOLD}0x${EC_AFTER}${NC}"
    if [[ "$EC_AFTER" == "31" ]]; then
        echo -e "  ${GREEN}EC write confirmed${NC}"
    else
        echo -e "  ${RED}EC write did not stick! Value reverted to 0x${EC_AFTER}${NC}"
        echo -e "  ${YELLOW}This means the EC/firmware is overriding our write.${NC}"
    fi
fi
echo ""

# 7. Restart nvidia-powerd and check negotiation
echo -e "${BOLD}[7] Restarting nvidia-powerd + checking power after 3s${NC}"
systemctl restart nvidia-powerd
sleep 3
nvidia-smi --query-gpu=power.draw,enforced.power.limit,power.max_limit,clocks.gr,utilization.gpu --format=csv 2>/dev/null
echo ""

# 8. Check for ACPI _DSM methods on GPU
echo -e "${BOLD}[8] GPU ACPI _DSM / Power Config${NC}"
GPU_ACPI=$(find /sys/devices -path "*/0000:01:00.0/firmware_node" -exec readlink {} \; 2>/dev/null | head -1)
if [[ -n "$GPU_ACPI" ]]; then
    echo -e "  GPU ACPI path: $GPU_ACPI"
fi
# Check for nvidia Dynamic Boost sysfs
DBOOST=$(find /sys/devices -path "*01:00.0*" -name "*boost*" -o -name "*power_limit*" 2>/dev/null | head -10)
if [[ -n "$DBOOST" ]]; then
    echo -e "  Dynamic Boost sysfs entries:"
    echo "$DBOOST" | while read f; do echo "    $f = $(cat "$f" 2>/dev/null || echo 'unreadable')"; done
else
    echo -e "  No Dynamic Boost sysfs entries found"
fi
echo ""

# 9. Check if ctgp (Configurable TGP) needs explicit setting
echo -e "${BOLD}[9] ACPI power-related calls via WMI${NC}"
# Use hp_wmi query to read thermal profile via WMI
# Query 0x0025 = HPWMI_THERMAL_PROFILE_QUERY on Omen
python3 -c "
import struct, os
# Try to read platform profile via sysfs as a sanity check
try:
    with open('/sys/firmware/acpi/platform_profile', 'r') as f:
        print(f'  Platform profile (sysfs): {f.read().strip()}')
except:
    print('  Cannot read platform_profile')
" 2>/dev/null || true
echo ""

# 10. Check dGPU PCI power management
echo -e "${BOLD}[10] dGPU PCI Power State${NC}"
echo -e "  Power state: $(cat /sys/bus/pci/devices/0000:01:00.0/power_state 2>/dev/null || echo 'unknown')"
echo -e "  Runtime status: $(cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status 2>/dev/null || echo 'unknown')"
echo -e "  D3cold allowed: $(cat /sys/bus/pci/devices/0000:01:00.0/d3cold_allowed 2>/dev/null || echo 'unknown')"
echo ""

# 11. SW Thermal Slowdown investigation
echo -e "${BOLD}[11] Thermal Investigation${NC}"
echo -e "  GPU temp: $(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader 2>/dev/null)°C"
echo -e "  GPU temp limit: $(nvidia-smi -q -d TEMPERATURE 2>/dev/null | grep -E 'Slowdown Temp|Shutdown Temp|Max Operating' | head -5)"
# Check CPU temps too - shared thermal budget
if command -v sensors &>/dev/null; then
    echo -e "\n  System thermals:"
    sensors 2>/dev/null | grep -E "^(coretemp|Package|Core |iwlwifi|NVIDIA)" -A2 | head -20
fi
echo ""

echo -e "${BOLD}=== Summary ===${NC}"
echo -e "If EC 0x95 shows 0x31 but enforced limit is still <60W, the issue is"
echo -e "in NPCF→nvidia-powerd negotiation. Possible causes:"
echo -e "  1. NPCF ACPI _DSM reports a limited ctgp power budget"
echo -e "  2. nvidia-powerd has a built-in board table that caps this laptop"
echo -e "  3. The EC performance mode doesn't fully unlock NPCF's reported budget"
echo -e ""
echo -e "Next steps to try:"
echo -e "  - Set platform_profile to performance + restart nvidia-powerd"
echo -e "  - Check if nvidia-powerd version supports this GPU/platform combo"
echo -e "  - Try NVIDIA 560+ driver with updated Dynamic Boost tables"
