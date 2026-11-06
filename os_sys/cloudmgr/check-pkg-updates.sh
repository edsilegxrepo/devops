#!/usr/bin/env bash
# ==============================================================================
# Script:      /opt/scripts/check-pkg-updates.sh
# Version:     1.0.0  2026/11/05
# Standard:    DRY Architecture Framework (lib/common.sh)
# Author:      DevOps Systems Administration <criticalsys.mis@gmail.com>
# Compatibility: Enterprise Linux 8, 9, 10 (RHEL, AlmaLinux, Rocky Linux)
# Description: Non-intrusively inspects upstream package repositories for available
#              operating system package updates, correlates security errata and
#              bugfixes, generates rich HTML advisory reports, and notifies
#              administrators according to sysadmin policy.
# ==============================================================================
set -euo pipefail
umask 077
shopt -u patsub_replacement 2> /dev/null || true

# ------------------------------------------------------------------------------
# 1. Environment & Library Initialization
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_COMMON="${SCRIPT_DIR}/lib/common.sh"
if [[ ! -f "${LIB_COMMON}" ]]; then
  echo "[-] Fatal Error: Shared library not found at ${LIB_COMMON}" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "${LIB_COMMON}"

TEMPLATES_DIR="${SCRIPT_DIR}/templates/pkg-update"
TEMPLATE_SUMMARY_GRID="${TEMPLATES_DIR}/summary-grid.html"
TEMPLATE_ROW="${TEMPLATES_DIR}/table-row.html"
TEMPLATE_INSTR_PENDING="${TEMPLATES_DIR}/instructions-pending.html"
TEMPLATE_INSTR_UPTODATE="${TEMPLATES_DIR}/instructions-uptodate.html"

# Capture raw CLI arguments for execution logging
CLI_ARGS="$*"

# Operational Flags
CHECK_ONLY=0
FORCE_NOTIFY=0
CLI_NOTIFY_NEW_ONLY=""
CLI_SECURITY_ONLY=""
CLI_REFRESH=""
MOCK_PENDING=0

# ------------------------------------------------------------------------------
# 2. Argument Parsing
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Function: show_help
# Purpose:  Displays command syntax, options, and operational modes to stdout.
# Arguments:
#   None.
# Returns:
#   Outputs help documentation.
# ------------------------------------------------------------------------------
show_help() {
  cat << EOF
Usage: $(basename "$0") [OPTIONS]

OS package update advisor and security vulnerability detection tool.
Inspects configured repositories via DNF/YUM and sends an email advisory
report. Execution logs are maintained in /var/log/jobs/pkg-updates-<DATESTAMP>.log
(14-day retention).

Options:
  --notify-new-only         Only send email if package updates are detected; remain silent otherwise.
  --notify-all              Send email notification even if all packages are up to date.
  --check-only, --dry-run   Print scan results to stdout; do not send email.
  --security-only           Only check and alert on security-related errata / updates.
  --refresh                 Force DNF to refresh repository metadata before scan (default).
  --no-refresh              Use local repository cache without forcing metadata refresh.
  --simulate-updates        Simulate detected package updates to verify alerting pipeline.
  --force, --test, --always-notify
                            Force sending notification email regardless of update status.
  -h, --help                Show this help message.
EOF
}

while [[ $# -gt 0 ]]; do
  if handle_common_cli_option "$1"; then
    shift
    continue
  fi
  case "$1" in
    --security-only)
      CLI_SECURITY_ONLY="true"
      shift
      ;;
    --refresh)
      CLI_REFRESH="true"
      shift
      ;;
    --no-refresh)
      CLI_REFRESH="false"
      shift
      ;;
    --simulate-updates | --mock-pending)
      MOCK_PENDING=1
      shift
      ;;
    *)
      echo "[-] Error: Unknown argument: $1" >&2
      show_help >&2
      exit 1
      ;;
  esac
done

# ------------------------------------------------------------------------------
# 3. Bootstrap, Guards & Configuration Locking
# ------------------------------------------------------------------------------
bootstrap_job "pkg-updates" \
  --require-root \
  --deps "dnf rpm sed awk grep mktemp" \
  --log-dir "${LOG_BASE_DIR:-/var/log/jobs}" \
  --retention "${LOG_RETENTION_DAYS:-14}"

# CLI flag overrides configuration file settings
[[ -n "${CLI_NOTIFY_NEW_ONLY}" ]] && NOTIFY_NEW_ONLY="${CLI_NOTIFY_NEW_ONLY}"
[[ -n "${CLI_SECURITY_ONLY}" ]] && CHECK_SECURITY_ONLY="${CLI_SECURITY_ONLY}"
[[ -n "${CLI_REFRESH}" ]] && REFRESH_METADATA="${CLI_REFRESH}"

# ------------------------------------------------------------------------------
# 4. Repository Inspection Execution
# ------------------------------------------------------------------------------
DNF_EXTRA_OPTS=()
[[ "${REFRESH_METADATA:-true}" == "true" ]] && DNF_EXTRA_OPTS+=("--refresh")

log_msg "[*] Starting package update inspection on ${SYS_HOSTNAME}..."
[[ -n "${CLI_ARGS}" ]] && log_msg "[*] Invocation options: ${CLI_ARGS}"
log_msg "[*] Mode: Dry-Run Repository Inspection via '${PKG_MGR:-dnf} check-update ${DNF_EXTRA_OPTS[*]:-}'"

RAW_SCAN_ERR_TMP="$(mktemp /tmp/pkg-scan-err.XXXXXX)"
register_cleanup "rm -f '${RAW_SCAN_ERR_TMP}'"

RAW_SCAN_OUT_TMP="$(mktemp /tmp/pkg-scan-out.XXXXXX)"
register_cleanup "rm -f '${RAW_SCAN_OUT_TMP}'"

RAW_QUERY_OUT_TMP="$(mktemp /tmp/pkg-query-out.XXXXXX)"
register_cleanup "rm -f '${RAW_QUERY_OUT_TMP}'"

SEC_INFO_TMP="$(mktemp /tmp/pkg-sec-info.XXXXXX)"
register_cleanup "rm -f '${SEC_INFO_TMP}'"

BUG_INFO_TMP="$(mktemp /tmp/pkg-bug-info.XXXXXX)"
register_cleanup "rm -f '${BUG_INFO_TMP}'"

ENH_INFO_TMP="$(mktemp /tmp/pkg-enh-info.XXXXXX)"
register_cleanup "rm -f '${ENH_INFO_TMP}'"

# Execute DNF check-update
# DNF Exit codes: 0 = no updates, 100 = updates available, 1 = fatal error
scan_exit=0
timeout "${CHECK_TIMEOUT:-600}" "${PKG_MGR:-dnf}" check-update "${DNF_EXTRA_OPTS[@]}" > "${RAW_SCAN_OUT_TMP}" 2> "${RAW_SCAN_ERR_TMP}" || scan_exit=$?

if [[ "${scan_exit}" -ne 0 && "${scan_exit}" -ne 100 ]]; then
  dispatch_failure_alert \
    --title "Package Update Advisor" \
    --category "Operating System Lifecycle" \
    --message "Repository package update check failed during inspection execution (exit code ${scan_exit})." \
    --err-file "${RAW_SCAN_ERR_TMP}" \
    --terminal-title "Repository Scan Diagnostic Stderr"
fi

TOTAL_COUNT=0
SECURITY_COUNT=0
BUGFIX_COUNT=0
ENHANCEMENT_COUNT=0
OTHER_COUNT=0

declare -a PACKAGES_DATA=()

if [[ "${scan_exit}" -eq 100 ]]; then
  log_msg "[*] Package updates detected. Correlating errata and advisories..."

  # Query security, bugfix, and enhancement advisories for available updates
  "${PKG_MGR:-dnf}" updateinfo list --security -q > "${SEC_INFO_TMP}" 2>/dev/null || true
  "${PKG_MGR:-dnf}" updateinfo list --bugfix -q > "${BUG_INFO_TMP}" 2>/dev/null || true
  "${PKG_MGR:-dnf}" updateinfo list --enhancement -q > "${ENH_INFO_TMP}" 2>/dev/null || true

  # Build in-memory advisory lookup maps (O(1) lookups, immune to regex characters)
  declare -A SEC_MAP=()
  declare -A BUG_MAP=()
  declare -A ENH_MAP=()

  # Helper to parse errata package names and advisory keys from DNF updateinfo
  parse_updateinfo_list() {
    local file="$1"
    local col="${2:-1}"
    awk -v c="${col}" '{
      pkg = $NF
      sub(/\.[^.]+$/, "", pkg)
      sub(/-[^-]+$/, "", pkg)
      sub(/-[^-]+$/, "", pkg)
      print $c, pkg
    }' "${file}"
  }

  while read -r adv_sev pkg; do
    [[ -n "${pkg}" ]] && SEC_MAP["${pkg}"]="${adv_sev}"
  done < <(parse_updateinfo_list "${SEC_INFO_TMP}" 2)

  while read -r _adv_id pkg; do
    [[ -n "${pkg}" ]] && BUG_MAP["${pkg}"]="BUGFIX"
  done < <(parse_updateinfo_list "${BUG_INFO_TMP}" 1)

  while read -r _adv_id pkg; do
    [[ -n "${pkg}" ]] && ENH_MAP["${pkg}"]="ENHANCEMENT"
  done < <(parse_updateinfo_list "${ENH_INFO_TMP}" 1)

  # Query structured package list (name, arch, evr, reponame)
  if [[ "${CHECK_SECURITY_ONLY}" == "true" ]]; then
    "${PKG_MGR:-dnf}" repoquery --upgrades --security -q --queryformat "%{name}\t%{arch}\t%{evr}\t%{reponame}" > "${RAW_QUERY_OUT_TMP}" 2>/dev/null || true
  else
    "${PKG_MGR:-dnf}" repoquery --upgrades -q --queryformat "%{name}\t%{arch}\t%{evr}\t%{reponame}" > "${RAW_QUERY_OUT_TMP}" 2>/dev/null || true
  fi

  # Filter exclusions and parse each package candidate
  while IFS=$'\t' read -r pkg_name pkg_arch pkg_evr pkg_repo; do
    [[ -z "${pkg_name}" ]] && continue

    # Check exclusions
    if [[ -n "${EXCLUDED_PACKAGES:-}" ]]; then
      skip_pkg=0
      for excl in ${EXCLUDED_PACKAGES}; do
        # shellcheck disable=SC2053
        if [[ "${pkg_name}" == ${excl} ]]; then
          skip_pkg=1
          break
        fi
      done
      [[ ${skip_pkg} -eq 1 ]] && continue
    fi

    # Determine installed version via local package database query
    if installed_ver="$(rpm -q --qf "%{evr}" "${pkg_name}.${pkg_arch}" 2>/dev/null)" || \
       installed_ver="$(rpm -q --qf "%{evr}" "${pkg_name}" 2>/dev/null)"; then
      :
    else
      installed_ver="not installed"
    fi

    # Correlate with updateinfo advisories
    adv_badge_type="warning"
    adv_label="UPDATE"

    sec_match="${SEC_MAP["${pkg_name}"]:-}"
    if [[ -n "${sec_match}" ]]; then
      SECURITY_COUNT=$((SECURITY_COUNT + 1))
      if [[ "${sec_match}" =~ [Cc]ritical ]]; then
        adv_badge_type="failed"
        adv_label="⚡ CRITICAL SEC"
      elif [[ "${sec_match}" =~ [Ii]mportant ]]; then
        adv_badge_type="failed"
        adv_label="⚡ IMPORTANT SEC"
      elif [[ "${sec_match}" =~ [Mm]oderate ]]; then
        adv_badge_type="warning"
        adv_label="MODERATE SEC"
      else
        adv_badge_type="warning"
        adv_label="LOW SEC"
      fi
    elif [[ -n "${BUG_MAP["${pkg_name}"]:-}" ]]; then
      adv_badge_type="info"
      adv_label="BUGFIX"
      BUGFIX_COUNT=$((BUGFIX_COUNT + 1))
    elif [[ -n "${ENH_MAP["${pkg_name}"]:-}" ]]; then
      adv_badge_type="info"
      adv_label="ENHANCEMENT"
      ENHANCEMENT_COUNT=$((ENHANCEMENT_COUNT + 1))
    else
      OTHER_COUNT=$((OTHER_COUNT + 1))
    fi

    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    PACKAGES_DATA+=("${pkg_name}"$'\t'"${pkg_arch}"$'\t'"${installed_ver}"$'\t'"${pkg_evr}"$'\t'"${pkg_repo}"$'\t'"${adv_badge_type}"$'\t'"${adv_label}")
  done < "${RAW_QUERY_OUT_TMP}"
fi

if [[ "${MOCK_PENDING}" -eq 1 ]]; then
  log_msg "[!] Simulation Mode: Injecting mock pending package updates for notification verification..."
  TOTAL_COUNT=2
  SECURITY_COUNT=1
  BUGFIX_COUNT=1
  ENHANCEMENT_COUNT=0
  OTHER_COUNT=0
  PACKAGES_DATA=(
    "openssl"$'\t'"x86_64"$'\t'"1:3.2.2-6.el10_2"$'\t'"1:3.2.2-7.el10_2"$'\t'"baseos"$'\t'"failed"$'\t'"⚡ IMPORTANT SEC"
    "systemd"$'\t'"x86_64"$'\t'"256.7-1.el10_2"$'\t'"256.7-2.el10_2"$'\t'"baseos"$'\t'"info"$'\t'"BUGFIX"
  )
fi

log_msg "[*] Scan complete: ${TOTAL_COUNT} updates available | ${SECURITY_COUNT} security | ${BUGFIX_COUNT} bugfix | ${ENHANCEMENT_COUNT} enhancement | ${OTHER_COUNT} general"

# ------------------------------------------------------------------------------
# 5. Check-Only Output Handler
# ------------------------------------------------------------------------------
if [[ "${CHECK_ONLY}" -eq 1 ]]; then
  echo "========================================================================================================================"
  printf "%-32s %-10s %-26s %-26s %-16s\n" "PACKAGE NAME" "ARCH" "CURRENT VERSION" "AVAILABLE VERSION" "ADVISORY"
  echo "========================================================================================================================"

  for entry in "${PACKAGES_DATA[@]}"; do
    IFS=$'\t' read -r pkg_name pkg_arch installed_ver pkg_evr pkg_repo adv_badge_type adv_label <<< "${entry}"
    printf "%-32s %-10s %-26s %-26s %-16s\n" "${pkg_name}" "${pkg_arch}" "${installed_ver}" "${pkg_evr}" "${adv_label}"
  done

  echo "========================================================================================================================"
  echo "Summary: ${TOTAL_COUNT} package updates available (${SECURITY_COUNT} security, ${BUGFIX_COUNT} bugfix, ${ENHANCEMENT_COUNT} enhancement)."

  if [[ "${TOTAL_COUNT}" -gt 0 ]]; then
    echo -e "\nRecommended action (safe DNF wrapper + bootloader sync):"
    echo "  sudo /opt/scripts/dnf_check.sh update -y"
    if [[ "${SECURITY_COUNT}" -gt 0 ]]; then
      echo -e "\nOr apply security errata only:"
      echo "  sudo /opt/scripts/dnf_check.sh --security update -y"
    fi
    echo -e "\nInspect detailed advisory CVEs and descriptions:"
    echo "  sudo /opt/scripts/dnf_check.sh --show-update-details"
  fi
  exit 0
fi

# ------------------------------------------------------------------------------
# 6. Notification Evaluation & Assembly
# ------------------------------------------------------------------------------
if [[ "${FORCE_NOTIFY}" -eq 0 && "${NOTIFY_NEW_ONLY}" == "true" && "${TOTAL_COUNT}" -eq 0 ]]; then
  suppress_reason="NOTIFY_NEW_ONLY configured"
  [[ "${CLI_NOTIFY_NEW_ONLY}" == "true" ]] && suppress_reason="--notify-new-only active"
  log_msg "[*] Notification policy: All packages up to date. Suppressing email notification (${suppress_reason})."
  exit 0
fi

log_msg "[*] Generating HTML email report..."

# Determine Status Badge & Subject
status_type="success"
badge_icon="✓"
badge_label="UP TO DATE"
if [[ "${SECURITY_COUNT}" -gt 0 ]]; then
  status_type="warning"
  badge_icon="⚡"
  badge_label="SECURITY UPDATES"
  SUBJECT="[ALERT] Security Updates Available - ${SYS_HOSTNAME} (${SECURITY_COUNT} pending)"
  PENDING_SUMMARY="<span style=\"color: #b45309; font-weight: 700;\">${TOTAL_COUNT} package update(s) available</span>"
  SECURITY_SUMMARY="<span style=\"color: #dc2626; font-weight: 700;\">${SECURITY_COUNT} security advisory update(s) pending</span>"
  POLICY_MODE="Dry-Run Repository Scan &bull; <strong>Security Advisory Alert</strong>"
elif [[ "${TOTAL_COUNT}" -gt 0 ]]; then
  status_type="warning"
  badge_icon="⚡"
  badge_label="UPDATES PENDING"
  SUBJECT="[REVIEW] Package Updates Available - ${SYS_HOSTNAME} (${TOTAL_COUNT} pending)"
  PENDING_SUMMARY="<span style=\"color: #b45309; font-weight: 700;\">${TOTAL_COUNT} package update(s) pending review</span>"
  SECURITY_SUMMARY="<span style=\"color: #059669; font-weight: 700;\">0 (No security vulnerabilities)</span>"
  POLICY_MODE="Dry-Run Repository Scan &bull; <strong>Controlled Production</strong>"
else
  status_type="success"
  badge_icon="✓"
  badge_label="UP TO DATE"
  SUBJECT="[INFO] Packages Up to Date - ${SYS_HOSTNAME}"
  PENDING_SUMMARY="<span style=\"color: #059669; font-weight: 700;\">0 (All installed packages are current)</span>"
  SECURITY_SUMMARY="<span style=\"color: #059669; font-weight: 700;\">0 (All security errata applied)</span>"
  POLICY_MODE="Dry-Run Repository Scan &bull; <strong>Controlled Production</strong>"
fi

ROW_TEMPLATE="$(cat "${TEMPLATE_ROW}" 2> /dev/null || true)"
TABLE_ROWS=""

for entry in "${PACKAGES_DATA[@]}"; do
  IFS=$'\t' read -r pkg_name pkg_arch installed_ver pkg_evr pkg_repo adv_badge_type adv_label <<< "${entry}"
  row_badge="$(get_status_badge "${adv_badge_type}" "" "${adv_label}" "table")"

  if [[ -n "${ROW_TEMPLATE}" ]]; then
    TABLE_ROWS+="$(render_snippet "${ROW_TEMPLATE}" \
      "PACKAGE_NAME" "${pkg_name}" \
      "ARCH" "${pkg_arch}" \
      "CURRENT_VERSION" "${installed_ver}" \
      "NEW_VERSION" "${pkg_evr}" \
      "REPO" "${pkg_repo}" \
      "ROW_STATUS_BADGE" "${row_badge}")"
  else
    TABLE_ROWS+="<tr><td>${pkg_name}</td><td>${pkg_arch}</td><td>${installed_ver}</td><td>${pkg_evr}</td><td>${pkg_repo}</td><td>${row_badge}</td></tr>"
  fi
done

if [[ "${TOTAL_COUNT}" -eq 0 ]]; then
  TABLE_ROWS="<tr><td colspan=\"6\" style=\"padding: 14px; text-align: center; color: #64748b; font-size: 13px;\">No package updates pending in configured repositories.</td></tr>"
fi

# Populate Update Instructions Block
if [[ "${TOTAL_COUNT}" -gt 0 ]]; then
  if [[ -f "${TEMPLATE_INSTR_PENDING}" ]]; then
    UPDATE_INSTRUCTIONS_BLOCK="$(render_template "${TEMPLATE_INSTR_PENDING}" "HOST_NAME" "${SYS_HOSTNAME}")"
  else
    UPDATE_INSTRUCTIONS_BLOCK="<p>Pending Updates: Run 'sudo /opt/scripts/dnf_check.sh update -y'</p>"
  fi
else
  if [[ -f "${TEMPLATE_INSTR_UPTODATE}" ]]; then
    UPDATE_INSTRUCTIONS_BLOCK="$(render_template "${TEMPLATE_INSTR_UPTODATE}")"
  else
    UPDATE_INSTRUCTIONS_BLOCK="<p>All packages up to date.</p>"
  fi
fi

PKG_MGR_INFO="$(get_pkg_mgr_info)"

# Render Content Body (Summary Grid + Table)
CONTENT_BODY="$(render_template "${TEMPLATE_SUMMARY_GRID}" \
  "HOST_NAME" "${SYS_HOSTNAME}" \
  "CHECK_TIME" "${JOB_CHECK_TIME}" \
  "PENDING_SUMMARY" "${PENDING_SUMMARY}" \
  "SECURITY_SUMMARY" "${SECURITY_SUMMARY}" \
  "PKG_MANAGER_INFO" "${PKG_MGR_INFO}" \
  "POLICY_MODE" "${POLICY_MODE}" \
  "PACKAGE_TABLE_ROWS" "${TABLE_ROWS}")"

# Format raw scan output for terminal card
if [[ -s "${RAW_SCAN_OUT_TMP}" ]]; then
  RAW_TERMINAL_TEXT="$(< "${RAW_SCAN_OUT_TMP}")"
  if [[ "${TOTAL_COUNT}" -eq 0 ]]; then
    RAW_TERMINAL_TEXT+=$'\n'$'\n'"Status: All installed packages are up to date with upstream repositories."$'\n'"0 updates pending."
  fi
else
  RAW_TERMINAL_TEXT="Repository metadata check complete.
Status: All installed packages are up to date with upstream repositories.
0 updates pending."
fi
log_msg "[*] Dispatching notification email to ${MAIL_TO}..."
dispatch_job_notification \
  --title "Package Update Advisor" \
  --category "Operating System Lifecycle" \
  --status "${status_type}" \
  --badge-icon "${badge_icon}" \
  --badge-label "${badge_label}" \
  --subject "${SUBJECT}" \
  --content "${CONTENT_BODY}" \
  --action "${UPDATE_INSTRUCTIONS_BLOCK}" \
  --terminal-title "DNF Check-Update Raw Output" \
  --terminal-content "${RAW_TERMINAL_TEXT}"

log_msg "[✓] Email notification successfully dispatched."

exit 0

