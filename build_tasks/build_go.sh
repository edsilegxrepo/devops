#!/bin/bash
# ==============================================================================
#  DirPoller Go Compilation & Quality Pipeline Engine
#  File      : build_go.sh
#  Version   : 1.2.3xg
#  Date      : 2026-08-27
#  Author    : Critical Systems / XDG
# ==============================================================================
#  Objective:
#    Enforces formatting rules, runs Go linting and vulnerability checks, compiles
#    module binaries with size optimizations, and publishes source/binary zip/tar
#    distributions.
#
#  Design Principles:
#    1. Universal Paths: Converts Cygwin/MSYS2 UNIX-like absolute paths to Windows-native
#       formats (via cygpath) to prevent Go compiler resolution failures.
#    2. Script-Relative Paths: Resolves BINDIR and DISTDIR relative to the script
#       itself, preventing cwd dependency issues.
#    3. Strict Error Boundaries: Asserts exit codes of compiler builds and linter
#       runs, preventing invalid packages.
#    4. Version Fallback: Reads version.txt or falls back to 'dev'.
#    5. Entry Point Autodetect: Reads main.txt for entrypoint location, version, and git hash ldflags targets.
#
#  Syntax:
#    ./build_go.sh [--main-path=<path>] [--update-modules] [--publish]
#                  [--lint-only] [--compile-only] [--testsuite]
# ==============================================================================

# Helper function to normalize path formats (C:\... to /c/...) and prepend to PATH
# Returns: 0 if path was added, 1 otherwise.
normalize_and_add_to_path() {
  local target_dir="$1"
  if [ -d "${target_dir}" ]; then
    # Normalize Windows drive letter format "C:\..." or "C:/..." to UNIX-style "/c/..."
    # to avoid path splitting issues on colon (:) separators in Bash PATH.
    if command -v cygpath &> /dev/null; then
      target_dir="$(cygpath -u "${target_dir}")"
    elif [[ "${target_dir}" =~ ^([a-zA-Z]):[/\\](.*) ]]; then
      target_dir="/${BASH_REMATCH[1],,}/${BASH_REMATCH[2]//\\//}"
    fi
    export PATH="${target_dir}:$PATH"
    return 0
  fi
  return 1
}

# Platform Environment Detection & Setup
if [ "${OS}" == "Windows_NT" ]; then
  OS_TYPE="WIN"

  # Prioritize custom CC toolchain path if defined and valid
  CC_PATH_ADDED=false
  if [ -n "${CC}" ] && [[ "${CC}" == *[/\\]* ]]; then
    if normalize_and_add_to_path "$(dirname "${CC}")"; then
      CC_PATH_ADDED=true
    fi
  fi

  # Fallback to the default Windows-native toolchain path if no custom compiler was configured
  if [ "${CC_PATH_ADDED}" = false ]; then
    normalize_and_add_to_path "d:/dev/mingw64/bin" || true
  fi

  # Prioritize custom Git installation path if defined and valid
  GIT_PATH_ADDED=false
  if [ -n "${GIT_BASE}" ]; then
    if normalize_and_add_to_path "${GIT_BASE}/bin"; then
      GIT_PATH_ADDED=true
    elif normalize_and_add_to_path "${GIT_BASE}"; then
      GIT_PATH_ADDED=true
    fi
  fi

  # Fallback to the default Windows Git path if no custom path was configured
  if [ "${GIT_PATH_ADDED}" = false ]; then
    normalize_and_add_to_path "d:/dev/git/bin" || true
  fi

  OS_ARCH="-w64"
  BIN_EXT=".exe"
else
  OS_TYPE="LINUX"
  OS_ARCH="-x86_64"
  BIN_EXT=""
fi

# Configure Go Proxy registry download target
export GOPROXY="https://proxy.golang.org,direct"

# Corporate Namespace Realm
APP_REALM="criticalsys.net"

# Auto-detect application metadata from active directory and config files
APP_NAME="$(basename "$(pwd)")"
VERSION_VAL="dev"
if [ -f version.txt ]; then
  VERSION_VAL="$(tr -cd '0-9.' < version.txt)"
fi
APP_VERSION="${VERSION_VAL}-$(date +%Y%m%d)"

MAIN_PATH=""
VERSION_PKG="main.version"
BUILD_PKG=""
GIT_HASH=""
if [ -f main.txt ]; then
  MAIN_PATH="$(sed -n '1p' main.txt | tr -cd 'a-zA-Z0-9./_-')"
  _VER_PKG="$(sed -n '2p' main.txt | tr -cd 'a-zA-Z0-9./_-')"
  if [ -n "${_VER_PKG}" ]; then
    VERSION_PKG="${_VER_PKG}"
  fi
  _BLD_PKG="$(sed -n '3p' main.txt | tr -cd 'a-zA-Z0-9./_-')"
  if [ -n "${_BLD_PKG}" ]; then
    BUILD_PKG="${_BLD_PKG}"
  fi
fi

if [ -n "${BUILD_PKG}" ]; then
  if command -v git &> /dev/null && git rev-parse --is-inside-work-tree &> /dev/null; then
    GIT_HASH="$(git rev-parse --short HEAD 2>/dev/null)"
  fi
  GIT_HASH="${GIT_HASH:-unknown}"
fi

# Determine Go module canonical import path
APP_MODULE="${APP_REALM}/${APP_NAME}"

# Resolve absolute path variables relative to the script's home folder
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
BINDIR="${SCRIPT_DIR}/../bin"
DISTDIR="${SCRIPT_DIR}/../distrib"
DISTRIB_ARC="${DISTDIR}/${APP_NAME}-${APP_VERSION%xg*}"

# Windows Path Translation: Map UNIX-like paths to Windows drive paths to avoid Go/GCC tool failures
if [ "${OS_TYPE}" == "WIN" ] && command -v cygpath &> /dev/null; then
  BINDIR="$(cygpath -m "${BINDIR}")"
  DISTDIR="$(cygpath -m "${DISTDIR}")"
  DISTRIB_ARC="$(cygpath -m "${DISTRIB_ARC}")"
fi

# Ensure output target directories are created
mkdir -p "${BINDIR}" "${DISTDIR}"

# Initialize Go module declaration if missing
if [ ! -s go.mod ]; then
  echo "Initialize Go Module ${APP_MODULE}"
  go mod init "${APP_MODULE}"
fi

# Command Line Arguments: Override entrypoint source package path
if [[ $* =~ --main-path=([^[:space:]]+) ]]; then
  MAIN_PATH="${BASH_REMATCH[1]}"
fi

# ==============================================================================
#  Quality Assurance & Audit Phase (Skipped if --compile-only is passed)
# ==============================================================================
if [[ ! $* =~ "--compile-only" ]]; then

  # Run automated test suites if requested
  if [[ $* =~ "--testsuite" ]]; then
    go test -v -cover ./...
    exit $?
  fi

  echo "Generate dependency list"
  go mod download

  # Update dependencies unless locked by donot-update-mod.token
  if [[ $* =~ "--update-modules" ]] || [ ! -f "donot-update-mod.token" ]; then
    echo "Update all modules to latest release"
    go get -u -t ./...
  fi
  go mod tidy
  if [ -d "vendor" ] || [[ $* =~ "--vendor" ]]; then
    echo "Syncing vendor directory (go mod vendor)"
    go mod vendor
  fi

  # Run standard and custom static analyzers
  echo "Linting Code"
  LINT_ERR=0
  gofumpt -l -w -extra .
  go vet ./... || LINT_ERR=1
  if command -v golangci-lint &> /dev/null; then
    golangci-lint run ./... --no-config --timeout=5m || LINT_ERR=1
  else
    echo "Warning: golangci-lint not installed. Skipping lint check."
  fi

  if command -v govulncheck &> /dev/null; then
    govulncheck ./... || LINT_ERR=1
  else
    echo "Warning: govulncheck not installed. Skipping vulnerability check."
  fi

  if command -v gosec &> /dev/null; then
    gosec -quiet ./... || LINT_ERR=1
  else
    echo "Warning: gosec not installed. Skipping security scan."
  fi

  # Halt script if user requested a lint-only check
  if [[ $* =~ "--lint-only" ]]; then
    exit $LINT_ERR
  fi
fi

# ==============================================================================
#  Compilation Phase
# ==============================================================================
LDFLAGS="-s -w -X ${VERSION_PKG}=${APP_VERSION}"
if [ -n "${BUILD_PKG}" ]; then
  LDFLAGS="${LDFLAGS} -X ${BUILD_PKG}=${GIT_HASH}"
fi

echo "Build Module ${APP_MODULE} - Version: ${APP_VERSION} [${VERSION_PKG}]${BUILD_PKG:+ - Build: ${GIT_HASH} [${BUILD_PKG}]} - Main Module: ${MAIN_PATH:-generic}"

# Build with optimization flags:
# -s -w       Strips symbols and debug tables to reduce binary footprint
# -trimpath   Strips developer path metadata from panic traces
# -buildmode  Emits Position Independent Executable (PIE) binaries
if ! go build -v -buildvcs=false -ldflags "${LDFLAGS}" -trimpath -buildmode=pie -o "${BINDIR}/${APP_NAME}${BIN_EXT}" ${MAIN_PATH:+"${MAIN_PATH}"}; then
  echo "ERROR: Compilation failed!"
  exit 1
fi

# ==============================================================================
#  Workspace & Environment Sanitation Phase
# ==============================================================================
# Safely run sanitization recursively on all code files and metadata files (ignoring hidden dot folders)
find . -type f \( -name "*.go" -o -name "go.mod" -o -name "go.sum" -o -name "*.txt" -o -name "*.md" -o -name "LICENSE*" \) -not -path '*/.*' -exec dos2unix -k -q {} + 2>/dev/null || true
find . -type f \( -name "*.go" -o -name "go.mod" -o -name "go.sum" \) -not -path '*/.*' -exec chmod 644 {} + 2>/dev/null || true

# Adjust execution permissions on the produced binary and print build validation metadata
chmod 755 "${BINDIR}/${APP_NAME}${BIN_EXT}"
# Skip validation run if cross-compilation is detected (target GOOS/GOARCH is different from host)
if { [ -z "${GOOS}" ] || [ "${GOOS}" == "$(go env GOOS)" ]; } &&
  { [ -z "${GOARCH}" ] || [ "${GOARCH}" == "$(go env GOARCH)" ]; }; then
  "${BINDIR}/${APP_NAME}${BIN_EXT}" --version
else
  echo "Skipping validation run (cross-compilation detected: GOOS=${GOOS:-$(go env GOOS)} GOARCH=${GOARCH:-$(go env GOARCH)})"
fi

# ==============================================================================
#  Distribution Packaging Phase (Executed if --publish is passed)
# ==============================================================================
if [[ $* =~ "--publish" ]]; then
  echo "Generating distribution archive [${DISTRIB_ARC}]"
  if [ "${OS_TYPE}" == "WIN" ]; then
    SRC_ARC="${DISTRIB_ARC}-src.zip"
    BIN_ARC="${DISTRIB_ARC}${OS_ARCH}.zip"
    rm -f "${SRC_ARC}"
    zip -9rq "${SRC_ARC}" -- *
    zip -9mrjq "${BIN_ARC}" "${BINDIR}/${APP_NAME}${BIN_EXT}"
  else
    SRC_ARC="${DISTRIB_ARC}-src.tar.xz"
    BIN_ARC="${DISTRIB_ARC}${OS_ARCH}.tar.xz"
    tar Jcf "${SRC_ARC}" -- *
    tar Jcf "${BIN_ARC}" -C "${BINDIR}" "${APP_NAME}${BIN_EXT}"
    rm -f "${BINDIR}/${APP_NAME}${BIN_EXT}"
  fi

  echo "Calculating SHA256 checksums"
  (
    cd "${DISTDIR}" || exit 1
    if command -v sha256sum &> /dev/null; then
      sha256sum "$(basename "${SRC_ARC}")" "$(basename "${BIN_ARC}")" > SHA256SUMS
    elif command -v shasum &> /dev/null; then
      shasum -a 256 "$(basename "${SRC_ARC}")" "$(basename "${BIN_ARC}")" > SHA256SUMS
    fi
  )
fi
