#!/bin/bash
# ----------------------------------------
# /opt/scripts/ubuntu_upgrade.sh
# v1.1.0xg  2026/11/06  XDG / MIS Center
# ----------------------------------------

# ==============================================================================
# SUMMARY & OBJECTIVES:
# ------------------------------------------------------------------------------
# Robust Automated System Upgrade & Hardening Utility (Debian/Ubuntu/Linux Mint)
# Designed for safe, non-interactive, and complete package state maintenance:
#   1. Environment & Privilege Verification (ensuring root context and OS validation).
#   2. Non-interactive frontend enforcement to block interactive package configuration prompts.
#   3. Comprehensive APT/dpkg transaction lock inspection, locker PID auditing, and auto-remediation.
#   4. Pre-flight storage capacity checks on / and /boot to prevent initramfs ENOSPC failures.
#   5. Background Flatpak package updates run in parallel to minimize run time.
#   6. APT Cache synchronization and OS package distribution upgrades.
#   7. Safety configuration/repair of partially installed (unconfigured) packages.
#   8. Cleanup of obsolete packages, configuration files, and unwanted services.
#   9. Chain-loading the Mainline Kernel Deployment pipeline with post-upgrade storage metrics.
#
# CORE COMPONENTS & FUNCTIONAL MODULES:
# ------------------------------------------------------------------------------
#   - Shared Foundation Library: Sourced from lib/debian_sys.sh for centralized logging,
#     root enforcement, OS checks, storage capacity guards, lock inspection, and auto-upgrades.
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
  -f, --force                   Bypass pre-flight checks (e.g. /boot and / disk capacity warnings).
  --max-root                    Run max_root.sh before upgrade to reclaim root partition headroom.
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
FORCE_FLAG=false
DO_MAX_ROOT=false

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -f|--force)
            FORCE_FLAG=true
            shift
            ;;
        --max-root)
            DO_MAX_ROOT=true
            shift
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
# 1. ENVIRONMENT & LIBRARY INITIALIZATION
# ------------------------------------------------------------------------------
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
LIB_SYSTEM="${SCRIPT_DIR}/lib/system.sh"
[[ -f "${LIB_SYSTEM}" ]] || LIB_SYSTEM="/opt/scripts/lib/system.sh"
if [[ ! -f "${LIB_SYSTEM}" ]]; then
    echo "[-] Fatal Error: Universal system foundation library not found at ${LIB_SYSTEM}" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "${LIB_SYSTEM}"

# Initialize logging architecture
init_debian_logging "/var/log/ubuntu_upgrade.log"

# Enforce administrator context and platform restrictions
require_root
validate_debian_os

# Ensure all APT transactions are non-interactive to block blocking configuration screens
export DEBIAN_FRONTEND=noninteractive

# Enforce script-wide exclusive locking to prevent concurrent executions
acquire_script_lock "/run/ubuntu_upgrade.lock"

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
NODE_TAG="PRD|prd|wks|$(get_safe_hostname)"
APT_OPTS=("${DEFAULT_APT_OPTS[@]}" -o APT::Get::Always-Include-Phased-Updates=true)
APT_REPO_BASE="/etc/apt"
APT_AUTO_PROC="apt-news.service esm-cache.service motd-news.service motd-news.timer ubuntu-advantage.service"
MOTD_UPDATE_BASE="/etc/update-motd.d"
BOOT_MIN_FREE_MB=100
ROOT_MIN_FREE_MB=1024

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
# 4.5. PRE-FLIGHT LOCK & STORAGE SAFEGUARDS
# ------------------------------------------------------------------------------
print_header "LOCK-INSPECTION"
# Run 4-point lock inspection & concurrency checks (with automatic remediation hook for background updaters)
inspect_and_wait_for_package_locks 120 false disable_autoupgrades

if [ "$DISABLE_AUTOUPGRADES" = true ]; then
    disable_autoupgrades "$ONLY_DISABLE_AUTOUPGRADES"
fi

print_header "DISK-CAPACITY-CHECK"
root_free_mb="$(get_free_mb "/")"
boot_path="/boot"
[[ -d "${boot_path}" ]] || boot_path="/"
boot_free_mb="$(get_free_mb "${boot_path}")"

max_root_bin="${SCRIPT_DIR}/max_root.sh"
[[ -f "${max_root_bin}" ]] || max_root_bin="/opt/scripts/max_root.sh"

if [[ (${root_free_mb} -lt ${ROOT_MIN_FREE_MB} || ${boot_free_mb} -lt ${BOOT_MIN_FREE_MB} || "${DO_MAX_ROOT}" == "true") && -f "${max_root_bin}" ]]; then
    log_warn "Storage capacity check or --max-root triggered pre-upgrade disk space optimization."
    log_info "Executing ${max_root_bin} to maximize free headroom on root (/)..."
    bash "${max_root_bin}"
fi

# Pre-flight filesystem capacity safeguards (/ and /boot)
check_storage_capacity "${ROOT_MIN_FREE_MB}" "${BOOT_MIN_FREE_MB}" "${FORCE_FLAG}" false "$(basename "$0")" "${SYS_SCRIPTS}/ubuntu_kernel_updater.sh --purge"

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

# Repair unconfigured/unpacked packages, autoremove orphans, and purge config-files
repair_unconfigured_packages false
clean_apt_cache_and_orphans false
purge_residual_configs false

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

# ------------------------------------------------------------------------------
# 10. REBOOT AUDIT & POST-UPGRADE STORAGE SUMMARY
# ------------------------------------------------------------------------------
print_header "REBOOT-STATUS"
check_system_reboot_status

print_header "UPGRADE-COMPLETE"
log_info "Upgrade tasks finished."
print_storage_summary "${boot_path}"
