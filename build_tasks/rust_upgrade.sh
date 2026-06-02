#!/bin/bash
# -----------------------------------------------------------------------------
#  /usr/src/redhat/SPECS/rust_upgrade.sh
#  v1.0.8xg  2026/06/01  XDG / MIS Center
# -----------------------------------------------------------------------------
#  Purpose:
#    Automates downloading, extracting, and installing specific Rust toolchain
#    versions along with the Windows GNU target standard library.
#    Supports both system-wide and localized directory installs.
#
#  Syntax:
#    rust_upgrade.sh [--version <version> | --auto] [--local] [--force] [--core-components] [--linters [<fqdn>]] [--package-citools [fqdn]] [--log [fqdn]] [--help]
#    rust_upgrade.sh --detect [text|json]
#    rust_upgrade.sh --linters [<fqdn>]
#
#  Examples:
#    - System-wide install (specific version):  rust_upgrade.sh --version 1.96.0
#    - Local prefix & auto-detect stable:        rust_upgrade.sh --auto --local
#    - Force reinstall version:                  rust_upgrade.sh --version 1.96.0 --force
#    - Standalone linter compilation:            rust_upgrade.sh --linters
#    - Standalone linter archive extraction:     rust_upgrade.sh --linters /path/to/archive.tar.xz
#    - Package linters to default archive:       rust_upgrade.sh --package-citools
#    - Redirect all output to append log file:   rust_upgrade.sh --auto --log
#    - Show detection report in JSON format:     rust_upgrade.sh --detect json
#    - Show help menu:                           rust_upgrade.sh --help
# -----------------------------------------------------------------------------

# ----- ENVIRONMENT AND CONFIGURATION -----
RUST_ARCH=$(uname -m)

# Optional toolchain components that can be skipped via --core-components or audited in --detect
OPTIONAL_COMPONENTS=(
  "rust-docs"
  "rust-docs-json-preview"
  "rust-analysis-${RUST_ARCH}-unknown-linux-gnu"
  "rust-analysis-${RUST_ARCH}-pc-windows-gnu"
  "llvm-bitcode-linker-preview"
)

# Resolve system temporary directory based on priority order: TMPDIR, TMP, TEMP, fallback to /tmp
SYS_TMP_DIR="${TMPDIR:-${TMP:-${TEMP:-/tmp}}}"

# Check if OS_ID or OS_DISTRIB are declared in the environment; otherwise attempt auto-detection
if [ -z "${OS_ID}" ] || [ -z "${OS_DISTRIB}" ]; then
  if [ -f "/etc/os-release" ]; then
    OS_RELEASE_ID=$(grep -E '^ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"'\' 2>/dev/null)
    OS_RELEASE_LIKE=$(grep -E '^ID_LIKE=' /etc/os-release | cut -d'=' -f2 | tr -d '"'\' 2>/dev/null)
    OS_COMBINED_LIKE="${OS_RELEASE_ID} ${OS_RELEASE_LIKE}"
    OS_COMBINED_LIKE="${OS_COMBINED_LIKE,,}"

    if [[ "${OS_COMBINED_LIKE}" =~ (rhel|centos|fedora) ]]; then
      [ -z "${OS_DISTRIB}" ] && OS_DISTRIB="el"
      if [ -z "${OS_ID}" ]; then
        if [ -f "/etc/distrib" ]; then
          OS_ID=$(cat /etc/distrib | sed 's|[a-zA-Z]||g' 2>/dev/null)
        else
          OS_ID=$(grep -E '^VERSION_ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"'\' | cut -d'.' -f1 2>/dev/null)
        fi
      fi
    elif [[ "${OS_COMBINED_LIKE}" =~ (ubuntu|debian|mint) ]]; then
      [ -z "${OS_DISTRIB}" ] && OS_DISTRIB="ubu"
      if [ -z "${OS_ID}" ]; then
        UBUNTU_VER=""
        if [ -f "/etc/upstream-release/lsb-release" ]; then
          UBUNTU_VER=$(grep -E '^DISTRIB_RELEASE=' /etc/upstream-release/lsb-release | cut -d'=' -f2 | tr -d '"'\' 2>/dev/null)
        fi
        if [ -z "${UBUNTU_VER}" ]; then
          UBUNTU_VER=$(grep -E '^VERSION_ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"'\' 2>/dev/null)
        fi
        OS_ID=$(echo "${UBUNTU_VER}" | cut -d'.' -f1 2>/dev/null)
      fi
    fi
  fi

  # General fallback if still unset
  if [ -z "${OS_ID}" ]; then
    if [ -f "/etc/distrib" ]; then
      OS_ID=$(cat /etc/distrib | sed 's|[a-zA-Z]||g' 2>/dev/null)
    elif [ -f "/etc/os-release" ]; then
      OS_ID=$(grep -E '^VERSION_ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"'\' | cut -d'.' -f1 2>/dev/null)
    fi
  fi
  
  if [ -z "${OS_DISTRIB}" ] && [ -n "${OS_ID}" ]; then
    OS_DISTRIB="el"
  fi
fi

if [ -z "${OS_ID}" ] || [ -z "${OS_DISTRIB}" ]; then
  echo -e "\n*** ERROR09: OS_DISTRIB or OS_ID environment variable is not declared."
  exit 9
fi

# Destination directories for LOCAL installations
RUST_HOME="/var/opt/rust"
INSTALL_BASE="/opt/install"
TARGET_PATH="/opt/done"
RUST_PERMS="builder:users"
RUST_LOCAL="/usr/local/bin"
RUSTC_BIN="${RUST_LOCAL}/rustc"

# Official Rust distribution mirror URL
RUST_URL_BASE="https://static.rust-lang.org/dist"

# Variables to track temporary paths for signal-trap cleanup
ABS_RUST_INSTALL_ARCH=""
ABS_RUST_STD_WIN_ARCH=""
ABS_RUST_INSTALL_BASE=""
ABS_RUST_STD_WIN_BASE=""
ABS_TEMP_CARGO_HOME=""

# Cleanup function to purge temporary archives and cache folders on script exit
function cleanup() {
  if [ -n "${ABS_TEMP_CARGO_HOME}" ] && [ -d "${ABS_TEMP_CARGO_HOME}" ]; then
    rm -rf "${ABS_TEMP_CARGO_HOME}"
  fi
  if [ -n "${ABS_RUST_INSTALL_ARCH}" ] && [ -f "${ABS_RUST_INSTALL_ARCH}" ]; then
    rm -f "${ABS_RUST_INSTALL_ARCH}"
  fi
  if [ -n "${ABS_RUST_STD_WIN_ARCH}" ] && [ -f "${ABS_RUST_STD_WIN_ARCH}" ]; then
    rm -f "${ABS_RUST_STD_WIN_ARCH}"
  fi
  if [ -n "${ABS_RUST_INSTALL_BASE}" ] && [ -d "${ABS_RUST_INSTALL_BASE}" ]; then
    rm -rf "${ABS_RUST_INSTALL_BASE}"
  fi
  if [ -n "${ABS_RUST_STD_WIN_BASE}" ] && [ -d "${ABS_RUST_STD_WIN_BASE}" ]; then
    rm -rf "${ABS_RUST_STD_WIN_BASE}"
  fi
}

# Trap termination signals to ensure cleanup of temporary objects
trap cleanup EXIT INT TERM HUP


# Helper function to display script usage
function show_help() {
  echo "Usage: $(basename "$0") [--version <version> | --auto | --detect [text|json] | --linters [<fqdn>]] [--package-citools [fqdn]] [--local] [--force] [--core-components] [--log [fqdn]] [--help]"
  echo ""
  echo "Options:"
  echo "  --version <version>  Install/upgrade to a specific Rust version (e.g. 1.96.0)."
  echo "  --auto               Auto-detect the latest stable version and upgrade if needed."
  echo "  --detect [text|json] Detect existing Rust installation status, location, and components."
  echo "                         text  (default) Human-readable formatted report."
  echo "                         json           Machine-readable JSON output."
  echo "  --local              Install to a prefix-isolated path (/var/opt/rust) and symlink."
  echo "  --force              Force download and installation even if the version is already installed."
  echo "  --core-components    Install only core toolchain components, skipping docs, analysis files, and linkers."
  echo "  --linters [<fqdn>]   Install Rust code quality tools (can be combined with --version/--auto,"
  echo "                       or used standalone to add linters to an existing Rust installation)."
  echo "                       If <fqdn> is specified, checks and extracts precompiled linter binaries"
  echo "                       from the archive instead of compilation. Otherwise compiles them:"
  echo "                         Components : clippy, rustfmt, rust-analyzer"
  echo "                         Security   : cargo-audit, cargo-deny"
  echo "                         Analysis   : cargo-geiger, cargo-machete, cargo-semver-checks"
  echo "                         Coverage   : cargo-tarpaulin"
  echo "                         Testing    : cargo-nextest"
  echo "                         Performance: cargo-bloat, cargo-outdated"
  echo "                         Nightly req: cargo-udeps"
  echo "  --package-citools [fqdn]"
  echo "                       Generate a tar.xz archive of all installed linter binaries"
  echo "                       for deployment. If [fqdn] is omitted, defaults to:"
  echo "                       /opt/done/rust-linters-<version>-<date>-<dist><os_id>-<arch>.tar.xz"
  echo "  --log [fqdn]         Redirect all output (stdout and stderr) to the specified log file in append mode."
  echo "                         If [fqdn] is omitted, defaults to /var/log/rust_upgrade.log."
  echo "  --help, -h           Show this help message and exit."
  echo ""
}

# Determine if help or detect flags are present before enforcing root privileges
IS_INFORMATIONAL="false"
for arg in "$@"; do
  if [ "${arg}" == "--help" ] || [ "${arg}" == "-h" ] || [ "${arg}" == "--detect" ]; then
    IS_INFORMATIONAL="true"
  fi
done

# ----- PREREQUISITES & ROOT CHECK -----
if [ "${IS_INFORMATIONAL}" == "false" ] && [ "$(id -n -u)" != "root" ]; then
  echo -e "\n*** ERROR02: Shell user must be root to install rust."
  exit 2
fi

# If no arguments are provided, default to displaying the help menu
if [ $# -eq 0 ]; then
  show_help
  exit 0
fi

# Initialize argument flags
INSTALL_MODE="SYSTEM"
UPGRADE_MODE=""
RUST_VERSION=""
HAS_VERSION="false"
HAS_AUTO="false"
HAS_DETECT="false"
SHOW_HELP="false"
FORCE_INSTALL="false"
DETECT_FORMAT="text"   # Default output format for --detect
HAS_LINTERS="false"
LINTERS_ARCHIVE=""
HAS_PACKAGE_CITOOLS="false"
PACKAGE_CITOOLS_NAME=""
HAS_CORE_COMPONENTS="false"
HAS_LOG="false"
LOG_FILE=""

# Non-positional argument parser loop
while [ $# -gt 0 ]; do
  case "$1" in
    --version)
      if [ -z "$2" ] || [[ "$2" == -* ]]; then
        echo "ERROR: --version option requires an argument (e.g., 1.96.0)."
        show_help
        exit 1
      fi
      RUST_VERSION="$2"
      HAS_VERSION="true"
      shift 2
      ;;
    --auto)
      HAS_AUTO="true"
      shift
      ;;
    --detect)
      HAS_DETECT="true"
      # Consume optional format argument: text | json
      if [ -n "$2" ] && [[ "$2" != -* ]]; then
        case "$2" in
          text|json)
            DETECT_FORMAT="$2"
            shift
            ;;
          *)
            echo "ERROR: --detect format must be 'text' or 'json' (got '$2')."
            show_help
            exit 1
            ;;
        esac
      fi
      shift
      ;;
    --local)
      INSTALL_MODE="LOCAL"
      shift
      ;;
    --force)
      FORCE_INSTALL="true"
      shift
      ;;
    --linters)
      HAS_LINTERS="true"
      # Consume optional archive file name
      if [ -n "$2" ] && [[ "$2" != -* ]]; then
        LINTERS_ARCHIVE="$2"
        shift 2
      else
        LINTERS_ARCHIVE=""
        shift
      fi
      ;;
    --package-citools)
      HAS_PACKAGE_CITOOLS="true"
      # Consume optional package file name
      if [ -n "$2" ] && [[ "$2" != -* ]]; then
        PACKAGE_CITOOLS_NAME="$2"
        shift 2
      else
        PACKAGE_CITOOLS_NAME=""
        shift
      fi
      ;;
    --core-components)
      HAS_CORE_COMPONENTS="true"
      shift
      ;;
    --log)
      HAS_LOG="true"
      # Consume optional log file name
      if [ -n "$2" ] && [[ "$2" != -* ]]; then
        LOG_FILE="$2"
        shift 2
      else
        LOG_FILE="/var/log/rust_upgrade.log"
        shift
      fi
      ;;
    --help|-h)
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

# If package-citools is requested, automatically enable linter installation
if [ "${HAS_PACKAGE_CITOOLS}" == "true" ]; then
  HAS_LINTERS="true"
fi

# Validate mutually exclusive options and required arguments
if [ "${HAS_DETECT}" == "true" ]; then
  if [ "${HAS_VERSION}" == "true" ] || [ "${HAS_AUTO}" == "true" ] || [ "${INSTALL_MODE}" == "LOCAL" ] || [ "${FORCE_INSTALL}" == "true" ] || [ "${HAS_LINTERS}" == "true" ] || [ "${HAS_CORE_COMPONENTS}" == "true" ]; then
    echo "ERROR: --detect is an exclusive option and cannot be combined with other options."
    show_help
    exit 1
  fi
fi

if [ "${HAS_VERSION}" == "true" ] && [ "${HAS_AUTO}" == "true" ]; then
  echo "ERROR: --version and --auto are mutually exclusive options."
  show_help
  exit 1
fi

if [ "${HAS_VERSION}" == "false" ] && [ "${HAS_AUTO}" == "false" ] && [ "${HAS_DETECT}" == "false" ] && [ "${HAS_LINTERS}" == "false" ]; then
  echo "ERROR: You must specify --version <version>, --auto, --detect, or --linters."
  show_help
  exit 1
fi

# ----- LOG REDIRECTION -----
if [ "${HAS_LOG}" == "true" ]; then
  # Ensure the directory exists
  LOG_DIR=$(dirname "${LOG_FILE}")
  if [ ! -d "${LOG_DIR}" ]; then
    mkdir -p "${LOG_DIR}" || { echo "ERROR: Failed to create log directory: ${LOG_DIR}"; exit 1; }
  fi
  # Redirect stdout and stderr to the log file in append mode
  exec >> "${LOG_FILE}" 2>&1 || { echo "ERROR: Failed to redirect output to log file: ${LOG_FILE}"; exit 1; }
fi

# Execute detection routine if requested and terminate cleanly
if [ "${HAS_DETECT}" == "true" ]; then
  RUSTC_PATH=$(which rustc 2>/dev/null)
  if [ -z "${RUSTC_PATH}" ] && [ -x "${RUSTC_BIN}" ]; then
    RUSTC_PATH="${RUSTC_BIN}"
  fi

  # ---- Gather data regardless of output format ----
  if [ -z "${RUSTC_PATH}" ] || ! [ -x "${RUSTC_PATH}" ]; then
    # No Rust found — emit the appropriate not-found response
    if [ "${DETECT_FORMAT}" == "json" ]; then
      printf '{\n  "status": "not_found",\n  "message": "No active Rust installation detected in PATH or standard location."\n}\n'
    else
      echo -e "\n============================================================================="
      echo -e "                      RUST INSTALLATION DETECTION REPORT                      "
      echo -e "============================================================================="
      echo -e "  Status: No active Rust installation detected in PATH or standard location."
      echo -e "=============================================================================\n"
    fi
    exit 0
  fi

  CARGO_PATH=$(which cargo 2>/dev/null)
  if [ -z "${CARGO_PATH}" ]; then
    CARGO_DIR=$(dirname "${RUSTC_PATH}")
    if [ -x "${CARGO_DIR}/cargo" ]; then
      CARGO_PATH="${CARGO_DIR}/cargo"
    fi
  fi

  RUSTC_VER=$("${RUSTC_PATH}" --version 2>/dev/null)
  CARGO_VER=""
  if [ -n "${CARGO_PATH}" ] && [ -x "${CARGO_PATH}" ]; then
    CARGO_VER=$("${CARGO_PATH}" --version 2>/dev/null)
  fi

  SYSROOT=$("${RUSTC_PATH}" --print sysroot 2>/dev/null)
  HOST_TARGET=$("${RUSTC_PATH}" -vV 2>/dev/null | grep "host:" | cut -d' ' -f2)
  COMPONENTS_FILE="${SYSROOT}/lib/rustlib/components"

  # Collect installed std targets and toolchain components into arrays
  STD_TARGETS=()
  TOOL_COMPONENTS=()
  COMPONENTS_WARNING=""
  if [ -f "${COMPONENTS_FILE}" ]; then
    while IFS= read -r line; do
      if [[ "${line}" == rust-std-* ]]; then
        STD_TARGETS+=("${line#rust-std-}")
      elif [ -n "${line}" ]; then
        TOOL_COMPONENTS+=("${line}")
      fi
    done < "${COMPONENTS_FILE}"
  else
    COMPONENTS_WARNING="Component registry file not found at: ${COMPONENTS_FILE}"
  fi

  # Check status of each code quality/linter tool
  # Sorted alphabetically:
  LINTERS=(
    "cargo-audit"
    "cargo-bloat"
    "cargo-deny"
    "cargo-geiger"
    "cargo-machete"
    "cargo-nextest"
    "cargo-outdated"
    "cargo-semver-checks"
    "cargo-tarpaulin"
    "cargo-udeps"
    "clippy"
    "rust-analyzer"
    "rustfmt"
  )
  LINTER_STATUS=()
  LINTER_VERSION=()
  BIN_DIR=$(dirname "${RUSTC_PATH}")

  # Create a temporary directory to collect results from parallel background jobs
  DETECT_TMP_DIR=$(mktemp -d -p "${SYS_TMP_DIR}" rust-detect-XXXXXX)

  for i in "${!LINTERS[@]}"; do
    linter="${LINTERS[$i]}"
    binary_name="${linter}"
    if [ "${linter}" == "clippy" ]; then
      binary_name="cargo-clippy"
    elif [ "${linter}" == "rustfmt" ]; then
      binary_name="rustfmt"
    fi

    # Check standard PATH first, then toolchain bin directory, then RUST_LOCAL, then RUST_HOME/bin
    resolved_path=""
    if command -v "${binary_name}" &>/dev/null; then
      resolved_path=$(command -v "${binary_name}")
    elif [ -x "${BIN_DIR}/${binary_name}" ]; then
      resolved_path="${BIN_DIR}/${binary_name}"
    elif [ -x "${RUST_LOCAL}/${binary_name}" ]; then
      resolved_path="${RUST_LOCAL}/${binary_name}"
    elif [ -x "${RUST_HOME}/bin/${binary_name}" ]; then
      resolved_path="${RUST_HOME}/bin/${binary_name}"
    fi

    if [ -n "${resolved_path}" ] && [ -x "${resolved_path}" ]; then
      # Run version retrieval in background
      (
        raw_version=""
        if [[ "${binary_name}" == cargo-* ]]; then
          # For cargo tools, run via cargo subcommand to ensure clean execution environment
          subcmd="${binary_name#cargo-}"
          if [ -n "${CARGO_PATH}" ] && [ -x "${CARGO_PATH}" ]; then
            # Prepend the directory of the resolved tool and cargo to PATH so cargo can locate it
            # shellcheck disable=SC2030
            PATH="$(dirname "${resolved_path}"):$(dirname "${CARGO_PATH}"):${PATH}"
            export PATH
            raw_version=$("${CARGO_PATH}" "${subcmd}" --version 2>&1)
          else
            raw_version=$("${resolved_path}" --version 2>&1)
          fi
        else
          raw_version=$("${resolved_path}" --version 2>&1)
        fi
        
        # Take only the first line of output
        raw_version=$(echo "${raw_version}" | head -n 1)

        # Strip leading alphabetic/hyphenated words followed by space (e.g. clippy, rustfmt, cargo-audit, etc.)
        clean_version=$(echo "${raw_version}" | sed -E 's/^([a-zA-Z_-]+[[:space:]]*)+//')
        
        if [ -z "${clean_version}" ]; then
          clean_version="Unknown"
        fi
        
        echo "Installed" > "${DETECT_TMP_DIR}/${i}.status"
        echo "${clean_version}" > "${DETECT_TMP_DIR}/${i}.version"
      ) &
    else
      echo "Not Installed" > "${DETECT_TMP_DIR}/${i}.status"
      echo "-" > "${DETECT_TMP_DIR}/${i}.version"
    fi
  done

  # Wait for all background tasks to complete
  wait

  # Read parallel outputs back into arrays
  for i in "${!LINTERS[@]}"; do
    LINTER_STATUS+=("$(cat "${DETECT_TMP_DIR}/${i}.status")")
    LINTER_VERSION+=("$(cat "${DETECT_TMP_DIR}/${i}.version")")
  done

  # Clean up temporary directory
  rm -rf "${DETECT_TMP_DIR}"

  # Check status of core components that could be excluded via --core-components
  OPT_COMPONENTS_STATUS=()
  for opt_c in "${OPTIONAL_COMPONENTS[@]}"; do
    found="false"
    if [ -z "${COMPONENTS_WARNING}" ]; then
      for c in "${TOOL_COMPONENTS[@]}"; do
        if [ "${c}" == "${opt_c}" ]; then
          found="true"
          break
        fi
      done
    fi

    if [ -n "${COMPONENTS_WARNING}" ]; then
      OPT_COMPONENTS_STATUS+=("Unknown")
    elif [ "${found}" == "true" ]; then
      OPT_COMPONENTS_STATUS+=("Installed")
    else
      OPT_COMPONENTS_STATUS+=("Excluded")
    fi
  done

  # ---- TEXT output (default) ----
  if [ "${DETECT_FORMAT}" == "text" ]; then
    echo -e "\n============================================================================="
    echo -e "                      RUST INSTALLATION DETECTION REPORT                      "
    echo -e "============================================================================="
    echo -e "[1] Core Binaries & Locations"
    echo -e "-----------------------------"
    echo -e "  rustc path:    ${RUSTC_PATH}"
    echo -e "  rustc version: ${RUSTC_VER}"
    echo -e "  cargo path:    ${CARGO_PATH:-Not Found}"
    echo -e "  cargo version: ${CARGO_VER:-Not Found}"
    echo -e "  Sysroot path:  ${SYSROOT}"
    echo -e "  Host target:   ${HOST_TARGET:-Unknown}"
    echo ""

    if [ -n "${COMPONENTS_WARNING}" ]; then
      echo -e "[2] Installed Targets & Components"
      echo -e "----------------------------------"
      echo -e "  Warning: ${COMPONENTS_WARNING}"
    else
      echo -e "[2] Installed Standard Library Targets"
      echo -e "--------------------------------------"
      for t in "${STD_TARGETS[@]}"; do
        echo -e "  - ${t}"
      done
      echo ""

      echo -e "[3] Installed Toolchain Components"
      echo -e "----------------------------------"
      for c in "${TOOL_COMPONENTS[@]}"; do
        echo -e "  - ${c}"
      done
    fi
    echo ""

    echo -e "[4] Switchable Components"
    echo -e "-------------------------"
    printf "  %-42s %s\n" "Component" "Status"
    printf "  %-42s %s\n" "---------" "------"
    for i in "${!OPTIONAL_COMPONENTS[@]}"; do
      printf "  %-42s %s\n" "${OPTIONAL_COMPONENTS[$i]}" "${OPT_COMPONENTS_STATUS[$i]}"
    done
    echo ""

    echo -e "[5] Code Quality & Linter Tools"
    echo -e "-------------------------------"
    # Format as a clean 3-column table
    printf "  %-22s %-15s %s\n" "Tool" "Status" "Version"
    printf "  %-22s %-15s %s\n" "----" "------" "-------"
    for i in "${!LINTERS[@]}"; do
      printf "  %-22s %-15s %s\n" "${LINTERS[$i]}" "${LINTER_STATUS[$i]}" "${LINTER_VERSION[$i]}"
    done

    echo -e "=============================================================================\n"

  # ---- JSON output ----
  else
    # Helper: escape a string for safe JSON embedding
    json_str() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

    printf $'{\n'
    printf $'  "status": "found",\n'
    printf $'  "rustc": {\n'
    printf $'    "path": "%s",\n'    "$(json_str "${RUSTC_PATH}")"
    printf $'    "version": "%s"\n'  "$(json_str "${RUSTC_VER}")"
    printf $'  },\n'
    printf $'  "cargo": {\n'
    printf $'    "path": "%s",\n'    "$(json_str "${CARGO_PATH:-}")"
    printf $'    "version": "%s"\n'  "$(json_str "${CARGO_VER:-}")"
    printf $'  },\n'
    printf $'  "sysroot": "%s",\n'   "$(json_str "${SYSROOT}")"
    printf $'  "host_target": "%s",\n' "$(json_str "${HOST_TARGET:-}")"

    # std targets array
    printf $'  "std_targets": ['
    if [ "${#STD_TARGETS[@]}" -gt 0 ]; then
      printf $'\n'
      for i in "${!STD_TARGETS[@]}"; do
        if [ "${i}" -lt $(( ${#STD_TARGETS[@]} - 1 )) ]; then
          printf $'    "%s",\n' "$(json_str "${STD_TARGETS[${i}]}")"
        else
          printf $'    "%s"\n'  "$(json_str "${STD_TARGETS[${i}]}")"
        fi
      done
      printf $'  ],\n'
    else
      printf $'],\n'
    fi

    # toolchain components array
    printf $'  "toolchain_components": ['
    if [ "${#TOOL_COMPONENTS[@]}" -gt 0 ]; then
      printf $'\n'
      for i in "${!TOOL_COMPONENTS[@]}"; do
        if [ "${i}" -lt $(( ${#TOOL_COMPONENTS[@]} - 1 )) ]; then
          printf $'    "%s",\n' "$(json_str "${TOOL_COMPONENTS[${i}]}")"
        else
          printf $'    "%s"\n'  "$(json_str "${TOOL_COMPONENTS[${i}]}")"
        fi
      done
      printf $'  ]'
    else
      printf $']'
    fi

    # switchable components status
    printf $',\n  "switchable_components": {\n'
    for i in "${!OPTIONAL_COMPONENTS[@]}"; do
      val="unknown"
      if [ "${OPT_COMPONENTS_STATUS[$i]}" == "Excluded" ]; then
        val="excluded"
      elif [ "${OPT_COMPONENTS_STATUS[$i]}" == "Installed" ]; then
        val="installed"
      fi
      if [ "${i}" -lt $(( ${#OPTIONAL_COMPONENTS[@]} - 1 )) ]; then
        printf $'    "%s": "%s",\n' "${OPTIONAL_COMPONENTS[$i]}" "${val}"
      else
        printf $'    "%s": "%s"\n' "${OPTIONAL_COMPONENTS[$i]}" "${val}"
      fi
    done
    printf $'  }'

    # Print linters object (v1 backward-compatible)
    printf $',\n  "linters": {\n'
    for i in "${!LINTERS[@]}"; do
      val="not_installed"
      if [ "${LINTER_STATUS[$i]}" == "Installed" ]; then
        val="installed"
      fi
      if [ "${i}" -lt $(( ${#LINTERS[@]} - 1 )) ]; then
        printf $'    "%s": "%s",\n' "${LINTERS[$i]}" "${val}"
      else
        printf $'    "%s": "%s"\n' "${LINTERS[$i]}" "${val}"
      fi
    done
    printf $'  },\n'

    # Print detailed linter metadata (v2)
    printf $'  "linter_details": {\n'
    for i in "${!LINTERS[@]}"; do
      val="not_installed"
      if [ "${LINTER_STATUS[$i]}" == "Installed" ]; then
        val="installed"
      fi
      printf $'    "%s": {\n' "${LINTERS[$i]}"
      printf $'      "status": "%s",\n' "${val}"
      printf $'      "version": "%s"\n' "$(json_str "${LINTER_VERSION[$i]}")"
      if [ "${i}" -lt $(( ${#LINTERS[@]} - 1 )) ]; then
        printf $'    },\n'
      else
        printf $'    }\n'
      fi
    done
    printf $'  }'

    # Append components warning if registry was missing
    if [ -n "${COMPONENTS_WARNING}" ]; then
      printf $',\n  "components_warning": "%s"\n' "$(json_str "${COMPONENTS_WARNING}")"
    else
      printf $'\n'
    fi
    printf $'}\n'
  fi

  exit 0
fi

# ----- STANDALONE LINTERS MODE SHORT-CIRCUIT -----
# If --linters is the only operational flag, skip version detection and the
# full install pipeline entirely. installLinters() is called after its
# function definition further below, and the script exits.
if [ "${HAS_LINTERS}" == "true" ] && [ "${HAS_VERSION}" == "false" ] && [ "${HAS_AUTO}" == "false" ]; then
  STANDALONE_LINTERS="true"
else
  STANDALONE_LINTERS="false"
fi

# Set the upgrade mode based on verified arguments
if [ "${STANDALONE_LINTERS}" == "false" ]; then
  if [ "${HAS_VERSION}" == "true" ]; then
    UPGRADE_MODE="VERSION"
  else
    UPGRADE_MODE="AUTO"
  fi
fi

# ----- GET LOCAL RUSTC VERSION -----
if [ "${STANDALONE_LINTERS}" == "false" ]; then
  if [ -x "${RUSTC_BIN}" ]; then
    LOCAL_VERSION=$("${RUSTC_BIN}" --version | cut -d' ' -f2)
  else
    LOCAL_VERSION="0.0.0" # Not installed
  fi
fi

# ----- VERSION DETECTION / RESOLUTION -----
if [ "${STANDALONE_LINTERS}" == "false" ] && [ "${UPGRADE_MODE}" == "AUTO" ]; then
  echo -e "\n>> Auto-detecting latest stable Rust version..."

  # Fetch the official Rust stable manifest
  MANIFEST_URL="https://static.rust-lang.org/dist/channel-rust-stable.toml"
  MANIFEST_DATA=$(curl -sSfL "$MANIFEST_URL")

  if [ -z "$MANIFEST_DATA" ]; then
    echo "Error: Failed to fetch the Rust release manifest."
    exit 1
  fi

  # Parse the version string out of the manifest
  LATEST_VERSION=$(echo "$MANIFEST_DATA" | grep -A 2 '\[pkg.rust\]' | grep 'version =' | cut -d'"' -f2 | cut -d' ' -f1)
  RUST_VERSION="${LATEST_VERSION}"
fi

# ----- COMPARE AND VALIDATE VERSIONS -----
if [ "${STANDALONE_LINTERS}" == "false" ]; then
  if [ "${LOCAL_VERSION}" == "${RUST_VERSION}" ]; then
    if [ "${FORCE_INSTALL}" == "true" ]; then
      echo "Rust version ${RUST_VERSION} is already installed, but --force was specified. Proceeding with installation..."
    else
      echo "Rust is up to date (Version: ${LOCAL_VERSION}). No download/upgrade needed."
      echo "Use --force to force reinstall."
      exit 0
    fi
  else
    echo -e "\n>> Rust version mismatch detected. Proceeding with install/upgrade..."
    echo "Local Version:  ${LOCAL_VERSION}"
    echo "Target Version: ${RUST_VERSION}"
    echo "----------------------------------------"
  fi
fi

# Ensure version variable is not blank (only relevant for install modes)
if [ "${STANDALONE_LINTERS}" == "false" ] && [ -z "${RUST_VERSION}" ]; then
  echo -e "\n*** ERROR01: Rust version must be specified or auto-detected."
  exit 1
fi

# Name and archive variables (only populated for install modes)
if [ "${STANDALONE_LINTERS}" == "false" ]; then
  # Name and archive variables for the main Linux Rust package
  RUST_INSTALL_BASE="rust-${RUST_VERSION}-${RUST_ARCH}-unknown-linux-gnu"
  RUST_INSTALL_ARCH="${RUST_INSTALL_BASE}.tar.xz"
 
  # Name and archive variables for the Windows GNU target standard library package
  RUST_STD_WIN_BASE="rust-std-${RUST_VERSION}-${RUST_ARCH}-pc-windows-gnu"
  RUST_STD_WIN_ARCH="${RUST_STD_WIN_BASE}.tar.xz"

  # Populate absolute paths for the cleanup trap
  ABS_RUST_INSTALL_ARCH="${INSTALL_BASE}/${RUST_INSTALL_ARCH}"
  ABS_RUST_STD_WIN_ARCH="${INSTALL_BASE}/${RUST_STD_WIN_ARCH}"
  ABS_RUST_INSTALL_BASE="${INSTALL_BASE}/${RUST_INSTALL_BASE}"
  ABS_RUST_STD_WIN_BASE="${INSTALL_BASE}/${RUST_STD_WIN_BASE}"
fi

# -----------------------------------------------------------------------------
#  Function: installLinters
#  Description:
#    Installs Rust code quality toolchain components (clippy, rustfmt) and
#    third-party cargo tools across four categories:
#      Security   : cargo-audit, cargo-deny
#      Analysis   : cargo-geiger, cargo-machete, cargo-semver-checks, cargo-udeps*
#      Coverage   : cargo-tarpaulin
#      Testing    : cargo-nextest
#      Performance: cargo-bloat, cargo-outdated
#    (* cargo-udeps requires a nightly toolchain; a warning is emitted if not
#       available.)
#    Individual failures are non-fatal — reported as warnings and skipped.
# -----------------------------------------------------------------------------
function installLinters() {
  # Resolve the cargo binary based on install mode
  local CARGO_BIN
  if [ "${INSTALL_MODE}" == "LOCAL" ]; then
    CARGO_BIN="${RUST_HOME}/bin/cargo"
  else
    CARGO_BIN="${RUST_LOCAL}/cargo"
  fi

  if ! [ -x "${CARGO_BIN}" ]; then
    echo "*** WARNING: cargo not found at [${CARGO_BIN}]. Skipping linter installation."
    return 1
  fi

  # Prepend cargo bin directory to PATH to ensure cargo can locate rustc
  local BIN_DIR
  BIN_DIR=$(dirname "${CARGO_BIN}")
  # shellcheck disable=SC2031
  PATH="${BIN_DIR}:${PATH}"
  export PATH
  export RUSTC="${RUSTC_BIN}"

  # Set CARGO_HOME to a temporary directory to prevent writing to ~/.cargo or /root/.cargo
  local TEMP_PARENT_DIR
  if [ -d "${INSTALL_BASE}" ]; then
    TEMP_PARENT_DIR="${INSTALL_BASE}"
  else
    TEMP_PARENT_DIR="${SYS_TMP_DIR}"
  fi
  local TEMP_CARGO_HOME
  TEMP_CARGO_HOME=$(mktemp -d -p "${TEMP_PARENT_DIR}" cargo-linters-XXXXXX)
  export CARGO_HOME="${TEMP_CARGO_HOME}"
  ABS_TEMP_CARGO_HOME="${TEMP_CARGO_HOME}"

  # Determine system-wide installation root for cargo packages
  local INSTALL_ROOT
  if [ "${INSTALL_MODE}" == "LOCAL" ]; then
    INSTALL_ROOT="${RUST_HOME}"
  else
    INSTALL_ROOT=$(dirname "${RUST_LOCAL}") # Resolves to /usr/local
  fi

  if [ -n "${LINTERS_ARCHIVE}" ]; then
    if [ ! -f "${LINTERS_ARCHIVE}" ]; then
      echo -e "\n*** ERROR10: Archive file [${LINTERS_ARCHIVE}] does not exist."
      exit 10
    fi
    if ! tar -tf "${LINTERS_ARCHIVE}" &>/dev/null; then
      echo -e "\n*** ERROR11: Archive file [${LINTERS_ARCHIVE}] is not a valid tar archive."
      exit 11
    fi
    
    echo -e "\n>> 5- Extracting precompiled linter binaries from archive [${LINTERS_ARCHIVE}]"
    echo    "   target root: ${INSTALL_ROOT}"
    echo    "-------------------------------------------------------------"
    
    if tar -C "${INSTALL_ROOT}" -Jxf "${LINTERS_ARCHIVE}"; then
      echo "      OK"
    else
      echo -e "\n*** ERROR12: Failed to extract linter archive [${LINTERS_ARCHIVE}] to [${INSTALL_ROOT}]."
      exit 12
    fi
    
    # Clean up the unused temporary CARGO_HOME directory
    if [ -d "${TEMP_CARGO_HOME}" ]; then
      rm -rf "${TEMP_CARGO_HOME}"
      ABS_TEMP_CARGO_HOME=""
    fi
  else
    echo -e "\n>> 5- Installing Rust code quality tools [--linters]"
    echo    "   cargo: ${CARGO_BIN}"
    echo    "   root:  ${INSTALL_ROOT}"
    echo    "-------------------------------------------------------------"

    # ---- Verify system dependencies for compilation ----
    echo -e "\n>> Verifying system dependencies for linter compilation..."
    
    # 1. Resolve and validate C compiler (honoring env variables like CC)
    local TARGET_CC="${CC:-}"
    if [ -z "${TARGET_CC}" ]; then
      local TARGET_UPPER
      TARGET_UPPER=$(echo "${RUST_ARCH}_unknown_linux_gnu" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
      local TARGET_CC_VAR="CC_${TARGET_UPPER}"
      TARGET_CC="${!TARGET_CC_VAR:-}"
    fi
    if [ -z "${TARGET_CC}" ]; then
      if command -v gcc &>/dev/null; then
        TARGET_CC="gcc"
      elif command -v clang &>/dev/null; then
        TARGET_CC="clang"
      fi
    fi
    if [ -z "${TARGET_CC}" ] || ! command -v "${TARGET_CC}" &>/dev/null; then
      echo -e "\n*** ERROR14: C compiler (gcc/clang) is not installed, or resolved CC=[${TARGET_CC}] is invalid."
      if [ "${OS_DISTRIB}" == "el" ]; then
        echo "    Please install gcc via: sudo dnf groupinstall \"Development Tools\""
      else
        echo "    Please install gcc via: sudo apt-get install build-essential"
      fi
      exit 14
    fi

    # 2. Check for pkg-config
    if ! command -v pkg-config &>/dev/null; then
      echo -e "\n*** ERROR15: pkg-config is not installed."
      if [ "${OS_DISTRIB}" == "el" ]; then
        echo "    Please install it via: sudo dnf install pkgconf"
      else
        echo "    Please install it via: sudo apt-get install pkg-config"
      fi
      exit 15
    fi

    # 3. Check for OpenSSL development headers
    local HAS_OPENSSL="false"
    if pkg-config --exists openssl; then
      HAS_OPENSSL="true"
    elif [ -f "/usr/include/openssl/ssl.h" ]; then
      HAS_OPENSSL="true"
    fi
    
    if [ "${HAS_OPENSSL}" == "false" ]; then
      echo -e "\n*** ERROR13: OpenSSL development packages are missing."
      if [ "${OS_DISTRIB}" == "el" ]; then
        echo "    Please install it via: sudo dnf install openssl-devel"
      else
        echo "    Please install it via: sudo apt-get install libssl-dev"
      fi
      exit 13
    fi
    
    echo "   C compiler:      OK (${TARGET_CC})"
    echo "   pkg-config:      OK"
    echo "   OpenSSL headers: OK"

    # ---- Toolchain components (shipped with Rust, added via rustup component) ----
    # On non-rustup installs the components directory may already include them;
    # attempt to add via rustup if present, otherwise skip gracefully.
    local RUSTUP_BIN
    RUSTUP_BIN=$(command -v rustup 2>/dev/null)

    local COMPONENTS=("clippy" "rustfmt" "rust-analyzer")
    for comp in "${COMPONENTS[@]}"; do
      echo -e "\n  [+] Component: ${comp}"
      
      # Check if the component binary is already present in the toolchain bin directory
      local is_installed="false"
      if [ "${comp}" == "clippy" ]; then
        if [ -x "${BIN_DIR}/cargo-clippy" ] || [ -x "${BIN_DIR}/clippy-driver" ]; then
          is_installed="true"
        fi
      elif [ "${comp}" == "rustfmt" ]; then
        if [ -x "${BIN_DIR}/rustfmt" ] || [ -x "${BIN_DIR}/cargo-fmt" ]; then
          is_installed="true"
        fi
      elif [ "${comp}" == "rust-analyzer" ]; then
        if [ -x "${BIN_DIR}/rust-analyzer" ]; then
          is_installed="true"
        fi
      fi

      if [ "${is_installed}" == "true" ]; then
        echo "      OK (already present in sysroot)"
      elif [ -n "${RUSTUP_BIN}" ]; then
        "${RUSTUP_BIN}" component add "${comp}" && echo "      OK" || echo "      WARNING: failed to add component [${comp}]"
      else
        echo "      WARNING: component [${comp}] not found in sysroot, and rustup is not available to install it."
      fi
    done

    # ---- Third-party cargo tools (stable toolchain) ----
    local CARGO_TOOLS=(
      "cargo-audit"        # Security: advisory DB vulnerability scan
      "cargo-deny"         # Security: license / advisory / duplicate-dep policy
      "cargo-geiger"       # Analysis: counts unsafe { } usage in crate tree
      "cargo-machete"      # Analysis: detects unused dependencies (stable)
      "cargo-semver-checks" # Analysis: detects semver-breaking API changes
      "cargo-tarpaulin"    # Coverage: LCOV/HTML code coverage (Linux)
      "cargo-nextest"      # Testing : parallel test runner, JUnit XML output
      "cargo-bloat"        # Performance: binary section size analysis
      "cargo-outdated"     # Performance: reports outdated dependency versions
      "cargo-udeps"        # Nightly req: detects unused dependencies (run with RUSTC_BOOTSTRAP=1)
    )
    local force_rebuild_linters="false"
    # If not in standalone mode and the compiler was upgraded, force rebuild all linters
    if [ "${STANDALONE_LINTERS}" == "false" ] && [ "${LOCAL_VERSION}" != "${RUST_VERSION}" ]; then
      echo -e "\n>> Rust toolchain upgraded from ${LOCAL_VERSION} to ${RUST_VERSION}."
      echo "   Forcing linter rebuilds to compile against the new compiler..."
      force_rebuild_linters="true"
    fi

    if [ "${FORCE_INSTALL}" == "true" ]; then
      force_rebuild_linters="true"
    fi

    for tool in "${CARGO_TOOLS[@]}"; do
      local crate_name
      crate_name=$(echo "${tool}" | cut -d'#' -f1 | tr -d ' ')

      local cargo_install_args=("--root" "${INSTALL_ROOT}" "--locked")
      if [ "${force_rebuild_linters}" == "true" ]; then
        cargo_install_args+=("--force")
        echo -e "\n  [+] cargo install ${crate_name} (forced rebuild)"
      else
        echo -e "\n  [+] cargo install ${crate_name} (conditional update)"
      fi

      "${CARGO_BIN}" install "${cargo_install_args[@]}" "${crate_name}" && echo "      OK" || echo "      WARNING: failed to install [${crate_name}]"
    done
  fi

  # For LOCAL mode, generate symlinks to /usr/local/bin and restore permissions
  if [ "${INSTALL_MODE}" == "LOCAL" ]; then
    echo -e "\n>> Generating symlinks for local mode tools in [${RUST_LOCAL}]"
    pushd "${RUST_LOCAL}" &>/dev/null || exit 1
    for b in "${RUST_HOME}"/bin/*; do
      if [ -e "$b" ] || [ -L "$b" ]; then
        ln -sfv "$b" .
      fi
    done
    popd &>/dev/null || exit 1
    chown -R "${RUST_PERMS}" "${RUST_HOME}"
  fi

  # ---- Generate Package Archive (Optional) ----
  if [ "${HAS_PACKAGE_CITOOLS}" == "true" ]; then
    local RUST_VER_VAL="${RUST_VERSION}"
    if [ -z "${RUST_VER_VAL}" ]; then
      if [ -x "${RUSTC_BIN}" ]; then
        RUST_VER_VAL=$("${RUSTC_BIN}" --version | cut -d' ' -f2)
      else
        RUST_VER_VAL="0.0.0"
      fi
    fi

    local DATE_STR
    DATE_STR=$(date +%Y%m%d)
    local DEFAULT_NAME="rust-linters-${RUST_VER_VAL}-${DATE_STR}-${OS_DISTRIB}${OS_ID}-${RUST_ARCH}.tar.xz"
    
    local ARCHIVE_PATH
    if [ -n "${PACKAGE_CITOOLS_NAME}" ]; then
      if [[ "${PACKAGE_CITOOLS_NAME}" == */* ]]; then
        ARCHIVE_PATH="${PACKAGE_CITOOLS_NAME}"
      else
        ARCHIVE_PATH="${TARGET_PATH}/${PACKAGE_CITOOLS_NAME}"
      fi
    else
      ARCHIVE_PATH="${TARGET_PATH}/${DEFAULT_NAME}"
    fi

    echo -e "\n>> 6- Packaging linter binaries to archive [${ARCHIVE_PATH}]"
    
    # Ensure target output directory exists
    local ARCHIVE_DIR
    ARCHIVE_DIR=$(dirname "${ARCHIVE_PATH}")
    mkdir -p "${ARCHIVE_DIR}"

    # Build the list of binaries to package
    local PACKAGE_BINARIES=(
      "cargo-clippy"
      "clippy-driver"
      "cargo-fmt"
      "rustfmt"
      "rust-analyzer"
      "cargo-audit"
      "cargo-deny"
      "cargo-geiger"
      "cargo-machete"
      "cargo-semver-checks"
      "cargo-tarpaulin"
      "cargo-nextest"
      "cargo-bloat"
      "cargo-outdated"
      "cargo-udeps"
    )

    local EXIST_BINS=()
    for bin in "${PACKAGE_BINARIES[@]}"; do
      if [ -x "${INSTALL_ROOT}/bin/${bin}" ]; then
        EXIST_BINS+=("bin/${bin}")
      fi
    done

    if [ "${#EXIST_BINS[@]}" -eq 0 ]; then
      echo "*** WARNING: No linter binaries found to package under [${INSTALL_ROOT}/bin/]."
    else
      tar -C "${INSTALL_ROOT}" -Jcf "${ARCHIVE_PATH}" "${EXIST_BINS[@]}"
      local RETVAL="$?"
      if [ "${RETVAL}" -eq 0 ]; then
        echo "      OK"
      else
        echo "*** WARNING: Packaging failed with exit code [${RETVAL}]"
      fi
    fi
  fi

  # Clean up temporary CARGO_HOME directory
  if [ -d "${TEMP_CARGO_HOME}" ]; then
    rm -rf "${TEMP_CARGO_HOME}"
  fi

  echo -e "\n-------------------------------------------------------------"
  echo    "   Linter installation complete."
}

# -----------------------------------------------------------------------------
#  Function: execInstall
#  Description:
#    Takes an extracted Rust package directory, sets ownership to root, and
#    runs the official Rust vendor-provided install.sh script with parameters
#    corresponding to the installation mode.
# -----------------------------------------------------------------------------
function execInstall() {
  # Set target folder permissions to root before executing installation
  chown -R root:root "$1"
  pushd "$1" &>/dev/null || exit 1
  
  echo -e "\n>> 2- Installing Rust version [${RUST_VERSION} -> $1]"
  
  local install_args=()
  if [ "${INSTALL_MODE}" == "LOCAL" ]; then
    install_args+=("--destdir=${RUST_HOME}" "--prefix=/")
  fi

  if [ "${HAS_CORE_COMPONENTS}" == "true" ]; then
    local WITHOUT_COMPONENTS=()
    if [ -f "components" ]; then
      for skip_c in "${OPTIONAL_COMPONENTS[@]}"; do
        if grep -qFx "${skip_c}" components; then
          WITHOUT_COMPONENTS+=("${skip_c}")
        fi
      done
    fi

    if [ "${#WITHOUT_COMPONENTS[@]}" -gt 0 ]; then
      local joined
      joined=$(IFS=,; echo "${WITHOUT_COMPONENTS[*]}")
      install_args+=("--without=${joined}")
    fi
  fi

  ./install.sh "${install_args[@]}"
  RETVAL="$?"

  if [ "${INSTALL_MODE}" == "LOCAL" ] && [ "${RETVAL}" -eq 0 ]; then
    chown -R "${RUST_PERMS}" "${RUST_HOME}"
  fi
  
  popd &>/dev/null || exit 1

  # Verify if vendor install script succeeded
  if [ "${RETVAL}" -ne 0 ]; then
    echo "*** ERROR07: Rust installation failed [$1]"
    exit 7
  fi
}

# ----- STANDALONE LINTERS MODE -----
# If --linters was the only operational flag (no --version or --auto), skip
# the download/install pipeline and apply linters to the existing installation.
if [ "${HAS_LINTERS}" == "true" ] && [ "${HAS_VERSION}" == "false" ] && [ "${HAS_AUTO}" == "false" ]; then
  installLinters
  exit 0
fi

# ----- DOWNLOAD -----
if [ -d "${INSTALL_BASE}" ]; then
  cd "${INSTALL_BASE}" || exit 1

  # Pre-flight check: Ensure there is at least 1GB (1048576 KB) of free disk space on the install partition
  if command -v df &>/dev/null && command -v awk &>/dev/null; then
    FREE_KB=$(df -P "${INSTALL_BASE}" | tail -1 | awk '{print $4}')
    if [[ "${FREE_KB}" =~ ^[0-9]+$ ]] && [ "${FREE_KB}" -lt 1048576 ]; then
      echo -e "\n*** ERROR08: Insufficient disk space on ${INSTALL_BASE}. At least 1GB of free space is required (found $((FREE_KB / 1024))MB)."
      exit 8
    fi
  fi

  echo -e "\n>> 0- Downloading Rust archives: ${RUST_INSTALL_ARCH}, ${RUST_STD_WIN_ARCH}"

  # Remove older versions / partial downloads to prevent caching issues
  rm -rf "${RUST_INSTALL_ARCH}" "${RUST_STD_WIN_ARCH}" "${RUST_INSTALL_BASE}" "${RUST_STD_WIN_BASE}"
  
  # Fetch packages securely:
  # -sSfL ensures curl is silent, reports errors on HTTP failures (like 404),
  # and follows redirects.
  curl -sSf -L \
    -C - -O "${RUST_URL_BASE}/${RUST_INSTALL_ARCH}" \
    -C - -O "${RUST_URL_BASE}/${RUST_STD_WIN_ARCH}"
else
  echo -e "\nERROR03: Invalid base installation folder [${INSTALL_BASE}]"
  exit 3
fi

# Confirm downloaded files exist and are not empty
if ! [ -s "${RUST_INSTALL_ARCH}" ] || ! [ -s "${RUST_STD_WIN_ARCH}" ]; then
  echo -e "\n*** ERROR04: Rust install archive [${RUST_INSTALL_ARCH}] or [${RUST_STD_WIN_ARCH}] is missing or invalid."
  exit 4
fi

# ----- EXTRACTION -----
echo -e "\n>> 1- Extracting Rust archive: ${RUST_INSTALL_ARCH}, ${RUST_STD_WIN_ARCH}"
for a in "${RUST_INSTALL_ARCH}" "${RUST_STD_WIN_ARCH}"; do
  if ! tar -Jxf "$a"; then
    echo "*** ERROR05: Rust archive [$a] extraction failed"
    exit 5
  fi
done

# Confirm the directories extracted successfully
if ! [ -d "${RUST_INSTALL_BASE}" ] || ! [ -d "${RUST_STD_WIN_BASE}" ]; then
  echo "*** ERROR06: Base Rust install folder [${RUST_INSTALL_BASE}] or [${RUST_STD_WIN_BASE}] is missing or invalid."
  exit 6
fi

# ----- UNINSTALL PREVIOUS VERSION (IF PRESENT) -----
# If an existing installation is present, run its uninstaller first to ensure a clean state
# and prevent orphaned files/components from previous installations.
if [ "${INSTALL_MODE}" == "SYSTEM" ]; then
  if [ -x "/usr/local/lib/rustlib/uninstall.sh" ]; then
    echo -e "\n>> Uninstalling existing global Rust installation..."
    /usr/local/lib/rustlib/uninstall.sh
  fi
else
  if [ -x "${RUST_HOME}/lib/rustlib/uninstall.sh" ]; then
    echo -e "\n>> Uninstalling existing local Rust installation..."
    "${RUST_HOME}/lib/rustlib/uninstall.sh"
  fi
fi

# ----- INSTALLATION EXECUTION -----
# Run installer for main compiler toolchain
execInstall "${RUST_INSTALL_BASE}"
# Run installer for windows GNU target standard library
execInstall "${RUST_STD_WIN_BASE}"

# ----- SYMLINKS GENERATION (LOCAL MODE ONLY) -----
if [ "${INSTALL_MODE}" == "LOCAL" ]; then
  echo -e ">> 3- ${INSTALL_MODE} mode: Generating symlinks [${RUST_LOCAL}]"
  pushd "${RUST_LOCAL}" &>/dev/null || exit 1
  for b in "${RUST_HOME}"/bin/*; do
    if [ -e "$b" ] || [ -L "$b" ]; then
      ln -sfv "$b" .
    fi
  done
  popd &>/dev/null || exit 1
else
  echo -e ">> 3- ${INSTALL_MODE} mode: Rust binaries are installed in [${RUST_LOCAL}]"
fi

# ----- PURGE & CLEANUP -----
echo -e "\n>> 4- Purging Rust archives [${RUST_INSTALL_ARCH}, ${RUST_STD_WIN_ARCH}]"
echo    "        and base folders [${RUST_INSTALL_BASE}, ${RUST_STD_WIN_BASE}]"
rm -rf "${RUST_INSTALL_ARCH}" "${RUST_STD_WIN_ARCH}" "${RUST_INSTALL_BASE}" "${RUST_STD_WIN_BASE}"
ABS_RUST_INSTALL_ARCH=""
ABS_RUST_STD_WIN_ARCH=""
ABS_RUST_INSTALL_BASE=""
ABS_RUST_STD_WIN_BASE=""

# ----- VERIFICATION -----
echo -e "\nRust installation was successful: $("${RUSTC_BIN}" --version)\n"
echo -e "Supported targets:"
"${RUSTC_BIN}" --print target-list | grep -E "x86_64-(unknown-linux|pc-windows)-gnu"
echo ""

# ----- LINTER INSTALLATION (OPTIONAL) -----
if [ "${HAS_LINTERS}" == "true" ]; then
  installLinters
fi
