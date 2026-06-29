#!/usr/bin/env bash
#
# rpi-clone.sh — Create a bootable, content-sized NVMe clone image (RPi 5, CasaOS)
#
# Builds a raw .img from scratch using a loopback device + rsync. The image is
# sized to the ACTUAL included data (root used minus excluded bulk dirs), NOT to
# the full disk. Saved locally on the NVMe. Flash it to a blank NVMe to build an
# identical cold-spare; the root filesystem auto-expands on first boot.
#
# Excludes bulk InfluxDB time-series data and the MinIO CAN bucket; keeps all
# config, identity, OS, Docker layers, and dashboards.
#
# Usage:
#   sudo ./rpi-clone.sh [output_directory]      # default: /DATA
#
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo $0)" >&2; exit 1; }

# ── Configuration ────────────────────────────────────────────────────────────

HOSTNAME="$(hostname)"
DATE="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${1:-/DATA}"
IMG="${OUT_DIR}/rpi-clone-${HOSTNAME}-${DATE}.img"

STOP_CONTAINERS=(node-red influxdb minio)

# Bulk dirs to exclude (absolute paths, anchored to / in rsync)
EXCLUDES=(
    /DATA/AppData/influxdb/data/engine
    "/DATA/AppData/influxdb/data/backup_*"
    /DATA/AppData/big-bear-minio/can-edge2
    /var/swap
)

MNT="/mnt/rpi-clone-root"

human() {
    awk -v b="$1" 'BEGIN{split("B KiB MiB GiB TiB",u," ");i=1;
        while(b>=1024&&i<5){b/=1024;i++}printf "%.1f %s",b,u[i]}'
}

# ── Detect source geometry ───────────────────────────────────────────────────

ROOT_PART_DEV="$(findmnt -no SOURCE /)"            # e.g. /dev/nvme0n1p2
SRC_DISK="/dev/$(lsblk -no PKNAME "$ROOT_PART_DEV" | head -1)"  # /dev/nvme0n1
DISK_ID="$(sfdisk --disk-id "$SRC_DISK")"          # e.g. 0x59795b20

P1_LINE="$(sfdisk -d "$SRC_DISK" | grep "${SRC_DISK}p1")"
P2_LINE="$(sfdisk -d "$SRC_DISK" | grep "${SRC_DISK}p2")"
P1_START="$(grep -o 'start=[ ]*[0-9]*' <<<"$P1_LINE" | grep -o '[0-9]*')"
P1_SIZE="$(grep -o 'size=[ ]*[0-9]*'  <<<"$P1_LINE" | grep -o '[0-9]*')"
P2_START="$(grep -o 'start=[ ]*[0-9]*' <<<"$P2_LINE" | grep -o '[0-9]*')"

echo "=== RPi 5 NVMe Clone ==="
echo "Host:        $HOSTNAME"
echo "Source disk: $SRC_DISK (disk-id $DISK_ID, MBR)"
echo "Output:      $IMG"
echo ""

# ── Calculate image size from ACTUAL included data ───────────────────────────

ROOT_USED="$(df -B1 --output=used / | tail -1 | tr -d ' ')"
EXC_TOTAL=0
echo ">>> Excluded bulk data:"
for pat in "${EXCLUDES[@]}"; do
    for d in $pat; do          # expand glob (backup_*)
        if [ -e "$d" ]; then
            s="$(du -sB1 --one-file-system "$d" 2>/dev/null | cut -f1)"
            s="${s:-0}"
            EXC_TOTAL=$((EXC_TOTAL + s))
            printf '    %-50s %s\n' "$d" "$(human "$s")"
        fi
    done
done

INCLUDED=$((ROOT_USED - EXC_TOTAL))
# root partition = included + 15% + 1 GiB headroom, aligned up to 1 MiB.
# Pure bash 64-bit arithmetic — do NOT use awk printf %d here (mawk on
# Debian truncates to 32-bit and overflows above ~2 GiB).
ROOT_PART_BYTES=$(( INCLUDED * 115 / 100 + 1073741824 ))
ROOT_SECTORS=$(( (ROOT_PART_BYTES + 511) / 512 ))
ROOT_SECTORS=$(( (ROOT_SECTORS + 2047) / 2048 * 2048 ))   # align to 1 MiB
ROOT_PART_BYTES=$((ROOT_SECTORS * 512))
TOTAL_SECTORS=$((P2_START + ROOT_SECTORS))
IMG_BYTES=$((TOTAL_SECTORS * 512))

echo ""
echo "    root used:      $(human "$ROOT_USED")"
echo "    excluded total: $(human "$EXC_TOTAL")"
echo "    included:       $(human "$INCLUDED")"
echo "    image size:     $(human "$IMG_BYTES")  (boot $(human $((P1_SIZE*512))) + root $(human "$ROOT_PART_BYTES"))"
echo ""

# Free-space check on output filesystem
OUT_AVAIL="$(df -B1 --output=avail "$OUT_DIR" | tail -1 | tr -d ' ')"
NEED=$((INCLUDED + 2 * 1024 * 1024 * 1024))   # included + 2 GiB slack
if (( OUT_AVAIL < NEED )); then
    echo "ERROR: not enough free space in $OUT_DIR" >&2
    echo "  available: $(human "$OUT_AVAIL"), need ~$(human "$NEED")" >&2
    exit 1
fi

# ── Cleanup trap ─────────────────────────────────────────────────────────────

LOOP=""
CONTAINERS_STOPPED=()

cleanup() {
    set +e
    sync
    mountpoint -q "$MNT/boot/firmware" && umount "$MNT/boot/firmware"
    mountpoint -q "$MNT"               && umount "$MNT"
    [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null
    rmdir "$MNT" 2>/dev/null
    if [ ${#CONTAINERS_STOPPED[@]} -gt 0 ]; then
        echo ""
        echo ">>> Restarting stopped containers..."
        for c in "${CONTAINERS_STOPPED[@]}"; do
            docker start "$c" >/dev/null && echo "    Started: $c"
        done
    fi
}
trap cleanup EXIT

# ── Stop write-heavy containers for a consistent snapshot ────────────────────

echo ">>> Stopping write-heavy containers..."
for c in "${STOP_CONTAINERS[@]}"; do
    if docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null | grep -q true; then
        docker stop "$c" >/dev/null
        CONTAINERS_STOPPED+=("$c")
        echo "    Stopped: $c"
    else
        echo "    Skipped: $c (not running)"
    fi
done
sync

# ── Create and partition the image ───────────────────────────────────────────

echo ""
echo ">>> Creating image file ($(human "$IMG_BYTES"))..."
rm -f "$IMG"
truncate -s "$IMG_BYTES" "$IMG"

echo ">>> Writing partition table (matching disk-id $DISK_ID)..."
sfdisk "$IMG" >/dev/null <<SFDISK
label: dos
label-id: $DISK_ID
unit: sectors

start=$P1_START, size=$P1_SIZE, type=c, bootable
start=$P2_START, size=$ROOT_SECTORS, type=83
SFDISK

LOOP="$(losetup --find --show --partscan "$IMG")"
partprobe "$LOOP" 2>/dev/null || partx -a "$LOOP" 2>/dev/null || true
udevadm settle 2>/dev/null || sleep 1

echo ">>> Formatting partitions..."
mkfs.vfat -F 32 -n bootfs "${LOOP}p1" >/dev/null
mkfs.ext4 -F -q -L rootfs "${LOOP}p2"

# ── Mount and copy ───────────────────────────────────────────────────────────

mkdir -p "$MNT"
mount "${LOOP}p2" "$MNT"
mkdir -p "$MNT/boot/firmware"
mount "${LOOP}p1" "$MNT/boot/firmware"

# Build rsync exclude args (anchored to /)
RSYNC_EXCLUDES=(
    --exclude="$IMG"
    --exclude="$MNT"
)
for pat in "${EXCLUDES[@]}"; do
    RSYNC_EXCLUDES+=(--exclude="$pat")
done

echo ""
echo ">>> Copying root filesystem (this is the long part)..."
rsync -aHAXx --numeric-ids --info=progress2 \
    "${RSYNC_EXCLUDES[@]}" \
    / "$MNT/"

echo ""
echo ">>> Copying boot partition..."
rsync -aHAXx --numeric-ids /boot/firmware/ "$MNT/boot/firmware/"

# ── Install first-boot resize service ────────────────────────────────────────

echo ">>> Installing first-boot auto-resize service..."
cat > "$MNT/usr/local/sbin/rpi-clone-resize.sh" <<'RESIZE'
#!/bin/bash
# Expand the root partition + filesystem to fill the disk, once, then self-remove.
set -e
exec >>/var/log/rpi-clone-resize.log 2>&1
echo "=== rpi-clone-resize $(date) ==="
ROOT_PART="$(findmnt -no SOURCE /)"
PARTNUM="$(echo "$ROOT_PART" | grep -o '[0-9]*$')"
DISK="/dev/$(lsblk -no pkname "$ROOT_PART")"
echo "disk=$DISK partnum=$PARTNUM root=$ROOT_PART"
echo ', +' | sfdisk --no-reread --force -N "$PARTNUM" "$DISK" || true
partprobe "$DISK" 2>/dev/null || partx -u "$DISK" 2>/dev/null || true
sleep 2
resize2fs "$ROOT_PART"
systemctl disable rpi-clone-resize.service || true
rm -f /etc/systemd/system/rpi-clone-resize.service \
      /etc/systemd/system/multi-user.target.wants/rpi-clone-resize.service \
      /usr/local/sbin/rpi-clone-resize.sh
echo "=== done ==="
RESIZE
chmod +x "$MNT/usr/local/sbin/rpi-clone-resize.sh"

cat > "$MNT/etc/systemd/system/rpi-clone-resize.service" <<'UNIT'
[Unit]
Description=Expand root filesystem on first boot (rpi-clone)
After=local-fs.target
Before=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/rpi-clone-resize.sh
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
UNIT

mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants"
ln -sf ../rpi-clone-resize.service \
    "$MNT/etc/systemd/system/multi-user.target.wants/rpi-clone-resize.service"

# ── Done (cleanup trap unmounts, detaches loop, restarts containers) ─────────

sync
echo ""
echo "=== Clone complete ==="
echo "Image:     $IMG"
echo "File size: $(du -h "$IMG" | cut -f1) actual on disk"
echo ""
echo "Next: copy the image off the Pi (use rsync --sparse or scp), then flash"
echo "      it to a blank NVMe with rpi-burn.sh. Root auto-expands on first boot."
