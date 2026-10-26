#!/usr/bin/env bash
# ==============================================================================
# Script:      /opt/scripts/vm-backup-gdrive.sh
# Version:     1.4.0  2026/10/26
# Standard:    DRY Architecture Framework (lib/common.sh)
# Author:      DevOps Systems Administration <criticalsys.mis@gmail.com>
# Compatibility: Enterprise Linux 8, 9, 10 (RHEL, AlmaLinux, Rocky Linux)
# Description: Comprehensive VM Snapshot & Google Drive Backup tool. Creates hot
#              SQLite backups, captures bare-metal DR manifests, compresses and
#              encrypts with AES-256 GPG, synchronizes to cloud storage via Rclone,
#              enforces retention policies, and dispatches HTML email reports.
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

TEMPLATES_DIR="${SCRIPT_DIR}/templates/backup"

# Capture raw CLI arguments for execution logging
CLI_ARGS="$*"

# Operational Flags
NOTIFY_ONLY_FAILURES=0

# ------------------------------------------------------------------------------
# 2. Argument Parsing
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Function: show_help
# Purpose:  Displays command syntax, options, and operational summary to stdout.
# Arguments:
#   None.
# Returns:
#   Outputs help documentation.
# ------------------------------------------------------------------------------
show_help() {
  cat << EOF
Usage: $(basename "$0") [OPTIONS]

Comprehensive VM Snapshot & Cloud Backup tool for ${SYS_HOSTNAME}.
Creates hot SQLite backups, captures DR manifests, encrypts with AES-256 GPG,
syncs to cloud storage, enforces dual retention, and dispatches HTML email notifications.

Options:
  --notify-only-failures    Only send email notification if backup fails; remain silent on success.
  -h, --help                Show this help message.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --notify-only-failures | --failures-only | --notify-failures-only)
      NOTIFY_ONLY_FAILURES=1
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
bootstrap_job "vm-backup" \
  --require-root \
  --deps "tar zstd gpg rclone find awk sed stat date mktemp" \
  --log-dir "${LOG_BASE_DIR:-/var/log/backups}" \
  --retention "${LOG_RETENTION_DAYS:-14}"

# Execution state
BACKUP_SUCCESSFUL=0
# shellcheck disable=SC2034 # Evaluated dynamically in cleanup trap
LOCAL_BACKUP_CREATED=0
ARCHIVE_SIZE="Not created"
START_TS="${JOB_START_TS:-$(date +%s)}"
START_TIME_STR="${JOB_CHECK_TIME:-$(date -u '+%Y-%m-%d %H:%M:%S UTC')}"
DATE_STAMP="${JOB_DATE_STAMP:-$(date +%Y%m%d_%H%M%S)}"
ARCHIVE_NAME="${ARCHIVE_PREFIX:-${SHORT_HOSTNAME}-backup}-${DATE_STAMP}.${COMPRESSION_EXT:-tar.zst.gpg}"
ARCHIVE_PATH="${BACKUP_DIR}/${ARCHIVE_NAME}"

# Temporary staging directory and cleanup hooks
STAGING_DIR="$(mktemp -d /tmp/vm-backup-stage.XXXXXX)"
register_cleanup "rm -rf '${STAGING_DIR}'"
register_cleanup "[[ \${LOCAL_BACKUP_CREATED:-0} -eq 0 ]] && rm -f '${ARCHIVE_PATH}' '${ARCHIVE_PATH}.sha256'"

# ------------------------------------------------------------------------------
# 4. Backup Notification Dispatcher
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Function: send_backup_notification
# Purpose:  Compiles backup summary grid (archive size, durations, retention),
#           attaches truncated execution log, and dispatches HTML notification
#           email unless suppressed by failure-only policy.
# Arguments:
#   $1 (Optional) - Backup exit code (0 for success, non-zero for failure; default: 1).
# Returns:
#   0.
# ------------------------------------------------------------------------------
send_backup_notification() {
  local exit_code="${1:-1}"

  if [[ "${exit_code}" -eq 0 && "${NOTIFY_ONLY_FAILURES}" -eq 1 ]]; then
    log_msg "[+] Backup succeeded. Email notification suppressed (--notify-only-failures is active)."
    return 0
  fi

  local end_ts
  end_ts="$(date +%s)"
  local duration_sec=$((end_ts - START_TS))
  local duration_formatted
  duration_formatted=$(printf "%dm %02ds" $((duration_sec / 60)) $((duration_sec % 60)))
  local end_time_str
  end_time_str="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

  local status_type="success"
  local badge_icon="✓"
  local badge_label="BACKUP SUCCESS"
  local status_header="SUCCESS"
  local alert_banner=""
  if [[ "${exit_code}" -ne 0 ]]; then
    status_type="failed"
    badge_icon="✕"
    badge_label="BACKUP FAILED"
    status_header="FAILED"
    alert_banner="<div style=\"margin: 0 0 16px 0; padding: 12px 16px; background-color: #fef2f2; border: 1px solid #fecaca; border-radius: 6px;\"><strong style=\"color: #991b1b; font-size: 13px;\">Critical Backup Alert:</strong> <span style=\"color: #b91c1c; font-size: 13px;\">One or more pipeline stages failed. The exact root cause and diagnostic traces have been documented in the Execution Log below.</span></div>"
  fi

  local retention_days="Local: ${LOCAL_RETENTION_DAYS}d &bull; Remote: ${REMOTE_RETENTION_DAYS}d &bull; Logs: ${LOG_RETENTION_DAYS}d"

  # Render Summary Grid
  local summary_grid
  summary_grid="$(render_template "${TEMPLATES_DIR}/summary-grid.html" \
    "HOST_NAME" "${SYS_HOSTNAME}" \
    "ARCHIVE_NAME" "${ARCHIVE_NAME}" \
    "ARCHIVE_SIZE" "${ARCHIVE_SIZE}" \
    "TARGET_REMOTE" "${TARGET_REMOTE}" \
    "START_TIME" "${START_TIME_STR}" \
    "END_TIME" "${end_time_str}" \
    "DURATION" "${duration_formatted} (${duration_sec}s)" \
    "RETENTION_DAYS" "${retention_days}")"

  local content_body="${alert_banner}<h2 style=\"font-size: 13px; text-transform: uppercase; letter-spacing: 0.06em; color: #64748b; margin: 0 0 14px 0; font-weight: 700;\">Backup Summary</h2>${summary_grid}"

  dispatch_job_notification \
    --title "VM Snapshot & Cloud Backup" \
    --category "Disaster Recovery & Snapshots" \
    --status "${status_type}" \
    --badge-icon "${badge_icon}" \
    --badge-label "${badge_label}" \
    --content "${content_body}" \
    --log-file "${JOB_LOG_FILE}" \
    --log-lines 350 \
    --terminal-title "Backup Execution Log" \
    --extra-header "X-Backup-Status: ${status_header}"

  log_msg "[✓] Email notification dispatched to ${MAIL_TO}."
}

# ------------------------------------------------------------------------------
# 5. Core Backup Execution Pipeline
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Function: execute_backup_routine
# Purpose:  Orchestrates full backup lifecycle: pre-backup hook execution, hot
#           SQLite staging, disaster recovery manifest generation, encrypted
#           archive creation, integrity checksumming, remote cloud synchronization,
#           post-backup hooks, and dual retention pruning.
# Arguments:
#   None.
# Returns:
#   0 on full success; 1 if any critical pipeline stage fails.
# ------------------------------------------------------------------------------
execute_backup_routine() {
  log_msg "[*] Starting VM snapshot & cloud backup routine on ${SYS_HOSTNAME}..."
  [[ -n "${CLI_ARGS}" ]] && log_msg "[*] Invocation options: ${CLI_ARGS}"
  log_msg "[*] Backup destination: ${ARCHIVE_PATH}"
  mkdir -p "${BACKUP_DIR}"

  # 1. Execute Pre-Backup Hook if configured
  if [[ -n "${PRE_BACKUP_HOOK:-}" && -x "${PRE_BACKUP_HOOK}" ]]; then
    log_msg "[*] Executing Pre-Backup Hook: ${PRE_BACKUP_HOOK}..."
    if ! "${PRE_BACKUP_HOOK}" "${STAGING_DIR}"; then
      log_msg "[-] Error: Pre-Backup Hook failed. Aborting backup."
      return 1
    fi
  fi

  # 2. Container Volume & SQLite Staging
  local dbs=()
  read -ra dbs <<< "${SQLITE_DATABASES:-}"
  if [[ ${#dbs[@]} -gt 0 ]]; then
    log_msg "[+] Performing safe staging of container volumes and databases..."
    for db_path in "${dbs[@]}"; do
      if [[ -f "${db_path}" ]]; then
        local db_rel="${db_path#/}"
        local stage_target="${STAGING_DIR}/${db_rel}"

        # Ensure parent container directory is staged if under /var/lib/
        if [[ "${db_path}" =~ ^/var/lib/([^/]+)/ ]]; then
          local container_root="/var/lib/${BASH_REMATCH[1]}"
          local c_rel="${container_root#/}"
          if [[ -d "${container_root}" && ! -d "${STAGING_DIR}/${c_rel}" ]]; then
            mkdir -p "$(dirname "${STAGING_DIR}/${c_rel}")"
            cp -a "${container_root}" "${STAGING_DIR}/${c_rel}"
          fi
        fi

        sqlite_hot_backup "${db_path}" "${stage_target}"
        log_msg "    [✓] Database snapshot staged: ${db_path}"
      else
        log_msg "    [-] Notice: Configured SQLite DB not found: ${db_path}"
      fi
    done
  fi

  # 3. Generate Disaster Recovery Manifest
  generate_dr_manifest "${STAGING_DIR}/var/recovery-manifest"

  # 4. Assemble Archive Tar Exclusions and Source Directories
  local tar_excludes=()
  local raw_excludes=()
  read -ra raw_excludes <<< "${BACKUP_EXCLUDES:-}"
  for pat in "${raw_excludes[@]}"; do
    tar_excludes+=(--exclude="${pat}")
  done

  local root_dirs=()
  local raw_root_dirs=()
  read -ra raw_root_dirs <<< "${BACKUP_ROOT_DIRS:-home root etc opt var/www var/lib/caddy}"
  for r in "${raw_root_dirs[@]}"; do
    [[ -e "/${r}" ]] && root_dirs+=("${r}")
  done

  # Collect staged items from STAGING_DIR dynamically
  local staged_items=()
  if [[ -d "${STAGING_DIR}/var" ]]; then
    for vitem in "${STAGING_DIR}/var"/*; do
      [[ -e "${vitem}" ]] || continue
      local vname
      vname="$(basename "${vitem}")"
      if [[ "${vname}" == "lib" && -d "${vitem}" ]]; then
        for cdir in "${vitem}"/*; do
          [[ -d "${cdir}" ]] && staged_items+=("var/lib/$(basename "${cdir}")")
        done
      else
        staged_items+=("var/${vname}")
      fi
    done
  fi
  for extra in "${STAGING_DIR}"/*; do
    [[ -e "${extra}" ]] || continue
    local extra_rel="${extra#"${STAGING_DIR}/"}"
    if [[ "${extra_rel}" != "var" && " ${staged_items[*]:-} " != *" ${extra_rel} "* ]]; then
      staged_items+=("${extra_rel}")
    fi
  done

  log_msg "[+] Creating and encrypting archive: ${ARCHIVE_NAME}..."

  local file_list_tmp="${STAGING_DIR}/backed-up-files.txt"
  local tar_err_tmp="${STAGING_DIR}/tar-stderr.log"
  local gpg_err_tmp="${STAGING_DIR}/gpg-stderr.log"

  tar --warning=no-file-changed --ignore-failed-read --totals \
    -v --index-file="${file_list_tmp}" \
    --use-compress-program="${COMPRESSION_PROGRAM:-zstd -T0 -3}" -c \
    "${tar_excludes[@]}" \
    -C / "${root_dirs[@]}" \
    -C "${STAGING_DIR}" "${staged_items[@]}" \
    2> "${tar_err_tmp}" |
    gpg --batch --yes --symmetric \
      --cipher-algo AES256 \
      --passphrase-file "${PASSPHRASE_FILE}" \
      --output "${ARCHIVE_PATH}" \
      2> "${gpg_err_tmp}"

  local pipe_statuses=("${PIPESTATUS[@]}")
  local tar_rc="${pipe_statuses[0]:-0}"
  local gpg_rc="${pipe_statuses[1]:-0}"

  # Forward genuine tar warnings or errors to log
  if [[ -f "${tar_err_tmp}" ]]; then
    grep -v '^Total bytes written:' "${tar_err_tmp}" >> "${JOB_LOG_FILE}" || true
  fi

  # Forward genuine gpg warnings or errors to log
  if [[ -f "${gpg_err_tmp}" && -s "${gpg_err_tmp}" ]]; then
    cat "${gpg_err_tmp}" >&2
    if [[ -n "${JOB_LOG_FILE:-}" && -f "${JOB_LOG_FILE}" ]]; then
      sed 's/^/    [gpg] /' "${gpg_err_tmp}" >> "${JOB_LOG_FILE}"
    fi
  fi

  if [[ ${tar_rc} -ne 0 || ${gpg_rc} -ne 0 ]]; then
    log_msg "[-] Error: Archive creation pipeline failed (tar exit: ${tar_rc}, gpg exit: ${gpg_rc})."
    return 1
  fi

  local uncompressed_bytes
  uncompressed_bytes=$(awk '/Total bytes written:/ {print $4}' "${tar_err_tmp}" 2> /dev/null || true)
  local uncompressed_stat=""
  if [[ -n "${uncompressed_bytes}" && "${uncompressed_bytes}" =~ ^[0-9]+$ ]]; then
    local uncompressed_mb
    uncompressed_mb=$(awk -v b="${uncompressed_bytes}" 'BEGIN {printf "%.1fM", b/1024/1024}')
    uncompressed_stat="${uncompressed_mb} uncompressed"
  fi

  local file_count=0
  local dir_count=0
  local total_count=0
  if [[ -f "${file_list_tmp}" ]]; then
    total_count=$(wc -l < "${file_list_tmp}")
    dir_count=$(grep -c '/$' "${file_list_tmp}" 2> /dev/null || true)
    file_count=$((total_count - dir_count))
    {
      echo "=== Backed Up Files Manifest (${total_count} items: ${file_count} files, ${dir_count} directories) ==="
      cat "${file_list_tmp}"
      echo "=== End of Backed Up Files Manifest ==="
    } >> "${JOB_LOG_FILE}"
  fi

  chmod 600 "${ARCHIVE_PATH}"

  # Generate SHA-256 checksum for pre-flight integrity verification
  local checksum_file="${ARCHIVE_PATH}.sha256"
  (cd "$(dirname "${ARCHIVE_PATH}")" && sha256sum "$(basename "${ARCHIVE_PATH}")" > "${checksum_file}")
  chmod 600 "${checksum_file}"
  local sha256_hash
  sha256_hash="$(awk '{print $1}' "${checksum_file}")"
  log_msg "[+] SHA-256 checksum generated: ${sha256_hash}"

  # Verify archive was generated and meets minimum sanity threshold
  if [[ ! -s "${ARCHIVE_PATH}" ]]; then
    log_msg "[-] Error: Archive ${ARCHIVE_PATH} was not created or is empty!"
    return 1
  fi

  local archive_bytes
  archive_bytes=$(stat -c%s "${ARCHIVE_PATH}")
  if ((archive_bytes < MIN_ARCHIVE_BYTES)); then
    log_msg "[-] Error: Archive size (${archive_bytes} bytes) is suspiciously smaller than threshold (${MIN_ARCHIVE_BYTES} bytes)!"
    return 1
  fi

  local raw_archive_size
  raw_archive_size="$(du -h "${ARCHIVE_PATH}" | awk '{print $1}')"

  local file_fmt
  local dir_fmt
  file_fmt=$(LC_NUMERIC=en_US.UTF-8 printf "%'d" "${file_count}" 2> /dev/null || echo "${file_count}")
  dir_fmt=$(LC_NUMERIC=en_US.UTF-8 printf "%'d" "${dir_count}" 2> /dev/null || echo "${dir_count}")

  local stat_parts=()
  [[ -n "${uncompressed_stat}" ]] && stat_parts+=("${uncompressed_stat}")
  if ((file_count > 0 || dir_count > 0)); then
    stat_parts+=("${file_fmt} files, ${dir_fmt} directories")
  fi

  if [[ ${#stat_parts[@]} -gt 0 ]]; then
    local stat_joined=""
    for part in "${stat_parts[@]}"; do
      [[ -n "${stat_joined}" ]] && stat_joined+=", "
      stat_joined+="${part}"
    done
    ARCHIVE_SIZE="${raw_archive_size} (${stat_joined})"
  else
    ARCHIVE_SIZE="${raw_archive_size}"
  fi

  log_msg "[✓] Archive validated: ${ARCHIVE_SIZE}"
  # shellcheck disable=SC2034 # Evaluated dynamically in cleanup trap
  LOCAL_BACKUP_CREATED=1

  # 5. Remote Sync
  if ! sync_to_remote "${ARCHIVE_PATH}" "${TARGET_REMOTE}" "${TARGET_REMOTE_TYPE:-rclone}"; then
    log_msg "[-] Error: Primary remote synchronization failed for ${TARGET_REMOTE}!"
    return 1
  fi

  # Optional Secondary Remote Sync (3-2-1 Backup Rule)
  if [[ -n "${TARGET_SECONDARY_REMOTE:-}" ]]; then
    if ! sync_to_remote "${ARCHIVE_PATH}" "${TARGET_SECONDARY_REMOTE}" "${TARGET_SECONDARY_TYPE:-rclone}"; then
      log_msg "[-] Error: Secondary remote synchronization failed for ${TARGET_SECONDARY_REMOTE}!"
      return 1
    fi
  fi

  # 6. Post-Backup Hook
  if [[ -n "${POST_BACKUP_HOOK:-}" && -x "${POST_BACKUP_HOOK}" ]]; then
    log_msg "[*] Executing Post-Backup Hook: ${POST_BACKUP_HOOK}..."
    "${POST_BACKUP_HOOK}" "${ARCHIVE_PATH}" || true
  fi

  # 7. Retention Enforcement (Age Threshold + Minimum Backup Count Floor)
  prune_local_storage "${BACKUP_DIR}" "${LOCAL_RETENTION_DAYS}" "${ARCHIVE_PREFIX}-*.tar.*.gpg" "${LOCAL_MIN_KEEP:-${LOCAL_RETENTION_DAYS}}"
  prune_remote_storage "${TARGET_REMOTE}" "${TARGET_REMOTE_TYPE:-rclone}" "${REMOTE_RETENTION_DAYS}" "${ARCHIVE_PREFIX}-*.tar.*.gpg" "${REMOTE_MIN_KEEP:-${REMOTE_RETENTION_DAYS}}"

  if [[ -n "${TARGET_SECONDARY_REMOTE:-}" ]]; then
    prune_remote_storage "${TARGET_SECONDARY_REMOTE}" "${TARGET_SECONDARY_TYPE:-rclone}" "${REMOTE_RETENTION_DAYS}" "${ARCHIVE_PREFIX}-*.tar.*.gpg" "${REMOTE_MIN_KEEP:-${REMOTE_RETENTION_DAYS}}"
  fi

  # shellcheck disable=SC2034
  BACKUP_SUCCESSFUL=1
  log_msg "[✓] Encrypted backup completed successfully."
  return 0
}

# ------------------------------------------------------------------------------
# 6. Execution Pipeline & Notification Trigger
# ------------------------------------------------------------------------------
BACKUP_EXIT_CODE=0
if ! execute_backup_routine; then
  BACKUP_EXIT_CODE=1
fi

send_backup_notification "${BACKUP_EXIT_CODE}"

exit "${BACKUP_EXIT_CODE}"
