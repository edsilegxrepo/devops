#!/usr/bin/env bash
# ==============================================================================
# Script: /opt/scripts/dnf_check.sh
# Version: 1.6.1  2026/11/06
# Compatibility: Enterprise Linux 8, 9, 10 (RHEL, AlmaLinux, Rocky Linux, CentOS)
# Standard: DRY Architecture Framework
# Description: Production-hardened DNF wrapper with cross-version SQLite integrity
#              checks, WAL vacuuming, RPM database rebuild and recovery, pre-flight
#              /boot guards, service restart auditing, and post-transaction kernel
#              synchronization.
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# 1. Environment & Library Initialization
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_SYSTEM="${SCRIPT_DIR}/lib/system.sh"
[[ -f "${LIB_SYSTEM}" ]] || LIB_SYSTEM="/opt/scripts/lib/system.sh"
if [[ ! -f "${LIB_SYSTEM}" ]]; then
  echo "[-] Fatal Error: Shared system library not found at ${LIB_SYSTEM}" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "${LIB_SYSTEM}"

# Common paths and relaxed dependency options
DNF_RELAX_OPTS=(--skip-broken --nobest)
DNF_BASE="/var/lib/dnf"
DNF_CACHE="/var/cache/dnf"
BOOT_MIN_FREE_MB=100

# ------------------------------------------------------------------------------
# 2. CLI Usage & Help
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Function: show_usage
# Purpose:  Displays command syntax, options, and operational behavior to stdout.
# Arguments:
#   None.
# Returns:
#   Outputs usage documentation.
# ------------------------------------------------------------------------------
show_usage() {
  cat << EOF
Usage: $(basename "$0") [OPTIONS] [DNF_COMMAND...]

Maintenance Options:
  --verify-rpmdb        Inspect RPM database health, SQLite integrity, and transaction locks
  --rebuild-rpmdb       Safely rebuild RPM database with pre-rebuild backup snapshot
  --sqlite-check        Verify SQLite database integrity for DNF caches and history
  --sqlite-vacuum       Checkpoint WAL journals and vacuum SQLite databases to reclaim space
  --purge-cache         Safely purge DNF package and metadata cache via native clean
  --show-update-details Display detailed CVEs, severity, and errata for pending updates
  --needs-restarting    Inspect whether core libraries or active services require restart
  --relax               Permit non-best packages and skip broken dependencies (--skip-broken --nobest)
  --auto-reboot         Automatically reboot the host if a new kernel is installed/upgraded
  --force               Bypass pre-flight checks (e.g. /boot disk capacity warnings)
  -h, --help            Display this help message and exit

DNF Pass-Through:
  Any other arguments are passed directly to '${PKG_MGR}' (e.g. update, install, search).
  On mutating transactions (update, install, distro-sync, etc.):
    - Pre-flight checks verify /boot filesystem capacity (>= ${BOOT_MIN_FREE_MB} MB recommended).
    - Post-transaction bootloader kernel is automatically synchronized via kernel-default.sh.
    - Kernel and core-library upgrade status is audited (with auto-reboot if requested).

Compatibility:
  Enterprise Linux 8, 9, and 10 (UEFI and BIOS boot topologies).
EOF
}

# Allow non-root users to view help
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  show_usage
  exit 0
fi

if [[ $# -lt 1 ]]; then
  show_usage >&2
  exit 2
fi

# Privilege guard: all functional actions require root / sudo
require_root

# ------------------------------------------------------------------------------
# 3. Core Maintenance Functions
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Function: verify_rpmdb
# Purpose:  Inspects RPM database structural integrity, active transaction locks,
#           underlying SQLite engine health, and queryable package inventory.
# Arguments:
#   None.
# Returns:
#   0 if database is healthy; 1 if corrupted or unhealthy.
# ------------------------------------------------------------------------------
verify_rpmdb() {
  echo "=============================================================================="
  echo "[*] RPM Database Integrity & Lock Inspection"
  echo "=============================================================================="

  local rpm_dir="/var/lib/rpm"
  local rpm_real_dir
  rpm_real_dir="$(readlink -f "${rpm_dir}" 2>/dev/null || echo "${rpm_dir}")"
  echo "[*] RPM Database Path: ${rpm_dir} -> ${rpm_real_dir}"

  local issues=0

  # 1. Inspect transaction lock
  local lock_file="${rpm_real_dir}/.rpm.lock"
  if [[ -f "${lock_file}" ]]; then
    echo "[*] Inspecting transaction lock: [${lock_file}]..."
    local locker_pids=""
    if command -v fuser >/dev/null 2>&1; then
      locker_pids="$(fuser "${lock_file}" 2>/dev/null || true)"
    fi
    if [[ -n "${locker_pids}" ]]; then
      echo "[!] Lock is actively held by process PID(s): ${locker_pids}"
      local -a pids_arr=()
      read -r -a pids_arr <<< "${locker_pids}"
      ps -fp "${pids_arr[@]}" 2>/dev/null || true
    else
      if command -v fuser >/dev/null 2>&1; then
        echo "[+] Transaction lock is idle (no active locks held)."
      else
        echo "[i] Lock file present (concurrency check shows no active package managers)."
      fi
    fi
  else
    echo "[+] No active transaction lock detected."
  fi

  # 2. Inspect SQLite engine integrity (EL9 / EL10)
  local sqlite_db="${rpm_real_dir}/rpmdb.sqlite"
  if [[ -f "${sqlite_db}" ]]; then
    if command -v sqlite3 >/dev/null 2>&1; then
      echo "[*] Inspecting SQLite engine integrity..."
      if ! sqlite_integrity_check "${sqlite_db}"; then
        issues=$((issues + 1))
      fi
    else
      echo "[i] SQLite3 CLI not installed; skipping low-level PRAGMA integrity check."
    fi
  fi

  # 3. Native RPM verification
  echo -n "[*] Running native RPM verification... "
  local verify_cmd="rpmdb --verifydb"
  if ! command -v rpmdb >/dev/null 2>&1; then
    verify_cmd="rpm --verifydb"
  fi
  local verify_out
  if verify_out="$(${verify_cmd} 2>&1)"; then
    echo "OK"
  else
    echo "FAILED"
    echo "${verify_out}" >&2
    issues=$((issues + 1))
  fi

  # 4. Inventory count check
  local pkg_count=0
  if pkg_count="$(rpm -qa 2>/dev/null | wc -l)"; then
    echo "[+] Package inventory query succeeded: ${pkg_count} packages installed."
    if [[ ${pkg_count} -eq 0 ]]; then
      echo "[-] Warning: Zero packages returned by 'rpm -qa'." >&2
      issues=$((issues + 1))
    fi
  else
    echo "[-] Error: Failed to query package inventory via 'rpm -qa'." >&2
    issues=$((issues + 1))
  fi

  echo "=============================================================================="
  if [[ ${issues} -eq 0 ]]; then
    echo "[+] RPM database status: HEALTHY"
    return 0
  else
    echo "[-] RPM database status: ISSUES DETECTED (${issues} check(s) failed)." >&2
    echo "    Hint: Run 'sudo $(basename "$0") --rebuild-rpmdb' to repair." >&2
    log_audit "RPM database verification failed (${issues} issue(s) detected)" "dnf_check"
    return 1
  fi
}

# ------------------------------------------------------------------------------
# Function: rebuild_rpmdb
# Purpose:  Safely rebuilds a corrupted or locked RPM database. Verifies process
#           concurrency, takes a compressed pre-rebuild safety archive, clears
#           stale locks, runs native rpmdb --rebuilddb, and validates post-rebuild
#           inventory and integrity.
# Arguments:
#   None.
# Returns:
#   0 on success; 1 on failure.
# ------------------------------------------------------------------------------
rebuild_rpmdb() {
  echo "=============================================================================="
  echo "[*] RPM Database Rebuild & Recovery"
  echo "=============================================================================="

  # 1. Concurrency check: Ensure no active package managers are running
  local running_procs
  running_procs="$(pgrep -a -x "dnf|dnf-3|dnf5|yum|rpm|rpmdb" 2>/dev/null || true)"
  if [[ -n "${running_procs}" ]]; then
    echo "[-] Error: Active package management process(es) detected:" >&2
    echo "${running_procs}" >&2
    echo "[-] Aborting rebuild to prevent data race or active transaction corruption." >&2
    return 1
  fi

  local rpm_dir="/var/lib/rpm"
  local rpm_real_dir
  rpm_real_dir="$(readlink -f "${rpm_dir}" 2>/dev/null || echo "${rpm_dir}")"
  local lock_file="${rpm_real_dir}/.rpm.lock"

  # 2. Check if .rpm.lock is actively held
  if [[ -f "${lock_file}" ]]; then
    if command -v fuser >/dev/null 2>&1; then
      local locker_pids
      locker_pids="$(fuser "${lock_file}" 2>/dev/null || true)"
      if [[ -n "${locker_pids}" ]]; then
        echo "[-] Error: Lock file [${lock_file}] is actively held by process(es): ${locker_pids}" >&2
        return 1
      fi
      echo "[*] Removing stale transaction lock file: [${lock_file}]..."
      rm -f "${lock_file}"
    else
      echo "[!] Warning: Removing [${lock_file}] (concurrency check confirmed no running package managers)."
      rm -f "${lock_file}"
    fi
  fi

  # 3. Record pre-rebuild package inventory count
  local pre_count=0
  pre_count="$(rpm -qa 2>/dev/null | wc -l || echo 0)"
  echo "[*] Pre-rebuild package count: ${pre_count}"

  # 4. Pre-rebuild safety snapshot
  local backup_dir="/var/backups/rpmdb"
  local backup_user="${SYS_USER:-csysadm}"
  local backup_group="${SYS_GROUP:-root}"
  mkdir -p "${backup_dir}"
  chmod 0750 "${backup_dir}"
  chown "${backup_user}:${backup_group}" "${backup_dir}" 2>/dev/null || true

  local ts
  ts="$(date +%Y%m%d_%H%M%S)"
  local archive_name="rpmdb-pre-rebuild-${ts}.tar.gz"
  local archive_path="${backup_dir}/${archive_name}"

  echo "[*] Creating pre-rebuild safety backup archive: [${archive_path}]..."
  local rpm_parent
  rpm_parent="$(dirname "${rpm_real_dir}")"
  local rpm_base
  rpm_base="$(basename "${rpm_real_dir}")"

  if ! tar -czf "${archive_path}" -C "${rpm_parent}" "${rpm_base}"; then
    echo "[-] Error: Failed to create safety backup of RPM database. Aborting rebuild." >&2
    rm -f "${archive_path}"
    return 1
  fi
  chmod 0640 "${archive_path}"
  chown "${backup_user}:${backup_group}" "${archive_path}" 2>/dev/null || true

  local archive_size
  archive_size="$(stat -c %s "${archive_path}" 2>/dev/null || echo "unknown")"
  echo "[+] Pre-rebuild safety snapshot created (${archive_size} bytes)."

  # Prune obsolete backups (retain 5 newest snapshots)
  local old_backups=()
  mapfile -t old_backups < <(find "${backup_dir}" -maxdepth 1 -name 'rpmdb-pre-rebuild-*.tar.gz' -type f 2>/dev/null | sort -r | tail -n +6)
  if [[ ${#old_backups[@]} -gt 0 ]]; then
    rm -f "${old_backups[@]}"
  fi

  # 5. Execute native database rebuild
  echo "[*] Executing native RPM database rebuild..."
  local rebuild_cmd="rpmdb --rebuilddb"
  if ! command -v rpmdb >/dev/null 2>&1; then
    rebuild_cmd="rpm --rebuilddb"
  fi

  local rebuild_status=0
  ${rebuild_cmd} || rebuild_status=$?

  if [[ ${rebuild_status} -ne 0 ]]; then
    echo "[-] Fatal: RPM database rebuild command (${rebuild_cmd}) failed with exit code ${rebuild_status}!" >&2
    echo "    Safety snapshot is preserved at: ${archive_path}" >&2
    echo "    To restore manually: tar -xzf ${archive_path} -C ${rpm_parent}" >&2
    log_audit "RPM database rebuild failed with exit code ${rebuild_status}" "dnf_check"
    return ${rebuild_status}
  fi
  echo "[+] Database rebuild command executed successfully."

  # 6. Post-rebuild validation
  echo "[*] Performing post-rebuild verification..."
  local verify_cmd="rpmdb --verifydb"
  if ! command -v rpmdb >/dev/null 2>&1; then
    verify_cmd="rpm --verifydb"
  fi

  local verify_fail=0
  if ! ${verify_cmd} >/dev/null 2>&1; then
    echo "[-] Warning: Post-rebuild native verification check failed!" >&2
    verify_fail=1
  else
    echo "[+] Native RPM verification passed."
  fi

  local sqlite_db="${rpm_real_dir}/rpmdb.sqlite"
  if [[ -f "${sqlite_db}" ]]; then
    if ! sqlite_integrity_check "${sqlite_db}"; then
      verify_fail=1
    fi
  fi

  local post_count=0
  post_count="$(rpm -qa 2>/dev/null | wc -l || echo 0)"
  echo "[*] Post-rebuild package count: ${post_count}"

  if [[ ${pre_count} -gt 0 && ${post_count} -lt ${pre_count} ]]; then
    local diff=$((pre_count - post_count))
    echo "[!] WARNING: Package count decreased after rebuild by ${diff} package(s) (pre: ${pre_count}, post: ${post_count})!" >&2
    echo "    Inspect packages or restore safety snapshot at: ${archive_path}" >&2
  elif [[ ${post_count} -eq 0 && ${pre_count} -gt 0 ]]; then
    echo "[-] ERROR: Package database is empty after rebuild!" >&2
    return 1
  else
    echo "[+] Package count verified intact (${post_count} packages)."
  fi

  if [[ ${verify_fail} -ne 0 ]]; then
    echo "[-] Warning: Database rebuilt, but post-verification reported anomalies." >&2
    log_audit "RPM database rebuilt with verification warnings (pre: ${pre_count}, post: ${post_count}, backup: ${archive_path})" "dnf_check"
    return 1
  fi

  log_audit "RPM database rebuilt successfully (pre: ${pre_count}, post: ${post_count}, backup: ${archive_path})" "dnf_check"
  echo "=============================================================================="
  echo "[+] RPM database rebuild completed successfully."
  echo "    Safety backup stored at: ${archive_path}"
  echo "=============================================================================="
  return 0
}

# ------------------------------------------------------------------------------
# Function: sqliteWalCheck
# Purpose:  Verifies SQLite database integrity across DNF history and metadata
#           databases, reporting WAL journal presence or corruption.
# Arguments:
#   None.
# Returns:
#   0 if all databases are intact; 1 if any database fails integrity check.
# ------------------------------------------------------------------------------
sqliteWalCheck() {
  if ! command -v sqlite3 > /dev/null 2>&1; then
    echo "[-] Error: 'sqlite3' CLI utility is not installed." >&2
    return 1
  fi

  local databases=(
    "${DNF_CACHE}/packages.db"
    "${DNF_BASE}/history.sqlite"
  )

  local errors=0
  echo "[*] Checking integrity of DNF SQLite databases..."
  for db in "${databases[@]}"; do
    sqlite_integrity_check "${db}" || errors=$((errors + 1))
  done

  if [[ ${errors} -eq 0 ]]; then
    echo "[+] All DNF SQLite database integrity checks passed."
    return 0
  else
    echo "[-] Errors detected in ${errors} database(s)." >&2
    return 1
  fi
}

# ------------------------------------------------------------------------------
# Function: sqliteWalVacuum
# Purpose:  Flushes and truncates active WAL journals and vacuums DNF databases
#           to recover fragmented disk space and prevent WAL bloat.
# Arguments:
#   None.
# Returns:
#   0 on success; 1 if any database fails.
# ------------------------------------------------------------------------------
sqliteWalVacuum() {
  if ! command -v sqlite3 > /dev/null 2>&1; then
    echo "[-] Error: 'sqlite3' CLI utility is not installed." >&2
    return 1
  fi

  local databases=(
    "${DNF_CACHE}/packages.db"
    "${DNF_BASE}/history.sqlite"
  )

  local errors=0
  echo "[*] Checkpointing and vacuuming DNF SQLite databases..."
  for db in "${databases[@]}"; do
    sqlite_vacuum_db "${db}" || errors=$((errors + 1))
  done

  if [[ ${errors} -eq 0 ]]; then
    echo "[+] All DNF SQLite databases vacuumed and checkpointed successfully."
    return 0
  else
    echo "[-] Errors encountered vacuuming ${errors} database(s)." >&2
    return 1
  fi
}

# Backward-compatibility aliases
# shellcheck disable=SC2329
sqlite_wal_check() { sqliteWalCheck "$@"; }
# shellcheck disable=SC2329
sqliteWalClean() { sqliteWalCheck "$@"; }

# ------------------------------------------------------------------------------
# Function: inspect_needs_restarting
# Purpose:  Audits running system processes and core libraries using native
#           DNF needs-restarting capabilities.
# Arguments:
#   None.
# Returns:
#   0.
# ------------------------------------------------------------------------------
inspect_needs_restarting() {
  echo "=============================================================================="
  echo "[*] System Reboot & Service Restart Audit"
  echo "=============================================================================="

  if "${PKG_MGR}" needs-restarting --help >/dev/null 2>&1; then
    echo "[*] Checking if core libraries or system reboot are required..."
    local reboot_needed=0
    "${PKG_MGR}" needs-restarting -r || reboot_needed=$?

    if [[ ${reboot_needed} -eq 0 ]]; then
      echo "[+] Core libraries are current. No full system reboot is required."
    else
      echo "[!] SYSTEM REBOOT IS REQUIRED to activate updated core libraries / kernel."
    fi

    echo ""
    echo "[*] Checking active services that require restarting..."
    local stale_services
    stale_services="$("${PKG_MGR}" needs-restarting -s 2>/dev/null || true)"
    if [[ -n "${stale_services}" ]]; then
      echo "${stale_services}"
      echo ""
      echo "[i] To restart stale services, run: sudo systemctl restart <service>"
    else
      echo "[+] No active systemd services require restarting."
    fi
  else
    echo "[i] '${PKG_MGR} needs-restarting' plugin is not available on this system."
  fi
  echo "=============================================================================="
  return 0
}

# ------------------------------------------------------------------------------
# Function: verify_kernel_upgrade
# Purpose:  Audits the installed default boot kernel against the currently active
#           running kernel and core libraries. Emits warning to reboot,
#           or triggers automated reboot if --auto-reboot was supplied.
# Arguments:
#   None.
# Returns:
#   0.
# ------------------------------------------------------------------------------
verify_kernel_upgrade() {
  if is_wsl; then
    echo "[i] WSL environment detected (kernel is managed by Windows host)."
    return 0
  fi

  local running_kernel
  running_kernel="$(uname -r)"

  local default_kernel=""
  local default_kernel_path=""

  if command -v grubby > /dev/null 2>&1; then
    default_kernel_path="$(grubby --default-kernel 2> /dev/null || true)"
    default_kernel="${default_kernel_path#/boot/vmlinuz-}"
  fi

  if [[ -z "${default_kernel}" ]]; then
    default_kernel="$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core 2> /dev/null | sort -V | tail -n 1 || true)"
    if [[ -z "${default_kernel}" ]]; then
      default_kernel="$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel 2> /dev/null | sort -V | tail -n 1 || true)"
    fi
  fi

  local kernel_changed=0
  if [[ -n "${default_kernel}" && "${default_kernel}" != "${running_kernel}" ]]; then
    kernel_changed=1
  fi

  if [[ ${kernel_changed} -eq 1 ]]; then
    echo ""
    echo "=============================================================================="
    echo "[!] WARNING: System Kernel Upgrade Detected!"
    echo "------------------------------------------------------------------------------"
    echo "  Currently Running Kernel: ${running_kernel}"
    echo "  New Default Boot Kernel : ${default_kernel}"
    echo ""
    echo "  A system reboot is required to activate the newly deployed kernel."
    echo "  After rebooting, you may safely purge obsolete kernel packages by running:"
    echo "    sudo /opt/scripts/kernel-default.sh --cleanup"
    echo "=============================================================================="
    echo ""

    log_audit "Kernel upgrade detected: running ${running_kernel}, default ${default_kernel}" "dnf_check"

    if [[ ${auto_reboot} -eq 1 ]]; then
      echo "[*] Option --auto-reboot specified: Initiating automated system reboot in 5 seconds..."
      log_audit "Triggering automated reboot post-kernel upgrade via --auto-reboot" "dnf_check"
      sleep 5
      systemctl reboot 2> /dev/null || shutdown -r now 2> /dev/null || reboot
    fi
  else
    # Kernel did not change; check if core system libraries require a reboot
    if "${PKG_MGR}" needs-restarting --help >/dev/null 2>&1; then
      if ! "${PKG_MGR}" needs-restarting -r >/dev/null 2>&1; then
        echo ""
        echo "[!] NOTICE: Core system libraries (e.g. glibc, systemd, openssl) have been updated."
        echo "    A system reboot is recommended. Run 'sudo $(basename "$0") --needs-restarting' for details."
        echo ""
      fi
    fi
  fi
}

# ------------------------------------------------------------------------------
# 4. Argument Processing & Dispatch
# ------------------------------------------------------------------------------
do_verify_rpmdb=0
do_rebuild_rpmdb=0
do_sqlite_check=0
do_sqlite_vacuum=0
do_purge_cache=0
do_show_details=0
do_needs_restarting=0
relax_deps=0
auto_reboot=0
force_flag=0
is_mutating=0
dnf_args=()

for arg in "$@"; do
  case "${arg}" in
    --verify-rpmdb | --rpmdb-verify)
      do_verify_rpmdb=1
      ;;
    --rebuild-rpmdb | --rpmdb-rebuild)
      do_rebuild_rpmdb=1
      ;;
    --sqlite-check | --sqlite-close)
      do_sqlite_check=1
      ;;
    --sqlite-vacuum | --sqlite-checkpoint | --sqlite-optimize)
      do_sqlite_vacuum=1
      ;;
    --purge-cache)
      do_purge_cache=1
      ;;
    --show-update-details | --update-details)
      do_show_details=1
      ;;
    --needs-restarting)
      do_needs_restarting=1
      ;;
    --relax)
      relax_deps=1
      ;;
    --auto-reboot)
      auto_reboot=1
      ;;
    --force)
      force_flag=1
      ;;
    *)
      dnf_args+=("${arg}")
      case "${arg}" in
        update | upgrade | distro-sync | install | reinstall | remove | erase | upgrade-minimal)
          is_mutating=1
          ;;
      esac
      ;;
  esac
done

# Execute standalone maintenance tasks if requested
has_maintenance=0
maint_status=0

if [[ ${do_verify_rpmdb} -eq 1 ]]; then
  has_maintenance=1
  verify_rpmdb || maint_status=$?
  if [[ ${maint_status} -ne 0 ]]; then
    exit ${maint_status}
  fi
fi

if [[ ${do_rebuild_rpmdb} -eq 1 ]]; then
  has_maintenance=1
  rebuild_rpmdb || maint_status=$?
  if [[ ${maint_status} -ne 0 ]]; then
    exit ${maint_status}
  fi
fi

if [[ ${do_sqlite_check} -eq 1 ]]; then
  has_maintenance=1
  sqliteWalCheck || maint_status=$?
  if [[ ${maint_status} -ne 0 ]]; then
    exit ${maint_status}
  fi
fi

if [[ ${do_sqlite_vacuum} -eq 1 ]]; then
  has_maintenance=1
  sqliteWalVacuum || maint_status=$?
  if [[ ${maint_status} -ne 0 ]]; then
    exit ${maint_status}
  fi
fi

if [[ ${do_purge_cache} -eq 1 ]]; then
  has_maintenance=1
  echo "[*] Purging DNF cache via native package manager (${PKG_MGR})..."
  "${PKG_MGR}" clean all || maint_status=$?
  if [[ ${maint_status} -ne 0 ]]; then
    exit ${maint_status}
  fi
fi

if [[ ${do_show_details} -eq 1 ]]; then
  has_maintenance=1
  echo "[*] Querying detailed advisory and errata update information via ${PKG_MGR}..."
  "${PKG_MGR}" updateinfo info --updates || maint_status=$?
  if [[ ${maint_status} -ne 0 ]]; then
    exit ${maint_status}
  fi
fi

if [[ ${do_needs_restarting} -eq 1 ]]; then
  has_maintenance=1
  inspect_needs_restarting || maint_status=$?
  if [[ ${maint_status} -ne 0 ]]; then
    exit ${maint_status}
  fi
fi

# If standalone maintenance was performed and no further DNF commands remain, exit cleanly
if [[ ${has_maintenance} -eq 1 && ${#dnf_args[@]} -eq 0 ]]; then
  exit ${maint_status}
fi

# Ensure at least one DNF argument remains if no maintenance command ran
if [[ ${#dnf_args[@]} -eq 0 ]]; then
  show_usage >&2
  exit 2
fi

# ------------------------------------------------------------------------------
# 5. Pre-Flight Safeguards (Mutating Operations)
# ------------------------------------------------------------------------------
if [[ ${is_mutating} -eq 1 ]]; then
  if ! check_boot_capacity "${BOOT_MIN_FREE_MB}"; then
    if [[ ${force_flag} -eq 0 ]]; then
      echo "[-] Error: /boot free space is critically low. Aborting transaction to prevent initramfs corruption." >&2
      echo "    Hint: Run 'sudo /opt/scripts/kernel-default.sh --cleanup' to remove retired kernels, or pass '--force'." >&2
      exit 1
    else
      echo "[!] Warning: Proceeding with low /boot capacity due to '--force'." >&2
    fi
  fi
fi

# ------------------------------------------------------------------------------
# 6. DNF Execution & Post-Transaction Synchronization
# ------------------------------------------------------------------------------
# Append relaxed dependency options if requested
if [[ ${relax_deps} -eq 1 ]]; then
  dnf_args+=("${DNF_RELAX_OPTS[@]}")
fi

# Execute package manager with exact arguments preserved, safely capturing exit code under set -e
DNF_STATUS=0
"${PKG_MGR}" "${dnf_args[@]}" || DNF_STATUS=$?

# If command failed, abort immediately and preserve its exit code
if [[ ${DNF_STATUS} -ne 0 ]]; then
  exit ${DNF_STATUS}
fi

# Conditionally synchronize boot kernel only on mutating transactions
if [[ ${is_mutating} -eq 1 ]]; then
  if is_wsl; then
    echo "[i] WSL environment detected (kernel is managed by Windows host; skipping bootloader synchronization)."
  else
    kernel_script="${SCRIPT_DIR}/kernel-default.sh"
    [[ ! -x "${kernel_script}" ]] && kernel_script="/opt/scripts/kernel-default.sh"
    if [[ -x "${kernel_script}" ]]; then
      echo "[*] Synchronizing default boot kernel post-transaction..."
      "${kernel_script}"
    fi

    # Audit if installed kernel or core libraries differ from running environment
    verify_kernel_upgrade
  fi
fi

exit ${DNF_STATUS}
