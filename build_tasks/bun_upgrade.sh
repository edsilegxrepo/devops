#!/bin/bash
# -----------------------------------------------------------------------------
#  e:/data/devel/build/code/private/devops/build_tasks/bun_upgrade.sh
#  v1.11.0  2026/07/19  XDG / MIS Center
# -----------------------------------------------------------------------------
#  Purpose:
#    Automates downloading, upgrading, and managing the Bun JavaScript runtime
#    across both Windows (Cygwin/MSYS2) and Linux environments.
#    Supports path expressions in drive:/path/sub format on Windows.
#
#  Syntax:
#    bun_upgrade.sh [--detect] [--update] [--auto] [--package] [--clear-cache]
#                   [--trust-all] [--list] [--update-modules] [--install] [--path <path>]
#                   [--install-module <module>] [--remove-module <module>]
#                   [--source <path>] [--target <path>] [--force] [--no-update-source]
#                   [--dry-run] [--token <pat>] [--verbose]
#
#  Diagnostics Exit Codes:
#    0 = Success
#    1 = Bun not found during check/detection
#    2 = Invalid arguments or command validations
#    3 = Missing environmental prerequisites (curl, unzip, taskkill.exe)
#    4 = Network download failure
#    5 = ZIP extraction failure
#    6 = Version verification execution check failure
#    7 = Bun client operation failure
# -----------------------------------------------------------------------------

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_LIB="${SCRIPT_DIR}/client_package_common.sh"
if [ ! -f "${COMMON_LIB}" ]; then
  echo "[ERROR] Missing required shared library: ${COMMON_LIB}" >&2
  exit 3
fi
# shellcheck source=client_package_common.sh
source "${COMMON_LIB}"

TEMP_ROOT_CYG=$(detect_temp_root)
TEMP_ROOT_PATH=$(enforce_drive_path "$TEMP_ROOT_CYG")
EXEC_WORKSPACE=""
CURRENT_BUILD_DIR=""
CURRENT_TARGET_TMP=""

# =============================================================================
#  CONFIGURATION GLOBALS
# =============================================================================

BUN_ORG="oven-sh"
BUN_REPO="bun"
BUN_ZIP_NAME="bun.zip"
BUN_DEFAULT_SUBDIR=".bun/bin"
BUN_BASE_URL="https://github.com/${BUN_ORG}/${BUN_REPO}/releases/latest"
BUN_DOWNLOAD_URL="${BUN_BASE_URL}/download"

# =============================================================================
#  PLATFORM INITIALIZATION
# =============================================================================

# Resolve POSIX equivalent of the user's home/profile directory
USER_HOME=""
if is_windows_platform && [ -n "${USERPROFILE:-}" ]; then
  USER_HOME=$(to_posix_path "${USERPROFILE}" 2> /dev/null || true)
fi
# Fallback to standard shell HOME directory if not resolved
[ -z "${USER_HOME}" ] && USER_HOME="${HOME:-}"

# =============================================================================
#  HELPER FUNCTIONS
# =============================================================================

# -----------------------------------------------------------------------------
#  Function: locate_bun
#  Description: Searches the current PATH and default directories (e.g. .bun/bin)
#               to find the active Bun binary.
#  Outputs:
#    Prints the absolute path of the bun executable to stdout if found.
# -----------------------------------------------------------------------------
function locate_bun() {
  if command -v "${BUN_REPO}" &> /dev/null; then
    command -v "${BUN_REPO}"
  elif [ -n "${USER_HOME}" ]; then
    if [ -f "${USER_HOME}/${BUN_DEFAULT_SUBDIR}/${BUN_REPO}.exe" ]; then
      echo "${USER_HOME}/${BUN_DEFAULT_SUBDIR}/${BUN_REPO}.exe"
    elif [ -f "${USER_HOME}/${BUN_DEFAULT_SUBDIR}/${BUN_REPO}" ]; then
      echo "${USER_HOME}/${BUN_DEFAULT_SUBDIR}/${BUN_REPO}"
    fi
  fi
}

# -----------------------------------------------------------------------------
#  Function: get_bun_home
#  Description: Resolves the target directory where Bun is (or should be) installed.
#               Prioritizes CLI args, environment overrides, and locate_bun.
#  Outputs:
#    Prints the directory path to stdout.
# -----------------------------------------------------------------------------
function get_bun_home() {
  # 1. Check command-line override path
  [ -n "${INSTALL_PATH:-}" ] && echo "${INSTALL_PATH}" && return 0

  # 2. Check environmental overrides
  [ -n "${BUN_HOME:-}" ] && echo "${BUN_HOME}" && return 0
  [ -n "${BUN_INSTALL:-}" ] && echo "${BUN_INSTALL}" && return 0

  # 3. Fallback to active binary folder or user home default
  local bin
  bin=$(locate_bun)
  if [ -n "${bin}" ]; then
    dirname "${bin}"
  else
    echo "${USER_HOME}/${BUN_DEFAULT_SUBDIR}"
  fi
}

# -----------------------------------------------------------------------------
#  Function: fetch_latest_version
#  Description: Fetches the latest available Bun version tag from GitHub releases.
#               Uses shared gh_resolve_release when jq is available, falling back
#               to HTTP Location redirect parsing otherwise.
#  Outputs:
#    Prints the version number (e.g. 1.4.5) to stdout if successful.
# -----------------------------------------------------------------------------
function fetch_latest_version() {
  if command -v jq > /dev/null 2>&1; then
    local info ver
    info=$(gh_resolve_release "${BUN_ORG}/${BUN_REPO}" "$BUN_REPO" "${BUN_REPO}-v" "${GITHUB_TOKEN:-}" 2> /dev/null || true)
    if [ -n "$info" ]; then
      IFS=$'\t' read -r ver _ <<< "$info"
      printf '%s\n' "$ver"
      return 0
    fi
  fi
  curl -sI --connect-timeout 10 --max-time 20 --retry 2 "${BUN_BASE_URL}" 2> /dev/null | grep -i '^Location:' | sed -E "s/.*tag\/${BUN_REPO}-v//I" | tr -d '\r'
}

# -----------------------------------------------------------------------------
#  Function: show_help
#  Description: Displays the CLI usage manual.
# -----------------------------------------------------------------------------
function show_help() {
  echo "Usage: $(basename "$0") [options]"
  echo ""
  echo "Options:"
  echo "  --detect               Detect current Bun version and path."
  echo "  --update               Upgrade Bun (unzip on Windows, 'bun upgrade' on Linux)."
  echo "  --auto                 With --update, check version first and skip if up-to-date."
  echo "  --package              Auto-detect latest GitHub release and package Linux/Windows x64 zips."
  echo "  --source <path>        With --package, software library dir (default: n:/softlib/software/public/devel/nodejs)."
  echo "  --target <path>        With --package, pending stage dir (default: f:/stage/upload/pending)."
  echo "  --force                With --package, download and stage even if local version is current."
  echo "  --no-update-source     With --package, stage to --target without modifying --source."
  echo "  --dry-run              With --package, preview actions without modifying files on disk."
  echo "  --token <pat>          With --package, GitHub token (or GITHUB_TOKEN / gh auth token)."
  echo "  --verbose              With --package, print resolved asset URLs and diagnostics."
  echo "  --clear-cache          Clear Bun PM cache (bun pm cache rm)."
  echo "  --trust-all            Trust all global package binaries."
  echo "  --list                 List global npm packages."
  echo "  --update-modules       Update global modules."
  echo "  --install              Perform a fresh install (requires --path)."
  echo "  --path <path>          The installation target directory (mandatory for --install)."
  echo "  --install-module <pkg> Install a global npm module (bun add -g <pkg>)."
  echo "  --remove-module <pkg>  Remove a global npm module (bun remove -g <pkg>)."
  echo "  -h, --help             Show this help menu."
}

# =============================================================================
#  CLI ARGUMENT PARSING
# =============================================================================

DO_DETECT="false"
DO_UPDATE="false"
DO_AUTO="false"
DO_PACKAGE="false"
DO_CLEAR_CACHE="false"
DO_TRUST_ALL="false"
DO_LIST="false"
DO_UPDATE_MODULES="false"
DO_INSTALL="false"
DO_INSTALL_MODULE="false"
INSTALL_MODULE_PKG=""
DO_REMOVE_MODULE="false"
REMOVE_MODULE_PKG=""
INSTALL_PATH=""
PKG_SOURCE_PATH=""
PKG_TARGET_PATH=""
PKG_TOKEN="${GITHUB_TOKEN:-}"
FORCE_REPACKAGE="false"
UPDATE_SOURCE="true"
DRY_RUN="false"
VERBOSE="false"

while [ $# -gt 0 ]; do
  case "$1" in
    --detect) DO_DETECT="true" && shift ;;
    --update) DO_UPDATE="true" && shift ;;
    --auto) DO_AUTO="true" && shift ;;
    --package) DO_PACKAGE="true" && shift ;;
    --source)
      [ -z "${2:-}" ] || [[ "$2" == -* ]] && log_error "--source requires an argument." && exit 2
      PKG_SOURCE_PATH="$2"
      shift 2
      ;;
    --target)
      [ -z "${2:-}" ] || [[ "$2" == -* ]] && log_error "--target requires an argument." && exit 2
      PKG_TARGET_PATH="$2"
      shift 2
      ;;
    --token)
      [ -z "${2:-}" ] || [[ "$2" == -* ]] && log_error "--token requires an argument." && exit 2
      PKG_TOKEN="$2"
      shift 2
      ;;
    --force) FORCE_REPACKAGE="true" && shift ;;
    --no-update-source) UPDATE_SOURCE="false" && shift ;;
    --dry-run) DRY_RUN="true" && shift ;;
    --verbose) VERBOSE="true" && shift ;;
    --clear-cache) DO_CLEAR_CACHE="true" && shift ;;
    --trust-all) DO_TRUST_ALL="true" && shift ;;
    --list) DO_LIST="true" && shift ;;
    --update-modules) DO_UPDATE_MODULES="true" && shift ;;
    --install) DO_INSTALL="true" && shift ;;
    --install-module)
      [ -z "${2:-}" ] || [[ "$2" == -* ]] && log_error "--install-module requires an argument." && exit 2
      DO_INSTALL_MODULE="true"
      INSTALL_MODULE_PKG="$2"
      shift 2
      ;;
    --remove-module)
      [ -z "${2:-}" ] || [[ "$2" == -* ]] && log_error "--remove-module requires an argument." && exit 2
      DO_REMOVE_MODULE="true"
      REMOVE_MODULE_PKG="$2"
      shift 2
      ;;
    --path)
      [ -z "${2:-}" ] || [[ "$2" == -* ]] && log_error "--path requires an argument." && exit 2
      INSTALL_PATH="$2"
      shift 2
      ;;
    -h | --help) show_help && exit 0 ;;
    *) log_error "Unknown option '$1'" && show_help && exit 2 ;;
  esac
done

# =============================================================================
#  VALIDATION & SANITY CHECKS
# =============================================================================

# Require at least one action flag
if [ "${DO_DETECT}" = "false" ] && [ "${DO_UPDATE}" = "false" ] &&
  [ "${DO_PACKAGE}" = "false" ] && [ "${DO_CLEAR_CACHE}" = "false" ] &&
  [ "${DO_TRUST_ALL}" = "false" ] && [ "${DO_LIST}" = "false" ] &&
  [ "${DO_UPDATE_MODULES}" = "false" ] && [ "${DO_INSTALL}" = "false" ] &&
  [ "${DO_INSTALL_MODULE}" = "false" ] && [ "${DO_REMOVE_MODULE}" = "false" ]; then
  show_help
  exit 0
fi

# Fresh install requires the target path explicitly specified
if [ "${DO_INSTALL}" = "true" ] && [ -z "${INSTALL_PATH}" ]; then
  log_error "--path <path> is mandatory when using --install."
  exit 2
fi

# Fail-fast if update is requested but Bun is not installed
if [ "${DO_UPDATE}" = "true" ] && [ "${DO_INSTALL}" = "false" ] && [ -z "${INSTALL_PATH}" ]; then
  if [ -z "$(locate_bun)" ]; then
    log_error "Bun is not installed. Use --install --path <path> to perform a fresh install."
    exit 2
  fi
fi

# =============================================================================
#  OPERATION PIPELINES
# =============================================================================

# -----------------------------------------------------------------------------
#  Pipeline 1: DETECT MODE (Standalone)
# -----------------------------------------------------------------------------
if [ "${DO_DETECT}" = "true" ]; then
  bun_path=$(locate_bun)
  if [ -n "${bun_path}" ]; then
    bun_version=$("${bun_path}" --version 2> /dev/null | tr -d '\r')
    [ -z "${bun_version}" ] && bun_version=$("${bun_path}" -v 2> /dev/null | tr -d '\r')

    mixed_path=$(enforce_drive_path "${bun_path}")

    in_path="NO"
    command -v "${BUN_REPO}" &> /dev/null && in_path="YES"

    echo "Bun Version:    ${bun_version}"
    echo "Located Path:   ${mixed_path}"
    echo "In system PATH: ${in_path}"
    exit 0
  else
    log_error "Bun is not installed or not found."
    exit 1
  fi
fi

# -----------------------------------------------------------------------------
#  Pipeline 2: INSTALL / UPDATE PIPELINE
# -----------------------------------------------------------------------------
if [ "${DO_INSTALL}" = "true" ] || [ "${DO_UPDATE}" = "true" ]; then
  # Fail-fast check for command-line prerequisites
  verify_required_tools curl unzip

  # Perform smart version comparison check if --auto is enabled
  if [ "${DO_UPDATE}" = "true" ] && [ "${DO_AUTO}" = "true" ]; then
    current_bin=$(locate_bun)
    if [ -n "${current_bin}" ]; then
      current_ver=$("${current_bin}" -version 2> /dev/null | tr -d '\r')
      if [ -n "${current_ver}" ]; then
        log_info "Checking latest version info from GitHub..."
        latest_ver=$(fetch_latest_version)
        if [ -n "${latest_ver}" ]; then
          if [ "${current_ver}" = "${latest_ver}" ]; then
            log_info "Bun is already up to date (version ${current_ver}). Skipping upgrade."
            exit 0
          else
            log_info "New version ${latest_ver} is available (current: ${current_ver})."
          fi
        else
          log_info "Unable to fetch latest version info. Proceeding with upgrade..."
        fi
      fi
    fi
  fi

  # Determine target release archive name and platform specifics
  zip_name=""
  exe_name=""
  if is_windows_platform; then
    if ! command -v taskkill.exe &> /dev/null; then
      log_error "Windows prerequisite 'taskkill.exe' is not in PATH."
      exit 3
    fi
    zip_name="${BUN_REPO}-windows-x64.zip"
    exe_name="${BUN_REPO}.exe"
  else
    zip_name="${BUN_REPO}-linux-x64.zip"
    exe_name="${BUN_REPO}"
  fi

  # Resolve paths and setup directory structure
  bun_home=$(get_bun_home)
  mixed_home=$(enforce_drive_path "${bun_home}")

  log_info "Target Directory: ${mixed_home}"
  mkdir -p "${bun_home}"
  zip_file="${bun_home}/${BUN_ZIP_NAME}"

  # Retrieve release package
  log_info "Downloading Bun..."
  if ! download_asset "${BUN_DOWNLOAD_URL}/${zip_name}" "${zip_file}" "" "sha256" || [ ! -s "${zip_file}" ]; then
    log_error "Failed to download Bun package."
    exit 4
  fi

  # Terminate processes to unlock files
  log_info "Terminating active bun processes..."
  if is_windows_platform; then
    taskkill.exe /F /IM "${exe_name}" 2> /dev/null || true
  else
    pkill "${exe_name}" 2> /dev/null || killall "${exe_name}" 2> /dev/null || true
  fi

  # Extract bundle contents
  log_info "Extracting Bun..."
  (
    cd "${bun_home}" || exit 5
    unzip -jo "${BUN_ZIP_NAME}" || exit 5
    rm -f "${BUN_ZIP_NAME}"
  ) || exit 5

  # Assign execution rights under Linux
  if [ "${exe_name}" = "${BUN_REPO}" ] && [ -f "${bun_home}/${exe_name}" ]; then
    chmod +x "${bun_home}/${exe_name}"
  fi

  # Run validation diagnostic check
  if [ -f "${bun_home}/${exe_name}" ]; then
    ver=""
    ver=$("${bun_home}/${exe_name}" -version 2> /dev/null)
    if [ -n "${ver}" ]; then
      log_info "Bun installed/upgraded successfully!"
      log_info "Verified Version: ${ver}"
    else
      log_error "Bun binary found, but it failed to execute or return version info."
      exit 6
    fi
  else
    log_error "Extraction complete, but ${exe_name} is missing."
    exit 6
  fi
fi

# 3. CLIENT OPERATIONS
if [ "${DO_CLEAR_CACHE}" = "true" ] || [ "${DO_TRUST_ALL}" = "true" ] || [ "${DO_UPDATE_MODULES}" = "true" ] || [ "${DO_LIST}" = "true" ] || [ "${DO_INSTALL_MODULE}" = "true" ] || [ "${DO_REMOVE_MODULE}" = "true" ]; then
  bun_bin=$(locate_bun)

  # Fallback to local path if not found in current shell session's PATH
  if [ -z "${bun_bin}" ]; then
    bun_home=$(get_bun_home)
    if is_windows_platform && [ -f "${bun_home}/${BUN_REPO}.exe" ]; then
      bun_bin="${bun_home}/${BUN_REPO}.exe"
    elif [ -f "${bun_home}/${BUN_REPO}" ]; then
      bun_bin="${bun_home}/${BUN_REPO}"
    fi
  fi

  # Require binary to exist
  if [ -z "${bun_bin}" ]; then
    log_error "Bun is not installed. Use --install or --update first."
    exit 2
  fi

  # Resolve Bun's global installation directory path
  install_dir=$(get_bun_home)
  if [[ "${install_dir}" == */bin ]]; then
    install_dir=$(dirname "${install_dir}")
  fi
  global_dir="${install_dir}/install/global"

  # Ensure the global installation directory is initialized with a package.json and bun.lock
  # to prevent Bun PM commands from throwing "No package.json" or "Lockfile not found" errors.
  if [ ! -f "${global_dir}/package.json" ]; then
    mkdir -p "${global_dir}" 2> /dev/null
    echo '{"name": "bun-global"}' > "${global_dir}/package.json" 2> /dev/null
  fi
  if [ ! -f "${global_dir}/bun.lock" ]; then
    mkdir -p "${global_dir}" 2> /dev/null
    echo '{"lockfileVersion": 1, "configVersion": 1, "workspaces": {"": {"name": "bun-global"}}, "packages": {}}' > "${global_dir}/bun.lock" 2> /dev/null
  fi

  # Workaround: Bun client operations throw an error if no package.json is present in the CWD.
  # We execute all client operations inside an isolated temporary workspace with a dummy package.json.
  temp_dir=$(create_temp_workdir "bun_tmp_" "$(get_bun_home)") || exit 5
  EXEC_WORKSPACE="$temp_dir"
  (
    cd "${temp_dir}" || exit 5
    echo '{"name": "temp-client-ops"}' > package.json

    if [ "${DO_CLEAR_CACHE}" = "true" ]; then
      log_info "Clearing Bun PM cache..."
      "${bun_bin}" pm cache rm || {
        log_error "Bun clear-cache failed."
        exit 7
      }
    fi
    if [ "${DO_TRUST_ALL}" = "true" ]; then
      log_info "Trusting global package binaries..."
      "${bun_bin}" pm trust -g --all || {
        log_error "Bun trust-all failed."
        exit 7
      }
    fi
    if [ "${DO_UPDATE_MODULES}" = "true" ]; then
      log_info "Updating global modules..."
      "${bun_bin}" update -g || {
        log_error "Bun global module update failed."
        exit 7
      }
    fi
    if [ "${DO_LIST}" = "true" ]; then
      log_info "Listing global modules..."
      "${bun_bin}" pm ls -g || {
        log_error "Bun listing global modules failed."
        exit 7
      }
    fi
    if [ "${DO_INSTALL_MODULE}" = "true" ]; then
      log_info "Installing global module ${INSTALL_MODULE_PKG}..."
      "${bun_bin}" add -g "${INSTALL_MODULE_PKG}" || {
        log_error "Bun install-module failed."
        exit 7
      }
    fi
    if [ "${DO_REMOVE_MODULE}" = "true" ]; then
      log_info "Removing global module ${REMOVE_MODULE_PKG}..."
      "${bun_bin}" remove -g "${REMOVE_MODULE_PKG}" || {
        log_error "Bun remove-module failed."
        exit 7
      }
    fi

    cd - &> /dev/null || true
  ) || exit 7
  cleanup_exec_workspace
fi

# -----------------------------------------------------------------------------
#  Pipeline 4: PACKAGE MODE (--package)
# -----------------------------------------------------------------------------
if [ "${DO_PACKAGE}" = "true" ]; then
  set -Eeo pipefail
  enable_err_trap

  SOURCE_PATH="${PKG_SOURCE_PATH:-$(resolve_default_path "n" "softlib/software/public/devel/nodejs")}"
  TARGET_PATH="${PKG_TARGET_PATH:-$(resolve_default_path "f" "stage/upload/pending")}"
  SOURCE_PATH=$(enforce_drive_path "$SOURCE_PATH")
  SOURCE_CYG=$(to_posix_path "$SOURCE_PATH")
  TARGET_PATH=$(enforce_drive_path "$TARGET_PATH")
  TARGET_CYG=$(to_posix_path "$TARGET_PATH")
  GITHUB_TOKEN="${PKG_TOKEN:-}"

  verify_required_tools curl unzip jq

  print_action_banner "Bun Binary Packaging Utility" \
    "Platform" "$PLATFORM" \
    "Repository" "${BUN_ORG}/${BUN_REPO}" \
    "Source Library" "$SOURCE_PATH" \
    "Target Pending" "$TARGET_PATH" \
    "Dry Run" "$DRY_RUN" \
    "Force Repack" "$FORCE_REPACKAGE" \
    "Update Source" "$UPDATE_SOURCE" \
    "Temp Root Dir" "$TEMP_ROOT_PATH"

  rel_info=""
  if ! rel_info=$(gh_resolve_release "${BUN_ORG}/${BUN_REPO}" "$BUN_REPO" "${BUN_REPO}-v" "$GITHUB_TOKEN"); then
    log_error "Failed to query latest Bun release from GitHub."
    exit 4
  fi

  rver=""
  rtag=""
  rel_json=""
  IFS=$'\t' read -r rver rtag rel_json <<< "$rel_info"
  log_info "Remote latest version: ${rver} (tag: ${rtag})"

  lnx_row=$(gh_find_asset "$rel_json" "^bun-linux-x64[.]zip$" "musl|baseline|profile|android|aarch64|arm")
  win_row=$(gh_find_asset "$rel_json" "^bun-windows-x64[.]zip$" "baseline|profile|aarch64|arm")

  lnx_name="" lnx_url="" lnx_digest=""
  win_name="" win_url="" win_digest=""
  if [ -n "$lnx_row" ]; then
    IFS=$'\t' read -r lnx_name lnx_url lnx_digest <<< "$lnx_row"
  fi
  if [ -n "$win_row" ]; then
    IFS=$'\t' read -r win_name win_url win_digest <<< "$win_row"
  fi

  if [ -z "$lnx_url" ] || [ -z "$win_url" ]; then
    log_error "Missing required x64 release assets (linux='${lnx_name:-MISSING}', windows='${win_name:-MISSING}')"
    exit 4
  fi

  if [ "$VERBOSE" = true ]; then
    log_info "  Linux x64 asset  : $lnx_name ($lnx_url)"
    log_info "  Windows x64 asset: $win_name ($win_url)"
  fi

  init_exec_workspace "bun_pkg_" "$SOURCE_CYG" "$TARGET_CYG" "$DRY_RUN" "$UPDATE_SOURCE"

  TOTAL_COUNT=0
  UPDATED_COUNT=0
  SKIPPED_COUNT=0
  ERROR_COUNT=0

  dest_src_dir=""
  if [ "$UPDATE_SOURCE" = true ]; then
    dest_src_dir="$SOURCE_CYG"
  fi

  for plat_spec in \
    "Linux x64|linux-x64|${lnx_name}|${lnx_url}|${lnx_digest}|bun-linux-x64/bun" \
    "Windows x64|windows-x64|${win_name}|${win_url}|${win_digest}|bun-windows-x64/bun.exe"; do
    IFS='|' read -r p_label p_suffix a_name a_url a_digest expected_entry <<< "$plat_spec"
    TOTAL_COUNT=$((TOTAL_COUNT + 1))

    lver="" lfile=""
    read -r lver lfile < <(find_local_version "$SOURCE_CYG" "$BUN_REPO" "$p_suffix" "zip")
    log_info "Local ${p_label} version  : ${lver} (${lfile:-none})"

    pkg_name="${BUN_REPO}-${rver}-${p_suffix}.zip"
    if [ "$FORCE_REPACKAGE" != true ] && ! is_version_newer "$rver" "$lver"; then
      log_info "${p_label} package is already up to date (${lver} >= ${rver})."
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
      continue
    fi

    if [ "$DRY_RUN" = true ]; then
      log_ok "[DRY-RUN] Would download: $a_name -> $pkg_name"
      atomic_stage_package "" "$pkg_name" "$BUN_REPO" "$p_suffix" "$dest_src_dir" "$TARGET_CYG" true
      UPDATED_COUNT=$((UPDATED_COUNT + 1))
      continue
    fi

    CURRENT_BUILD_DIR=$(mktemp -d "${EXEC_WORKSPACE}/${BUN_REPO}_${p_suffix}_XXXXXX")
    pkg_file="${CURRENT_BUILD_DIR}/${pkg_name}"

    if ! gh_download_verified_asset "$rel_json" "$p_label" "$a_name" "$a_url" "$a_digest" "$pkg_file" "$CURRENT_BUILD_DIR"; then
      cleanup_current_build_dir
      ERROR_COUNT=$((ERROR_COUNT + 1))
      continue
    fi

    if ! verify_zip_integrity "$pkg_file" || ! verify_zip_has_entry "$pkg_file" "$expected_entry"; then
      log_error "Downloaded ${p_label} zip failed validation (corrupt or missing '${expected_entry}'): $a_name"
      cleanup_current_build_dir
      ERROR_COUNT=$((ERROR_COUNT + 1))
      continue
    fi

    if atomic_stage_package "$pkg_file" "$pkg_name" "$BUN_REPO" "$p_suffix" "$dest_src_dir" "$TARGET_CYG" false; then
      UPDATED_COUNT=$((UPDATED_COUNT + 1))
      log_ok "Packaged and staged: ${pkg_name}"
    else
      ERROR_COUNT=$((ERROR_COUNT + 1))
    fi
    cleanup_current_build_dir
  done

  cleanup_exec_workspace
  print_packaging_summary "Bun Packaging Summary" "$TOTAL_COUNT" "$UPDATED_COUNT" "$SKIPPED_COUNT" "$ERROR_COUNT"
  [ "$ERROR_COUNT" -eq 0 ] || exit 4
fi

log_info "Done."
exit 0
