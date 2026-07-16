#!/usr/bin/env bash
# ============================================================
#  Ubuntu Performance Optimizer
#  Targets: HP EliteBook | Lenovo ThinkPad T14s
#  Ubuntu 22.04 / 24.04 LTS
#  Safe standard optimizations only
# ============================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()     { echo -e "${GREEN}[OK]${RESET}   $1"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $1"; }
info()    { echo -e "${CYAN}[INFO]${RESET} $1"; }
section() { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════${RESET}\n${BOLD} $1${RESET}\n${BOLD}${CYAN}══════════════════════════════════════${RESET}"; }

# ── Root check ──────────────────────────────────────────────
if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}[ERROR]${RESET} Run as root: sudo bash $0"
    exit 1
fi

LOGFILE="/var/log/ubuntu_optimizer.log"
exec > >(tee -a "$LOGFILE") 2>&1
echo "=== Optimization run: $(date) ==="

# ────────────────────────────────────────────────────────────
# STEP 1 — SYSTEM INFO
# ────────────────────────────────────────────────────────────
section "STEP 1 — System Info"

MANUFACTURER=$(dmidecode -t system 2>/dev/null | awk -F': ' '/Manufacturer/{print $2}' | xargs)
PRODUCT=$(dmidecode -t system 2>/dev/null | awk -F': ' '/Product Name/{print $2}' | xargs)
CPU_MODEL=$(grep "model name" /proc/cpuinfo | head -1 | cut -d':' -f2 | xargs)
TOTAL_RAM=$(free -h | awk '/Mem/{print $2}')
SWAP_SIZE=$(free -h | awk '/Swap/{print $2}')
KERNEL=$(uname -r)
UBUNTU_VER=$(lsb_release -rs 2>/dev/null || echo "unknown")
DISK_INFO=$(lsblk -d -o NAME,SIZE,ROTA | grep -v NAME | \
    awk '{if($3==0) type="SSD"; else type="HDD"; print $1" "$2" ["type"]"}')

echo ""
echo -e "  ${BOLD}Manufacturer :${RESET} $MANUFACTURER"
echo -e "  ${BOLD}Product      :${RESET} $PRODUCT"
echo -e "  ${BOLD}CPU          :${RESET} $CPU_MODEL"
echo -e "  ${BOLD}RAM          :${RESET} $TOTAL_RAM"
echo -e "  ${BOLD}Swap         :${RESET} $SWAP_SIZE"
echo -e "  ${BOLD}Kernel       :${RESET} $KERNEL"
echo -e "  ${BOLD}Ubuntu       :${RESET} $UBUNTU_VER"
echo -e "  ${BOLD}Disk(s)      :${RESET}"
echo "$DISK_INFO" | while read -r line; do echo "    $line"; done
echo ""

# ────────────────────────────────────────────────────────────
# STEP 2 — SWAPPINESS & MEMORY
# ────────────────────────────────────────────────────────────
section "STEP 2 — Memory: swappiness & dirty pages"

SYSCTL_FILE="/etc/sysctl.d/99-performance.conf"

cat > "$SYSCTL_FILE" <<'EOF'
# ── Ubuntu Performance Tuning ─────────────────────────────

# Keep more in RAM; swap only when nearly full
# 10 is good for 8GB+ RAM; raise to 20-30 if you have 4GB
vm.swappiness = 10

# How aggressively kernel reclaims page cache (default 100)
# 50 = balanced; less reclaim pressure
vm.vfs_cache_pressure = 50

# Dirty page writeback tuning — smoother disk I/O
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
vm.dirty_writeback_centisecs = 1500
vm.dirty_expire_centisecs = 3000

# Inotify watches — prevents "too many open files" in VSCode/IntelliJ
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
EOF

sysctl -p "$SYSCTL_FILE" 2>/dev/null \
    && log "sysctl tuning applied (/etc/sysctl.d/99-performance.conf)" \
    || warn "Some sysctl params skipped"

# ────────────────────────────────────────────────────────────
# STEP 3 — ZSWAP (RAM-based swap compression)
# ────────────────────────────────────────────────────────────
section "STEP 3 — zswap (compressed swap in RAM)"

if [[ -d /sys/module/zswap ]]; then
    echo 1   > /sys/module/zswap/parameters/enabled    2>/dev/null || true
    # Try lz4 first (faster), fall back to lzo
    echo lz4 > /sys/module/zswap/parameters/compressor 2>/dev/null || \
    echo lzo > /sys/module/zswap/parameters/compressor 2>/dev/null || true
    echo z3fold > /sys/module/zswap/parameters/zpool   2>/dev/null || true

    COMPRESSOR=$(cat /sys/module/zswap/parameters/compressor 2>/dev/null || echo "unknown")
    log "zswap enabled (compressor: $COMPRESSOR)"

    # Persist in GRUB for next boot
    GRUB_FILE="/etc/default/grub"
    if [[ -f "$GRUB_FILE" ]] && ! grep -q "zswap.enabled=1" "$GRUB_FILE"; then
        cp "$GRUB_FILE" "${GRUB_FILE}.bak.$(date +%F)"
        sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 zswap.enabled=1 zswap.compressor=lz4"/' "$GRUB_FILE"
        update-grub 2>/dev/null \
            && log "zswap persisted in GRUB (active after reboot)" \
            || warn "update-grub failed — zswap active this session only"
    else
        info "zswap already in GRUB or GRUB not found — skipping GRUB edit"
    fi
else
    warn "zswap module not available on this kernel — skipping"
fi

# ────────────────────────────────────────────────────────────
# STEP 4 — SSD I/O SCHEDULER
# ────────────────────────────────────────────────────────────
section "STEP 4 — SSD/NVMe I/O Scheduler"

for disk in $(lsblk -d -n -o NAME,ROTA | awk '$2==0{print $1}'); do
    SCHED_PATH="/sys/block/$disk/queue/scheduler"
    if [[ -f "$SCHED_PATH" ]]; then
        if [[ "$disk" == nvme* ]]; then
            echo "none" > "$SCHED_PATH" \
                && log "NVMe $disk → scheduler: none (hardware queue)"
        else
            echo "mq-deadline" > "$SCHED_PATH" \
                && log "SSD $disk → scheduler: mq-deadline"
        fi
    fi
done

# Persist via udev rules
cat > /etc/udev/rules.d/60-ssd-scheduler.rules <<'EOF'
# NVMe — no I/O scheduler needed
ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="none"
# SATA SSD
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
# HDD
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
EOF
log "udev I/O scheduler rules saved (persistent)"

# Enable weekly SSD TRIM
systemctl enable fstrim.timer 2>/dev/null \
    && log "Weekly SSD TRIM timer enabled" \
    || warn "fstrim.timer not available"

# ────────────────────────────────────────────────────────────
# STEP 5 — SHUTDOWN TIMEOUT (reduce hang on shutdown)
# ────────────────────────────────────────────────────────────
section "STEP 5 — Reduce shutdown hang timeout"

SYSTEMD_CONF="/etc/systemd/system.conf"
cp "$SYSTEMD_CONF" "${SYSTEMD_CONF}.bak.$(date +%F)" 2>/dev/null || true

set_systemd_param() {
    local key="$1" val="$2"
    if grep -q "^${key}=" "$SYSTEMD_CONF"; then
        sed -i "s/^${key}=.*/${key}=${val}/" "$SYSTEMD_CONF"
    elif grep -q "^#${key}=" "$SYSTEMD_CONF"; then
        sed -i "s/^#${key}=.*/${key}=${val}/" "$SYSTEMD_CONF"
    else
        echo "${key}=${val}" >> "$SYSTEMD_CONF"
    fi
    log "systemd: $key = $val"
}

set_systemd_param "DefaultTimeoutStopSec"  "15s"
set_systemd_param "DefaultTimeoutStartSec" "20s"

systemctl daemon-reload && log "systemd reloaded"

# ────────────────────────────────────────────────────────────
# STEP 6 — JOURNAL LOG SIZE LIMIT
# ────────────────────────────────────────────────────────────
section "STEP 6 — Journal log cleanup"

# Limit journal size on disk
mkdir -p /etc/systemd/journald.conf.d/
cat > /etc/systemd/journald.conf.d/99-size.conf <<'EOF'
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=50M
EOF
systemctl restart systemd-journald 2>/dev/null \
    && log "Journal max size limited to 200MB"

# Clean old logs right now
journalctl --vacuum-time=7d 2>/dev/null \
    && log "Journal logs older than 7 days removed"

# ────────────────────────────────────────────────────────────
# STEP 7 — REMOVE UNNECESSARY APT PACKAGES
# ────────────────────────────────────────────────────────────
section "STEP 7 — Remove unnecessary packages"

# Packages that are bloat on a developer laptop.
# Each one is only removed if installed — safe to run.
BLOAT_PACKAGES=(
    # Games
    "aisleriot"           # Solitaire card game
    "gnome-mahjongg"      # Mahjong game
    "gnome-mines"         # Minesweeper
    "gnome-sudoku"        # Sudoku game
    "gnome-2048"          # 2048 game

    # Media / entertainment not needed for dev
    "rhythmbox"           # Music player
    "totem"               # GNOME video player

    # Office / document apps (use LibreOffice selectively or web)
    "libreoffice-draw"    # Drawing tool
    "libreoffice-math"    # Math formula editor

    # Unused accessories
    "gnome-contacts"      # Contacts app (no sync usually configured)
    "gnome-maps"          # Maps app (use browser instead)
    "gnome-weather"       # Weather app
    "gnome-clocks"        # Clocks app
    "gnome-calendar"      # Calendar (redundant if using web calendar)

    # Printing stack — remove if no printer
    "cups"                # Common UNIX Printing System
    "cups-browsed"        # Network printer browsing
    "cups-filters"        # CUPS filters

    # Ubuntu-specific telemetry / crash reporting
    "apport"              # Crash reporter
    "whoopsie"            # Sends crash reports to Canonical
    "ubuntu-report"       # System reporting tool

    # Unused hardware / protocol support
    "simple-scan"         # Scanner app — remove if no scanner
    "snapd"               # Snap daemon — remove if you don't use snaps
)

REMOVED=()
SKIPPED=()

for pkg in "${BLOAT_PACKAGES[@]}"; do
    # Strip inline comments to get the clean package name
    clean_pkg=$(echo "$pkg" | awk '{print $1}')
    if dpkg -l "$clean_pkg" 2>/dev/null | grep -q "^ii"; then
        apt-get remove -y "$clean_pkg" 2>/dev/null \
            && REMOVED+=("$clean_pkg") \
            || warn "Could not remove: $clean_pkg"
    else
        SKIPPED+=("$clean_pkg")
    fi
done

if [[ ${#REMOVED[@]} -gt 0 ]]; then
    log "Removed ${#REMOVED[@]} bloat package(s): ${REMOVED[*]}"
else
    log "No bloat packages were installed — nothing to remove"
fi
info "Skipped (not installed): ${#SKIPPED[@]} package(s)"

# ────────────────────────────────────────────────────────────
# STEP 8 — APT CLEANUP
# ────────────────────────────────────────────────────────────
section "STEP 8 — APT cleanup"

apt-get autoremove -y 2>/dev/null && log "Orphaned dependency packages removed"
apt-get autoclean  -y 2>/dev/null && log "APT package cache cleaned"

# ────────────────────────────────────────────────────────────
# DONE
# ────────────────────────────────────────────────────────────
section "DONE"

echo ""
echo -e "${BOLD}${GREEN}  ✔  Optimizations applied!${RESET}"
echo ""
echo -e "${BOLD}  What was changed:${RESET}"
echo "  ├─ vm.swappiness = 10        (less swap usage)"
echo "  ├─ vm.vfs_cache_pressure = 50 (balanced cache)"
echo "  ├─ dirty page ratios tuned   (smoother I/O)"
echo "  ├─ inotify watches = 524288  (IDE fix)"
echo "  ├─ zswap enabled (lz4)       (RAM swap compression)"
echo "  ├─ SSD/NVMe I/O scheduler    (mq-deadline / none)"
echo "  ├─ Weekly SSD TRIM enabled"
echo "  ├─ Shutdown timeout = 15s    (was 90s)"
echo "  ├─ Journal capped at 200MB"
echo "  ├─ Bloat packages removed (games, telemetry, unused apps)"
echo "  └─ APT orphans + cache cleaned"
echo ""
echo -e "${YELLOW}  ⚠  Reboot recommended for all changes to take full effect${RESET}"
echo -e "  Log: ${CYAN}$LOGFILE${RESET}"
echo ""

read -rp "  Reboot now? [y/N]: " ANS
[[ "$ANS" =~ ^[Yy]$ ]] && reboot || echo "  Skipping reboot."
