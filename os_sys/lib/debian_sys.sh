#!/usr/bin/env bash
# ==============================================================================
# Library:     /opt/scripts/lib/debian_sys.sh
# Version:     2.0.0  2026/11/18
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
    # shellcheck disable=SC2317 # Reached when invoked directly rather than sourced
    return 1 2>/dev/null || exit 1
fi

# Default log file target for Debian operations
LOG_FILE="${LOG_FILE:-/var/log/debian_sys.log}"

init_debian_logging() {
    init_system_logging "${1:-/var/log/debian_sys.log}"
}

resolve_version_sort_cmd() {
    if command -v linux-version >/dev/null 2>&1; then
        SORT_CMD=(linux-version sort)
    else
        SORT_CMD=(sort -V)
    fi
}

# ------------------------------------------------------------------------------
# 2. APT / dpkg Concurrency & Lock Management
# ------------------------------------------------------------------------------
_filter_self_pids() {
    local raw_pids="$1"
    local -a pids_arr=()
    local -a out_pids=()
    read -r -a pids_arr <<< "${raw_pids}"
    if [[ ${#pids_arr[@]} -gt 0 ]]; then
        local pid
        for pid in "${pids_arr[@]}"; do
            [[ -z "${pid}" || "${pid}" == "$$" || "${pid}" == "${PPID:-0}" ]] && continue
            out_pids+=("${pid}")
        done
    fi
    [[ ${#out_pids[@]} -gt 0 ]] && printf '%s\n' "${out_pids[@]}"
    return 0
}

_filter_active_pkg_procs() {
    local procs
    procs="$(get_active_pkg_managers)"
    if [[ -n "${procs}" ]]; then
        awk -v pid="$$" -v ppid="${PPID:-0}" '$1 != pid && $1 != ppid' <<< "${procs}" || true
    fi
}

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

    local lf
    for lf in "${lock_files[@]}"; do
        if [[ -f "${lf}" ]]; then
            local pids
            pids="$(get_lock_pids "${lf}")"
            if [[ -n "${pids}" ]]; then
                local -a filtered_pids=()
                mapfile -t filtered_pids < <(_filter_self_pids "${pids}")
                if [[ ${#filtered_pids[@]} -gt 0 ]]; then
                    local pid
                    for pid in "${filtered_pids[@]}"; do
                        all_locker_pids+=("${pid}")
                        if [[ -d "/proc/${pid}" ]]; then
                            local cmd
                            cmd="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || ps -p "${pid}" -o comm= 2>/dev/null || true)"
                            if grep -qiE "unattended-upgr|apt\.systemd\.daily|packagekit|apt-daily" <<< "${cmd}"; then
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
        fi
    done

    # Concurrency verification via process table
    local filtered_procs
    filtered_procs="$(_filter_active_pkg_procs)"
    if [[ -n "${filtered_procs}" ]]; then
        if grep -qiE "unattended-upgr|apt\.systemd\.daily|packagekitd" <<< "${filtered_procs}"; then
            bg_updater=true
            [[ -z "${reason}" ]] && reason="background auto-updater service"
        else
            contention=true
            [[ -z "${reason}" ]] && reason="active package manager process"
        fi
    fi

    # Deduplicate locker PIDs
    local -a unique_pids=()
    if [[ ${#all_locker_pids[@]} -gt 0 ]]; then
        read -r -a unique_pids <<< "$(printf '%s\n' "${all_locker_pids[@]}" | sort -u | tr '\n' ' ')"
    fi

    if [[ ${#unique_pids[@]} -gt 0 ]]; then
        log_warn "APT/dpkg lock actively held by process PID(s): ${unique_pids[*]}"
        _run_apt_logged ps -fp "${unique_pids[@]}" 2>/dev/null || true
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
                local cur_lock_pids
                cur_lock_pids="$(_filter_self_pids "$(get_lock_pids "${lf}")")"
                if [[ -n "${cur_lock_pids}" ]]; then
                    still_locked=true
                    break
                fi
            done

            local cur_procs=""
            cur_procs="$(_filter_active_pkg_procs)"

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
        return 1
    else
        log_info "No active transaction locks detected. Package manager locks are clear."
    fi
    return 0
}

# ------------------------------------------------------------------------------
# 3. Background Auto-Upgrades Remediation
# ------------------------------------------------------------------------------
disable_autoupgrades() {
    local only_disable="${1:-false}"
    log_info "Permanently disabling automatic background APT timers and services..."
    if command -v systemctl >/dev/null 2>&1; then
        local -a auto_services=(
            apt-daily.timer
            apt-daily-upgrade.timer
            apt-daily.service
            apt-daily-upgrade.service
            unattended-upgrades.service
        )
        local s
        for s in "${auto_services[@]}"; do
            systemctl stop "$s" >/dev/null 2>&1 || true
            systemctl disable "$s" >/dev/null 2>&1 || true
            systemctl mask "$s" >/dev/null 2>&1 || true
        done
    fi
    if [[ -d /etc/apt/apt.conf.d ]]; then
        log_info "Configuring /etc/apt/apt.conf.d to disable periodic APT actions..."
        local periodic_cfg
        periodic_cfg='APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "0";
APT::Periodic::Unattended-Upgrade "0";'
        printf '%s\n' "${periodic_cfg}" > /etc/apt/apt.conf.d/20auto-upgrades
        if [[ -f /etc/apt/apt.conf.d/10periodic ]]; then
            printf '%s\n' "${periodic_cfg}" > /etc/apt/apt.conf.d/10periodic
        fi
    fi
    log_info "Automatic background upgrades have been permanently disabled and masked."
    if [[ "${only_disable}" == "true" ]]; then
        log_info "Completed --disable-autoupgrades-only request. Exiting."
        exit 0
    fi
}

# ------------------------------------------------------------------------------
# 4. Kernel Boot Symlinks Synchronization
# ------------------------------------------------------------------------------
_sync_boot_symlink_pair() {
    local suffix="$1"
    local kver="$2"

    update_link "/boot/vmlinuz${suffix}" "vmlinuz-${kver}"
    update_link "/boot/initrd.img${suffix}" "initrd.img-${kver}"

    if [[ -L "/vmlinuz${suffix}" || -f "/vmlinuz${suffix}" ]]; then
        update_link "/vmlinuz${suffix}" "boot/vmlinuz-${kver}"
    fi
    if [[ -L "/initrd.img${suffix}" || -f "/initrd.img${suffix}" ]]; then
        update_link "/initrd.img${suffix}" "boot/initrd.img-${kver}"
    fi
}

update_boot_symlinks() {
    log_info "Updating system boot symlinks..."

    resolve_version_sort_cmd

    # 1. Gather all kernel versions where BOTH vmlinuz and initrd.img exist
    local -a versions=()
    local f kver
    for f in /boot/vmlinuz-*; do
        [[ -e "${f}" ]] || continue
        if [[ -f "${f}" && ! -L "${f}" && "${f}" != *.tmp && "${f}" != *.bak ]]; then
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
    _sync_boot_symlink_pair "" "${newest_ver}"

    if [[ ${num_sorted} -gt 1 ]]; then
        local second_ver="${sorted_arr[1]}"
        log_info "Second newest valid kernel version resolved: ${second_ver}"
        _sync_boot_symlink_pair ".old" "${second_ver}"
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
# 5. Standard Hardened Non-Interactive APT Configuration
# ------------------------------------------------------------------------------
DEFAULT_APT_OPTS=(
    -qy
    -o DPkg::Lock::Timeout=120
    -o Dpkg::Options::=--force-confdef
    -o Dpkg::Options::=--force-confold
    -o Acquire::http::No-Cache=true
    -o Acquire::http::Max-Age=0
)

_run_apt_logged() {
    local rc=0
    if _is_log_writable; then
        "$@" 2>&1 | tee -a "${LOG_FILE}" || rc=$?
    else
        "$@" 2>&1 || rc=$?
    fi
    return "${rc}"
}

# ------------------------------------------------------------------------------
# 6. Package Archive & Unneeded Dependencies Cleanup
# ------------------------------------------------------------------------------
clean_apt_cache_and_orphans() {
    local dry_run="${1:-false}"
    log_info "Autoremoving unneeded dependencies and cleaning package archive..."
    if [[ "${dry_run}" == "true" ]]; then
        log_info "  -> [DRY-RUN] Would execute 'apt-get autoremove --purge -y' and 'apt-get clean'"
        return 0
    fi

    local rc=0
    _run_apt_logged apt-get "${DEFAULT_APT_OPTS[@]}" autoremove -y --purge || rc=$?
    _run_apt_logged apt-get "${DEFAULT_APT_OPTS[@]}" clean || rc=$?
    return "${rc}"
}

# ------------------------------------------------------------------------------
# 7. Unconfigured & Residual Package Remediation
# ------------------------------------------------------------------------------
repair_unconfigured_packages() {
    local dry_run="${1:-false}"
    local purge_unpacked="${2:-false}"
    log_info "Attempting to configure any unpacked or unconfigured packages..."

    local rc=0
    if [[ "${dry_run}" == "false" ]]; then
        _run_apt_logged dpkg --configure -a || rc=$?
    fi

    if command -v dpkg-query >/dev/null 2>&1; then
        local iu_pkgs
        iu_pkgs="$(dpkg-query -f '${db:Status-Status} ${Package}\n' -W 2>/dev/null | awk '/^unpacked/ {print $2}' || true)"
        if [[ -n "${iu_pkgs}" ]]; then
            if [[ "${dry_run}" == "true" ]]; then
                log_info "  -> [DRY-RUN] Unpacked package(s) detected: ${iu_pkgs}"
            elif [[ "${purge_unpacked}" == "true" ]]; then
                log_warn "Purging broken unpacked package(s) (--purge-unpacked): ${iu_pkgs}"
                _run_apt_logged xargs -r apt-get "${DEFAULT_APT_OPTS[@]}" remove --purge -y <<< "${iu_pkgs}" || rc=$?
            else
                log_warn "Unpacked package(s) remain after 'dpkg --configure -a': ${iu_pkgs}"
                log_warn "Skipping automatic purge to prevent config/dependency loss; pass 'true' as 2nd arg to purge."
                rc=1
            fi
        fi
    fi
    return "${rc}"
}

purge_residual_configs() {
    local dry_run="${1:-false}"
    if ! command -v dpkg-query >/dev/null 2>&1; then
        return 0
    fi

    local rc=0
    local rc_pkgs
    rc_pkgs="$(dpkg-query -f '${db:Status-Status} ${Package}\n' -W 2>/dev/null | awk '/^config-files/ {print $2}' || true)"
    if [[ -n "${rc_pkgs}" ]]; then
        local num_rc
        num_rc="$(wc -l <<< "${rc_pkgs}")"
        if [[ "${dry_run}" == "true" ]]; then
            log_info "  -> [DRY-RUN] Would purge ${num_rc} residual package configuration files (status: rc)."
        else
            log_info "Purging ${num_rc} residual package configurations..."
            _run_apt_logged xargs -r apt-get "${DEFAULT_APT_OPTS[@]}" purge -y <<< "${rc_pkgs}" || rc=$?
        fi
    else
        log_info "No residual package configurations (status: rc) found."
    fi
    return "${rc}"
}

# ------------------------------------------------------------------------------
# 8. Kernel Discrepancy & Reboot Inspection
# ------------------------------------------------------------------------------
check_system_reboot_status() {
    local target_kernel="${1:-}"
    local running_kver
    running_kver="$(uname -r)"

    local reboot_required=false
    local reason=""

    if declare -F is_reboot_required >/dev/null 2>&1 && is_reboot_required; then
        reboot_required=true
        reason="Reboot required flag (/run/reboot-required or pending service restart) is present"
    elif [[ -f /var/run/reboot-required ]]; then
        reboot_required=true
        reason="/var/run/reboot-required flag is present"
    elif [[ -n "${target_kernel}" && "${running_kver}" != "${target_kernel}" ]]; then
        reboot_required=true
        reason="Active kernel (${running_kver}) does not match target kernel (${target_kernel})"
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

