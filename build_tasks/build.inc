#!/bin/bash
# ==============================================================================
#  Central Build & Toolchain Configuration Include
#  File      : build.inc
#  Version   : 2.0.0
#  Date      : 2026-10-22
#  Author    : Critical Systems / XDG
# ==============================================================================
#  Objective:
#    Provides a centralized, single-source-of-truth configuration library and
#    shared utility engine sourced by both the multi-module orchestrator
#    (build_orchestrate.sh) and the individual module compiler engine (build_go.sh).
#
#  Core Components:
#    1. Granular Exit Codes: Standardized numeric codes for automated triage.
#    2. Host OS Detection: Automatic detection of Linux vs. Windows (Cygwin/MSYS2).
#    3. Corporate & Cryptographic Defaults: Maintainer, corporate URL, signing key
#       paths, and mandatory key generation parameters.
#    4. Workspace, Directory & Toolchain Defaults: Standard relative output paths
#       (../bin, ../distrib), entrypoint scripts, and Windows GCC search paths.
#    5. Application Metadata Defaults: Fallback definitions for build.json fields.
#    6. Template Sync & Git AutoSync Defaults: Configuration file paths and messages.
#    7. Packaging & Security Exclusions: Strict file exclusion filters for archives.
#    8. Artifact Cleaning & Temp Directory Tracking: Safe lifecycle cleaners.
#    9. Structured NDJSON Audit Logging: Machine-readable audit trails.
#   10. ANSI Colored Logging Primitives: Human-readable terminal telemetry.
#   11. Path Normalizers: Windows/Cygwin/MSYS2 path conversions.
#   12. Multi-Engine JSON Parser: Fallback chain (jq -> python3 -> python -> awk).
#   13. Packaging Sanitizers: RPM spec and Debian control field formatters.
#   14. SSH Code Signing Engine: Ed25519 key generation and path resolution.
#
#  Functionality & Data Flows:
#    - Sourced at startup by build_orchestrate.sh and build_go.sh via dynamic SCRIPT_DIR.
#    - Exports shared variables, environment variables, and helper functions.
#    - Input: Parent script configuration, CLI flags, build.json metadata.
#    - Output: Normalized paths, temporary stage folders, NDJSON log records,
#      cryptographic keys, sanitized control/spec strings.
#
#  Test Strategy Explanation:
#    - Standardized Diagnostic Exit Codes: Defines EXIT_TEST (6) and EXIT_AUDIT (5)
#      ensuring uniform CI/CD telemetry and automated test failure isolation across
#      both single-module builds (build_go.sh) and multi-module runs (build_orchestrate.sh).
#    - Safe Test Environment Isolation: Provides temporary directory tracking
#      primitives (make_temp_dir, cleanup_tracked_temp_dirs) to isolate intermediate
#      test artifacts and guarantee leak-free cleanup upon test completion or abort.
# ==============================================================================
# shellcheck disable=SC2034

# ------------------------------------------------------------------------------
# 1. Diagnostic Granular Exit Codes
# ------------------------------------------------------------------------------
export EXIT_SUCCESS=0
export EXIT_GENERAL=1
export EXIT_USAGE=2
export EXIT_CONFIG=3
export EXIT_DEPENDENCY=4
export EXIT_AUDIT=5
export EXIT_TEST=6
export EXIT_COMPILE=7
export EXIT_PACKAGE=8
export EXIT_SYNC=9

# ------------------------------------------------------------------------------
# 2. Host Operating System Detection
# ------------------------------------------------------------------------------
# Function: detect_host_os
# Objective: Determines whether the script is running under Linux or Windows
#            (native Windows_NT, Cygwin, MinGW, or MSYS2 environment).
# Outputs: Echoes "WIN" or "LINUX" to stdout.
detect_host_os() {
  if [ "${OS:-}" == "Windows_NT" ]; then
    echo "WIN"
    return
  fi
  case "$(uname -s 2>/dev/null)" in
    CYGWIN*|MINGW*|MSYS*)
      echo "WIN"
      ;;
    *)
      echo "LINUX"
      ;;
  esac
}
HOST_OS="$(detect_host_os)"
export HOST_OS

# ------------------------------------------------------------------------------
# 3. Corporate, Maintainer & Cryptographic Defaults
# ------------------------------------------------------------------------------
export DEFAULT_MAINTAINER="Mis Center <support@criticalsys.net>"
export DEFAULT_URL="https://criticalsys.net"
export DEFAULT_IDENTITY="mis@criticalsys.net"
export DEFAULT_COMMENT_PREFIX="Critical Systems Release Signing"
export DEFAULT_SIGN_KEY="${HOME}/.ssh/signing/release_key"

# Concurrency defaults
DEFAULT_PARALLEL_JOBS="$(nproc 2>/dev/null || echo 4)"
export DEFAULT_PARALLEL_JOBS

# ------------------------------------------------------------------------------
# 4. Workspace, Directory & Toolchain Search Defaults
# ------------------------------------------------------------------------------
# Resolve Code Home (3 levels above private/devops/build_tasks)
_BUILD_INC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
CODE_HOME="$(cd "${_BUILD_INC_DIR}/../../.." &> /dev/null && pwd)"
export CODE_HOME
export BUILD_HOME="${CODE_HOME}"
export WORKSPACE_ROOT="${CODE_HOME}"

export DEFAULT_CODE_BASE="private"
export DEFAULT_BIN_DIR="$(cd "${CODE_HOME}/../bin" 2>/dev/null && pwd || echo "${CODE_HOME}/../bin")"
export DEFAULT_DIST_DIR="$(cd "${CODE_HOME}/../distrib" 2>/dev/null && pwd || echo "${CODE_HOME}/../distrib")"
export DEFAULT_BUILD_GO_SCRIPT="build_go.sh"
CODE_BASE="${DEFAULT_CODE_BASE}"
CODE_EXCLUDES=("devops")

# Windows host toolchain search paths
DEFAULT_MINGW_SEARCH_PATHS=(
  "d:/dev/mingw64/bin"
  "c:/msys64/mingw64/bin"
)
DEFAULT_GIT_SEARCH_PATHS=(
  "d:/dev/git/bin"
  "c:/Program Files/Git/bin"
)

# ------------------------------------------------------------------------------
# 5. Application & Packaging Metadata Defaults (build.json fallbacks)
# ------------------------------------------------------------------------------
export DEFAULT_CONFIG_FILE="build.json"
export DEFAULT_VERSION="0.1.0"
export DEFAULT_RELEASE="1"
export DEFAULT_CHANNEL="xg"
export DEFAULT_ENTRYPOINT="."
export DEFAULT_VERSION_PKG="main.version"
export DEFAULT_BUILD_PKG=""
export DEFAULT_LICENSE="MIT"
export DEFAULT_SECTION="utils"
export DEFAULT_PRIORITY="optional"
export DEFAULT_INSTALL_PATH="/usr/bin"
export DEFAULT_OS_VER="el9"
export DEFAULT_ARCH="amd64"
export DEFAULT_SUMMARY_SUFFIX="binary"
export DEFAULT_DESC_SUFFIX="command-line application written in Go."

# Go Toolchain & Compression Environment Defaults
export DEFAULT_GOPROXY="https://proxy.golang.org,direct"
export DEFAULT_XZ_OPT="-T0"
export DEFAULT_GO_LDFLAGS="-s -w"
export DEFAULT_LINUX_EXTRA_FLAGS="-buildmode=pie"

# Standard Documentation Files Included in Release Packages
DEFAULT_DOC_FILES=(
  "LICENSE"
  "README.md"
  "CHANGELOG.md"
)

# ------------------------------------------------------------------------------
# 6. Template Synchronization & Git Management Defaults (build_orchestrate.sh)
# ------------------------------------------------------------------------------
export DEFAULT_TEMPLATE_GITIGNORE="${CODE_HOME}/TMPL.gitignore"
export DEFAULT_TEMPLATE_SECURITY="${CODE_HOME}/SECURITY.md"
export DEFAULT_TEMPLATE_LICENSE="${CODE_HOME}/LICENSE"
export DEFAULT_GIT_AUTOSYNC_SCRIPT="${CODE_HOME}/private/devops/git_repomgr/git_autosync.sh"
export DEFAULT_GIT_SYNC_MESSAGE="Module Updates"

# ------------------------------------------------------------------------------
# 7. Packaging & Source Security Policy
# ------------------------------------------------------------------------------
# Strict exclusion patterns for source archives to prevent leakage of Git
# metadata, compilation binaries, tokens, private keys, or environment files.
DEFAULT_SOURCE_EXCLUDES=(
  "*.git*"
  "*bin/*"
  "*distrib/*"
  "*.token"
  ".env*"
  "*.key"
  "*.pem"
  "*.pfx"
  "*.crt"
  "*.local*"
  "*.tmp*"
  "*.bak"
  "*.log"
  "*.swp"
  "*~"
)

# ------------------------------------------------------------------------------
# 8. Artifact Cleaners & Temp Directory Tracking
# ------------------------------------------------------------------------------
# Function: clean_workspace_artifacts
# Objective: Purges all compiled binaries and distribution archives across the workspace.
# Arguments:
#   $1 - Binary directory path (optional, defaults to DEFAULT_BIN_DIR)
#   $2 - Distribution directory path (optional, defaults to DEFAULT_DIST_DIR)
clean_workspace_artifacts() {
  local bin_dir="${1:-${DEFAULT_BIN_DIR}}"
  local dist_dir="${2:-${DEFAULT_DIST_DIR}}"

  log_info "Cleaning workspace artifacts in '${bin_dir}' and '${dist_dir}'..."
  if [ -d "${bin_dir}" ]; then
    rm -rf "${bin_dir:?}"/* 2>/dev/null || true
    log_success "Cleaned binary directory: ${bin_dir}"
  fi
  mkdir -p "${bin_dir}" 2>/dev/null || true
  if [ -d "${dist_dir}" ]; then
    rm -rf "${dist_dir:?}"/* 2>/dev/null || true
    log_success "Cleaned distribution directory: ${dist_dir}"
  fi
  mkdir -p "${dist_dir}" 2>/dev/null || true
}

# Function: clean_module_artifacts
# Objective: Safely purges only the built artifacts belonging to a specific module,
#            leaving other modules' compiled outputs intact.
# Arguments:
#   $1 - Module name (application name)
#   $2 - Binary directory path (optional)
#   $3 - Distribution directory path (optional)
clean_module_artifacts() {
  local app_name="${1:-}"
  local bin_dir="${2:-${DEFAULT_BIN_DIR}}"
  local dist_dir="${3:-${DEFAULT_DIST_DIR}}"

  if [ -z "${app_name}" ]; then
    clean_workspace_artifacts "${bin_dir}" "${dist_dir}"
    return
  fi

  log_info "Cleaning artifacts for module '${app_name}'..."
  if [ -d "${bin_dir}" ]; then
    rm -f "${bin_dir}/${app_name}" "${bin_dir}/${app_name}.exe" "${bin_dir}/${app_name}.tmp."* 2>/dev/null || true
    log_success "Cleaned binary artifacts for '${app_name}' in: ${bin_dir}"
  fi
  if [ -d "${dist_dir}" ]; then
    rm -f "${dist_dir}/${app_name}-"* 2>/dev/null || true
    log_success "Cleaned distribution artifacts for '${app_name}' in: ${dist_dir}"
  fi
}

TRACKED_TEMP_DIRS=()

# Function: make_temp_dir
# Objective: Creates a temporary directory with guaranteed cleanup registration.
# Arguments:
#   $1 - Directory name prefix (optional, defaults to "tmp_build")
# Outputs: Echoes the absolute path of the created temporary directory.
make_temp_dir() {
  local prefix="${1:-tmp_build}"
  local temp_dir
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX")"
  TRACKED_TEMP_DIRS+=("${temp_dir}")
  echo "${temp_dir}"
}

# Function: cleanup_tracked_temp_dirs
# Objective: Recursively removes all tracked temporary directories registered during execution.
cleanup_tracked_temp_dirs() {
  if [ ${#TRACKED_TEMP_DIRS[@]} -gt 0 ]; then
    for d in "${TRACKED_TEMP_DIRS[@]}"; do
      [ -d "${d}" ] && rm -rf "${d}" 2>/dev/null || true
    done
  fi
}

# ------------------------------------------------------------------------------
# 9. NDJSON Audit Logging & Escaping Helpers
# ------------------------------------------------------------------------------
NDJSON_LOG_FILE=""

# Function: json_escape
# Objective: Sanitizes raw strings for RFC 8259 JSON embedding (escapes backslashes,
#            quotes, and replaces newlines/carriage returns/tabs with spaces).
# Arguments:
#   $1 - Raw text string
# Outputs: Prints escaped text string to stdout.
json_escape() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="$(printf '%s' "${s}" | tr '\n' ' ' | tr '\r' ' ' | tr '\t' ' ')"
  printf '%s' "${s}"
}

# Function: log_ndjson
# Objective: Appends structured NDJSON audit entries to the file defined by NDJSON_LOG_FILE.
# Arguments:
#   $1 - Severity level (INFO, SUCCESS, WARN, ERROR)
#   $2 - Event name (e.g., "log", "start", "finish", "abort")
#   $3 - Log message text
#   $4 - Optional extra JSON details object (e.g., '{"exit_code":0}')
log_ndjson() {
  local level="$1"
  local event="$2"
  local msg="$3"
  local extra="${4:-}"

  [ -z "${NDJSON_LOG_FILE:-}" ] && return 0

  local timestamp
  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")"
  local esc_module esc_level esc_event esc_msg
  esc_module="$(json_escape "${APP_NAME:-$(basename "$(pwd)")}")"
  esc_level="$(json_escape "${level}")"
  esc_event="$(json_escape "${event}")"
  esc_msg="$(json_escape "${msg}")"

  local line="{\"timestamp\":\"${timestamp}\",\"module\":\"${esc_module}\",\"level\":\"${esc_level}\",\"event\":\"${esc_event}\",\"message\":\"${esc_msg}\""
  if [ -n "${extra}" ]; then
    line="${line},\"details\":${extra}}"
  else
    line="${line}}"
  fi

  printf '%s\n' "${line}" >> "${NDJSON_LOG_FILE}" 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# 10. Standardized Logging Helpers (ANSI formatting with NDJSON audit capture)
# ------------------------------------------------------------------------------
COLOR_BLUE="\033[1;34m"
COLOR_GREEN="\033[1;32m"
COLOR_YELLOW="\033[1;33m"
COLOR_RED="\033[1;31m"
COLOR_RESET="\033[0m"

# Function: log_info
# Objective: Prints an informational message to stdout (blue indicator on TTY)
#            and records an INFO entry in the NDJSON audit log.
log_info() {
  if [ -t 1 ]; then
    echo -e "${COLOR_BLUE}>>${COLOR_RESET} $*"
  else
    echo ">> $*"
  fi
  log_ndjson "INFO" "log" "$*"
}

# Function: log_success
# Objective: Prints an operation success message to stdout (green indicator on TTY)
#            and records a SUCCESS entry in the NDJSON audit log.
log_success() {
  if [ -t 1 ]; then
    echo -e "${COLOR_GREEN}   [OK]${COLOR_RESET} $*"
  else
    echo "   [OK] $*"
  fi
  log_ndjson "SUCCESS" "log" "$*"
}

# Function: log_warn
# Objective: Prints a warning message to stderr (yellow indicator on TTY)
#            and records a WARN entry in the NDJSON audit log.
log_warn() {
  if [ -t 2 ]; then
    echo -e "${COLOR_YELLOW}   [WARN]${COLOR_RESET} $*" >&2
  else
    echo "   [WARN] $*" >&2
  fi
  log_ndjson "WARN" "log" "$*"
}

# Function: log_error
# Objective: Prints an error message to stderr (red indicator on TTY)
#            and records an ERROR entry in the NDJSON audit log.
log_error() {
  if [ -t 2 ]; then
    echo -e "${COLOR_RED}   [ERROR]${COLOR_RESET} $*" >&2
  else
    echo "   [ERROR] $*" >&2
  fi
  log_ndjson "ERROR" "log" "$*"
}

# ------------------------------------------------------------------------------
# 11. Path & Environment Normalizers
# ------------------------------------------------------------------------------
# Function: normalize_and_add_to_path
# Objective: Converts Windows drive-letter paths to POSIX paths (using cygpath
#            or bash regex substitution) and prepends them to $PATH.
# Arguments:
#   $1 - Target directory path
# Returns: 0 if directory exists and was added to PATH, 1 otherwise.
normalize_and_add_to_path() {
  local target_dir="${1:-}"
  [ -z "${target_dir}" ] && return 1

  if [ -d "${target_dir}" ]; then
    if command -v cygpath &> /dev/null; then
      target_dir="$(cygpath -u "${target_dir}")"
    elif [[ "${target_dir}" =~ ^([a-zA-Z]):[/\\](.*) ]]; then
      target_dir="/${BASH_REMATCH[1],,}/${BASH_REMATCH[2]//\\//}"
    fi
    export PATH="${target_dir}:${PATH:-}"
    return 0
  fi
  return 1
}

# ------------------------------------------------------------------------------
# 12. JSON Field Parser
# ------------------------------------------------------------------------------
# Function: parse_json_field
# Objective: Robust multi-engine JSON value extractor with a 4-tier fallback:
#            1. jq (fastest, full JSON parser)
#            2. python3 (standard python JSON library)
#            3. python (python 2/3 fallback)
#            4. awk (pure POSIX regex key-value extraction)
# Arguments:
#   $1 - Path to JSON file
#   $2 - Key name to extract
#   $3 - Default fallback value if key is not found
# Outputs: Prints extracted string value to stdout.
parse_json_field() {
  local json_file="${1:-}"
  local key="${2:-}"
  local default_val="${3:-}"
  local result=""

  if [ ! -f "${json_file}" ]; then
    echo "${default_val}"
    return
  fi

  if command -v jq &> /dev/null; then
    result=$(jq -r ".${key} // empty" "${json_file}" 2>/dev/null || true)
  elif command -v python3 &> /dev/null; then
    result=$(python3 -c "import json, sys; d=json.load(open(sys.argv[1])); v=d.get(sys.argv[2], ''); print(v if v is not None else '')" "${json_file}" "${key}" 2>/dev/null || true)
  elif command -v python &> /dev/null; then
    result=$(python -c "import json, sys; d=json.load(open(sys.argv[1])); v=d.get(sys.argv[2], ''); print(v if v is not None else '')" "${json_file}" "${key}" 2>/dev/null || true)
  else
    result=$(awk -v k="\"$key\"" '
      $0 ~ k {
        sub(/^[^:]*:[[:space:]]*/, "");
        sub(/,[[:space:]]*$/, "");
        sub(/^"/, "");
        sub(/"$/, "");
        print;
        exit;
      }
    ' "${json_file}" 2>/dev/null || true)
  fi

  if [ -n "${result}" ] && [ "${result}" != "null" ]; then
    echo "${result}"
  else
    echo "${default_val}"
  fi
}

# ------------------------------------------------------------------------------
# 13. Packaging Metadata Sanitizers (RPM spec & Debian control compliance)
# ------------------------------------------------------------------------------
# Function: sanitize_rpm_spec_string
# Objective: Escapes percent signs (%) to %% to prevent RPM spec macro expansions.
# Arguments:
#   $1 - Raw string value
# Outputs: Prints sanitized string to stdout.
sanitize_rpm_spec_string() {
  local val="${1:-}"
  echo "${val//%/%%}"
}

# Function: sanitize_deb_description
# Objective: Formats multi-line description text for Debian RFC 822 control file compliance
#            (indents lines with leading spaces, replaces blank lines with ' .').
# Arguments:
#   $1 - Raw description string
# Outputs: Prints formatted multi-line description to stdout.
sanitize_deb_description() {
  echo "$1" | awk '
    {
      if (NF == 0) {
        print " ."
      } else {
        sub(/^[[:space:]]+/, "");
        print " " $0
      }
    }
  '
}

# ------------------------------------------------------------------------------
# 14. SSH Code Signing Key Resolution & Generation Engine
# ------------------------------------------------------------------------------
# Function: resolve_signing_key_path
# Objective: Canonicalizes SSH private key paths by expanding tildes (~),
#            resolving directories to <dir>/release_key, and converting
#            relative paths to absolute paths.
# Arguments:
#   $1 - Key path or directory (optional, defaults to DEFAULT_SIGN_KEY)
# Outputs: Prints resolved canonical key path to stdout.
resolve_signing_key_path() {
  local p="${1:-${DEFAULT_SIGN_KEY}}"
  p="${p/#\~/$HOME}"
  if [ -z "${p}" ]; then
    p="${DEFAULT_SIGN_KEY}"
  elif [ -d "${p}" ] || [[ "${p}" == */ ]] || { [ "$(basename "${p}")" = "signing" ] && [ ! -f "${p}" ]; }; then
    p="${p%/}/release_key"
  fi
  local p_dir
  p_dir="$(dirname "${p}")"
  if [ -d "${p_dir}" ]; then
    local abs_dir
    abs_dir="$(cd "${p_dir}" 2>/dev/null && pwd)"
    if [ "${abs_dir}" = "/" ]; then
      p="/$(basename "${p}")"
    else
      p="${abs_dir}/$(basename "${p}")"
    fi
  fi
  echo "${p}"
}

# Function: generate_signing_key
# Objective: Interactively or autonomously generates an isolated Ed25519 SSH
#            signing key pair with mandatory identity binding and hardened
#            directory/file permissions (0700 dir, 0600 private key, 0644 pub key).
# Arguments:
#   $1 - Target private key path
#   $2 - Mandatory identity email/name (e.g., "mis@criticalsys.net")
#   $3 - Optional comment (defaults to DEFAULT_COMMENT_PREFIX <identity>)
generate_signing_key() {
  local key_path
  key_path="$(resolve_signing_key_path "${1:-${DEFAULT_SIGN_KEY}}")"
  local key_identity="${2:-}"
  local key_comment="${3:-}"

  if [ -z "${key_identity}" ]; then
    log_error "--identity=<id> is MANDATORY when generating a signing key."
    log_error "Example: --genkey --identity=${DEFAULT_IDENTITY}"
    exit "${EXIT_USAGE}"
  fi

  if [ -z "${key_comment}" ]; then
    key_comment="${DEFAULT_COMMENT_PREFIX} <${key_identity}>"
  fi

  if [ -f "${key_path}" ]; then
    log_error "Key file already exists at '${key_path}'. Refusing to overwrite."
    exit "${EXIT_CONFIG}"
  fi

  if ! command -v ssh-keygen &> /dev/null; then
    log_error "ssh-keygen not found. Cannot generate SSH key."
    exit "${EXIT_DEPENDENCY}"
  fi

  local key_dir
  key_dir="$(dirname "${key_path}")"
  mkdir -p "${key_dir}" 2>/dev/null || true
  chmod 700 "${key_dir}" 2>/dev/null || true

  log_info "Generating Ed25519 SSH signing key pair at '${key_path}'..."
  log_info "  Identity : ${key_identity}"
  log_info "  Comment  : ${key_comment}"
  if ! ssh-keygen -t ed25519 -N "" -C "${key_comment}" -f "${key_path}" >/dev/null 2>&1; then
    log_error "ssh-keygen failed to generate key pair."
    exit "${EXIT_GENERAL}"
  fi

  chmod 600 "${key_path}"
  chmod 644 "${key_path}.pub"

  local pub_content
  pub_content="$(cat "${key_path}.pub")"

  echo "================================================================================"
  log_success "SSH Signing Key Pair Created Successfully!"
  echo "  Identity    : ${key_identity}"
  echo "  Comment     : ${key_comment}"
  echo "  Private Key : ${key_path}"
  echo "  Public Key  : ${key_path}.pub"
  echo "--------------------------------------------------------------------------------"
  echo "To configure signature verification, create an 'allowed_signers' file with:"
  echo "  ${key_identity} namespaces=\"file\" ${pub_content}"
  echo ""
  echo "To sign builds with this key, pass:"
  if [ "${key_path}" = "${DEFAULT_SIGN_KEY}" ]; then
    echo "  --sign"
  else
    echo "  --sign=${key_path}"
  fi
  echo "================================================================================"
  exit "${EXIT_SUCCESS}"
}
