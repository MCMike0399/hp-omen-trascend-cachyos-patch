#!/bin/bash
# validate-boot.sh — Post-reboot health check for Ralph loop safe-apply gate
# Run this IMMEDIATELY after rebooting with ACPI override installed
#
# Usage: sudo ./validate-boot.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

SNAPSHOT_FILE="/tmp/ralph-snapshot-id"
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_WARN=0

pass() { echo -e "  ${GREEN}PASS${NC}: $1"; CHECKS_PASSED=$((CHECKS_PASSED + 1)); }
fail() { echo -e "  ${RED}FAIL${NC}: $1"; CHECKS_FAILED=$((CHECKS_FAILED + 1)); }
warn_() { echo -e "  ${YELLOW}WARN${NC}: $1"; CHECKS_WARN=$((CHECKS_WARN + 1)); }

if [[ $EUID -ne 0 ]]; then
    echo "Must run as root"
    exit 1
fi

echo -e "${BOLD}=== Post-Reboot Health Check ===${NC}"
echo ""

# 1. Kernel version
echo -e "${BOLD}[1] Kernel${NC}"
KERNEL=$(uname -r)
echo -e "  Running: ${KERNEL}"
if [[ "$KERNEL" == *cachyos* ]]; then
    pass "CachyOS kernel"
else
    warn_ "Unexpected kernel: ${KERNEL}"
fi

# 2. Boot errors
echo -e "${BOLD}[2] Critical boot errors${NC}"
ERRORS=$(journalctl -b -p err --no-pager 2>/dev/null | grep -v "audit\|ACPI Error.*AE_NOT_FOUND" | head -10)
if [[ -z "$ERRORS" ]]; then
    pass "No critical errors"
else
    warn_ "Some errors found (may be normal):"
    echo "$ERRORS" | head -5 | sed 's/^/    /'
fi

# 3. ACPI override loaded
echo -e "${BOLD}[3] SSDT25 ACPI override${NC}"
ACPI_MSG=$(dmesg 2>/dev/null | grep -iE "ACPI.*override|ACPI.*table.*upgrade|SSDT.*loaded|acpi.*ssdt" || true)
if [[ -n "$ACPI_MSG" ]]; then
    pass "ACPI override detected in dmesg"
    echo "$ACPI_MSG" | head -3 | sed 's/^/    /'
else
    # Check if SSDT count changed or if the override is present in /sys
    SSDT_COUNT=$(find /sys/firmware/acpi/tables/ -name "SSDT*" 2>/dev/null | wc -l)
    warn_ "No explicit ACPI override message in dmesg (${SSDT_COUNT} SSDTs found)"
    echo "    This might still work — check GPU thermal behavior under load"
fi

# 4. hp-wmi module
echo -e "${BOLD}[4] hp-wmi module${NC}"
if lsmod | grep -q hp_wmi; then
    pass "hp-wmi loaded"
    # Check if it's the DKMS version
    MODPATH=$(modinfo -F filename hp_wmi 2>/dev/null || echo "unknown")
    if echo "$MODPATH" | grep -q dkms; then
        pass "DKMS patched version"
    else
        warn_ "Module path: ${MODPATH} (expected DKMS)"
    fi
else
    fail "hp-wmi NOT loaded"
fi

# 5. Platform profile
echo -e "${BOLD}[5] Platform profile${NC}"
PROFILE=$(cat /sys/firmware/acpi/platform_profile 2>/dev/null || echo "unavailable")
if [[ "$PROFILE" == "performance" ]]; then
    pass "Profile: performance"
else
    warn_ "Profile: ${PROFILE} (expected performance)"
fi

# 6. GPU state
echo -e "${BOLD}[6] GPU state${NC}"
GPU_INFO=$(nvidia-smi --query-gpu=power.draw,power.limit,enforced.power.limit,temperature.gpu --format=csv,noheader 2>/dev/null || echo "unavailable")
if [[ "$GPU_INFO" != "unavailable" ]]; then
    pass "nvidia-smi responsive"
    echo "    Power/Limit/Enforced/Temp: ${GPU_INFO}"
else
    fail "nvidia-smi not responding"
fi

# 7. GPU thermal throttle status (the key metric)
echo -e "${BOLD}[7] GPU thermal throttle (KEY CHECK)${NC}"
THROTTLE_INFO=$(nvidia-smi -q 2>/dev/null | grep -A5 "GPU Slowdown Temp" || true)
SLOWDOWN=$(nvidia-smi -q 2>/dev/null | grep "GPU Slowdown Temp" | head -1 | grep -oP '\d+' || echo "unknown")
if [[ "$SLOWDOWN" != "unknown" ]]; then
    if [[ "$SLOWDOWN" -gt 20 ]]; then
        pass "GPU Slowdown Temp: ${SLOWDOWN}°C (override working!)"
    else
        fail "GPU Slowdown Temp: ${SLOWDOWN}°C (still throttled, override may not have taken effect)"
    fi
else
    warn_ "Could not read GPU Slowdown Temp"
fi

# Check SW Thermal Slowdown
SW_THROTTLE=$(nvidia-smi -q 2>/dev/null | grep -A1 "SW Thermal Slowdown" | tail -1 | tr -d ' ' || echo "unknown")
echo "    SW Thermal Slowdown: ${SW_THROTTLE}"

echo ""
echo -e "${BOLD}=== Results ===${NC}"
echo -e "  Passed: ${CHECKS_PASSED}  Warnings: ${CHECKS_WARN}  Failed: ${CHECKS_FAILED}"
echo ""

if [[ $CHECKS_FAILED -gt 0 ]]; then
    echo -e "${RED}${BOLD}HEALTH CHECK HAS FAILURES${NC}"
    if [[ -f "$SNAPSHOT_FILE" ]]; then
        SNAP_NUM=$(cat "$SNAPSHOT_FILE")
        echo -e "Rollback available: snapper -c root undochange ${SNAP_NUM}..0"
    fi
    echo -e "Investigate failures before testing under load."
    exit 1
else
    echo -e "${GREEN}${BOLD}HEALTH CHECK PASSED${NC}"
    echo ""
    echo -e "Next steps:"
    echo -e "  1. Open a root terminal and run: ./gpu-ralph.sh"
    echo -e "  2. Launch Persona 3 Reload"
    echo -e "  3. Watch for power > 50W at high utilization"
    echo -e "  4. If power > 50W → SUCCESS! Create post-snapshot:"
    echo -e "     snapper -c root create -d 'post-ralph: SSDT25 validated' --type post --pre-number \$(cat /tmp/ralph-snapshot-id)"
    exit 0
fi
