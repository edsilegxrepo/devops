#!/usr/bin/env bash
# ==============================================================================
# Script:      /opt/scripts/check-container-updates.sh
# Version:     1.4.0  2026/10/26
# Standard:    DRY Architecture Framework (lib/common.sh)
# Author:      DevOps Systems Administration <criticalsys.mis@gmail.com>
# Compatibility: Enterprise Linux 8, 9, 10 (RHEL, AlmaLinux, Rocky Linux)
# Description: Non-intrusively inspects container registries for updated images
#              (via 'podman auto-update --dry-run'), generates rich HTML advisory
#              reports, and optionally applies automated updates with rollback
#              readiness according to sysadmin policy.
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

TEMPLATES_DIR="${SCRIPT_DIR}/templates/container-update"
TEMPLATE_SUMMARY_GRID="${TEMPLATES_DIR}/summary-grid.html"
TEMPLATE_ROW="${TEMPLATES_DIR}/table-row.html"
TEMPLATE_CMD_ITEM="${TEMPLATES_DIR}/service-command-item.html"
TEMPLATE_INSTR_PENDING="${TEMPLATES_DIR}/instructions-pending.html"
TEMPLATE_INSTR_UPTODATE="${TEMPLATES_DIR}/instructions-uptodate.html"
TEMPLATE_INSTR_AUTO_SUCCESS="${TEMPLATES_DIR}/instructions-autoupdate-success.html"
TEMPLATE_INSTR_AUTO_FAILED="${TEMPLATES_DIR}/instructions-autoupdate-failed.html"

# Capture raw CLI arguments for execution logging
CLI_ARGS="$*"

# Operational Flags
CHECK_ONLY=0
FORCE_NOTIFY=0
CLI_NOTIFY_NEW_ONLY=""
CLI_AUTO_UPDATE=""

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

Container image update advisor and automation tool for systemd Quadlets.
Checks remote registries using 'podman auto-update --dry-run' and sends an email
advisory or automatically applies updates. Execution logs are maintained in
/var/log/jobs/container-updates-<DATESTAMP>.log (14-day retention).

Options:
  --auto-update             Automatically pull images and restart containers if updates are detected.
  --no-auto-update          Disable auto-updates, overriding AUTO_UPDATE in configuration.
  --notify-new-only         Only send email if new images are detected; remain silent otherwise.
  --notify-all              Send email notification even if all images are up to date.
  --check-only, --dry-run   Print scan results to stdout; do not send email or update.
  --force, --test, --always-notify
                            Force sending notification email regardless of update status.
  -h, --help                Show this help message.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto-update)
      CLI_AUTO_UPDATE="true"
      shift
      ;;
    --no-auto-update)
      CLI_AUTO_UPDATE="false"
      shift
      ;;
    --notify-new-only)
      CLI_NOTIFY_NEW_ONLY="true"
      shift
      ;;
    --notify-all)
      CLI_NOTIFY_NEW_ONLY="false"
      shift
      ;;
    --check-only | --dry-run)
      CHECK_ONLY=1
      shift
      ;;
    --force | --test | --always-notify)
      FORCE_NOTIFY=1
      shift
      ;;
    -h | --help)
      show_help
      exit 0
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
bootstrap_job "container-updates" \
  --require-root \
  --deps "podman jq sed find mktemp" \
  --log-dir "${LOG_BASE_DIR:-/var/log/jobs}" \
  --retention "${LOG_RETENTION_DAYS:-14}"

# CLI flag overrides configuration file settings
[[ -n "${CLI_AUTO_UPDATE}" ]] && AUTO_UPDATE="${CLI_AUTO_UPDATE}"
[[ -n "${CLI_NOTIFY_NEW_ONLY}" ]] && NOTIFY_NEW_ONLY="${CLI_NOTIFY_NEW_ONLY}"

# ------------------------------------------------------------------------------
# 4. Registry Inspection Execution
# ------------------------------------------------------------------------------
log_msg "[*] Starting Podman container update inspection on ${SYS_HOSTNAME}..."
[[ -n "${CLI_ARGS}" ]] && log_msg "[*] Invocation options: ${CLI_ARGS}"
log_msg "[*] Mode: Dry-Run Inspection via '${CONTAINER_ENGINE:-podman} auto-update --dry-run --format json'"

RAW_SCAN_ERR_TMP="$(mktemp /tmp/container-scan-err.XXXXXX)"
register_cleanup "rm -f '${RAW_SCAN_ERR_TMP}'"

if ! RAW_SCAN_OUTPUT=$(timeout "${SCAN_TIMEOUT:-900}" "${CONTAINER_ENGINE:-podman}" auto-update --dry-run --format json 2> "${RAW_SCAN_ERR_TMP}"); then
  log_msg "[-] Error: Container inspection command failed."
  if [[ -s "${RAW_SCAN_ERR_TMP}" ]]; then
    log_msg "--- Stderr Output ---"
    cat "${RAW_SCAN_ERR_TMP}" >> "${JOB_LOG_FILE}"
    [[ "${CHECK_ONLY}" -eq 1 ]] && cat "${RAW_SCAN_ERR_TMP}" >&2
  fi

  if [[ "${CHECK_ONLY}" -eq 0 ]]; then
    err_content="$(escape_html "$(< "${RAW_SCAN_ERR_TMP}")")"
    terminal_block="$(render_template "${SHARED_TEMPLATES_DIR}/terminal-card.html" \
      "TERMINAL_TITLE" "Scan Diagnostic Stderr" \
      "TERMINAL_SUBTITLE" "" \
      "TERMINAL_CONTENT" "${err_content}")"

    dispatch_job_notification \
      --title "Container Image Update Advisor" \
      --category "Container Lifecycle Monitor" \
      --status "failed" \
      --badge-icon "✕" \
      --badge-label "SCAN FAILED" \
      --subject "[ALERT] Container Update Scan Failed - ${SYS_HOSTNAME}" \
      --content "<p style=\"color: #991b1b; font-weight: 600;\">Container registry update check failed during inspection execution.</p>${terminal_block}" \
      --log-lines 0
  fi
  exit 1
fi

# Validate JSON schema
if ! echo "${RAW_SCAN_OUTPUT}" | jq empty > /dev/null 2>&1; then
  log_msg "[-] Error: Failed to parse podman auto-update output as JSON."
  log_msg "Raw Output: ${RAW_SCAN_OUTPUT}"
  exit 1
fi

TOTAL_COUNT=$(echo "${RAW_SCAN_OUTPUT}" | jq 'length')
PENDING_COUNT=$(echo "${RAW_SCAN_OUTPUT}" | jq '[.[] | select(.Updated == "pending")] | length')
FAILED_COUNT=$(echo "${RAW_SCAN_OUTPUT}" | jq '[.[] | select(.Updated == "failed")] | length')
UPTODATE_COUNT=$(echo "${RAW_SCAN_OUTPUT}" | jq '[.[] | select(.Updated == "false")] | length')

log_msg "[*] Scan complete: ${TOTAL_COUNT} services scanned | ${PENDING_COUNT} updates pending | ${UPTODATE_COUNT} up to date | ${FAILED_COUNT} failed"

# ------------------------------------------------------------------------------
# 5. Optional Auto-Update Execution
# ------------------------------------------------------------------------------
AUTO_UPDATE_EXECUTED=0
AUTO_UPDATE_SUCCESS=0
AUTO_UPDATE_OUTPUT=""

if [[ "${AUTO_UPDATE}" == "true" && "${CHECK_ONLY}" -eq 0 && "${PENDING_COUNT}" -gt 0 ]]; then
  log_msg "[!] Policy Mode: AUTO_UPDATE enabled. Applying updates to pending containers..."
  AUTO_UPDATE_EXECUTED=1

  AUTO_UPDATE_ERR_TMP="$(mktemp /tmp/container-autoupdate-err.XXXXXX)"
  register_cleanup "rm -f '${AUTO_UPDATE_ERR_TMP}'"

  if AUTO_UPDATE_OUTPUT=$(timeout "${SCAN_TIMEOUT:-900}" "${CONTAINER_ENGINE:-podman}" auto-update 2> "${AUTO_UPDATE_ERR_TMP}"); then
    AUTO_UPDATE_SUCCESS=1
    log_msg "[✓] Auto-update successfully completed."
    log_msg "${AUTO_UPDATE_OUTPUT}"
  else
    AUTO_UPDATE_SUCCESS=0
    log_msg "[-] Error: podman auto-update failed during execution."
    [[ -s "${AUTO_UPDATE_ERR_TMP}" ]] && cat "${AUTO_UPDATE_ERR_TMP}" >> "${JOB_LOG_FILE}"
    AUTO_UPDATE_OUTPUT+=$'\n'"$(< "${AUTO_UPDATE_ERR_TMP}")"
  fi
fi

# ------------------------------------------------------------------------------
# 6. Check-Only Output Handler
# ------------------------------------------------------------------------------
if [[ "${CHECK_ONLY}" -eq 1 ]]; then
  echo "================================================================================"
  printf "%-30s %-25s %-12s\n" "SYSTEMD SERVICE" "CONTAINER NAME" "STATUS"
  echo "================================================================================"

  while IFS=$'\t' read -r unit container_name image updated; do
    status_label="Up to Date"
    if [[ "${updated}" == "pending" ]]; then
      status_label="UPDATE PENDING"
    elif [[ "${updated}" == "failed" ]]; then
      status_label="SCAN FAILED"
    fi
    printf "%-30s %-25s %-12s\n" "${unit}" "${container_name}" "${status_label}"
  done < <(echo "${RAW_SCAN_OUTPUT}" | jq -r '.[] | [.Unit, .ContainerName, .Image, .Updated] | @tsv')

  echo "================================================================================"
  echo "Summary: ${TOTAL_COUNT} containers monitored, ${PENDING_COUNT} updates available, ${FAILED_COUNT} scan failures."

  if [[ "${PENDING_COUNT}" -gt 0 ]]; then
    echo -e "\nRecommended manual action:\n  sudo podman auto-update\n\nRollback if needed:\n  sudo podman auto-update --rollback"
  fi
  exit 0
fi

# ------------------------------------------------------------------------------
# 7. Notification Evaluation & Assembly
# ------------------------------------------------------------------------------
if [[ "${FORCE_NOTIFY}" -eq 0 && "${NOTIFY_NEW_ONLY}" == "true" && "${PENDING_COUNT}" -eq 0 && "${FAILED_COUNT}" -eq 0 && "${AUTO_UPDATE_EXECUTED}" -eq 0 ]]; then
  suppress_reason="NOTIFY_NEW_ONLY configured"
  [[ "${CLI_NOTIFY_NEW_ONLY}" == "true" ]] && suppress_reason="--notify-new-only active"
  log_msg "[*] Notification policy: All ${TOTAL_COUNT} containers up to date. Suppressing email notification (${suppress_reason})."
  exit 0
fi

log_msg "[*] Generating HTML email report..."

# Determine Status Badge & Subject
status_type="success"
badge_icon="✓"
badge_label="UP TO DATE"
if [[ "${AUTO_UPDATE_EXECUTED}" -eq 1 ]]; then
  if [[ "${AUTO_UPDATE_SUCCESS}" -eq 1 ]]; then
    status_type="success"
    badge_icon="✓"
    badge_label="UPDATED"
    SUBJECT="[INFO] Container Auto-Update Succeeded - ${SYS_HOSTNAME}"
    PENDING_SUMMARY="<span style=\"color: #059669; font-weight: 700;\">${PENDING_COUNT} container(s) updated successfully</span>"
    POLICY_MODE="Automatic Update & Restart &bull; <strong>Auto-Maintenance</strong>"
  else
    status_type="failed"
    badge_icon="✕"
    badge_label="UPDATE FAILED"
    SUBJECT="[ALERT] Container Auto-Update Failed - ${SYS_HOSTNAME}"
    PENDING_SUMMARY="<span style=\"color: #dc2626; font-weight: 700;\">Automatic update transaction failed</span>"
    POLICY_MODE="Automatic Update Attempt &bull; <strong>Intervention Required</strong>"
  fi
elif [[ "${FAILED_COUNT}" -gt 0 ]]; then
  status_type="failed"
  badge_icon="✕"
  badge_label="SCAN ISSUES"
  SUBJECT="[ALERT] Container Scan Issues Detected - ${SYS_HOSTNAME}"
  PENDING_SUMMARY="<span style=\"color: #dc2626; font-weight: 700;\">${FAILED_COUNT} registry query error(s)</span>"
  POLICY_MODE="Dry-Run Registry Scan &bull; <strong>Query Warnings</strong>"
elif [[ "${PENDING_COUNT}" -gt 0 ]]; then
  status_type="warning"
  badge_icon="⚡"
  badge_label="UPDATES PENDING"
  SUBJECT="[REVIEW] Container Image Updates Available - ${SYS_HOSTNAME} (${PENDING_COUNT} pending)"
  PENDING_SUMMARY="<span style=\"color: #b45309; font-weight: 700;\">${PENDING_COUNT} image update(s) pending review</span>"
  POLICY_MODE="Dry-Run Registry Scan &bull; <strong>Controlled Production</strong>"
else
  status_type="success"
  badge_icon="✓"
  badge_label="UP TO DATE"
  SUBJECT="[INFO] Container Images Up to Date - ${SYS_HOSTNAME}"
  PENDING_SUMMARY="<span style=\"color: #059669; font-weight: 700;\">0 (All containers running latest images)</span>"
  POLICY_MODE="Dry-Run Registry Scan &bull; <strong>Controlled Production</strong>"
fi

ROW_TEMPLATE="$(cat "${TEMPLATE_ROW}" 2> /dev/null || true)"
CMD_ITEM_TEMPLATE="$(cat "${TEMPLATE_CMD_ITEM}" 2> /dev/null || true)"

TABLE_ROWS=""
SPECIFIC_COMMANDS=""

while IFS=$'\t' read -r unit container_name image updated; do
  row_badge="$(get_status_badge "success" "" "UP TO DATE" "table")"
  if [[ "${AUTO_UPDATE_EXECUTED}" -eq 1 ]]; then
    if [[ "${updated}" == "pending" ]]; then
      if [[ "${AUTO_UPDATE_SUCCESS}" -eq 1 ]]; then
        row_badge="$(get_status_badge "success" "" "UPDATED" "table")"
      else
        row_badge="$(get_status_badge "failed" "" "UPDATE FAILED" "table")"
      fi
    fi
  elif [[ "${updated}" == "pending" ]]; then
    row_badge="$(get_status_badge "warning" "" "UPDATE PENDING" "table")"
    if [[ -n "${CMD_ITEM_TEMPLATE}" ]]; then
      SPECIFIC_COMMANDS+="$(render_snippet "${CMD_ITEM_TEMPLATE}" "UNIT" "${unit}" "CONTAINER_NAME" "${container_name}" "IMAGE" "${image}")"
    fi
  elif [[ "${updated}" == "failed" ]]; then
    row_badge="$(get_status_badge "failed" "" "SCAN FAILED" "table")"
  fi

  if [[ -n "${ROW_TEMPLATE}" ]]; then
    TABLE_ROWS+="$(render_snippet "${ROW_TEMPLATE}" "UNIT" "${unit}" "CONTAINER_NAME" "${container_name}" "IMAGE" "${image}" "ROW_STATUS_BADGE" "${row_badge}")"
  else
    TABLE_ROWS+="<tr><td>${unit}</td><td>${container_name}</td><td>${image}</td><td>${row_badge}</td></tr>"
  fi
done < <(echo "${RAW_SCAN_OUTPUT}" | jq -r '.[] | [.Unit, .ContainerName, .Image, .Updated] | @tsv')

# Populate Update Instructions Block
if [[ "${PENDING_COUNT}" -gt 0 ]]; then
  if [[ "${AUTO_UPDATE_EXECUTED}" -eq 1 ]]; then
    escaped_auto_output="$(escape_html "${AUTO_UPDATE_OUTPUT}")"
    if [[ "${AUTO_UPDATE_SUCCESS}" -eq 1 && -f "${TEMPLATE_INSTR_AUTO_SUCCESS}" ]]; then
      UPDATE_INSTRUCTIONS_BLOCK="$(cat "${TEMPLATE_INSTR_AUTO_SUCCESS}")"
    elif [[ "${AUTO_UPDATE_SUCCESS}" -eq 0 && -f "${TEMPLATE_INSTR_AUTO_FAILED}" ]]; then
      UPDATE_INSTRUCTIONS_BLOCK="$(cat "${TEMPLATE_INSTR_AUTO_FAILED}")"
    else
      UPDATE_INSTRUCTIONS_BLOCK="<pre>${escaped_auto_output}</pre>"
    fi
    UPDATE_INSTRUCTIONS_BLOCK="${UPDATE_INSTRUCTIONS_BLOCK//\{\{HOST_NAME\}\}/${SYS_HOSTNAME}}"
    UPDATE_INSTRUCTIONS_BLOCK="${UPDATE_INSTRUCTIONS_BLOCK//\{\{AUTO_UPDATE_OUTPUT\}\}/${escaped_auto_output}}"
  else
    if [[ -f "${TEMPLATE_INSTR_PENDING}" ]]; then
      UPDATE_INSTRUCTIONS_BLOCK="$(cat "${TEMPLATE_INSTR_PENDING}")"
      UPDATE_INSTRUCTIONS_BLOCK="${UPDATE_INSTRUCTIONS_BLOCK//\{\{HOST_NAME\}\}/${SYS_HOSTNAME}}"
      UPDATE_INSTRUCTIONS_BLOCK="${UPDATE_INSTRUCTIONS_BLOCK//\{\{SPECIFIC_COMMANDS\}\}/${SPECIFIC_COMMANDS}}"
    else
      UPDATE_INSTRUCTIONS_BLOCK="<p>Pending Updates: Run 'sudo podman auto-update'</p>"
    fi
  fi
else
  if [[ -f "${TEMPLATE_INSTR_UPTODATE}" ]]; then
    UPDATE_INSTRUCTIONS_BLOCK="$(cat "${TEMPLATE_INSTR_UPTODATE}")"
  else
    UPDATE_INSTRUCTIONS_BLOCK="<p>All containers up to date.</p>"
  fi
fi

# Render Content Body (Summary Grid + Table)
CONTENT_BODY="$(render_template "${TEMPLATE_SUMMARY_GRID}" \
  "HOST_NAME" "${SYS_HOSTNAME}" \
  "CHECK_TIME" "${JOB_CHECK_TIME}" \
  "TOTAL_COUNT" "${TOTAL_COUNT}" \
  "PENDING_SUMMARY" "${PENDING_SUMMARY}" \
  "POLICY_MODE" "${POLICY_MODE}" \
  "CONTAINER_TABLE_ROWS" "${TABLE_ROWS}")"

ESCAPED_RAW_OUTPUT="$(escape_html "${RAW_SCAN_OUTPUT}")"
TERMINAL_BLOCK="$(render_template "${SHARED_TEMPLATES_DIR}/terminal-card.html" \
  "TERMINAL_TITLE" "Registry Scan Raw Output" \
  "TERMINAL_SUBTITLE" "" \
  "TERMINAL_CONTENT" "${ESCAPED_RAW_OUTPUT}")"

log_msg "[*] Dispatching notification email to ${MAIL_TO}..."
dispatch_job_notification \
  --title "Container Image Update Advisor" \
  --category "Container Lifecycle Monitor" \
  --status "${status_type}" \
  --badge-icon "${badge_icon}" \
  --badge-label "${badge_label}" \
  --subject "${SUBJECT}" \
  --content "${CONTENT_BODY}${TERMINAL_BLOCK}" \
  --action "${UPDATE_INSTRUCTIONS_BLOCK}" \
  --log-lines 0

log_msg "[✓] Email notification successfully dispatched."

exit 0
