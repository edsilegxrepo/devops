#!/usr/bin/env bash
# ==============================================================================
# Script: /opt/scripts/kernel-default.sh
# Version: 1.5.0  2026/11/06
# Compatibility: Enterprise Linux 8, 9, 10 (RHEL, AlmaLinux, Rocky Linux, CentOS)
# Standard: DRY Architecture Framework
# Description: Production-hardened GRUB boot kernel manager with multi-kernel
#              retention floors, dry-run cleanup, version resolution, rescue guards,
#              and /boot capacity monitoring.
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

# ------------------------------------------------------------------------------
# 2. CLI Usage & Help
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Function: show_usage
# Purpose:  Displays command syntax, options, and GRUB index selection rules.
# Arguments:
#   None.
# Returns:
#   Outputs usage documentation.
# ------------------------------------------------------------------------------
show_usage() {
  cat << EOF
Usage: $(basename "$0") [OPTIONS | INDEX]

Inspection Options:
  --default             Display currently configured default boot kernel and /boot usage
  --report              List all registered GRUB boot entries, kernels, and indexes
  -h, --help            Display this help message and exit

Default Kernel Management:
  <INDEX>               Non-negative integer index to assign as default (e.g. 0, 1)
  --latest              Assign latest kernel (index 0) as default
  --set <VERSION>       Find and assign kernel matching version string or substring
  --allow-rescue        Explicitly allow assigning a rescue kernel as default

Kernel Cleanup Options:
  --cleanup             Safely remove retired kernel packages (preserves running kernel)
  --keep <N>            Number of latest kernel versions to retain during cleanup (default: 2)
  --dry-run, -n         Preview retired kernel packages to be purged without modifying system
  --force               Override safety guards (e.g. allow cleanup when pending reboot)

Behavior:
  If no option or index is provided, defaults to index 0 (used by automated update hooks).

Compatibility:
  Enterprise Linux 8, 9, and 10 (UEFI and BIOS boot topologies).
EOF
}

# Allow non-root users to view help
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  show_usage
  exit 0
fi

# ------------------------------------------------------------------------------
# 3. Privilege & Dependency Guards
# ------------------------------------------------------------------------------
require_root

if is_wsl; then
  echo "[i] WSL environment detected (kernel is managed by Windows host; skipping bootloader configuration)."
  exit 0
fi

verify_dependencies "grubby" "${PKG_MGR}" "grep" "uname" "awk"

# ------------------------------------------------------------------------------
# 4. Helper Functions
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Function: get_boot_summary
# Purpose:  Returns formatted storage utilization string for /boot.
# Arguments:
#   None.
# Returns:
#   Outputs formatted partition metrics (e.g. "/boot (193M free / 62% used)").
# ------------------------------------------------------------------------------
get_boot_summary() {
  get_partition_summary "/boot"
}

# ------------------------------------------------------------------------------
# Function: find_index_by_version
# Purpose:  Resolves a kernel version string or substring to its GRUB entry index.
# Arguments:
#   $1 - Version string or substring (e.g. "6.12.0-211.74.1" or "el10_2").
# Returns:
#   Outputs index number if found, or returns 1 if no match found.
# ------------------------------------------------------------------------------
find_index_by_version() {
  local target_ver="$1"
  local matched_index
  matched_index="$(grubby --info=ALL 2>/dev/null | awk -v target="${target_ver}" '
    /^index=/ { idx = substr($0, 7) }
    /^kernel=/ || /^title=/ {
      if (index($0, target) > 0) {
        print idx
        exit
      }
    }
  ')"

  if [[ -n "${matched_index}" ]]; then
    echo "${matched_index}"
    return 0
  else
    return 1
  fi
}

# ------------------------------------------------------------------------------
# 5. Core Operational Functions
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Function: report_boot_kernel
# Purpose:  Queries and prints the currently active default GRUB boot kernel title,
#           vmlinuz path, entry index, and /boot storage utilization.
# Arguments:
#   None.
# Returns:
#   0.
# ------------------------------------------------------------------------------
report_boot_kernel() {
  echo "Current Default Boot Kernel:"
  local title kernel index boot_storage
  title="$(grubby --default-title 2> /dev/null || true)"
  kernel="$(grubby --default-kernel 2> /dev/null || true)"
  index="$(grubby --default-index 2> /dev/null || true)"
  boot_storage="$(get_boot_summary)"

  [[ -n "${title}" ]] && echo "  Title  : ${title}"
  [[ -n "${kernel}" ]] && echo "  Kernel : ${kernel}"
  [[ -n "${index}" ]] && echo "  Index  : ${index}"
  echo "  Storage: ${boot_storage}"
}

# ------------------------------------------------------------------------------
# Function: report_all_kernel_entries
# Purpose:  Enumerates all registered GRUB boot entries showing their indexes,
#           kernel binary paths, and descriptive titles.
# Arguments:
#   None.
# Returns:
#   0.
# ------------------------------------------------------------------------------
report_all_kernel_entries() {
  echo "Available GRUB Kernel Entries:"
  grubby --info=ALL 2> /dev/null | grep -E "^(index|kernel|title)=" || true
  echo ""
  echo "Storage: $(get_boot_summary)"
}

# ------------------------------------------------------------------------------
# Function: remove_old_kernels
# Purpose:  Safely identifies and purges retired installonly kernel packages via
#           the native package manager while strictly preserving the running kernel
#           and enforcing a minimum kernel retention floor.
# Arguments:
#   $1 - Minimum kernels to keep (default: 2)
#   $2 - Dry-run flag (1 = preview only, 0 = execute)
#   $3 - Force flag (1 = bypass pending reboot check)
# Returns:
#   0 on success; 1 if safety guard halts execution.
# ------------------------------------------------------------------------------
remove_old_kernels() {
  local keep_count="${1:-2}"
  local dry_run="${2:-0}"
  local force="${3:-0}"
  local current_kernel
  current_kernel="$(uname -r)"

  # Safety Guard: Check if a new kernel is installed but not yet booted
  local default_kernel=""
  local default_kernel_path
  default_kernel_path="$(grubby --default-kernel 2> /dev/null || true)"
  default_kernel="${default_kernel_path#/boot/vmlinuz-}"

  if [[ -n "${default_kernel}" && "${default_kernel}" != "${current_kernel}" && ${force} -eq 0 ]]; then
    echo "=============================================================================="
    echo "[!] SAFETY GUARD: Pending System Reboot Detected!"
    echo "------------------------------------------------------------------------------"
    echo "  Currently Running Kernel: ${current_kernel}"
    echo "  New Default Boot Kernel : ${default_kernel}"
    echo ""
    echo "  A newly installed kernel has NOT been booted yet."
    echo "  Purging older kernels now may remove your only known-good working fallback."
    echo "  Recommendation: Reboot first to test the new kernel, then re-run cleanup."
    echo "  To override this safety guard, re-run with: $(basename "$0") --cleanup --force"
    echo "=============================================================================="
    return 1
  fi

  echo "[*] Inspecting installed kernel packages (retention floor: keep latest ${keep_count})..."
  # Query installonly packages excluding the highest N versions
  local limit_arg="-${keep_count}"
  mapfile -t old_pkgs < <("${PKG_MGR}" repoquery --installonly --latest-limit="${limit_arg}" -q 2> /dev/null || true)

  if [[ ${#old_pkgs[@]} -eq 0 ]]; then
    echo "[+] No retired kernels found beyond the retention floor (${keep_count} kernels preserved)."
    return 0
  fi

  # Filter out empty entries and packages matching the currently running kernel
  local safe_pkgs=()
  for pkg in "${old_pkgs[@]}"; do
    [[ -z "${pkg}" ]] && continue
    if [[ "${pkg}" == *"${current_kernel}"* ]]; then
      echo "[!] Preserving active running kernel: ${pkg}"
    else
      safe_pkgs+=("${pkg}")
    fi
  done

  if [[ ${#safe_pkgs[@]} -eq 0 ]]; then
    echo "[+] No eligible retired kernels to remove (active and latest ${keep_count} kernels preserved)."
    return 0
  fi

  if [[ ${dry_run} -eq 1 ]]; then
    echo "[i] Dry-Run Mode: The following kernel package(s) would be removed:"
    printf "  - %s\n" "${safe_pkgs[@]}"
    echo "[+] Dry-run complete. No packages were removed."
    return 0
  fi

  echo "[*] Removing retired kernel packages:"
  printf "  - %s\n" "${safe_pkgs[@]}"
  "${PKG_MGR}" remove -y "${safe_pkgs[@]}"
  log_audit "Removed retired kernel packages: ${safe_pkgs[*]}" "kernel-default"
  echo "[+] Kernel cleanup completed successfully."
  echo "    Storage: $(get_boot_summary)"
  return 0
}

# Backward-compatibility aliases
reportBootKernel() { report_boot_kernel "$@"; }
reportAllkernelEntries() { report_all_kernel_entries "$@"; }
removeOldKernels() { remove_old_kernels "$@"; }

# ------------------------------------------------------------------------------
# 6. Argument Processing & Dispatch
# ------------------------------------------------------------------------------
ACTION=""
KERNEL_INDEX=""
KEEP_COUNT=2
DRY_RUN=0
FORCE_FLAG=0
ALLOW_RESCUE=0
SET_VERSION=""

# Helper to enforce mutual exclusivity between primary actions
set_action() {
  local new_action="$1"
  if [[ -n "${ACTION}" && "${ACTION}" != "${new_action}" ]]; then
    echo "[-] Error: Conflicting actions specified ('${ACTION}' and '${new_action}')." >&2
    echo "    Run '$(basename "$0") --help' for usage syntax." >&2
    exit 1
  fi
  ACTION="${new_action}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --default)
      set_action "default"
      shift
      ;;
    --report)
      set_action "report"
      shift
      ;;
    --cleanup)
      set_action "cleanup"
      shift
      ;;
    --dry-run | -n)
      DRY_RUN=1
      set_action "cleanup"
      shift
      ;;
    --force)
      FORCE_FLAG=1
      shift
      ;;
    --allow-rescue)
      ALLOW_RESCUE=1
      shift
      ;;
    --latest)
      set_action "set_index"
      KERNEL_INDEX=0
      shift
      ;;
    --keep)
      if [[ -z "${2:-}" || ! "$2" =~ ^[1-9][0-9]*$ ]]; then
        echo "[-] Error: --keep requires a positive integer argument (>= 1)." >&2
        exit 1
      fi
      KEEP_COUNT="$2"
      set_action "cleanup"
      shift 2
      ;;
    --set)
      if [[ -z "${2:-}" ]]; then
        echo "[-] Error: --set requires a kernel version string argument." >&2
        exit 1
      fi
      set_action "set_version"
      SET_VERSION="$2"
      shift 2
      ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        set_action "set_index"
        KERNEL_INDEX="$1"
        shift
      else
        echo "[-] Error: Unrecognized argument '$1'." >&2
        echo "" >&2
        show_usage >&2
        exit 1
      fi
      ;;
  esac
done

# Default action if no arguments provided: set index 0 (automated update hook behavior)
if [[ -z "${ACTION}" ]]; then
  ACTION="set_index"
  KERNEL_INDEX=0
fi

# ------------------------------------------------------------------------------
# 7. Action Execution
# ------------------------------------------------------------------------------
case "${ACTION}" in
  default)
    report_boot_kernel
    exit 0
    ;;
  report)
    report_all_kernel_entries
    exit 0
    ;;
  cleanup)
    remove_old_kernels "${KEEP_COUNT}" "${DRY_RUN}" "${FORCE_FLAG}"
    exit $?
    ;;
  set_version)
    echo "[*] Resolving GRUB index for kernel version '${SET_VERSION}'..."
    if ! KERNEL_INDEX="$(find_index_by_version "${SET_VERSION}")"; then
      echo "[-] Error: No GRUB boot entry matches kernel version '${SET_VERSION}'." >&2
      echo "" >&2
      report_all_kernel_entries >&2
      exit 1
    fi
    echo "[+] Found entry index '${KERNEL_INDEX}' matching '${SET_VERSION}'."
    ;;
  set_index)
    # KERNEL_INDEX is already set
    ;;
esac

# ------------------------------------------------------------------------------
# 8. Index Validation, Rescue Guard & Bootloader Assignment
# ------------------------------------------------------------------------------
# Validate index exists in GRUB
if ! grubby --info="${KERNEL_INDEX}" > /dev/null 2>&1 && ! grubby --info=ALL 2> /dev/null | grep -q "^index=${KERNEL_INDEX}$"; then
  echo "[-] Error: GRUB index '${KERNEL_INDEX}' does not exist." >&2
  echo "" >&2
  report_all_kernel_entries >&2
  exit 1
fi

# Rescue Kernel Safeguard
target_info="$(grubby --info="${KERNEL_INDEX}" 2>/dev/null || true)"
if [[ "${target_info}" == *"rescue"* && ${ALLOW_RESCUE} -eq 0 ]]; then
  echo "[-] SECURITY GUARD: Entry index '${KERNEL_INDEX}' appears to be a RESCUE kernel!" >&2
  echo "    Setting a rescue kernel as default may boot into emergency single-user recovery mode." >&2
  echo "    If you intentionally wish to boot the rescue kernel, pass '--allow-rescue'." >&2
  exit 1
fi

echo "[*] Assigning index '${KERNEL_INDEX}' to default kernel..."
report_all_kernel_entries
echo ""

if ! grubby --set-default-index="${KERNEL_INDEX}"; then
  echo "[-] Error: Failed to set default GRUB index (is /boot mounted read-only or full?)." >&2
  exit 1
fi

report_boot_kernel

# Verify post-assignment consistency
active_index="$(grubby --default-index 2> /dev/null || true)"
if [[ -n "${active_index}" && "${active_index}" != "${KERNEL_INDEX}" ]]; then
  echo "[!] Warning: Requested index was '${KERNEL_INDEX}', but GRUB reported default index '${active_index}'." >&2
  echo "[!] Ensure /etc/default/grub or saved_entry is not overriding index selection." >&2
fi

log_audit "Set default boot kernel to index ${KERNEL_INDEX}" "kernel-default"
