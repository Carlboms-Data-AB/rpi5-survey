# rpi5-maintenance

Maintenance toolkit for Raspberry Pi 5 units that boot from NVMe and run
CasaOS / Docker. Survey a unit, clone it into a bootable cold-spare image,
flash that image to a blank NVMe, and keep drives healthy.

> **Configure before use.** The clone excludes and the list of containers to
> stop are deployment-specific. Edit the clearly-marked `EXCLUDES` /
> `STOP_CONTAINERS` blocks near the top of `rpi-clone.sh` (and the matching
> `EXCLUDES` in `rpi-survey.sh`) to match your own apps and bulk data.

## Scripts

| Script | Run on | Purpose |
|--------|--------|---------|
| `rpi-survey.sh` | Target Pi | Read-only diagnostic — partition layout, boot config, disk usage, projected clone size |
| `rpi-clone.sh` | Target Pi | Builds a bootable, content-sized `.img` clone, excluding configured bulk data |
| `rpi-burn.sh` | Spare Pi (SD card boot) | Flashes the `.img` to a blank NVMe drive |
| `rpi-health.sh` | Any Pi | Read-only health report (disk, Docker logs, NVMe SMART, journal) + opt-in cleanup |

Replace `OWNER/REPO` in the commands below with your repository path.

## Clone workflow

### 1. Survey

```bash
curl -fsSL https://raw.githubusercontent.com/OWNER/REPO/main/rpi-survey.sh | sudo bash
```

Reports geometry and a **CLONE SIZE ESTIMATE** (root used − excluded bulk dirs
+ headroom) so you know the image size before building anything.

### 2. Clone (on the target Pi)

```bash
curl -fsSL https://raw.githubusercontent.com/OWNER/REPO/main/rpi-clone.sh -o rpi-clone.sh
chmod +x rpi-clone.sh
sudo ./rpi-clone.sh                 # default output dir: /DATA
```

This will:
- Calculate the image size from **actual included data** and print it before copying
- Stop the configured write-heavy containers for a consistent snapshot
- Build a raw `.img` from scratch (loopback + rsync) at `/DATA/rpi-clone-<hostname>-<date>.img`, saved locally on the NVMe
- Replicate the MBR table with the **same disk-id** so PARTUUIDs match `fstab`/`cmdline.txt` unchanged
- Install a first-boot systemd service that auto-expands the root partition + filesystem
- Restart the stopped containers (also on failure, via cleanup trap)

No external imaging tool — just `sfdisk`, `losetup`, `mkfs`, and `rsync`, all
standard on Raspberry Pi OS.

**What's kept vs excluded.** Everything is kept except the bulk dirs you list in
`EXCLUDES`. Typical excludes are large time-series engines and object-store
buckets; the corresponding metadata/config (e.g. InfluxDB `influxd.bolt` /
`influxd.sqlite`, MinIO `.minio.sys`) sits outside those dirs and is preserved.

**Image size** = included data + ~15% + 1 GiB headroom. It scales with whatever
is on disk at clone time, so it varies between runs.

Custom output directory: `sudo ./rpi-clone.sh /other/dir` (default: `/DATA`)

### 3. Verify the image (recommended)

Mount the image read-only and confirm structure and your KEEP/EXCLUDE choices:

```bash
IMG=/DATA/rpi-clone-<hostname>-<date>.img
LOOP=$(sudo losetup -f --show -P "$IMG")
sudo mkdir -p /mnt/verify && sudo mount ${LOOP}p2 /mnt/verify
sudo ls -la /mnt/verify/DATA/AppData/<app>/      # spot-check kept config / excluded bulk
sudo umount /mnt/verify && sudo losetup -d "$LOOP" && sudo rmdir /mnt/verify
```

### 4. Copy the image off the Pi

For remote units without local backup storage, pull the image to your machine
(sparse-aware to keep it at actual size):

```bash
rsync -avP --sparse user@TARGET-PI:/DATA/rpi-clone-*.img .
```

Then move it to wherever the spare Pi can reach it (NAS, USB drive, or scp
directly to the spare).

### 5. Burn (on the spare Pi, booted from SD card)

Boot the spare RPi 5 from an SD card with Raspberry Pi OS and insert a blank
NVMe drive. The burn script reads a local file or mounts a NAS share directly
and streams to the NVMe — nothing is saved to the SD card.

```bash
curl -fsSL https://raw.githubusercontent.com/OWNER/REPO/main/rpi-burn.sh -o rpi-burn.sh
chmod +x rpi-burn.sh
sudo ./rpi-burn.sh /path/to/rpi-clone-<hostname>-<date>.img   # local file
# or:  sudo ./rpi-burn.sh //NAS-IP/share                       # from a NAS share
```

It confirms before erasing, refuses to write to the current boot disk, and the
root filesystem auto-expands on first boot.

### 6. Boot from NVMe

1. `sudo poweroff`
2. Remove the SD card
3. Power on — the Pi boots from NVMe
4. Verify: `df -h` (root partition should fill the entire drive)

## Health & maintenance

`rpi-health.sh` is **read-only by default** — it reports disk usage, oversized
Docker container logs, NVMe SMART wear/health (with a plain-language verdict),
and journal size.

```bash
curl -fsSL https://raw.githubusercontent.com/OWNER/REPO/main/rpi-health.sh -o rpi-health.sh
chmod +x rpi-health.sh
sudo ./rpi-health.sh
```

Cleanup actions are **opt-in** and never run unless requested:

```bash
sudo ./rpi-health.sh --truncate-logs        # truncate container logs > 100M (no restart)
sudo ./rpi-health.sh --truncate-logs 50M    # custom threshold
sudo ./rpi-health.sh --install-log-rotation # write /etc/docker/daemon.json caps (backs up existing)
sudo ./rpi-health.sh --vacuum-journal 200M  # shrink the systemd journal
```

Note: Docker log-rotation caps apply to containers created *after* the change —
existing containers must be recreated (e.g. `docker compose up -d --force-recreate`)
to pick them up. The script does **not** restart the Docker daemon for you.

## Safety

- `rpi-survey.sh` and `rpi-health.sh` are read-only unless you pass an explicit `--` action flag
- `rpi-clone.sh` briefly stops the configured containers (auto-restarts on completion or failure); writes only the new `.img`
- `rpi-burn.sh` refuses to write to the current boot disk and prompts before erasing
- Cold spares only — a clone shares the original's PARTUUID/hostname, so never run it alongside the original

> Note: the GitHub raw CDN caches the `main` ref for a few minutes. If a freshly
> pushed change isn't reflected, fetch a commit-pinned URL instead:
> `.../REPO/<commit-sha>/rpi-clone.sh`.
