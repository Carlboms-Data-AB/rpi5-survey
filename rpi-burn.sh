#!/usr/bin/env bash
#
# rpi-burn.sh — Flash a clone image to an NVMe drive
#
# Run on a backup RPi 5 booted from SD card with a blank NVMe inserted.
# The root filesystem auto-expands to fill the NVMe on first boot.
#
# Usage:
#   sudo ./rpi-burn.sh <image_file> [nvme_device]
#
# Default NVMe device: /dev/nvme0n1

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo $0)" >&2; exit 1; }

IMG="${1:?Usage: sudo $0 <image_file> [/dev/nvme0n1]}"
NVME="${2:-/dev/nvme0n1}"

# ── Validate inputs ──────────────────────────────────────────────────────────

[[ -f "$IMG" ]] || { echo "ERROR: image file not found: $IMG" >&2; exit 1; }
[[ -b "$NVME" ]] || { echo "ERROR: NVMe device not found: $NVME" >&2; exit 1; }

# Check no partitions on the NVMe are mounted
MOUNTED=$(mount | grep "^${NVME}" || true)
if [[ -n "$MOUNTED" ]]; then
    echo "ERROR: $NVME has mounted partitions — unmount them first:" >&2
    echo "$MOUNTED" >&2
    exit 1
fi

# Make sure we're not about to write to the boot disk
BOOT_DISK=$(lsblk -ndo PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null || true)
if [[ "/dev/$BOOT_DISK" == "$NVME" ]]; then
    echo "ERROR: $NVME is the current boot disk — refusing to overwrite it." >&2
    exit 1
fi

# ── Show what we're about to do ──────────────────────────────────────────────

IMG_SIZE=$(du -h "$IMG" | cut -f1)
NVME_SIZE=$(lsblk -ndo SIZE "$NVME" 2>/dev/null || echo "unknown")
NVME_MODEL=$(lsblk -ndo MODEL "$NVME" 2>/dev/null || echo "unknown")

echo "=== RPi 5 NVMe Burn ==="
echo ""
echo "Image:      $IMG ($IMG_SIZE)"
echo "Target:     $NVME ($NVME_SIZE, $NVME_MODEL)"
echo ""
echo "WARNING: This will ERASE all data on $NVME!"
echo ""
read -rp "Type YES to continue: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || { echo "Aborted."; exit 1; }

# ── Flash the image ──────────────────────────────────────────────────────────

echo ""
echo ">>> Flashing image to $NVME..."
dd if="$IMG" of="$NVME" bs=4M status=progress conv=fsync

echo ""
echo ">>> Syncing..."
sync

echo ""
echo "=== Burn complete ==="
echo ""
echo "The root filesystem will auto-expand to fill the NVMe on first boot."
echo ""
echo "Next steps:"
echo "  1. Power off:       sudo poweroff"
echo "  2. Remove the SD card"
echo "  3. Power on — it will boot from NVMe"
echo "  4. Verify with:     df -h   (root partition should fill the drive)"
