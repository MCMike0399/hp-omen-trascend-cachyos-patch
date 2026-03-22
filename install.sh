#!/bin/bash
# install.sh - Install patched hp-wmi DKMS module + gpu-performance systemd service
# For HP Omen Transcend 14 (board 8C58) with RTX 4060 Max-Q
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

DKMS_NAME="hp-wmi-omen8c58"
DKMS_VERSION="1.0"
DKMS_SRC="/usr/src/${DKMS_NAME}-${DKMS_VERSION}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Must run as root: sudo $0${NC}"
    exit 1
fi

echo -e "${BOLD}=== HP Omen Transcend 14 GPU Power Fix Installer ===${NC}"
echo ""

# Verify board
BOARD=$(cat /sys/class/dmi/id/board_name 2>/dev/null || echo "unknown")
if [[ "$BOARD" != "8C58" ]]; then
    echo -e "${YELLOW}Warning: Board is '${BOARD}', expected '8C58'. Continuing anyway...${NC}"
fi

# Step 1: Install DKMS module
echo -e "${BOLD}[1/5] Setting up DKMS module...${NC}"

# Remove old version if it exists
if dkms status "${DKMS_NAME}/${DKMS_VERSION}" 2>/dev/null | grep -q .; then
    echo "  Removing existing DKMS registration..."
    dkms remove "${DKMS_NAME}/${DKMS_VERSION}" --all 2>/dev/null || true
fi

# Copy source to DKMS tree
rm -rf "$DKMS_SRC"
mkdir -p "$DKMS_SRC"
cp "${SCRIPT_DIR}/hp-wmi.c" "$DKMS_SRC/"
cp "${SCRIPT_DIR}/Makefile" "$DKMS_SRC/"
cp "${SCRIPT_DIR}/dkms.conf" "$DKMS_SRC/"

echo -e "  ${GREEN}Source installed to ${DKMS_SRC}${NC}"

# Register with DKMS
dkms add "${DKMS_NAME}/${DKMS_VERSION}"
echo -e "  ${GREEN}DKMS module registered${NC}"

# Step 2: Build for current kernel
echo -e "${BOLD}[2/5] Building module for $(uname -r)...${NC}"
dkms build "${DKMS_NAME}/${DKMS_VERSION}" -k "$(uname -r)"
echo -e "  ${GREEN}Build successful${NC}"

# Step 3: Install for current kernel
echo -e "${BOLD}[3/5] Installing module...${NC}"
dkms install "${DKMS_NAME}/${DKMS_VERSION}" -k "$(uname -r)" --force
echo -e "  ${GREEN}Module installed (will auto-rebuild on kernel updates via DKMS)${NC}"

# Step 4: Load the module
echo -e "${BOLD}[4/5] Loading patched module...${NC}"
if lsmod | grep -q hp_wmi; then
    rmmod hp_wmi 2>/dev/null || echo -e "  ${YELLOW}Could not unload hp_wmi (may be in use, reboot recommended)${NC}"
fi
modprobe hp_wmi 2>/dev/null || echo -e "  ${YELLOW}Could not load hp_wmi (reboot may be needed)${NC}"

if [[ -f /sys/firmware/acpi/platform_profile ]]; then
    PROFILE=$(cat /sys/firmware/acpi/platform_profile)
    CHOICES=$(cat /sys/firmware/acpi/platform_profile_choices 2>/dev/null || echo "?")
    echo -e "  ${GREEN}platform_profile available! Current: ${BOLD}${PROFILE}${NC} ${GREEN}(choices: ${CHOICES})${NC}"
else
    echo -e "  ${YELLOW}platform_profile not available yet - reboot needed${NC}"
fi

# Step 5: Install systemd service
echo -e "${BOLD}[5/5] Installing systemd service...${NC}"
SERVICE_FILE="/etc/systemd/system/gpu-performance.service"

cat > "$SERVICE_FILE" << 'UNIT'
[Unit]
Description=Set GPU performance profile (65W TGP) for HP Omen Transcend 14
After=nvidia-powerd.service
Wants=nvidia-powerd.service
ConditionPathExists=/sys/firmware/acpi/platform_profile

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo performance > /sys/firmware/acpi/platform_profile && systemctl restart nvidia-powerd'
RemainAfterExit=yes
ExecStop=/bin/bash -c 'echo balanced > /sys/firmware/acpi/platform_profile && systemctl restart nvidia-powerd'

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable gpu-performance.service
echo -e "  ${GREEN}Service installed and enabled${NC}"

# Start it now if platform_profile is available
if [[ -f /sys/firmware/acpi/platform_profile ]]; then
    systemctl start gpu-performance.service 2>/dev/null || true
    echo -e "  ${GREEN}Service started - profile set to performance${NC}"
fi

echo ""
echo -e "${BOLD}=== Installation Complete ===${NC}"
echo ""
echo -e "What was installed:"
echo -e "  ${GREEN}1.${NC} DKMS module at ${DKMS_SRC} (auto-rebuilds on kernel updates)"
echo -e "  ${GREEN}2.${NC} Systemd service: gpu-performance.service (auto-starts at boot)"
echo -e "  ${GREEN}3.${NC} Script at ~/.local/bin/gpu-performance (manual control)"
echo ""
echo -e "Commands:"
echo -e "  ${BOLD}gpu-performance status${NC}    - Check GPU power state"
echo -e "  ${BOLD}sudo gpu-performance on${NC}   - Set performance mode manually"
echo -e "  ${BOLD}sudo gpu-performance off${NC}  - Set balanced mode"
echo ""
echo -e "Steam launch option:"
echo -e "  ${BOLD}__GL_SHADER_DISK_CACHE_SKIP_CLEANUP=1 prime-run game-performance %command%${NC}"
echo ""
echo -e "${YELLOW}If platform_profile isn't available yet, reboot to load the new module.${NC}"
