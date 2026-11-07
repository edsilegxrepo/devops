#!/usr/bin/env bash
# ==============================================================================
# Script:      /opt/scripts/max_root.sh
# Version:     2.0.0  2026/11/06
# Standard:    DRY Architecture Framework
# Author:      DevOps Systems Administration <criticalsys.mis@gmail.com>
# Compatibility: Enterprise Linux 8, 9, 10 (RHEL, AlmaLinux, Rocky, CentOS, Fedora)
#                Debian 12+ (Bookworm), Ubuntu 22.04+ (Jammy/Noble), Proxmox VE 8+
# Description: Production-hardened root (/) filesystem space maximization utility.
#              Reclaims disk space prior to OS updates/upgrades by safely pruning
#              systemd journals, rotated logs (preserving audit/journal integrity),
#              core/crash dumps, stale /tmp & /var/tmp files, user cache, and
#              distribution-specific package manager caches/orphans (APT / DNF).
# ==============================================================================
set -euo pipefail
umask 022

# ------------------------------------------------------------------------------
# 1. Environment & Foundation Library Initialization
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
LIB_SYSTEM="${SCRIPT_DIR}/lib/system.sh"
[[ -f "${LIB_SYSTEM}" ]] || LIB_SYSTEM="/opt/scripts/lib/system.sh"
if [[ ! -f "${LIB_SYSTEM}" ]]; then
    echo "[-] Fatal Error: Universal system foundation library not found at ${LIB_SYSTEM}" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "${LIB_SYSTEM}"

# Initialize logging architecture
init_system_logging "/var/log/max_root.log"

# Default configuration parameters
DRY_RUN=false
FORCE=false
SKIP_PKG_CLEAN=false
VACUUM_SIZE="100M"
TMP_MAX_DAYS=2

# ------------------------------------------------------------------------------
# 2. CLI Usage & Help
# ------------------------------------------------------------------------------
show_usage() {
    cat << EOF
Usage: sudo $(basename "$0") [OPTIONS]

Root (/) Filesystem Space Maximization Utility (RHEL / Debian / Ubuntu / Proxmox)
Reclaims disk headroom prior to OS updates to prevent transaction & initramfs failures.

Options:
  -h, --help                Show this help documentation and exit.
  -n, --dry-run, --detect   Scan system and preview space reclamation without deleting files.
  -f, --force               Bypass active lock warnings and force package cleaning.
  --vacuum-size <SIZE>      Target size for systemd journal vacuuming (default: 100M).
  --tmp-days <DAYS>         Age threshold in days for stale /tmp files (default: 2).
  --skip-pkg-clean          Skip package manager cache cleaning and orphan autoremoval.

Cleanup Modules:
  1. Systemd Journals      Vacuums journal logs to specified threshold (--vacuum-size).
  2. Rotated Logs          Safely prunes *.gz, *.[0-9], *.old from /var/log (protects audit & journal).
  3. Crash & Core Dumps    Removes crash artifacts from /var/crash and /var/lib/systemd/coredump.
  4. Stale Temporary Files Prunes stale regular files from /tmp and /var/tmp (> 2 days old).
  5. Package Caches & DBs  Debian/Ubuntu: purges 'rc' config-files, cleans APT cache & autoremoves.
                           RHEL/CentOS/Alma: cleans DNF cache, autoremoves orphans, vacuums SQLite DBs.
  6. Stale User Cache      Prunes /root/.cache (pip, package manager, and build cache).
  7. Proxmox VE (if PVE)   Removes orphaned *.tmp backup files in /var/lib/vz/dump.

Supported Environments:
  - Enterprise Linux: RHEL, AlmaLinux, Rocky Linux, CentOS, Fedora (EL8+)
  - Debian Family: Debian 12+, Ubuntu 22.04+, Linux Mint, Proxmox VE 8+
EOF
}

# ------------------------------------------------------------------------------
# 3. Argument Parsing
# ------------------------------------------------------------------------------
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
        --skip-pkg-clean)
            SKIP_PKG_CLEAN=true
            shift
            ;;
        --vacuum-size)
            if [[ -z "${2:-}" ]]; then
                log_error "Option --vacuum-size requires an argument (e.g. 100M, 50M)."
                exit 1
            fi
            VACUUM_SIZE="$2"
            shift 2
            ;;
        --tmp-days)
            if [[ -z "${2:-}" || ! "$2" =~ ^[0-9]+$ ]]; then
                log_error "Option --tmp-days requires a non-negative integer."
                exit 1
            fi
            TMP_MAX_DAYS="$2"
            shift 2
            ;;
        *)
            log_error "Unknown argument: '$1'"
            show_usage >&2
            exit 1
            ;;
    esac
done

# ------------------------------------------------------------------------------
# 4. Privilege & Operating System Guards
# ------------------------------------------------------------------------------
require_root "Executing root disk maximization requires superuser privileges (or sudo)."

validate_os "any"

# ------------------------------------------------------------------------------
# 5. Pre-Flight Storage Capacity Snapshot
# ------------------------------------------------------------------------------
initial_free_mb="$(get_free_mb "/")"
initial_summary="$(get_partition_summary "/")"

echo "=============================================================================="
log_info "Starting Root (/) Filesystem Space Maximization"
log_info "Detected OS   : ${OS_PRETTY} (${OS_FAMILY} family)"
log_info "Initial Space : ${initial_summary} (${initial_free_mb} MB free)"
if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "Mode          : DRY-RUN (Preview only, no files will be deleted)"
fi
echo "=============================================================================="

# ------------------------------------------------------------------------------
# Module 1: Systemd Journals Vacuuming
# ------------------------------------------------------------------------------
log_info "[1/7] Vacuuming systemd journal logs to max ${VACUUM_SIZE}..."
if command -v journalctl >/dev/null 2>&1; then
    current_journal="$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGTPE]B?' | head -n 1 || echo "N/A")"
    log_info "  -> Current journal disk footprint: ${current_journal}"
    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "  -> [DRY-RUN] Would vacuum journal logs to retain maximum ${VACUUM_SIZE}."
    else
        journalctl --vacuum-size="${VACUUM_SIZE}" >/dev/null 2>&1 || true
        log_info "  -> Journal logs vacuumed successfully."
    fi
else
    log_warn "  -> journalctl not available on this system; skipping journal vacuum."
fi

# ------------------------------------------------------------------------------
# Module 2: Rotated & Compressed Logs in /var/log
# ------------------------------------------------------------------------------
log_info "[2/7] Pruning rotated and compressed logs in /var/log..."
# CRITICAL SAFETY: Protect /var/log/journal (systemd index integrity) and /var/log/audit (auditd compliance)
if [[ -d "/var/log" ]]; then
    if [[ "${DRY_RUN}" == "true" ]]; then
        count_logs="$(find /var/log \( -path "/var/log/journal" -o -path "/var/log/audit" \) -prune -o -type f \( -name "*.gz" -o -name "*.[0-9]" -o -name "*.old" -o -name "*.1" \) -print 2>/dev/null | wc -l || echo 0)"
        log_info "  -> [DRY-RUN] Found ${count_logs} rotated/compressed log files eligible for removal."
    else
        find /var/log \( -path "/var/log/journal" -o -path "/var/log/audit" \) -prune -o -type f \( -name "*.gz" -o -name "*.[0-9]" -o -name "*.old" -o -name "*.1" \) -delete 2>/dev/null || true
        log_info "  -> Rotated log files pruned (audit and journal logs safely protected)."
    fi
fi

# ------------------------------------------------------------------------------
# Module 3: Crash Artifacts & Core Dumps
# ------------------------------------------------------------------------------
log_info "[3/7] Pruning core dumps and crash reports..."
crash_targets=("/var/crash" "/var/lib/systemd/coredump")
for cdir in "${crash_targets[@]}"; do
    if [[ -d "${cdir}" ]]; then
        if [[ "${DRY_RUN}" == "true" ]]; then
            dump_count="$(find "${cdir}" -mindepth 1 -type f 2>/dev/null | wc -l || echo 0)"
            log_info "  -> [DRY-RUN] Found ${dump_count} file(s) in ${cdir}."
        else
            find "${cdir}" -mindepth 1 -type f -delete 2>/dev/null || true
            log_info "  -> Cleaned crash directory: ${cdir}"
        fi
    fi
done

# ------------------------------------------------------------------------------
# Module 4: Stale Temporary Files (/tmp & /var/tmp)
# ------------------------------------------------------------------------------
log_info "[4/7] Pruning stale temporary files (> ${TMP_MAX_DAYS} days old)..."
# Check if /tmp is a separate mount / tmpfs
if mountpoint -q /tmp 2>/dev/null; then
    tmp_type="$(df -T /tmp 2>/dev/null | awk 'NR==2 {print $2}')"
    if [[ "${tmp_type}" == "tmpfs" ]]; then
        log_info "  -> Notice: /tmp is mounted on tmpfs (RAM); cleaning reclaims memory rather than root disk."
    fi
fi

for tdir in "/tmp" "/var/tmp"; do
    if [[ -d "${tdir}" ]]; then
        if [[ "${DRY_RUN}" == "true" ]]; then
            stale_tmp_count="$(find "${tdir}" -mindepth 1 -type f -mtime "+${TMP_MAX_DAYS}" ! -name "*.lock" ! -name "*.pid" ! -path "*/systemd-private-*" 2>/dev/null | wc -l || echo 0)"
            log_info "  -> [DRY-RUN] Found ${stale_tmp_count} stale temporary file(s) in ${tdir}."
        else
            find "${tdir}" -mindepth 1 -type f -mtime "+${TMP_MAX_DAYS}" ! -name "*.lock" ! -name "*.pid" ! -path "*/systemd-private-*" -delete 2>/dev/null || true
            find "${tdir}" -mindepth 1 -depth -type d -empty ! -path "*/systemd-private-*" -delete 2>/dev/null || true
            log_info "  -> Pruned stale temporary files in ${tdir}."
        fi
    fi
done

# ------------------------------------------------------------------------------
# Module 5: Package Manager Caches & Orphan Dependencies
# ------------------------------------------------------------------------------
log_info "[5/7] Optimizing package manager storage and caches..."
if [[ "${SKIP_PKG_CLEAN}" == "true" ]]; then
    log_info "  -> Package cleaning skipped by user request (--skip-pkg-clean)."
else
    # Check for package manager concurrency
    active_pkg_procs="$(get_active_pkg_managers)"
    if [[ -n "${active_pkg_procs}" ]]; then
        log_warn "Active package manager process(es) detected:"
        echo "${active_pkg_procs}" >&2
        if [[ "${FORCE}" != "true" ]]; then
            log_warn "  -> Skipping package cache cleaning to avoid lock contention (use --force to override)."
        else
            log_warn "  -> --force specified: proceeding despite active processes."
        fi
    fi

    if [[ -z "${active_pkg_procs}" || "${FORCE}" == "true" ]]; then
        if [[ "${OS_FAMILY}" == "debian" ]]; then
            # 1. Purge config-files (status: rc) safely without column truncation
            purge_residual_configs "${DRY_RUN}"

            # 2. APT autoremove & clean
            clean_apt_cache_and_orphans "${DRY_RUN}"

        elif [[ "${OS_FAMILY}" == "rhel" ]]; then
            dnf_check_bin="${SCRIPT_DIR}/dnf_check.sh"
            [[ -f "${dnf_check_bin}" ]] || dnf_check_bin="/opt/scripts/dnf_check.sh"

            if [[ -f "${dnf_check_bin}" ]]; then
                if [[ "${DRY_RUN}" == "true" ]]; then
                    log_info "  -> [DRY-RUN] Would delegate RHEL package and SQLite cleanup to '${dnf_check_bin} --clean'."
                else
                    log_info "  -> Delegating package & SQLite cleanup to '${dnf_check_bin} --clean'..."
                    bash "${dnf_check_bin}" --clean
                fi
            else
                # Fallback to direct execution if dnf_check.sh is not installed
                pm="${PKG_MGR:-$(command -v dnf 2>/dev/null || command -v yum 2>/dev/null || echo "dnf")}"
                if command -v "${pm}" >/dev/null 2>&1; then
                    if [[ "${DRY_RUN}" == "true" ]]; then
                        log_info "  -> [DRY-RUN] Would execute '${pm} clean all' and '${pm} autoremove -y'."
                    else
                        log_info "  -> Cleaning ${pm} package and metadata cache..."
                        "${pm}" clean all >/dev/null 2>&1 || true
                        log_info "  -> Autoremoving unneeded dependencies via ${pm}..."
                        "${pm}" autoremove -y >/dev/null 2>&1 || true
                    fi
                fi

                # SQLite DB vacuum for DNF history
                if declare -F sqlite_vacuum_db >/dev/null 2>&1 && [[ "${DRY_RUN}" == "false" ]]; then
                    dnf_hist="/var/lib/dnf/history.sqlite"
                    if [[ -f "${dnf_hist}" ]]; then
                        log_info "  -> Checkpointing and vacuuming DNF history database..."
                        sqlite_vacuum_db "${dnf_hist}" >/dev/null 2>&1 || true
                    fi
                fi
            fi
        fi
    fi
fi

# ------------------------------------------------------------------------------
# Module 6: Stale User Cache (/root/.cache)
# ------------------------------------------------------------------------------
log_info "[6/7] Pruning stale root user cache (/root/.cache)..."
root_cache="/root/.cache"
if [[ -d "${root_cache}" ]]; then
    if [[ "${DRY_RUN}" == "true" ]]; then
        cache_footprint="$(du -sh "${root_cache}" 2>/dev/null | awk '{print $1}' || echo "N/A")"
        log_info "  -> [DRY-RUN] Found /root/.cache utilizing ${cache_footprint}."
    else
        rm -rf "${root_cache:?}"/* 2>/dev/null || true
        log_info "  -> Pruned stale files from /root/.cache."
    fi
else
    log_info "  -> /root/.cache does not exist or is already clean."
fi

# ------------------------------------------------------------------------------
# Module 7: Hypervisor Backup Temporary Files (Proxmox VE)
# ------------------------------------------------------------------------------
log_info "[7/7] Checking for hypervisor backup temporary files..."
if [[ -d "/var/lib/vz/dump" ]]; then
    if [[ "${DRY_RUN}" == "true" ]]; then
        vz_tmp_count="$(find /var/lib/vz/dump -maxdepth 1 -type f -name "*.tmp" 2>/dev/null | wc -l || echo 0)"
        log_info "  -> [DRY-RUN] Found ${vz_tmp_count} stale Proxmox backup temporary files in /var/lib/vz/dump."
    else
        find /var/lib/vz/dump -maxdepth 1 -type f -name "*.tmp" -delete 2>/dev/null || true
        log_info "  -> Cleaned stale Proxmox backup artifacts in /var/lib/vz/dump."
    fi
else
    log_info "  -> No Proxmox VE backup storage directory detected (/var/lib/vz/dump)."
fi

# ------------------------------------------------------------------------------
# 6. Post-Execution Metrics & Summary
# ------------------------------------------------------------------------------
final_free_mb="$(get_free_mb "/")"
final_summary="$(get_partition_summary "/")"

echo "------------------------------------------------------------------------------"
log_info "=== Root Filesystem (/) Space Maximization Summary ==="
log_info "  -> Initial Free Space : ${initial_summary} (${initial_free_mb} MB free)"
log_info "  -> Final Free Space   : ${final_summary} (${final_free_mb} MB free)"

if [[ "${initial_free_mb}" =~ ^[0-9]+$ ]] && [[ "${final_free_mb}" =~ ^[0-9]+$ ]]; then
    reclaimed_mb=$((final_free_mb - initial_free_mb))
    if [[ ${reclaimed_mb} -gt 0 ]]; then
        log_info "  -> Total Space Reclaimed: ${reclaimed_mb} MB"
    else
        log_info "  -> Total Space Reclaimed: 0 MB (Filesystem already clean or cleared files were on RAM/tmpfs)"
    fi
fi
log_info "=== Space Maximization Complete ==="
echo "=============================================================================="
