#!/usr/bin/env bash
# ==============================================================================
#  Ubuntu System Settings Rollback Script
#  Reverts changes applied by:
#    - screen_blank.sh (GNOME screen lock & idle delay policies)
#    - optimizev2.sh   (sysctl, zswap, I/O schedulers, systemd timeouts, journal)
# ==============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()     { echo -e "${GREEN}[OK]${RESET}   $1"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $1"; }
info()    { echo -e "${CYAN}[INFO]${RESET} $1"; }
section() { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════${RESET}\n${BOLD} $1${RESET}\n${BOLD}${CYAN}══════════════════════════════════════${RESET}"; }

# ── Argument Parsing ──────────────────────────────────────────────────────────
MODE="all"
REINSTALL_PKGS=false

show_help() {
    cat <<EOF
Usage: sudo bash restore-defaults.sh [OPTIONS]

Options:
  --all               Revert all changes from screen_blank.sh and optimizev2.sh (default)
  --screen-lock       Revert only GNOME screen lock and idle blanking policies
  --performance       Revert only kernel, zswap, sysctl, and systemd performance tweaks
  --reinstall-pkgs    Also reinstall desktop packages removed by optimizev2.sh (CUPS, media, etc.)
  -h, --help          Show this help message
EOF
    exit 0
}

for arg in "$@"; do
    if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
        show_help
    fi
done

# ── Root check ────────────────────────────────────────────────────────────────
if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}[ERROR]${RESET} This script must be run as root: sudo bash $0"
    exit 1
fi

LOGFILE="/var/log/ubuntu_restore_defaults.log"
exec > >(tee -a "$LOGFILE") 2>&1
echo "=== Defaults restoration run: $(date) ==="

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all)
            MODE="all"
            shift
            ;;
        --screen-lock)
            MODE="screen-lock"
            shift
            ;;
        --performance)
            MODE="performance"
            shift
            ;;
        --reinstall-pkgs)
            REINSTALL_PKGS=true
            shift
            ;;
        -h|--help)
            show_help
            ;;
        *)
            echo -e "${RED}[ERROR]${RESET} Unknown option: $1"
            show_help
            ;;
    esac
done

echo ""
echo -e "${BOLD}Target Mode:${RESET} $MODE"
if [[ "$REINSTALL_PKGS" == true ]]; then
    echo -e "${BOLD}Reinstall removed packages:${RESET} yes"
fi
echo ""

# ──────────────────────────────────────────────────────────────────────────────
# STEP 1 — REVERT GNOME SCREEN BLANK & LOCK (screen_blank.sh)
# ──────────────────────────────────────────────────────────────────────────────
revert_screen_blank() {
    section "STEP 1 — Reverting GNOME screen blank & lock policy"

    local dconf_rule="/etc/dconf/db/local.d/00-screen-blank-lock"
    local dconf_lock="/etc/dconf/db/local.d/locks/screen-blank-lock"
    local changes=false

    if [[ -f "$dconf_rule" ]]; then
        rm -f "$dconf_rule"
        log "Removed $dconf_rule"
        changes=true
    else
        info "$dconf_rule not found — skipping"
    fi

    if [[ -f "$dconf_lock" ]]; then
        rm -f "$dconf_lock"
        log "Removed $dconf_lock"
        changes=true
    else
        info "$dconf_lock not found — skipping"
    fi

    # Clean up empty locks directory if nothing else is locked
    if [[ -d /etc/dconf/db/local.d/locks ]] && [[ -z "$(ls -A /etc/dconf/db/local.d/locks 2>/dev/null)" ]]; then
        rmdir /etc/dconf/db/local.d/locks 2>/dev/null || true
    fi

    if command -v dconf >/dev/null 2>&1; then
        dconf update
        log "dconf database recompiled"
    else
        warn "dconf command not found — skipping dconf update"
    fi

    log "GNOME screen lock policy restored to user control."
    info "Users can now configure screen blanking & lock under GNOME Settings -> Power & Privacy."
}

# ──────────────────────────────────────────────────────────────────────────────
# STEP 2 — REVERT SYSCTL MEMORY & KERNEL TUNING (optimizev2.sh Step 2)
# ──────────────────────────────────────────────────────────────────────────────
revert_sysctl() {
    section "STEP 2 — Reverting sysctl memory & dirty page tuning"

    local sysctl_file="/etc/sysctl.d/99-performance.conf"
    if [[ -f "$sysctl_file" ]]; then
        rm -f "$sysctl_file"
        log "Removed $sysctl_file"
    else
        info "$sysctl_file not found — skipping"
    fi

    # Apply Ubuntu stock defaults
    sysctl -w vm.swappiness=60 >/dev/null 2>&1 && log "vm.swappiness reset to 60"
    sysctl -w vm.vfs_cache_pressure=100 >/dev/null 2>&1 && log "vm.vfs_cache_pressure reset to 100"
    sysctl -w vm.dirty_background_ratio=10 >/dev/null 2>&1 && log "vm.dirty_background_ratio reset to 10"
    sysctl -w vm.dirty_ratio=20 >/dev/null 2>&1 && log "vm.dirty_ratio reset to 20"
    sysctl -w vm.dirty_writeback_centisecs=500 >/dev/null 2>&1 && log "vm.dirty_writeback_centisecs reset to 500"
    sysctl -w vm.dirty_expire_centisecs=3000 >/dev/null 2>&1 && log "vm.dirty_expire_centisecs reset to 3000"

    # Reload system sysctl configurations
    sysctl --system >/dev/null 2>&1 && log "System sysctl defaults reloaded"
}

# ──────────────────────────────────────────────────────────────────────────────
# STEP 3 — REVERT ZSWAP & GRUB CONFIGURATION (optimizev2.sh Step 3)
# ──────────────────────────────────────────────────────────────────────────────
revert_zswap() {
    section "STEP 3 — Reverting zswap & GRUB settings"

    # Disable runtime zswap if available
    if [[ -d /sys/module/zswap ]]; then
        echo 0 > /sys/module/zswap/parameters/enabled 2>/dev/null || true
        log "zswap disabled in current running session"
    fi

    local grub_file="/etc/default/grub"
    if [[ -f "$grub_file" ]]; then
        if grep -q "zswap.enabled=1" "$grub_file"; then
            # Clean zswap parameters from GRUB_CMDLINE_LINUX_DEFAULT
            sed -i 's/[[:space:]]*zswap\.enabled=1[[:space:]]*zswap\.compressor=lz4//g' "$grub_file"
            sed -i 's/[[:space:]]*zswap\.enabled=1//g' "$grub_file"
            sed -i 's/[[:space:]]*zswap\.compressor=lz4//g' "$grub_file"
            # Normalize possible double spaces inside quotes
            sed -i 's/  */ /g' "$grub_file"
            log "Removed zswap parameters from $grub_file"

            if command -v update-grub >/dev/null 2>&1; then
                info "Updating GRUB configuration (update-grub)..."
                update-grub 2>/dev/null && log "GRUB configuration updated" || warn "update-grub failed"
            else
                warn "update-grub command not found"
            fi
        else
            info "No zswap parameter found in $grub_file — skipping"
        fi
    else
        warn "$grub_file does not exist — skipping"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# STEP 4 — REVERT SSD/NVMe I/O SCHEDULER RULES (optimizev2.sh Step 4)
# ──────────────────────────────────────────────────────────────────────────────
revert_io_scheduler() {
    section "STEP 4 — Reverting SSD/NVMe I/O scheduler rules"

    local udev_file="/etc/udev/rules.d/60-ssd-scheduler.rules"
    if [[ -f "$udev_file" ]]; then
        rm -f "$udev_file"
        log "Removed $udev_file"
        udevadm control --reload-rules 2>/dev/null || true
        udevadm trigger 2>/dev/null || true
        log "udev rules reloaded and triggered"
    else
        info "$udev_file not found — skipping"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# STEP 5 — REVERT SYSTEMD TIMEOUTS (optimizev2.sh Step 5)
# ──────────────────────────────────────────────────────────────────────────────
revert_systemd_timeouts() {
    section "STEP 5 — Reverting systemd shutdown & startup timeouts"

    local systemd_conf="/etc/systemd/system.conf"
    if [[ -f "$systemd_conf" ]]; then
        # Check for original backup first
        local latest_bak
        latest_bak=$(ls -1t /etc/systemd/system.conf.bak.* 2>/dev/null | head -n 1 || true)
        
        if [[ -n "$latest_bak" && -f "$latest_bak" ]]; then
            cp "$latest_bak" "$systemd_conf"
            log "Restored system.conf from backup ($latest_bak)"
        else
            # Revert to standard defaults (commented out #DefaultTimeoutStopSec=90s)
            sed -i 's/^DefaultTimeoutStopSec=.*/#DefaultTimeoutStopSec=90s/' "$systemd_conf"
            sed -i 's/^DefaultTimeoutStartSec=.*/#DefaultTimeoutStartSec=90s/' "$systemd_conf"
            log "Reset DefaultTimeoutStopSec and DefaultTimeoutStartSec to default 90s"
        fi

        systemctl daemon-reload && log "systemd daemon reloaded"
    else
        warn "$systemd_conf not found — skipping"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# STEP 6 — REVERT JOURNALD LOG RESTRICTIONS (optimizev2.sh Step 6)
# ──────────────────────────────────────────────────────────────────────────────
revert_journald() {
    section "STEP 6 — Reverting journal log size limits"

    local journal_conf="/etc/systemd/journald.conf.d/99-size.conf"
    if [[ -f "$journal_conf" ]]; then
        rm -f "$journal_conf"
        log "Removed $journal_conf"

        # Remove directory if empty
        if [[ -d /etc/systemd/journald.conf.d ]] && [[ -z "$(ls -A /etc/systemd/journald.conf.d 2>/dev/null)" ]]; then
            rmdir /etc/systemd/journald.conf.d 2>/dev/null || true
        fi

        systemctl restart systemd-journald 2>/dev/null \
            && log "systemd-journald restarted with stock limits" \
            || warn "Could not restart systemd-journald"
    else
        info "$journal_conf not found — skipping"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# STEP 7 (OPTIONAL) — REINSTALL REMOVED PACKAGES (optimizev2.sh Step 7)
# ──────────────────────────────────────────────────────────────────────────────
reinstall_removed_packages() {
    section "STEP 7 — Reinstalling commonly needed packages"

    local pkgs=(
        "cups"
        "cups-browsed"
        "cups-filters"
        "simple-scan"
        "totem"
        "apport"
        "whoopsie"
        "ubuntu-report"
    )

    info "Updating APT cache..."
    apt-get update -y >/dev/null 2>&1 || true

    for pkg in "${pkgs[@]}"; do
        if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
            info "$pkg is already installed — skipping"
        else
            info "Installing $pkg..."
            apt-get install -y "$pkg" 2>/dev/null && log "Installed $pkg" || warn "Could not install $pkg"
        fi
    done
}

# ──────────────────────────────────────────────────────────────────────────────
# EXECUTION
# ──────────────────────────────────────────────────────────────────────────────
case "$MODE" in
    all)
        revert_screen_blank
        revert_sysctl
        revert_zswap
        revert_io_scheduler
        revert_systemd_timeouts
        revert_journald
        ;;
    screen-lock)
        revert_screen_blank
        ;;
    performance)
        revert_sysctl
        revert_zswap
        revert_io_scheduler
        revert_systemd_timeouts
        revert_journald
        ;;
esac

if [[ "$REINSTALL_PKGS" == true ]]; then
    reinstall_removed_packages
fi

# ──────────────────────────────────────────────────────────────────────────────
# DONE
# ──────────────────────────────────────────────────────────────────────────────
section "RESTORATION COMPLETE"

echo ""
echo -e "${BOLD}${GREEN}  ✔  System default configurations restored!${RESET}"
echo ""
echo -e "${BOLD}  Summary of restored defaults:${RESET}"
if [[ "$MODE" == "all" || "$MODE" == "screen-lock" ]]; then
    echo "  ├─ GNOME screen blank/lock unlocked (user manageable)"
fi
if [[ "$MODE" == "all" || "$MODE" == "performance" ]]; then
    echo "  ├─ vm.swappiness = 60 (Ubuntu default)"
    echo "  ├─ vm.vfs_cache_pressure = 100"
    echo "  ├─ Dirty page ratios reset"
    echo "  ├─ zswap disabled & removed from GRUB"
    echo "  ├─ SSD/NVMe scheduler custom udev rules removed"
    echo "  ├─ systemd stop/start timeouts reset to defaults"
    echo "  └─ systemd-journald disk size limits removed"
fi
if [[ "$REINSTALL_PKGS" == true ]]; then
    echo "  └─ Reinstalled desktop packages (CUPS, printing, media)"
fi
echo ""
echo -e "  Log file: ${CYAN}$LOGFILE${RESET}"
echo -e "${YELLOW}  ⚠  A system reboot is recommended for all GRUB/kernel changes to take full effect.${RESET}"
echo ""

if [[ -t 0 ]]; then
    read -rp "  Reboot now? [y/N]: " ANS
    [[ "$ANS" =~ ^[Yy]$ ]] && reboot || echo "  Skipping reboot."
else
    echo "  Non-interactive session detected — skipping reboot prompt."
fi
exit 0
