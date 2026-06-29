#!/usr/bin/env bash
#
# rpi-health.sh — Health & maintenance for RPi 5 NVMe units (CasaOS/Docker)
#
# READ-ONLY by default: reports disk usage, oversized Docker container logs,
# NVMe SMART wear/health, and journal size — with a plain-language verdict.
#
# Cleanup actions are OPT-IN and never run unless you ask:
#   --truncate-logs [SIZE]    truncate container logs larger than SIZE (default 100M)
#   --install-log-rotation    write /etc/docker/daemon.json log caps (backs up existing)
#   --vacuum-journal [SIZE]   shrink systemd journal to SIZE (default 200M)
#
# Usage:
#   sudo ./rpi-health.sh                       # report only
#   sudo ./rpi-health.sh --truncate-logs       # report + truncate logs >100M
#   sudo ./rpi-health.sh --truncate-logs 50M --vacuum-journal
#
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo $0)" >&2; exit 1; }

# ── Options ──────────────────────────────────────────────────────────────────

DO_TRUNCATE=false
TRUNCATE_SIZE="100M"
DO_LOGROTATE=false
DO_VACUUM=false
VACUUM_SIZE="200M"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --truncate-logs)
            DO_TRUNCATE=true
            [[ "${2:-}" =~ ^[0-9]+[KMG]?$ ]] && { TRUNCATE_SIZE="$2"; shift; }
            ;;
        --install-log-rotation) DO_LOGROTATE=true ;;
        --vacuum-journal)
            DO_VACUUM=true
            [[ "${2:-}" =~ ^[0-9]+[KMG]?$ ]] && { VACUUM_SIZE="$2"; shift; }
            ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

SEP="--------------------------------------------------------------------------------"
section() { printf '\n===== %s =====\n' "$1"; }

# size string (100M/2G) -> bytes
to_bytes() {
    local n="${1%[KMG]}" u="${1##*[0-9]}"
    case "$u" in
        K) echo $((n * 1024)) ;;
        M) echo $((n * 1024 * 1024)) ;;
        G) echo $((n * 1024 * 1024 * 1024)) ;;
        *) echo "$n" ;;
    esac
}

human() {
    awk -v b="$1" 'BEGIN{split("B KiB MiB GiB TiB",u," ");i=1;
        while(b>=1024&&i<5){b/=1024;i++}printf "%.1f %s",b,u[i]}'
}

# ── Report: disk usage ───────────────────────────────────────────────────────

section "DISK USAGE"
df -h / /boot/firmware 2>/dev/null
echo "$SEP"
echo "Top-level:"
du -xh --max-depth=1 / 2>/dev/null | sort -rh | head -8
if [ -d /DATA/AppData ]; then
    echo "$SEP"
    echo "/DATA/AppData:"
    du -h --max-depth=1 /DATA/AppData 2>/dev/null | sort -rh | head -8
fi

# ── Report: Docker container logs ────────────────────────────────────────────

section "DOCKER CONTAINER LOGS"
LOG_TOTAL=0
BIG_LOGS=()
if [ -d /var/lib/docker/containers ]; then
    while IFS= read -r log; do
        [ -f "$log" ] || continue
        sz=$(stat -c%s "$log")
        LOG_TOTAL=$((LOG_TOTAL + sz))
        cid=$(basename "$(dirname "$log")")
        name=$(docker inspect --format '{{.Name}}' "$cid" 2>/dev/null | sed 's#^/##')
        name="${name:-$cid}"
        printf '  %-22s %s\n' "${name:0:22}" "$(human "$sz")"
        BIG_LOGS+=("$sz:$log:$name")
    done < <(find /var/lib/docker/containers -name '*-json.log' 2>/dev/null)
    echo "$SEP"
    echo "  total container log size: $(human "$LOG_TOTAL")"
else
    echo "  (no docker containers dir)"
fi

# ── Report: NVMe SMART health ────────────────────────────────────────────────

section "NVMe HEALTH (SMART)"
if ! command -v smartctl &>/dev/null; then
    echo ">>> installing smartmontools (read-only diagnostic tool)..."
    apt-get update -qq && apt-get install -y -qq smartmontools
fi
ROOT_SRC="$(findmnt -no SOURCE / 2>/dev/null)"
NVME="/dev/$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -1)"
SMART="$(smartctl -a "$NVME" 2>/dev/null)"

get() { grep -m1 "$1" <<<"$SMART" | sed 's/.*:[[:space:]]*//'; }

HEALTH=$(get "SMART overall-health")
CRIT=$(get "Critical Warning")
PUSED=$(get "Percentage Used")
SPARE=$(get "Available Spare:")
SPARE_THR=$(get "Available Spare Threshold")
MEDIA_ERR=$(get "Media and Data Integrity Errors")
TEMP=$(get "Temperature:")
WRITTEN=$(grep -m1 "Data Units Written" <<<"$SMART" | grep -o '\[.*\]')
POH=$(get "Power On Hours")
UNSAFE=$(get "Unsafe Shutdowns")

printf '  %-26s %s\n' "Device:"            "$NVME ($(grep -m1 'Model Number' <<<"$SMART" | sed 's/.*:[[:space:]]*//'))"
printf '  %-26s %s\n' "Overall health:"    "$HEALTH"
printf '  %-26s %s\n' "Critical warning:"  "$CRIT"
printf '  %-26s %s\n' "Percentage used:"   "$PUSED"
printf '  %-26s %s\n' "Available spare:"   "$SPARE (threshold $SPARE_THR)"
printf '  %-26s %s\n' "Media errors:"      "$MEDIA_ERR"
printf '  %-26s %s\n' "Temperature:"       "$TEMP"
printf '  %-26s %s\n' "Total written:"     "$WRITTEN"
printf '  %-26s %s\n' "Power-on hours:"    "$POH"
printf '  %-26s %s\n' "Unsafe shutdowns:"  "$UNSAFE"

echo "$SEP"
PUSED_N="${PUSED%\%}"
echo "  VERDICT:"
[[ "$HEALTH" == *PASSED* ]] || echo "  ** SMART reports FAILED — replace this drive **"
[[ "$CRIT" == "0x00" ]]     || echo "  ** Critical warning $CRIT — drive reliability degraded **"
if [[ "$PUSED_N" =~ ^[0-9]+$ ]]; then
    if   (( PUSED_N >= 100 )); then echo "  ** Endurance fully consumed (${PUSED}) — replace ASAP **"
    elif (( PUSED_N >= 80 ));  then echo "  ** Wear high (${PUSED}) — plan replacement **"
    else echo "  Wear OK (${PUSED})"
    fi
fi
[[ "$MEDIA_ERR" == "0" ]] || echo "  ** Media errors present ($MEDIA_ERR) **"
[[ "$HEALTH" == *PASSED* && "$CRIT" == "0x00" ]] && echo "  Drive healthy."

# ── Report: journal ──────────────────────────────────────────────────────────

section "SYSTEMD JOURNAL"
journalctl --disk-usage 2>/dev/null || echo "  (journalctl unavailable)"

# ── Actions (opt-in) ─────────────────────────────────────────────────────────

if $DO_TRUNCATE; then
    section "ACTION: truncate container logs > $TRUNCATE_SIZE"
    THR=$(to_bytes "$TRUNCATE_SIZE")
    FREED=0
    for entry in "${BIG_LOGS[@]}"; do
        sz="${entry%%:*}"; rest="${entry#*:}"; log="${rest%%:*}"; name="${rest##*:}"
        if (( sz > THR )); then
            truncate -s 0 "$log"
            FREED=$((FREED + sz))
            echo "  truncated $name ($(human "$sz"))"
        fi
    done
    echo "  freed: $(human "$FREED")"
    [[ "$LOG_TOTAL" -gt "$THR" && "$FREED" -eq 0 ]] && echo "  (nothing over threshold)"
fi

if $DO_LOGROTATE; then
    section "ACTION: install Docker log rotation"
    DJ=/etc/docker/daemon.json
    if [ -f "$DJ" ]; then
        BK="${DJ}.bak-$(date +%Y%m%d-%H%M%S)"
        cp "$DJ" "$BK"
        echo "  backed up existing $DJ -> $BK"
        echo "  NOT overwriting automatically — current contents:"
        sed 's/^/    /' "$DJ"
        echo "  Merge these log-opts in manually, or remove $DJ and re-run:"
        echo '    "log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}'
    else
        mkdir -p /etc/docker
        cat > "$DJ" <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
JSON
        echo "  wrote $DJ (caps each container at 3 × 10 MB)"
    fi
    echo ""
    echo "  NOTE: this applies to containers CREATED after the change. Existing"
    echo "  containers keep their current (uncapped) logs until recreated, e.g.:"
    echo "      docker compose up -d --force-recreate   (per CasaOS app)"
    echo "  A 'systemctl restart docker' alone does NOT rotate existing logs and"
    echo "  WILL briefly bounce every container — avoid on production unless needed."
fi

if $DO_VACUUM; then
    section "ACTION: vacuum journal to $VACUUM_SIZE"
    journalctl --vacuum-size="$VACUUM_SIZE"
fi

echo ""
echo "Done."
