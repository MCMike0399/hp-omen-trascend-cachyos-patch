#!/bin/bash
# gps-thermal-daemon.sh — Runtime GPS thermal limit fix (no reboot needed)
# Continuously primes GPSP buffer with TGPU=87°C via acpi_call
# This validates the SSDT25 fix works BEFORE touching initramfs.
#
# Usage: sudo ./gps-thermal-daemon.sh
# Stop: Ctrl+C or kill the process
#
# If GPU power goes >50W under load → fix is validated, proceed to Phase 2
# If GPU stays at ~35W → GPS thermal limit is NOT the bottleneck

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Must run as root"
    exit 1
fi

# Load acpi_call if not loaded
if ! lsmod | grep -q acpi_call; then
    echo "Loading acpi_call module..."
    modprobe acpi_call || { echo "FAIL: acpi_call not available. Install: pacman -S acpi_call-dkms"; exit 1; }
fi

# GPS _DSM path and parameters
# UUID: A3132D01-8CDA-49BA-A52E-BC9D46DF6B81 (16 bytes, mixed-endian)
# Revision: 0x0200, Function: 0x2A (42), Arg: subcase 2 (prime TGPU)
GPS_DSM='\_SB.PC00.RP12.PXSX._DSM {0x01,0x2d,0x13,0xa3,0xda,0x8c,0xba,0x49,0xa5,0x2e,0xbc,0x9d,0x46,0xdf,0x6b,0x81} 0x0200 0x2A {0x02,0x00,0x00,0x00}'

INTERVAL=1
PRIME_COUNT=0
FAIL_COUNT=0

echo "=== GPS Thermal Daemon ==="
echo "Priming GPSP buffer with TGPU=87°C every ${INTERVAL}s"
echo "Press Ctrl+C to stop"
echo ""

cleanup() {
    echo ""
    echo "Stopped after ${PRIME_COUNT} primes (${FAIL_COUNT} failures)"
    exit 0
}
trap cleanup INT TERM

while true; do
    # Prime the GPSP buffer: subcase 2 sets TGPU=GPSV (87°C)
    echo "$GPS_DSM" > /proc/acpi/call 2>/dev/null
    RESULT=$(cat /proc/acpi/call 2>/dev/null)

    PRIME_COUNT=$((PRIME_COUNT + 1))

    if [[ -n "$RESULT" && "$RESULT" != "not called" ]]; then
        # Check for 0x57 (87) at expected position in result
        if echo "$RESULT" | grep -q "0x57"; then
            STATUS="OK (TGPU=87°C confirmed)"
        else
            STATUS="PRIMED (buffer written, checking...)"
        fi
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        STATUS="FAIL"
    fi

    # Also read current GPU power for quick feedback
    POWER=$(nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits 2>/dev/null || echo "?")
    TEMP=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader 2>/dev/null || echo "?")
    UTIL=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader 2>/dev/null || echo "?")

    printf "\r[%04d] %s | GPU: %.1fW %s°C %s util    " "$PRIME_COUNT" "$STATUS" "$POWER" "$TEMP" "$UTIL"

    sleep "$INTERVAL"
done
