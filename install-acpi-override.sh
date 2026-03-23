#!/bin/bash
# install-acpi-override.sh — Install SSDT25 ACPI override for GPS thermal fix
# HP Omen Transcend 14 (8C58) + RTX 4060
#
# This patches the GPSP buffer in the GPS _DSM handler to pre-initialize
# TGPU=87°C (0x57) and set TGPU=GPSV in ALL subcases, not just subcase 2.
# Without this, the zero-initialized buffer causes the NVIDIA driver to
# use a ~58°C thermal limit, capping GPU power at ~33W instead of 65W.
#
# Uses mkinitcpio to embed the ACPI table override in the initramfs.
# Requires reboot to take effect.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OVERRIDE_SRC="${SCRIPT_DIR}/ssdt25-fix.aml"
OVERRIDE_DST="/lib/firmware/acpi/ssdt25.aml"
MKINITCPIO_HOOK="/etc/mkinitcpio.conf.d/acpi-override.conf"

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Must run as root${NC}"
    exit 1
fi

if [[ ! -f "$OVERRIDE_SRC" ]]; then
    echo -e "${RED}Missing: ${OVERRIDE_SRC}${NC}"
    exit 1
fi

echo -e "${BOLD}Installing SSDT25 ACPI override for GPS thermal fix${NC}"
echo ""

# 1. Install the AML to /lib/firmware/acpi/
echo -e "${GREEN}[1/3]${NC} Installing AML to ${OVERRIDE_DST}"
mkdir -p /lib/firmware/acpi
cp "$OVERRIDE_SRC" "$OVERRIDE_DST"
chmod 644 "$OVERRIDE_DST"

# 2. Add early ACPI CPIO to mkinitcpio
# Method: use FILES= to include it, but mkinitcpio can't do early ACPI this way.
# Instead, we need to create the early CPIO and prepend it to initramfs.
# The cleanest way on CachyOS is a mkinitcpio post hook.

echo -e "${GREEN}[2/3]${NC} Creating mkinitcpio post-generation hook"

# Create a post-generation hook that prepends the ACPI CPIO
mkdir -p /etc/initcpio/post
cat > /etc/initcpio/post/acpi-override << 'HOOKEOF'
#!/bin/bash
# Prepend ACPI table override CPIO to initramfs
# This runs after mkinitcpio generates the initramfs

ACPI_DIR="/lib/firmware/acpi"
if [[ -d "$ACPI_DIR" ]] && ls "$ACPI_DIR"/*.aml >/dev/null 2>&1; then
    TMPDIR=$(mktemp -d)
    mkdir -p "$TMPDIR/kernel/firmware/acpi"
    cp "$ACPI_DIR"/*.aml "$TMPDIR/kernel/firmware/acpi/"

    EARLY_CPIO=$(mktemp)
    cd "$TMPDIR"
    find . -type f | bsdcpio -o -H newc > "$EARLY_CPIO" 2>/dev/null

    # Prepend to the generated initramfs ($1 is the image path)
    if [[ -n "${1:-}" && -f "${1:-}" ]]; then
        COMBINED=$(mktemp)
        cat "$EARLY_CPIO" "$1" > "$COMBINED"
        mv "$COMBINED" "$1"
        echo ":: ACPI override prepended to $1"
    fi

    rm -rf "$TMPDIR" "$EARLY_CPIO"
fi
HOOKEOF
chmod +x /etc/initcpio/post/acpi-override

# 3. Regenerate initramfs
echo -e "${GREEN}[3/3]${NC} Regenerating initramfs with ACPI override"
mkinitcpio -P

echo ""
echo -e "${GREEN}${BOLD}Done!${NC} SSDT25 ACPI override installed."
echo -e "Changes:"
echo -e "  - GPSP buffer pre-initialized with TGPU=87°C (0x57)"
echo -e "  - TGPU=GPSV set in ALL GPS _DSM subcases"
echo -e ""
echo -e "${YELLOW}Reboot required to take effect.${NC}"
echo -e "After reboot, verify with: nvidia-smi -q | grep 'T.Limit'"
echo -e "Expected: GPU Slowdown T.Limit > 20°C (not -2°C)"
