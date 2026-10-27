#!/bin/bash
# ==============================================================================
#  Go Project Build Execution & Orchestration Wrapper
#  File      : build_go_exec.sh
#  Version   : 2.2.0
#  Date      : 2026-10-26
#  Author    : Critical Systems / XDG
# ==============================================================================
#  Objective:
#    Enterprise orchestration wrapper engineered to prepare, patch, configure,
#    and execute Go projects within the Critical Systems Devops pipeline.
#    Automates both pristine remote checkouts (git-clone mode) and iterative in-tree
#    development workflows (local mode), enforcing non-interactive patch
#    application, metadata injection, and fail-fast prerequisite validation before
#    delegating to the central compilation and packaging engine (build_go.sh).
#
#  Core Components:
#    1. Execution Mode & Argument Router: Parses and validates mandatory CLI options
#       (--mode, --code-base, --project, --custom-objects, --git-url) and forwards
#       any extended flags directly to the build engine.
#    2. Direct Command Dependency Auditor: Enforces fail-fast presence checks for
#       tools directly invoked by this script (cat, dirname, basename, chmod, rm,
#       cp, sort, patch, and optionally git).
#    3. Filesystem DAC & Sanitization Guard: Verifies read/write/execute permissions,
#       resolves physical symlinks (-P), and rejects path traversal injection
#       patterns in project identifiers.
#    4. Build Engine & Include Validator: Ensures build_go.sh and its central include
#       library (build.inc) are discoverable, readable, and executable.
#    5. Single-Pass Patch Discovery & Validator: Scans custom overlay patches in
#       a single deterministic pass, verifying non-empty sizes and readability
#       without subshell word-splitting.
#    6. Workspace Lifecycle Engine: Handles safe directory purges, interrupt-safe
#       git clones, and directory transitions.
#    7. Non-Interactive Patch Application Engine: Simulates patch application
#       in-memory (--dry-run) and applies unified diffs with zero interactive
#       prompts (--batch --forward), failing fast on rejected or reversed hunks.
#    8. Configuration Overlay Stager: Stages <project>_build.json (or build.json)
#       into the module root for metadata extraction by build_go.sh.
#    9. Process Replacement Handover: Transfers control to build_go.sh via 'exec',
#       guaranteeing zero wrapper overhead and transparent exit code propagation.
#
#  Functionality & Data Flows:
#    - Initialization: Enables strict bash modes (set -euo pipefail), sets exit codes.
#    - Signal Traps: Installs INT/TERM signal traps to roll back partial clones on abort.
#    - Pre-flight Checks: Audits CLI syntax, system tools, directory permissions,
#      configuration files, and patch integrity before mutating disk state.
#    - Workspace Staging: Prepares project folder (fresh clone or local workspace).
#    - Overlay Execution: Applies pre-validated patches and copies build configuration.
#    - Engine Handover: Replaces wrapper process with build_go.sh with forwarded flags.
#
#  Error Handling & Diagnostic Strategy:
#    - Standardized Granular Exit Codes (aligned with build.inc):
#        0 = EXIT_SUCCESS    : Normal termination or --help display
#        1 = EXIT_GENERAL    : Runtime errors or git clone failures
#        2 = EXIT_USAGE      : Command-line syntax or missing parameter errors
#        3 = EXIT_CONFIG     : Filesystem, directory, or configuration file errors
#        4 = EXIT_DEPENDENCY : Missing directly required command-line tools
#        7 = EXIT_COMPILE    : Patch rejection, conflict, or compilation failures
#
#  Syntax:
#    ./build_go_exec.sh --mode <git-clone|local>
#                       --code-base <path>
#                       --project <project>
#                       --custom-objects <path>
#                       [--git-url <base-url>]
#                       [--help|-h]
#                       [build_go.sh options...]
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# 1. Standard Granular Diagnostic Exit Codes (aligned with build.inc)
# ------------------------------------------------------------------------------
EXIT_SUCCESS=0
EXIT_GENERAL=1
EXIT_USAGE=2
EXIT_CONFIG=3
EXIT_DEPENDENCY=4
EXIT_COMPILE=7

# ------------------------------------------------------------------------------
# 2. Defaults & Variable Initialization
# ------------------------------------------------------------------------------
MODE=""
CODE_BASE=""
PROJECT=""
CUSTOM_OBJECTS=""
GIT_URL=""
EXTRA_ARGS=()

# Default compilation and packaging pipeline flags forwarded to build_go.sh
DEFAULT_BUILD_FLAGS=(
  "--all-platform"
  "--all-pkg"
  "--update-modules"
  "--ignore-audit"
)

# Flag tracking active git clone phase for safe interrupt rollback
CLONING_IN_PROGRESS=false

# ------------------------------------------------------------------------------
# 3. Helper Functions & Defensive Primitives
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Function : abort
# Objective: Centralized diagnostic failure handler. Emits an formatted error
#            message to standard error and halts execution with the specified
#            granular exit code.
# Arguments:
#   $1 - Numeric exit status code (e.g., EXIT_USAGE, EXIT_CONFIG, EXIT_DEPENDENCY)
#   $2..$N - Diagnostic error message strings
# Outputs  : Writes "ERROR: <message>" to stderr.
# Exit Code: Halts with the provided $1 status code.
# ------------------------------------------------------------------------------
abort() {
  local exit_code="$1"
  shift
  echo "ERROR: $*" >&2
  exit "${exit_code}"
}

# ------------------------------------------------------------------------------
# Function : check_dir_access
# Objective: Verifies directory existence, searchability (DAC execute permission),
#            readability, and optional write access. Halts immediately on failure.
# Arguments:
#   $1 - Absolute or relative path to the directory under inspection.
#   $2 - Human-readable label for the directory (used in diagnostic messages).
#   $3 - Boolean flag ("true" or "false") indicating whether write access is required.
# Outputs  : Emits diagnostic error message to stderr upon failure.
# Exit Code: Halts with EXIT_CONFIG (3) if directory checks fail.
# ------------------------------------------------------------------------------
check_dir_access() {
  local dir_path="$1"
  local desc="$2"
  local need_write="${3:-false}"

  if [[ ! -d "${dir_path}" ]]; then
    abort "${EXIT_CONFIG}" "${desc} directory does not exist: ${dir_path}"
  fi
  if [[ ! -r "${dir_path}" || ! -x "${dir_path}" ]]; then
    abort "${EXIT_CONFIG}" "${desc} directory is not accessible (read/execute denied): ${dir_path}"
  fi
  if [[ "${need_write}" == "true" && ! -w "${dir_path}" ]]; then
    abort "${EXIT_CONFIG}" "${desc} directory is not writable: ${dir_path}"
  fi
}

# ------------------------------------------------------------------------------
# Function : cleanup_on_interrupt
# Objective: Signal trap handler for INT (Ctrl+C) and TERM signals. Prevents
#            workspace pollution by removing partially cloned project trees if
#            an interrupt occurs during the git clone stage.
# Arguments: None (inspects $? for previous exit status).
# Outputs  : Emits rollback notification to stderr if cleaning an active clone.
# Exit Code: Propagates termination exit status.
# ------------------------------------------------------------------------------
cleanup_on_interrupt() {
  local exit_status=$?
  if [[ "${CLONING_IN_PROGRESS}" == "true" && -n "${CODE_BASE}" && -n "${PROJECT}" && -d "${CODE_BASE}/${PROJECT}" ]]; then
    echo -e "\n>> Interrupted during git clone. Cleaning up partial directory..." >&2
    rm -rf "${CODE_BASE:?}/${PROJECT:?}" 2>/dev/null || true
  fi
  exit "${exit_status}"
}
trap cleanup_on_interrupt INT TERM

# ------------------------------------------------------------------------------
# Function : usage
# Objective: Displays standard manual, command-line arguments, operational modes,
#            exit code reference, and usage examples.
# Arguments:
#   $1 - (Optional) Exit code to terminate with. Defaults to EXIT_SUCCESS (0).
# Outputs  : Writes formatted manual to stdout.
# Exit Code: Halts with the provided $1 status code.
# ------------------------------------------------------------------------------
usage() {
  local exit_code="${1:-${EXIT_SUCCESS}}"
  cat <<EOF
Usage: $(basename "$0") --mode <git-clone|local> --code-base <path> --project <project> --custom-objects <path> [options]

Required Arguments:
  --mode <mode>            Execution mode: 'git-clone' (clones fresh repo) or 'local' (uses existing directory)
  --code-base <path>       Directory containing the projects (e.g. /u01/data/devel/build/code/public)
  --project <project>      Project/module name (e.g. godap)
  --custom-objects <path>  Directory containing <project>_build.json (or build.json) and patches to apply
  --git-url <base-url>     Base Git repository URL (mandatory when --mode is git-clone)

Optional Arguments:
  --help, -h               Show this help message

Additional flags will be forwarded directly to build_go.sh (defaults: ${DEFAULT_BUILD_FLAGS[*]}).

Exit Codes:
  0 = Success (${EXIT_SUCCESS})
  1 = General / Runtime Error (${EXIT_GENERAL})
  2 = Usage / CLI Syntax Error (${EXIT_USAGE})
  3 = Configuration / Filesystem Error (${EXIT_CONFIG})
  4 = Missing CLI Dependency (${EXIT_DEPENDENCY})
  7 = Patch / Compilation Error (${EXIT_COMPILE})

Examples:
  # git-clone mode (clones https://github.com/Macmod/godap into /u01/data/devel/build/code/public/godap):
  $(basename "$0") --mode git-clone --code-base /u01/data/devel/build/code/public --project godap --custom-objects /u01/data/devel/build/code/public --git-url https://github.com/Macmod

  # local mode (uses existing folder /u01/data/devel/build/code/public/godap):
  $(basename "$0") --mode local --code-base /u01/data/devel/build/code/public --project godap --custom-objects /u01/data/devel/build/code/public
EOF
  exit "${exit_code}"
}

# ------------------------------------------------------------------------------
# 4. Command Line Argument Parsing
# ------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="$2"
      shift 2
      ;;
    --code-base)
      CODE_BASE="$2"
      shift 2
      ;;
    --project)
      PROJECT="$2"
      shift 2
      ;;
    --custom-objects)
      CUSTOM_OBJECTS="$2"
      shift 2
      ;;
    --git-url)
      GIT_URL="$2"
      shift 2
      ;;
    --help|-h)
      usage "${EXIT_SUCCESS}"
      ;;
    *)
      # Accumulate any extra flags to pass directly to build_go.sh
      EXTRA_ARGS+=("$1")
      shift
      ;;
  esac
done

# ------------------------------------------------------------------------------
# 5. CLI Argument Validation
# ------------------------------------------------------------------------------
if [[ -z "${MODE}" ]]; then
  echo "ERROR: Missing required argument: --mode <git-clone|local>" >&2
  usage "${EXIT_USAGE}"
fi

if [[ "${MODE}" != "git-clone" && "${MODE}" != "local" ]]; then
  echo "ERROR: Invalid --mode '${MODE}'. Must be 'git-clone' or 'local'." >&2
  usage "${EXIT_USAGE}"
fi

if [[ -z "${CODE_BASE}" ]]; then
  echo "ERROR: Missing required argument: --code-base <path>" >&2
  usage "${EXIT_USAGE}"
fi

if [[ -z "${PROJECT}" ]]; then
  echo "ERROR: Missing required argument: --project <project>" >&2
  usage "${EXIT_USAGE}"
fi

# Defensive validation: project name must not contain path separators or relative references
# Prevents arbitrary directory wiping or directory traversal attacks
if [[ "${PROJECT}" =~ [/] || "${PROJECT}" =~ ^\.\.?$ ]]; then
  abort "${EXIT_CONFIG}" "Invalid project name '${PROJECT}'. Must be a simple folder name without path separators."
fi

if [[ -z "${CUSTOM_OBJECTS}" ]]; then
  echo "ERROR: Missing required argument: --custom-objects <path>" >&2
  usage "${EXIT_USAGE}"
fi

if [[ "${MODE}" == "git-clone" && -z "${GIT_URL}" ]]; then
  echo "ERROR: Missing required argument: --git-url <base-url> (mandatory when --mode is git-clone)" >&2
  usage "${EXIT_USAGE}"
fi

# ------------------------------------------------------------------------------
# 6. Prerequisite Verification: Directly Used System Commands
# ------------------------------------------------------------------------------
# Function : check_command_prereqs
# Objective: Pre-flight fail-fast validation for all CLI utilities directly invoked
#            by build_go_exec.sh. Downstream build utilities (go, archivers, rpm/deb)
#            are delegated to build_go.sh's internal checker.
# Arguments: None (inspects MODE).
# Outputs  : Emits diagnostic error message listing any missing commands.
# Exit Code: Halts with EXIT_DEPENDENCY (4) if any required tool is absent.
# ------------------------------------------------------------------------------
check_command_prereqs() {
  local missing_tools=()
  local direct_tools=("cat" "dirname" "basename" "chmod" "rm" "cp" "sort" "patch")

  if [[ "${MODE}" == "git-clone" ]]; then
    direct_tools+=("git")
  fi

  for tool in "${direct_tools[@]}"; do
    if ! command -v "${tool}" &> /dev/null; then
      missing_tools+=("${tool}")
    fi
  done

  if [[ ${#missing_tools[@]} -gt 0 ]]; then
    abort "${EXIT_DEPENDENCY}" "Missing required command-line tool(s) directly used by this script: ${missing_tools[*]}
       Please ensure all required tools are installed and available in PATH."
  fi
}

check_command_prereqs

# ------------------------------------------------------------------------------
# 7. Prerequisite Verification: Filesystem & Directory Paths
# ------------------------------------------------------------------------------
# Validate Code Base: must exist and have write permissions (for clone or builds)
check_dir_access "${CODE_BASE}" "Code base" true

# Validate Custom Objects: must exist and be readable
check_dir_access "${CUSTOM_OBJECTS}" "Custom objects" false

# Canonicalize paths using physical resolution (-P) to eliminate symlink ambiguity
CODE_BASE="$(cd "${CODE_BASE}" && pwd -P)"
CUSTOM_OBJECTS="$(cd "${CUSTOM_OBJECTS}" && pwd -P)"

# In local mode, verify the target project directory already exists and is writable
LOCAL_PROJECT_DIR="${CODE_BASE}/${PROJECT}"
if [[ "${MODE}" == "local" ]]; then
  check_dir_access "${LOCAL_PROJECT_DIR}" "Local project" true
fi

# ------------------------------------------------------------------------------
# 8. Prerequisite Verification: Build Engine & Framework Include
# ------------------------------------------------------------------------------
# Resolve location of build_go.sh (same directory, relative code base, or fixed system path)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd -P)"
BUILD_GO_SCRIPT=""
POSSIBLE_BUILD_PATHS=(
  "${SCRIPT_DIR}/build_go.sh"
  "${CODE_BASE}/../../private/devops/build_tasks/build_go.sh"
  "/u01/data/devel/build/code/private/devops/build_tasks/build_go.sh"
)

for candidate in "${POSSIBLE_BUILD_PATHS[@]}"; do
  if [[ -f "${candidate}" ]]; then
    BUILD_GO_SCRIPT="$(cd "$(dirname "${candidate}")" && pwd -P)/$(basename "${candidate}")"
    break
  fi
done

if [[ -z "${BUILD_GO_SCRIPT}" || ! -f "${BUILD_GO_SCRIPT}" ]]; then
  abort "${EXIT_CONFIG}" "Could not locate build_go.sh build engine."
fi

# Ensure build engine has execute permissions
if [[ ! -x "${BUILD_GO_SCRIPT}" ]]; then
  chmod +x "${BUILD_GO_SCRIPT}" 2>/dev/null || true
  if [[ ! -x "${BUILD_GO_SCRIPT}" ]]; then
    abort "${EXIT_CONFIG}" "Build engine script is not executable: ${BUILD_GO_SCRIPT}"
  fi
fi

# Verify presence and readability of core include library (build.inc)
BUILD_INC_FILE="$(dirname "${BUILD_GO_SCRIPT}")/build.inc"
if [[ ! -f "${BUILD_INC_FILE}" ]]; then
  abort "${EXIT_CONFIG}" "Required build configuration include 'build.inc' not found in $(dirname "${BUILD_GO_SCRIPT}")."
fi

if [[ ! -r "${BUILD_INC_FILE}" ]]; then
  abort "${EXIT_CONFIG}" "Required build configuration include 'build.inc' is not readable: ${BUILD_INC_FILE}"
fi

# ------------------------------------------------------------------------------
# 9. Prerequisite Verification: Custom Configuration
# ------------------------------------------------------------------------------
# Locate project-specific configuration (<project>_build.json, build.json, or local tree)
CONFIG_FOUND=""
if [[ -f "${CUSTOM_OBJECTS}/${PROJECT}_build.json" ]]; then
  CONFIG_FOUND="${CUSTOM_OBJECTS}/${PROJECT}_build.json"
elif [[ -f "${CUSTOM_OBJECTS}/build.json" ]]; then
  CONFIG_FOUND="${CUSTOM_OBJECTS}/build.json"
elif [[ -f "${CUSTOM_OBJECTS}/${PROJECT}.json" ]]; then
  CONFIG_FOUND="${CUSTOM_OBJECTS}/${PROJECT}.json"
elif [[ "${MODE}" == "local" && -f "${LOCAL_PROJECT_DIR}/build.json" ]]; then
  CONFIG_FOUND="${LOCAL_PROJECT_DIR}/build.json"
fi

if [[ -z "${CONFIG_FOUND}" ]]; then
  abort "${EXIT_CONFIG}" "Required configuration file not found in ${CUSTOM_OBJECTS}.
       Expected '${PROJECT}_build.json' or 'build.json'."
fi

if [[ ! -r "${CONFIG_FOUND}" ]]; then
  abort "${EXIT_CONFIG}" "Configuration file is not readable: ${CONFIG_FOUND}"
fi

# ------------------------------------------------------------------------------
# 10. Prerequisite Verification: Custom Patches Discovery & Validation (Single-Pass DRY)
# ------------------------------------------------------------------------------
# Scan for patch files matching ${PROJECT}*.patch or fallback to any *.patch
VALIDATED_PATCHES=()
shopt -s nullglob
RAW_PATCHES=("${CUSTOM_OBJECTS}/${PROJECT}"*.patch)
if [[ ${#RAW_PATCHES[@]} -eq 0 ]]; then
  RAW_PATCHES=("${CUSTOM_OBJECTS}"/*.patch)
fi
shopt -u nullglob

if [[ ${#RAW_PATCHES[@]} -gt 0 ]]; then
  # Sort patch files deterministically using bash 4+ readarray (avoids subshell word-splitting)
  readarray -t SORTED_PATCHES < <(printf '%s\n' "${RAW_PATCHES[@]}" | sort)
  for patch_candidate in "${SORTED_PATCHES[@]}"; do
    if [[ ! -r "${patch_candidate}" ]]; then
      abort "${EXIT_CONFIG}" "Patch file is not readable: ${patch_candidate}"
    fi
    if [[ ! -s "${patch_candidate}" ]]; then
      abort "${EXIT_CONFIG}" "Patch file is empty (0 bytes): ${patch_candidate}"
    fi
    VALIDATED_PATCHES+=("${patch_candidate}")
  done
fi

# ------------------------------------------------------------------------------
# 11. Workspace Staging (git-clone vs local)
# ------------------------------------------------------------------------------
if [[ "${MODE}" == "git-clone" ]]; then
  # Programmatically append project name to base git URL
  CLONE_URL="${GIT_URL%/}/${PROJECT}"

  echo "=============================================================================="
  echo ">> Build Go Exec Wrapper"
  echo ">> Mode           : ${MODE}"
  echo ">> Code Base      : ${CODE_BASE}"
  echo ">> Project        : ${PROJECT}"
  echo ">> Custom Objects : ${CUSTOM_OBJECTS}"
  echo ">> Git Base URL   : ${GIT_URL}"
  echo ">> Clone URL      : ${CLONE_URL}"
  echo ">> Build Engine   : ${BUILD_GO_SCRIPT}"
  echo "=============================================================================="

  cd "${CODE_BASE}" || abort "${EXIT_GENERAL}" "Failed to cd into ${CODE_BASE}"

  # Safely wipe any prior clone directory using guarded parameter expansion
  if [[ -d "${PROJECT}" ]]; then
    echo ">> Removing existing ${PROJECT} directory in ${CODE_BASE}..."
    rm -rf "${CODE_BASE:?}/${PROJECT:?}"
  fi

  # Execute clone with active trap flag for interrupt safety
  echo ">> Cloning ${CLONE_URL} into ${CODE_BASE}/${PROJECT}..."
  CLONING_IN_PROGRESS=true
  if ! git clone "${CLONE_URL}" "${PROJECT}"; then
    abort "${EXIT_GENERAL}" "git clone failed for ${CLONE_URL}"
  fi
  CLONING_IN_PROGRESS=false

  cd "${PROJECT}" || abort "${EXIT_GENERAL}" "Failed to cd into ${PROJECT}"
else
  echo "=============================================================================="
  echo ">> Build Go Exec Wrapper"
  echo ">> Mode           : ${MODE}"
  echo ">> Code Base      : ${CODE_BASE}"
  echo ">> Project        : ${PROJECT}"
  echo ">> Custom Objects : ${CUSTOM_OBJECTS}"
  echo ">> Project Folder : ${LOCAL_PROJECT_DIR}"
  echo ">> Build Engine   : ${BUILD_GO_SCRIPT}"
  echo "=============================================================================="

  cd "${LOCAL_PROJECT_DIR}" || abort "${EXIT_GENERAL}" "Failed to cd into ${LOCAL_PROJECT_DIR}"
fi

# ------------------------------------------------------------------------------
# 12. Apply Custom Patches (Reusing Pre-validated Patches)
# ------------------------------------------------------------------------------
if [[ ${#VALIDATED_PATCHES[@]} -gt 0 ]]; then
  for patch_file in "${VALIDATED_PATCHES[@]}"; do
    echo ">> Testing and applying patch: $(basename "${patch_file}")..."
    # Non-interactive:
    #   --batch  : Suppresses interactive prompting on stdin or /dev/tty
    #   --forward: Rejects reversed/already-applied patches, preventing interactive 'Assume -R?'
    #   --dry-run: Verifies clean application in-memory before writing changes to disk
    if ! patch -p1 --batch --forward --dry-run < "${patch_file}"; then
      abort "${EXIT_COMPILE}" "Patch $(basename "${patch_file}") does not apply cleanly (rejected, reversed, or already applied)."
    fi
    if ! patch -p1 --batch --forward < "${patch_file}"; then
      abort "${EXIT_COMPILE}" "Failed to apply patch: ${patch_file}"
    fi
  done
else
  echo ">> No patch files found in ${CUSTOM_OBJECTS} to apply."
fi

# ------------------------------------------------------------------------------
# 13. Copy Custom Configuration (<project>_build.json -> build.json)
# ------------------------------------------------------------------------------
# Copy verified build configuration into the project root unless already located there
TARGET_CONFIG="$(pwd -P)/build.json"
if [[ -n "${CONFIG_FOUND}" && "${CONFIG_FOUND}" != "${TARGET_CONFIG}" ]]; then
  echo ">> Copying $(basename "${CONFIG_FOUND}") to ./build.json..."
  cp -af "${CONFIG_FOUND}" ./build.json
fi

# ------------------------------------------------------------------------------
# 14. Execute Build Pipeline (Process Handover to build_go.sh)
# ------------------------------------------------------------------------------
FINAL_BUILD_ARGS=("${DEFAULT_BUILD_FLAGS[@]}")
if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
  FINAL_BUILD_ARGS+=("${EXTRA_ARGS[@]}")
fi

echo ">> Executing: ${BUILD_GO_SCRIPT} ${FINAL_BUILD_ARGS[*]}"
# Process replacement via 'exec' transfers control to build_go.sh without shell overhead
# and transparently propagates its final exit code to the caller.
exec "${BUILD_GO_SCRIPT}" "${FINAL_BUILD_ARGS[@]}"
