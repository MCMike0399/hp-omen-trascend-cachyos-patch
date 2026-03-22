#!/bin/bash
# uninstall.sh - Remove patched hp-wmi DKMS module + gpu-performance service
set -euo pipefail

DKMS_NAME="hp-wmi-omen8c58"
DKMS_VERSION="1.0"

if [[ $EUID -ne 0 ]]; then
    echo "Must run as root: sudo $0"
    exit 1
fi

echo "=== Removing hp-wmi-omen8c58 ==="

# Remove systemd service
if systemctl is-active --quiet gpu-performance.service 2>/dev/null; then
    systemctl stop gpu-performance.service
fi
systemctl disable gpu-performance.service 2>/dev/null || true
rm -f /etc/systemd/system/gpu-performance.service
systemctl daemon-reload
echo "Systemd service removed"

# Remove DKMS module
if dkms status "${DKMS_NAME}/${DKMS_VERSION}" 2>/dev/null | grep -q .; then
    dkms remove "${DKMS_NAME}/${DKMS_VERSION}" --all
    echo "DKMS module removed"
fi
rm -rf "/usr/src/${DKMS_NAME}-${DKMS_VERSION}"

# Reinstall stock module
depmod -a
echo "Stock hp-wmi will be used after reboot"
echo ""
echo "Done. Reboot to restore stock hp-wmi module."
