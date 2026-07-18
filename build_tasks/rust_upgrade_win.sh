#!/bin/bash
# -----------------------------------------------------------------------------
#  /usr/src/redhat/SPECS/rust_upgrade_win.sh
#  v1.0.1xg  2026/07/11  XDG / MIS Center
# -----------------------------------------------------------------------------
#  Purpose:
#    Automates Rust toolchain downloading, building, and deploying on Windows
#    under Cygwin/MSYS2. Supports building custom unified packages with compiled
#    linters/cargo tools in user-space (no admin rights) and deploying them.
#
#  Syntax:
#    rust_upgrade_win.sh [--build] [--deploy] [--version <version> | --auto]
#                        [--cc <path>] [--path-update <mode>] [--target-dir <path>]
#                        [--build-dir <path>] [--archive-path <path>] [--force]
#                        [--core-components] [--log [file]] [--help]
#    rust_upgrade_win.sh --detect [text|json]
# -----------------------------------------------------------------------------

# ----- ENVIRONMENT AND INITIALIZATION -----
set -e # Exit immediately if a command exits with a non-zero status
set -u # Treat unset variables as an error

# Detect Cygwin or MSYS2 environment
OS_ENV="UNKNOWN"
if [[ "$(uname -s)" == *"CYGWIN"* ]]; then
  OS_ENV="CYGWIN"
elif [[ "$(uname -s)" == *"MSYS"* || "$(uname -s)" == *"MINGW"* ]]; then
  OS_ENV="MSYS"
fi

if [ "${OS_ENV}" == "UNKNOWN" ]; then
  echo -e "\n*** ERROR09: Unsupported environment. This script must be run inside Cygwin or MSYS2."
  exit 9
fi

# Ensure official Cygwin/MSYS2 bin directory has highest priority in PATH
# to avoid Microsoft/Windows bundled tools taking precedence.
export PATH="/usr/bin:/bin:${PATH}"

# -----------------------------------------------------------------------------
# Path Conversion Utilities
# Purpose:  Bridge native Windows executables and POSIX (Cygwin/MSYS2) bash environment.
#
#   to_win_path:   Converts a POSIX path to standard Windows format (backslash).
#   to_unix_path:  Converts a Windows path to POSIX format (forward slash, /cygdrive).
#   to_mixed_path: Converts any path to Windows drive-prefix with forward slashes (e.g. d:/path).
# -----------------------------------------------------------------------------
function to_win_path() {
  [ -z "${1:-}" ] && echo "" && return 0
  cygpath -w "$1" 2>/dev/null || echo "$1"
}

function to_unix_path() {
  [ -z "${1:-}" ] && echo "" && return 0
  cygpath -u "$1" 2>/dev/null || echo "$1"
}

function to_mixed_path() {
  [ -z "${1:-}" ] && echo "" && return 0
  cygpath -m "$1" 2>/dev/null || echo "$1"
}

# Default Directories & Configurations (Windows-style paths with forward slashes)
# These are automatically resolved to POSIX paths (MSYS2 or Cygwin format) at startup.
DEFAULT_TARGET_DIR="d:/dev/rust"
DEFAULT_BUILD_DIR="f:/stage/upload/pending"
RUST_URL_BASE="https://static.rust-lang.org/dist"
XZ_OPTS="xz -T0"

# Global configuration arrays for tools and components (DRY principle)
GLOBAL_CARGO_TOOLS=(
  "cargo-audit" "cargo-bloat" "cargo-deny" "cargo-geiger" "cargo-machete"
  "cargo-nextest" "cargo-outdated" "cargo-semver-checks" "cargo-udeps"
)
GLOBAL_BUILTIN_TOOLS=(
  "cargo-clippy" "clippy-driver" "cargo-fmt" "rustfmt" "rust-analyzer"
)
GLOBAL_OPTIONAL_COMPONENTS=(
  "rust-docs"
  "rust-docs-json-preview"
  "rust-analysis-x86_64-pc-windows-gnu"
  "rust-analysis-x86_64-unknown-linux-gnu"
  "llvm-bitcode-linker-preview"
)
GLOBAL_EXCLUDE_COMPONENTS=(
  "clippy-preview" "rustfmt-preview" "rust-analyzer-preview" "rust-linters-custom"
  "${GLOBAL_OPTIONAL_COMPONENTS[@]}"
)

# Resolve system temporary directory based on priority order: TMPDIR, TMP, TEMP, fallback to /tmp
# Convert to POSIX format so that it uses MSYS2/Cygwin style paths (resolving colons and backslashes)
RAW_TEMP="${TMPDIR:-${TMP:-${TEMP:-/tmp}}}"
SYS_TMP_DIR=$(cygpath -u "${RAW_TEMP}" 2>/dev/null || echo "${RAW_TEMP}")

# Staged variables for traps
TEMP_WORKSPACE=""
DETECT_TMP_DIR=""

# Persistent directory to cache compiled tools across runs (DRY & speed optimization)
# Can be overridden via RUST_PERSISTENT_TOOLS_DIR environment variable
PERSISTENT_TOOLS_DIR=$(to_unix_path "${RUST_PERSISTENT_TOOLS_DIR:-${SYS_TMP_DIR}/devops/cargo_compiled_tools}")
mkdir -p "${PERSISTENT_TOOLS_DIR}"

# Persistent isolated CARGO_HOME to cache registry indexes and crates across runs
# Can be overridden via RUST_CARGO_CACHE_DIR environment variable
BOOTSTRAP_CARGO_HOME=$(to_unix_path "${RUST_CARGO_CACHE_DIR:-${SYS_TMP_DIR}/devops/cargo_cache}")
mkdir -p "${BOOTSTRAP_CARGO_HOME}"
CARGO_HOME=$(to_win_path "${BOOTSTRAP_CARGO_HOME}")
export CARGO_HOME

# -----------------------------------------------------------------------------
# Function:    safe_delete
# Description: Recursively deletes directories, files, or symbolic links safely.
#              Performs defensive checks against empty strings, uninitialized 
#              variables, root (/) paths, and Windows/POSIX drive roots (e.g. C:,
#              /cygdrive/d, /d) to prevent destructive filesystem deletions.
# Arguments:   $@ - One or more paths to delete.
# Returns:     None (Exits with 99 on dangerous input detection).
# -----------------------------------------------------------------------------
function safe_delete() {
  for path in "$@"; do
    if [ -z "${path}" ]; then
      continue
    fi
    local normalized
    # shellcheck disable=SC1003
    normalized=$(printf '%s\n' "${path}" | tr '\\' '/' | sed 's|//*|/|g' | sed 's|/$||')
    
    # Block Unix root or empty path
    if [ "${normalized}" == "/" ] || [ "${normalized}" == "" ]; then
      echo "*** ERROR: Dangerous deletion of root (/) or empty path prevented for target: ${path}!"
      exit 99
    fi
    
    # Block drive root structures (e.g. D:, d:/, D:\, /cygdrive/c, /cygdrive/c/, /c, /c/)
    if [[ "${normalized}" =~ ^[a-zA-Z]:/?$ ]] || [[ "${normalized}" =~ ^/cygdrive/[a-zA-Z]/?$ ]] || [[ "${normalized}" =~ ^/[a-zA-Z]/?$ ]]; then
      echo "*** ERROR: Dangerous deletion of drive root prevented for target: ${path}!"
      exit 99
    fi
    
    if [ -d "${normalized}" ]; then
      # Fast path: rename directory out of the way instantly, then delete natively in background
      local rand_suffix
      rand_suffix=$(date +%s%N 2>/dev/null || echo "${RANDOM}")
      local trash_dir="${normalized}.trash-${rand_suffix}"
      local win_trash
      
      if mv -f -- "${normalized}" "${trash_dir}" 2>/dev/null; then
        win_trash=$(to_win_path "${trash_dir}")
        if [ "${OS_ENV}" == "CYGWIN" ]; then
          cmd.exe /c rmdir /s /q "${win_trash}" >/dev/null 2>&1 &
        else
          cmd.exe //c rmdir //s //q "${win_trash}" >/dev/null 2>&1 &
        fi
      else
        # Fallback if rename fails (e.g. due to lock or volume boundaries)
        local win_path
        win_path=$(to_win_path "${normalized}")
        if [ "${OS_ENV}" == "CYGWIN" ]; then
          cmd.exe /c rmdir /s /q "${win_path}" >/dev/null 2>&1 || rm -rf -- "${normalized}" || true
        else
          cmd.exe //c rmdir //s //q "${win_path}" >/dev/null 2>&1 || rm -rf -- "${normalized}" || true
        fi
      fi
    elif [ -f "${normalized}" ] || [ -L "${normalized}" ]; then
      rm -f -- "${normalized}" || true
    fi
  done
}

# Cleanup routine for exit signals
# -----------------------------------------------------------------------------
# Function:    cleanup
# Description: Standard exit signal handler. Safely deletes the entire
#              temporary compilation workspace sandboxes.
# Arguments:   None
# Returns:     None
# -----------------------------------------------------------------------------
function cleanup() {
  safe_delete "${TEMP_WORKSPACE}" "${DETECT_TMP_DIR}"
}
trap cleanup EXIT INT TERM HUP

# -----------------------------------------------------------------------------
# Function:    configure_compiler_env
# Description: Normalizes compiler paths, exports CC and compiler target variables,
#              and enables LLD linker optimizations if LLD is detected.
# Arguments:   $1 - Path to C compiler
# Returns:     None
# -----------------------------------------------------------------------------
function configure_compiler_env() {
  local cc_path="$1"
  [ -z "${cc_path}" ] && return 0

  CC=$(to_win_path "${cc_path}")
  export CC
  CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER=$(to_win_path "${cc_path}")
  export CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER

  local cc_dir
  cc_dir=$(dirname "${cc_path}")
  if [ -f "${cc_dir}/ld.lld.exe" ] || [ -f "${cc_dir}/lld.exe" ] || command -v lld.exe &>/dev/null; then
    if [[ -z "${RUSTFLAGS:-}" ]]; then
      export RUSTFLAGS="-C link-arg=-fuse-ld=lld"
    elif [[ "${RUSTFLAGS}" != *"-fuse-ld=lld"* ]]; then
      export RUSTFLAGS="${RUSTFLAGS} -C link-arg=-fuse-ld=lld"
    fi
  fi

  if [ "${NO_LTO}" == "true" ]; then
    export CARGO_PROFILE_RELEASE_LTO="false"
    export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=256
  fi
}

# -----------------------------------------------------------------------------
# Function:    register_manifest_components
# Description: Scans standard component directories and records folder basenames
#              into the package component registry manifest.
# Arguments:   $1 - Root path of components to scan
#              $2 - Target manifest filepath
# Returns:     None
# -----------------------------------------------------------------------------
function register_manifest_components() {
  local root_dir="$1"
  local manifest_file="$2"
  [ -d "${root_dir}" ] || return 0

  for comp_path in "${root_dir}"/*/; do
    if [ -d "${comp_path}" ]; then
      local comp_name
      comp_name=$(basename "${comp_path%/}")
      echo "${comp_name}" >> "${manifest_file}"
    fi
  done
}

# -----------------------------------------------------------------------------
# Function:    update_windows_path
# Description: Persistently appends a folder to the Windows PATH environment
#              variable using PowerShell environment classes. Normalizes slashes
#              and handles case-insensitive checks to prevent duplicate paths.
# Arguments:   $1 - Target registry scope ('User' or 'Machine').
#              $2 - Windows path to append.
# Returns:     0 if successfully added, 1 if path was already present.
# -----------------------------------------------------------------------------
function update_windows_path() {
  local target_scope="$1"
  local path_to_add="$2"
  
  # Normalize target path to add (use backslashes, strip trailing slashes)
  local norm_add
  # shellcheck disable=SC2001
  norm_add=$(to_win_path "${path_to_add}" | sed 's|\\*$||')
  
  local current_val
  current_val=$(powershell.exe -Command "[Environment]::GetEnvironmentVariable('Path', '${target_scope}')" | tr -d '\r')
  
  # Compare case-insensitively and normalize existing paths in split registry value
  local path_exists="false"
  local ORIG_IFS="${IFS}"
  IFS=';'
  for p in ${current_val}; do
    local norm_p
    # shellcheck disable=SC2001
    norm_p=$(echo "${p}" | sed 's|\\*$||')
    if [ "${norm_p,,}" == "${norm_add,,}" ]; then
      path_exists="true"
      break
    fi
  done
  IFS="${ORIG_IFS}"
  
  if [ "${path_exists}" == "false" ]; then
    powershell.exe -Command "[Environment]::SetEnvironmentVariable('Path', \"${current_val};${norm_add}\", '${target_scope}')"
    return 0
  else
    return 1
  fi
}

# -----------------------------------------------------------------------------
# Function:    is_elevated
# Description: Verifies if the script is running with elevated Administrator
#              privileges on Windows.
# Arguments:   None
# Returns:     Prints "true" if running as Administrator, "false" otherwise.
# -----------------------------------------------------------------------------
function is_elevated() {
  net session &>/dev/null && echo "true" || echo "false"
}

# Display script help menu
function show_help() {
  echo "Usage: $(basename "$0") [options]"
  echo ""
  echo "Modes (At least one operational mode, --detect, --linters, or --package-citools must be specified):"
  echo "  --build              Build a custom unified Rust toolchain with compiled linters."
  echo "  --deploy             Deploy/extract a pre-built Rust custom toolchain package."
  echo "  --detect [text|json] Detect current Rust installation and linters status."
  echo "  --linters [<path>]   Install linters/cargo tools. If <path> is provided, extracts"
  echo "                       precompiled binaries directly from that archive."
  echo "  --package-citools [p] Package compiled linters into a tar.xz archive."
  echo ""
  echo "Options:"
  echo "  --version <version>  Specify the target Rust version (e.g., 1.96.1)."
  echo "  --auto               Auto-detect the latest stable Rust version."
  echo "  --cc <path>          Path to custom C compiler (e.g., d:/dev/mingw64/bin/gcc.exe)."
  echo "  --path-update <mode> PATH update mode: none (default), user, system, script."
  echo "                         none:   Do not modify environment variables."
  echo "                         user:   Persistently append bin/ to User PATH (via registry/setx)."
  echo "                         system: Persistently append bin/ to System PATH (requires Admin)."
  echo "                         script: Generate local setup scripts (env.sh / env.bat)."
  echo "  --target-dir <path>  Target directory for --deploy (default: d:/dev/rust)."
  echo "  --build-dir <path>   Output directory for built packages (default: f:/stage/upload/pending)."
  echo "  --archive-path <pat> Path to custom archive to deploy (omitting defaults to pending folder)."
  echo "  --force              Force download, compilation, or deployment even if versions match."
  echo "  --core-components    Deploy core compiler only (exclude docs, preview components)."
  echo "  --no-lto             Disable Link-Time Optimization (LTO) and use parallel codegen"
  echo "                       units to speed up Cargo compilation (release build speedup)."
  echo "  --log [file]         Redirect stdout/stderr to a log file (default: /var/log/rust_upgrade_win.log)."
  echo "  --help, -h           Show this help message and exit."
  echo ""
}

# ----- ARGUMENT PARSING -----
RUN_BUILD="false"
RUN_DEPLOY="false"
RUN_DETECT="false"
DETECT_FORMAT="text"
RUST_VERSION=""
HAS_VERSION="false"
HAS_AUTO="false"
CC_CUSTOM_PATH=""
PATH_UPDATE_MODE="none"
TARGET_DIR="${DEFAULT_TARGET_DIR}"
BUILD_DIR="${DEFAULT_BUILD_DIR}"
ARCHIVE_PATH=""
FORCE_INSTALL="false"
CORE_COMPONENTS="false"
HAS_LOG="false"
LOG_FILE="/var/log/rust_upgrade_win.log"
HAS_PACKAGE_CITOOLS="false"
PACKAGE_CITOOLS_NAME=""
HAS_LINTERS="false"
LINTERS_ARCHIVE=""
NO_LTO="false"
SHOW_HELP="false"

while [ $# -gt 0 ]; do
  case "$1" in
    --build)
      RUN_BUILD="true"
      shift
      ;;
    --deploy)
      RUN_DEPLOY="true"
      shift
      ;;
    --detect)
      RUN_DETECT="true"
      if [ -n "${2:-}" ] && [[ "${2}" != -* ]]; then
        case "$2" in
          text|json) DETECT_FORMAT="$2"; shift 2 ;;
          *) echo "ERROR: --detect format must be 'text' or 'json'." && exit 1 ;;
        esac
      else
        shift
      fi
      ;;
    --version)
      if [ -z "${2:-}" ] || [[ "$2" == -* ]]; then
        echo "ERROR: --version requires an argument (e.g. 1.96.1)." && exit 1
      fi
      RUST_VERSION="$2"
      HAS_VERSION="true"
      shift 2
      ;;
    --auto)
      HAS_AUTO="true"
      shift
      ;;
    --cc)
      if [ -z "${2:-}" ] || [[ "$2" == -* ]]; then
        echo "ERROR: --cc requires a compiler path." && exit 1
      fi
      CC_CUSTOM_PATH="$2"
      shift 2
      ;;
    --path-update)
      if [ -z "${2:-}" ] || [[ "$2" == -* ]]; then
        echo "ERROR: --path-update requires a mode: none, user, system, script." && exit 1
      fi
      case "$2" in
        none|user|system|script) PATH_UPDATE_MODE="$2"; shift 2 ;;
        *) echo "ERROR: Invalid PATH mode. Options: none, user, system, script." && exit 1 ;;
      esac
      ;;
    --target-dir)
      if [ -z "${2:-}" ] || [[ "$2" == -* ]]; then
        echo "ERROR: --target-dir requires a path." && exit 1
      fi
      TARGET_DIR="$2"
      shift 2
      ;;
    --build-dir)
      if [ -z "${2:-}" ] || [[ "$2" == -* ]]; then
        echo "ERROR: --build-dir requires a path." && exit 1
      fi
      BUILD_DIR="$2"
      shift 2
      ;;
    --archive-path)
      if [ -z "${2:-}" ] || [[ "$2" == -* ]]; then
        echo "ERROR: --archive-path requires a path." && exit 1
      fi
      ARCHIVE_PATH="$2"
      shift 2
      ;;
    --force)
      FORCE_INSTALL="true"
      shift
      ;;
    --core-components)
      CORE_COMPONENTS="true"
      shift
      ;;
    --log)
      HAS_LOG="true"
      if [ -n "${2:-}" ] && [[ "$2" != -* ]]; then
        LOG_FILE=$(to_unix_path "$2")
        shift 2
      fi
      ;;
    --package-citools)
      HAS_PACKAGE_CITOOLS="true"
      if [ -n "${2:-}" ] && [[ "$2" != -* ]]; then
        PACKAGE_CITOOLS_NAME="$2"
        shift 2
      else
        shift
      fi
      ;;
    --linters)
      HAS_LINTERS="true"
      if [ -n "${2:-}" ] && [[ "$2" != -* ]]; then
        LINTERS_ARCHIVE="$2"
        shift 2
      else
        shift
      fi
      ;;
    --no-lto)
      NO_LTO="true"
      shift
      ;;
    -h|--help)
      SHOW_HELP="true"
      shift
      ;;
    *)
      echo "ERROR: Unknown option: $1"
      show_help
      exit 1
      ;;
  esac
done

if [ "${SHOW_HELP}" == "true" ]; then
  show_help
  exit 0
fi

# Validation: Mutually exclusive modes and requirements
if [ "${RUN_DETECT}" == "true" ]; then
  if [ "${RUN_BUILD}" == "true" ] || [ "${RUN_DEPLOY}" == "true" ]; then
    echo "ERROR: --detect cannot be combined with --build or --deploy." && exit 1
  fi
fi

if [ "${RUN_DETECT}" == "false" ] && [ "${RUN_BUILD}" == "false" ] && [ "${RUN_DEPLOY}" == "false" ] && [ "${HAS_PACKAGE_CITOOLS}" == "false" ] && [ "${HAS_LINTERS}" == "false" ]; then
  echo "ERROR: You must specify --build, --deploy, --detect, --linters, or --package-citools."
  show_help
  exit 1
fi

# Resolve default package name for citools
if [ "${HAS_PACKAGE_CITOOLS}" == "true" ]; then
  HAS_LINTERS="true"
fi

if [ "${RUN_DETECT}" == "false" ] && [ "${HAS_VERSION}" == "false" ] && [ "${HAS_AUTO}" == "false" ] && [ "${HAS_LINTERS}" == "false" ] && [ "${HAS_PACKAGE_CITOOLS}" == "false" ]; then
  echo "ERROR: You must specify a version (--version <version> or --auto) or run in standalone linter mode."
  exit 1
fi

if [ "${HAS_VERSION}" == "true" ] && [ "${HAS_AUTO}" == "true" ]; then
  echo "ERROR: --version and --auto are mutually exclusive."
  exit 1
fi

if [ "${PATH_UPDATE_MODE}" == "system" ] && [ "$(is_elevated)" != "true" ]; then
  echo -e "\n*** ERROR02: Administrator privileges are required for system PATH updates."
  exit 2
fi

# Create unified temporary workspace for all operations
if [ "${RUN_BUILD}" == "true" ] || [ "${RUN_DEPLOY}" == "true" ] || [ "${HAS_LINTERS}" == "true" ] || [ "${HAS_PACKAGE_CITOOLS}" == "true" ]; then
  TIMESTAMP=$(date +%Y%m%d%H%M%S)
  TEMP_WORKSPACE="${SYS_TMP_DIR}/devops/rust-${TIMESTAMP}"
  mkdir -p "${TEMP_WORKSPACE}"
fi

# Log Redirection
if [ "${HAS_LOG}" == "true" ]; then
  LOG_DIR=$(dirname "${LOG_FILE}")
  mkdir -p "${LOG_DIR}"
  exec >> "${LOG_FILE}" 2>&1
  echo -e "\n--- Log session started: $(date) ---"
fi

# -----------------------------------------------------------------------------
# Function:    resolve_cc
# Description: Dynamically locates and validates a suitable C compiler (GCC/MinGW)
#              on the host system. Evaluates CLI custom options, active 
#              environment variables, and standard installation directory paths.
#              Excludes native POSIX compilers (Cygwin/MSYS2 native GCC) to 
#              avoid runtime DLL dependency conflicts.
# Arguments:   None
# Returns:     Prints the absolute POSIX path of the resolved compiler, or 
#              returns empty if no compiler is found.
# -----------------------------------------------------------------------------
function resolve_cc() {
  local cc_resolved=""

  # 1. Check CLI specified path
  if [ -n "${CC_CUSTOM_PATH}" ]; then
    local cli_cc_posix
    cli_cc_posix=$(to_unix_path "${CC_CUSTOM_PATH}")
    if [ -x "${cli_cc_posix}" ]; then
      cc_resolved="${cli_cc_posix}"
    else
      echo "*** WARNING: Specified C compiler at [${CC_CUSTOM_PATH}] was not found or is not executable."
    fi
  fi

  # 2. Check CC environment variable
  if [ -z "${cc_resolved}" ] && [ -n "${CC:-}" ]; then
    local env_cc_posix
    env_cc_posix=$(to_unix_path "${CC}")
    if command -v "${env_cc_posix}" &>/dev/null; then
      local resolved_val
      resolved_val=$(command -v "${env_cc_posix}")
      # Skip Cygwin/MSYS2 native compilers which depend on cygwin1.dll/msys-2.0.dll
      if [[ "${resolved_val}" != "/usr/bin/gcc"* ]] && [[ "${resolved_val}" != "/bin/gcc"* ]] && \
         [[ "${resolved_val}" != "/usr/bin/clang"* ]] && [[ "${resolved_val}" != "/bin/clang"* ]]; then
        cc_resolved="${resolved_val}"
      fi
    elif [ -x "${env_cc_posix}" ]; then
      if [[ "${env_cc_posix}" != "/usr/bin/gcc"* ]] && [[ "${env_cc_posix}" != "/bin/gcc"* ]] && \
         [[ "${env_cc_posix}" != "/usr/bin/clang"* ]] && [[ "${env_cc_posix}" != "/bin/clang"* ]]; then
        cc_resolved="${env_cc_posix}"
      fi
    fi
  fi

  # 3. Check system PATH
  if [ -z "${cc_resolved}" ]; then
    # Look for MinGW-w64 compiler first
    if command -v x86_64-w64-mingw32-gcc.exe &>/dev/null; then
      cc_resolved=$(command -v x86_64-w64-mingw32-gcc.exe)
    elif command -v gcc.exe &>/dev/null; then
      local system_gcc
      system_gcc=$(command -v gcc.exe)
      # Skip Cygwin/MSYS2 native compilers
      if [[ "${system_gcc}" != "/usr/bin/gcc"* ]] && [[ "${system_gcc}" != "/bin/gcc"* ]]; then
        cc_resolved="${system_gcc}"
      fi
    elif command -v clang.exe &>/dev/null; then
      local system_clang
      system_clang=$(command -v clang.exe)
      # Skip Cygwin/MSYS2 native compilers
      if [[ "${system_clang}" != "/usr/bin/clang"* ]] && [[ "${system_clang}" != "/bin/clang"* ]]; then
        cc_resolved="${system_clang}"
      fi
    fi
  fi

  # 4. Check common Windows developer locations (e.g. MinGW64)
  # Resolve Windows drive-prefix paths dynamically using to_unix_path
  if [ -z "${cc_resolved}" ]; then
    local common_paths=(
      "d:/dev/mingw64/bin/gcc.exe"
      "c:/cygwin64/bin/x86_64-w64-mingw32-gcc.exe"
      "c:/msys64/mingw64/bin/gcc.exe"
      "c:/msys64/ucrt64/bin/gcc.exe"
      "/usr/bin/x86_64-w64-mingw32-gcc.exe"
    )
    for path in "${common_paths[@]}"; do
      local posix_path
      posix_path=$(to_unix_path "${path}")
      if [ -x "${posix_path}" ]; then
        cc_resolved="${posix_path}"
        break
      fi
    done
  fi

  # 5. Staging-Bundled Fallback (handled at build-time using staging directories)
  # This returns empty if none found, triggering build pipeline to hook the staging path.
  echo "${cc_resolved}"
}

# -----------------------------------------------------------------------------
#  Function: install_linters
#  Description:
#    Installs Rust code quality tools. If LINTERS_ARCHIVE is provided, extracts
#    precompiled binaries directly into the target root. Otherwise, compiles
#    them using the resolved cargo.exe and compiler.
# -----------------------------------------------------------------------------
function install_linters() {
  local install_root="$1"
  local target_bin_dir="${install_root}/bin"
  mkdir -p "${target_bin_dir}"

  # If an archive is specified, extract it
  if [ -n "${LINTERS_ARCHIVE}" ]; then
    if [ ! -f "${LINTERS_ARCHIVE}" ]; then
      echo "*** ERROR10: Archive file [${LINTERS_ARCHIVE}] does not exist." && exit 10
    fi
    echo ""
    echo ">> Extracting precompiled linter binaries from [${LINTERS_ARCHIVE}]..."
    tar --force-local -C "${install_root}" -I "${XZ_OPTS}" -xf "${LINTERS_ARCHIVE}"
    echo "   OK"
    return 0
  fi

  # Otherwise, compile them!
  local CARGO_BIN=""
  if [ -x "${BOOTSTRAP_BIN_DIR:-}/bin/cargo.exe" ]; then
    CARGO_BIN="${BOOTSTRAP_BIN_DIR}/bin/cargo.exe"
  elif command -v cargo.exe &>/dev/null; then
    CARGO_BIN=$(command -v cargo.exe)
  elif [ -x "${TARGET_DIR}/bin/cargo.exe" ]; then
    CARGO_BIN="${TARGET_DIR}/bin/cargo.exe"
  fi

  if [ -z "${CARGO_BIN}" ] || ! [ -x "${CARGO_BIN}" ]; then
    echo "*** ERROR: cargo.exe not found. Cannot compile linters." && exit 1
  fi

  local BIN_DIR
  BIN_DIR=$(dirname "${CARGO_BIN}")
  
  # Setup paths and compiler options
  local CC_PATH
  CC_PATH=$(resolve_cc)
  if [ -z "${CC_PATH}" ]; then
    local BUNDLED_GCC_PATH="${BIN_DIR}/lib/rustlib/x86_64-pc-windows-gnu/bin/self-contained/x86_64-w64-mingw32-gcc.exe"
    if [ -f "${BUNDLED_GCC_PATH}" ]; then
      CC_PATH="${BUNDLED_GCC_PATH}"
    fi
  fi

  # Copy LLD linker if missing from compiler directory to speed up compilation
  if [ -n "${CC_PATH}" ]; then
    local cc_dir
    cc_dir=$(dirname "${CC_PATH}")
    local needs_lld="false"
    if [ ! -f "${cc_dir}/ld.lld.exe" ] && [ ! -f "${cc_dir}/lld.exe" ] && ! command -v lld.exe &>/dev/null; then
      needs_lld="true"
    elif [ -f "${cc_dir}/ld.lld.exe" ] && ! "${cc_dir}/ld.lld.exe" --version &>/dev/null; then
      needs_lld="true"
    fi

    if [ "${needs_lld}" == "true" ]; then
      local toolchain_root
      toolchain_root=$(dirname "${BIN_DIR}")
      local source_lld="${toolchain_root}/lib/rustlib/x86_64-pc-windows-gnu/bin/rust-lld.exe"
      if [ -f "${source_lld}" ]; then
        echo "   [+] LLD linker not found or broken in compiler directory. Copying from Rust standard library..."
        # Remove potentially broken wrapper if it exists before copying
        [ -f "${cc_dir}/ld.lld.exe" ] && rm -f "${cc_dir}/ld.lld.exe"
        if cp "${source_lld}" "${cc_dir}/ld.lld.exe" 2>/dev/null; then
          echo "       Successfully copied LLD to $(to_mixed_path "${cc_dir}/ld.lld.exe")"
        else
          echo "       WARNING: Failed to copy LLD (check write permissions for ${cc_dir})"
        fi
      fi
    fi
  fi

  # Run cargo installs
  echo -e "\n>> Compiling third-party tools/linters..."
  local ORIGINAL_PATH="${PATH}"
  local cc_dir=""
  [ -n "${CC_PATH:-}" ] && cc_dir=$(dirname "${CC_PATH}")
  export PATH="${PERSISTENT_TOOLS_DIR}/bin:${BIN_DIR}:${cc_dir}:${PATH}"

  configure_compiler_env "${CC_PATH}"

  local CARGO_TOOLS=("${GLOBAL_CARGO_TOOLS[@]}")

  local failed_tools=()
  for tool in "${CARGO_TOOLS[@]}"; do
    # Check if binary already exists in PERSISTENT_TOOLS_DIR/bin to bypass redundant installation checks
    if [ "${FORCE_INSTALL}" != "true" ] && [ -f "${PERSISTENT_TOOLS_DIR}/bin/${tool}.exe" ]; then
      echo "   [+] ${tool} is already installed (cached), skipping."
      continue
    fi

    echo "   [+] Installing ${tool}..."
    local install_args=("--root" "$(to_win_path "${PERSISTENT_TOOLS_DIR}")" "--locked")
    [ "${FORCE_INSTALL}" == "true" ] && install_args+=("--force")
    
    local install_success="true"
    if [ "${tool}" == "cargo-audit" ]; then
      cargo install "${install_args[@]}" cargo-audit || install_success="false"
    elif [ "${tool}" == "cargo-udeps" ]; then
      RUSTC_BOOTSTRAP=1 cargo install "${install_args[@]}" cargo-udeps || install_success="false"
    else
      cargo install "${install_args[@]}" "${tool}" || install_success="false"
    fi

    if [ "${install_success}" == "true" ]; then
      echo "      OK"
    else
      echo "      ERROR: failed to install [${tool}]"
      failed_tools+=("${tool}")
    fi
  done

  if [ ${#failed_tools[@]} -gt 0 ]; then
    echo -e "\n*** ERROR15: Failed to compile or install one or more tools: ${failed_tools[*]}"
    exit 15
  fi

  # Link/copy the compiled tools from PERSISTENT_TOOLS_DIR/bin to install_root/bin
  # Use CP_CMD (which resolves to cp -rlf) for instant staging
  mkdir -p "${install_root}/bin"
  if [ -d "${PERSISTENT_TOOLS_DIR}/bin" ]; then
    ${CP_CMD:-cp -rlf} "${PERSISTENT_TOOLS_DIR}/bin"/* "${install_root}/bin/"
  fi

  export PATH="${ORIGINAL_PATH}"
}

# -----------------------------------------------------------------------------
#  Function: package_linters
#  Description:
#    Packages all compiled/staged linter binaries into a tar.xz archive.
# -----------------------------------------------------------------------------
function package_linters() {
  local source_root="$1"
  local target_archive="$2"
  
  echo ""
  printf ">> Packaging linter binaries to archive [%s]\n" "$(to_mixed_path "${target_archive}")"
  
  # Ensure target output directory exists
  local archive_dir
  archive_dir=$(dirname "${target_archive}")
  mkdir -p "${archive_dir}"

  local exist_bins=()
  local tool
  for tool in "${GLOBAL_BUILTIN_TOOLS[@]}" "${GLOBAL_CARGO_TOOLS[@]}"; do
    if [ -f "${source_root}/bin/${tool}.exe" ]; then
      exist_bins+=("bin/${tool}.exe")
    fi
  done

  if [ "${#exist_bins[@]}" -eq 0 ]; then
    echo "*** WARNING: No linter binaries found to package under [$(to_mixed_path "${source_root}/bin")]."
  else
    tar --force-local -C "${source_root}" -I "${XZ_OPTS}" -cf "${target_archive}" "${exist_bins[@]}"
    local retval="$?"
    if [ "${retval}" -eq 0 ]; then
      echo "      OK"
    else
      echo "*** WARNING: Packaging failed with exit code [${retval}]"
    fi
  fi
}

# ----- AUTO DETECTION REPORT MODE -----
if [ "${RUN_DETECT}" == "true" ]; then
  # Optional toolchain components that can be skipped via --core-components or audited in --detect
  OPTIONAL_COMPONENTS=("${GLOBAL_OPTIONAL_COMPONENTS[@]}")

  # Determine local rustc location
  RUSTC_PATH=""
  if command -v rustc.exe &>/dev/null; then
    RUSTC_PATH=$(command -v rustc.exe)
  elif [ -x "${TARGET_DIR}/bin/rustc.exe" ]; then
    RUSTC_PATH="${TARGET_DIR}/bin/rustc.exe"
  fi

  if [ -z "${RUSTC_PATH}" ]; then
    if [ "${DETECT_FORMAT}" == "json" ]; then
      printf '{\n  "status": "not_found",\n  "message": "No active Rust installation detected."\n}\n'
    else
      echo -e "\n========================================================================="
      echo -e "                 RUST WINDOWS INSTALLATION DETECTION REPORT              "
      echo -e "========================================================================="
      echo -e "  Status: No active Rust installation detected in PATH or standard folders."
      echo -e "=========================================================================\n"
    fi
    exit 0
  fi

  BIN_DIR=$(dirname "${RUSTC_PATH}")
  SYSROOT=$("${RUSTC_PATH}" --print sysroot 2>/dev/null | tr -d '\r')
  SYSROOT_UNIX=$(to_unix_path "${SYSROOT}")
  RUSTC_VER=$("${RUSTC_PATH}" --version 2>/dev/null | tr -d '\r')
  
  CARGO_PATH=""
  if [ -x "${BIN_DIR}/cargo.exe" ]; then
    CARGO_PATH="${BIN_DIR}/cargo.exe"
  fi
  CARGO_VER=""
  if [ -n "${CARGO_PATH}" ]; then
    CARGO_VER=$("${CARGO_PATH}" --version 2>/dev/null | tr -d '\r')
  fi

  # Resolve C Compiler path and version
  CC_PATH=$(resolve_cc)
  CC_PATH_WIN="Not Found"
  CC_VER="-"
  if [ -n "${CC_PATH}" ]; then
    CC_PATH_WIN=$(to_win_path "${CC_PATH}")
    CC_VER=$("${CC_PATH}" --version 2>/dev/null | head -n 1 | tr -d '\r')
  fi

  # Extract components from registry if present
  COMPONENTS_FILE="${SYSROOT_UNIX}/lib/rustlib/components"
  STD_TARGETS=()
  TOOL_COMPONENTS=()
  if [ -f "${COMPONENTS_FILE}" ]; then
    while IFS= read -r line || [ -n "${line}" ]; do
      line_clean=$(echo "${line}" | tr -d '\r')
      if [[ "${line_clean}" == rust-std-* ]]; then
        STD_TARGETS+=("${line_clean#rust-std-}")
      elif [ -n "${line_clean}" ]; then
        TOOL_COMPONENTS+=("${line_clean}")
      fi
    done < "${COMPONENTS_FILE}"
  fi

  HOST_TARGET=$("${RUSTC_PATH}" -vV 2>/dev/null | grep "host:" | cut -d' ' -f2 | tr -d '\r')

  # Check status of core components that could be excluded via --core-components
  OPT_COMPONENTS_STATUS=()
  for opt_c in "${OPTIONAL_COMPONENTS[@]}"; do
    found="false"
    for c in "${TOOL_COMPONENTS[@]}"; do
      if [ "${c}" == "${opt_c}" ]; then
        found="true"
        break
      fi
    done

    if [ "${found}" == "true" ]; then
      OPT_COMPONENTS_STATUS+=("Installed")
    else
      OPT_COMPONENTS_STATUS+=("Excluded")
    fi
  done

  # Linter detection (Parallelized for Windows speed)
  LINTERS=("${GLOBAL_CARGO_TOOLS[@]}" "clippy" "rust-analyzer" "rustfmt")
  LINTER_STATUS=()
  LINTER_VERSION=()

  DETECT_TMP_DIR=$(mktemp -d -p "${SYS_TMP_DIR}" rust-detect-XXXXXX)

  for i in "${!LINTERS[@]}"; do
    linter="${LINTERS[$i]}"
    binary_name="${linter}"
    if [ "${linter}" == "clippy" ]; then
      binary_name="cargo-clippy"
    elif [ "${linter}" == "rustfmt" ]; then
      binary_name="rustfmt"
    fi

    resolved_path=""
    if [ -x "${BIN_DIR}/${binary_name}.exe" ]; then
      resolved_path="${BIN_DIR}/${binary_name}.exe"
    elif command -v "${binary_name}.exe" &>/dev/null; then
      resolved_path=$(command -v "${binary_name}.exe")
    fi

    if [ -n "${resolved_path}" ]; then
      (
        # Prepend binary and cargo folders to PATH to resolve DLL and subcommand dependencies (process-free)
        PATH="${resolved_path%/*}:${CARGO_PATH%/*}:${PATH}"
        export PATH

        raw_version=""
        if [[ "${binary_name}" == cargo-* ]] && [ -n "${CARGO_PATH}" ] && [ -x "${CARGO_PATH}" ]; then
          subcmd="${binary_name#cargo-}"
          raw_version=$("${CARGO_PATH}" "${subcmd}" --version 2>&1) || true
        else
          raw_version=$("${resolved_path}" --version 2>&1) || true
        fi
        
        # Parse version using 100% native bash builtins (0 processes spawned)
        read -r first_line <<< "${raw_version}"
        first_line="${first_line//$'\r'/}"
        
        clean_ver=""
        if [[ "${first_line}" =~ (v?[0-9]+\.[0-9]+\.[0-9]+.*) ]]; then
          clean_ver="${BASH_REMATCH[1]}"
        else
          clean_ver="${first_line}"
        fi
        
        echo "Installed" > "${DETECT_TMP_DIR}/${i}.status"
        echo "${clean_ver:-Unknown}" > "${DETECT_TMP_DIR}/${i}.version"
      ) &
    else
      echo "Not Installed" > "${DETECT_TMP_DIR}/${i}.status"
      echo "-" > "${DETECT_TMP_DIR}/${i}.version"
    fi
  done

  # Wait for all parallel background version queries to complete
  wait

  # Read outputs back
  for i in "${!LINTERS[@]}"; do
    LINTER_STATUS+=("$(cat "${DETECT_TMP_DIR}/${i}.status" | tr -d '\r')")
    LINTER_VERSION+=("$(cat "${DETECT_TMP_DIR}/${i}.version" | tr -d '\r')")
  done

  safe_delete "${DETECT_TMP_DIR}"

  # Output Formats
  if [ "${DETECT_FORMAT}" == "text" ]; then
    echo ""
    echo "========================================================================="
    echo "                 RUST WINDOWS INSTALLATION DETECTION REPORT              "
    echo "========================================================================="
    echo "[1] Locations & Core Versions"
    printf "  rustc path:    %s\n" "$(to_mixed_path "${RUSTC_PATH}")"
    printf "  rustc version: %s\n" "${RUSTC_VER}"
    printf "  cargo path:    %s\n" "$(to_mixed_path "${CARGO_PATH}")"
    printf "  cargo version: %s\n" "${CARGO_VER:-Not Found}"
    printf "  Sysroot path:  %s\n" "$(to_mixed_path "${SYSROOT}")"
    printf "  Host target:   %s\n" "${HOST_TARGET:-Unknown}"
    printf "  C compiler:    %s\n" "$(to_mixed_path "${CC_PATH_WIN}")"
    printf "  CC version:    %s\n" "${CC_VER}"
    echo ""
    echo "[2] Target Standard Libraries"
    if [ ${#STD_TARGETS[@]} -eq 0 ]; then
      echo "  (No target metadata registry found)"
    else
      for t in "${STD_TARGETS[@]}"; do echo "  - ${t}"; done
    fi
    echo ""
    echo "[3] Installed Toolchain Components"
    if [ ${#TOOL_COMPONENTS[@]} -eq 0 ]; then
      echo "  (No component metadata registry found)"
    else
      for c in "${TOOL_COMPONENTS[@]}"; do echo "  - ${c}"; done
    fi
    echo ""
    echo "[4] Switchable Components"
    printf "  %-42s %s\n" "Component" "Status"
    printf "  %-42s %s\n" "---------" "------"
    for i in "${!OPTIONAL_COMPONENTS[@]}"; do
      printf "  %-42s %s\n" "${OPTIONAL_COMPONENTS[$i]}" "${OPT_COMPONENTS_STATUS[$i]}"
    done
    echo ""
    echo "[5] Code Quality & Linter Tools"
    printf "  %-22s %-15s %s\n" "Tool" "Status" "Version"
    printf "  %-22s %-15s %s\n" "----" "------" "-------"
    for i in "${!LINTERS[@]}"; do
      printf "  %-22s %-15s %s\n" "${LINTERS[$i]}" "${LINTER_STATUS[$i]}" "${LINTER_VERSION[$i]}"
    done
    printf "=========================================================================\n\n"
  else
    # Output JSON
    json_str() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
    printf $'{\n'
    printf $'  "status": "found",\n'
    printf $'  "rustc": {\n'
    printf $'    "path": "%s",\n'    "$(json_str "$(to_win_path "${RUSTC_PATH}")")"
    printf $'    "version": "%s"\n'  "$(json_str "${RUSTC_VER}")"
    printf $'  },\n'
    printf $'  "cargo": {\n'
    printf $'    "path": "%s",\n'    "$(json_str "$(to_win_path "${CARGO_PATH}")")"
    printf $'    "version": "%s"\n'  "$(json_str "${CARGO_VER}")"
    printf $'  },\n'
    printf $'  "c_compiler": {\n'
    printf $'    "path": "%s",\n'    "$(json_str "${CC_PATH_WIN}")"
    printf $'    "version": "%s"\n'  "$(json_str "${CC_VER}")"
    printf $'  },\n'
    printf $'  "sysroot": "%s",\n'   "$(json_str "${SYSROOT}")"
    printf $'  "host_target": "%s",\n' "$(json_str "${HOST_TARGET:-}")"
    
    # std targets array
    printf $'  "std_targets": ['
    for i in "${!STD_TARGETS[@]}"; do
      printf $'"%s"' "$(json_str "${STD_TARGETS[$i]}")"
      [ "$i" -lt $(( ${#STD_TARGETS[@]} - 1 )) ] && printf $', '
    done
    printf $'],\n'
    
    # toolchain components array
    printf $'  "toolchain_components": ['
    for i in "${!TOOL_COMPONENTS[@]}"; do
      printf $'"%s"' "$(json_str "${TOOL_COMPONENTS[$i]}")"
      [ "$i" -lt $(( ${#TOOL_COMPONENTS[@]} - 1 )) ] && printf $', '
    done
    printf $'],\n'
    
    # legacy alias components array
    printf $'  "components": ['
    for i in "${!TOOL_COMPONENTS[@]}"; do
      printf $'"%s"' "$(json_str "${TOOL_COMPONENTS[$i]}")"
      [ "$i" -lt $(( ${#TOOL_COMPONENTS[@]} - 1 )) ] && printf $', '
    done
    printf $'],\n'
    
    # switchable components status
    printf $'  "switchable_components": {\n'
    for i in "${!OPTIONAL_COMPONENTS[@]}"; do
      val="unknown"
      if [ "${OPT_COMPONENTS_STATUS[$i]}" == "Excluded" ]; then
        val="excluded"
      elif [ "${OPT_COMPONENTS_STATUS[$i]}" == "Installed" ]; then
        val="installed"
      fi
      printf $'    "%s": "%s"' "${OPTIONAL_COMPONENTS[$i]}" "${val}"
      if [ "${i}" -lt $(( ${#OPTIONAL_COMPONENTS[@]} - 1 )) ]; then printf $',\n'; else printf $'\n'; fi
    done
    printf $'  },\n'
    
    # Print linters object (v1 backward-compatible/Linux flat layout)
    printf $'  "linters": {\n'
    for i in "${!LINTERS[@]}"; do
      val="not_installed"
      if [ "${LINTER_STATUS[$i]}" == "Installed" ]; then
        val="installed"
      fi
      printf $'    "%s": "%s"' "${LINTERS[$i]}" "${val}"
      if [ "$i" -lt $(( ${#LINTERS[@]} - 1 )) ]; then printf $',\n'; else printf $'\n'; fi
    done
    printf $'  },\n'
    
    # Print detailed linter metadata (v2/Linux linter_details layout)
    printf $'  "linter_details": {\n'
    for i in "${!LINTERS[@]}"; do
      val="not_installed"
      if [ "${LINTER_STATUS[$i]}" == "Installed" ]; then
        val="installed"
      fi
      printf $'    "%s": {\n' "${LINTERS[$i]}"
      printf $'      "status": "%s",\n' "${val}"
      printf $'      "version": "%s"\n' "${LINTER_VERSION[$i]}"
      if [ "$i" -lt $(( ${#LINTERS[@]} - 1 )) ]; then printf $'    },\n'; else printf $'    }\n'; fi
    done
    printf $'  }\n}\n'
  fi
  exit 0
fi

# ----- STABLE VERSION RESOLUTION -----
if [ "${HAS_AUTO}" == "true" ]; then
  echo -e "\n>> Auto-detecting latest stable Rust version..."
  MANIFEST_URL="https://static.rust-lang.org/dist/channel-rust-stable.toml"
  MANIFEST_DATA=$(curl -sSfL "$MANIFEST_URL")
  
  if [ -z "$MANIFEST_DATA" ]; then
    echo "ERROR: Failed to download Rust release manifest." && exit 1
  fi
  
  LATEST_VERSION=$(echo "$MANIFEST_DATA" | grep -A 2 '\[pkg.rust\]' | grep 'version =' | cut -d'"' -f2 | cut -d' ' -f1 | tr -d '\r')
  RUST_VERSION="${LATEST_VERSION}"
  echo "Latest Stable Rust Version: ${RUST_VERSION}"
fi

# Dynamically resolve linter archive if requested but not specified
if [ "${FORCE_INSTALL}" != "true" ] && [ "${HAS_LINTERS}" == "true" ] && [ -z "${LINTERS_ARCHIVE}" ]; then
  echo -e "\n>> Dynamically searching for latest linter archive..."
  linter_pattern="${BUILD_DIR}/rust-linters-*-win-x86_64.tar.xz"
  matches=()
  for f in ${linter_pattern}; do
    [ -f "${f}" ] && matches+=("${f}")
  done
  if [ ${#matches[@]} -gt 0 ]; then
    # Sort matches descending (newest version/date first)
    mapfile -t sorted < <(printf "%s\n" "${matches[@]}" | sort -r)
    LINTERS_ARCHIVE="${sorted[0]}"
    echo "   Resolved to: $(to_mixed_path "${LINTERS_ARCHIVE}")"
  else
    if [ "${RUN_BUILD}" == "true" ]; then
      echo "   No precompiled linter archive found. Will compile from source."
    else
      echo "*** ERROR12: No linter archive matching [$(to_mixed_path "${BUILD_DIR}")/rust-linters-*-win-x86_64.tar.xz] found in build directory."
      exit 12
    fi
  fi
fi

# Local current version check
LOCAL_VER="0.0.0"
RUSTC_BIN_LOCAL="${TARGET_DIR}/bin/rustc.exe"
if [ -x "${RUSTC_BIN_LOCAL}" ]; then
  LOCAL_VER=$("${RUSTC_BIN_LOCAL}" --version | cut -d' ' -f2 | tr -d '\r')
fi

# Compare versions if force install is not active and linter tasks are not requested
if [ "${RUN_BUILD}" == "false" ] && [ "${LOCAL_VER}" == "${RUST_VERSION}" ] && \
   [ "${FORCE_INSTALL}" == "false" ] && [ "${HAS_LINTERS}" == "false" ] && \
   [ "${HAS_PACKAGE_CITOOLS}" == "false" ]; then
  echo "Rust is already up to date (Version: ${LOCAL_VER}). No upgrade needed."
  echo "Use --force to override."
  exit 0
fi

# Setup filenames for download
RUST_MAIN_PKG="rust-${RUST_VERSION}-x86_64-pc-windows-gnu"
RUST_MAIN_ARCH="${RUST_MAIN_PKG}.tar.xz"
RUST_STD_LINUX_PKG="rust-std-${RUST_VERSION}-x86_64-unknown-linux-gnu"
RUST_STD_LINUX_ARCH="${RUST_STD_LINUX_PKG}.tar.xz"

# Unified bundle target name
FINAL_BUNDLE_NAME="rust-custom-${RUST_VERSION}-x86_64-pc-windows-gnu.tar.xz"
FINAL_BUNDLE_PATH="${BUILD_DIR}/${FINAL_BUNDLE_NAME}"

# Resolve default linter package name once target Rust version is resolved
if [ "${HAS_PACKAGE_CITOOLS}" == "true" ] && [ -z "${PACKAGE_CITOOLS_NAME}" ]; then
  date_str=$(date +%Y%m%d)
  PACKAGE_CITOOLS_NAME="${BUILD_DIR}/rust-linters-${RUST_VERSION}-${date_str}-win-x86_64.tar.xz"
fi

# ----- PHASE 1: BUILD MODE (`--build`) -----
if [ "${RUN_BUILD}" == "true" ]; then
  echo -e "\n========================================================================="
  echo -e "                         RUST WINDOWS BUILD MODE                         "
  echo -e "========================================================================="
  
  # Ensure build directory exists
  mkdir -p "${BUILD_DIR}"

  # 1. Download official compiler package and Linux target std library
  echo -e "\n>> 1. Downloading Rust packages: ${RUST_MAIN_ARCH}, ${RUST_STD_LINUX_ARCH}"
  # Can be overridden via RUST_DOWNLOAD_CACHE_DIR environment variable
  DOWNLOAD_CACHE_DIR=$(to_unix_path "${RUST_DOWNLOAD_CACHE_DIR:-${SYS_TMP_DIR}/devops/downloads}")
  mkdir -p "${DOWNLOAD_CACHE_DIR}"
  
  ORIG_PWD=$(pwd)
  cd "${DOWNLOAD_CACHE_DIR}"
  
  curl -sSfL --parallel -C - -O "${RUST_URL_BASE}/${RUST_MAIN_ARCH}" \
             -C - -O "${RUST_URL_BASE}/${RUST_STD_LINUX_ARCH}"
  
  if [ ! -s "${RUST_MAIN_ARCH}" ] || [ ! -s "${RUST_STD_LINUX_ARCH}" ]; then
    echo "*** ERROR04: Failed to download Rust installation packages." && exit 4
  fi
  
  cd "${ORIG_PWD}"
 
  # 2. Extract into staging area
  echo -e "\n>> 2. Extracting package components..."
  STAGING_DIR=$(mktemp -d -p "${TEMP_WORKSPACE}" rust-stage-XXXXXX)
  tar --force-local -I "${XZ_OPTS}" -xf "${DOWNLOAD_CACHE_DIR}/${RUST_MAIN_ARCH}" -C "${STAGING_DIR}" &
  pid1=$!
  tar --force-local -I "${XZ_OPTS}" -xf "${DOWNLOAD_CACHE_DIR}/${RUST_STD_LINUX_ARCH}" -C "${STAGING_DIR}" &
  pid2=$!
  wait $pid1 $pid2
 
  EXTRACTED_ROOT="${STAGING_DIR}/${RUST_MAIN_PKG}"
 
  # 3. Create sandboxed bootstrapper folder
  echo -e "\n>> 3. Creating bootstrapped compilation sandbox..."
  BOOTSTRAP_BIN_DIR=$(mktemp -d -p "${TEMP_WORKSPACE}" rust-boot-XXXXXX)
  
  # Determine if we can use hard links to speed up copying (highly recommended on Windows/NTFS)
  CP_CMD="cp -rlf"
  if ! ln "${EXTRACTED_ROOT}/cargo/bin/cargo.exe" "${BOOTSTRAP_BIN_DIR}/test_link.exe" &>/dev/null; then
    CP_CMD="cp -rf"
  else
    safe_delete "${BOOTSTRAP_BIN_DIR}/test_link.exe"
  fi
  echo "   Sandbox copy method: ${CP_CMD}"

  # Copy all component contents from host and Linux std target package to bootstrap bin
  for comp_path in "${EXTRACTED_ROOT}"/*/; do
    if [ -d "${comp_path}" ]; then
      ${CP_CMD} "${comp_path}." "${BOOTSTRAP_BIN_DIR}/"
    fi
  done
  
  if [ -d "${STAGING_DIR}/${RUST_STD_LINUX_PKG}" ]; then
    for comp_path in "${STAGING_DIR}/${RUST_STD_LINUX_PKG}"/*/; do
      if [ -d "${comp_path}" ]; then
        ${CP_CMD} "${comp_path}." "${BOOTSTRAP_BIN_DIR}/"
      fi
    done
  fi

  # Replace the broken LLD wrapper inside the bootstrapped sandbox with the real linker binary
  sandbox_wrapper="${BOOTSTRAP_BIN_DIR}/lib/rustlib/x86_64-pc-windows-gnu/bin/gcc-ld/ld.lld.exe"
  sandbox_real="${BOOTSTRAP_BIN_DIR}/lib/rustlib/x86_64-pc-windows-gnu/bin/rust-lld.exe"
  if [ -f "${sandbox_real}" ] && [ -f "${sandbox_wrapper}" ]; then
    echo "   [+] Overwriting LLD wrapper in sandbox with real linker binary..."
    rm -f "${sandbox_wrapper}"
    cp "${sandbox_real}" "${sandbox_wrapper}"
  fi

  # 4. Resolve and configure C compiler path
  echo -e "\n>> 4. Resolving C-Compiler..."
  CC_PATH=$(resolve_cc)
  
  if [ -z "${CC_PATH}" ]; then
    # Fallback to the bundled MinGW compiler in our bootstrap sandbox
    BUNDLED_GCC_PATH="${BOOTSTRAP_BIN_DIR}/lib/rustlib/x86_64-pc-windows-gnu/bin/self-contained/x86_64-w64-mingw32-gcc.exe"
    if [ -f "${BUNDLED_GCC_PATH}" ]; then
      echo "  Using bundled fallback MinGW C Compiler: $(to_mixed_path "${BUNDLED_GCC_PATH}")"
      CC_PATH="${BUNDLED_GCC_PATH}"
    else
      echo "*** ERROR14: No C compiler detected, and bundled fallback is missing." && exit 14
    fi
  else
    echo "  Using C Compiler: $(to_mixed_path "${CC_PATH}")"
  fi

  # Prepend the bootstrapped rustc/cargo to path so cargo is invoked from our sandbox
  ORIGINAL_PATH="${PATH}"
  cc_dir=""
  [ -n "${CC_PATH:-}" ] && cc_dir=$(dirname "${CC_PATH}")
  export PATH="${BOOTSTRAP_BIN_DIR}/bin:${cc_dir}:${PATH}"
  
  # Setup compiler variables for cargo build-scripts to compile C dependencies
  # Use Windows-style paths since cargo.exe and rustc.exe are native Windows binaries
  configure_compiler_env "${CC_PATH}"

  RUSTC=$(to_win_path "${BOOTSTRAP_BIN_DIR}/bin/rustc.exe")
  export RUSTC

  # 5. Compile linters / cargo tools in the sandbox
  install_linters "${BOOTSTRAP_BIN_DIR}"

  # 6. Package everything into a custom unified archive
  echo -e "\n>> 6. Packaging unified custom Rust + linters toolchain package..."
  
  # Re-arrange the target into standard unified format
  # Staging structure in temporary staging folder
  PACKAGE_STAGING=$(mktemp -d -p "${TEMP_WORKSPACE}" rust-pkg-stage-XXXXXX)
  mkdir -p "${PACKAGE_STAGING}/bin"
  mkdir -p "${PACKAGE_STAGING}/lib"
  mkdir -p "${PACKAGE_STAGING}/share"
  mkdir -p "${PACKAGE_STAGING}/etc"
  mkdir -p "${PACKAGE_STAGING}/libexec"

  # Move standard and built components from our bootstrap directory
  ${CP_CMD} "${BOOTSTRAP_BIN_DIR}/bin"/* "${PACKAGE_STAGING}/bin/"
  ${CP_CMD} "${BOOTSTRAP_BIN_DIR}/lib"/* "${PACKAGE_STAGING}/lib/"
  [ -d "${BOOTSTRAP_BIN_DIR}/share" ] && ${CP_CMD} "${BOOTSTRAP_BIN_DIR}/share"/* "${PACKAGE_STAGING}/share/"
  [ -d "${BOOTSTRAP_BIN_DIR}/etc" ] && ${CP_CMD} "${BOOTSTRAP_BIN_DIR}/etc"/* "${PACKAGE_STAGING}/etc/"
  [ -d "${BOOTSTRAP_BIN_DIR}/libexec" ] && ${CP_CMD} "${BOOTSTRAP_BIN_DIR}/libexec"/* "${PACKAGE_STAGING}/libexec/"

  # Create the component manifest registry manually
  # This matches the names of folders in the original package plus the extra linters
  MANIFEST_DIR="${PACKAGE_STAGING}/lib/rustlib"
  mkdir -p "${MANIFEST_DIR}"
  
  # List all standard components copied from original packages
  register_manifest_components "${EXTRACTED_ROOT}" "${MANIFEST_DIR}/components"
  
  if [ -d "${STAGING_DIR}/${RUST_STD_LINUX_PKG}" ]; then
    register_manifest_components "${STAGING_DIR}/${RUST_STD_LINUX_PKG}" "${MANIFEST_DIR}/components"
  fi
  
  # Also append the custom linters component name
  echo "rust-linters-custom" >> "${MANIFEST_DIR}/components"

  # If packaging of linters is requested, package them from BOOTSTRAP_BIN_DIR before it is cleaned up
  if [ "${HAS_PACKAGE_CITOOLS}" == "true" ]; then
    package_linters "${BOOTSTRAP_BIN_DIR}" "${PACKAGE_CITOOLS_NAME}"
  fi

  # Compile package
  tar --force-local -C "${PACKAGE_STAGING}" -I "${XZ_OPTS}" -cf "${FINAL_BUNDLE_PATH}" .
  
  # Clean up build staging areas (do NOT delete TEMP_WORKSPACE yet, let trap handle it or keep for deploy)
  export PATH="${ORIGINAL_PATH}"
  safe_delete "${PACKAGE_STAGING}" "${BOOTSTRAP_BIN_DIR}" "${STAGING_DIR}"

  echo -e "\n>> Build succeeded!"
  echo "   Custom Package Archive: $(to_mixed_path "${FINAL_BUNDLE_PATH}")"
fi

# ----- PHASE 2: DEPLOY MODE (`--deploy`) -----
if [ "${RUN_DEPLOY}" == "true" ]; then
  echo -e "\n========================================================================="
  echo -e "                        RUST WINDOWS DEPLOY MODE                         "
  echo -e "========================================================================="

  # 1. Resolve archive path
  ACTIVE_ARCHIVE=""
  if [ -n "${ARCHIVE_PATH}" ]; then
    ACTIVE_ARCHIVE="${ARCHIVE_PATH}"
  else
    ACTIVE_ARCHIVE="${FINAL_BUNDLE_PATH}"
  fi

  if [ ! -f "${ACTIVE_ARCHIVE}" ]; then
    echo "*** ERROR04: Archive package [$(to_mixed_path "${ACTIVE_ARCHIVE}")] not found. Ensure Build stage runs first."
    exit 4
  fi

  # 2. Pre-flight disk space and path check
  echo ">> 1. Verifying target directory: $(to_mixed_path "${TARGET_DIR}")"
  mkdir -p "${TARGET_DIR}"
  
  if [ ! -w "${TARGET_DIR}" ]; then
    echo "*** ERROR03: Target installation directory [$(to_mixed_path "${TARGET_DIR}")] is not writable."
    exit 3
  fi

  # Disk space check (ensure at least 1GB of free space)
  if command -v df &>/dev/null && command -v awk &>/dev/null; then
    FREE_KB=$(df -P "${TARGET_DIR}" 2>/dev/null | tail -1 | awk '{print $4}') || true
    if [[ "${FREE_KB}" =~ ^[0-9]+$ ]] && [ "${FREE_KB}" -lt 1048576 ]; then
      echo ""
      printf "*** ERROR08: Insufficient disk space on %s. At least 1GB of free space is required (found %sMB).\n" "$(to_mixed_path "${TARGET_DIR}")" "$((FREE_KB / 1024))"
      exit 8
    fi
  fi

  # 3. Extract and stage toolchain files in a temporary location
  echo -e "\n>> 2. Extracting toolchain files to staging area..."
  DEPLOY_STAGING=$(mktemp -d -p "${TEMP_WORKSPACE}" rust-deploy-stage-XXXXXX)
  
  if ! tar --force-local -I "${XZ_OPTS}" -xf "${ACTIVE_ARCHIVE}" -C "${DEPLOY_STAGING}"; then
    echo "*** ERROR16: Failed to extract toolchain archive."
    safe_delete "${DEPLOY_STAGING}"
    exit 16
  fi

  # Apply core components filtering in the staging directory if requested
  if [ "${CORE_COMPONENTS}" == "true" ]; then
    echo "   Filtering core compiler components..."
    # Strip linters and optional tools
    opt_tools=()
    for tool in "${GLOBAL_BUILTIN_TOOLS[@]}" "${GLOBAL_CARGO_TOOLS[@]}"; do
      opt_tools+=("${tool}.exe")
    done
    for tool in "${opt_tools[@]}"; do
      safe_delete "${DEPLOY_STAGING}/bin/${tool}"
    done

    # Delete analysis files and preview linker
    safe_delete "${DEPLOY_STAGING}/lib/rustlib/x86_64-pc-windows-gnu/analysis" \
                "${DEPLOY_STAGING}/lib/rustlib/x86_64-unknown-linux-gnu/analysis" \
                "${DEPLOY_STAGING}/bin/llvm-bitcode-linker.exe"

    # Filter the components manifest registry
    COMP_FILE="${DEPLOY_STAGING}/lib/rustlib/components"
    if [ -f "${COMP_FILE}" ]; then
      temp_comp_file=$(mktemp -p "${TEMP_WORKSPACE}" comp-filter-XXXXXX)
      regex_pattern="^($(IFS='|'; echo "${GLOBAL_EXCLUDE_COMPONENTS[*]}"))$"
      grep -vE "${regex_pattern}" "${COMP_FILE}" > "${temp_comp_file}" || true
      mv "${temp_comp_file}" "${COMP_FILE}"
    fi
  fi

  # 4. Swap and apply new installation atomically
  echo -e "\n>> 3. Deploying toolchain files to target..."
  if [ -x "${TARGET_DIR}/bin/rustc.exe" ]; then
    # Perform clean sweep of primary folders to prevent orphans
    safe_delete "${TARGET_DIR}/bin" "${TARGET_DIR}/lib" "${TARGET_DIR}/share" "${TARGET_DIR}/etc" "${TARGET_DIR}/libexec"
  fi

  # Move folders from staging area to target
  mkdir -p "${TARGET_DIR}"
  for dir in bin lib share etc libexec; do
    if [ -d "${DEPLOY_STAGING}/${dir}" ]; then
      mv "${DEPLOY_STAGING}/${dir}" "${TARGET_DIR}/" 2>/dev/null || {
        cp -rf "${DEPLOY_STAGING}/${dir}" "${TARGET_DIR}/"
      }
    fi
  done

  # Clean up staging area
  safe_delete "${DEPLOY_STAGING}"

  # Generate default Cargo config.toml to enable rust-lld for cross-compilation
  mkdir -p "${TARGET_DIR}/.cargo"
  config_file="${TARGET_DIR}/.cargo/config.toml"
  if [ ! -f "${config_file}" ]; then
    cat <<EOF > "${config_file}"
[target.x86_64-unknown-linux-gnu]
linker = "rust-lld"
EOF
    echo "   Default Cargo config created to enable rust-lld linker for Linux cross-compilation."
  elif ! grep -q "\[target.x86_64-unknown-linux-gnu\]" "${config_file}" 2>/dev/null; then
    cat <<EOF >> "${config_file}"

[target.x86_64-unknown-linux-gnu]
linker = "rust-lld"
EOF
    echo "   Cargo config updated to enable rust-lld linker for Linux cross-compilation."
  fi

  # 5. Generate Environment Setup
  echo -e "\n>> 4. Configuring environment options..."
  RUST_BIN_WIN=$(to_win_path "${TARGET_DIR}/bin")
  
  if [ "${PATH_UPDATE_MODE}" == "user" ]; then
    echo "   Updating User Environment PATH..."
    if update_windows_path "User" "${RUST_BIN_WIN}"; then
      echo "   PATH updated persistently in User Environment registry."
    else
      echo "   PATH already exists in User Environment registry."
    fi

  elif [ "${PATH_UPDATE_MODE}" == "system" ]; then
    echo "   Updating System Environment PATH (requires Admin)..."
    if update_windows_path "Machine" "${RUST_BIN_WIN}"; then
      echo "   PATH updated persistently in System Environment registry."
    else
      echo "   PATH already exists in System Environment registry."
    fi

  elif [ "${PATH_UPDATE_MODE}" == "script" ]; then
    echo "   Generating setup shims in target folder..."
    
    # Unix source file
    cat <<EOF > "${TARGET_DIR}/env.sh"
# Source this file to add Rust to your Cygwin/MSYS2 path
export PATH="\$(cygpath -u '${RUST_BIN_WIN}'):\${PATH}"
export CARGO_HOME="\$(cygpath -u '$(to_win_path "${TARGET_DIR}/.cargo")')"
EOF
    chmod +x "${TARGET_DIR}/env.sh"

    # Batch file for CMD/PowerShell
    cat <<EOF > "${TARGET_DIR}/env.bat"
@echo off
rem Run this file to add Rust to your session path
set "PATH=${RUST_BIN_WIN};%PATH%"
set "CARGO_HOME=$(to_win_path "${TARGET_DIR}/.cargo")"
EOF
    echo "   Scripts created: [env.sh] and [env.bat] under $(to_mixed_path "${TARGET_DIR}")."
  fi

  # 6. Verification
  echo -e "\n>> Deployment Complete!"
  echo -e "   Rust compiler version: $("${TARGET_DIR}/bin/rustc.exe" --version | tr -d '\r')\n"
  
  # Print environment guidance
  echo "========================================================================="
  echo "                  RUST ENVIRONMENT VARIABLES CONFIGURATION               "
  echo "========================================================================="
  echo " To configure Rust globally on this machine, add the following variables:"
  echo ""
  echo " 1. User Environment Variables (Recommended - no Admin required):"
  echo "    [PATH]        -> Add \"${RUST_BIN_WIN}\""
  echo "    [CARGO_HOME]  -> \"$(to_win_path "${TARGET_DIR}/.cargo")\""
  echo ""
  echo " 2. System Environment Variables (Global - Administrator required):"
  echo "    [PATH]        -> Add \"${RUST_BIN_WIN}\""
  echo "    [CARGO_HOME]  -> \"$(to_win_path "${TARGET_DIR}/.cargo")\""
  echo "========================================================================="
  echo ""
  
  if [ -n "${LINTERS_ARCHIVE}" ]; then
    install_linters "${TARGET_DIR}"
  fi
fi

# ----- STANDALONE LINTERS & CITOOLS PACKAGING MODE -----
if [ "${RUN_BUILD}" == "false" ] && [ "${RUN_DEPLOY}" == "false" ]; then
  if [ "${HAS_LINTERS}" == "true" ]; then
    install_linters "${TARGET_DIR}"
  fi
  
  if [ "${HAS_PACKAGE_CITOOLS}" == "true" ]; then
    package_linters "${TARGET_DIR}" "${PACKAGE_CITOOLS_NAME}"
  fi
fi

exit 0
