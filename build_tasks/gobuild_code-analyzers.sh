#!/bin/bash
# shellcheck disable=SC2329,SC2030,SC2031,SC2155
# --------------------------------------------------------------------------------
#  gobuild_code-analyzers.sh
#  v1.1.5xg  2026/04/27  XDG
# --------------------------------------------------------------------------------

# Objectives:
#   - Automated Build Pipeline: Provide a streamlined, reproducible process for building a curated suite of Go static analysis and development tools.
#   - Unified Tooling: Maintain a consistent set of essential Go tools in a portable, pre-compiled format.
#   - Cross-Platform Support: Support high-performance, statically linked binaries for both Windows (x86_64-windows-gnu) and Linux (x86_64-linux-musl).
#   - Advanced Compilation: Leverage the Zig toolchain as a drop-in C compiler replacement (CGO_ENABLED=1) to achieve easy cross-compilation with modern C libraries.
#   - Version Integrity: Automatically derive semantic versions or short commit hashes to ensure every binary's origin is traceable.
#
# Core Components:
#   - Global Configuration: Defines centralized paths, build options (PIE, trimpath), and cross-compilation environment variables.
#   - Build Utilities: Modular shell functions orchestration (`repoPrep`, `codeAnalysis`, `codeBuild`, `generateArchive`) that form the backbone of the pipeline.
#   - Tool-Specific Wrappers: Lightweight subshell environments that configure package-specific variables and metadata.
#   - Parallel Execution Engine: A robust process management system that utilizes background subshells and PID tracking to build all tools concurrently.
#
# Data Flows:
#   1. Remote-to-Local: Fetches the latest source code from GitHub repositories into a dedicated `compile` workspace.
#   2. metadata Extraction: Inspects Git tags and commit history to generate a unique `PKG_VER` identifier.
#   3. Pre-processor: Synchronizes Go modules (`tidy`), handles vendoring, and ensures source code sanity with `fmt` and `vet`.
#   4. Multi-Target Compilation: Dispatches build commands to the Go compiler, injecting version flags via `LDFLAGS` and routing CGO calls through Zig.
#   5. Distribution & Cleanup: Compresses binaries into architecture-specific `.tar.xz` archives, moves them to the `distrib` folder, and purges temporary working files.
# -------------------------------------------------------------------
# Syntax:  ./gobuild_code-analyzers.sh [--clean-cache] [all | <build_function>]
# Example: ./gobuild_code-analyzers.sh --clean-cache all
# Example: ./gobuild_code-analyzers.sh build_gosec
#
# References: see below the toolchain organized by the nature of each tool.
# +----------------+------------------------------------------+--------------------------------------------+------------------------------------------+
# | Tool (21)      | Repo URL                                 | Short Description                          | Recommended Command Line                 |
# +----------------+------------------------------------------+--------------------------------------------+------------------------------------------+
# | TYPE: FORMATTING & STYLE (4)                                                                                                                      |
# +----------------+------------------------------------------+--------------------------------------------+------------------------------------------+
# | gofumpt        | github.com/mvdan/gofumpt                 | Stricter, more opinionated Go formatter    | gofumpt -w -extra .                      |
# | gocritic       | github.com/go-critic/go-critic           | Finds stylistic and performance micro-bugs | gocritic check ./...                     |
# | goconst        | github.com/jgautheron/goconst            | Finds repeated strings to make constants   | goconst -min-occurrences 3 ./...         |
# | go-mnd         | github.com/tommy-muehle/go-mnd           | Detects magic numbers (unnamed constants)  | mnd ./...                                |
# +----------------+------------------------------------------+--------------------------------------------+------------------------------------------+
# | TYPE: STATIC ANALYSIS & LINTING (7)                                                                                                               |
# +----------------+------------------------------------------+--------------------------------------------+------------------------------------------+
# | golangci-lint  | github.com/golangci/golangci-lint        | Fast, parallel runner for dozens of linters| golangci-lint run ./... --no-config      |
# | staticcheck    | github.com/dominikh/go-tools             | Advanced static analysis with all checks   | staticcheck -checks="all" ./...          |
# | nilaway        | github.com/uber-go/nilaway               | Advanced static nil-panic detector         | nilaway -include-pkgs="<pkg>" ./...      |
# | nilness        | golang.org/x/tools                       | Detects potential nil-pointer dereferences | nilness ./...                            |
# | gocyclo        | github.com/fzipp/gocyclo                 | Measures cyclomatic complexity of functions| gocyclo -over 15 .                       |
# | interfacebloat | github.com/sashamelentyev/interfacebloat | Flags interfaces with too many methods     | interfacebloat -max 5 ./...              |
# | copyloopvar    | github.com/karamaru-alpha/copyloopvar    | Detects loop variable pointer issues       | copyloopvar ./...                        |
# +----------------+------------------------------------------+--------------------------------------------+------------------------------------------+
# | TYPE: SECURITY & VULNERABILITY (2)                                                                                                                |
# +----------------+------------------------------------------+--------------------------------------------+------------------------------------------+
# | govulncheck    | github.com/golang/vuln                   | Official vulnerability scanner for Go code | govulncheck ./...                        |
# | gosec          | github.com/securego/gosec                | Inspects source code for security problems | gosec -fmt=text ./...                    |
# +----------------+------------------------------------------+--------------------------------------------+------------------------------------------+
# | TYPE: TESTING & PERFORMANCE (3)                                                                                                                   |
# +----------------+------------------------------------------+--------------------------------------------+------------------------------------------+
# | mockery        | github.com/vektra/mockery                | Generates type-safe mocks for interfaces   | mockery --all --inpackage                |
# | goleak         | github.com/uber-go/goleak                | Verifies no Goroutines are leaked in tests | (Inside _test.go) goleak.VerifyNone(t)   |
# | benchstat      | github.com/golang/perf                   | Computes statistics about Go benchmarks    | benchstat old.txt new.txt                |
# +----------------+------------------------------------------+--------------------------------------------+------------------------------------------+
# | TYPE: DEVELOPMENT & VISUALIZATION (4)                                                                                                             |
# +----------------+------------------------------------------+--------------------------------------------+------------------------------------------+
# | gopls          | go.googlesource.com/tools                | Official Go Language Server (IDE logic)    | gopls check ./...                        |
# | delve (dlv)    | github.com/go-delve/delve                | The standard debugger for the Go language  | dlv debug ./main.go                      |
# | go-callvis     | github.com/ondrajz/go-callvis            | Interactive graph visualization of Go code | go-callvis -format=png -file=<output>    |
# | impl           | github.com/josharian/impl                | Generates method stubs for interfaces      | impl 'r *Receiver' io.Reader             |
# +----------------+------------------------------------------+--------------------------------------------+------------------------------------------+
# | TYPE: ASSET MANAGEMENT (1)                                                                                                                        |
# +----------------+------------------------------------------+--------------------------------------------+------------------------------------------+
# | go.rice        | github.com/GeertJohan/go.rice            | Embeds static assets into Go binaries      | rice embed-go                            |
# +----------------+------------------------------------------+--------------------------------------------+------------------------------------------+

# --- Global Configuration & Build Environment ---
# Hardening of shell environment
set -euo pipefail
# Environment Detection: Dynamically resolve drive prefixes for Cygwin vs MSYS2 compatibility.
IS_CYGWIN=false
IS_MSYS=false
DRIVE_PREFIX=""

if [[ "$(uname -s)" =~ "CYGWIN" ]]; then
  IS_CYGWIN=true
  DRIVE_PREFIX="/cygdrive"
elif [[ "$(uname -s)" =~ "MSYS" || "$(uname -s)" =~ "MINGW" || "$(uname -s)" =~ "MSYS" ]]; then
  IS_MSYS=true
  DRIVE_PREFIX=""
else
  echo "Error: This script is designed to run on Cygwin or MSYS2/Git-Bash."
  exit 1
fi

# Validation: Ensure GOPATH is defined for go install operations.
if [ -z "${GOPATH:-}" ]; then
  echo "Error: GOPATH is not defined. Please set your Go workspace environment variable."
  exit 1
fi

# Centralized paths for source code, binaries, and distribution archives.
readonly INSTALL_BASE="${DRIVE_PREFIX}/f/stage/install"
readonly COMPILE_BASE="${INSTALL_BASE}/compile" # Temporary workspace for cloning and building
readonly DISTRIB_BASE="${INSTALL_BASE}/distrib" # Final destination for compressed archives
readonly BUILD_HOME="bin"                       # Subdirectory within each tool where binaries are placed
readonly TAR_OPTS="-Jcf"                        # tar options: J (xz), c (create), f (file)

# System and execution metadata
readonly CPU_CORES=$(nproc)             # Detected CPU cores for parallel build optimization
readonly LOG_PATH="${TMPDIR:-/tmp}/logs/golang" # Path to store build logs for background tasks
SECONDS=0                      # Timer for calculating total execution duration
ACTION=""                      # Current build target (determined by CLI arguments)
DO_CLEAN=false                 # Flag to trigger cache cleanup before execution
DO_PURGE_DIST=false            # Flag to purge distribution subdirectories
DO_REPORT_DIST=false           # Flag to report existing distribution archives
DO_SCOPE=""                    # Specific tool scope for maintenance tasks

# Go build settings & optimizations
readonly GH_BASE_URL="https://github.com"
export GOPROXY="https://proxy.golang.org,direct"
# GO_OPTS: -trimpath (removes local file paths), -buildmode=pie (Security: ASLR support), -p (Parallelism)
declare -a GO_OPTS=(-trimpath -buildmode=pie "-p=$((CPU_CORES / 2))")
readonly BASE_LDFLAGS="-s -w" # Default size-reduction flags
readonly GOARCH=amd64
declare -a GOOS_LIST=(windows linux) # Compile for both Windows and Linux simultaneously
readonly WINOS_EXT=".exe"

# Master list of all available tools (used for build_all and maintenance scope expansion)
declare -a MASTER_TOOLS=("gofumpt" "govulncheck" "golangci-lint" "staticcheck" "gopls" "delve" "gocyclo" "goconst" "interfacebloat" "nilaway" "nilness" "gosec" "gorice" "gomnd" "gocritic" "impl" "gocallvis" "benchstat" "mockery" "copyloopvar" "goleak")

if [[ "${OSTYPE:-}" == "msys" || "${OSTYPE:-}" == "cygwin" || "${OSTYPE:-}" == "win32" ]]; then
  OS_EXT="${WINOS_EXT}"
else
  OS_EXT=""
fi

# CGO and Cross-Compilation (Zig) settings
# CGO_LDFLAGS: Forces static linking of external libraries (glibc/musl) for portability.
readonly CGO_LDFLAGS="-linkmode external -extldflags '-static'"
readonly ZIG_BIN="d:/dev/zig/zig" # Path to the Zig executable (used as a C compiler)
readonly ZIG_CACHE="$(cygpath "${LOCALAPPDATA:-}")/zig"
# CC_* variables: Direct Zig to target specific OS/libc families (GNU for Windows, MUSL for Linux).
readonly CC_WINDOWS="${ZIG_BIN} cc -target x86_64-windows-gnu"
readonly CC_LINUX="${ZIG_BIN} cc -target x86_64-linux-musl"

# --- Pre-Execution Guard: Instance Locking & Lifecycle Management ---
LOCK_FILE="${TMPDIR:-/tmp}/gobuild_code-analyzers.lock"
declare -A pid_map=() # Global PID map for lifecycle tracking

function cleanup() {
  local exit_code=$?
  # 1. Terminate any orphaned background builds
  if [ "${#pid_map[@]}" -gt 0 ]; then
    echo -e "\n[CLEANUP] Terminating ${#pid_map[@]} background builds..."
    # Attempt to kill all registered background PIDs (SIGTERM for graceful exit)
    kill -TERM "${!pid_map[@]}" 2>/dev/null || true
    # Reap the processes to prevent zombies
    wait "${!pid_map[@]}" 2>/dev/null || true
  fi
  # 2. Remove the instance lock
  rm -f "$LOCK_FILE"
}

if [ -f "$LOCK_FILE" ]; then
  OLD_PID=$(cat "$LOCK_FILE")
  if kill -0 "$OLD_PID" 2>/dev/null; then
    echo -e "\n[FATAL ERROR] Another instance of this script (PID $OLD_PID) is already running."
    echo "Please wait for the current build to finish or terminate the existing process."
    exit 1
  fi
fi

# Register current PID and set up lifecycle traps
echo $$ > "$LOCK_FILE"
trap cleanup EXIT
trap "exit 1" INT TERM

# Displays the script usage guide and available build targets.
function displayHelp() {
  echo "-------------------------------------------------------------------"
  echo " Go Build Pipeline - Usage"
  echo "-------------------------------------------------------------------"
  echo "Syntax:  $(basename "$0") [option] [target]"
  echo ""
  echo "Options:"
  echo "  --help, -h            Display this help menu"
  echo "  --clean-cache         Clean Zig and Go caches"
  echo "  --purge-distrib       Purge distribution subdirs for selected target(s)"
  echo "  --report-distrib      List all compiled binaries in a table"
  echo "  --scope=<pkg1,pkg2>   Restrict maintenance to specific tools (no build)"
  echo ""
  echo "Targets:"
  echo "  build_all             Build every tool in parallel"
  echo "  build_gofumpt         Build only gofumpt"
  echo "  build_govulncheck     Build only govulncheck"
  echo "  build_golangci-lint   Build only golangci-lint"
  echo "  build_staticcheck     Build only staticcheck + addons"
  echo "  build_gopls           Build only gopls"
  echo "  build_delve           Build only delve (dlv)"
  echo "  build_gocyclo         Build only gocyclo"
  echo "  build_goconst         Build only goconst"
  echo "  build_interfacebloat  Build only interfacebloat"
  echo "  build_nilaway         Build only nilaway"
  echo "  build_nilness         Build only nilness"
  echo "  build_gosec           Build only gosec"
  echo "  build_gorice          Build only rice"
  echo "  build_gomnd           Build only mnd"
  echo "  build_gocritic        Build only gocritic"
  echo "  build_impl            Build only impl"
  echo "  build_gocallvis       Build only go-callvis"
  echo "  build_benchstat       Build only benchstat"
  echo "  build_mockery         Build only mockery"
  echo "  build_copyloopvar     Build only copyloopvar"
  echo "  build_goleak          Build only goleak"
  echo ""
  echo "Example: ./$(basename "$0") --clean-cache build_all"
  echo "-------------------------------------------------------------------"
}

# Clears Zig and Go caches to ensure a fresh build environment.
# Functionality: Deletes temporary build artifacts from Zig's local app data and invokes 'go clean'.
# Objective: Prevent stale objects or corrupted caches from affecting the build integrity.
function cleanCache() {
  echo "Cleaning Zig and Go caches..."
  if [ -n "${ZIG_CACHE:-}" ] && [ "${ZIG_CACHE}" != "/" ] && [ -d "${ZIG_CACHE}" ]; then
    rm -rf "${ZIG_CACHE:?}"/*
  fi
  go clean -cache
}

# Purges distribution subdirectories for the selected target or all tools.
# Arguments: $1 (optional filter: build_xxx or all).
# Functionality: Deletes tool-specific folders in DISTRIB_BASE to ensure a fresh release state.
function purgeDistrib() {
  local filter="${1:-}"
  local target_pn="${filter#build_}"
  
  if [ -n "${target_pn}" ] && [ "${target_pn}" != "all" ] && [ "${target_pn}" != "HELP" ]; then
    # Disable globbing to prevent expansion against local files
    set -f
    # Handle comma-separated scope with wildcard support
    local scope_items="${target_pn//,/ }"
    for scope_item in ${scope_items}; do
      local matched=false
      for tool in "${MASTER_TOOLS[@]}"; do
        # Match using Bash pattern matching (supports wildcards like go*)
        if [[ "${tool}" == ${scope_item} ]]; then
          echo "Purging distribution directory for ${tool}..."
          if [[ -n "${tool}" && "${tool}" != "/" ]]; then
            rm -rf "${DISTRIB_BASE:?}/${tool:?}"
            matched=true
          fi
        fi
      done
      [ "$matched" = false ] && echo "Warning: No tools matched scope pattern '${scope_item}'"
    done
    set +f
  elif [ "${target_pn}" == "all" ] || [ -z "${target_pn}" ]; then
    echo "Purging all distribution directories..."
    # Robust deletion of the entire distribution contents.
    rm -rf "${DISTRIB_BASE:?}"/*
  else
    echo "Skipping purge: Unrecognized target '${target_pn}'"
  fi
}

# Generates a formatted report of all compiled binaries currently in the distribution directory.
# Data Flow: [DISTRIB_BASE] -> [Directory Traversal] -> [Version Extraction] -> [Table Output].
function reportDistrib() {
  local filter="${1:-}"
  local target_pn="${filter#build_}" # Strip "build_" prefix if present
  
  local col1=20 col2=25 col3=110
  local total_width=$((col1 + col2 + col3 + 6))
  local separator
  separator=$(printf "%${total_width}s" | tr ' ' '-')

  echo -e "\n${separator}"
  printf "%-${col1}s | %-${col2}s | %s\n" "Package Name" "Version" "Archive Names"
  echo "${separator}"

  if [ ! -d "${DISTRIB_BASE}" ]; then
    echo "Distribution directory not found at ${DISTRIB_BASE}"
    return
  fi

  local pkg_count=0
  local -A pkg_archives=()
  local -A pkg_versions=()

  # Use a standard for loop with native shell expansion to avoid process fork overhead
  for f in "${DISTRIB_BASE}"/*/*.tar.xz; do
    [ -f "${f}" ] || continue

    # Fast path: Use shell parameter expansion instead of basename/dirname
    local tmp_dir="${f%/*}"
    local PN_LOCAL="${tmp_dir##*/}"
    
    # Apply filtering logic if a specific target or scope is requested
    if [ -n "${target_pn}" ] && [ "${target_pn}" != "all" ] && [ "${target_pn}" != "HELP" ]; then
      # Disable globbing to prevent expansion against local files
      set -f
      # Handle comma-separated scope with wildcard support
      local scope_items="${target_pn//,/ }"
      local matched=false
      for scope_item in ${scope_items}; do
        if [[ "${PN_LOCAL}" == ${scope_item} ]]; then
          matched=true
          break
        fi
      done
      set +f
      [ "$matched" = false ] && continue
    fi

    local fname="${f##*/}"
    
    # Extract version metadata: Strip tool name and trailing OS/arch suffix
    local tmp="${fname#${PN_LOCAL}-}"
    local version="${tmp%_*}"

    if [ -z "${pkg_archives[$PN_LOCAL]:-}" ]; then
      pkg_archives["$PN_LOCAL"]="${fname}"
      pkg_versions["$PN_LOCAL"]="${version}"
    else
      pkg_archives["$PN_LOCAL"]="${pkg_archives[$PN_LOCAL]}, ${fname}"
    fi
  done

  # Iterate over sorted keys of the associative array to print the report table
  if [ "${#pkg_archives[@]}" -gt 0 ]; then
    local sorted_pns
    sorted_pns=$(echo "${!pkg_archives[@]}" | tr ' ' '\n' | sort)
    local PN_KEY
    for PN_KEY in ${sorted_pns}; do
      printf "%-${col1}s | %-${col2}s | %s\n" "${PN_KEY}" "${pkg_versions[$PN_KEY]}" "${pkg_archives[$PN_KEY]}"
      ((pkg_count += 1))
    done
  fi

  if [ "${pkg_count}" -eq 0 ]; then
    if [ -n "${target_pn}" ] && [ "${target_pn}" != "all" ] && [ "${target_pn}" != "HELP" ]; then
       echo "No distribution archives found for target: ${target_pn}"
    elif [ "${target_pn}" == "all" ] || [ -z "${target_pn}" ]; then
       echo "No distribution archives found in ${DISTRIB_BASE}"
    fi
  fi
  echo "${separator}"
}

# Updates all Go modules in the current path to their latest versions.
# Functionality: Invokes 'go get -u' which updates dependencies in go.mod.
# Objective: Ensure the tools are built against the most recent bugfixes and features.
function goUpdateModules() {
  go get -u ./...
}

# Detects and displays the package version for the compiled binary.
# Arguments: $1 (version flag/mode: v, -v, --v, -V, meta).
# Functionality: Executes the local binary with various version flags or uses 'go version -m' for metadata.
# Data Flow: [Compiled Binary] -> [Version Output] -> [Stdout].
function pkgVersion() {
  local bin_path="${PKG_BIN_PATH:-./${PKG_BIN}${OS_EXT}}"
  
  # Search heuristic fallback (only if PKG_BIN_PATH is missing)
  if [ ! -f "$bin_path" ]; then
    if [ -f "./${BUILD_HOME}/${PKG_BIN}${OS_EXT}" ]; then
      bin_path="./${BUILD_HOME}/${PKG_BIN}${OS_EXT}"
    elif [ -f "../${BUILD_HOME}/${PKG_BIN}${OS_EXT}" ]; then
      bin_path="../${BUILD_HOME}/${PKG_BIN}${OS_EXT}"
    elif [ -f "../../${BUILD_HOME}/${PKG_BIN}${OS_EXT}" ]; then
      bin_path="../../${BUILD_HOME}/${PKG_BIN}${OS_EXT}"
    fi
  fi

  # Resolve to a Windows-compatible path for Go and compiled binaries
  local win_bin_path
  win_bin_path=$(cygpath -w "$bin_path")

  case "${1:-}" in
    v | -v | --v)
      "$bin_path" "${1:-}ersion"
      ;;
    -V)
      "$bin_path" "${1:-}=full"
      ;;
    meta)
      # Pass the Windows-native path to the Go toolchain for metadata extraction
      go version -m "${win_bin_path}" | grep "^"$'\t'"mod"
      ;;
  esac
}

# Prepares the repository for building by setting up the workspace and extracting version metadata.
# Arguments: $1: PKG_NAME (display name), $2: GitHub Org, $3: Repository Name, $4: Tag Filter Regex, $5: [NOCLONE] (optional).
# Functionality: Creates build/distrib directories, clones the source (unless NOCLONE), and calculates the version string.
# Data Flow: [Remote Git] -> [Local Workspace] -> [APP_VERSION/PKG_VER String Generation].
function repoPrep() {
  local PN="${1:-}" ORG="${2:-}" REPO="${3:-}" FILTER="${4:-}" MODE="${5:-}"
  echo -e "\n----- Building ${PN} -----"
  cd "${COMPILE_BASE}" || exit
  # Clean up existing distribution artifacts for this tool
  rm -rf "${DISTRIB_BASE:?}/${PN:?}"
  # Initialize the compile workspace and the final distribution folder
  mkdir -p "${PN}/${BUILD_HOME}" "${DISTRIB_BASE}/${PN}" && cd "${PN}" || exit

  if [ "$MODE" == "NOCLONE" ]; then
    mkdir -p "${REPO}" && cd "${REPO}" || exit
    # Extract versioning (YYYYMMDD-HASH) without a full repository clone
    local COMMIT_HASH
    COMMIT_HASH=$(git ls-remote "${GH_BASE_URL}/${ORG}/${REPO}" HEAD 2>/dev/null | cut -c1-7)
    local COMMIT_DATE
    COMMIT_DATE=$(go list -m -json "${MOD_PATH:-${REPO}}@latest" 2>/dev/null | sed -n 's/.*"Time": "\(.*\)T.*/\1/p' | tr -d '-')
    APP_VERSION="${COMMIT_DATE:-latest}"
    APP_HASH="${COMMIT_HASH:-head}"
    export PKG_VER="${APP_VERSION}-${APP_HASH}"
    return
  fi

  # Purge old source to ensure a clean clone
  rm -rf "${REPO:?}"
  if ! git clone "${GH_BASE_URL}/${ORG}/${REPO}"; then
    echo "Fatal: Failed to clone repository ${ORG}/${REPO}"
    exit 1
  fi
  cd "${REPO}" || exit

  # HEURISTIC: Determine the latest semantic tag.
  # Use '|| true' to prevent 'set -e' from crashing if no tags match the filter.
  APP_VERSION=$(git tag -l | grep "${FILTER}" | sort -V | grep -v pre | tail -1 | cut -d'/' -f2 || true)
  # FALLBACK: If no tags match, use the last commit date (YYYYMMDD).
  if [ -z "${APP_VERSION}" ]; then
    APP_VERSION=$(git log -1 --format=%cs | tr -d '-')
  fi
  APP_HASH=$(git rev-parse --short=7 HEAD)
  # Combine version and hash for a unique identifier (e.g., 1.2.3-abc1234)
  export PKG_VER="${APP_VERSION}-${APP_HASH}"
}

# Runs static analysis tasks and source code preparation on the cloned repository.
# Arguments: $1 (Environment mode: "VENDOR" to force vendoring, "FULL" for lint/format).
# Functionality: Standardizes the Go module state and ensures the code is formatted and vetted.
# Data Flow: [Source Code] -> [Go Toolchain (tidy, vendor, fmt, vet)] -> [Staged Git Commit].
function codeAnalysis() {
  # Mode: VENDOR - Necessary for tools with large dependency trees or non-standard go.mod files.
  if [ "${1:-}" == "VENDOR" ]; then
    go mod vendor
  fi
  # Synchronize go.mod and go.sum with the actual imports in the source code.
  go mod tidy
  # Mode: FULL - Ensures that the binaries are built from standardized, high-quality source code.
  if [ "${1:-}" == "FULL" ]; then
    go fmt ./...
    go vet ./...
  fi
  # Track all local changes (like vendoring or formatting) in a temporary commit for auditability.
  git add . &>/dev/null
  git commit -m "Final build changes" &>/dev/null || true
}

## Core compilation engine that handles cross-platform Go builds with optional CGO/Zig support.
# Arguments: Space-separated flags like "CMD" (subdir build), "SUB" (shallow subdir), "CGO" (enable Zig CC).
# Functionality: Dynamically sets build paths, env vars, and invokes 'go build' for each target OS.
# Data Flow: [Environment/LDFLAGS] -> [Go Compiler + Zig CC (if CGO)] -> [Architecture-Specific Binaries].
function codeBuild() {
  local START_DIR=$PWD
  local PATH_REL=".."
  local BUILD_BASE
  local GO_LDFLAGS="${BASE_LDFLAGS:-}" # Initialize from global base flags
  local CGO=0
  local GOOS

  # LOGIC: Navigate to the appropriate subdirectory based on the tool's repository structure.
  if [[ "$*" =~ "CMD" ]]; then
    PATH_REL="../../.."
    cd "cmd/${PKG_BIN}" || exit
  elif [[ "$*" =~ "SUB" ]]; then
    PATH_REL="../.."
    cd "${PKG_BIN}" || exit
  elif [[ "$*" =~ "MAIN" ]]; then
    PATH_REL=".."
  elif [[ "$*" =~ "PRE" ]]; then
    PATH_REL="../.."
  fi

  # Calculate the binary destination relative to the current subdirectory.
  BUILD_BASE="${PATH_REL}/${BUILD_HOME}"

  # Define Linker Flags (LDFLAGS) for version injection and size reduction.
  if [ -n "${PKG_VER_LDFLAG:-}" ]; then
    GO_LDFLAGS="${GO_LDFLAGS} ${PKG_VER_LDFLAG}"
  fi

  # Enable CGO if requested (required for tools like Delve).
  if [[ "$*" =~ "CGO" ]]; then
    CGO=1
    GO_LDFLAGS="${GO_LDFLAGS} ${CGO_LDFLAGS:-}"
  else
    CGO=0
  fi

  echo -e "\n  - Compiling version ${PKG_VER}"
  # MAIN LOOP: Build for every Operating System defined in GOOS_LIST.
  for GOOS in "${GOOS_LIST[@]}"; do
    echo "Building for GOOS: $GOOS, GOARCH: $GOARCH"
    # Inject Zig CC as the cross-compiler for C-code dependencies.
    if [ "$CGO" -eq 1 ]; then
      case "$GOOS" in
        "windows")
          export CC="${CC_WINDOWS}"
          ;;
        "linux")
          export CC="${CC_LINUX}"
          ;;
      esac
    fi
    # -s: Omit symbol table and debug info. -w: Omit DWARF symbol table.
    CGO_ENABLED=$CGO GOOS="$GOOS" nice -n 10 go build -ldflags "${GO_LDFLAGS}" "${GO_OPTS[@]}" -o "${BUILD_BASE}/" >/dev/null
  done

  # Return to build directory and verify binaries.
  cd "${BUILD_BASE}" || exit
  ls -l "${PKG_BIN}${WINOS_EXT}" "${PKG_BIN}"
  
  # Export the absolute path of the Windows binary for versioning/archiving tools
  export PKG_BIN_PATH="$(pwd)/${PKG_BIN}${WINOS_EXT}"
  
  cd "$START_DIR" || exit
}

# Core compilation engine that leverages 'go install' for remote packages.
# Arguments: $1: Package URL (e.g., golang.org/x/tools/...@latest)
# Functionality: Captures cross-compiled binaries generated by 'go install' in GOPATH and moves them to BUILD_HOME.
# Data Flow: [Remote Module] -> [Go Install + GOPATH] -> [Architecture-Specific Binaries].
function codeInstall() {
  local PKG_URL="${1:-}"
  local PATH_REL=".."
  local BUILD_BASE="${PATH_REL}/${BUILD_HOME}"
  local GOOS

  mkdir -p "${BUILD_BASE}"
  for GOOS in linux windows; do
    echo "Installing for GOOS: $GOOS"
    CGO_ENABLED=0 GOOS="$GOOS" nice -n 10 go install -ldflags "${BASE_LDFLAGS}" "${GO_OPTS[@]}" "${PKG_URL}" >/dev/null
    # Resolve the primary GOPATH directory (handles multi-path GOPATH and drive letters)
    local go_bin_base
    go_bin_base=$(go env GOPATH)
    if [[ "$go_bin_base" == *";"* ]]; then
      go_bin_base="${go_bin_base%%;*}"
    elif [[ "$go_bin_base" == *":"* && ! "$go_bin_base" =~ ^[A-Za-z]: ]]; then
      go_bin_base="${go_bin_base%%:*}"
    fi
    local bin_src_dir="$(cygpath "${go_bin_base}")/bin"

    if [ "$GOOS" == "windows" ]; then
      mv -f "${bin_src_dir}/${PKG_BIN}.exe" "${BUILD_BASE}/"
    else
      mv -f "${bin_src_dir}/${GOOS}_${GOARCH}/${PKG_BIN}" "${BUILD_BASE}/"
    fi
  done
  cd "${BUILD_BASE}" || exit
  ls -l "${PKG_BIN}${WINOS_EXT}" "${PKG_BIN}" 2>/dev/null

  # Export the absolute path of the Windows binary for versioning/archiving tools
  export PKG_BIN_PATH="$(pwd)/${PKG_BIN}${WINOS_EXT}"
}

# Collects compiled binaries and packages them into compressed archives for distribution.
# Arguments: $1: Cleanup target directory, $2: List of extra binaries, $3: "NOPURGE" flag to skip cleanup.
# Functionality: Generates .tar.xz bundles for Windows and Linux, including necessary file extensions.
# Data Flow: [Compiled Binaries] -> [tar/xz Compression] -> [Distrib Folder] -> [Workspace Purge].
function generateArchive() {
  local PKG_BASE_TARGET="${1:-}"
  local EXTRA_BINS="${2:-}"
  local PURGE_MODE="${3:-}"
  
  # Navigate to the binary directory (bin/) where compiles are staged.
  # Priority: 1. Tracked absolute path, 2. Local search, 3. Parent search, 4. Double-parent search.
  if [ -n "${PKG_BIN_PATH:-}" ] && [ -f "${PKG_BIN_PATH}" ]; then
    local bin_dir
    bin_dir=$(dirname "${PKG_BIN_PATH}")
    cd "${bin_dir}" || exit
  elif [ -d "${BUILD_HOME}" ]; then
    cd "${BUILD_HOME}" || exit
  elif [ -d "../${BUILD_HOME}" ]; then
    cd "../${BUILD_HOME}" || exit
  elif [ -d "../../${BUILD_HOME}" ]; then
    cd "../../${BUILD_HOME}" || exit
  elif [ -d "../../../${BUILD_HOME}" ]; then
    cd "../../../${BUILD_HOME}" || exit
  fi
  
  # Resolve the list of binaries into an array for safe multi-file handling
  local bin_array=(${PKG_BIN} ${EXTRA_BINS})
  local win_bin_array=()
  local b
  for b in "${bin_array[@]}"; do
    win_bin_array+=("${b}${WINOS_EXT}")
  done

  # ATOMIC PACKAGING: Ensure both Windows and Linux archives are created successfully.
  local win_archive="${DISTRIB_BASE}/${PKG_NAME}/${PKG_NAME}-${PKG_VER}_windows-amd64.tar.xz"
  local lin_archive="${DISTRIB_BASE}/${PKG_NAME}/${PKG_NAME}-${PKG_VER}_linux-amd64.tar.xz"

  tar "${TAR_OPTS}" "${win_archive}" "${win_bin_array[@]}" || return 1
  
  if tar "${TAR_OPTS}" "${lin_archive}" "${bin_array[@]}"; then
    # CLEANUP: Remove staged binaries only after successful archival
    rm -f "${win_bin_array[@]}" "${bin_array[@]}"
    # COMPRESSION SUCCESS: Display archiving results.
    echo "  [Archived] ${PKG_NAME} Version: ${PKG_VER}"
    echo "  - Windows: ${PKG_NAME}-${PKG_VER}_windows-amd64.tar.xz"
    echo "  - Linux:   ${PKG_NAME}-${PKG_VER}_linux-amd64.tar.xz"

    # WORKSPACE CLEANUP: Remove the temporary compile folders.
    cd ../../ || exit # Move out of bin/ and tool/ to parent folder
    if [ "${PURGE_MODE}" != "NOPURGE" ]; then
      # Safety check: Prevent accidental deletion of root or system folders.
      if [[ -n "${PKG_BASE_TARGET}" && "${PKG_BASE_TARGET}" != "/" && -d "./${PKG_BASE_TARGET}" ]]; then
        rm -rf "./${PKG_BASE_TARGET:?}"
      fi
      # Also remove the tool-level container if it exists
      if [[ -n "${PKG_NAME}" && -d "./${PKG_NAME}" ]]; then
        rm -rf "./${PKG_NAME:?}"
      fi
    fi
    return 0
  else
    return 1
  fi
}

# --- Tool-Specific Build Functions ---
# Each function encapsulates the environment and build steps for a specific tool.

# gofumpt: A stricter, more opinionated Go formatter.
# Objectives: Enforce a rigid coding style that is a superset of 'gofmt'.
# Data Flow: repoPrep -> codeAnalysis -> codeBuild (MAIN) -> generateArchive.
function build_gofumpt() {
  (
    PKG_NAME=gofumpt
    PKG_BASE=${PKG_NAME}
    PKG_BIN=${PKG_NAME}
    repoPrep "${PKG_NAME}" mvdan "${PKG_BASE}" "v"
    PKG_VER_LDFLAG=""
    goUpdateModules
    codeAnalysis
    codeBuild "MAIN"
    pkgVersion "--v"
    generateArchive "${PKG_BASE}"
  )
}

# govulncheck: Official vulnerability scanner for Go code.
# Objectives: Identify known vulnerabilities in project dependencies.
# Data Flow: repoPrep -> codeAnalysis -> codeBuild (CMD) -> generateArchive.
function build_govulncheck() {
  (
    PKG_NAME=govulncheck
    PKG_BASE=vuln
    PKG_BIN=${PKG_NAME}
    repoPrep "${PKG_NAME}" golang "${PKG_BASE}" "v"
    PKG_VER_LDFLAG=""
    goUpdateModules
    codeAnalysis
    codeBuild "CMD"
    pkgVersion "-v"
    generateArchive "${PKG_BASE}"
  )
}

# golangci-lint: Fast, parallel runner for dozens of Go linters.
# Objectives: Provide a unified, high-performance interface for multiple analysis tools.
# Data Flow: repoPrep -> codeAnalysis -> codeBuild (CMD) -> generateArchive.
function build_golangci-lint() {
  (
    PKG_NAME=golangci-lint
    PKG_BASE=${PKG_NAME}
    PKG_BIN=${PKG_NAME}
    repoPrep "${PKG_NAME}" golangci "${PKG_BASE}" "v"
    PKG_VER_LDFLAG=""
    goUpdateModules
    go get github.com/denis-tingaikin/go-header@v0.5.0
    codeAnalysis
    codeBuild "CMD"
    pkgVersion "--v"
    generateArchive "${PKG_BASE}"
  )
}

# staticcheck: Advanced static analysis with a wide range of checks.
# Objectives: Detect bugs, performance issues, and suggest simplifications.
# Data Flow: repoPrep -> codeAnalysis -> codeBuild (CMD/multiple) -> generateArchive.
function build_staticcheck() {
  (
    PKG_NAME=staticcheck
    PKG_BASE=go-tools
    PKG_BIN=${PKG_NAME}
    PKG_ADDONS="structlayout structlayout-optimize structlayout-pretty"
    repoPrep "${PKG_NAME}" dominikh "${PKG_BASE}" "v"
    PKG_VER_LDFLAG=""
    goUpdateModules
    codeAnalysis
    codeBuild "CMD"
    # Verify main binary version before processing addons (checking parent bin dir)
    ./"../${BUILD_HOME}/${PKG_NAME}${OS_EXT}" -version
    for a in ${PKG_ADDONS}; do
      PKG_BIN=$a
      cd "${COMPILE_BASE}/${PKG_NAME}/${PKG_BASE}" || exit
      codeBuild "CMD"
      pkgVersion "-v"
    done
    PKG_BIN=${PKG_NAME}
    generateArchive "${PKG_BASE}" "${PKG_ADDONS}"
  )
}

# gopls: The official Go Language Server (LSP) providing IDE-like logic.
# Objectives: Power IDE features like autocompletion, navigation, and refactoring.
# Data Flow: repoPrep -> codeAnalysis -> codeBuild (PRE) -> generateArchive.
function build_gopls() {
  (
    PKG_NAME=gopls
    PKG_BASE=tools
    PKG_BIN=${PKG_NAME}
    repoPrep "${PKG_NAME}" golang "${PKG_BASE}" "${PKG_NAME}"
    PKG_VER_LDFLAG="-X main.version=${PKG_VER}"
    # Navigate to the gopls subdirectory within the tools repository
    cd "${PKG_NAME}" || exit
    goUpdateModules
    codeAnalysis
    codeBuild "PRE"
    pkgVersion "v"
    generateArchive "${PKG_BASE}"
  )
}

# delve (dlv): The standard debugger for the Go programming language.
# Objectives: Provide interactive debugging capabilities (breakpoints, stack traces).
# Data Flow: repoPrep -> codeAnalysis (VENDOR) -> codeBuild (CMD + CGO) -> generateArchive.
function build_delve() {
  (
    PKG_NAME=delve
    PKG_BASE=${PKG_NAME}
    PKG_BIN=dlv
    # Delve specific: PIE (Position Independent Executable) is not supported for all Delve targets.
    # We filter out the -buildmode=pie flag from the global options for this subshell.
    local temp_opts=()
    for opt in "${GO_OPTS[@]}"; do
      [[ "${opt}" != "-buildmode=pie" ]] && temp_opts+=("${opt}")
    done
    GO_OPTS=("${temp_opts[@]}")
    repoPrep "${PKG_NAME}" go-delve "${PKG_BASE}" "v"
    PKG_VER_LDFLAG=""
    goUpdateModules
    codeAnalysis "VENDOR"
    codeBuild "CMD" "CGO"
    pkgVersion "v"
    generateArchive "${PKG_BASE}"
  )
}

# gocyclo: Measures the cyclomatic complexity of Go functions.
# Objectives: Identify overly complex functions that may need refactoring.
# Data Flow: repoPrep -> codeAnalysis -> codeBuild (CMD) -> generateArchive.
function build_gocyclo() {
  (
    PKG_NAME=gocyclo
    PKG_BASE=${PKG_NAME}
    PKG_BIN=${PKG_NAME}
    repoPrep "${PKG_NAME}" fzipp "${PKG_BASE}" "v"
    PKG_VER_LDFLAG=""
    goUpdateModules
    codeAnalysis
    codeBuild "CMD"
    pkgVersion "meta"
    generateArchive "${PKG_BASE}"
  )
}

# goconst: Finds repeated strings that should be converted into constants.
# Objectives: Reduce duplication and improve maintainability of string literals.
# Data Flow: repoPrep -> codeAnalysis -> codeBuild (CMD) -> generateArchive.
function build_goconst() {
  (
    PKG_NAME=goconst
    PKG_BASE=${PKG_NAME}
    PKG_BIN=${PKG_NAME}
    repoPrep "${PKG_NAME}" jgautheron "${PKG_BASE}" "v"
    PKG_VER_LDFLAG=""
    goUpdateModules
    codeAnalysis
    codeBuild "CMD"
    pkgVersion "meta"
    generateArchive "${PKG_BASE}"
  )
}

# interfacebloat: Flags interfaces that have too many methods.
# Objectives: Encourage smaller, more focused interfaces (Interface Segregation Principle).
# Data Flow: repoPrep -> codeAnalysis -> codeBuild (MAIN) -> generateArchive.
function build_interfacebloat() {
  (
    PKG_NAME=interfacebloat
    PKG_BASE=${PKG_NAME}
    PKG_BIN=${PKG_NAME}
    repoPrep "${PKG_NAME}" sashamelentyev "${PKG_BASE}" "v"
    PKG_VER_LDFLAG=""
    goUpdateModules
    codeAnalysis
    codeBuild "MAIN"
    pkgVersion "meta"
    generateArchive "${PKG_BASE}"
  )
}

# nilaway: Advanced static detector for potential nil-pointer panics.
# Objectives: Statically guarantee nil-safety in Go applications.
# Data Flow: repoPrep -> codeAnalysis -> codeBuild (CMD) -> generateArchive.
function build_nilaway() {
  (
    PKG_NAME=nilaway
    PKG_BASE=${PKG_NAME}
    PKG_BIN=${PKG_NAME}
    repoPrep "${PKG_NAME}" uber-go "${PKG_BASE}" "v"
    PKG_VER_LDFLAG=""
    goUpdateModules
    codeAnalysis
    codeBuild "CMD"
    pkgVersion "meta"
    generateArchive "${PKG_BASE}"
  )
}

# nilness: Advanced static detector for nil panics, part of golang.org/x/tools.
# Objectives: Statically guarantee nil-safety in Go applications.
# Data Flow: repoPrep -> codeInstall -> generateArchive.
function build_nilness() {
  (
    PKG_NAME=nilness
    PKG_BASE=tools
    PKG_BIN=nilness
    MOD_PATH="golang.org/x/tools"
    repoPrep "${PKG_NAME}" golang "${PKG_BASE}" "v" "NOCLONE"
    codeInstall "golang.org/x/tools/go/analysis/passes/nilness/cmd/nilness@latest"
    pkgVersion "meta"
    generateArchive "${PKG_BASE}"
  )
}

# gosec: Inspects source code for common security vulnerabilities.
# Objectives: Automate security auditing and catch common pitfalls early.
# Data Flow: repoPrep -> codeAnalysis -> codeBuild (CMD) -> generateArchive.
function build_gosec() {
  (
    PKG_NAME=gosec
    PKG_BASE=${PKG_NAME}
    PKG_BIN=${PKG_NAME}
    repoPrep "${PKG_NAME}" securego "${PKG_BASE}" "v"
    PKG_VER_LDFLAG="-X 'main.Version=${APP_VERSION}' -X 'main.GitTag=${APP_HASH}' -X 'main.BuildDate=$(date '+%Y/%m/%d')'"
    goUpdateModules
    # FIX: Resolve the orderedmap conflict in anthropic-sdk-go v1.38.0
    # anthropic-sdk-go v1.38.0 is incompatible with invopop/jsonschema v0.14.0+ due to an ordered-map type mismatch.
    go get github.com/invopop/jsonschema@v0.13.0
    codeAnalysis
    codeBuild "CMD"
    pkgVersion "--v"
    generateArchive "${PKG_BASE}"
  )
}

# go.rice: Tool for embedding static assets into Go binaries.
# Objectives: Simplify deployment by bundling resources into the executable.
# Data Flow: repoPrep -> codeAnalysis -> codeBuild (SUB) -> generateArchive.
function build_gorice() {
  (
    PKG_NAME=gorice
    PKG_BASE=go.rice
    PKG_BIN=rice
    GO_OPTS+=(-tags release)
    repoPrep "${PKG_NAME}" geertjohan "${PKG_BASE}" "v"
    PKG_VER_LDFLAG=""
    goUpdateModules
    codeAnalysis
    codeBuild "SUB"
    pkgVersion "meta"
    generateArchive "${PKG_BASE}"
  )
}

# gomnd: Detects "magic numbers" (unnamed numerical constants) in your code.
# Objectives: Improve code readability by encouraging named constants.
# Data Flow: repoPrep -> codeAnalysis (VENDOR) -> codeBuild (CMD) -> generateArchive.
function build_gomnd() {
  (
    PKG_NAME=gomnd
    PKG_BASE=go-mnd
    PKG_BIN=mnd
    repoPrep "${PKG_NAME}" tommy-muehle "${PKG_BASE}" "v"
    PKG_VER_LDFLAG=""
    goUpdateModules
    codeAnalysis "VENDOR"
    codeBuild "CMD"
    pkgVersion "meta"
    generateArchive "${PKG_BASE}"
  )
}

# gocritic: A linter that provides suggestions for code stylistic and performance improvements.
# Objectives: Find micro-bugs and stylistic issues not caught by standard vets.
# Data Flow: repoPrep -> codeAnalysis -> codeBuild (CMD) -> generateArchive.
function build_gocritic() {
  (
    PKG_NAME=gocritic
    PKG_BASE=go-critic
    PKG_BIN=${PKG_NAME}
    repoPrep "${PKG_NAME}" go-critic "${PKG_BASE}" "v"
    PKG_VER_LDFLAG=""
    goUpdateModules
    codeAnalysis
    codeBuild "CMD"
    pkgVersion "meta"
    generateArchive "${PKG_BASE}"
  )
}

# impl: Generates method stubs for implementing an interface.
# Objectives: Automate the creation of boilerplate code for Go interfaces.
# Data Flow: repoPrep -> codeAnalysis -> codeBuild (MAIN) -> generateArchive.
function build_impl() {
  (
    PKG_NAME=impl
    PKG_BASE=${PKG_NAME}
    PKG_BIN=${PKG_NAME}
    repoPrep "${PKG_NAME}" josharian "${PKG_BASE}" "v"
    PKG_VER_LDFLAG=""
    goUpdateModules
    codeAnalysis
    codeBuild "MAIN"
    pkgVersion "meta"
    generateArchive "${PKG_BASE}"
  )
}

# gocallvis: A tool to visualize the call graph of a Go program.
# Objectives: Assist in understanding the architecture and flow of complex codebases.
# Data Flow: repoPrep -> codeAnalysis -> codeBuild (MAIN) -> generateArchive.
function build_gocallvis() {
  (
    PKG_NAME=gocallvis
    PKG_BASE=go-callvis
    PKG_BIN=${PKG_BASE}
    repoPrep "${PKG_NAME}" ondrajz "${PKG_BASE}" "v"
    PKG_VER_LDFLAG=""
    goUpdateModules
    codeAnalysis
    codeBuild "MAIN"
    pkgVersion "meta"
    generateArchive "${PKG_BASE}"
  )
}

# benchstat: Computes and compares statistics about Go benchmarks.
# Objectives: Provide reliable statistical analysis of performance changes.
# Data Flow: repoPrep -> codeAnalysis -> codeBuild (CMD) -> generateArchive.
function build_benchstat() {
  (
    PKG_NAME=benchstat
    PKG_BASE=perf
    PKG_BIN=${PKG_NAME}
    repoPrep "${PKG_NAME}" golang "${PKG_BASE}" "v"
    PKG_VER_LDFLAG=""
    goUpdateModules
    codeAnalysis
    codeBuild "CMD"
    pkgVersion "meta"
    generateArchive "${PKG_BASE}"
  )
}

# mockery: Generates type-safe mocks for Go interfaces.
# Objectives: Streamline unit testing by automating mock generation.
# Data Flow: repoPrep -> codeAnalysis -> codeBuild (MAIN) -> generateArchive.
function build_mockery() {
  (
    PKG_NAME=mockery
    PKG_BASE=${PKG_NAME}
    PKG_BIN=${PKG_NAME}
    repoPrep "${PKG_NAME}" vektra "${PKG_BASE}" "v"
    PKG_VER_LDFLAG=""
    goUpdateModules
    codeAnalysis
    codeBuild "MAIN"
    pkgVersion "meta"
    generateArchive "${PKG_BASE}"
  )
}

# copyloopvar: Detects places where loop variables are captured by reference.
# Objectives: Prevent common Go concurrency bugs related to loop variable scoping.
# Data Flow: repoPrep -> codeAnalysis -> codeBuild (CMD) -> generateArchive.
function build_copyloopvar() {
  (
    PKG_NAME=copyloopvar
    PKG_BASE=${PKG_NAME}
    PKG_BIN=${PKG_NAME}
    repoPrep "${PKG_NAME}" karamaru-alpha "${PKG_BASE}" "v"
    PKG_VER_LDFLAG=""
    goUpdateModules
    codeAnalysis
    codeBuild "CMD"
    pkgVersion "meta"
    generateArchive "${PKG_BASE}"
  )
}

function build_goleak() {
  cat <<"EOF"

GOLEAK INTEGRATION NOTE:
------------------------
goleak is a library imported into test binaries via "go test". 
It acts as a gatekeeper that fails tests if it detects any goroutines 
that were started but never finished.

HOW TO USE IT IN A WORKFLOW:
----------------------------
1. Add it to the Go code: add a TestMain function to *_test.go files.
2. Run the tests: execute "go test ./..."
3. The Result: if a leak is found, the "go test" command itself will exit with 
   a non-zero status (failure) and print the leaked goroutine's stack trace.

EOF
}

# ________________________________________________________________________________________________________________________
# Main Build Logic Entry Point
# ________________________________________________________________________________________________________________________

# 0. Parse Command Line Arguments
# This loop iterates through all CLI provided arguments.
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --help | -h)
      ACTION="HELP" # Flag as help to be handled in the validation stage
      shift
      ;;
    --clean-cache)
      DO_CLEAN=true
      shift
      ;;
    --purge-distrib)
      DO_PURGE_DIST=true
      shift
      ;;
    --report-distrib)
      DO_REPORT_DIST=true
      shift
      ;;
    --scope=*)
      DO_SCOPE="${1#--scope=}"
      shift
      ;;
    build_all)
      ACTION="build_all" # Set target to build all 20 tools concurrently
      shift
      ;;
    *)
      # DYNAMIC DISPATCH: Check if the argument is a valid bash function name.
      # Using '--' ensures that arguments starting with '-' are treated as names, not declare options.
      if declare -f -- "$1" >/dev/null; then
        ACTION="$1"
        shift
      else
        echo "Error: Unknown target or option '$1'"
        # Only fallback to HELP if we don't already have a valid action.
        # This prevents typos at the end of a command from canceling a valid build request.
        if [ -z "${ACTION:-}" ]; then
          ACTION="HELP"
        fi
        shift
      fi
      ;;
  esac
done

# 1. Validation Phase: Mutually Exclusive Arguments
# --scope is strictly for maintenance tasks and cannot be used during a build operation.
if [ -n "${DO_SCOPE:-}" ] && [ -n "${ACTION:-}" ]; then
  echo "Fatal Error: --scope cannot be used when a build target ('${ACTION}') is specified."
  exit 1
fi

# 2. Pre-Execution Maintenance Phase
if [ "${DO_CLEAN:-}" = true ] || [ "${DO_PURGE_DIST:-}" = true ] || [ "${DO_REPORT_DIST:-}" = true ]; then
  # Determine the target for maintenance functions
  # Priority: 1. Build Action, 2. Explicit Scope, 3. Empty (interpreted as 'all' by functions)
  maint_target="${ACTION:-${DO_SCOPE:-}}"

  [ "${DO_CLEAN:-}" = true ] && cleanCache
  [ "${DO_PURGE_DIST:-}" = true ] && purgeDistrib "${maint_target}"
  
  # If no build target was specified, and we are not in help mode, we can exit after maintenance.
  if [ -z "${ACTION:-}" ]; then
    [ "${DO_REPORT_DIST:-}" = true ] && reportDistrib "${maint_target}"
    exit 0
  fi
fi

# 2. Display Help Information
if [ -z "${ACTION:-}" ] || [ "${ACTION:-}" == "HELP" ]; then
  # NO ARGUMENTS or HELP REQUESTED: Display usage guide
  displayHelp
  exit 1
fi

# 3. Execution Phase: Background Processing and Parallelism
mkdir -p "${LOG_PATH}"
rm -rf "${LOG_PATH:?}"/*.log

SUCCESS_COUNT=0
FAILURE_COUNT=0

if [ "${ACTION:-}" == "build_all" ]; then
  # COMPREHENSIVE SUITE: List of all build targets for parallel processing
  declare -a ALL_BUILDS=()
  for t in "${MASTER_TOOLS[@]}"; do ALL_BUILDS+=("build_${t}"); done

  echo "Running all builds in parallel..."

  for func in "${ALL_BUILDS[@]}"; do
    # ISOLATION: Launch each build in a background subshell.
    "$func" >"${LOG_PATH}/${func}.log" 2>&1 &
    pid=$!
    pid_map[$pid]="$func"
    echo "  [Started] $func (PID: $pid)"
  done

  # REAL-TIME MONITORING LOOP: Wait for the NEXT process to finish.
  # This provides immediate feedback as tools complete, regardless of order.
  while [ "${#pid_map[@]}" -gt 0 ]; do
    finished_pid=""
    exit_status=0
    # Use 'wait -n' to catch the next finishing job. 
    # The 'if' block captures the exit status safely without triggering 'set -e'.
    if wait -n -p finished_pid; then
      exit_status=0
    else
      exit_status=$?
    fi

    # Process the finished PID if it exists in our map.
    if [ -n "${finished_pid:-}" ] && [ -n "${pid_map[$finished_pid]:-}" ]; then
      func_name="${pid_map[$finished_pid]}"
      if [ "$exit_status" -eq 0 ]; then
        echo "  [Success] $func_name (Finished PID: $finished_pid)"
        ((SUCCESS_COUNT += 1))
      else
        echo "  [FAILED ] $func_name - Status: ${exit_status} (See ${LOG_PATH}/${func_name}.log)"
        ((FAILURE_COUNT += 1))
      fi
      unset "pid_map[$finished_pid]"
    fi
  done
  echo "All parallel build tasks completed."
else
  # SINGLE TARGET: Execute exactly one build function synchronously.
  echo "Running specific build: $ACTION"
  if "$ACTION"; then SUCCESS_COUNT=1; else FAILURE_COUNT=1; fi
fi
BUILD_TOTAL_TIME=$SECONDS

BUILD_STATUS="PASS"
[[ "${FAILURE_COUNT}" -gt 0 ]] && BUILD_STATUS="FAIL" || true

printf "________________________________________________________________________________________________________________________\n"
printf "All builds finished in %dm %ds. Success: %d, Failures: %d, Status: %s\n" "$((BUILD_TOTAL_TIME / 60))" "$((BUILD_TOTAL_TIME % 60))" "${SUCCESS_COUNT}" "${FAILURE_COUNT}" "${BUILD_STATUS}"

if [ "${DO_REPORT_DIST:-}" = true ]; then
  reportDistrib "${ACTION:-}"
fi

printf 'Install Go tools in d:\dev\go-tools [Windows] or /u01/tools/ [linux], and make sure they are accessible via system path\n'
printf 'On Windows, replicate to %%GOPATH%%\\bin\n'

exit "${FAILURE_COUNT}"
