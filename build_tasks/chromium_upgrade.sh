#!/bin/bash
# -----------------------------------------------------------------------------
#  e:/data/devel/build/code/private/devops/build_tasks/chromium_upgrade.sh
#  v1.0.3  2026/09/08  XDG / MIS Center
# -----------------------------------------------------------------------------
#  Purpose:
#    Automates downloading, repackaging, and deploying Chromium browser builds
#    across Windows (Cygwin/MSYS2) and Linux environments.
#
#    Packaging Mode (--action package):
#      - Downloads official binary distributions (Hibbiki win64 / Ungoogled Linux)
#      - Normalizes internal folder layout to 'chromium'
#      - Prunes non-English locales (retains only en-US.*)
#      - Repacks inner payload with maximum compression (7z on Windows, tar.xz on Linux)
#      - Stages inner payload to --archive-path (default: f:/stage/upload/pending/)
#      - Wraps inner payload into chromium-<major>.<minor>-<w64|lnx>.zip and updates
#        --release-path (default: n:/softlib/software/public/inet/www/browser/chrome/)
#
#    Deployment Mode (--action deploy):
#      - Extracts packaged archive to target directory (--to-folder)
#      - Verifies and displays installed Chromium version info
#
#  Syntax:
#    chromium_upgrade.sh --action package [--platform windows,linux]
#                        [--from-url <url>] [--release-path <path>]
#                        [--archive-path <path>] [--with-7z <path>]
#                        [--force] [--no-update-source] [--dry-run]
#
#    chromium_upgrade.sh --action deploy
#                        [--from-folder <folder>] [--from-url <url>]
#                        --to-folder <folder> [--with-7z <path>] [--purge] [--dry-run]
#
#  Examples:
#    [WINDOWS]
#    - package:
#      ./chromium_upgrade.sh --action package --platform windows,linux --with-7z c:/tls/arc/7zip/
#    - deploy:
#      ./chromium_upgrade.sh --action deploy --from-folder f:/stage/upload/pending/chromium-150.0.7871.187_1639810-x64.7z --to-folder d:/inet/www/chromium/
#
#    [LINUX]
#    - deploy:
#      ./chromium_upgrade.sh --action deploy --from-folder /opt/install/queue/chromium-150.0.7871.186-1-ungoogled-x86_64_linux.tar.xz --to-folder /u01/chromium/
#
#  Diagnostics Exit Codes:
#    0 = Success
#    1 = Release up-to-date (skipped) or operation abort
#    2 = Invalid arguments or command validation error
#    3 = Missing environmental prerequisites (curl, zip, unzip, 7z, tar, xz, powershell)
#    4 = Network download failure
#    5 = Archive extraction failure
#    6 = Package creation / compression failure
#    7 = Deployment or version verification failure
# -----------------------------------------------------------------------------

set -euo pipefail

# =============================================================================
#  SHARED LIBRARY INITIALIZATION & PATH ENVIRONMENT
# =============================================================================
LOG_INFO_TO_STDERR=1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_LIB="${SCRIPT_DIR}/client_package_common.sh"
if [ ! -f "${COMMON_LIB}" ]; then
  echo "[ERROR] Shared library not found: ${COMMON_LIB}" >&2
  exit 3
fi
# shellcheck source=client_package_common.sh
source "${COMMON_LIB}"
# chromium_upgrade.sh uses granular exit codes (1..7) and logs explicitly before exit
trap - ERR

# =============================================================================
#  DEFAULT CONFIGURATION GLOBALS
# =============================================================================

DEFAULT_WIN_FROM_URL="https://github.com/Hibbiki/chromium-win64/releases/"
DEFAULT_LNX_FROM_URL="https://ungoogled-software.github.io/ungoogled-chromium-binaries/"

DEFAULT_RELEASE_PATH="$(resolve_default_path "n" "softlib/software/public/inet/www/browser/chrome")"
DEFAULT_ARCHIVE_PATH="$(resolve_default_path "f" "stage/upload/pending")"

# shellcheck disable=SC2034
NUM_JOBS=$(nproc 2> /dev/null || echo 4)

# Sanitize environmental path variables upfront for Windows native tools
[ -n "${TMPDIR:-}" ] && TMPDIR=$(to_mixed_path "${TMPDIR}")
[ -n "${TMP:-}" ] && TMP=$(to_mixed_path "${TMP}")
[ -n "${TEMP:-}" ] && TEMP=$(to_mixed_path "${TEMP}")
[ -n "${USERPROFILE:-}" ] && USERPROFILE=$(to_mixed_path "${USERPROFILE}")
[ -n "${HOME:-}" ] && HOME=$(to_mixed_path "${HOME}")

# =============================================================================
#  PREREQUISITE & TOOL RESOLUTION
# =============================================================================

WITH_7Z_PATH=""
RESOLVED_7Z_BIN=""
RESOLVED_WSL_BIN=""
SEVENZIP_BIN=""

function find_wsl_binary() {
  resolve_wsl_binary
}

function find_7z_binary() {
  local cand=""

  # 1. Explicit CLI argument --with-7z
  if [ -n "${WITH_7Z_PATH:-}" ]; then
    cand=$(to_posix_path "${WITH_7Z_PATH}")
    if [ -d "${cand}" ]; then
      if [ -f "${cand}/7z.exe" ]; then
        to_mixed_path "${cand}/7z.exe"
        return 0
      fi
      if [ -f "${cand}/7za.exe" ]; then
        to_mixed_path "${cand}/7za.exe"
        return 0
      fi
      if [ -f "${cand}/7z" ]; then
        to_mixed_path "${cand}/7z"
        return 0
      fi
    elif [ -f "${cand}" ]; then
      to_mixed_path "${cand}"
      return 0
    fi
    log_error "Specified 7z path via --with-7z not found: $(to_mixed_path "${WITH_7Z_PATH}")"
    return 1
  fi

  # 2. Check 7Z_HOME environment variable
  local env_7z_home
  env_7z_home=$(printenv 7Z_HOME 2> /dev/null || true)
  if [ -n "${env_7z_home}" ]; then
    cand=$(to_posix_path "${env_7z_home}")
    if [ -d "${cand}" ]; then
      if [ -f "${cand}/7z.exe" ]; then
        to_mixed_path "${cand}/7z.exe"
        return 0
      fi
      if [ -f "${cand}/7za.exe" ]; then
        to_mixed_path "${cand}/7za.exe"
        return 0
      fi
    elif [ -f "${cand}" ]; then
      to_mixed_path "${cand}"
      return 0
    fi
  fi

  # 3. Check common Windows installation paths
  local std_paths=(
    "c:/tls/arc/7zip/7z.exe"
    "c:/Program Files/7-Zip/7z.exe"
    "c:/Program Files (x86)/7-Zip/7z.exe"
  )
  for p in "${std_paths[@]}"; do
    cand=$(to_posix_path "${p}")
    if [ -f "${cand}" ]; then
      to_mixed_path "${cand}"
      return 0
    fi
  done

  # 4. Check system PATH
  local path_7z=""
  if path_7z=$(command -v 7z.exe 2> /dev/null || command -v 7z 2> /dev/null || command -v 7za.exe 2> /dev/null || command -v 7za 2> /dev/null) && [ -n "${path_7z}" ]; then
    to_mixed_path "${path_7z}"
    return 0
  fi

  return 1
}

function verify_prerequisites() {
  local target_platform="$1"
  local missing=()

  if ! command -v curl &> /dev/null; then missing+=("curl"); fi
  if ! command -v grep &> /dev/null; then missing+=("grep"); fi
  if ! command -v sed &> /dev/null; then missing+=("sed"); fi

  if [ "${ACTION}" = "package" ] && [ "${UPDATE_SOURCE}" = "true" ]; then
    if ! command -v zip &> /dev/null; then missing+=("zip"); fi
    if ! command -v unzip &> /dev/null; then missing+=("unzip"); fi
  fi

  if is_windows_platform; then
    RESOLVED_7Z_BIN=$(find_7z_binary || true)
    RESOLVED_WSL_BIN=$(find_wsl_binary || true)
    SEVENZIP_BIN="${RESOLVED_7Z_BIN}"
  fi

  if [[ "${target_platform}" == *"windows"* ]]; then
    if ! command -v cygpath &> /dev/null; then missing+=("cygpath"); fi
    if ! command -v powershell &> /dev/null && ! command -v powershell.exe &> /dev/null; then
      missing+=("powershell")
    fi

    if [ -z "${RESOLVED_7Z_BIN}" ]; then
      missing+=("7z (specify via --with-7z <path> or 7Z_HOME)")
    else
      log_info "Using 7z binary: $(to_mixed_path "${RESOLVED_7Z_BIN}")"
    fi
  fi

  if [[ "${target_platform}" == *"linux"* ]]; then
    if is_windows_platform; then
      if [ -z "${RESOLVED_WSL_BIN}" ]; then
        missing+=("wsl (WSL is required on Windows to preserve Linux POSIX execution attributes)")
      else
        log_info "Using WSL binary for Linux packaging: $(to_mixed_path "${RESOLVED_WSL_BIN}")"
      fi
    else
      if ! command -v tar &> /dev/null; then missing+=("tar"); fi
      if ! command -v xz &> /dev/null; then missing+=("xz"); fi
      if [ -n "${RESOLVED_7Z_BIN}" ]; then
        log_info "Using 7z binary: $(to_mixed_path "${RESOLVED_7Z_BIN}")"
      fi
    fi
  fi

  if [ ${#missing[@]} -gt 0 ]; then
    log_error "Missing required environmental prerequisites for platform '${target_platform}':"
    for item in "${missing[@]}"; do
      log_error "  - ${item}"
    done
    exit 3
  fi
}

# Wrapper to execute 7z.exe with Windows drive path formatting (DRY principle)
function exec_7z() {
  local mode="$1"
  shift
  local bin="${RESOLVED_7Z_BIN:-}"
  [ -z "${bin}" ] && bin=$(command -v 7z.exe 2> /dev/null || command -v 7z 2> /dev/null || true)
  [ -z "${bin}" ] && return 1

  local posix_7z
  posix_7z=$(to_posix_path "${bin}")

  local win_args=()
  for arg in "$@"; do
    if [[ "${arg}" == -o* ]]; then
      local out_dir="${arg#-o}"
      win_args+=("-o$(to_mixed_path "${out_dir}")")
    elif [[ "${arg}" == -* ]]; then
      win_args+=("${arg}")
    else
      win_args+=("$(to_mixed_path "${arg}")")
    fi
  done

  "${posix_7z}" "${mode}" "${win_args[@]}"
}

# =============================================================================
#  HELP & CLI ARGUMENT PARSING
# =============================================================================

function show_help() {
  echo "Usage: $(basename "$0") --action package|deploy [options]"
  echo ""
  echo "Actions:"
  echo "  --action package         Package a raw Chromium release after pruning non-US locales."
  echo "  --action deploy          Deploy a packaged Chromium archive to a target folder."
  echo ""
  echo "Options:"
  echo "  --platform <win|linux>   Target OS platform (default: auto-detected from system/URL)."
  echo "  --from-url <url>         Source release page or direct download URL."
  echo "  --release-path <path>    Reference/library path for chromium-<maj.min>-<w64|lnx>.zip envelopes"
  echo "                           (default: ${DEFAULT_RELEASE_PATH})."
  echo "  --archive-path <path>    Target destination directory for inner .7z / .tar.xz archives"
  echo "                           (default: ${DEFAULT_ARCHIVE_PATH})."
  echo "  --from-folder <folder>   Source folder (auto-detects latest archive) or exact archive file path."
  echo "  --to-folder <folder>     Destination directory for extraction and deployment."
  echo "  --with-7z <path>         Path to 7z executable or directory (Windows)."
  echo "  --force                  Force packaging or deployment even if up to date."
  echo "  --no-update-source       In --action package, stage to --archive-path without modifying --release-path."
  echo "  --dry-run                Preview actions without downloading or modifying files on disk."
  echo "  --purge                  Delete source archive file after successful deployment (--action deploy only)."
  echo "  -h, --help               Display this help menu."
  echo ""
  echo "Examples:"
  echo "  # Package Windows release:"
  echo "  $(basename "$0") --action package --platform windows --with-7z c:/tls/arc/7zip/"
  echo ""
  echo "  # Package Linux release:"
  echo "  $(basename "$0") --action package --platform linux"
  echo ""
  echo "  # Deploy from folder:"
  echo "  $(basename "$0") --action deploy --from-folder f:/stage/upload/pending --to-folder d:/inet/www/chromium"
  echo ""
  echo "  # Deploy from direct URL:"
  echo "  $(basename "$0") --action deploy --from-url https://example.com/chromium-150.0.7871.187_1639810-x64.7z --to-folder d:/inet/www/chromium"
}

ACTION=""
TARGET_PLATFORM=""
FROM_URL=""
RELEASE_PATH=""
ARCHIVE_PATH=""
FROM_FOLDER=""
TO_FOLDER=""
FORCE="false"
UPDATE_SOURCE="true"
DRY_RUN="false"
PURGE="false"

while [ $# -gt 0 ]; do
  case "$1" in
    --action)
      [ -z "${2:-}" ] || [[ "$2" == -* ]] && log_error "--action requires 'package' or 'deploy'." && exit 2
      ACTION="$2"
      shift 2
      ;;
    --platform)
      [ -z "${2:-}" ] || [[ "$2" == -* ]] && log_error "--platform requires 'windows', 'linux', or 'windows,linux'." && exit 2
      new_plat=$(echo "$2" | tr '[:upper:]' '[:lower:]')
      if [ -n "${TARGET_PLATFORM:-}" ]; then
        TARGET_PLATFORM="${TARGET_PLATFORM},${new_plat}"
      else
        TARGET_PLATFORM="${new_plat}"
      fi
      shift 2
      ;;
    --from-url)
      [ -z "${2:-}" ] || [[ "$2" == -* ]] && log_error "--from-url requires a URL parameter." && exit 2
      FROM_URL="$2"
      shift 2
      ;;
    --release-path)
      [ -z "${2:-}" ] || [[ "$2" == -* ]] && log_error "--release-path requires a file/directory path." && exit 2
      RELEASE_PATH="$2"
      shift 2
      ;;
    --archive-path)
      [ -z "${2:-}" ] || [[ "$2" == -* ]] && log_error "--archive-path requires a directory path." && exit 2
      ARCHIVE_PATH="$2"
      shift 2
      ;;
    --from-folder)
      [ -z "${2:-}" ] || [[ "$2" == -* ]] && log_error "--from-folder requires a directory path." && exit 2
      FROM_FOLDER="$2"
      shift 2
      ;;
    --to-folder)
      [ -z "${2:-}" ] || [[ "$2" == -* ]] && log_error "--to-folder requires a directory path." && exit 2
      TO_FOLDER="$2"
      shift 2
      ;;
    --with-7z)
      [ -z "${2:-}" ] || [[ "$2" == -* ]] && log_error "--with-7z requires a path parameter." && exit 2
      WITH_7Z_PATH="$2"
      shift 2
      ;;
    --force)
      FORCE="true"
      shift
      ;;
    --no-update-source)
      UPDATE_SOURCE="false"
      shift
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    --purge)
      PURGE="true"
      shift
      ;;
    -h | --help)
      show_help
      exit 0
      ;;
    *)
      log_error "Unknown option '$1'"
      show_help
      exit 2
      ;;
  esac
done

# Sanitize all CLI input paths for Cygwin/MSYS2 compatibility
[ -n "${RELEASE_PATH}" ] && RELEASE_PATH=$(to_mixed_path "${RELEASE_PATH}")
[ -n "${ARCHIVE_PATH}" ] && ARCHIVE_PATH=$(to_mixed_path "${ARCHIVE_PATH}")
[ -n "${FROM_FOLDER}" ] && FROM_FOLDER=$(to_mixed_path "${FROM_FOLDER}")
[ -n "${TO_FOLDER}" ] && TO_FOLDER=$(to_mixed_path "${TO_FOLDER}")
[ -n "${WITH_7Z_PATH}" ] && WITH_7Z_PATH=$(to_mixed_path "${WITH_7Z_PATH}")

if [ -z "${ACTION}" ]; then
  log_error "--action parameter is mandatory (package or deploy)."
  show_help
  exit 2
fi

if [ "${ACTION}" != "package" ] && [ "${ACTION}" != "deploy" ]; then
  log_error "Invalid action '${ACTION}'. Must be 'package' or 'deploy'."
  exit 2
fi

# Platform Auto-Detection / Validation
if [ "${ACTION}" = "deploy" ]; then
  if [ -n "${TARGET_PLATFORM:-}" ]; then
    log_error "--platform option is not allowed for deployment mode. Deployment target platform is always auto-detected."
    exit 2
  fi
  if [ "${UPDATE_SOURCE}" = "false" ]; then
    log_error "--no-update-source option is only allowed with --action package."
    exit 2
  fi

  if is_windows_platform; then
    TARGET_PLATFORM="windows"
  else
    local_hint="${FROM_URL}${FROM_FOLDER}${TO_FOLDER}"
    if [[ "${local_hint}" == *"win"* || "${local_hint}" == *"w64"* ]]; then
      TARGET_PLATFORM="windows"
    else
      TARGET_PLATFORM="linux"
    fi
  fi
  log_info "Auto-detected deployment platform target: ${TARGET_PLATFORM}"
else
  # Packaging mode: default to both windows and linux if not specified
  if [ "${PURGE}" = "true" ]; then
    log_error "--purge option is prohibited for packaging mode. It is only allowed with --action deploy."
    exit 2
  fi

  if [ -z "${TARGET_PLATFORM:-}" ]; then
    TARGET_PLATFORM="windows,linux"
    log_info "Packaging platform target not specified; defaulting to both: windows, linux"
  fi

  case "${TARGET_PLATFORM}" in
    windows | win)
      TARGET_PLATFORM="windows"
      ;;
    linux | lnx)
      TARGET_PLATFORM="linux"
      ;;
    windows,linux | linux,windows | win,linux | linux,win)
      TARGET_PLATFORM="windows,linux"
      ;;
    *)
      log_error "Invalid --platform '${TARGET_PLATFORM}'. Supported values for packaging are: windows, linux, or windows,linux."
      exit 2
      ;;
  esac
fi

function verify_specified_paths() {
  local invalid=()

  if [ "${ACTION}" = "package" ]; then
    local check_ref="${RELEASE_PATH:-${DEFAULT_RELEASE_PATH}}"
    local posix_ref
    posix_ref=$(to_posix_path "${check_ref}")
    if [ "${FORCE}" = "false" ] && [ ! -e "${posix_ref}" ]; then
      invalid+=("Specified --release-path does not exist: $(to_mixed_path "${check_ref}")")
    elif [ "${UPDATE_SOURCE}" = "true" ] && [ ! -d "${posix_ref}" ]; then
      local parent_ref
      parent_ref=$(dirname "${posix_ref}")
      if [ ! -d "${parent_ref}" ]; then
        invalid+=("Target --release-path parent directory does not exist: $(to_mixed_path "${check_ref}")")
      fi
    fi

    local check_arch="${ARCHIVE_PATH:-${DEFAULT_ARCHIVE_PATH}}"
    local posix_arch
    posix_arch=$(to_posix_path "${check_arch}")
    if [ ! -d "${posix_arch}" ]; then
      local parent_arch
      parent_arch=$(dirname "${posix_arch}")
      if [ ! -d "${parent_arch}" ]; then
        invalid+=("Target --archive-path parent directory does not exist: $(to_mixed_path "${check_arch}")")
      fi
    fi
  fi

  if [ "${ACTION}" = "deploy" ] && [ -n "${FROM_FOLDER:-}" ]; then
    local posix_src
    posix_src=$(to_posix_path "${FROM_FOLDER}")
    if [ ! -e "${posix_src}" ]; then
      invalid+=("Specified --from-folder does not exist: $(to_mixed_path "${FROM_FOLDER}")")
    fi
  fi

  if [ "${ACTION}" = "deploy" ] && [ -n "${TO_FOLDER:-}" ]; then
    local posix_to
    posix_to=$(to_posix_path "${TO_FOLDER}")
    local parent_to
    parent_to=$(dirname "${posix_to}")
    if [ ! -d "${parent_to}" ] && [ ! -d "${posix_to}" ]; then
      invalid+=("Target --to-folder parent directory does not exist: $(to_mixed_path "${TO_FOLDER}")")
    fi
  fi

  if [ -n "${WITH_7Z_PATH:-}" ]; then
    local posix_7z
    posix_7z=$(to_posix_path "${WITH_7Z_PATH}")
    if [ ! -e "${posix_7z}" ]; then
      invalid+=("Specified 7z path via --with-7z does not exist: $(to_mixed_path "${WITH_7Z_PATH}")")
    fi
  fi

  if [ ${#invalid[@]} -gt 0 ]; then
    log_error "Validation Failure - Directory or Path Error(s):"
    for err_item in "${invalid[@]}"; do
      log_error "  - ${err_item}"
    done
    exit 2
  fi
}

verify_specified_paths
verify_prerequisites "${TARGET_PLATFORM}"

# =============================================================================
#  WORKSPACE TEMP MANAGEMENT
# =============================================================================

EXEC_WORKSPACE=""
TEMP_WORKSPACE=""

function create_temp_workspace() {
  if [ -z "${EXEC_WORKSPACE}" ] || [ ! -d "${EXEC_WORKSPACE}" ]; then
    EXEC_WORKSPACE=$(create_temp_workdir "chromium_")
  fi
  TEMP_WORKSPACE="${EXEC_WORKSPACE}"
  log_info "Created workspace: $(to_mixed_path "${TEMP_WORKSPACE}")"
}

function terminate_running_chrome_processes() {
  log_info "Ensuring any active Chromium/Chrome processes are terminated..."
  if is_windows_platform; then
    taskkill.exe /F /IM chrome.exe /T &> /dev/null || true
    taskkill.exe /F /IM chromium.exe /T &> /dev/null || true
    taskkill.exe /F /IM chromedriver.exe /T &> /dev/null || true
  else
    killall -9 chrome chromium chromedriver &> /dev/null || true
    pkill -9 -x "chrome|chromium|chromedriver" &> /dev/null || true
  fi
  sleep 1
}

# =============================================================================
#  COMMON HELPER UTILITIES (DRY PRINCIPLE)
# =============================================================================

# -----------------------------------------------------------------------------
# Function: extract_version_from_string
# Objective: Extracts semantic version numbers (e.g. 150.0.7871.187 or 150.0.7871.186-1)
#            from filename strings or directory listings.
# Data Flow: String input -> regex extraction -> sanitized version string output.
# -----------------------------------------------------------------------------
function extract_version_from_string() {
  local str="$1"
  echo "${str}" | grep -oE 'chromium-[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+)?' | head -n 1 | sed 's/chromium-//' ||
    echo "${str}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+)?' | head -n 1 || echo ""
}

# -----------------------------------------------------------------------------
# Function: resolve_reference_version
# Objective: Inspects reference envelope archives (chromium-*-w64.zip for Windows,
#            chromium-*-lnx.zip for Linux) in the reference path to determine the
#            currently stored version.
# Data Flow: Reference path + Platform -> Archive locate -> 7z/tar listing -> Version string.
# -----------------------------------------------------------------------------
function resolve_reference_version() {
  local ref_path="$1"
  local platform="${2:-${TARGET_PLATFORM}}"
  local posix_ref
  posix_ref=$(to_posix_path "${ref_path}")

  [ ! -f "${posix_ref}" ] && [ ! -d "${posix_ref}" ] && echo "0.0.0.0" && return 0

  local target_file="${posix_ref}"
  if [ -d "${posix_ref}" ]; then
    if [ "${platform}" = "windows" ]; then
      target_file=$(find "${posix_ref}" -maxdepth 1 -type f \( -name "chromium-*-w64.zip" -o -name "chromium-*-w64.7z" \) | sort -V | tail -n 1 || true)
      [ -z "${target_file}" ] && target_file=$(find "${posix_ref}" -maxdepth 1 -type f \( -name "chromium-*.zip" -o -name "chromium-*.7z" \) | sort -V | tail -n 1 || true)
    else
      target_file=$(find "${posix_ref}" -maxdepth 1 -type f \( -name "chromium-*-lnx.zip" -o -name "chromium-*-lnx.tar.xz" \) | sort -V | tail -n 1 || true)
      [ -z "${target_file}" ] && target_file=$(find "${posix_ref}" -maxdepth 1 -type f \( -name "chromium-*.tar.xz" -o -name "chromium-*.zip" \) | sort -V | tail -n 1 || true)
    fi
  fi

  [ -z "${target_file}" ] || [ ! -f "${target_file}" ] && echo "0.0.0.0" && return 0

  log_info "Inspecting reference archive contents: $(to_mixed_path "${target_file}")"

  local listing=""
  if [[ "${target_file}" == *.tar.xz ]] || [[ "${target_file}" == *.tar.gz ]]; then
    listing=$(tar -tf "${target_file}" 2> /dev/null || true)
  elif [[ "${target_file}" == *.zip ]] && command -v unzip > /dev/null 2>&1; then
    listing=$(unzip -Z1 "${target_file}" 2> /dev/null || true)
  else
    listing=$(exec_7z l "${target_file}" 2> /dev/null || true)
  fi

  local base_name
  base_name=$(basename "${target_file}")

  local ver
  ver=$(extract_version_from_string "$(echo "${listing}" | grep -i "chromium-" | grep -v -F "${base_name}" || true)")
  [ -n "${ver}" ] && echo "${ver}" && return 0

  ver=$(extract_version_from_string "${base_name}")
  echo "${ver:-0.0.0.0}"
}

# Extracts <major>.<minor> (e.g. 158.0) from a full Chromium version string.
function _extract_major_minor() {
  local ver="$1"
  if [[ "${ver}" =~ ^([0-9]+\.[0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo "${ver%%-*}"
  fi
}

# Returns standard package suffix (w64 | lnx) for <platform>.
function _platform_suffix() {
  [ "$1" = "windows" ] && echo "w64" || echo "lnx"
}

# Returns canonical envelope zip name chromium-<major>.<minor>-<w64|lnx>.zip.
function _envelope_zip_name() {
  local platform="$1"
  local ver="$2"
  local major_minor
  major_minor=$(_extract_major_minor "${ver}")
  echo "chromium-${major_minor}-$(_platform_suffix "${platform}").zip"
}

# Resolves the writable release library directory from --release-path.
function _resolve_release_dir() {
  local ref_path="$1"
  local posix_ref
  posix_ref=$(to_posix_path "${ref_path}")
  posix_ref=$(strip_trailing_slashes "${posix_ref}")

  if [ -d "${posix_ref}" ]; then
    echo "${posix_ref}"
  elif [[ "${posix_ref,,}" == *.zip ]]; then
    dirname "${posix_ref}"
  elif [[ "${ref_path}" == */ || "${ref_path}" == *\\ ]] || [[ ! "${posix_ref,,}" =~ \.(7z|tar\.xz|tar\.gz|zip)$ ]]; then
    echo "${posix_ref}"
  fi
}

# Removes files in <dir> matching any of the trailing globs except <current_name>.
function _purge_glob_except() {
  local dir="$1"
  local label="$2"
  local current_name="$3"
  local dry_run="$4"
  shift 4

  [ -n "${dir}" ] && [ -d "${dir}" ] || return 0

  local pat f bname
  shopt -s nullglob
  for pat in "$@"; do
    for f in "${dir}"/${pat}; do
      bname=$(basename "${f}")
      [ "${bname}" != "${current_name}" ] || continue
      if [ "${dry_run}" = "true" ]; then
        log_info "[DRY-RUN] Would remove obsolete ${label}: ${bname}"
      else
        log_info "Removing obsolete ${label}: ${bname}"
        safe_rm_f "${f}"
      fi
    done
  done
  shopt -u nullglob
}

# Removes stale Chromium envelope archives in --release-path for <platform>.
function _purge_release_envelopes() {
  local ref_path="$1"
  local platform="$2"
  local current_zip="$3"
  local dry_run="$4"

  local release_dir
  release_dir=$(_resolve_release_dir "${ref_path}")
  [ -n "${release_dir}" ] && [ -d "${release_dir}" ] || return 0

  if [ "${platform}" = "windows" ]; then
    _purge_glob_except "${release_dir}" "release envelope" "${current_zip}" "${dry_run}" \
      "chromium-[0-9]*-w64.zip" "chromium-[0-9]*-w64.7z"
  else
    _purge_glob_except "${release_dir}" "release envelope" "${current_zip}" "${dry_run}" \
      "chromium-[0-9]*-lnx.zip" "chromium-[0-9]*-lnx.tar.xz"
  fi
}

# -----------------------------------------------------------------------------
# Function: is_newer_version
# Objective: Evaluates whether remote version string differs from local reference version.
# Data Flow: Remote version + Local version -> Boolean return status (0 = newer, 1 = same).
# -----------------------------------------------------------------------------
function is_newer_version() {
  local remote="$1"
  local local_v="$2"

  [ -z "${local_v}" ] || [ "${local_v}" = "0.0.0.0" ] && return 0
  [ "${remote}" != "${local_v}" ]
}

# -----------------------------------------------------------------------------
# Function: check_packaging_version_gate
# Objective: Evaluates reference version against remote version prior to packaging.
#            Returns status code 1 to skip up-to-date platform without terminating script.
# Data Flow: Reference path + Target platform + Remote version -> Gate status return.
# -----------------------------------------------------------------------------
function check_packaging_version_gate() {
  local ref_path="$1"
  local target_platform="$2"
  local remote_ver="$3"

  if [ "${FORCE}" = "true" ]; then
    log_info "--force flag specified. Bypassing reference version detection and systematically forcing packaging."
    return 0
  else
    local current_ver
    current_ver=$(resolve_reference_version "${ref_path}" "${target_platform}")
    log_info "Current reference release version: ${current_ver}"

    if ! is_newer_version "${remote_ver}" "${current_ver}"; then
      log_info "Local release is already up to date (${current_ver}). Skipping packaging for ${target_platform}."
      if [ "${UPDATE_SOURCE}" = "true" ]; then
        _purge_release_envelopes "${ref_path}" "${target_platform}" "$(_envelope_zip_name "${target_platform}" "${current_ver}")" "${DRY_RUN}"
      fi
      return 1
    fi
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Function: normalize_extracted_layout
# Objective: Normalizes disparate raw extracted package structures (Chrome-bin,
#            ungoogled-chromium-*, or nested subfolders) into a standardized
#            top-level directory named 'chromium'.
# Data Flow: Extracted workspace path -> layout detection -> copy to workspace/chromium.
# -----------------------------------------------------------------------------
function normalize_extracted_layout() {
  local posix_ws="$1"
  local chrome_bin="${posix_ws}/extracted/Chrome-bin"
  local target_chromium="${posix_ws}/chromium"

  mkdir -p "${target_chromium}"

  local src_dir=""
  if [ -d "${chrome_bin}" ]; then
    src_dir="${chrome_bin}"
  elif [ -d "${posix_ws}/extracted/chromium" ]; then
    src_dir="${posix_ws}/extracted/chromium"
  else
    local root_dir
    root_dir=$(find "${posix_ws}/extracted" -mindepth 1 -maxdepth 1 -type d | head -n 1 || true)
    while [ -n "${root_dir}" ]; do
      local sub_count
      sub_count=$(find "${root_dir}" -mindepth 1 -maxdepth 1 | wc -l || echo 0)
      local inner_dir
      inner_dir=$(find "${root_dir}" -mindepth 1 -maxdepth 1 -type d | head -n 1 || true)
      if [ "${sub_count}" -eq 1 ] && [ -n "${inner_dir}" ]; then
        root_dir="${inner_dir}"
      else
        break
      fi
    done
    src_dir="${root_dir:-${posix_ws}/extracted}"
  fi

  cp -af "${src_dir}/." "${target_chromium}/"
}

# -----------------------------------------------------------------------------
# Function: prune_locales
# Objective: Removes all non-English locale files from the target directory,
#            strictly preserving 'en-US*.pak' files.
# Data Flow: Target directory -> Locate locales folder -> File deletion filter.
# -----------------------------------------------------------------------------
function prune_locales() {
  local target_dir="$1"
  log_info "Pruning non-English locales in: $(to_mixed_path "${target_dir}")"

  local found_any="false"
  while IFS= read -r locales_dir; do
    [ -z "${locales_dir}" ] || [ ! -d "${locales_dir}" ] && continue
    found_any="true"
    log_info "Target locales directory: $(to_mixed_path "${locales_dir}")"
    local count_before
    count_before=$(find "${locales_dir}" -maxdepth 1 -type f | wc -l || echo 0)

    find "${locales_dir}" -maxdepth 1 -type f ! -iname "en-US*" -delete

    local count_after
    count_after=$(find "${locales_dir}" -maxdepth 1 -type f | wc -l || echo 0)
    log_info "Locale pruning complete for $(to_mixed_path "${locales_dir}"): files reduced from ${count_before} to ${count_after} (retained en-US*)."
  done < <(find "${target_dir}" -type d \( -iname "locales" -o -iname "Locales" \) || true)

  if [ "${found_any}" = "false" ]; then
    log_warn "No locales directory found under $(to_mixed_path "${target_dir}"). Skipping locale pruning."
  fi
}

# -----------------------------------------------------------------------------
# Function: fetch_github_release_asset
# Objective: Queries GitHub API for the latest release download URL and tag name,
#            falling back to HTML scraping if API rate-limited or unavailable.
# Data Flow: Repository name + Asset pattern + Fallback URL -> Download URL | Tag string.
# -----------------------------------------------------------------------------
function fetch_github_release_asset() {
  local repo_owner_name="$1"
  local asset_pattern="$2"
  local fallback_page_url="$3"

  local api_url="https://api.github.com/repos/${repo_owner_name}/releases/latest"
  local release_json=""
  release_json=$(fetch_text "${api_url}" 30 false "chromium-updater" "${GITHUB_TOKEN:-}" "application/vnd.github+json" 2> /dev/null || true)

  local dl_url=""
  local tag=""
  if [ -n "${release_json}" ] && grep -q "browser_download_url" <<< "${release_json}"; then
    dl_url=$(echo "${release_json}" | grep -oE "https://[^\"]+${asset_pattern}" | head -n 1 || true)
    tag=$(echo "${release_json}" | grep -oE '"tag_name": *"[^\"]+"' | cut -d'"' -f4 || true)
  fi

  if [ -z "${dl_url}" ] && [ -n "${fallback_page_url}" ]; then
    log_warn "GitHub API check did not return direct asset. Scraping release page..."
    local page_html
    local allow_file=false
    [[ "${fallback_page_url}" == file://* ]] && allow_file=true
    page_html=$(fetch_text "${fallback_page_url}" 30 "${allow_file}" 2> /dev/null || true)
    dl_url=$(echo "${page_html}" | grep -oE "href=\"[^\"]+${asset_pattern}\"" | head -n 1 | sed 's/href="//;s/"//' || true)
    if [[ "${dl_url}" == /* ]]; then dl_url="https://github.com${dl_url}"; fi
    tag=$(echo "${dl_url}" | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(-r[0-9]+|-1)?' || true)
  fi

  echo "${dl_url}|${tag}"
}

# -----------------------------------------------------------------------------
# Function: finalize_package_archive
# Objective: Atomically publishes the inner payload (.7z / .tar.xz) to --archive-path,
#            purges obsolete inner payloads there, and (unless --no-update-source)
#            wraps it in chromium-<major>.<minor>-<w64|lnx>.zip in --release-path.
# Data Flow: Inner archive + Staging dirs + Platform/Ver -> Atomic stage & purge.
# -----------------------------------------------------------------------------
function finalize_package_archive() {
  local output_archive="$1"
  local arch_path="$2"
  local ref_path="$3"
  local platform="$4"
  local remote_ver="$5"

  local posix_arch_dir pkg_filename
  posix_arch_dir=$(to_posix_path "${arch_path}")
  posix_arch_dir=$(strip_trailing_slashes "${posix_arch_dir}")
  pkg_filename=$(basename "${output_archive}")

  local plat_suffix outer_zip_name release_dir=""
  plat_suffix=$(_platform_suffix "${platform}")
  outer_zip_name=$(_envelope_zip_name "${platform}" "${remote_ver}")
  release_dir=$(_resolve_release_dir "${ref_path}")

  local -a inner_purge_globs
  if [ "${platform}" = "windows" ]; then
    inner_purge_globs=("chromium-[0-9]*-x64.7z")
  else
    inner_purge_globs=("chromium-[0-9]*-ungoogled-x86_64_linux.tar.xz" "chromium-[0-9]*-x86_64_linux.tar.xz")
  fi

  if [ "${DRY_RUN}" = "true" ]; then
    log_info "[DRY-RUN] Would stage inner archive to --archive-path: $(to_mixed_path "${arch_path}")/${pkg_filename}"
    _purge_glob_except "${posix_arch_dir}" "staged archive" "${pkg_filename}" "true" "${inner_purge_globs[@]}"
    if [ "${UPDATE_SOURCE}" = "true" ] && [ -n "${release_dir}" ]; then
      log_info "[DRY-RUN] Would wrap ${pkg_filename} into ${outer_zip_name}"
      log_info "[DRY-RUN] Would publish release envelope to --release-path: $(to_mixed_path "${release_dir}")/${outer_zip_name}"
      _purge_release_envelopes "${ref_path}" "${platform}" "${outer_zip_name}" "true"
    elif [ "${UPDATE_SOURCE}" != "true" ]; then
      log_info "[DRY-RUN] --no-update-source set; would leave --release-path unchanged."
    fi
    return 0
  fi

  local posix_ws envelope_stage outer_zip_path=""
  posix_ws=$(to_posix_path "${TEMP_WORKSPACE}")
  if [ "${UPDATE_SOURCE}" = "true" ] && [ -n "${release_dir}" ]; then
    envelope_stage="${posix_ws}/envelope_${plat_suffix}"
    safe_rm_rf "${envelope_stage}"
    mkdir -p "${envelope_stage}" || exit 6
    if ! cp -f -- "${output_archive}" "${envelope_stage}/${pkg_filename}"; then
      log_error "Failed copying inner archive for envelope zip: ${pkg_filename}"
      exit 6
    fi
    chmod 644 "${envelope_stage}/${pkg_filename}" 2> /dev/null || true
    outer_zip_path="${posix_ws}/${outer_zip_name}"
    log_info "Creating normalized release envelope: ${outer_zip_name}..."
    if ! repack_directory_to_zip "${envelope_stage}" "${outer_zip_path}"; then
      safe_rm_rf "${envelope_stage}"
      exit 6
    fi
    safe_rm_rf "${envelope_stage}"
  fi

  if ! atomic_publish_file "${output_archive}" "${posix_arch_dir}/${pkg_filename}" "archive" true; then
    exit 6
  fi
  log_info "Inner archive staged to --archive-path:"
  log_info "  -> $(to_mixed_path "${posix_arch_dir}/${pkg_filename}")"
  _purge_glob_except "${posix_arch_dir}" "staged archive" "${pkg_filename}" "false" "${inner_purge_globs[@]}"

  if [ "${UPDATE_SOURCE}" = "true" ]; then
    if [ -z "${release_dir}" ]; then
      log_warn "Skipping --release-path update; target is not a directory or .zip envelope: $(to_mixed_path "${ref_path}")"
    else
      if ! atomic_publish_file "${outer_zip_path}" "${release_dir}/${outer_zip_name}" "release envelope" true; then
        exit 6
      fi
      log_info "Release envelope published to --release-path:"
      log_info "  -> $(to_mixed_path "${release_dir}/${outer_zip_name}")"
      _purge_release_envelopes "${ref_path}" "${platform}" "${outer_zip_name}" "false"
    fi
  else
    log_info "--no-update-source set; leaving --release-path unchanged."
  fi
}

# -----------------------------------------------------------------------------
# Function: extract_package_archive
# Objective: Unpacks source archive formats (.7z, .zip, .tar.xz, .tar.gz) into
#            the specified extraction directory.
# Data Flow: Archive path + Target extraction dir -> Archive extraction tool invocation.
# -----------------------------------------------------------------------------
function extract_package_archive() {
  local archive_path="$1"
  local target_dir="$2"

  local posix_archive posix_target
  posix_archive=$(to_posix_path "${archive_path}")
  posix_target=$(to_posix_path "${target_dir}")

  mkdir -p "${posix_target}"

  if [[ "${posix_archive}" == *.7z ]] || [[ "${posix_archive}" == *.zip ]]; then
    if exec_7z x -y "-o${posix_target}" "${posix_archive}" > /dev/null 2>&1; then
      return 0
    elif [[ "${posix_archive}" == *.zip ]] && command -v unzip &> /dev/null; then
      unzip -oq "${posix_archive}" -d "${posix_target}" > /dev/null
    else
      log_error "Extraction of deployment archive failed."
      exit 5
    fi
  elif [[ "${posix_archive}" == *.tar.xz ]] || [[ "${posix_archive}" == *.tar.gz ]]; then
    if is_windows_platform && exec_7z x -y "-o${posix_target}" "${posix_archive}" > /dev/null 2>&1; then
      local expected_tar intermediate_tar=""
      expected_tar="${posix_target}/$(basename "${posix_archive%.*}")"
      if [ -f "${expected_tar}" ]; then
        intermediate_tar="${expected_tar}"
      else
        intermediate_tar=$(find "${posix_target}" -maxdepth 1 -type f -name "*.tar" | head -n 1 || true)
      fi
      if [ -n "${intermediate_tar}" ] && [ -f "${intermediate_tar}" ]; then
        if ! exec_7z x -y "-o${posix_target}" "${intermediate_tar}" > /dev/null; then
          log_error "Extraction of tar archive failed."
          exit 5
        fi
        rm -f "${intermediate_tar}"
      fi
    elif ! extract_archive "${posix_archive}" "${posix_target}"; then
      log_error "Extraction of tar archive failed."
      exit 5
    fi
  else
    if [ "${TARGET_PLATFORM}" = "windows" ]; then
      exec_7z x -y "-o${posix_target}" "${posix_archive}" > /dev/null
    else
      extract_archive "${posix_archive}" "${posix_target}"
    fi
  fi
}

# =============================================================================
#  ACTION: PACKAGE
# =============================================================================

# Pure-POSIX helper shared by native Linux and WSL Linux packaging:
# normalizes extracted tree to chromium/, prunes locales, sets permissions, and packs .tar.xz.
function _linux_build_chromium_tar_xz() {
  local ws_dir="$1"
  local pkg_filename="$2"
  local log_prefix="${3:-[LNX]}"

  normalize_extracted_layout "${ws_dir}"

  echo "${log_prefix} Pruning non-English locales..."
  local loc_dir
  while IFS= read -r loc_dir; do
    [ -z "${loc_dir}" ] || [ ! -d "${loc_dir}" ] && continue
    find "${loc_dir}" -maxdepth 1 -type f ! -iname "en-US*" -delete
  done < <(find "${ws_dir}/chromium" -type d \( -iname "locales" -o -iname "Locales" \) || true)

  echo "${log_prefix} Enforcing POSIX executable attributes and permissions on Linux binaries..."
  chmod 755 "${ws_dir}/chromium" 2> /dev/null || true
  find "${ws_dir}/chromium" -type d -exec chmod 755 {} + 2> /dev/null || true
  find "${ws_dir}/chromium" -type f -exec chmod 644 {} + 2> /dev/null || true

  local bin
  for bin in chrome chromium chrome_crashpad_handler chrome-sandbox nacl_helper nacl_helper_bootstrap; do
    [ -f "${ws_dir}/chromium/${bin}" ] && chmod 755 "${ws_dir}/chromium/${bin}"
  done
  find "${ws_dir}/chromium" -type f -name "*.so*" -exec chmod 755 {} + 2> /dev/null || true

  echo "${log_prefix} Repacking package with tar.xz maximum compression: ${pkg_filename}..."
  if ! XZ_OPT="-9 -T0" tar -cJf "${ws_dir}/${pkg_filename}" -C "${ws_dir}" chromium; then
    echo "${log_prefix} [ERROR] Failed to compress tar.xz package." >&2
    return 6
  fi
}

# Builds the Windows inner 7z payload in <posix_ws>/<pkg_filename>.
function _build_windows_inner_7z() {
  local download_url="$1"
  local posix_ws="$2"
  local pkg_filename="$3"

  log_info "Downloading chrome.7z..."
  local allow_file=false
  [[ "${download_url}" == file://* ]] && allow_file=true
  if ! download_asset "${download_url}" "${posix_ws}/chrome.7z" "" "sha256" "${allow_file}"; then
    log_error "Failed to download chrome.7z from ${download_url}"
    exit 4
  fi

  log_info "Extracting chrome.7z..."
  if ! exec_7z x -y "-o${posix_ws}/extracted" "${posix_ws}/chrome.7z" > /dev/null; then
    log_error "Extraction of chrome.7z failed."
    exit 5
  fi

  normalize_extracted_layout "${posix_ws}"
  prune_locales "${posix_ws}/chromium"

  local output_archive="${posix_ws}/${pkg_filename}"
  log_info "Repacking package with 7z maximum compression: ${pkg_filename}..."
  if ! exec_7z a -t7z -m0=lzma2 -mx=9 "${output_archive}" "${posix_ws}/chromium" > /dev/null; then
    log_error "Failed to create 7z compressed package archive."
    exit 6
  fi
}

# Executes the Linux packaging pipeline within WSL to preserve POSIX permissions.
function do_package_linux_wsl() {
  local download_url="$1"
  local stage_dir="$2"
  local pkg_filename="$3"

  local wsl_bin="${RESOLVED_WSL_BIN:-wsl.exe}"
  if ! "${wsl_bin}" -e true 2> /dev/null; then
    log_error "WSL is installed but failed to execute. Ensure a default WSL distribution is installed and running."
    exit 3
  fi

  local wsl_stage_dest fn_defs wsl_script
  wsl_stage_dest=$(to_wsl_path "${stage_dir}" || true)
  fn_defs=$(declare -f normalize_extracted_layout _linux_build_chromium_tar_xz)

  log_info "Delegating Linux packaging to WSL to preserve POSIX executable attributes..."
  log_info "WSL Staging Destination: ${wsl_stage_dest}"
  log_info "Target Package: ${pkg_filename}"

  # shellcheck disable=SC2016
  wsl_script="${fn_defs}"$'\n''
set -euo pipefail

DOWNLOAD_URL="$1"
WSL_DEST_DIR="$2"
PKG_FILENAME="$3"

WSL_WS="$(mktemp -d /tmp/chromium-linux-pkg-XXXXXX)"
trap '\''rm -rf "${WSL_WS}"'\'' EXIT INT TERM

echo "[WSL] Created isolated Linux workspace: ${WSL_WS}"
echo "[WSL] Downloading Linux release archive from ${DOWNLOAD_URL}..."
if ! curl -f -s -S -L "${DOWNLOAD_URL}" -o "${WSL_WS}/chromium.tar.xz"; then
  echo "[WSL ERROR] Failed to download Linux release archive." >&2
  exit 4
fi

echo "[WSL] Extracting Linux release archive with native Linux tar..."
mkdir -p "${WSL_WS}/extracted"
if ! tar --warning=no-unknown-keyword -xf "${WSL_WS}/chromium.tar.xz" -C "${WSL_WS}/extracted"; then
  echo "[WSL ERROR] Extraction failed." >&2
  exit 5
fi

_linux_build_chromium_tar_xz "${WSL_WS}" "${PKG_FILENAME}" "[WSL]" || exit $?

echo "[WSL] Moving finalized archive to host workspace staging: ${WSL_DEST_DIR}..."
mkdir -p "${WSL_DEST_DIR}"
cp -f "${WSL_WS}/${PKG_FILENAME}" "${WSL_DEST_DIR}/${PKG_FILENAME}"

echo "[WSL] Linux package build and attribute preservation completed successfully."
'

  if ! "${wsl_bin}" -e bash -c "${wsl_script}" -- "${download_url}" "${wsl_stage_dest}" "${pkg_filename}"; then
    log_error "Linux packaging in WSL failed."
    exit 6
  fi

  log_info "Linux package built via WSL in workspace: $(to_mixed_path "${stage_dir}/${pkg_filename}")"
}

# Builds the Linux inner .tar.xz payload in <posix_ws>/<pkg_filename>.
function _build_linux_inner_tar_xz() {
  local download_url="$1"
  local posix_ws="$2"
  local pkg_filename="$3"

  if is_windows_platform; then
    do_package_linux_wsl "${download_url}" "${posix_ws}" "${pkg_filename}"
    return 0
  fi

  log_info "Downloading Linux tar.xz archive..."
  local allow_file=false
  [[ "${download_url}" == file://* ]] && allow_file=true
  if ! download_asset "${download_url}" "${posix_ws}/chromium.tar.xz" "" "sha256" "${allow_file}"; then
    log_error "Failed to download tar.xz from ${download_url}"
    exit 4
  fi

  log_info "Extracting archive..."
  extract_package_archive "${posix_ws}/chromium.tar.xz" "${posix_ws}/extracted"

  if ! _linux_build_chromium_tar_xz "${posix_ws}" "${pkg_filename}" "[INFO]"; then
    exit 6
  fi
}

# Shared packaging orchestrator across Windows and Linux targets.
function _run_package_platform() {
  local platform="$1"
  local url="$2"
  local gh_repo="$3"
  local asset_regex="$4"
  local ref_path="${RELEASE_PATH:-${DEFAULT_RELEASE_PATH}}"
  local arch_path="${ARCHIVE_PATH:-${DEFAULT_ARCHIVE_PATH}}"

  log_info "Executing ${platform^} packaging workflow..."
  log_info "Source URL: ${url}"
  log_info "Reference Path: $(to_mixed_path "${ref_path}")"
  log_info "Target Archive Directory: $(to_mixed_path "${arch_path}")"
  log_info "Update Release Path: ${UPDATE_SOURCE}"
  log_info "Dry Run: ${DRY_RUN}"

  log_info "Inspecting remote release details from ${url}..."
  local release_meta download_url tag_name
  release_meta=$(fetch_github_release_asset "${gh_repo}" "${asset_regex}" "${url}")
  download_url="${release_meta%%|*}"
  tag_name="${release_meta#*|}"

  if [ -z "${download_url}" ]; then
    log_error "Failed to locate ${platform} release download URL from ${url}"
    exit 4
  fi

  local remote_ver pkg_filename
  remote_ver=$(extract_version_from_string "${tag_name:-${download_url}}")
  if [ "${platform}" = "windows" ]; then
    local build_num
    build_num=$(echo "${tag_name:-${download_url}}" | grep -oE 'r[0-9]+' | sed 's/r//' || echo "")
    [ -z "${build_num}" ] && build_num="1639810"
    log_info "Latest remote version detected: ${remote_ver} (Build: ${build_num})"
    pkg_filename="chromium-${remote_ver}_${build_num}-x64.7z"
  else
    log_info "Latest remote version detected: ${remote_ver}"
    pkg_filename="chromium-${remote_ver}-ungoogled-x86_64_linux.tar.xz"
  fi
  log_info "Download URL: ${download_url}"

  if ! check_packaging_version_gate "${ref_path}" "${platform}" "${remote_ver}"; then
    return 0
  fi

  if [ "${DRY_RUN}" = "true" ]; then
    log_info "[DRY-RUN] Would download: ${download_url}"
    log_info "[DRY-RUN] Would normalize layout, prune locales (keep en-US*), and repack ${pkg_filename}"
    finalize_package_archive "${pkg_filename}" "${arch_path}" "${ref_path}" "${platform}" "${remote_ver}"
    return 0
  fi

  create_temp_workspace
  local posix_ws
  posix_ws=$(to_posix_path "${TEMP_WORKSPACE}")

  if [ "${platform}" = "windows" ]; then
    _build_windows_inner_7z "${download_url}" "${posix_ws}" "${pkg_filename}"
  else
    _build_linux_inner_tar_xz "${download_url}" "${posix_ws}" "${pkg_filename}"
  fi
  finalize_package_archive "${posix_ws}/${pkg_filename}" "${arch_path}" "${ref_path}" "${platform}" "${remote_ver}"
}

function do_package_windows() {
  _run_package_platform "windows" "${FROM_URL:-${DEFAULT_WIN_FROM_URL}}" "Hibbiki/chromium-win64" "chrome\.7z"
}

function do_package_linux() {
  _run_package_platform "linux" "${FROM_URL:-${DEFAULT_LNX_FROM_URL}}" "ungoogled-software/ungoogled-chromium-portablelinux" "x86_64_linux\.tar\.xz"
}

# =============================================================================
#  ACTION: DEPLOY
# =============================================================================

# -----------------------------------------------------------------------------
# Function: do_deploy
# Objective: Orchestrates deployment of packaged Chromium archives to --to-folder.
#            Unpacks archive into temporary staging (posix_ws/deploy_payload),
#            executes process termination (terminate_running_chrome_processes),
#            and updates target destination via atomic swap or CWD-locked fallback.
# Data Flow: Package source (--from-folder/--from-url) -> Staging extraction -> Process termination -> Target folder swap/update -> Version verification.
# -----------------------------------------------------------------------------
function do_deploy() {
  if [ -z "${TO_FOLDER}" ]; then
    log_error "--to-folder parameter is mandatory for deployment."
    exit 2
  fi

  local posix_target
  posix_target=$(to_posix_path "${TO_FOLDER}")
  posix_target="${posix_target%/}"
  log_info "Executing deployment to target folder: $(to_mixed_path "${posix_target}")"

  local archive_file="" posix_ws=""

  if [ -n "${FROM_URL}" ]; then
    local raw_name
    raw_name=$(basename "${FROM_URL%%#*}" | cut -d? -f1)
    if [ "${DRY_RUN}" = "true" ]; then
      archive_file="${raw_name:-downloaded_package}"
    else
      create_temp_workspace
      posix_ws=$(to_posix_path "${TEMP_WORKSPACE}")
      archive_file="${posix_ws}/${raw_name:-downloaded_package}"
      log_info "Downloading package from URL: ${FROM_URL}"
      local allow_file=false
      [[ "${FROM_URL}" == file://* ]] && allow_file=true
      if ! download_asset "${FROM_URL}" "${archive_file}" "" "sha256" "${allow_file}"; then
        log_error "Failed to download deployment package from ${FROM_URL}"
        exit 4
      fi
    fi
  elif [ -n "${FROM_FOLDER}" ]; then
    local posix_src
    posix_src=$(to_posix_path "${FROM_FOLDER}")
    if [ -f "${posix_src}" ]; then
      archive_file="${posix_src}"
    elif [ -d "${posix_src}" ]; then
      log_info "Locating packaged archive for platform '${TARGET_PLATFORM}' in folder: $(to_mixed_path "${FROM_FOLDER}")"
      if [ "${TARGET_PLATFORM}" = "windows" ]; then
        archive_file=$(find "${posix_src}" -maxdepth 1 -type f \( -name "chromium-*-x64.7z" -o -name "chromium-*-w64.zip" \) | sort -V | tail -n 1 || true)
      else
        archive_file=$(find "${posix_src}" -maxdepth 1 -type f \( -name "chromium-*-ungoogled-x86_64_linux.tar.xz" -o -name "chromium-*-x86_64_linux.tar.xz" -o -name "chromium-*-lnx.zip" \) | sort -V | tail -n 1 || true)
      fi

      if [ -z "${archive_file}" ]; then
        log_error "No valid ${TARGET_PLATFORM} chromium package found in folder: $(to_mixed_path "${FROM_FOLDER}")"
        exit 5
      fi
    else
      log_error "Specified --from-folder does not exist: $(to_mixed_path "${FROM_FOLDER}")"
      exit 2
    fi
    if [ "${DRY_RUN}" != "true" ]; then
      create_temp_workspace
      posix_ws=$(to_posix_path "${TEMP_WORKSPACE}")
    fi
  else
    log_error "Deployment requires either --from-folder or --from-url."
    exit 2
  fi

  # Validate against cross-platform deployment & invalid archive naming
  local archive_base
  archive_base=$(basename "${archive_file}" | tr '[:upper:]' '[:lower:]')

  if [ "${TARGET_PLATFORM}" = "windows" ]; then
    if [[ "${archive_base}" == *"linux"* || "${archive_base}" == *"ungoogled"* || "${archive_base}" == *".tar.xz"* ]]; then
      log_error "Cross-platform deployment prohibited: Cannot install Linux package '$(basename "${archive_file}")' on Windows environment."
      exit 2
    fi
  elif [ "${TARGET_PLATFORM}" = "linux" ]; then
    if [[ "${archive_base}" == *"win"* || "${archive_base}" == *"x64"* || "${archive_base}" == *".7z"* ]]; then
      log_error "Cross-platform deployment prohibited: Cannot install Windows package '$(basename "${archive_file}")' on Linux environment."
      exit 2
    fi
  fi

  if [ "${DRY_RUN}" = "true" ]; then
    local dry_src="${FROM_URL:-${archive_file}}"
    log_info "[DRY-RUN] Would deploy ${dry_src} to $(to_mixed_path "${posix_target}")"
    if [ "${PURGE}" = "true" ] && [ -z "${FROM_URL}" ] && [ -n "${archive_file}" ] && [ -f "${archive_file}" ]; then
      log_info "[DRY-RUN] Would purge source archive: $(to_mixed_path "${archive_file}")"
    fi
    return 0
  fi

  local extract_stage="${posix_ws}/deploy_stage"
  log_info "Deploying package archive: $(to_mixed_path "${archive_file}")"
  extract_package_archive "${archive_file}" "${extract_stage}"

  local target_tmp="${posix_ws}/deploy_payload"
  mkdir -p "${target_tmp}"

  local src_dir="${extract_stage}/chromium"
  if [ ! -d "${src_dir}" ]; then
    local root_dir
    root_dir=$(find "${extract_stage}" -mindepth 1 -maxdepth 1 -type d | head -n 1 || true)
    src_dir="${root_dir:-${extract_stage}}"
  fi

  local item_count
  item_count=$(find "${src_dir}" -mindepth 1 -maxdepth 1 | wc -l || echo 0)
  log_info "Stripping top-level container directory and copying ${item_count} item(s) to temporary staging..."

  if ! cp -af "${src_dir}/." "${target_tmp}/"; then
    log_error "Failed to copy deployed contents to temporary staging: $(to_mixed_path "${target_tmp}")"
    exit 7
  fi

  # Fail-safe locale pruning on temporary staging directory
  # Ensure active processes holding locks are terminated before replacing target directory
  terminate_running_chrome_processes

  log_info "Staging verified. Deploying release to target destination..."
  mkdir -p "${posix_target}"

  # Attempt clean directory swap; if target root container directory itself is CWD-locked by an open shell/service, fallback to wiping contents inside target
  if rm -rf "${posix_target}" 2> /dev/null && mv -f "${target_tmp}" "${posix_target}" 2> /dev/null; then
    log_info "Promoted staged release to target destination."
  else
    log_info "Target folder root locked by active handle/CWD. Wiping destination contents and updating in-place..."
    mkdir -p "${posix_target}"
    find "${posix_target}" -mindepth 1 -delete 2> /dev/null || true
    if ! cp -af "${target_tmp}/." "${posix_target}/"; then
      log_error "Failed to deploy release contents to target destination: $(to_mixed_path "${TO_FOLDER}")"
      exit 7
    fi
  fi

  log_info "Deployment extraction complete. Verifying installed Chromium version..."
  display_deployed_version "${posix_target}"

  if [ "${PURGE}" = "true" ]; then
    log_info "--purge flag specified: Purging deployed archive file..."
    if [ -f "${archive_file}" ]; then
      log_info "  -> Purging archive: $(to_mixed_path "${archive_file}")"
      rm -f "${archive_file}"
    else
      log_warn "Archive file not found or already removed: $(to_mixed_path "${archive_file}")"
    fi
  fi
}

# -----------------------------------------------------------------------------
# Function: display_deployed_version
# Objective: Queries and logs the installed Chromium product version from the target folder.
#            Uses PowerShell Get-Item -LiteralPath on Windows and binary --version on Linux.
# Data Flow: Target directory -> Locate executable -> Query product version -> Log output.
# -----------------------------------------------------------------------------
function display_deployed_version() {
  local target_dir="$1"
  local version_str=""

  if [ "${TARGET_PLATFORM}" = "windows" ]; then
    local exe_path
    exe_path=$(find "${target_dir}" -type f -iname "chrome.exe" | head -n 1 || true)
    if [ -n "${exe_path}" ]; then
      local win_exe
      win_exe=$(to_mixed_path "${exe_path}")
      local ps_win_exe="${win_exe//\'/\'\'}"
      version_str=$(powershell.exe -NoProfile -Command "(Get-Item -LiteralPath '${ps_win_exe}').VersionInfo.ProductVersion" 2> /dev/null | tr -d '\r' || true)
    fi
  else
    local bin_path
    bin_path=$(find "${target_dir}" -type f \( -name "chrome" -o -name "chromium" \) | head -n 1 || true)
    if [ -n "${bin_path}" ] && [ -x "${bin_path}" ]; then
      version_str=$("${bin_path}" --version 2> /dev/null || true)
    fi
  fi

  if [ -n "${version_str}" ]; then
    echo "-----------------------------------------------------------------------------"
    log_info "Chromium Version Verification: ${version_str}"
    echo "-----------------------------------------------------------------------------"
  else
    log_warn "Could not resolve version info from deployed directory $(to_mixed_path "${target_dir}")"
  fi
}

# =============================================================================
#  MAIN ROUTER
# =============================================================================

case "${ACTION}" in
  package)
    case "${TARGET_PLATFORM}" in
      windows)
        log_info "============================================================================="
        log_info " Executing Windows Packaging Workflow..."
        log_info "============================================================================="
        do_package_windows
        ;;
      linux)
        log_info "============================================================================="
        log_info " Executing Linux Packaging Workflow..."
        log_info "============================================================================="
        do_package_linux
        ;;
      windows,linux)
        log_info "============================================================================="
        log_info " Executing Windows Packaging Workflow..."
        log_info "============================================================================="
        do_package_windows

        log_info "============================================================================="
        log_info " Executing Linux Packaging Workflow..."
        log_info "============================================================================="
        do_package_linux
        ;;
    esac
    ;;
  deploy)
    do_deploy
    ;;
  *)
    log_error "Unknown action '${ACTION}'."
    exit 2
    ;;
esac

log_info "Operation completed successfully."
exit 0
