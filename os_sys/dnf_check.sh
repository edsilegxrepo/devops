#!/usr/bin/env bash
# ==============================================================================
# Script: /opt/scripts/dnf_check.sh
# Version: 1.3.0  2026/10/02
# Compatibility: Enterprise Linux 8, 9, 10 (RHEL, AlmaLinux, Rocky Linux, CentOS)
# Standard: DRY Architecture Framework
# Description: Production-hardened DNF wrapper with cross-version SQLite integrity
#              checks, safe cache clearing, and post-transaction kernel sync.
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# 1. Environment & Library Initialization
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_COMMON="${SCRIPT_DIR}/lib/common.sh"
if [[ -f "${LIB_COMMON}" ]]; then
  # shellcheck source=/dev/null
  source "${LIB_COMMON}"
fi

# Ensure standard system umask for package manager execution
umask 022

# Fallback definition if common.sh is missing or does not define require_root
if ! declare -f require_root > /dev/null 2>&1; then
  require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
      echo "[-] Error: Root privileges are required to run dnf." >&2
      exit 1
    fi
  }
fi

# Determine primary package manager binary (dnf on EL8/9/10, fallback to yum)
PKG_MGR="$(command -v dnf 2> /dev/null || command -v yum 2> /dev/null || echo "dnf")"

# ------------------------------------------------------------------------------
# 2. CLI Usage & Help
# ------------------------------------------------------------------------------
show_usage() {
  cat << EOF
Usage: $(basename "$0") [OPTION] | [DNF_COMMAND...]

Options:
  --sqlite-check      Verify SQLite database integrity for DNF caches and history
  --purge-cache       Safely purge DNF package and metadata cache via native clean
  -h, --help          Display this help message and exit

DNF Pass-Through:
  Any other arguments are passed directly to '${PKG_MGR}' (e.g. update, install, search).
  On successful mutating transactions (update, install, etc.), the default boot
  kernel is automatically synchronized via kernel-default.sh.

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
# 3. Core Functions
# ------------------------------------------------------------------------------
sqliteWalCheck() {
  if ! command -v sqlite3 > /dev/null 2>&1; then
    echo "[-] Error: 'sqlite3' CLI utility is not installed." >&2
    return 1
  fi

  local databases=(
    "/var/cache/dnf/packages.db"
    "/var/lib/dnf/history.sqlite"
  )

  local errors=0
  echo "[*] Checking integrity of DNF SQLite databases..."
  for db in "${databases[@]}"; do
    if [[ ! -f "${db}" ]]; then
      echo "[-] Notice: Database [${db}] does not exist, skipping."
      continue
    fi

    echo -n "    Checking integrity of [${db}]... "
    local result
    result="$(sqlite3 "${db}" 'PRAGMA integrity_check;' 2>&1 || true)"
    if [[ "${result}" == "ok" ]]; then
      echo "OK"
    else
      echo "FAILED (${result})"
      errors=$((errors + 1))
    fi

    # Check for presence of active WAL journal
    if [[ -f "${db}-wal" ]]; then
      local wal_size
      wal_size="$(stat -c %s "${db}-wal" 2> /dev/null || stat -f %z "${db}-wal" 2> /dev/null || echo "unknown")"
      echo "    [i] Active WAL journal detected: [${db}-wal] (${wal_size} bytes)"
    fi
  done

  if [[ ${errors} -eq 0 ]]; then
    echo "[+] All DNF SQLite database integrity checks passed."
    return 0
  else
    echo "[-] Errors detected in ${errors} database(s)." >&2
    return 1
  fi
}

# Backward-compatibility aliases
# shellcheck disable=SC2329
sqlite_wal_check() { sqliteWalCheck "$@"; }
# shellcheck disable=SC2329
sqliteWalClean() { sqliteWalCheck "$@"; }

# ------------------------------------------------------------------------------
# 4. Command Dispatch
# ------------------------------------------------------------------------------
case "$1" in
  --sqlite-check | --sqlite-close)
    sqliteWalCheck
    exit $?
    ;;
  --purge-cache)
    echo "[*] Purging DNF cache via native package manager (${PKG_MGR})..."
    "${PKG_MGR}" clean all
    exit $?
    ;;
esac

# ------------------------------------------------------------------------------
# 5. DNF Execution & Post-Transaction Synchronization
# ------------------------------------------------------------------------------
# Determine if command invocation represents a mutating package transaction
is_mutating=0
for arg in "$@"; do
  case "${arg}" in
    update | upgrade | distro-sync | install | reinstall | remove | erase | upgrade-minimal)
      is_mutating=1
      break
      ;;
  esac
done

# Execute package manager with exact arguments preserved
"${PKG_MGR}" "$@"
DNF_STATUS=$?

# If command failed, abort immediately and preserve its exit code
if [[ ${DNF_STATUS} -ne 0 ]]; then
  exit ${DNF_STATUS}
fi

# Conditionally synchronize boot kernel only on mutating transactions
if [[ ${is_mutating} -eq 1 ]]; then
  kernel_script="${SCRIPT_DIR}/kernel-default.sh"
  [[ ! -x "${kernel_script}" ]] && kernel_script="/opt/scripts/kernel-default.sh"
  if [[ -x "${kernel_script}" ]]; then
    echo "[*] Synchronizing default boot kernel post-transaction..."
    "${kernel_script}"
  fi
fi

exit ${DNF_STATUS}
