# rpi5-survey

Read-only diagnostic script for Raspberry Pi 5 units booting from NVMe (no SD card) running CasaOS with Docker.

Collects the system inventory needed to plan a full bootable NVMe clone/ghost image.

## What it gathers

- Model, OS version, kernel, bootloader/EEPROM status
- Partition table (GPT vs MBR), filesystem types, PARTUUIDs
- `/etc/fstab`, `cmdline.txt`, `config.txt`
- Disk usage breakdown (top-level and `/DATA/AppData`)
- InfluxDB data/config paths and sizes
- Docker containers, volumes, and CasaOS version
- Swap, hostname, machine-id, memory

## Usage

SSH into the Pi and run:

```bash
curl -fsSL https://raw.githubusercontent.com/Carlboms-Data-AB/rpi5-survey/main/rpi-survey.sh | sudo bash
```

Or download first:

```bash
curl -fsSL https://raw.githubusercontent.com/Carlboms-Data-AB/rpi5-survey/main/rpi-survey.sh -o rpi-survey.sh
chmod +x rpi-survey.sh
sudo ./rpi-survey.sh
```

Output is printed to the screen and saved to `/tmp/rpi-survey-<hostname>-<timestamp>.txt`.

## Safety

The script is strictly read-only — it makes no writes to the system disk. A few commands use `sudo` for reading protected paths (partition tables, `/DATA` directory sizes).
