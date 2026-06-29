#!/usr/bin/env bash
#
# rpi-clone.sh — Create a bootable NVMe clone image (RPi 5, CasaOS)
#
# Uses RonR image-backup (rsync-based) to produce a content-sized .img
# that can be flashed to a blank NVMe to build an identical cold-spare.
#
# Excludes bulk InfluxDB time-series data and MinIO CAN bucket data.
# Keeps all config, identity, OS, Docker containers, and dashboards.
#
# Usage:
#   sudo ./rpi-clone.sh [output_directory]
#
# Default output: /DATA/rpi-clone-<hostname>-<date>.img

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo $0)" >&2; exit 1; }

HOSTNAME="$(hostname)"
DATE="$(date +%Y%m%d-%H%M%S)"
IMG_NAME="rpi-clone-${HOSTNAME}-${DATE}.img"
OUT_DIR="${1:-/DATA}"
IMG_REAL="${OUT_DIR}/${IMG_NAME}"

# image-backup requires output under /mnt/ or /media/.
# Create a symlink so the string check passes; the file stays on local storage.
LINK="/mnt/.clone-link-$$"
ln -sfn "$OUT_DIR" "$LINK"
IMG="${LINK}/${IMG_NAME}"

EXCLUDE_FILE="/tmp/rpi-clone-excludes.txt"

echo "=== RPi 5 NVMe Clone ==="
echo "Host:   $HOSTNAME"
echo "Output: $IMG_REAL"
echo ""

# ── Install image-backup if missing ──────────────────────────────────────────

if ! command -v image-backup &>/dev/null; then
    echo ">>> Installing RonR image-utils..."
    apt-get update -qq && apt-get install -y -qq git
    TMPDIR=$(mktemp -d)
    git clone --depth 1 https://github.com/seamusdemora/RonR-RPi-image-utils.git "$TMPDIR"
    install --mode=755 "$TMPDIR"/image-* /usr/local/sbin/
    rm -rf "$TMPDIR"
    echo ">>> image-backup installed."
    echo ""
fi

# ── Create exclude file ─────────────────────────────────────────────────────

cat > "$EXCLUDE_FILE" <<EXCLUDES
# InfluxDB bulk data (keep influxd.bolt, influxd.sqlite, config/)
/DATA/AppData/influxdb/data/engine/
/DATA/AppData/influxdb/data/backup_*/

# MinIO CAN edge2 bucket data
/DATA/AppData/big-bear-minio/can-edge2/

# The output image itself
${IMG_REAL}
EXCLUDES

echo ">>> Exclude list:"
grep -v '^#' "$EXCLUDE_FILE" | grep -v '^$'
echo ""

# ── Stop write-heavy containers for consistent snapshot ──────────────────────

CONTAINERS_STOPPED=()

cleanup() {
    if [[ ${#CONTAINERS_STOPPED[@]} -gt 0 ]]; then
        echo ""
        echo ">>> Restarting stopped containers..."
        for c in "${CONTAINERS_STOPPED[@]}"; do
            docker start "$c" && echo "    Started: $c"
        done
    fi
    rm -f "$LINK" "$EXCLUDE_FILE"
}
trap cleanup EXIT

echo ">>> Stopping write-heavy containers..."
for c in node-red influxdb minio; do
    if docker inspect --format='{{.State.Running}}' "$c" 2>/dev/null | grep -q true; then
        docker stop "$c"
        CONTAINERS_STOPPED+=("$c")
        echo "    Stopped: $c"
    else
        echo "    Skipped: $c (not running)"
    fi
done

sync
sleep 2

# ── Run image-backup ─────────────────────────────────────────────────────────

echo ""
echo ">>> Creating clone image (this will take a while)..."
echo ""
image-backup -i "$IMG" -o "--exclude-from=$EXCLUDE_FILE,--delete-excluded"

echo ""
echo "=== Clone complete ==="
echo "Image: $IMG_REAL"
echo "Size:  $(du -h "$IMG_REAL" | cut -f1)"
echo ""
echo "Next: copy the image off the Pi, then flash with rpi-burn.sh"
