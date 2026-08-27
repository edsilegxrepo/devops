#!/bin/bash
# ==============================================================================
#  Python Windows Distribution Alignment & Devel Packager Engine
#  File      : build_python_win.sh
#  Version   : 1.1.0xg
#  Date      : 2026-08-27
#  Author    : Critical Systems / XDG
# ==============================================================================
#  Objective:
#    Processes Windows Python distribution zip archives (standard and freethreaded)
#    from a staging directory (e.g., f:/stage/upload/staging), stripping non-essential
#    packages (Doc, Tkinter, IDLE, Tcl/Tk DLLs, turtle, installer manifests),
#    repackaging the streamlined runtime distributions as:
#      python-<version>-bin-amd64.zip
#      python-<version>t-bin-amd64.zip
#    and assembling all segregated components into a standalone development archive:
#      python-<version>-devel-amd64.zip
#    while retaining core DLL dependencies inside the binary distribution.
#
#  Syntax:
#    ./build_python_win.sh [--staging-dir <path>] [--distrib-dir <path>]
#                          [--version <version>] [--diff-only]
#                          [--no-overwrite] [--remove]
#                          [--dry-run] [--verbose] [-h | --help]
# ==============================================================================

set -euo pipefail

# Platform Environment Detection & Verification
OS_ENV="UNKNOWN"
if [[ "$(uname -s)" == *"CYGWIN"* ]]; then
  OS_ENV="CYGWIN"
elif [[ "$(uname -s)" == *"MSYS"* || "$(uname -s)" == *"MINGW"* ]]; then
  OS_ENV="MSYS"
fi

if [ "${OS_ENV}" = "UNKNOWN" ]; then
  echo -e "\n[ERROR] Unsupported environment. This script must be executed inside Cygwin or MSYS2." >&2
  exit 1
fi

export PATH="/usr/bin:/bin:${PATH}"

# ==============================================================================
#  Global Configuration & Defaults
# ==============================================================================

DEFAULT_STAGING_DIR="f:/stage/upload/staging"
DEFAULT_VERSION=""

STAGING_DIR="${DEFAULT_STAGING_DIR}"
DISTRIB_DIR=""
VERSION_TAG="${DEFAULT_VERSION}"

DIFF_ONLY=false
NO_OVERWRITE=false
REMOVE_SOURCE=false
DRY_RUN=false
VERBOSE=false

TEMP_WORKSPACE=""

# ==============================================================================
#  Path Normalization Utilities
# ==============================================================================

to_posix_path() {
  local p="${1:-}"
  [ -z "${p}" ] && echo "" && return 0
  local clean_p="${p//\\//}"
  if command -v cygpath &> /dev/null; then
    cygpath -u "${clean_p}" 2> /dev/null || echo "${clean_p}"
  else
    echo "${clean_p}"
  fi
}

to_win_path() {
  local p="${1:-}"
  [ -z "${p}" ] && echo "" && return 0
  local clean_p="${p//\\//}"
  if command -v cygpath &> /dev/null; then
    cygpath -m "${clean_p}" 2> /dev/null || echo "${clean_p}"
  else
    echo "${clean_p}"
  fi
}

# ==============================================================================
#  Logging Helpers
# ==============================================================================

log_info()  { echo "[INFO]  $*" >&2; }
log_warn()  { echo "[WARN]  $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }
log_step()  { echo -e "\n=== $* ===" >&2; }

# ==============================================================================
#  Workspace Lifecycle Management
# ==============================================================================

# shellcheck disable=SC2329
cleanup_workspace() {
  if [ -n "${TEMP_WORKSPACE}" ] && [ -d "${TEMP_WORKSPACE}" ]; then
    if [ "${VERBOSE}" = true ]; then
      log_info "Cleaning up temporary workspace: ${TEMP_WORKSPACE}"
    fi
    rm -rf "${TEMP_WORKSPACE}"
  fi
}

trap cleanup_workspace EXIT INT TERM

create_temp_workspace() {
  local base_tmp="${TMPDIR:-${TMP:-${TEMP:-/tmp}}}"
  local posix_base
  posix_base=$(to_posix_path "${base_tmp}")
  mkdir -p "${posix_base}"
  local ts
  ts=$(date +%Y%m%d%H%M%S)
  TEMP_WORKSPACE="${posix_base}/pyalign-${ts}-$BASHPID"
  mkdir -p "${TEMP_WORKSPACE}"
}

# ==============================================================================
#  CLI Argument Parsing & Usage
# ==============================================================================

show_help() {
  cat << EOF
Usage: $(basename "$0") [options]

Objective:
  Strips non-essential GUI, documentation, and demo components from Windows Python
  source distribution archives, generating aligned runtime binary archives
  (python-<version>-bin-amd64.zip) and a standalone development archive
  (python-<version>-devel-amd64.zip).

Options:
  --staging-dir <path>     Directory containing input distribution zip archives
                           (Default: ${DEFAULT_STAGING_DIR})
  --distrib-dir <path>     Directory for generated destination archives
                           (Default: Same as --staging-dir)
  --version <ver>          Python version string (Default: ${DEFAULT_VERSION})
  --diff-only              Perform and display rule comparison without writing archives
  --no-overwrite           Do not overwrite existing destination archives (bin and devel)
  --remove                 Remove source archive(s) after successful destination packaging
  --dry-run                Simulate extraction, segregation, and archive assembly
  --verbose                Enable verbose file tracking output
  -h, --help               Display this help menu

Examples:
  # In-depth diff analysis only:
  $(basename "$0") --diff-only

  # Full alignment and packaging in-place:
  $(basename "$0") --staging-dir f:/stage/upload/staging

  # Separate staging and distribution directories:
  $(basename "$0") --staging-dir f:/stage/upload/staging --distrib-dir f:/stage/upload/pending

  # Prevent overwriting existing packages and remove source archive on success:
  $(basename "$0") --no-overwrite --remove
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --staging-dir)
      [ -z "${2:-}" ] || [[ "$2" == -* ]] && log_error "--staging-dir requires a path argument." && exit 2
      STAGING_DIR="$2"
      shift 2
      ;;
    --distrib-dir)
      [ -z "${2:-}" ] || [[ "$2" == -* ]] && log_error "--distrib-dir requires a path argument." && exit 2
      DISTRIB_DIR="$2"
      shift 2
      ;;
    --version)
      [ -z "${2:-}" ] || [[ "$2" == -* ]] && log_error "--version requires a version argument." && exit 2
      VERSION_TAG="$2"
      shift 2
      ;;
    --diff-only)
      DIFF_ONLY=true
      shift
      ;;
    --no-overwrite)
      NO_OVERWRITE=true
      shift
      ;;
    --remove)
      REMOVE_SOURCE=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --verbose)
      VERBOSE=true
      shift
      ;;
    -h | --help)
      show_help
      exit 0
      ;;
    *)
      log_error "Unknown argument: $1"
      show_help
      exit 2
      ;;
  esac
done

# Resolve distrib directory default
if [ -z "${DISTRIB_DIR}" ]; then
  DISTRIB_DIR="${STAGING_DIR}"
fi

# ==============================================================================
#  Validation & Prerequisites Verification
# ==============================================================================

POSIX_STAGING=$(to_posix_path "${STAGING_DIR}")
POSIX_DISTRIB=$(to_posix_path "${DISTRIB_DIR}")

if [ ! -d "${POSIX_STAGING}" ]; then
  log_error "Staging directory not found: $(to_win_path "${STAGING_DIR}")"
  exit 2
fi

mkdir -p "${POSIX_DISTRIB}"

# Required toolchain binaries
REQUIRED_BINS=("unzip" "zip" "find" "sha256sum" "sed" "grep" "sort" "wc" "awk")
for b in "${REQUIRED_BINS[@]}"; do
  if ! command -v "${b}" &> /dev/null; then
    log_error "Required system utility '${b}' is missing from PATH."
    exit 3
  fi
done

# Version resolution & auto-detection
if [ -z "${VERSION_TAG}" ]; then
  SRC_MATCH=$(find "${POSIX_STAGING}" -maxdepth 1 -name "python-*-amd64.zip" ! -name "*-bin-*" ! -name "*-devel-*" | sort | head -n 1)
  if [ -n "${SRC_MATCH}" ]; then
    SRC_FILENAME=$(basename "${SRC_MATCH}")
    VERSION_TAG=$(echo "${SRC_FILENAME}" | sed -E 's/^python-([0-9.]+t?)-amd64\.zip$/\1/' | sed 's/t$//')
    log_info "Auto-detected Python version: ${VERSION_TAG}"
  else
    VERSION_TAG="3.14.7"
  fi
fi

VERSION_MAJOR_MINOR=$(echo "${VERSION_TAG}" | cut -d. -f1,2)

# Source archive definitions in staging
SRC_STD_ZIP_NAME="python-${VERSION_TAG}-amd64.zip"
SRC_FREE_ZIP_NAME="python-${VERSION_TAG}t-amd64.zip"

SRC_STD_ZIP_PATH="${POSIX_STAGING}/${SRC_STD_ZIP_NAME}"
SRC_FREE_ZIP_PATH="${POSIX_STAGING}/${SRC_FREE_ZIP_NAME}"

# Destination archive definitions in distrib
DST_STD_BIN_NAME="python-${VERSION_TAG}-bin-amd64.zip"
DST_FREE_BIN_NAME="python-${VERSION_TAG}t-bin-amd64.zip"
DST_DEVEL_NAME="python-${VERSION_TAG}-devel-amd64.zip"

DST_STD_BIN_PATH="${POSIX_DISTRIB}/${DST_STD_BIN_NAME}"
DST_FREE_BIN_PATH="${POSIX_DISTRIB}/${DST_FREE_BIN_NAME}"
DST_DEVEL_PATH="${POSIX_DISTRIB}/${DST_DEVEL_NAME}"

if [ ! -f "${SRC_STD_ZIP_PATH}" ]; then
  log_error "Source distribution archive not found: $(to_win_path "${SRC_STD_ZIP_PATH}")"
  exit 2
fi

HAS_FREE_ARCHIVE=false
if [ -f "${SRC_FREE_ZIP_PATH}" ]; then
  HAS_FREE_ARCHIVE=true
fi

# Guard: Check --no-overwrite flag
if [ "${NO_OVERWRITE}" = true ]; then
  DST_PRESENT=true
  if [ ! -f "${DST_STD_BIN_PATH}" ] || [ ! -f "${DST_DEVEL_PATH}" ]; then
    DST_PRESENT=false
  fi
  if [ "${HAS_FREE_ARCHIVE}" = true ] && [ ! -f "${DST_FREE_BIN_PATH}" ]; then
    DST_PRESENT=false
  fi
  if [ "${DST_PRESENT}" = true ]; then
    log_info "Destination archives (${DST_STD_BIN_NAME}, ${DST_DEVEL_NAME}) already exist and --no-overwrite specified. Skipping rebuild."
    exit 0
  fi
fi

# ==============================================================================
#  Rule Definitions for Segregation
# ==============================================================================
# Directories to remove from runtime binary archive and move to devel archive:
SEPARATE_DIRS=(
  "Doc"
  "Lib/idlelib"
  "Lib/tkinter"
  "Lib/turtledemo"
)

# Individual files to remove from runtime binary archive and move to devel archive:
SEPARATE_FILES=(
  "Lib/turtle.py"
  "DLLs/tcl90.dll"
  "DLLs/tcl9tk90.dll"
  "DLLs/python.cat"
  "__install__.json"
)

# Note: The following native DLLs are explicitly RETAINED in the binary runtime archive:
#   All Python core binaries, headers, and standard modules.

# ==============================================================================
#  In-Depth Inspection & Diff Engine
# ==============================================================================

perform_rule_inspection() {
  log_step "Inspection & Segregation Rules Audit"
  log_info "Staging Directory     : $(to_win_path "${STAGING_DIR}")"
  log_info "Distribution Directory: $(to_win_path "${DISTRIB_DIR}")"
  log_info "Source Archive        : $(to_win_path "${SRC_STD_ZIP_PATH}")"
  if [ "${HAS_FREE_ARCHIVE}" = true ]; then
    log_info "Freethreaded Archive  : $(to_win_path "${SRC_FREE_ZIP_PATH}")"
  fi

  create_temp_workspace
  local comp_dir="${TEMP_WORKSPACE}/diff_audit"
  mkdir -p "${comp_dir}"

  unzip -Z1 "${SRC_STD_ZIP_PATH}" | sed 's/\\/\//g' | grep -v '/$' | sort > "${comp_dir}/src_files.txt"
  local total_files
  total_files=$(wc -l < "${comp_dir}/src_files.txt")

  echo "--------------------------------------------------------------------------------"
  printf "%-40s : %6d files\n" "Source Archive (${SRC_STD_ZIP_NAME})" "${total_files}"
  echo "--------------------------------------------------------------------------------"

  local doc_count idle_count tk_lib_count turtle_demo_count turtle_py_count
  local tcl_dll_count tk_pyd_count cat_count manifest_count

  doc_count=$(grep -c '^Doc/' "${comp_dir}/src_files.txt" || true)
  idle_count=$(grep -c '^Lib/idlelib/' "${comp_dir}/src_files.txt" || true)
  tk_lib_count=$(grep -c '^Lib/tkinter/' "${comp_dir}/src_files.txt" || true)
  turtle_demo_count=$(grep -c '^Lib/turtledemo/' "${comp_dir}/src_files.txt" || true)
  turtle_py_count=$(grep -c '^Lib/turtle\.py$' "${comp_dir}/src_files.txt" || true)
  tcl_dll_count=$(grep -E -c '^DLLs/(tcl90|tcl9tk90)\.dll$' "${comp_dir}/src_files.txt" || true)
  tk_pyd_count=$(grep -E -c '^DLLs/_tkinter.*\.pyd$' "${comp_dir}/src_files.txt" || true)
  cat_count=$(grep -E -c '^(DLLs/)?python\.cat$' "${comp_dir}/src_files.txt" || true)
  manifest_count=$(grep -c '^__install__\.json$' "${comp_dir}/src_files.txt" || true)

  local segregated_total=$(( doc_count + idle_count + tk_lib_count + turtle_demo_count + turtle_py_count + tcl_dll_count + tk_pyd_count + cat_count + manifest_count ))

  echo -e "\nComponents to Segregate into Development Archive (${segregated_total} files):"
  echo "--------------------------------------------------------------------------------"
  printf "%-25s | %-12s | %s\n" "Component" "File Count" "Destination Archive"
  echo "--------------------------+--------------+--------------------------------------"
  printf "%-25s | %12d | %s\n" "Doc/ (HTML/CHM Manual)" "${doc_count}" "${DST_DEVEL_NAME}"
  printf "%-25s | %12d | %s\n" "Lib/idlelib (IDLE GUI)" "${idle_count}" "${DST_DEVEL_NAME}"
  printf "%-25s | %12d | %s\n" "Lib/tkinter (Tk Bindings)" "${tk_lib_count}" "${DST_DEVEL_NAME}"
  printf "%-25s | %12d | %s\n" "Lib/turtledemo (Turtle)" "${turtle_demo_count}" "${DST_DEVEL_NAME}"
  printf "%-25s | %12d | %s\n" "Lib/turtle.py" "${turtle_py_count}" "${DST_DEVEL_NAME}"
  printf "%-25s | %12d | %s\n" "DLLs (tcl90, tcl9tk90)" "${tcl_dll_count}" "${DST_DEVEL_NAME}"
  printf "%-25s | %12d | %s\n" "DLLs/_tkinter*.pyd" "${tk_pyd_count}" "${DST_DEVEL_NAME}"
  printf "%-25s | %12d | %s\n" "DLLs/python.cat" "${cat_count}" "${DST_DEVEL_NAME}"
  printf "%-25s | %12d | %s\n" "__install__.json" "${manifest_count}" "${DST_DEVEL_NAME}"
  echo "--------------------------------------------------------------------------------"

  echo -e "\nComponents Included in Runtime Binary Archive:"
  echo "--------------------------------------------------------------------------------"
  printf "%-25s | %-12s | %s\n" "Component" "Status" "Destination Archive"
  echo "--------------------------+--------------+--------------------------------------"
  printf "%-25s | %-12s | %s\n" "Enable-LongPaths.reg" "Injected" "${DST_STD_BIN_NAME}"
  printf "%-25s | %-12s | %s\n" "Scripts/ (pip launchers)" "Bundled" "${DST_STD_BIN_NAME}"
  printf "%-25s | %-12s | %s\n" "pip & ensurepip" "Bundled" "${DST_STD_BIN_NAME}"
  printf "%-25s | %-12s | %s\n" "Core Python Binaries" "Retained" "${DST_STD_BIN_NAME}"
  printf "%-25s | %-12s | %s\n" "Standard Library" "Retained" "${DST_STD_BIN_NAME}"
  printf "%-25s | %-12s | %s\n" "C Headers & Import Libs" "Retained" "${DST_STD_BIN_NAME}"
  echo "--------------------------------------------------------------------------------"
}

if [ "${DIFF_ONLY}" = true ]; then
  perform_rule_inspection
  log_info "--diff-only specified. Halting without building archives."
  exit 0
fi

# ==============================================================================
#  Alignment & Devel Packaging Workflow
# ==============================================================================

perform_rule_inspection

log_step "Executing Distribution Alignment & Devel Archive Assembly"

create_temp_workspace
WS_STD="${TEMP_WORKSPACE}/extract_std"
WS_FREE="${TEMP_WORKSPACE}/extract_free"
WS_DEVEL="${TEMP_WORKSPACE}/devel_payload"

mkdir -p "${WS_STD}" "${WS_DEVEL}"

# 1. Unpack Standard Distribution Archive
log_info "Unpacking source standard archive: ${SRC_STD_ZIP_NAME}..."
unzip -q "${SRC_STD_ZIP_PATH}" -d "${WS_STD}"

# 2. Unpack Freethreaded Distribution Archive (if present)
if [ "${HAS_FREE_ARCHIVE}" = true ]; then
  mkdir -p "${WS_FREE}"
  log_info "Unpacking source freethreaded archive: ${SRC_FREE_ZIP_NAME}..."
  unzip -q "${SRC_FREE_ZIP_PATH}" -d "${WS_FREE}"
fi

# 3. Segregate Devel/Extra Payload into WS_DEVEL from WS_STD
log_info "Segregating extraneous packages into development payload..."

for d in "${SEPARATE_DIRS[@]}"; do
  if [ -d "${WS_STD}/${d}" ]; then
    mkdir -p "$(dirname "${WS_DEVEL}/${d}")"
    cp -af "${WS_STD}/${d}" "${WS_DEVEL}/${d}"
    rm -rf "${WS_STD:?}/${d:?}"
  fi
  if [ "${HAS_FREE_ARCHIVE}" = true ] && [ -d "${WS_FREE}/${d}" ]; then
    rm -rf "${WS_FREE:?}/${d:?}"
  fi
done

for f in "${SEPARATE_FILES[@]}"; do
  if [ -f "${WS_STD}/${f}" ]; then
    mkdir -p "$(dirname "${WS_DEVEL}/${f}")"
    cp -af "${WS_STD}/${f}" "${WS_DEVEL}/${f}"
    rm -f "${WS_STD}/${f}"
  fi
  if [ "${HAS_FREE_ARCHIVE}" = true ] && [ -f "${WS_FREE}/${f}" ]; then
    rm -f "${WS_FREE}/${f}"
  fi
done

# Handle _tkinter C extensions
if [ -f "${WS_STD}/DLLs/_tkinter.pyd" ]; then
  mkdir -p "${WS_DEVEL}/DLLs"
  cp -af "${WS_STD}/DLLs/_tkinter.pyd" "${WS_DEVEL}/DLLs/"
  rm -f "${WS_STD}/DLLs/_tkinter.pyd"
fi

if [ "${HAS_FREE_ARCHIVE}" = true ] && [ -f "${WS_FREE}/DLLs/_tkinter.cp314t-win_amd64.pyd" ]; then
  mkdir -p "${WS_DEVEL}/DLLs"
  cp -af "${WS_FREE}/DLLs/_tkinter.cp314t-win_amd64.pyd" "${WS_DEVEL}/DLLs/"
  rm -f "${WS_FREE}/DLLs/_tkinter.cp314t-win_amd64.pyd"
fi

find "${WS_STD}/DLLs" -name "_tkinter*.pyd" -delete 2> /dev/null || true
if [ "${HAS_FREE_ARCHIVE}" = true ]; then
  find "${WS_FREE}/DLLs" -name "_tkinter*.pyd" -delete 2> /dev/null || true
fi

# 4. Inject Windows Long Paths Configuration Registry Script
log_info "Injecting Enable-LongPaths.reg registry script into runtime distribution..."
create_longpaths_reg() {
  local target_dir="$1"
  printf "Windows Registry Editor Version 5.00\r\n\r\n[HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Control\\FileSystem]\r\n\"LongPathsEnabled\"=dword:00000001\r\n" > "${target_dir}/Enable-LongPaths.reg"
}

create_longpaths_reg "${WS_STD}"
if [ "${HAS_FREE_ARCHIVE}" = true ]; then
  create_longpaths_reg "${WS_FREE}"
fi

# 5. Generate Portable Pip Launcher Executables in Scripts/
log_info "Generating portable pip launcher executables in Scripts/..."
generate_pip_launchers() {
  local target_dir="$1"
  local ver_major_minor="$2"
  local is_free="${3:-false}"

  local t64_path="${target_dir}/Lib/site-packages/pip/_vendor/distlib/t64.exe"
  if [ ! -f "${t64_path}" ]; then
    log_warn "Pip distlib launcher t64.exe not found in ${target_dir}; skipping pip executable generation."
    return 0
  fi

  mkdir -p "${target_dir}/Scripts"

  local rand_id="$BASHPID-${RANDOM}"
  local tmp_main="${TEMP_WORKSPACE}/pip_main_${rand_id}"
  mkdir -p "${tmp_main}"
  cat << 'EOF' > "${tmp_main}/__main__.py"
import sys
from pip._internal.cli.main import main
if __name__ == '__main__':
    sys.argv[0] = sys.argv[0].removesuffix('.exe')
    sys.exit(main())
EOF

  local zip_payload="${TEMP_WORKSPACE}/pip_payload_${rand_id}.zip"
  (cd "${tmp_main}" && zip -0 -q "${zip_payload}" __main__.py)

  local pip_exe="${target_dir}/Scripts/pip.exe"
  local pip3_exe="${target_dir}/Scripts/pip3.exe"
  local pip_ver_exe="${target_dir}/Scripts/pip${ver_major_minor}.exe"
  local shebang_file="${TEMP_WORKSPACE}/shebang_${rand_id}.txt"

  printf "#!python.exe\n" > "${shebang_file}"
  cat "${t64_path}" "${shebang_file}" "${zip_payload}" > "${pip_exe}"
  chmod +x "${pip_exe}"
  cp -af "${pip_exe}" "${pip3_exe}"
  cp -af "${pip_exe}" "${pip_ver_exe}"

  if [ "${is_free}" = true ]; then
    local pip_free_exe="${target_dir}/Scripts/pip${ver_major_minor}t.exe"
    cp -af "${pip_exe}" "${pip_free_exe}"
  fi

  rm -rf "${tmp_main}" "${zip_payload}" "${shebang_file}"
}

generate_pip_launchers "${WS_STD}" "${VERSION_MAJOR_MINOR}" false
if [ "${HAS_FREE_ARCHIVE}" = true ]; then
  generate_pip_launchers "${WS_FREE}" "${VERSION_MAJOR_MINOR}" true
fi

# 6. Dry Run Guard
if [ "${DRY_RUN}" = true ]; then
  log_warn "--dry-run specified. Verification of packaging payload completed successfully without writing to disk."
  exit 0
fi

# 7. Repack Aligned Standard Runtime Binary Archive
log_info "Repackaging standard runtime binary archive: ${DST_STD_BIN_NAME}..."
NEW_STD_BIN_ZIP="${TEMP_WORKSPACE}/${DST_STD_BIN_NAME}"
(cd "${WS_STD}" && zip -9rq "${NEW_STD_BIN_ZIP}" -- .)

# 8. Repack Aligned Freethreaded Runtime Binary Archive (if present)
NEW_FREE_BIN_ZIP=""
if [ "${HAS_FREE_ARCHIVE}" = true ]; then
  log_info "Repackaging freethreaded runtime binary archive: ${DST_FREE_BIN_NAME}..."
  NEW_FREE_BIN_ZIP="${TEMP_WORKSPACE}/${DST_FREE_BIN_NAME}"
  (cd "${WS_FREE}" && zip -9rq "${NEW_FREE_BIN_ZIP}" -- .)
fi

# 9. Assemble Devel Distribution Archive
NEW_DEVEL_ZIP="${TEMP_WORKSPACE}/${DST_DEVEL_NAME}"
DEVEL_ITEM_COUNT=$(find "${WS_DEVEL}" -mindepth 1 | wc -l || echo 0)
log_info "Assembling development distribution archive: ${DST_DEVEL_NAME} (${DEVEL_ITEM_COUNT} items)..."
(cd "${WS_DEVEL}" && zip -9rq "${NEW_DEVEL_ZIP}" -- .)

# 10. Test Archive Integrity
log_info "Verifying archive integrity..."
unzip -tq "${NEW_STD_BIN_ZIP}"
if [ -n "${NEW_FREE_BIN_ZIP}" ] && [ -f "${NEW_FREE_BIN_ZIP}" ]; then
  unzip -tq "${NEW_FREE_BIN_ZIP}"
fi
unzip -tq "${NEW_DEVEL_ZIP}"
log_info "All generated archives passed integrity verification tests."

# 11. Promote Repackaged Archives to Distribution Directory
log_info "Promoting generated archives to distribution destination: $(to_win_path "${DISTRIB_DIR}")..."

ORIG_STD_SIZE=$(stat -c%s "${SRC_STD_ZIP_PATH}" 2>/dev/null || echo 0)
ORIG_FREE_SIZE=0
if [ "${HAS_FREE_ARCHIVE}" = true ]; then
  ORIG_FREE_SIZE=$(stat -c%s "${SRC_FREE_ZIP_PATH}" 2>/dev/null || echo 0)
fi

promote_archive() {
  local src="$1"
  local dst="$2"
  [ -f "${dst}" ] && rm -f "${dst}" 2>/dev/null || true
  if ! cp -f "${src}" "${dst}" 2>/dev/null; then
    cat "${src}" > "${dst}"
  fi
}

promote_archive "${NEW_STD_BIN_ZIP}" "${DST_STD_BIN_PATH}"
if [ -n "${NEW_FREE_BIN_ZIP}" ] && [ -f "${NEW_FREE_BIN_ZIP}" ]; then
  promote_archive "${NEW_FREE_BIN_ZIP}" "${DST_FREE_BIN_PATH}"
fi
promote_archive "${NEW_DEVEL_ZIP}" "${DST_DEVEL_PATH}"

NEW_STD_SIZE=$(stat -c%s "${DST_STD_BIN_PATH}")
NEW_FREE_SIZE=0
if [ "${HAS_FREE_ARCHIVE}" = true ]; then
  NEW_FREE_SIZE=$(stat -c%s "${DST_FREE_BIN_PATH}")
fi
NEW_DEVEL_SIZE=$(stat -c%s "${DST_DEVEL_PATH}")

# 12. Generate SHA256 Checksums
log_info "Calculating SHA256 checksums..."
(
  cd "${POSIX_DISTRIB}" || exit 1
  SUM_TARGETS=("${DST_STD_BIN_NAME}")
  if [ "${HAS_FREE_ARCHIVE}" = true ]; then
    SUM_TARGETS+=("${DST_FREE_BIN_NAME}")
  fi
  SUM_TARGETS+=("${DST_DEVEL_NAME}")
  sha256sum "${SUM_TARGETS[@]}" > SHA256SUMS
)

# 13. Remove Source Archives (if --remove specified)
if [ "${REMOVE_SOURCE}" = true ]; then
  if [ -f "${DST_STD_BIN_PATH}" ] && [ -f "${DST_DEVEL_PATH}" ]; then
    log_info "Removing source archive from staging directory: ${SRC_STD_ZIP_NAME}..."
    rm -f "${SRC_STD_ZIP_PATH}"
    if [ "${HAS_FREE_ARCHIVE}" = true ] && [ -f "${DST_FREE_BIN_PATH}" ] && [ -f "${SRC_FREE_ZIP_PATH}" ]; then
      log_info "Removing freethreaded source archive from staging directory: ${SRC_FREE_ZIP_NAME}..."
      rm -f "${SRC_FREE_ZIP_PATH}"
    fi
  else
    log_warn "Destination archives not verified; skipping source archive removal."
  fi
fi

# ==============================================================================
#  Summary & Metrics Output
# ==============================================================================

log_step "Distribution Alignment & Packaging Complete"

fmt_mb() {
  awk "BEGIN {printf \"%.2f\", $1 / 1048576}"
}

fmt_pct() {
  awk "BEGIN {if ($1 > 0 && $2 > 0) printf \"%.1f\", (($1 - $2) * 100) / $1; else printf \"0.0\"}"
}

echo "================================================================================"
printf "%-36s | %14s | %14s | %10s\n" "Archive Artifact" "Source Size" "Generated Size" "Reduction"
echo "-------------------------------------+----------------+----------------+----------"

printf "%-36s | %11s MB | %11s MB | %8s%%\n" \
  "${DST_STD_BIN_NAME}" \
  "$(fmt_mb "${ORIG_STD_SIZE}")" \
  "$(fmt_mb "${NEW_STD_SIZE}")" \
  "$(fmt_pct "${ORIG_STD_SIZE}" "${NEW_STD_SIZE}")"

if [ "${HAS_FREE_ARCHIVE}" = true ]; then
  printf "%-36s | %11s MB | %11s MB | %8s%%\n" \
    "${DST_FREE_BIN_NAME}" \
    "$(fmt_mb "${ORIG_FREE_SIZE}")" \
    "$(fmt_mb "${NEW_FREE_SIZE}")" \
    "$(fmt_pct "${ORIG_FREE_SIZE}" "${NEW_FREE_SIZE}")"
fi

printf "%-36s | %14s | %11s MB | %10s\n" \
  "${DST_DEVEL_NAME} (NEW)" \
  "N/A" \
  "$(fmt_mb "${NEW_DEVEL_SIZE}")" \
  "N/A"
echo "================================================================================"

echo -e "\nSHA256 Manifest (${POSIX_DISTRIB}/SHA256SUMS):"
cat "${POSIX_DISTRIB}/SHA256SUMS"
echo "================================================================================"

log_info "Python Windows distribution alignment pipeline completed successfully."
exit 0
