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
- Install [RonR image-backup](https://github.com/seamusdemora/RonR-RPi-image-utils) if not present
- Stop Node-RED, InfluxDB, and MinIO for a consistent snapshot
- Create a content-sized `.img` at `/DATA/rpi-clone-<hostname>-<date>.img` (saved locally on the NVMe)
- Restart the stopped containers
- Auto-resize is baked in — the root partition expands on first boot

**What's excluded** (bulk data only — all config/identity is kept):
- `/DATA/AppData/influxdb/data/engine/` — time-series bulk data
- `/DATA/AppData/influxdb/data/backup_*/` — InfluxDB backup dirs
- `/DATA/AppData/big-bear-minio/can-edge2/` — CAN log bucket

**Estimated image size**: ~13–18 GB (vs 143 GB total used on pi-gateway)

Custom output path: `sudo ./rpi-clone.sh /path/to/output.img`

### 3. Copy image to NAS

```bash
scp /DATA/rpi-clone-*.img user@nas:/path/to/backups/
```

### 4. Burn (on backup Pi, booted from SD card)

Boot the backup RPi 5 from an SD card with Raspberry Pi OS. Insert a blank NVMe drive. The burn script mounts the NAS share directly and streams the image to the NVMe — nothing is saved to the SD card.

```bash
curl -fsSL https://raw.githubusercontent.com/Carlboms-Data-AB/rpi5-survey/main/rpi-burn.sh -o rpi-burn.sh
chmod +x rpi-burn.sh
sudo ./rpi-burn.sh //192.168.1.10/backups
```

The script will:
- Mount the NAS share (read-only, prompts for credentials)
- List available `.img` files and let you pick one
- Confirm before erasing the NVMe
- Stream the image directly from NAS → NVMe with `dd`
- Auto-expand root filesystem on first boot

You can also pass a local file: `sudo ./rpi-burn.sh /path/to/image.img`

### 5. Boot from NVMe

1. `sudo poweroff`
2. Remove the SD card
3. Power on — the Pi boots from NVMe
4. Verify: `df -h` (root partition should fill the entire drive)

## Safety

- `rpi-survey.sh` and `rpi-burn.sh` are read-only / write-to-NVMe-only
- `rpi-clone.sh` briefly stops Node-RED, InfluxDB, and MinIO (auto-restarts on completion or failure)
- `rpi-burn.sh` refuses to write to the current boot disk
- Cold spares only — identical PARTUUID/hostname, never run alongside the original
