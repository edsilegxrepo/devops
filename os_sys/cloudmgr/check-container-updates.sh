#!/usr/bin/env bash
# ==============================================================================
# Script: check-container-updates.sh
# Purpose: Non-intrusively inspect container registries for newer images
#          (dry-run) and notify sysadmins via email for controlled review.
# Standard: DRY Architecture Framework (lib/common.sh)
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
TEMPLATE_BADGE_PENDING="${TEMPLATES_DIR}/row-badge-pending.html"
TEMPLATE_BADGE_UPTODATE="${TEMPLATES_DIR}/row-badge-uptodate.html"
TEMPLATE_BADGE_UPDATED="${TEMPLATES_DIR}/row-badge-updated.html"
TEMPLATE_BADGE_FAILED="${TEMPLATES_DIR}/row-badge-failed.html"
TEMPLATE_CMD_ITEM="${TEMPLATES_DIR}/service-command-item.html"
TEMPLATE_INSTR_PENDING="${TEMPLATES_DIR}/instructions-pending.html"
TEMPLATE_INSTR_UPTODATE="${TEMPLATES_DIR}/instructions-uptodate.html"
TEMPLATE_INSTR_AUTO_SUCCESS="${TEMPLATES_DIR}/instructions-autoupdate-success.html"
TEMPLATE_INSTR_AUTO_FAILED="${TEMPLATES_DIR}/instructions-autoupdate-failed.html"
TEMPLATE_SUMMARY_PENDING="${TEMPLATES_DIR}/summary-pending.html"
TEMPLATE_SUMMARY_UPTODATE="${TEMPLATES_DIR}/summary-uptodate.html"
TEMPLATE_SUMMARY_AUTO_SUCCESS="${TEMPLATES_DIR}/summary-autoupdate-success.html"
TEMPLATE_SUMMARY_AUTO_FAILED="${TEMPLATES_DIR}/summary-autoupdate-failed.html"

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
# 3. Privilege Guard & Dependencies
# ------------------------------------------------------------------------------
require_root

verify_dependencies "podman" "jq" "sed" "find" "mktemp"

# ------------------------------------------------------------------------------
# 4. Configuration & Concurrency Locking
# ------------------------------------------------------------------------------
load_config "container-updates"

# CLI flag overrides configuration file settings
[[ -n "${CLI_AUTO_UPDATE}" ]] && AUTO_UPDATE="${CLI_AUTO_UPDATE}"
[[ -n "${CLI_NOTIFY_NEW_ONLY}" ]] && NOTIFY_NEW_ONLY="${CLI_NOTIFY_NEW_ONLY}"

acquire_lock "check-container-updates"

init_job_log "container-updates" "${LOG_BASE_DIR:-/var/log/jobs}" "${LOG_RETENTION_DAYS:-14}"

# ------------------------------------------------------------------------------
# 5. Registry Inspection Execution
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
    STATUS_BADGE="$(get_status_badge "failed" "✕" "SCAN FAILED")"
    SUBJECT="[ALERT] Container Update Scan Failed - ${SYS_HOSTNAME}"
    ERR_CONTENT="$(escape_html "$(< "${RAW_SCAN_ERR_TMP}")")"
    TERMINAL_BLOCK="$(render_template "${SHARED_TEMPLATES_DIR}/terminal-card.html" \
      "TERMINAL_TITLE" "Scan Diagnostic Stderr" \
      "TERMINAL_SUBTITLE" "" \
      "TERMINAL_CONTENT" "${ERR_CONTENT}")"
    EMAIL_BODY="$(render_template "${SHARED_TEMPLATES_DIR}/base-layout.html" \
      "SUBJECT" "${SUBJECT}" \
      "SERVICE_CATEGORY" "Container Lifecycle Monitor" \
      "JOB_TITLE" "Container Image Update Advisor" \
      "STATUS_BADGE" "${STATUS_BADGE}" \
      "CONTENT_BODY" "<p style=\"color: #991b1b; font-weight: 600;\">Container registry update check failed during inspection execution.</p>" \
      "ACTION_BLOCK" "" \
      "TERMINAL_BLOCK" "${TERMINAL_BLOCK}" \
      "HOST_NAME" "${SYS_HOSTNAME}" \
      "EXECUTION_TIME" "${JOB_CHECK_TIME}" \
      "LOG_FILE_PATH" "${JOB_LOG_FILE}")"

    send_html_email "${MAIL_TO}" "${MAIL_FROM}" "${SUBJECT}" "${EMAIL_BODY}"
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
# 6. Optional Auto-Update Execution
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
# 7. Check-Only Output Handler
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
# 8. Notification Evaluation & Assembly
# ------------------------------------------------------------------------------
if [[ "${FORCE_NOTIFY}" -eq 0 && "${NOTIFY_NEW_ONLY}" == "true" && "${PENDING_COUNT}" -eq 0 && "${FAILED_COUNT}" -eq 0 && "${AUTO_UPDATE_EXECUTED}" -eq 0 ]]; then
  suppress_reason="NOTIFY_NEW_ONLY configured"
  [[ "${CLI_NOTIFY_NEW_ONLY}" == "true" ]] && suppress_reason="--notify-new-only active"
  log_msg "[*] Notification policy: All ${TOTAL_COUNT} containers up to date. Suppressing email notification (${suppress_reason})."
  exit 0
fi

log_msg "[*] Generating HTML email report..."

# Determine Status Badge & Subject
if [[ "${AUTO_UPDATE_EXECUTED}" -eq 1 ]]; then
  if [[ "${AUTO_UPDATE_SUCCESS}" -eq 1 ]]; then
    STATUS_BADGE="$(get_status_badge "success" "✓" "UPDATED")"
    SUBJECT="[INFO] Container Auto-Update Succeeded - ${SYS_HOSTNAME}"
    PENDING_SUMMARY="$(cat "${TEMPLATE_SUMMARY_AUTO_SUCCESS}" 2> /dev/null || echo "${PENDING_COUNT} updated")"
    POLICY_MODE="Automatic Update & Restart &bull; <strong>Auto-Maintenance</strong>"
  else
    STATUS_BADGE="$(get_status_badge "failed" "✕" "UPDATE FAILED")"
    SUBJECT="[ALERT] Container Auto-Update Failed - ${SYS_HOSTNAME}"
    PENDING_SUMMARY="$(cat "${TEMPLATE_SUMMARY_AUTO_FAILED}" 2> /dev/null || echo "Update failed")"
    POLICY_MODE="Automatic Update Attempt &bull; <strong>Intervention Required</strong>"
  fi
elif [[ "${FAILED_COUNT}" -gt 0 ]]; then
  STATUS_BADGE="$(get_status_badge "failed" "✕" "SCAN ISSUES")"
  SUBJECT="[ALERT] Container Scan Issues Detected - ${SYS_HOSTNAME}"
  PENDING_SUMMARY="${FAILED_COUNT} registry query error(s)"
  POLICY_MODE="Dry-Run Registry Scan &bull; <strong>Query Warnings</strong>"
elif [[ "${PENDING_COUNT}" -gt 0 ]]; then
  STATUS_BADGE="$(get_status_badge "warning" "⚡" "UPDATES PENDING")"
  SUBJECT="[REVIEW] Container Image Updates Available - ${SYS_HOSTNAME} (${PENDING_COUNT} pending)"
  PENDING_SUMMARY="$(cat "${TEMPLATE_SUMMARY_PENDING}" 2> /dev/null || echo "${PENDING_COUNT} update(s) available")"
  PENDING_SUMMARY="${PENDING_SUMMARY//\{\{PENDING_COUNT\}\}/${PENDING_COUNT}}"
  POLICY_MODE="Dry-Run Registry Scan &bull; <strong>Controlled Production</strong>"
else
  STATUS_BADGE="$(get_status_badge "success" "✓" "UP TO DATE")"
  SUBJECT="[INFO] Container Images Up to Date - ${SYS_HOSTNAME}"
  PENDING_SUMMARY="$(cat "${TEMPLATE_SUMMARY_UPTODATE}" 2> /dev/null || echo "All images up to date")"
  POLICY_MODE="Dry-Run Registry Scan &bull; <strong>Controlled Production</strong>"
fi

# Load row template badges
BADGE_PENDING_HTML="$(cat "${TEMPLATE_BADGE_PENDING}" 2> /dev/null || echo "[Pending]")"
BADGE_UPTODATE_HTML="$(cat "${TEMPLATE_BADGE_UPTODATE}" 2> /dev/null || echo "[Up to Date]")"
BADGE_UPDATED_HTML="$(cat "${TEMPLATE_BADGE_UPDATED}" 2> /dev/null || echo "[Updated]")"
BADGE_FAILED_HTML="$(cat "${TEMPLATE_BADGE_FAILED}" 2> /dev/null || echo "[Failed]")"
ROW_TEMPLATE="$(cat "${TEMPLATE_ROW}" 2> /dev/null || true)"
CMD_ITEM_TEMPLATE="$(cat "${TEMPLATE_CMD_ITEM}" 2> /dev/null || true)"

TABLE_ROWS=""
SPECIFIC_COMMANDS=""

while IFS=$'\t' read -r unit container_name image updated; do
  row_badge="${BADGE_UPTODATE_HTML}"
  if [[ "${AUTO_UPDATE_EXECUTED}" -eq 1 ]]; then
    if [[ "${updated}" == "pending" ]]; then
      [[ "${AUTO_UPDATE_SUCCESS}" -eq 1 ]] && row_badge="${BADGE_UPDATED_HTML}" || row_badge="${BADGE_FAILED_HTML}"
    fi
  elif [[ "${updated}" == "pending" ]]; then
    row_badge="${BADGE_PENDING_HTML}"
    if [[ -n "${CMD_ITEM_TEMPLATE}" ]]; then
      cmd_item="${CMD_ITEM_TEMPLATE}"
      cmd_item="${cmd_item//\{\{UNIT\}\}/${unit}}"
      cmd_item="${cmd_item//\{\{CONTAINER_NAME\}\}/${container_name}}"
      cmd_item="${cmd_item//\{\{IMAGE\}\}/${image}}"
      SPECIFIC_COMMANDS+="${cmd_item}"
    fi
  elif [[ "${updated}" == "failed" ]]; then
    row_badge="${BADGE_FAILED_HTML}"
  fi

  if [[ -n "${ROW_TEMPLATE}" ]]; then
    row="${ROW_TEMPLATE}"
    row="${row//\{\{UNIT\}\}/${unit}}"
    row="${row//\{\{CONTAINER_NAME\}\}/${container_name}}"
    row="${row//\{\{IMAGE\}\}/${image}}"
    row="${row//\{\{ROW_STATUS_BADGE\}\}/${row_badge}}"
    TABLE_ROWS+="${row}"
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

ACTION_BLOCK="<tr><td style=\"padding: 12px 28px 16px 28px;\">${UPDATE_INSTRUCTIONS_BLOCK}</td></tr>"

ESCAPED_RAW_OUTPUT="$(escape_html "${RAW_SCAN_OUTPUT}")"
TERMINAL_BLOCK="$(render_template "${SHARED_TEMPLATES_DIR}/terminal-card.html" \
  "TERMINAL_TITLE" "Registry Scan Raw Output" \
  "TERMINAL_SUBTITLE" "" \
  "TERMINAL_CONTENT" "${ESCAPED_RAW_OUTPUT}")"

EMAIL_BODY="$(render_template "${SHARED_TEMPLATES_DIR}/base-layout.html" \
  "SUBJECT" "${SUBJECT}" \
  "SERVICE_CATEGORY" "Container Lifecycle Monitor" \
  "JOB_TITLE" "Container Image Update Advisor" \
  "STATUS_BADGE" "${STATUS_BADGE}" \
  "CONTENT_BODY" "${CONTENT_BODY}" \
  "ACTION_BLOCK" "${ACTION_BLOCK}" \
  "TERMINAL_BLOCK" "${TERMINAL_BLOCK}" \
  "HOST_NAME" "${SYS_HOSTNAME}" \
  "EXECUTION_TIME" "${JOB_CHECK_TIME}" \
  "LOG_FILE_PATH" "${JOB_LOG_FILE}")"

# ------------------------------------------------------------------------------
# 9. Send Notification Email
# ------------------------------------------------------------------------------
log_msg "[*] Dispatching notification email to ${MAIL_TO}..."
send_html_email "${MAIL_TO}" "${MAIL_FROM}" "${SUBJECT}" "${EMAIL_BODY}"
log_msg "[✓] Email notification successfully dispatched."

exit 0
