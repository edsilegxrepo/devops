#!/usr/bin/env bash
# ==============================================================================
# Library:     /opt/scripts/lib/debian_sys.sh
# Version:     2.0.0  2026/11/06
# Standard:    DRY Architecture Framework (Debian/Ubuntu Domain Layer)
# Author:      DevOps Systems Administration <criticalsys.mis@gmail.com>
# Compatibility: Debian 12+ (Bookworm), Ubuntu 22.04+ (Jammy/Noble), Linux Mint
# Description: Production-hardened Debian/Ubuntu domain library building upon
#              lib/system.sh. Supplies Debian OS family validation, APT/dpkg
#              transaction lock inspection, auto-upgrade service disabling and
#              masking, and kernel boot symlink synchronization.
# ==============================================================================
set -euo pipefail
umask 022

# ------------------------------------------------------------------------------
# 1. Include Guard & System Foundation Assertion
# ------------------------------------------------------------------------------
# Debian domain layer must only be loaded via lib/system.sh auto-router
[[ -n "${_DEBIAN_SYS_LOADED:-}" ]] && return 0
_DEBIAN_SYS_LOADED=1

if [[ -z "${_SYSTEM_SH_LOADED:-}" ]]; then
    echo "[-] Fatal Error: debian_sys.sh must not be sourced directly. Source lib/system.sh instead." >&2
    return 1 2>/dev/null || exit 1
fi

# Default log file target for Debian operations
LOG_FILE="${LOG_FILE:-/var/log/debian_sys.log}"

# ------------------------------------------------------------------------------
# Function: init_debian_logging
# Purpose:  Initializes system logging with Debian-specific default path.
# ------------------------------------------------------------------------------
init_debian_logging() {
    init_system_logging "${1:-/var/log/debian_sys.log}"
}

# ------------------------------------------------------------------------------
# 2. Operating System Validation
# ------------------------------------------------------------------------------
validate_debian_os() {
    validate_os "debian"
}

resolve_version_sort_cmd() {
    if command -v linux-version >/dev/null 2>&1; then
        SORT_CMD=(linux-version sort)
    else
        SORT_CMD=(sort -V)
    fi
}

# ------------------------------------------------------------------------------
# 3. APT / dpkg Concurrency & Lock Management
# ------------------------------------------------------------------------------
inspect_and_wait_for_package_locks() {
    local max_wait="${1:-120}"
    local is_detect="${2:-false}"
    local on_bg_updater="${3:-}"

    local lock_files=(
        "/var/lib/dpkg/lock-frontend"
        "/var/lib/dpkg/lock"
        "/var/lib/apt/lists/lock"
        "/var/cache/apt/archives/lock"
    )

    log_info "Inspecting APT/dpkg transaction locks and active package managers..."
    local contention=false
    local bg_updater=false
    local reason=""
    local -a all_locker_pids=()

    for lf in "${lock_files[@]}"; do
        if [[ -f "${lf}" ]]; then
            local pids
            pids="$(get_lock_pids "${lf}")"
            if [[ -n "${pids}" ]]; then
                for pid in ${pids}; do
                    [[ "${pid}" == "$$" || "${pid}" == "${PPID:-0}" ]] && continue
                    all_locker_pids+=("${pid}")
                    if [[ -d "/proc/${pid}" ]]; then
                        local cmd
                        cmd="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || ps -p "${pid}" -o comm= 2>/dev/null || true)"
                        if echo "${cmd}" | grep -qiE "unattended-upgr|apt\.systemd\.daily|packagekit|apt-daily"; then
                            bg_updater=true
                            reason="background auto-updater [PID ${pid}: ${cmd}]"
                        else
                            contention=true
                            reason="active process [PID ${pid}: ${cmd}]"
                        fi
                    fi
                done
            fi
        fi
    done

    # Concurrency verification via process table
    local active_procs
    active_procs="$(get_active_pkg_managers)"
    if [[ -n "${active_procs}" ]]; then
        local filtered_procs
        filtered_procs="$(echo "${active_procs}" | awk -v pid="$$" -v ppid="${PPID:-0}" '$1 != pid && $1 != ppid')"
        if [[ -n "${filtered_procs}" ]]; then
            if echo "${filtered_procs}" | grep -qiE "unattended-upgr|apt\.systemd\.daily|packagekitd"; then
                bg_updater=true
                [[ -z "${reason}" ]] && reason="background auto-updater service"
            else
                contention=true
                [[ -z "${reason}" ]] && reason="active package manager process"
            fi
        fi
    fi

    # Deduplicate locker PIDs
    local -a unique_pids=()
    if [[ ${#all_locker_pids[@]} -gt 0 ]]; then
        read -r -a unique_pids <<< "$(printf '%s\n' "${all_locker_pids[@]}" | sort -u | tr '\n' ' ')"
    fi

    if [[ ${#unique_pids[@]} -gt 0 ]]; then
        log_warn "APT/dpkg lock actively held by process PID(s): ${unique_pids[*]}"
        ps -fp "${unique_pids[@]}" 2>/dev/null | tee -a "${LOG_FILE}" || true
    fi

    if [[ "${bg_updater}" == "true" ]]; then
        log_warn "APT lock contention detected: Held by ${reason}."
        if [[ -n "${on_bg_updater}" ]] && declare -F "${on_bg_updater}" >/dev/null 2>&1; then
            log_warn "Executing automatic remediation hook: ${on_bg_updater}..."
            "${on_bg_updater}"
        fi
    fi

    if [[ ${#unique_pids[@]} -gt 0 || "${contention}" == "true" || "${bg_updater}" == "true" ]]; then
        if [[ "${is_detect}" == "true" ]]; then
            log_warn "[DETECT] Active lock/concurrency detected. In execution mode, would wait up to ${max_wait}s for release."
            return 0
        fi

        log_info "Waiting up to ${max_wait}s for package manager transaction lock(s) to release..."
        local waited=0
        while [[ ${waited} -lt ${max_wait} ]]; do
            sleep 3
            waited=$((waited + 3))

            local still_locked=false
            for lf in "${lock_files[@]}"; do
                if [[ -n "$(get_lock_pids "${lf}")" ]]; then
                    still_locked=true
                    break
                fi
            done

            local cur_procs=""
            cur_procs="$(get_active_pkg_managers | awk -v pid="$$" -v ppid="${PPID:-0}" '$1 != pid && $1 != ppid' || true)"

            if [[ "${still_locked}" == "false" && -z "${cur_procs}" ]]; then
                log_info "Transaction lock released after ${waited}s. Proceeding."
                return 0
            fi

            if [[ $((waited % 15)) -eq 0 ]]; then
                log_info "Still waiting for locks to release (${waited}/${max_wait}s elapsed)..."
            fi
        done

        log_error "Lock acquisition timeout (${max_wait}s expired). APT/dpkg locks are still held."
        log_error "Cannot proceed safely without risking package database corruption."
        exit 1
    else
        log_info "No active transaction locks detected. Package manager locks are clear."
    fi
    return 0
}

# ------------------------------------------------------------------------------
# 4. Background Auto-Upgrades Remediation
# ------------------------------------------------------------------------------
disable_autoupgrades() {
    local only_disable="${1:-false}"
    log_info "Permanently disabling automatic background APT timers and services..."
    if command -v systemctl >/dev/null 2>&1; then
        local auto_services="apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service unattended-upgrades.service"
        for s in ${auto_services}; do
            systemctl stop "$s" >/dev/null 2>&1 || true
            systemctl disable "$s" >/dev/null 2>&1 || true
            systemctl mask "$s" >/dev/null 2>&1 || true
        done
    fi
    if [[ -d /etc/apt/apt.conf.d ]]; then
        log_info "Configuring /etc/apt/apt.conf.d to disable periodic APT actions..."
        cat << 'EOF' > /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "0";
APT::Periodic::Unattended-Upgrade "0";
EOF
        if [[ -f /etc/apt/apt.conf.d/10periodic ]]; then
            cat << 'EOF' > /etc/apt/apt.conf.d/10periodic
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "0";
APT::Periodic::Unattended-Upgrade "0";
EOF
        fi
    fi
    log_info "Automatic background upgrades have been permanently disabled and masked."
    if [[ "${only_disable}" == "true" ]]; then
        log_info "Completed --disable-autoupgrades-only request. Exiting."
        exit 0
    fi
}

# ------------------------------------------------------------------------------
# 5. Kernel Boot Symlinks Synchronization
# ------------------------------------------------------------------------------
update_boot_symlinks() {
    log_info "Updating system boot symlinks..."

    resolve_version_sort_cmd

    # 1. Gather all kernel versions where BOTH vmlinuz and initrd.img exist
    local -a versions=()
    local f kver
    for f in /boot/vmlinuz-*; do
        [[ -e "${f}" ]] || continue
        if [[ -f "${f}" && ! -L "${f}" && ! "${f}" == *.tmp && ! "${f}" == *.bak ]]; then
            kver="$(basename "${f}" | sed 's/^vmlinuz-//')"
            if [[ -f "/boot/initrd.img-${kver}" ]]; then
                versions+=("${kver}")
            else
                log_warn "Kernel image /boot/vmlinuz-${kver} exists, but matching /boot/initrd.img-${kver} is missing. Ignoring this version for symlink safety."
            fi
        fi
    done

    local num_kernels=${#versions[@]}
    if [[ ${num_kernels} -eq 0 ]]; then
        log_warn "No valid kernel versions (with matching initrd) found in /boot. Skipping symlink updates."
        return 0
    fi

    # 2. Sort versions in descending order (newest first)
    local sorted_versions
    sorted_versions="$(printf "%s\n" "${versions[@]}" | "${SORT_CMD[@]}" | tac | uniq)"

    local -a sorted_arr=()
    local line
    while read -r line; do
        if [[ -n "${line}" ]]; then
            sorted_arr+=("${line}")
        fi
    done <<< "${sorted_versions}"

    local num_sorted=${#sorted_arr[@]}
    if [[ ${num_sorted} -eq 0 ]]; then
        log_warn "No sorted kernel versions resolved. Skipping symlink updates."
        return 0
    fi

    local newest_ver="${sorted_arr[0]}"
    log_info "Newest valid kernel version resolved: ${newest_ver}"

    update_link "/boot/vmlinuz" "vmlinuz-${newest_ver}"
    update_link "/boot/initrd.img" "initrd.img-${newest_ver}"

    if [[ -L "/vmlinuz" || -f "/vmlinuz" ]]; then
        update_link "/vmlinuz" "boot/vmlinuz-${newest_ver}"
    fi
    if [[ -L "/initrd.img" || -f "/initrd.img" ]]; then
        update_link "/initrd.img" "boot/initrd.img-${newest_ver}"
    fi

    if [[ ${num_sorted} -gt 1 ]]; then
        local second_ver="${sorted_arr[1]}"
        log_info "Second newest valid kernel version resolved: ${second_ver}"

        update_link "/boot/vmlinuz.old" "vmlinuz-${second_ver}"
        update_link "/boot/initrd.img.old" "initrd.img-${second_ver}"

        if [[ -L "/vmlinuz.old" || -f "/vmlinuz.old" ]]; then
            update_link "/vmlinuz.old" "boot/vmlinuz-${second_ver}"
        fi
        if [[ -L "/initrd.img.old" || -f "/initrd.img.old" ]]; then
            update_link "/initrd.img.old" "boot/initrd.img-${second_ver}"
        fi
    else
        log_info "Only one valid kernel version resolved. Removing old symlinks to avoid dangling references."
        rm -f "/boot/vmlinuz.old" "/boot/initrd.img.old"
        if [[ -L "/vmlinuz.old" || -f "/vmlinuz.old" ]]; then
            rm -f "/vmlinuz.old"
        fi
        if [[ -L "/initrd.img.old" || -f "/initrd.img.old" ]]; then
            rm -f "/initrd.img.old"
        fi
    fi
}

# ------------------------------------------------------------------------------
# 6. Standard Hardened Non-Interactive APT Configuration
# ------------------------------------------------------------------------------
DEFAULT_APT_OPTS=(
    -qy
    -o DPkg::Lock::Timeout=120
    -o Dpkg::Options::=--force-confdef
    -o Dpkg::Options::=--force-confold
    -o Acquire::http::No-Cache=true
    -o Acquire::http::Max-Age=0
)

# ------------------------------------------------------------------------------
# 7. Package Archive & Unneeded Dependencies Cleanup
# ------------------------------------------------------------------------------
clean_apt_cache_and_orphans() {
    local dry_run="${1:-false}"
    log_info "Autoremoving unneeded dependencies and cleaning package archive..."
    if [[ "${dry_run}" == "true" ]]; then
        log_info "  -> [DRY-RUN] Would execute 'apt-get autoremove --purge -y' and 'apt-get clean'"
    else
        apt-get "${DEFAULT_APT_OPTS[@]}" autoremove -y --purge 2>&1 | tee -a "${LOG_FILE}" || true
        apt-get "${DEFAULT_APT_OPTS[@]}" clean 2>&1 | tee -a "${LOG_FILE}" || true
    fi
}

# ------------------------------------------------------------------------------
# 8. Unconfigured & Residual Package Remediation
# ------------------------------------------------------------------------------
repair_unconfigured_packages() {
    local dry_run="${1:-false}"
    log_info "Attempting to configure any unpacked or unconfigured packages..."
    if [[ "${dry_run}" == "false" ]]; then
        dpkg --configure -a 2>&1 | tee -a "${LOG_FILE}" || true
    fi

    if command -v dpkg-query >/dev/null 2>&1; then
        local iu_pkgs
        iu_pkgs="$(dpkg-query -f '${db:Status-Status} ${Package}\n' -W 2>/dev/null | awk '/^unpacked/ {print $2}' || true)"
        if [[ -n "${iu_pkgs}" ]]; then
            if [[ "${dry_run}" == "true" ]]; then
                log_info "  -> [DRY-RUN] Would purge unpacked package(s): ${iu_pkgs}"
            else
                log_info "Purging broken unpacked package(s)..."
                echo "${iu_pkgs}" | xargs -r apt-get "${DEFAULT_APT_OPTS[@]}" remove --purge -y 2>&1 | tee -a "${LOG_FILE}" || true
            fi
        fi
    fi
}

purge_residual_configs() {
    local dry_run="${1:-false}"
    if ! command -v dpkg-query >/dev/null 2>&1; then
        return 0
    fi

    local rc_pkgs
    rc_pkgs="$(dpkg-query -f '${db:Status-Status} ${Package}\n' -W 2>/dev/null | awk '/^config-files/ {print $2}' || true)"
    if [[ -n "${rc_pkgs}" ]]; then
        local num_rc
        num_rc="$(echo "${rc_pkgs}" | wc -l)"
        if [[ "${dry_run}" == "true" ]]; then
            log_info "  -> [DRY-RUN] Would purge ${num_rc} residual package configuration files (status: rc)."
        else
            log_info "Purging ${num_rc} residual package configurations..."
            echo "${rc_pkgs}" | xargs -r apt-get "${DEFAULT_APT_OPTS[@]}" purge -y 2>&1 | tee -a "${LOG_FILE}" || true
        fi
    else
        log_info "No residual package configurations (status: rc) found."
    fi
}

# ------------------------------------------------------------------------------
# 9. Kernel Discrepancy & Reboot Inspection
# ------------------------------------------------------------------------------
check_system_reboot_status() {
    local target_kernel="${1:-}"
    local running_kver
    running_kver="$(uname -r)"

    local reboot_required=false
    local reason=""

    if [[ -f /var/run/reboot-required ]]; then
        reboot_required=true
        reason="/var/run/reboot-required flag is present"
    elif [[ -n "${target_kernel}" && "${running_kver}" != "${target_kernel}" ]]; then
        reboot_required=true
        reason="Active kernel (${running_kver}) does not match target kernel (${target_kernel})"
    elif declare -f is_reboot_required >/dev/null 2>&1 && is_reboot_required; then
        reboot_required=true
        reason="Package manager flagged pending system restart"
    fi

    if [[ "${reboot_required}" == "true" ]]; then
        echo ""
        echo "================================================================================"
        echo " [!] ATTENTION: SYSTEM REBOOT REQUIRED"
        echo "--------------------------------------------------------------------------------"
        echo " Reason          : ${reason}"
        echo " Running Kernel  : ${running_kver}"
        [[ -n "${target_kernel}" ]] && echo " Target Kernel   : ${target_kernel}"
        echo " Action Required : Please schedule a system reboot to apply changes."
        echo "================================================================================"
        echo ""
        log_warn "Host reboot is required (${reason})."
    else
        log_info "No system reboot required. Running kernel (${running_kver}) is up to date."
    fi
}

