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
#    bun_upgrade.sh [--detect] [--update] [--auto] [--clear-cache]
#                   [--trust-all] [--list] [--update-modules] [--install] [--path <path>]
#                   [--install-module <module>] [--remove-module <module>]
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
#  LOGGING UTILITIES
# =============================================================================

# -----------------------------------------------------------------------------
#  Function: log_info
#  Description: Logs a standard informational message to stdout.
#  Arguments:
#    $1 - Message string to display.
# -----------------------------------------------------------------------------
function log_info() {
  echo "[INFO] $1"
}

# -----------------------------------------------------------------------------
#  Function: log_error
#  Description: Logs an error message to stderr.
#  Arguments:
#    $1 - Error message string to display.
# -----------------------------------------------------------------------------
function log_error() {
  echo "[ERROR] $1" >&2
}

# =============================================================================
#  PLATFORM INITIALIZATION
# =============================================================================

# Cache Windows platform detection status
IS_WINDOWS="false"
command -v cygpath &> /dev/null && IS_WINDOWS="true"

# Resolve POSIX equivalent of the user's home/profile directory
USER_HOME=""
if [ "${IS_WINDOWS}" = "true" ] && [ -n "${USERPROFILE:-}" ]; then
  # Translate Windows user profile path (C:\Users\...) to Cygwin/MSYS POSIX path
  USER_HOME=$(cygpath -u "${USERPROFILE}" 2> /dev/null)
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
#  Function: get_temp_dir
#  Description: Resolves a unique temporary directory path.
#               Prioritizes TMPDIR, TMP, and TEMP environment variables.
#  Outputs:
#    Prints the resolved directory path to stdout.
# -----------------------------------------------------------------------------
function get_temp_dir() {
  local base_temp=""

  if [ -n "${TMPDIR:-}" ]; then
    base_temp="${TMPDIR}"
  elif [ -n "${TMP:-}" ]; then
    base_temp="${TMP}"
  elif [ -n "${TEMP:-}" ]; then
    base_temp="${TEMP}"
  fi

  if [ -n "${base_temp}" ] && [ "${IS_WINDOWS}" = "true" ]; then
    base_temp=$(cygpath -u "${base_temp}" 2> /dev/null)
  fi

  if [ -z "${base_temp}" ] || [ ! -d "${base_temp}" ] || [ ! -w "${base_temp}" ]; then
    base_temp="/tmp"
  fi
  if [ ! -d "${base_temp}" ] || [ ! -w "${base_temp}" ]; then
    base_temp=$(get_bun_home)
  fi

  echo "${base_temp}/bun_tmp_$$"
}

# -----------------------------------------------------------------------------
#  Function: fetch_latest_version
#  Description: Fetches the latest available Bun version tag from GitHub releases.
#  Outputs:
#    Prints the version number (e.g. 1.3.14) to stdout if successful.
# -----------------------------------------------------------------------------
function fetch_latest_version() {
  curl -sI "${BUN_BASE_URL}" 2> /dev/null | grep -i '^Location:' | sed -E "s/.*tag\/${BUN_REPO}-v//I" | tr -d '\r'
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

while [ $# -gt 0 ]; do
  case "$1" in
    --detect) DO_DETECT="true" && shift ;;
    --update) DO_UPDATE="true" && shift ;;
    --auto) DO_AUTO="true" && shift ;;
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
  [ "${DO_CLEAR_CACHE}" = "false" ] && [ "${DO_TRUST_ALL}" = "false" ] &&
  [ "${DO_LIST}" = "false" ] && [ "${DO_UPDATE_MODULES}" = "false" ] &&
  [ "${DO_INSTALL}" = "false" ] && [ "${DO_INSTALL_MODULE}" = "false" ] &&
  [ "${DO_REMOVE_MODULE}" = "false" ]; then
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

    mixed_path="${bun_path}"
    [ "${IS_WINDOWS}" = "true" ] && mixed_path=$(cygpath -m "${bun_path}" 2> /dev/null)

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
  for cmd in curl unzip; do
    if ! command -v "$cmd" &> /dev/null; then
      log_error "Prerequisite '$cmd' is not installed or not in PATH."
      exit 3
    fi
  done

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
  if [ "${IS_WINDOWS}" = "true" ]; then
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
  mixed_home="${bun_home}"
  [ "${IS_WINDOWS}" = "true" ] && mixed_home=$(cygpath -m "${bun_home}" 2> /dev/null)

  log_info "Target Directory: ${mixed_home}"
  mkdir -p "${bun_home}"
  zip_file="${bun_home}/${BUN_ZIP_NAME}"

  # Retrieve release package
  log_info "Downloading Bun..."
  curl -sSL "${BUN_DOWNLOAD_URL}/${zip_name}" -o "${zip_file}"
  if [ ! -f "${zip_file}" ] || [ ! -s "${zip_file}" ]; then
    log_error "Failed to download Bun package."
    exit 4
  fi

  # Terminate processes to unlock files
  log_info "Terminating active bun processes..."
  if [ "${IS_WINDOWS}" = "true" ]; then
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
    if [ "${IS_WINDOWS}" = "true" ] && [ -f "${bun_home}/${BUN_REPO}.exe" ]; then
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
  # We execute all client operations inside a temporary workspace with a dummy package.json.
  (
    temp_dir=$(get_temp_dir)
    mkdir -p "${temp_dir}"
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
    rm -rf "${temp_dir}"
  ) || exit 7
fi

log_info "Done."
exit 0
