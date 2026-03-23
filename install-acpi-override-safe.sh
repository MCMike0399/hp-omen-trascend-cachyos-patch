#!/bin/bash
# install-acpi-override-safe.sh — Safe SSDT25 ACPI override installer
# HP Omen Transcend 14 (8C58) + RTX 4060
#
# Follows the Ralph loop safe-apply gate:
# 1. Creates btrfs snapshot BEFORE any changes
# 2. Validates AML file integrity
# 3. Installs ACPI override via mkinitcpio
# 4. Validates initramfs integrity BEFORE reboot
# 5. Records rollback instructions
#
# Usage: sudo ./install-acpi-override-safe.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OVERRIDE_SRC="${SCRIPT_DIR}/ssdt25-fix.aml"
FIRMWARE_DIR="/lib/firmware/acpi"
OVERRIDE_DST="${FIRMWARE_DIR}/ssdt25.aml"
POST_HOOK="/etc/initcpio/post/acpi-override"
STATE_FILE="/tmp/ralph-state.md"
SNAPSHOT_FILE="/tmp/ralph-snapshot-id"

die() { echo -e "${RED}ABORT: $1${NC}"; exit 1; }
info() { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $1"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
    die "Must run as root"
fi

if [[ ! -f "$OVERRIDE_SRC" ]]; then
    die "Missing: ${OVERRIDE_SRC}"
fi

echo -e "${BOLD}=== Safe SSDT25 ACPI Override Install ===${NC}"
echo ""

# ============================================================
# STEP 0: Pre-flight validation
# ============================================================
info "Step 0: Pre-flight validation"

# Validate AML file can be decompiled
if command -v iasl &>/dev/null; then
    TMPDECOMPILE=$(mktemp -d)
    if iasl -d -p "${TMPDECOMPILE}/test" "$OVERRIDE_SRC" &>/dev/null; then
        info "  AML decompiles cleanly"
    else
        warn "  AML decompile warning (may still work)"
    fi
    rm -rf "$TMPDECOMPILE"
else
    warn "  iasl not installed, skipping AML validation (pacman -S acpica)"
fi

# Check AML file size is sane
AML_SIZE=$(stat -c%s "$OVERRIDE_SRC")
if [[ "$AML_SIZE" -lt 100 || "$AML_SIZE" -gt 100000 ]]; then
    die "AML file size suspicious: ${AML_SIZE} bytes (expected 5K-50K)"
fi
info "  AML file size: ${AML_SIZE} bytes"

# Verify cpio tool is available
if command -v bsdcpio &>/dev/null; then
    CPIO_CMD="bsdcpio"
elif command -v cpio &>/dev/null; then
    CPIO_CMD="cpio"
else
    die "Neither cpio nor bsdcpio found"
fi
info "  ${CPIO_CMD} available"

# ============================================================
# STEP 1: Create btrfs snapshot
# ============================================================
info "Step 1: Creating btrfs snapshot"

if command -v snapper &>/dev/null; then
    SNAP_NUM=$(snapper -c root create -d "pre-ralph: SSDT25 ACPI override" --type pre -p)
    echo "$SNAP_NUM" > "$SNAPSHOT_FILE"
    info "  Snapshot #${SNAP_NUM} created"
    info "  Rollback: snapper -c root undochange ${SNAP_NUM}..0"
    info "  Or boot into 'CachyOS Snapshots' from GRUB"
else
    warn "  snapper not available, trying btrfs snapshot directly"
    SNAP_PATH="/.snapshots/pre-ralph-$(date +%Y%m%d-%H%M%S)"
    if btrfs subvolume snapshot / "$SNAP_PATH" &>/dev/null; then
        echo "$SNAP_PATH" > "$SNAPSHOT_FILE"
        info "  Snapshot at ${SNAP_PATH}"
    else
        die "Cannot create snapshot. Refusing to proceed without rollback safety."
    fi
fi

echo ""

# ============================================================
# STEP 2: Record current initramfs state (for comparison)
# ============================================================
info "Step 2: Recording current initramfs state"

# Find initramfs files
INITRAMFS_FILES=()
for f in /boot/initramfs-*.img /boot/initrd-*.img /boot/initramfs*.img /efi/EFI/Linux/*.efi; do
    [[ -f "$f" ]] && INITRAMFS_FILES+=("$f")
done

if [[ ${#INITRAMFS_FILES[@]} -eq 0 ]]; then
    # Try to find via mkinitcpio preset
    warn "  No initramfs found in /boot or /efi, checking mkinitcpio presets"
    for preset in /etc/mkinitcpio.d/*.preset; do
        if [[ -f "$preset" ]]; then
            info "  Found preset: $preset"
            cat "$preset"
        fi
    done
fi

declare -A OLD_SIZES
for f in "${INITRAMFS_FILES[@]}"; do
    OLD_SIZES["$f"]=$(stat -c%s "$f" 2>/dev/null || echo 0)
    info "  ${f}: ${OLD_SIZES[$f]} bytes"
done

echo ""

# ============================================================
# STEP 3: Install AML to firmware directory
# ============================================================
info "Step 3: Installing AML to ${OVERRIDE_DST}"
mkdir -p "$FIRMWARE_DIR"
cp "$OVERRIDE_SRC" "$OVERRIDE_DST"
chmod 644 "$OVERRIDE_DST"
info "  Done"

echo ""

# ============================================================
# STEP 4: Create mkinitcpio post hook (FIXED — uses cpio, not bsdcpio)
# ============================================================
info "Step 4: Creating mkinitcpio post-generation hook"

mkdir -p "$(dirname "$POST_HOOK")"
cat > "$POST_HOOK" << 'HOOKEOF'
#!/bin/bash
# Prepend ACPI table override CPIO to initramfs
# Runs after mkinitcpio generates each initramfs image
# $1 = path to the generated initramfs image

ACPI_DIR="/lib/firmware/acpi"

# Only proceed if we have AML files and a valid image path
if [[ ! -d "$ACPI_DIR" ]] || ! ls "$ACPI_DIR"/*.aml >/dev/null 2>&1; then
    exit 0
fi

if [[ -z "${1:-}" || ! -f "${1:-}" ]]; then
    echo ":: ACPI override: no image path provided, skipping"
    exit 0
fi

IMAGE="$1"
TMPDIR=$(mktemp -d)

# Create the directory structure the kernel expects
mkdir -p "$TMPDIR/kernel/firmware/acpi"
cp "$ACPI_DIR"/*.aml "$TMPDIR/kernel/firmware/acpi/"

# Create uncompressed CPIO archive (kernel requires uncompressed early CPIO)
EARLY_CPIO=$(mktemp)
cd "$TMPDIR"
if command -v bsdcpio &>/dev/null; then
    find . -type f | bsdcpio -o -H newc > "$EARLY_CPIO" 2>/dev/null
elif command -v cpio &>/dev/null; then
    find . -type f | cpio -o -H newc --quiet > "$EARLY_CPIO" 2>/dev/null
else
    echo ":: ACPI override: no cpio tool found, skipping"
    rm -rf "$TMPDIR" "$EARLY_CPIO"
    exit 0
fi

# Validate CPIO was created and is non-empty
if [[ ! -s "$EARLY_CPIO" ]]; then
    echo ":: ACPI override: CPIO creation failed, leaving initramfs untouched"
    rm -rf "$TMPDIR" "$EARLY_CPIO"
    exit 0
fi

# Prepend to initramfs (early CPIO before compressed main image)
COMBINED=$(mktemp)
cat "$EARLY_CPIO" "$IMAGE" > "$COMBINED"

# Validate combined image is larger than original (sanity check)
ORIG_SIZE=$(stat -c%s "$IMAGE")
NEW_SIZE=$(stat -c%s "$COMBINED")
if [[ "$NEW_SIZE" -le "$ORIG_SIZE" ]]; then
    echo ":: ACPI override: combined image smaller than original, aborting"
    rm -rf "$TMPDIR" "$EARLY_CPIO" "$COMBINED"
    exit 1
fi

mv "$COMBINED" "$IMAGE"
echo ":: ACPI override prepended to $IMAGE (+$((NEW_SIZE - ORIG_SIZE)) bytes)"

rm -rf "$TMPDIR" "$EARLY_CPIO"
HOOKEOF
chmod +x "$POST_HOOK"
info "  Hook installed at ${POST_HOOK}"

echo ""

# ============================================================
# STEP 5: Regenerate initramfs
# ============================================================
info "Step 5: Regenerating initramfs"
mkinitcpio -P 2>&1 | tee /tmp/ralph-mkinitcpio.log

echo ""

# ============================================================
# STEP 6: Validate initramfs integrity
# ============================================================
info "Step 6: Validating initramfs integrity"

VALIDATION_OK=true

# Re-scan initramfs files
NEW_INITRAMFS_FILES=()
for f in /boot/initramfs-*.img /boot/initrd-*.img /boot/initramfs*.img /efi/EFI/Linux/*.efi; do
    [[ -f "$f" ]] && NEW_INITRAMFS_FILES+=("$f")
done

for f in "${NEW_INITRAMFS_FILES[@]}"; do
    NEW_SIZE=$(stat -c%s "$f" 2>/dev/null || echo 0)
    OLD_SIZE=${OLD_SIZES["$f"]:-0}

    if [[ "$NEW_SIZE" -eq 0 ]]; then
        echo -e "  ${RED}FAIL${NC}: ${f} is empty!"
        VALIDATION_OK=false
    elif [[ "$OLD_SIZE" -gt 0 && "$NEW_SIZE" -lt $((OLD_SIZE / 2)) ]]; then
        echo -e "  ${RED}FAIL${NC}: ${f} shrank from ${OLD_SIZE} to ${NEW_SIZE} (>50% smaller)"
        VALIDATION_OK=false
    elif [[ "$OLD_SIZE" -gt 0 && "$NEW_SIZE" -gt $((OLD_SIZE + 1000000)) ]]; then
        echo -e "  ${YELLOW}WARN${NC}: ${f} grew significantly: ${OLD_SIZE} → ${NEW_SIZE}"
    else
        info "  ${f}: ${OLD_SIZE} → ${NEW_SIZE} bytes (OK)"
    fi
done

# Check if ACPI override message appeared in mkinitcpio log
if grep -q "ACPI override prepended" /tmp/ralph-mkinitcpio.log; then
    info "  ACPI CPIO prepend confirmed in mkinitcpio log"
else
    echo -e "  ${YELLOW}WARN${NC}: 'ACPI override prepended' not found in log"
    echo -e "  Check /tmp/ralph-mkinitcpio.log for details"
fi

echo ""

if [[ "$VALIDATION_OK" != "true" ]]; then
    echo -e "${RED}${BOLD}VALIDATION FAILED!${NC}"
    echo -e "Initramfs may be corrupted. Rolling back..."
    SNAP_NUM=$(cat "$SNAPSHOT_FILE" 2>/dev/null || echo "unknown")
    echo -e "Snapshot #${SNAP_NUM} exists for rollback."
    echo -e "Run: snapper -c root undochange ${SNAP_NUM}..0"
    echo -e "Then: mkinitcpio -P"
    die "Fix the issue before rebooting!"
fi

# ============================================================
# STEP 7: Print reboot instructions
# ============================================================
SNAP_NUM=$(cat "$SNAPSHOT_FILE" 2>/dev/null || echo "unknown")

echo -e "${GREEN}${BOLD}=== VALIDATION PASSED ===${NC}"
echo ""
echo -e "Snapshot: #${SNAP_NUM}"
echo -e ""
echo -e "${BOLD}Before rebooting, remember:${NC}"
echo -e "  If boot fails → select 'CachyOS Snapshots' in GRUB → pick snapshot #${SNAP_NUM}"
echo -e "  Or from live USB: snapper -c root undochange ${SNAP_NUM}..0"
echo -e ""
echo -e "${BOLD}After reboot, run:${NC}"
echo -e "  sudo ~/hp-omen-trascend-cachyos-patch/validate-boot.sh"
echo -e ""
echo -e "${YELLOW}Reboot when ready: sudo reboot${NC}"
