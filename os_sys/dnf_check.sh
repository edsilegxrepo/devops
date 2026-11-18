#!/usr/bin/env bash
# ==============================================================================
# Script: /opt/scripts/dnf_check.sh
# Version: 2.0.0  2026/11/18
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
  echo "[-] Fatal Error: Universal system foundation library not found at ${LIB_SYSTEM}" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "${LIB_SYSTEM}"
validate_rhel_os

# Verify package manager is DNF/YUM compatible
case "$(basename "${PKG_MGR}")" in
  dnf | dnf-* | yum) ;;
  *)
    echo "[-] Error: Unsupported package manager '${PKG_MGR}'. This wrapper requires dnf or yum." >&2
    exit 1
    ;;
esac

# Common paths and relaxed dependency options
DNF_RELAX_OPTS=(--skip-broken --nobest)
DNF_BASE="/var/lib/dnf"
DNF_CACHE="/var/cache/dnf"
BOOT_MIN_FREE_MB=100
sha1_audit_logged=0

# ------------------------------------------------------------------------------
# Function: get_rpmdb_dir
# Purpose:  Resolves the canonical RPM database directory path.
# ------------------------------------------------------------------------------
get_rpmdb_dir() {
  local rpm_dir="/var/lib/rpm"
  readlink -f "${rpm_dir}" 2>/dev/null || echo "${rpm_dir}"
}

# ------------------------------------------------------------------------------
# Function: get_rpmdb_bin
# Purpose:  Resolves the preferred RPM database maintenance binary (rpmdb or rpm).
# ------------------------------------------------------------------------------
get_rpmdb_bin() {
  if command -v rpmdb >/dev/null 2>&1; then
    echo "rpmdb"
  else
    echo "rpm"
  fi
}

# ------------------------------------------------------------------------------
# Function: get_rpm_pkg_count
# Purpose:  Safely counts installed RPM packages without pipeline masking.
# ------------------------------------------------------------------------------
get_rpm_pkg_count() {
  local count
  if count="$(rpm -qa 2>/dev/null | wc -l)"; then
    echo "${count}"
    return 0
  fi
  return 1
}

# ------------------------------------------------------------------------------
# Function: run_pkg_mgr
# Purpose:  Executes the configured package manager, scoping SHA-1 override when
#           --allow-sha1 is requested.
# ------------------------------------------------------------------------------
run_pkg_mgr() {
  if [[ ${allow_sha1:-0} -eq 1 ]]; then
    if [[ ${sha1_audit_logged:-0} -eq 0 ]]; then
      echo "[!] Warning: Permitting SHA-1 OpenSSL signatures for this transaction (--allow-sha1)." >&2
      log_audit "Running ${PKG_MGR} with OPENSSL_ENABLE_SHA1_SIGNATURES=1 (--allow-sha1)" "dnf_check"
      sha1_audit_logged=1
    fi
    env OPENSSL_ENABLE_SHA1_SIGNATURES=1 "${PKG_MGR}" "$@"
  else
    "${PKG_MGR}" "$@"
  fi
}

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
  --clean               Purge package/metadata cache, autoremove orphans, and vacuum SQLite DBs
  --verify-rpmdb        Inspect RPM database health, SQLite integrity, and transaction locks
  --rebuild-rpmdb       Safely rebuild RPM database with pre-rebuild backup snapshot
  --sqlite-check        Verify SQLite database integrity for DNF caches and history
  --sqlite-vacuum       Checkpoint WAL journals and vacuum SQLite databases to reclaim space
  --purge-cache         Safely purge DNF package and metadata cache via native clean
  --show-update-details Display detailed CVEs, severity, and errata for pending updates
  --needs-restarting    Inspect whether core libraries or active services require restart
  --relax               Permit non-best packages and skip broken dependencies (--skip-broken --nobest)
  --allow-sha1          Permit SHA-1 OpenSSL signatures for legacy RPM GPG keys
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
  rpm_real_dir="$(get_rpmdb_dir)"
  echo "[*] RPM Database Path: ${rpm_dir} -> ${rpm_real_dir}"

  local issues=0

  # 1. Inspect transaction lock
  local lock_file="${rpm_real_dir}/.rpm.lock"
  if [[ -f "${lock_file}" ]]; then
    echo "[*] Inspecting transaction lock: [${lock_file}]..."
    local locker_pids
    locker_pids="$(get_lock_pids "${lock_file}")"
    if [[ -n "${locker_pids}" ]]; then
      echo "[!] Lock is actively held by process PID(s): ${locker_pids}"
      local -a pids_arr=()
      read -r -a pids_arr <<< "${locker_pids}"
      ps -fp "${pids_arr[@]}" 2>/dev/null || true
    else
      if command -v fuser >/dev/null 2>&1 || command -v lsof >/dev/null 2>&1; then
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
  local rpmdb_bin
  rpmdb_bin="$(get_rpmdb_bin)"
  local verify_out
  if verify_out="$("${rpmdb_bin}" --verifydb 2>&1)"; then
    echo "OK"
  else
    echo "FAILED"
    echo "${verify_out}" >&2
    issues=$((issues + 1))
  fi

  # 4. Inventory count check
  local pkg_count=0
  if pkg_count="$(get_rpm_pkg_count)"; then
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
  running_procs="$(get_active_pkg_managers)"
  if [[ -n "${running_procs}" ]]; then
    echo "[-] Error: Active package management process(es) detected:" >&2
    echo "${running_procs}" >&2
    echo "[-] Aborting rebuild to prevent data race or active transaction corruption." >&2
    return 1
  fi

  local rpm_real_dir
  rpm_real_dir="$(get_rpmdb_dir)"
  local lock_file="${rpm_real_dir}/.rpm.lock"

  # 2. Check if .rpm.lock is actively held
  if [[ -f "${lock_file}" ]]; then
    if command -v fuser >/dev/null 2>&1 || command -v lsof >/dev/null 2>&1; then
      local locker_pids
      locker_pids="$(get_lock_pids "${lock_file}")"
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
  pre_count="$(get_rpm_pkg_count)" || pre_count=0
  echo "[*] Pre-rebuild package count: ${pre_count}"

  # 4. Pre-rebuild safety snapshot
  local backup_dir="/var/backups/rpmdb"
  local backup_user="${SYS_USER:-csysadm}"
  local backup_group="${SYS_GROUP:-root}"
  if ! mkdir -p "${backup_dir}"; then
    echo "[-] Error: Failed to create backup directory [${backup_dir}]. Aborting rebuild." >&2
    return 1
  fi
  chmod 0750 "${backup_dir}" || true
  chown "${backup_user}:${backup_group}" "${backup_dir}" 2>/dev/null || true

  local ts
  ts="$(date +%Y%m%d_%H%M%S)"
  local archive_path
  if ! archive_path="$(mktemp "${backup_dir}/rpmdb-pre-rebuild-${ts}-XXXXXX.tar.gz")"; then
    echo "[-] Error: Failed to create temporary backup archive in [${backup_dir}]. Aborting rebuild." >&2
    return 1
  fi

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
  local rpmdb_bin
  rpmdb_bin="$(get_rpmdb_bin)"

  local rebuild_status=0
  "${rpmdb_bin}" --rebuilddb || rebuild_status=$?

  if [[ ${rebuild_status} -ne 0 ]]; then
    echo "[-] Fatal: RPM database rebuild command (${rpmdb_bin} --rebuilddb) failed with exit code ${rebuild_status}!" >&2
    echo "    Safety snapshot is preserved at: ${archive_path}" >&2
    echo "    To restore manually: tar -xzf ${archive_path} -C ${rpm_parent}" >&2
    log_audit "RPM database rebuild failed with exit code ${rebuild_status}" "dnf_check"
    return "${rebuild_status}"
  fi
  echo "[+] Database rebuild command executed successfully."

  # 6. Post-rebuild validation
  echo "[*] Performing post-rebuild verification..."
  local verify_fail=0
  local verify_out
  if ! verify_out="$("${rpmdb_bin}" --verifydb 2>&1)"; then
    echo "[-] Warning: Post-rebuild native verification check failed!" >&2
    [[ -n "${verify_out}" ]] && echo "${verify_out}" >&2
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
  post_count="$(get_rpm_pkg_count)" || post_count=0
  echo "[*] Post-rebuild package count: ${post_count}"

  if [[ ${post_count} -eq 0 && ${pre_count} -gt 0 ]]; then
    echo "[-] ERROR: Package database is empty after rebuild (pre: ${pre_count}, post: 0)!" >&2
    log_audit "RPM database empty after rebuild (pre: ${pre_count}, backup: ${archive_path})" "dnf_check"
    return 1
  elif [[ ${pre_count} -gt 0 && ${post_count} -lt ${pre_count} ]]; then
    local diff=$((pre_count - post_count))
    echo "[!] WARNING: Package count decreased after rebuild by ${diff} package(s) (pre: ${pre_count}, post: ${post_count})!" >&2
    echo "    Inspect packages or restore safety snapshot at: ${archive_path}" >&2
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
# Function: _run_sqlite_batch
# Purpose:  Runs a SQLite maintenance helper across one or more database paths.
# Arguments:
#   $1 - Helper function name (sqlite_integrity_check | sqlite_vacuum_db)
#   $2 - Start banner message
#   $3 - Success banner message
#   $4 - Failure prefix message
#   $@ - Database paths
# ------------------------------------------------------------------------------
_run_sqlite_batch() {
  local fn="$1"
  local start_msg="$2"
  local ok_msg="$3"
  local fail_prefix="$4"
  shift 4

  if ! command -v sqlite3 > /dev/null 2>&1; then
    echo "[-] Error: 'sqlite3' CLI utility is not installed." >&2
    return 1
  fi

  local errors=0
  echo "${start_msg}"
  for db in "$@"; do
    "${fn}" "${db}" || errors=$((errors + 1))
  done

  if [[ ${errors} -eq 0 ]]; then
    echo "${ok_msg}"
    return 0
  else
    echo "[-] ${fail_prefix} (${errors} database(s))." >&2
    return 1
  fi
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
  _run_sqlite_batch \
    sqlite_integrity_check \
    "[*] Checking integrity of DNF SQLite databases..." \
    "[+] All DNF SQLite database integrity checks passed." \
    "Integrity errors detected in" \
    "${DNF_CACHE}/packages.db" \
    "${DNF_BASE}/history.sqlite"
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
  local rpm_real_dir
  rpm_real_dir="$(get_rpmdb_dir)"
  _run_sqlite_batch \
    sqlite_vacuum_db \
    "[*] Checkpointing and vacuuming DNF & RPM SQLite databases..." \
    "[+] All SQLite databases vacuumed and checkpointed successfully." \
    "Errors encountered vacuuming" \
    "${DNF_CACHE}/packages.db" \
    "${DNF_BASE}/history.sqlite" \
    "${rpm_real_dir}/rpmdb.sqlite"
}

# Backward-compatibility aliases
# shellcheck disable=SC2329
sqlite_wal_check() { sqliteWalCheck "$@"; }
# shellcheck disable=SC2329
sqliteWalClean() { sqliteWalCheck "$@"; }

# ------------------------------------------------------------------------------
# Function: clean_dnf_system
# Purpose:  Comprehensive package and database cleanup: purges DNF metadata and
#           package caches, autoremoves orphaned packages, and vacuums SQLite DBs.
# Arguments:
#   None.
# Returns:
#   0 on success; 1 on failure.
# ------------------------------------------------------------------------------
clean_dnf_system() {
  echo "=============================================================================="
  echo "[*] Comprehensive DNF & SQLite Package System Maintenance"
  echo "=============================================================================="

  local err=0

  local pre_default_kernel=""
  if ! is_wsl; then
    pre_default_kernel="$(get_default_boot_kernel)"
  fi

  # 1. Purge DNF package and metadata cache
  echo "[*] Purging DNF cache via '${PKG_MGR} clean all'..."
  run_pkg_mgr clean all || err=$((err + 1))

  # 2. Autoremove unneeded orphaned dependencies
  echo "[*] Removing orphaned packages via '${PKG_MGR} autoremove -y'..."
  run_pkg_mgr autoremove -y || err=$((err + 1))

  # 3. Checkpoint WAL journals and vacuum DNF + RPM SQLite databases
  sqliteWalVacuum || err=$((err + 1))

  if [[ ${err} -eq 0 ]] && ! is_wsl; then
    verify_kernel_upgrade "${pre_default_kernel}"
  fi

  echo "=============================================================================="
  if [[ ${err} -eq 0 ]]; then
    echo "[+] DNF and SQLite system cleanup completed successfully."
    return 0
  else
    echo "[-] DNF cleanup completed with ${err} error(s)." >&2
    return 1
  fi
}

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
#           or triggers automated reboot if --auto-reboot was supplied and this
#           transaction changed the default boot kernel.
# Arguments:
#   $1 (Optional) - Pre-transaction default boot kernel version.
# Returns:
#   0.
# ------------------------------------------------------------------------------
verify_kernel_upgrade() {
  local pre_default_kernel="${1:-}"
  if is_wsl; then
    echo "[i] WSL environment detected (kernel is managed by Windows host)."
    return 0
  fi

  local running_kernel
  running_kernel="$(uname -r)"

  local default_kernel
  default_kernel="$(get_default_boot_kernel)"

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
      if [[ -z "${pre_default_kernel}" || "${default_kernel}" != "${pre_default_kernel}" ]]; then
        echo "[*] Option --auto-reboot specified: Initiating automated system reboot in 5 seconds..."
        log_audit "Triggering automated reboot post-kernel upgrade via --auto-reboot" "dnf_check"
        sleep 5
        systemctl reboot 2> /dev/null || shutdown -r now 2> /dev/null || reboot
      else
        echo "[i] Pending kernel reboot predates this transaction; skipping --auto-reboot."
      fi
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
do_clean=0
do_verify_rpmdb=0
do_rebuild_rpmdb=0
do_sqlite_check=0
do_sqlite_vacuum=0
do_purge_cache=0
do_show_details=0
do_needs_restarting=0
relax_deps=0
allow_sha1=0
auto_reboot=0
force_flag=0
is_mutating=0
needs_boot_check=0
has_dry_run_or_help=0
saw_help=0
dnf_args=()

for arg in "$@"; do
  case "${arg}" in
    --clean | --clean-all)
      do_clean=1
      ;;
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
    --allow-sha1)
      allow_sha1=1
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
        -h | --help)
          saw_help=1
          has_dry_run_or_help=1
          ;;
        --downloadonly | --assumeno | *tsflags=*test*)
          has_dry_run_or_help=1
          ;;
      esac
      ;;
  esac
done

# Identify the first two positional DNF subcommand tokens (skipping DNF option flags and their values)
dnf_subcmd=""
dnf_subaction=""
skip_next=0
if [[ ${#dnf_args[@]} -gt 0 ]]; then
  for arg in "${dnf_args[@]}"; do
    if [[ ${skip_next} -eq 1 ]]; then
      skip_next=0
      continue
    fi
    case "${arg}" in
      --)
        break
        ;;
      -c | --config | --installroot | --releasever | --setopt | --repo | --repoid | --enablerepo | --disablerepo | --exclude | -x | --destdir | --downloaddir | --forcearch)
        skip_next=1
        ;;
      -*)
        ;;
      *)
        if [[ -z "${dnf_subcmd}" ]]; then
          dnf_subcmd="${arg}"
        else
          dnf_subaction="${arg}"
          break
        fi
        ;;
    esac
  done
fi

if [[ ${saw_help} -eq 1 && -z "${dnf_subcmd}" && $((do_clean + do_verify_rpmdb + do_rebuild_rpmdb + do_sqlite_check + do_sqlite_vacuum + do_purge_cache + do_show_details + do_needs_restarting)) -eq 0 ]]; then
  show_usage
  exit 0
fi

# Privilege guard: all functional actions require root / sudo
require_root

case "${dnf_subcmd}" in
  update | upgrade | distro-sync | install | reinstall | upgrade-minimal | downgrade | swap | localinstall | groupinstall | groupupdate)
    is_mutating=1
    needs_boot_check=1
    ;;
  remove | erase | autoremove | groupremove)
    is_mutating=1
    ;;
  group | module)
    case "${dnf_subaction}" in
      install | update | upgrade)
        is_mutating=1
        needs_boot_check=1
        ;;
      remove | erase)
        is_mutating=1
        ;;
    esac
    ;;
  history)
    case "${dnf_subaction}" in
      undo | redo | rollback)
        is_mutating=1
        needs_boot_check=1
        ;;
    esac
    ;;
esac

if [[ ${has_dry_run_or_help} -eq 1 ]]; then
  is_mutating=0
  needs_boot_check=0
fi

# Execute standalone maintenance tasks if requested
has_maintenance=0
maint_status=0

_check_maint_status() {
  has_maintenance=1
  if [[ ${maint_status} -ne 0 ]]; then
    exit "${maint_status}"
  fi
}

if [[ ${do_clean} -eq 1 ]]; then clean_dnf_system || maint_status=$?; _check_maint_status; fi
if [[ ${do_verify_rpmdb} -eq 1 ]]; then verify_rpmdb || maint_status=$?; _check_maint_status; fi
if [[ ${do_rebuild_rpmdb} -eq 1 ]]; then rebuild_rpmdb || maint_status=$?; _check_maint_status; fi
if [[ ${do_sqlite_check} -eq 1 ]]; then sqliteWalCheck || maint_status=$?; _check_maint_status; fi
if [[ ${do_sqlite_vacuum} -eq 1 ]]; then sqliteWalVacuum || maint_status=$?; _check_maint_status; fi
if [[ ${do_purge_cache} -eq 1 ]]; then
  echo "[*] Purging DNF cache via native package manager (${PKG_MGR})..."
  run_pkg_mgr clean all || maint_status=$?
  _check_maint_status
fi
if [[ ${do_show_details} -eq 1 ]]; then
  echo "[*] Querying detailed advisory and errata update information via ${PKG_MGR}..."
  run_pkg_mgr updateinfo info --updates || maint_status=$?
  _check_maint_status
fi
if [[ ${do_needs_restarting} -eq 1 ]]; then inspect_needs_restarting || maint_status=$?; _check_maint_status; fi

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
if [[ ${needs_boot_check} -eq 1 ]]; then
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

pre_default_kernel=""
if [[ ${is_mutating} -eq 1 ]] && ! is_wsl; then
  pre_default_kernel="$(get_default_boot_kernel)"
fi

# Execute package manager with exact arguments preserved, safely capturing exit code under set -e
DNF_STATUS=0
run_pkg_mgr "${dnf_args[@]}" || DNF_STATUS=$?

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
    verify_kernel_upgrade "${pre_default_kernel}"
  fi
fi

exit ${DNF_STATUS}
