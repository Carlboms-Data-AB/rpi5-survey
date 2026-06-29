# rpi5-survey

Tools for cloning Raspberry Pi 5 units (NVMe boot, CasaOS/Docker) into bootable cold-spare images.

## Scripts

| Script | Run on | Purpose |
|--------|--------|---------|
| `rpi-survey.sh` | Production Pi | Read-only diagnostic — gathers partition layout, boot config, disk usage |
| `rpi-clone.sh` | Production Pi | Creates a bootable `.img` clone, excluding bulk data |
| `rpi-burn.sh` | Backup Pi (SD card boot) | Flashes the `.img` to a blank NVMe drive |

## Full workflow

### 1. Survey (one-time, already done)

```bash
curl -fsSL https://raw.githubusercontent.com/Carlboms-Data-AB/rpi5-survey/main/rpi-survey.sh | sudo bash
```

### 2. Clone (on production Pi)

SSH into the production Pi and run:

```bash
curl -fsSL https://raw.githubusercontent.com/Carlboms-Data-AB/rpi5-survey/main/rpi-clone.sh -o rpi-clone.sh
chmod +x rpi-clone.sh
sudo ./rpi-clone.sh
```

This will:
- Calculate the image size from **actual included data** (root used − excluded bulk dirs) and print it before copying
- Stop Node-RED, InfluxDB, and MinIO for a consistent snapshot
- Build a raw `.img` from scratch (loopback + rsync) at `/DATA/rpi-clone-<hostname>-<date>.img`, saved locally on the NVMe
- Replicate the MBR table with the **same disk-id** so PARTUUIDs match `fstab`/`cmdline.txt` unchanged
- Install a first-boot systemd service that auto-expands the root partition + filesystem
- Restart the stopped containers

It uses no external imaging tool — just `sfdisk`, `losetup`, `mkfs`, and `rsync`, all standard on Raspberry Pi OS.

**What's excluded** (bulk data only — all config/identity is kept):
- `/DATA/AppData/influxdb/data/engine/` — time-series bulk data
- `/DATA/AppData/influxdb/data/backup_*/` — InfluxDB backup dirs
- `/DATA/AppData/big-bear-minio/can-edge2/` — CAN log bucket
- `/var/swap` — swapfile (regenerated automatically on boot)

**Image size** = included data + ~15% + 1 GiB headroom. It scales with whatever
is actually on disk at clone time (InfluxDB compacts, logs rotate), so it varies
between runs. Verified example on `raspberrypi5`: 127 GiB used − 113 GiB excluded
→ 13.8 GiB included → **17.4 GiB image (~15 GiB on disk)**. Run the survey's
"CLONE SIZE ESTIMATE" section to see the current number for any unit.

Custom output directory: `sudo ./rpi-clone.sh /other/dir` (default: `/DATA`)

### 3. Verify the image (optional but recommended)

Before burning, mount the image read-only and confirm structure + KEEP/EXCLUDE:

```bash
IMG=/DATA/rpi-clone-<hostname>-<date>.img
LOOP=$(sudo losetup -f --show -P "$IMG")
sudo mkdir -p /mnt/verify && sudo mount ${LOOP}p2 /mnt/verify
sudo ls -la /mnt/verify/DATA/AppData/influxdb/data/     # influxd.bolt + influxd.sqlite present, engine ABSENT
sudo ls -la /mnt/verify/DATA/AppData/big-bear-minio/    # .minio.sys present, can-edge2 ABSENT
sudo umount /mnt/verify && sudo losetup -d "$LOOP" && sudo rmdir /mnt/verify
```

### 4. Copy the image off the Pi

Production units are remote with no NAS access, so pull the image to your machine
(sparse-aware to keep it at actual size):

```bash
rsync -avP --sparse user@PROD-PI:/DATA/rpi-clone-*.img .
```

Then move it to wherever the backup Pi can reach it (home NAS, USB drive, or scp
directly to the backup Pi).

### 5. Burn (on backup Pi, booted from SD card)

Boot the backup RPi 5 from an SD card with Raspberry Pi OS. Insert a blank NVMe
drive. The burn script can read from a local file or mount a NAS share directly
and stream to the NVMe — nothing is saved to the SD card.

```bash
curl -fsSL https://raw.githubusercontent.com/Carlboms-Data-AB/rpi5-survey/main/rpi-burn.sh -o rpi-burn.sh
chmod +x rpi-burn.sh
sudo ./rpi-burn.sh /path/to/rpi-clone-<hostname>-<date>.img   # local file
# or:  sudo ./rpi-burn.sh //192.168.1.10/backups               # from NAS
```

The script will:
- (If a NAS share) mount it read-only, list available `.img` files, let you pick
- Confirm before erasing the NVMe
- Flash the image to the NVMe with `dd`
- Auto-expand root filesystem on first boot

### 6. Boot from NVMe

1. `sudo poweroff`
2. Remove the SD card
3. Power on — the Pi boots from NVMe
4. Verify: `df -h` (root partition should fill the entire drive)

## Safety

- `rpi-survey.sh` is strictly read-only
- `rpi-clone.sh` briefly stops Node-RED, InfluxDB, and MinIO (auto-restarts on completion or failure); writes only the new `.img`
- `rpi-burn.sh` refuses to write to the current boot disk and prompts before erasing
- Cold spares only — identical PARTUUID/hostname, never run alongside the original

## Status

- **Clone + image verification**: proven end-to-end on `raspberrypi5` (a real production unit) — correct size, partition table, KEEP/EXCLUDE, and resize service.
- **Burn + first-boot resize**: scripted but not yet run on hardware. Verify the first cold-spare boot before relying on it.

> Note: the GitHub raw CDN caches the `main` ref for a few minutes. If a
> freshly pushed change isn't reflected, fetch a commit-pinned URL instead:
> `.../rpi5-survey/<commit-sha>/rpi-clone.sh`.
