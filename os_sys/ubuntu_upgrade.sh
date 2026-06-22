#!/bin/bash
# ==============================================================================
# FILE: ubuntu_upgrade.sh
# VERSION: 1.0.0
# DATE: 2026-06-22
#
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
# ----------------------------------------
# /opt/scripts/ubuntu_upgrade.sh
# v1.0.7xg  2026/06/18  XDG / MIS Center
# ----------------------------------------
set -euo pipefail

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

# Ensure running on a supported Ubuntu, Debian, or Linux Mint distribution
if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}" in
        ubuntu|debian|linuxmint)
            # Supported OS
            ;;
        *)
            log_error "Operating System Error: This utility is designed exclusively for Ubuntu, Debian, or Linux Mint."
            exit 1
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
# shellcheck disable=SC1091
source /opt/scripts/settings.sh

# ------------------------------------------------------------------------------
# 3. CONFIGURE NODE IDENTIFIERS & PARAMETER HARDENING
# ------------------------------------------------------------------------------
# Objective: Sanitize hostname parameters and configure package manager options.
# Data Flow: Sanitizes hostname into SAFE_HOSTNAME. Stores options in APT_OPTS array.
# ------------------------------------------------------------------------------
# Sanitize hostname to prevent malicious word splitting or character injections
SAFE_HOSTNAME=$( (hostname -s 2>/dev/null || uname -n || echo "localhost") | tr -dc 'a-zA-Z0-9_-')
NODE_TAG="PRD|prd|wks|${SAFE_HOSTNAME}"
APT_OPTS=(-qy -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -o APT::Get::Always-Include-Phased-Updates=true)
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
    # shellcheck disable=SC2086
    apt-get "${APT_OPTS[@]}" remove --purge $iu_pkgs
fi

rc_pkgs=$(dpkg-query -f '${db:Status-Status} ${Package}\n' -W 2>/dev/null | awk '/^config-files/ {print $2}')
if [ -n "$rc_pkgs" ]; then
    # shellcheck disable=SC2086
    apt-get "${APT_OPTS[@]}" remove --purge $rc_pkgs
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
# Execute the custom mainline deployment utility
"${SYS_SCRIPTS}/ubuntu_kernel_updater.sh"

echo -e "\nExecute after reboot to purge obsolete kernels:"
echo "   [1] sudo ${SYS_SCRIPTS}/ubuntu_kernel_updater.sh --purge"
