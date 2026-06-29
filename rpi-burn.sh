#!/usr/bin/env bash
#
# rpi-burn.sh — Flash a clone image to the NVMe drive
#
# Run on a backup RPi 5 booted from SD card with a blank NVMe inserted.
# The image can be on a NAS (SMB/CIFS share) or a local file.
# The root filesystem auto-expands to fill the NVMe on first boot.
#
# Usage:
#   sudo ./rpi-burn.sh                          # interactive — prompts for NAS share
#   sudo ./rpi-burn.sh //nas/share/path         # mount this share, pick an image
#   sudo ./rpi-burn.sh /local/path/to/image.img # use a local file directly
#
# Default NVMe target: /dev/nvme0n1

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo $0)" >&2; exit 1; }

NVME="/dev/nvme0n1"
MNT="/mnt/nas-burn"
CREDS_FILE="/tmp/.rpi-burn-creds-$$"
MOUNTED_HERE=false

cleanup() {
    if $MOUNTED_HERE; then
        echo ">>> Unmounting NAS share..."
        umount "$MNT" 2>/dev/null || true
        rmdir "$MNT" 2>/dev/null || true
    fi
    rm -f "$CREDS_FILE"
}
trap cleanup EXIT

# ── Validate NVMe target ────────────────────────────────────────────────────

[[ -b "$NVME" ]] || { echo "ERROR: NVMe device not found: $NVME" >&2; exit 1; }

NVME_MOUNTED=$(mount | grep "^${NVME}" || true)
if [[ -n "$NVME_MOUNTED" ]]; then
    echo "ERROR: $NVME has mounted partitions — unmount them first:" >&2
    echo "$NVME_MOUNTED" >&2
    exit 1
fi

BOOT_DISK=$(lsblk -ndo PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null || true)
if [[ "/dev/$BOOT_DISK" == "$NVME" ]]; then
    echo "ERROR: $NVME is the current boot disk — refusing to overwrite." >&2
    exit 1
fi

NVME_SIZE=$(lsblk -ndo SIZE "$NVME" 2>/dev/null || echo "unknown")
NVME_MODEL=$(lsblk -ndo MODEL "$NVME" 2>/dev/null || echo "unknown")

echo "=== RPi 5 NVMe Burn ==="
echo "Target: $NVME ($NVME_SIZE, $NVME_MODEL)"
echo ""

# ── Resolve the image file ──────────────────────────────────────────────────

IMG=""
INPUT="${1:-}"

if [[ -z "$INPUT" ]]; then
    # Interactive: ask for NAS share
    read -rp "NAS share path (e.g. //192.168.1.10/backups): " INPUT
    echo ""
fi

if [[ -f "$INPUT" ]]; then
    # Local file
    IMG="$INPUT"

elif [[ "$INPUT" == //* ]]; then
    # SMB/CIFS share — mount and browse
    SHARE="$INPUT"

    if ! dpkg -s cifs-utils &>/dev/null; then
        echo ">>> Installing cifs-utils..."
        apt-get update -qq && apt-get install -y -qq cifs-utils
    fi

    read -rp "NAS username (or press Enter for guest): " NAS_USER
    if [[ -n "$NAS_USER" ]]; then
        read -rsp "NAS password: " NAS_PASS
        echo ""
        printf 'username=%s\npassword=%s\n' "$NAS_USER" "$NAS_PASS" > "$CREDS_FILE"
        chmod 600 "$CREDS_FILE"
        MOUNT_OPTS="ro,credentials=$CREDS_FILE"
    else
        MOUNT_OPTS="ro,guest"
    fi

    mkdir -p "$MNT"
    echo ">>> Mounting $SHARE..."
    mount -t cifs "$SHARE" "$MNT" -o "$MOUNT_OPTS" || {
        echo "ERROR: failed to mount $SHARE" >&2
        exit 1
    }
    MOUNTED_HERE=true
    echo ""

    # List available .img files
    mapfile -t IMAGES < <(find "$MNT" -maxdepth 2 -name "*.img" -type f 2>/dev/null | sort)

    if [[ ${#IMAGES[@]} -eq 0 ]]; then
        echo "ERROR: no .img files found in $SHARE" >&2
        exit 1
    fi

    echo "Available images:"
    for i in "${!IMAGES[@]}"; do
        SIZE=$(du -h "${IMAGES[$i]}" 2>/dev/null | cut -f1)
        NAME=$(basename "${IMAGES[$i]}")
        printf "  %d) %s (%s)\n" $((i + 1)) "$NAME" "$SIZE"
    done
    echo ""

    if [[ ${#IMAGES[@]} -eq 1 ]]; then
        IMG="${IMAGES[0]}"
        echo ">>> Using: $(basename "$IMG")"
    else
        read -rp "Select image [1-${#IMAGES[@]}]: " PICK
        IDX=$((PICK - 1))
        if [[ $IDX -lt 0 || $IDX -ge ${#IMAGES[@]} ]]; then
            echo "ERROR: invalid selection" >&2
            exit 1
        fi
        IMG="${IMAGES[$IDX]}"
    fi
else
    echo "ERROR: '$INPUT' is not a file or SMB share path (//server/share)" >&2
    exit 1
fi

# ── Confirm and flash ────────────────────────────────────────────────────────

IMG_SIZE=$(du -h "$IMG" | cut -f1)
IMG_NAME=$(basename "$IMG")

echo ""
echo "Image:  $IMG_NAME ($IMG_SIZE)"
echo "Target: $NVME ($NVME_SIZE, $NVME_MODEL)"
echo ""
echo "WARNING: This will ERASE all data on $NVME!"
echo ""
read -rp "Type YES to continue: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || { echo "Aborted."; exit 1; }

echo ""
echo ">>> Flashing image to $NVME..."
dd if="$IMG" of="$NVME" bs=4M status=progress conv=fsync

echo ""
echo ">>> Syncing..."
sync

echo ""
echo "=== Burn complete ==="
echo ""
echo "The root filesystem will auto-expand on first boot."
echo ""
echo "Next steps:"
echo "  1. Power off:       sudo poweroff"
echo "  2. Remove the SD card"
echo "  3. Power on — it boots from NVMe"
echo "  4. Verify:          df -h"
