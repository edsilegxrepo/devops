#!/bin/bash
# ------------------------------------------------------------------------------
# /opt/scripts/proxmox_update.sh
# v2.0.0xg  2026/11/06  XdG / MIS Center
# ------------------------------------------------------------------------------
# ==============================================================================
# SUMMARY & OBJECTIVES:
# ------------------------------------------------------------------------------
# Hardened Automated Proxmox VE Package Maintenance & Kernel Lifecycle Utility.
# Engineered to prevent root (/) partition exhaustion and initramfs truncation
# failures during distribution upgrades on Proxmox Virtual Environment nodes.
#
# Key Features & Safeguards:
#   1. Pre-Flight Storage Safeguards:
#      - Verifies >= 2048 MB free on / and >= 250 MB on /boot prior to touching APT.
#      - Automatically invokes max_root.sh to reclaim space if thresholds are low.
#      - Fails safely BEFORE package downloads if space remains critically low.
#   2. Pre-Purge APT Archives:
#      - Executes 'apt-get clean' BEFORE 'apt-get update' so stale .deb archives
#        do not steal capacity during the download phase.
#   3. Strict Proxmox Upgrade Semantics:
#      - Enforces 'apt-get dist-upgrade' exclusively (prohibits 'apt-get upgrade'
#        which causes partial broken dependency states across pve-manager/qemu).
#      - Non-interactive execution (DEBIAN_FRONTEND=noninteractive, DPkg timeouts).
#   4. Process & Concurrency Locking:
#      - Exclusive file lock (/run/proxmox_update.lock).
#      - 4-point APT/dpkg transaction lock inspection via lib/system.sh.
#   5. Safe PVE Kernel Lifecycle & Pruning (--purge-kernels):
#      - Identifies installed pve-kernel-* and proxmox-kernel-* packages.
#      - Strictly protects the running kernel (uname -r) and latest fallback kernel.
#      - Safely purges superseded kernel packages to prevent disk leakage.
#   6. Bootloader & Kernel Synchronization:
#      - Synchronizes ESP/GRUB via proxmox-boot-tool refresh or update-grub.
#   7. Dual Kernel-Naming Reboot Detection:
#      - Detects both legacy vmlinuz-*-pve and modern proxmox-kernel-* formats.
#   8. Modular Tuning Integration:
#      - Safely detects and executes /opt/scripts/proxmox_tune.sh if present.
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# 1. Environment & Universal Library Initialization
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

# Script configuration defaults
ROOT_MIN_FREE_MB=2048
BOOT_MIN_FREE_MB=250
DRY_RUN=false
FORCE=false
DO_MAX_ROOT=false
DO_PURGE_KERNELS=false
TUNE_ONLY=false
SKIP_TUNE=false

# ------------------------------------------------------------------------------
# 2. CLI Usage & Argument Parsing
# ------------------------------------------------------------------------------
show_usage() {
    cat << EOF
Usage: sudo $(basename "$0") [OPTIONS]

Hardened Proxmox VE Package Maintenance & Kernel Lifecycle Utility.

Options:
  -h, --help                Show this help documentation and exit.
  -n, --dry-run, --detect   Simulate package updates and inspect system state without modifications.
  -f, --force               Bypass storage capacity checks and proceed despite warnings.
  --max-root                Run max_root.sh before upgrade to reclaim root partition headroom.
  --purge-kernels           Safely purge obsolete PVE kernels (preserves active & newest kernels).
  --tune-only               Execute /opt/scripts/proxmox_tune.sh and exit immediately.
  --skip-tune               Skip execution of the Proxmox tuning script.

Storage Safety Thresholds:
  - Root (/) Minimum Free  : ${ROOT_MIN_FREE_MB} MB
  - Boot (/boot) Min Free  : ${BOOT_MIN_FREE_MB} MB

Log File:
  /var/log/proxmox_update.log
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_usage
            exit 0
            ;;
        -n|--dry-run|--detect)
            DRY_RUN=true
            shift
            ;;
        -f|--force)
            FORCE=true
            shift
            ;;
        --max-root)
            DO_MAX_ROOT=true
            shift
            ;;
        --purge-kernels)
            DO_PURGE_KERNELS=true
            shift
            ;;
        --tune-only)
            TUNE_ONLY=true
            shift
            ;;
        --skip-tune)
            SKIP_TUNE=true
            shift
            ;;
        *)
            echo "[-] Usage Error: Unknown argument '$1'" >&2
            show_usage >&2
            exit 1
            ;;
    esac
done

# Initialize centralized logging
init_system_logging "/var/log/proxmox_update.log"

# Enforce administrator context and validate Debian/Proxmox OS family
require_root
validate_os "debian"

# ------------------------------------------------------------------------------
# 3. Environment & Node Identity Configuration
# ------------------------------------------------------------------------------
NODE_TAG="PVE|$(get_safe_hostname)"

# ------------------------------------------------------------------------------
# 4. Proxmox Helper Functions
# ------------------------------------------------------------------------------
run_proxmox_tune() {
    local tune_script="/opt/scripts/proxmox_tune.sh"
    [[ -f "${tune_script}" ]] || tune_script="${SCRIPT_DIR}/proxmox_tune.sh"

    print_header "PROXMOX-TUNE"
    if [[ -f "${tune_script}" ]]; then
        log_info "Executing Proxmox post-update tuning script: ${tune_script}..."
        if [[ "${DRY_RUN}" == "true" ]]; then
            log_info "  -> [DRY-RUN] Would execute ${tune_script}"
        else
            bash "${tune_script}" || log_warn "Proxmox tuning script returned non-zero status ($?)."
            log_info "Tuning script execution finished."
        fi
    else
        log_info "No custom tuning script found at ${tune_script}. Skipping tuning phase."
    fi
}

get_installed_pve_kernels() {
    local -a kernels=()
    local f kver
    for f in /boot/vmlinuz-*; do
        [[ -e "${f}" ]] || continue
        if [[ -f "${f}" && ! -L "${f}" && ! "${f}" == *.tmp && ! "${f}" == *.bak ]]; then
            kver="$(basename "${f}" | sed 's/^vmlinuz-//')"
            if [[ "${kver}" =~ (pve|proxmox) ]]; then
                kernels+=("${kver}")
            fi
        fi
    done
    # Fallback to any vmlinuz in /boot if not specifically matching pve pattern
    if [[ ${#kernels[@]} -eq 0 ]]; then
        for f in /boot/vmlinuz-*; do
            [[ -e "${f}" ]] || continue
            if [[ -f "${f}" && ! -L "${f}" && ! "${f}" == *.tmp && ! "${f}" == *.bak ]]; then
                kernels+=("$(basename "${f}" | sed 's/^vmlinuz-//')")
            fi
        done
    fi
    printf "%s\n" "${kernels[@]}"
}

get_sorted_pve_kernels() {
    resolve_version_sort_cmd
    local raw
    raw="$(get_installed_pve_kernels)"
    if [[ -z "${raw}" ]]; then
        echo ""
        return 0
    fi
    echo "${raw}" | "${SORT_CMD[@]}" | uniq
}

refresh_bootloader() {
    log_info "Synchronizing bootloader and boot EFI partitions..."
    if command -v proxmox-boot-tool >/dev/null 2>&1 && [[ -d /etc/kernel/pve-efiboot-uuids || -f /etc/kernel/proxmox-boot-uuids ]]; then
        if [[ "${DRY_RUN}" == "true" ]]; then
            log_info "  -> [DRY-RUN] Would execute 'proxmox-boot-tool refresh'"
        else
            log_info "  -> Executing 'proxmox-boot-tool refresh'..."
            proxmox-boot-tool refresh 2>&1 | tee -a "${LOG_FILE}" || log_warn "proxmox-boot-tool refresh returned non-zero status."
        fi
    elif command -v update-grub >/dev/null 2>&1; then
        if [[ "${DRY_RUN}" == "true" ]]; then
            log_info "  -> [DRY-RUN] Would execute 'update-grub'"
        else
            log_info "  -> Executing 'update-grub'..."
            update-grub 2>&1 | tee -a "${LOG_FILE}" || log_warn "update-grub returned non-zero status."
        fi
    fi
}

purge_superseded_kernels() {
    print_header "PVE-KERNEL-PURGE"
    local running_kver
    running_kver="$(uname -r)"

    local sorted_kernels
    sorted_kernels="$(get_sorted_pve_kernels)"

    if [[ -z "${sorted_kernels}" ]]; then
        log_info "No installed kernel images found in /boot to analyze."
        return 0
    fi

    local -a kernel_list=()
    while IFS= read -r kline; do
        [[ -n "${kline}" ]] && kernel_list+=("${kline}")
    done <<< "${sorted_kernels}"

    local total_kernels=${#kernel_list[@]}
    if [[ ${total_kernels} -le 2 ]]; then
        log_info "Installed kernel count (${total_kernels}) <= 2. No obsolete kernels eligible for purging."
        log_info "  -> Active kernel : ${running_kver}"
        log_info "  -> Installed     : ${kernel_list[*]}"
        return 0
    fi

    local latest_kver="${kernel_list[$((total_kernels - 1))]}"
    log_info "Evaluating kernel retention (Active: ${running_kver} | Latest: ${latest_kver}):"

    local -a candidates=()
    for (( i=0; i < total_kernels - 1; i++ )); do
        local cand="${kernel_list[$i]}"
        if [[ "${cand}" != "${running_kver}" && "${cand}" != "${latest_kver}" ]]; then
            candidates+=("${cand}")
        fi
    done

    if [[ ${#candidates[@]} -eq 0 ]]; then
        log_info "All ${total_kernels} installed kernels are currently protected (active or latest). None purged."
        return 0
    fi

    log_info "Identified ${#candidates[@]} superseded kernel version(s) eligible for removal: ${candidates[*]}"

    local -a pkgs_to_purge=()
    for cand in "${candidates[@]}"; do
        local cand_pkgs
        cand_pkgs="$(dpkg-query -f '${Package} ${Status}\n' -W "*${cand}*" 2>/dev/null | awk '/install ok installed/ {print $1}' || true)"
        if [[ -n "${cand_pkgs}" ]]; then
            while IFS= read -r pkg; do
                # Safety check: do not match meta-packages without the specific release string
                if [[ "${pkg}" =~ (pve-kernel|proxmox-kernel|pve-headers|proxmox-headers|pve-modules|proxmox-modules) ]]; then
                    pkgs_to_purge+=("${pkg}")
                fi
            done <<< "${cand_pkgs}"
        fi
    done

    if [[ ${#pkgs_to_purge[@]} -eq 0 ]]; then
        log_info "No installed Debian packages found matching eligible obsolete kernels."
        return 0
    fi

    log_info "Packages identified for removal: ${pkgs_to_purge[*]}"
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "  -> [DRY-RUN] Would purge: ${pkgs_to_purge[*]}"
    else
        log_info "Purging ${#pkgs_to_purge[@]} obsolete kernel package(s)..."
        DEBIAN_FRONTEND=noninteractive apt-get -y purge "${pkgs_to_purge[@]}" 2>&1 | tee -a "${LOG_FILE}"
        refresh_bootloader
    fi
}

check_kernel_reboot_status() {
    print_header "REBOOT-STATUS"
    local running_kver
    running_kver="$(uname -r)"

    local sorted_kernels
    sorted_kernels="$(get_sorted_pve_kernels)"

    local latest_kver=""
    if [[ -n "${sorted_kernels}" ]]; then
        latest_kver="$(echo "${sorted_kernels}" | tail -n 1)"
    fi

    check_system_reboot_status "${latest_kver}"
}

# ------------------------------------------------------------------------------
# 5. Handle Tuning Only Request
# ------------------------------------------------------------------------------
if [[ "${TUNE_ONLY}" == "true" ]]; then
    run_proxmox_tune
    exit 0
fi

# ------------------------------------------------------------------------------
# 6. Concurrency Locks
# ------------------------------------------------------------------------------
acquire_script_lock "/run/proxmox_update.lock"

print_header "LOCK-INSPECTION"
inspect_and_wait_for_package_locks 120 "${DRY_RUN}"

# ------------------------------------------------------------------------------
# 7. Pre-Flight Storage Capacity Safeguards & max_root.sh Integration
# ------------------------------------------------------------------------------
print_header "DISK-CAPACITY-CHECK"

root_free_mb="$(get_free_mb "/")"
boot_path="/boot"
[[ -d "${boot_path}" ]] || boot_path="/"
boot_free_mb="$(get_free_mb "${boot_path}")"

max_root_bin="${SCRIPT_DIR}/max_root.sh"
[[ -f "${max_root_bin}" ]] || max_root_bin="/opt/scripts/max_root.sh"

# If space is below minimum thresholds or --max-root was explicitly passed, execute max_root.sh
if [[ ${root_free_mb} -lt ${ROOT_MIN_FREE_MB} || ${boot_free_mb} -lt ${BOOT_MIN_FREE_MB} || "${DO_MAX_ROOT}" == "true" ]]; then
    if [[ -f "${max_root_bin}" ]]; then
        log_warn "Storage capacity check or --max-root triggered pre-upgrade disk space optimization."
        log_info "Executing ${max_root_bin} to maximize free headroom on root (/)..."
        if [[ "${DRY_RUN}" == "true" ]]; then
            bash "${max_root_bin}" --dry-run
        else
            bash "${max_root_bin}"
        fi
    else
        log_warn "max_root.sh utility not found at ${max_root_bin}. Skipping automated space reclamation."
    fi
fi

# Audit storage capacity against minimum safe thresholds
check_storage_capacity "${ROOT_MIN_FREE_MB}" "${BOOT_MIN_FREE_MB}" "${FORCE}" "${DRY_RUN}" "$(basename "$0")" "$(basename "$0") --max-root --purge-kernels"

# ------------------------------------------------------------------------------
# 8. APT Pre-Clean & Repository Index Sync
# ------------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive

print_header "APT-PRE-CLEAN"
log_info "Wiping downloaded .deb archive cache prior to update to ensure maximum headroom..."
if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "  -> [DRY-RUN] Would execute 'apt-get clean'"
else
    apt-get "${DEFAULT_APT_OPTS[@]}" clean
fi

print_header "APT-CACHE-SYNC"
log_info "Synchronizing package lists from Proxmox & Debian repositories..."
if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "  -> [DRY-RUN] Would synchronize package repository indices ('apt-get update')"
else
    apt-get "${DEFAULT_APT_OPTS[@]}" update 2>&1 | tee -a "${LOG_FILE}"
fi

# ------------------------------------------------------------------------------
# 9. Distribution Upgrade (Strict Proxmox dist-upgrade Policy)
# ------------------------------------------------------------------------------
# Proxmox VE documentation explicitly mandates 'dist-upgrade' (or 'full-upgrade')
# and prohibits plain 'upgrade' to ensure kernel/qemu/cluster dependency integrity.
print_header "PROXMOX-DIST-UPGRADE"
log_info "Executing Proxmox distribution upgrade (dist-upgrade)..."
if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "  -> [DRY-RUN] Simulating distribution upgrade..."
    apt-get -s dist-upgrade 2>&1 | tee -a "${LOG_FILE}"
else
    apt-get "${DEFAULT_APT_OPTS[@]}" dist-upgrade 2>&1 | tee -a "${LOG_FILE}"
fi

# ------------------------------------------------------------------------------
# 10. Post-Upgrade Maintenance & Orphan Cleanup
# ------------------------------------------------------------------------------
print_header "POST-UPGRADE-CLEANUP"
repair_unconfigured_packages "${DRY_RUN}"
clean_apt_cache_and_orphans "${DRY_RUN}"
purge_residual_configs "${DRY_RUN}"

# Optional Kernel Pruning
if [[ "${DO_PURGE_KERNELS}" == "true" ]]; then
    purge_superseded_kernels
fi

# ------------------------------------------------------------------------------
# 11. Proxmox Post-Update Tuning Script Execution
# ------------------------------------------------------------------------------
if [[ "${SKIP_TUNE}" == "false" ]]; then
    run_proxmox_tune
fi

# ------------------------------------------------------------------------------
# 12. Reboot Inspection & Storage Summary
# ------------------------------------------------------------------------------
check_kernel_reboot_status

print_header "UPGRADE-COMPLETE"
log_info "Proxmox package update cycle finished successfully."
print_storage_summary "${boot_path}"
