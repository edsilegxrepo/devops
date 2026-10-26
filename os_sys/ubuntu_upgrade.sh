#!/bin/bash
# ----------------------------------------
# /opt/scripts/ubuntu_upgrade.sh
# v1.0.12xg 2026/10/26  XDG / MIS Center
# ----------------------------------------

# ==============================================================================
# SUMMARY & OBJECTIVES:
# ------------------------------------------------------------------------------
# Robust Automated System Upgrade & Hardening Utility (Debian/Ubuntu/Linux Mint)
# Designed for safe, non-interactive, and complete package state maintenance:
#   1. Environment & Privilege Verification (ensuring root context and OS validation).
#   2. Non-interactive frontend enforcement to block interactive package configuration prompts.
#   3. Background Flatpak package updates run in parallel to minimize run time.
#   4. APT Cache synchronization and OS package distribution upgrades.
#   5. Safety configuration/repair of partially installed (unconfigured) packages.
#   6. Cleanup of obsolete packages, configuration files, and unwanted services.
#   7. Chain-loading the Mainline Kernel Deployment pipeline.
#
# CORE COMPONENTS & FUNCTIONAL MODULES:
# ------------------------------------------------------------------------------
#   - Privilege & Platform Guard: Validates that the runner is root and OS is supported.
#   - Environment Source: Sourced settings.sh and sysenv.sh to import PATH and variables.
#   - Parallel Job Spawner: Detects Flatpak and upgrades Flatpak runtimes in the background.
#   - APT Transaction Processor: Cleans and updates APT caches, runs safe upgrade & dist-upgrade.
#   - Service Disabler & Motd Purger: Disables telemetry, ESM cache hooks, and MOTD news.
#   - Dpkg Configuration Repair: Attempts to auto-configure unconfigured unpacked packages.
#   - Package Purger: Cleans orphan packages and removes removed package configuration structures.
#   - Chain-loader: Runs ubuntu_kernel_updater.sh to deploy/verify mainline kernels.
#
# DATA FLOWS:
# ------------------------------------------------------------------------------
#   [Platform Checks] -> [Sourced Envs ($SYS_SCRIPTS)] -> [Spawn Flatpak Job]
#                                                             |
#           +-------------------------------------------------+
#           | (Parallel Execution)
#           v
#   [APT Cache Sync] -> [APT Patch OS] -> [APT Patch Kernel (dist-upgrade)]
#                                                             |
#           +-------------------------------------------------+
#           v
#   [Stop/Mask Telemetry Services] -> [dpkg --configure -a (Repair)]
#                                                             |
#           +-------------------------------------------------+
#           v
#   [Extract unpacked/config-files via dpkg-query] -> [apt-get purge (Clean)]
#                                                             |
#           +-------------------------------------------------+
#           v
#   [Wait for Flatpak Job] -> [Execute ubuntu_kernel_updater.sh]
#
# TEST & VERIFICATION STRATEGY:
# ------------------------------------------------------------------------------
#   1. Static Analysis (Linter):
#      Validated using ShellCheck to ensure POSIX compliance and clean Bash structures.
#      Command: shellcheck -s bash /opt/scripts/ubuntu_upgrade.sh
#
#   2. Dry-run Truncation Validation:
#      Verified package extraction under extremely narrow simulated terminal sizes
#      to guarantee that machine-readable outputs are not formatted or wrapped.
#      Command: COLUMNS=40 dpkg-query -f '${db:Status-Status} ${Package}\n' -W
#
#   3. Runtime Isolation verification:
#      Logging output redirected concurrently to standard output and the persistent log file:
#      File: /var/log/ubuntu_upgrade.log
# ==============================================================================
set -euo pipefail

# ==============================================================================
# CLI PARAMETER PARSING & HELP DISPLAY
# ==============================================================================
show_help() {
    cat << EOF
Usage: sudo $(basename "$0") [OPTIONS]

Automated System Upgrade & Hardening Utility (Debian/Ubuntu/Linux Mint)

Options:
  -h, --help                    Show this help documentation and exit.
  --disable-autoupgrades        Permanently stop, disable, and mask automatic background
                                APT upgrade services/timers (apt-daily, apt-daily-upgrade,
                                unattended-upgrades) before executing system upgrades.
  --disable-autoupgrades-only   Permanently disable and mask automatic background APT
                                upgrade services/timers, then exit immediately without
                                executing system upgrades.
EOF
}

DISABLE_AUTOUPGRADES=false
ONLY_DISABLE_AUTOUPGRADES=false

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        --disable-autoupgrades)
            DISABLE_AUTOUPGRADES=true
            shift
            ;;
        --disable-autoupgrades-only)
            DISABLE_AUTOUPGRADES=true
            ONLY_DISABLE_AUTOUPGRADES=true
            shift
            ;;
        *)
            echo "[-] Usage Error: Unknown argument '$1'" >&2
            show_help >&2
            exit 1
            ;;
    esac
done

# ------------------------------------------------------------------------------
# 1. ENVIRONMENT & PRIVILEGE VERIFICATION
# ------------------------------------------------------------------------------
# Objective: Enforce administrator context and platform restrictions before any state edits.
# Data Flow: Checks EUID variable. Siphons OS tags from /etc/os-release.
# ------------------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    echo "[-] Security Error: This script must be executed as root (sudo)." >&2
    exit 1
fi

# Ensure all APT transactions are non-interactive to block blocking configuration screens
export DEBIAN_FRONTEND=noninteractive

LOG_FILE="/var/log/ubuntu_upgrade.log"
touch "$LOG_FILE"

# Setup logging architecture to support concurrent stdout & file log tracing
log_info() {  echo -e "[+] $(date '+%Y-%m-%d %H:%M:%S') : $1" | tee -a "$LOG_FILE"; }
log_warn() {  echo -e "[!] $(date '+%Y-%m-%d %H:%M:%S') : $1" | tee -a "$LOG_FILE"; }
log_error() { echo -e "[-] $(date '+%Y-%m-%d %H:%M:%S') : $1" >&2 | tee -a "$LOG_FILE"; }

# Enforce script-wide exclusive locking to prevent concurrent executions
exec 8>/run/ubuntu_upgrade.lock
if ! flock -n 8; then
    log_error "Another instance of $(basename "$0") is currently running. Aborting."
    exit 1
fi

# Setup process lifecycle trap to cleanly terminate background jobs upon interruption or exit
cleanup_on_exit() {
    local exit_code=$?
    trap - EXIT INT TERM
    if [ -n "${FLATPAK_PID:-}" ] && kill -0 "$FLATPAK_PID" 2>/dev/null; then
        log_warn "Terminating background Flatpak update process (PID ${FLATPAK_PID})..."
        kill -TERM "$FLATPAK_PID" 2>/dev/null || true
        wait "$FLATPAK_PID" 2>/dev/null || true
    fi
    exit "$exit_code"
}
trap cleanup_on_exit EXIT INT TERM

# Detect if executing within Windows Subsystem for Linux (WSL)
is_wsl() {
    [ -n "${WSL_DISTRO_NAME:-}" ] || \
    [ -n "${WSL_INTEROP:-}" ] || \
    [ -e /proc/sys/fs/binfmt_misc/WSLInterop ] || \
    [ -e /proc/sys/fs/binfmt_misc/WSLInterop-late ] || \
    grep -qi microsoft /proc/version 2>/dev/null
}

# Ensure running on a supported Ubuntu, Debian, or Linux Mint distribution
if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
        ubuntu|debian|linuxmint)
            # Supported OS
            ;;
        *)
            case "${ID_LIKE:-}" in
                *ubuntu*|*debian*)
                    # Supported derivative
                    ;;
                *)
                    log_error "Operating System Error: Detected OS '${ID:-unknown}' (${PRETTY_NAME:-unknown}). This utility is designed exclusively for Ubuntu, Debian, or Linux Mint."
                    exit 1
                    ;;
            esac
            ;;
    esac
else
    log_error "Operating System Error: /etc/os-release not found."
    exit 1
fi

# ------------------------------------------------------------------------------
# 2. SOURCE SYSTEM ENVIRONMENT SETTINGS
# ------------------------------------------------------------------------------
# Objective: Load platform variable scopes, custom toolchain bins, and script pointers.
# Data Flow: Imports definitions from settings.sh and sysenv.sh (e.g. $SYS_SCRIPTS).
# ------------------------------------------------------------------------------
# Sourced settings provide base path, environment, and variables like $SYS_SCRIPTS
if [ -f /opt/scripts/settings.sh ]; then
    # shellcheck disable=SC1091
    source /opt/scripts/settings.sh
elif [ -n "${SUDO_USER:-}" ] && [ -f "/home/${SUDO_USER}/scripts/settings.sh" ]; then
    # shellcheck disable=SC1090,SC1091
    source "/home/${SUDO_USER}/scripts/settings.sh"
elif [ -n "${HOME:-}" ] && [ -f "${HOME}/scripts/settings.sh" ]; then
    # shellcheck disable=SC1090,SC1091
    source "${HOME}/scripts/settings.sh"
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
if [ -z "${SYS_SCRIPTS:-}" ]; then
    if [ -f "${SCRIPT_DIR}/ubuntu_kernel_updater.sh" ]; then
        SYS_SCRIPTS="${SCRIPT_DIR}"
    else
        SYS_SCRIPTS="/opt/scripts"
    fi
fi

# ------------------------------------------------------------------------------
# 3. CONFIGURE NODE IDENTIFIERS & PARAMETER HARDENING
# ------------------------------------------------------------------------------
# Objective: Sanitize hostname parameters and configure package manager options.
# Data Flow: Sanitizes hostname into SAFE_HOSTNAME. Stores options in APT_OPTS array.
# ------------------------------------------------------------------------------
# Sanitize hostname to prevent malicious word splitting or character injections
SAFE_HOSTNAME=$( (hostname -s 2>/dev/null || uname -n || echo "localhost") | tr -dc 'a-zA-Z0-9_-')
NODE_TAG="PRD|prd|wks|${SAFE_HOSTNAME}"
APT_OPTS=(-qy -o DPkg::Lock::Timeout=120 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -o APT::Get::Always-Include-Phased-Updates=true -o Acquire::http::No-Cache=true -o Acquire::http::Max-Age=0)
APT_REPO_BASE="/etc/apt"
APT_AUTO_PROC="apt-news.service esm-cache.service motd-news.service motd-news.timer ubuntu-advantage.service"
MOTD_UPDATE_BASE="/etc/update-motd.d"

# Helper function to print unified formatted section headers using pure Bash string expansion
print_header() {
    local title=$1
    local tag=${NODE_TAG}
    local formatted_title="${title}->${tag}"
    local total_len=75
    local current_len=${#formatted_title}
    local fill_len=$((total_len - current_len - 5))
    if [ "$fill_len" -lt 1 ]; then fill_len=1; fi
    
    printf '_____%s' "${formatted_title}"
    local fill
    printf -v fill "%0${fill_len}d" 0
    echo "${fill//0/_}"
}

# ------------------------------------------------------------------------------
# 4. TRIGGER BACKGROUND TASKS (PARALLELIZATION OPTIMIZATION)
# ------------------------------------------------------------------------------
# Objective: Asynchronously update Flatpak dependencies concurrently with APT updates.
# Data Flow: Launches background process, logs status to flatpak_upgrade.log, returns PID.
# ------------------------------------------------------------------------------
# Flatpak update operates on its own sandboxed repository database and doesn't lock APT frontend.
# We execute it in parallel to minimize total upgrade run time.
FLATPAK_PID=""
if command -v flatpak >/dev/null 2>&1; then
    log_file="/var/log/flatpak_upgrade.log"
    log_info "Starting background Flatpak updates (logging to ${log_file})..."
    flatpak upgrade -y >"${log_file}" 2>&1 &
    FLATPAK_PID=$!
fi

# ------------------------------------------------------------------------------
# 4.5. LOCK CONTENTION INSPECTION & AUTOMATIC UPGRADE REMEDIATION
# ------------------------------------------------------------------------------
# Objective: Inspect active APT lock holders, automatically remedy background
#            auto-upgrades upon collision, and execute explicit --disable-autoupgrades requests.
# ------------------------------------------------------------------------------
inspect_and_remedy_lock_contention() {
    local lock_frontend="/var/lib/dpkg/lock-frontend"
    local lock_lists="/var/lib/apt/lists/lock"
    local contention=false
    local reason=""
    local pids_info=""

    for lf in "$lock_frontend" "$lock_lists"; do
        if [ -f "$lf" ]; then
            local detected_pids=""
            if command -v fuser >/dev/null 2>&1; then
                detected_pids=$(fuser "$lf" 2>/dev/null || true)
            elif command -v lsof >/dev/null 2>&1; then
                detected_pids=$(lsof -t "$lf" 2>/dev/null || true)
            fi
            if [ -n "$detected_pids" ]; then
                for pid in $detected_pids; do
                    if [ -d "/proc/$pid" ]; then
                        local cmd
                        cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || ps -p "$pid" -o comm= 2>/dev/null || true)
                        pids_info="${pids_info} [PID ${pid}: ${cmd}]"
                        if echo "$cmd" | grep -qiE "unattended-upgr|apt\.systemd\.daily|packagekit|apt-daily"; then
                            contention=true
                            reason="background auto-updater (${cmd})"
                        fi
                    fi
                done
            fi
        fi
    done

    # Fallback check via process table if lock tools did not catch PIDs but an updater is running
    if [ "$contention" = false ] && command -v pgrep >/dev/null 2>&1; then
        local bg_pids
        bg_pids=$(pgrep -f "unattended-upgr|apt\.systemd\.daily|packagekitd" 2>/dev/null || true)
        if [ -n "$bg_pids" ]; then
            contention=true
            reason="active background auto-update service (PIDs: ${bg_pids})"
        fi
    fi

    if [ "$contention" = true ]; then
        log_warn "APT lock contention detected: Held by ${reason}."
        log_warn "Automatically activating --disable-autoupgrades to prevent future lock collisions on this system."
        DISABLE_AUTOUPGRADES=true
    elif [ -n "$pids_info" ]; then
        log_info "APT lock is currently held by non-autoupgrade process:${pids_info}. Waiting up to 120s for release..."
    fi
}

disable_autoupgrades() {
    print_header "DISABLE-AUTOUPGRADES"
    log_info "Permanently disabling automatic background APT timers and services..."
    if command -v systemctl >/dev/null 2>&1; then
        local auto_services="apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service unattended-upgrades.service"
        for s in ${auto_services}; do
            systemctl stop "$s" >/dev/null 2>&1 || true
            systemctl disable "$s" >/dev/null 2>&1 || true
            systemctl mask "$s" >/dev/null 2>&1 || true
        done
    fi
    if [ -d /etc/apt/apt.conf.d ]; then
        log_info "Configuring /etc/apt/apt.conf.d to disable periodic APT actions..."
        cat << 'EOF' > /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "0";
APT::Periodic::Unattended-Upgrade "0";
EOF
        if [ -f /etc/apt/apt.conf.d/10periodic ]; then
            cat << 'EOF' > /etc/apt/apt.conf.d/10periodic
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "0";
APT::Periodic::Unattended-Upgrade "0";
EOF
        fi
    fi
    log_info "Automatic background upgrades have been permanently disabled and masked."
    if [ "$ONLY_DISABLE_AUTOUPGRADES" = true ]; then
        log_info "Completed --disable-autoupgrades-only request. Exiting."
        exit 0
    fi
}

# Run lock inspection (auto-activates DISABLE_AUTOUPGRADES if held by background updater)
inspect_and_remedy_lock_contention

if [ "$DISABLE_AUTOUPGRADES" = true ]; then
    disable_autoupgrades
fi

# ------------------------------------------------------------------------------
# 5. APT PACKAGE LIST SYNCED
# ------------------------------------------------------------------------------
# Objective: Clean old repository archives and fetch fresh database mappings.
# ------------------------------------------------------------------------------
print_header "APT-CACHE-SYNC"
apt-get "${APT_OPTS[@]}" clean
apt-get "${APT_OPTS[@]}" update

# ------------------------------------------------------------------------------
# 6. RUN SYSTEM UPGRADES
# ------------------------------------------------------------------------------
# Objective: Upgrade standard packages, then run distribution upgrades to handle kernels.
# ------------------------------------------------------------------------------
print_header "APT-PATCH-OS"
apt-get "${APT_OPTS[@]}" upgrade

print_header "APT-PATCH-KERNEL"
apt-get "${APT_OPTS[@]}" dist-upgrade

# ------------------------------------------------------------------------------
# 7. CLEANUP TASKS
# ------------------------------------------------------------------------------
# Objective: Remove telemetry cache points, repair failed installations, clean orphans.
# Data Flow: Queries dpkg-query for unpacked / config-files states and purges targets.
# ------------------------------------------------------------------------------
print_header "APT-PATCH-CLEANUP"
rm -f "${MOTD_UPDATE_BASE}/88-esm-announce" "${APT_REPO_BASE}/apt.conf.d/20apt-esm-hook.conf"

# Disable ESM ads, motd tickers, and telemetry processes safely if systemctl exists
if command -v systemctl >/dev/null 2>&1; then
    for s in ${APT_AUTO_PROC}; do
        # Stop and mask the service safely (using || true to prevent set -e aborts if service is not found)
        systemctl stop "$s" >/dev/null 2>&1 || true
        systemctl mask "$s" >/dev/null 2>&1 || true
    done
fi

# Attempt to resolve / configure packages left in unconfigured states before cleanup
log_info "Attempting to configure any unpacked packages..."
dpkg --configure -a || true

log_info "Autoremove and clean orphan packages"
for a in autoremove autoclean; do
    apt-get "${APT_OPTS[@]}" "$a"
done

# Safe checks for empty package lists before running purge commands
# Prevents syntax failure when dpkg query yields empty lists
# Using dpkg-query instead of dpkg -l to prevent terminal width truncation issues
iu_pkgs=$(dpkg-query -f '${db:Status-Status} ${Package}\n' -W 2>/dev/null | awk '/^unpacked/ {print $2}')
if [ -n "$iu_pkgs" ]; then
    echo "$iu_pkgs" | xargs -r apt-get "${APT_OPTS[@]}" remove --purge
fi

rc_pkgs=$(dpkg-query -f '${db:Status-Status} ${Package}\n' -W 2>/dev/null | awk '/^config-files/ {print $2}')
if [ -n "$rc_pkgs" ]; then
    echo "$rc_pkgs" | xargs -r apt-get "${APT_OPTS[@]}" remove --purge
fi

# Remove unwanted package (crashes xorg if 3d acceleration is not available)
if dpkg-query -W -f='${Status}\n' gstreamer1.0-vaapi 2>/dev/null | grep -q "ok installed"; then
    apt-get "${APT_OPTS[@]}" remove gstreamer1.0-vaapi
fi

# ------------------------------------------------------------------------------
# 8. SYNCHRONIZE AND AWAIT BACKGROUND PROCESSES
# ------------------------------------------------------------------------------
# Objective: Join asynchronous Flatpak background tasks before finishing execution.
# Data Flow: Waits on $FLATPAK_PID process.
# ------------------------------------------------------------------------------
if [ -n "$FLATPAK_PID" ]; then
    log_info "Waiting for background Flatpak updates to complete..."
    wait "$FLATPAK_PID" || log_warn "Flatpak upgrade exited with non-zero status."
fi

# ------------------------------------------------------------------------------
# 9. MAINLINE KERNEL UPDATE
# ------------------------------------------------------------------------------
# Objective: Chain-load the custom standalone mainline kernel updater utility.
# ------------------------------------------------------------------------------
# Execute the custom mainline deployment utility (skipped in WSL environments)
if is_wsl; then
    log_info "WSL environment detected (WSL kernel is managed by Windows host). Skipping mainline kernel updater."
elif [ -f "${SYS_SCRIPTS}/ubuntu_kernel_updater.sh" ]; then
    "${SYS_SCRIPTS}/ubuntu_kernel_updater.sh"
    echo -e "\nExecute after reboot to purge obsolete kernels:"
    echo "   [1] sudo ${SYS_SCRIPTS}/ubuntu_kernel_updater.sh --purge"
elif [ -f "${SCRIPT_DIR}/ubuntu_kernel_updater.sh" ]; then
    "${SCRIPT_DIR}/ubuntu_kernel_updater.sh"
    echo -e "\nExecute after reboot to purge obsolete kernels:"
    echo "   [1] sudo ${SCRIPT_DIR}/ubuntu_kernel_updater.sh --purge"
else
    log_warn "ubuntu_kernel_updater.sh not found at ${SYS_SCRIPTS}. Skipping mainline kernel update."
fi
