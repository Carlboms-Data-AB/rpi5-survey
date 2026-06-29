#!/usr/bin/env bash
#
# rpi-survey.sh - read-only inventory of a Raspberry Pi 5 (NVMe boot, CasaOS)
#
# Purpose: gather everything needed to plan a full clone / backup image.
# Safe to run: it performs NO writes to the system disk. A few commands use
# sudo (partition table, du on protected dirs) and will prompt for a password.
#
# Usage:
#   chmod +x rpi-survey.sh
#   ./rpi-survey.sh
#
# Output is printed to the screen AND saved to a text file (path shown at end).

OUT="/tmp/rpi-survey-$(hostname)-$(date +%Y%m%d-%H%M%S).txt"

section() {
    printf '\n===== %s =====\n' "$1"
}

main() {
    # Resolve the disk backing the root filesystem (avoids hardcoding nvme0n1)
    ROOT_SRC="$(findmnt -no SOURCE / 2>/dev/null)"
    ROOT_PK="$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -1)"
    DISK="/dev/${ROOT_PK:-nvme0n1}"

    section "MODEL / OS"
    tr -d '\0' < /sys/firmware/devicetree/base/model 2>/dev/null; echo
    cat /etc/os-release
    uname -a
    cat /etc/rpi-issue 2>/dev/null

    section "BOOTLOADER / EEPROM"
    sudo rpi-eeprom-update 2>/dev/null
    vcgencmd bootloader_version 2>/dev/null

    section "ROOT DISK"
    echo "Detected boot disk: $DISK   (root fs on: $ROOT_SRC)"

    section "BLOCK DEVICES"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,PARTUUID,UUID
    echo "--- partition table ---"
    sudo fdisk -l "$DISK" 2>/dev/null
    sudo parted -s "$DISK" print 2>/dev/null

    section "FSTAB / CMDLINE / CONFIG"
    cat /etc/fstab
    echo "--- cmdline ---"
    cat /boot/firmware/cmdline.txt 2>/dev/null || cat /boot/cmdline.txt 2>/dev/null
    echo "--- config.txt location ---"
    ls -la /boot/firmware/config.txt /boot/config.txt 2>/dev/null

    section "DISK USAGE"
    df -hT
    echo "--- top-level usage (may take a few seconds) ---"
    sudo du -xh --max-depth=1 / 2>/dev/null | sort -h

    section "CASAOS / DOCKER"
    casaos -v 2>/dev/null || systemctl status casaos --no-pager 2>/dev/null | head -3
    docker --version 2>/dev/null
    docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null
    docker volume ls 2>/dev/null
    echo "--- /DATA usage ---"
    sudo du -xh --max-depth=2 /DATA 2>/dev/null | sort -h | tail -30

    section "INFLUXDB MOUNTS"
    for c in $(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -i influx); do
        echo "## $c"
        docker inspect -f '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}' "$c"
    done

    section "SWAP / IDENTITY / MEMORY"
    swapon --show
    echo "hostname:   $(hostname)"
    echo "machine-id: $(cat /etc/machine-id 2>/dev/null)"
    free -h

    section "PARTITION GEOMETRY (for clone)"
    echo "disk-id:    $(sudo sfdisk --disk-id "$DISK" 2>/dev/null)"
    sudo sfdisk -d "$DISK" 2>/dev/null

    section "CLONE SIZE ESTIMATE"
    # These are the bulk dirs the clone will EXCLUDE.
    EXCLUDES=(
        /DATA/AppData/influxdb/data/engine
        /DATA/AppData/big-bear-minio/can-edge2
        /var/swap
    )
    # backup_* dirs are also excluded (glob)
    for d in /DATA/AppData/influxdb/data/backup_*; do
        [ -d "$d" ] && EXCLUDES+=("$d")
    done

    human() {
        awk -v b="$1" 'BEGIN{split("B KiB MiB GiB TiB",u," ");i=1;
            while(b>=1024&&i<5){b/=1024;i++}printf "%.1f %s",b,u[i]}'
    }

    ROOT_USED=$(df -B1 --output=used / 2>/dev/null | tail -1 | tr -d ' ')
    echo "root used:        $(human "$ROOT_USED")"
    EXC_TOTAL=0
    echo "excluded dirs:"
    for d in "${EXCLUDES[@]}"; do
        if [ -e "$d" ]; then
            s=$(sudo du -sB1 --one-file-system "$d" 2>/dev/null | cut -f1)
            s=${s:-0}
            EXC_TOTAL=$((EXC_TOTAL + s))
            printf '  %-50s %s\n' "$d" "$(human "$s")"
        else
            printf '  %-50s (absent)\n' "$d"
        fi
    done
    echo "excluded total:   $(human "$EXC_TOTAL")"
    INCLUDED=$((ROOT_USED - EXC_TOTAL))
    echo "INCLUDED (copied): $(human "$INCLUDED")"
    # image root partition = included + 15% + 1 GiB headroom.
    # Pure bash 64-bit arithmetic — awk printf %d overflows on mawk (Debian).
    ROOT_PART=$(( INCLUDED * 115 / 100 + 1073741824 ))
    BOOT_PART=$((512 * 1024 * 1024))
    IMG_SIZE=$((ROOT_PART + BOOT_PART))
    echo "projected .img:    $(human "$IMG_SIZE")  (boot 512 MiB + root $(human "$ROOT_PART"))"
}

echo "This script uses sudo for a few read-only commands; you may be prompted now."
sudo -v

main 2>&1 | tee "$OUT"

echo
echo ">>> Saved to: $OUT"
echo ">>> Send me that file (scp it off the Pi, or paste its contents)."
