#!/bin/bash
# --------------------------------------------------------------------------------
#  gobuild_code-analyzers.sh
#  v1.1.3xg  2026/03/31  XDG
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
# Syntax: gobuild_code-analyzers.sh
# Example: gobuild_code-analyzers.sh
#
# References: see below the toolchain organized by the nature of each tool.
# +----------------+------------------------------------------+--------------------------------------------+------------------------------------------+
# | Tool (20)      | Repo URL                                 | Short Description                          | Recommended Command Line                 |
# +----------------+------------------------------------------+--------------------------------------------+------------------------------------------+
# | TYPE: FORMATTING & STYLE                                                                                                                          |
# +----------------+------------------------------------------+--------------------------------------------+------------------------------------------+
# | gofumpt        | github.com/mvdan/gofumpt                 | Stricter, more opinionated Go formatter    | gofumpt -w -extra .                      |
# | gocritic       | github.com/go-critic/go-critic           | Finds stylistic and performance micro-bugs | gocritic check ./...                     |
# | goconst        | github.com/jgautheron/goconst            | Finds repeated strings to make constants   | goconst -min-occurrences 3 ./...         |
# | go-mnd         | github.com/tommy-muehle/go-mnd           | Detects magic numbers (unnamed constants)  | mnd ./...                                |
# +----------------+------------------------------------------+--------------------------------------------+------------------------------------------+
# | TYPE: STATIC ANALYSIS & LINTING                                                                                                                   |
# +----------------+------------------------------------------+--------------------------------------------+------------------------------------------+
# | golangci-lint  | github.com/golangci/golangci-lint        | Fast, parallel runner for dozens of linters| golangci-lint run ./... --no-config      |
# | staticcheck    | github.com/dominikh/go-tools             | Advanced static analysis with all checks   | staticcheck -checks="all" ./...          |
# | nilaway        | github.com/uber-go/nilaway               | Advanced static nil-panic detector         | nilaway -include-pkgs="<pkg>" ./...      |
# | gocyclo        | github.com/fzipp/gocyclo                 | Measures cyclomatic complexity of functions| gocyclo -over 15 .                       |
# | interfacebloat | github.com/sashamelentyev/interfacebloat | Flags interfaces with too many methods     | interfacebloat -max 5 ./...              |
# | copyloopvar    | github.com/karamaru-alpha/copyloopvar    | Detects loop variable pointer issues       | copyloopvar ./...                        |
# +----------------+------------------------------------------+--------------------------------------------+------------------------------------------+
# | TYPE: SECURITY & VULNERABILITY                                                                                                                    |
# +----------------+------------------------------------------+--------------------------------------------+------------------------------------------+
# | govulncheck    | github.com/golang/vuln                   | Official vulnerability scanner for Go code | govulncheck ./...                        |
# | gosec          | github.com/securego/gosec                | Inspects source code for security problems | gosec -fmt=text ./...                    |
# +----------------+------------------------------------------+--------------------------------------------+------------------------------------------+
# | TYPE: TESTING & PERFORMANCE                                                                                                                       |
# +----------------+------------------------------------------+--------------------------------------------+------------------------------------------+
# | mockery        | github.com/vektra/mockery                | Generates type-safe mocks for interfaces   | mockery --all --inpackage                |
# | goleak         | github.com/uber-go/goleak                | Verifies no Goroutines are leaked in tests | (Inside _test.go) goleak.VerifyNone(t)   |
# | benchstat      | github.com/golang/perf                   | Computes statistics about Go benchmarks    | benchstat old.txt new.txt                |
# +----------------+------------------------------------------+--------------------------------------------+------------------------------------------+
# | TYPE: DEVELOPMENT & VISUALIZATION                                                                                                                 |
# +----------------+------------------------------------------+--------------------------------------------+------------------------------------------+
# | gopls          | go.googlesource.com/tools                | Official Go Language Server (IDE logic)    | gopls check ./...                        |
# | delve (dlv)    | github.com/go-delve/delve                | The standard debugger for the Go language  | dlv debug ./main.go                      |
# | go-callvis     | github.com/ondrajz/go-callvis            | Interactive graph visualization of Go code | go-callvis -format=png -file=<output>    |
# | impl           | github.com/josharian/impl                | Generates method stubs for interfaces      | impl 'r *Receiver' io.Reader             |
# +----------------+------------------------------------------+--------------------------------------------+------------------------------------------+
# | TYPE: ASSET MANAGEMENT                                                                                                                            |
# +----------------+------------------------------------------+--------------------------------------------+------------------------------------------+
# | go.rice        | github.com/GeertJohan/go.rice            | Embeds static assets into Go binaries      | rice embed-go                            |
# +----------------+------------------------------------------+--------------------------------------------+------------------------------------------+


## --- Global Configuration & Build Environment ---
# Centralized paths for source code, binaries, and distribution archives.
INSTALL_BASE="/cygdrive/f/stage/install"
COMPILE_BASE="${INSTALL_BASE}/compile" # Temporary workspace for cloning and building
DISTRIB_BASE="${INSTALL_BASE}/distrib" # Final destination for compressed archives
BUILD_HOME="bin"                       # Subdirectory within each tool where binaries are placed
TAR_OPTS="-Jcf"                        # tar options: J (xz), c (create), f (file)

# System and execution metadata
CPU_CORES=$(nproc)                     # Detected CPU cores for parallel build optimization
LOG_PATH=${TMPDIR}/logs/golang         # Path to store build logs for background tasks
SECONDS=0                              # Timer for calculating total execution duration
ACTION=""                              # Current build target (determined by CLI arguments)
DO_CLEAN=false                         # Flag to trigger cache cleanup before execution

# Go build settings & optimizations
export GOPROXY="https://proxy.golang.org,direct"
# GO_OPTS: -trimpath (removes local file paths), -buildmode=pie (Security: ASLR support), -p (Parallelism)
GO_OPTS="-trimpath -buildmode=pie -p=$((CPU_CORES / 2))"
GOARCH=amd64
GOOS_LIST=(windows linux)             # Compile for both Windows and Linux simultaneously
WINOS_EXT=".exe"
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || "$OSTYPE" == "win32" ]];then
  OS_EXT="${WINOS_EXT}"
else
  OS_EXT=""
fi

# CGO and Cross-Compilation (Zig) settings
# CGO_LDFLAGS: Forces static linking of external libraries (glibc/musl) for portability.
CGO_LDFLAGS="-linkmode external -extldflags '-static'"
ZIG_BIN="d:/dev/zig/zig"               # Path to the Zig executable (used as a C compiler)
ZIG_CACHE="$(cygpath ${LOCALAPPDATA})/zig"
# CC_* variables: Direct Zig to target specific OS/libc families (GNU for Windows, MUSL for Linux).
CC_WINDOWS="${ZIG_BIN} cc -target x86_64-windows-gnu"
CC_LINUX="${ZIG_BIN} cc -target x86_64-linux-musl"

# Clears Zig and Go caches to ensure a fresh build environment.
# Functionality: Deletes temporary build artifacts from Zig's local app data and invokes 'go clean'.
# Objective: Prevent stale objects or corrupted caches from affecting the build integrity.
function cleanCache() {
  echo "Cleaning Zig and Go caches..."
  if [ ! -z "${ZIG_CACHE}" ] && [ "${ZIG_CACHE}" != "/" ] && [ -d "${ZIG_CACHE}" ];then
    rm -rf "${ZIG_CACHE}"/*
  fi
  go clean -cache
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
  case $1 in
    v|-v|--v)
	  ./${PKG_BIN}${OS_EXT} ${1}ersion
	;;
	-V)
	  ./${PKG_BIN}${OS_EXT} ${1}=full
	;;
	meta)
	  go version -m ./${PKG_BIN}${OS_EXT} | grep "^"$'\t'"mod"
	;;
  esac
}

# Prepares the repository for building by setting up the workspace and extracting version metadata.
# Arguments: $1: PKG_NAME (display name), $2: GitHub Org, $3: Repository Name, $4: Tag Filter Regex.
# Functionality: Creates build/distrib directories, clones the source, and calculates the version string.
# Data Flow: [Remote Git] -> [Local Workspace] -> [APP_VERSION/PKG_VER String Generation].
function repoPrep() {
  echo -e "\n----- Building ${PKG_NAME} -----"
  cd ${COMPILE_BASE}
  # Clean up existing distribution artifacts for this tool
  rm -rf ${DISTRIB_BASE}/$1
  # Initialize the compile workspace and the final distribution folder
  mkdir -p $1 ${DISTRIB_BASE}/$1 && cd $1
  # Purge old source to ensure a clean clone
  rm -rf $3
  git clone https://github.com/$2/$3
  cd $3

  # HEURISTIC: Determine the latest semantic tag.
  # 1. List tags. 2. Filter by regex ($4). 3. Sort by version (-V). 4. Exclude pre-releases.
  APP_VERSION=$(git tag -l | grep "$4" | sort -V | grep -v pre | tail -1 | cut -d'/' -f2)
  # FALLBACK: If no tags match, use the last commit date (YYYYMMDD).
  if [ -z "$APP_VERSION" ]; then
    APP_VERSION=$(git log -1 --format=%cs | tr -d '-')
  fi
  APP_HASH=$(git rev-parse --short=7 HEAD)
  # Combine version and hash for a unique identifier (e.g., 1.2.3-abc1234)
  PKG_VER="${APP_VERSION}-${APP_HASH}"
}

# Runs static analysis tasks and source code preparation on the cloned repository.
# Arguments: $1 (Environment mode: "VENDOR" to force vendoring, "FULL" for lint/format).
# Functionality: Standardizes the Go module state and ensures the code is formatted and vetted.
# Data Flow: [Source Code] -> [Go Toolchain (tidy, vendor, fmt, vet)] -> [Staged Git Commit].
function codeAnalysis() {
  # Mode: VENDOR - Necessary for tools with large dependency trees or non-standard go.mod files.
  if [ "$1" == "VENDOR" ];then
    go mod vendor
  fi
  # Synchronize go.mod and go.sum with the actual imports in the source code.
  go mod tidy
  # Mode: FULL - Ensures that the binaries are built from standardized, high-quality source code.
  if [ "$1" == "FULL" ];then
    go fmt ./...
    go vet ./...
  fi
  # Track all local changes (like vendoring or formatting) in a temporary commit for auditability.
  git add . &>/dev/null
  git commit -m "Final build changes" &>/dev/null
}

## Core compilation engine that handles cross-platform Go builds with optional CGO/Zig support.
# Arguments: Space-separated flags like "CMD" (subdir build), "SUB" (shallow subdir), "CGO" (enable Zig CC).
# Functionality: Dynamically sets build paths, env vars, and invokes 'go build' for each target OS.
# Data Flow: [Environment/LDFLAGS] -> [Go Compiler + Zig CC (if CGO)] -> [Architecture-Specific Binaries].
function codeBuild() {
  PATH_REL=".."
  # LOGIC: Navigate to the appropriate subdirectory based on the tool's repository structure.
  if [[ "$*" =~ "CMD" ]];then
    PATH_REL="../../.."
    cd cmd/${PKG_BIN}
  elif [[ "$*" =~ "SUB" ]];then
    PATH_REL="../.."
    cd ${PKG_BIN}
  elif [[ "$*" =~ "PRE" ]];then
    PATH_REL="../.."
  fi
  
  # Calculate the binary destination relative to the current subdirectory.
  BUILD_BASE="${PATH_REL}/${BUILD_HOME}"
  
  # Define Linker Flags (LDFLAGS) for version injection and size reduction.
  if [ -z "${PKG_VER_LDFLAG}" ];then
    GO_LDFLAGS=""
  else
    GO_LDFLAGS="${PKG_VER_LDFLAG}"
  fi
  
  # Enable CGO if requested (required for tools like Delve).
  if [[ "$*" =~ "CGO" ]];then
    CGO=1
	GO_LDFLAGS="${GO_LDFLAGS} ${CGO_LDFLAGS}"
  else
    CGO=0
	GO_LDFLAGS="${GO_LDFLAGS}"
  fi
  
  echo -e "\n  - Compiling version ${PKG_VER}"
  # MAIN LOOP: Build for every Operating System defined in GOOS_LIST.
  for GOOS in "${GOOS_LIST[@]}"; do
    echo "Building for GOOS: $GOOS, GOARCH: $GOARCH"
	# Inject Zig CC as the cross-compiler for C-code dependencies.
	if [ $CGO -eq 1 ];then
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
    CGO_ENABLED=$CGO GOOS=$GOOS go build -ldflags "-s -w ${GO_LDFLAGS}" ${GO_OPTS} -o ${BUILD_BASE}/ >/dev/null
  done
  
  # Return to build directory and verify binaries.
  cd ${BUILD_BASE}
  ls -l ${PKG_BIN}{${OS_EXT},}
}

# Collects compiled binaries and packages them into compressed archives for distribution.
# Arguments: $1: Cleanup target directory, $2: List of extra binaries, $3: "NOPURGE" flag to skip cleanup.
# Functionality: Generates .tar.xz bundles for Windows and Linux, including necessary file extensions.
# Data Flow: [Compiled Binaries] -> [tar/xz Compression] -> [Distrib Folder] -> [Workspace Purge].
function generateArchive() {
  BIN_LIST="${PKG_BIN}"
  if [ ! -z "$2" ];then
    BIN_LIST="${BIN_LIST} $2"
  fi
  
  # WINDOWS PACKAGING: Append .exe to all binaries before zipping.
  # BIN_LIST// /${WINOS_EXT}  : Bash string replacement to add .exe to space-separated names.
  tar ${TAR_OPTS} ${DISTRIB_BASE}/${PKG_NAME}/${PKG_NAME}-${PKG_VER}_windows-amd64.tar.xz ${BIN_LIST// /${WINOS_EXT} }${WINOS_EXT} && rm -f ${BIN_LIST// /${WINOS_EXT} }${WINOS_EXT}
  
  # LINUX PACKAGING: Standard filenames (no extension).
  tar ${TAR_OPTS} ${DISTRIB_BASE}/${PKG_NAME}/${PKG_NAME}-${PKG_VER}_linux-amd64.tar.xz ${BIN_LIST} && rm -f ${PKG_NAME} ${BIN_LIST}
  
  # Listing resulting archives for verification.
  ls -l ${DISTRIB_BASE}/${PKG_NAME}/*.xz
  
  # WORKSPACE CLEANUP: Remove the temporary compile folders to save disk space.
  if [ $? -eq 0 ];then
    cd ../
    if [ "$3" != "NOPURGE" ];then
      # Safety check: Prevent accidental deletion of root or system folders.
      [[ -n "$1" && "$1" != "/" && -d "./$1" ]] && rm -rf ./$1 ./${BUILD_HOME}
	fi
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
    repoPrep ${PKG_NAME} mvdan ${PKG_BASE} "v"
    PKG_VER_LDFLAG=""
    goUpdateModules
    codeAnalysis
    codeBuild "MAIN"
    pkgVersion "--v"
    generateArchive ${PKG_BASE}
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
    repoPrep ${PKG_NAME} golang ${PKG_BASE} "v"
    PKG_VER_LDFLAG=""
    goUpdateModules
    codeAnalysis
    codeBuild "CMD"
    pkgVersion "-v"
    generateArchive ${PKG_BASE}
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
    repoPrep ${PKG_NAME} golangci ${PKG_BASE} "v"
    PKG_VER_LDFLAG=""
    goUpdateModules
    go get github.com/denis-tingaikin/go-header@v0.5.0
    codeAnalysis
    codeBuild "CMD"
    pkgVersion "--v"
    generateArchive ${PKG_BASE}
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
    repoPrep ${PKG_NAME} dominikh ${PKG_BASE} "v"
    PKG_VER_LDFLAG=""
    goUpdateModules
    codeAnalysis
    codeBuild "CMD"
    ./${PKG_NAME}${OS_EXT} -version
    for a in ${PKG_ADDONS};do
      PKG_BIN=$a
      cd ${COMPILE_BASE}/${PKG_NAME}/${PKG_BASE}
      codeBuild "CMD"
      pkgVersion "-v"
    done
	PKG_BIN=${PKG_NAME}
    generateArchive ${PKG_BASE} "${PKG_ADDONS}"
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
    repoPrep ${PKG_NAME} golang ${PKG_BASE} ${PKG_NAME}
    PKG_VER_LDFLAG="-X main.version=${PKG_VER}"
    cd ${PKG_NAME}
    goUpdateModules
    codeAnalysis
    codeBuild "PRE"
    pkgVersion "v"
    generateArchive ${PKG_BASE}
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
	GO_OPTS="${GO_OPTS/-buildmode=pie/}"
    repoPrep ${PKG_NAME} go-delve ${PKG_BASE} "v"
    PKG_VER_LDFLAG=""
    goUpdateModules
    codeAnalysis "VENDOR"
    codeBuild "CMD" "CGO"
    pkgVersion "v"
    generateArchive ${PKG_BASE}
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
    repoPrep ${PKG_NAME} fzipp ${PKG_BASE} "v"
    PKG_VER_LDFLAG=""
    goUpdateModules
    codeAnalysis
    codeBuild "CMD"
	pkgVersion "meta"
    generateArchive ${PKG_BASE}
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
    repoPrep ${PKG_NAME} jgautheron ${PKG_BASE} "v"
    PKG_VER_LDFLAG=""
    goUpdateModules
    codeAnalysis
    codeBuild "CMD"
	pkgVersion "meta"
    generateArchive ${PKG_BASE}
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
    repoPrep ${PKG_NAME} sashamelentyev ${PKG_BASE} "v"
    PKG_VER_LDFLAG=""
    goUpdateModules
    codeAnalysis
    codeBuild "MAIN"
	pkgVersion "meta"
    generateArchive ${PKG_BASE}
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
    repoPrep ${PKG_NAME} uber-go ${PKG_BASE} "v"
    PKG_VER_LDFLAG=""
    goUpdateModules
    codeAnalysis
    codeBuild "CMD"
	pkgVersion "meta"
    generateArchive ${PKG_BASE}
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
    repoPrep ${PKG_NAME} securego ${PKG_BASE} "v"
    PKG_VER_LDFLAG="-X 'main.Version=${APP_VERSION}' -X 'main.GitTag=${APP_HASH}' -X 'main.BuildDate=$(date '+%Y/%m/%d')'"
    goUpdateModules
    codeAnalysis
    codeBuild "CMD"
	pkgVersion "--v"
    generateArchive ${PKG_BASE}
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
	GO_OPTS="${GO_OPTS} -tags release"
    repoPrep ${PKG_NAME} geertjohan ${PKG_BASE} "v"
    PKG_VER_LDFLAG=""
    goUpdateModules
    codeAnalysis
    codeBuild "SUB"
    pkgVersion "meta"
    generateArchive ${PKG_BASE}
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
    repoPrep ${PKG_NAME} tommy-muehle ${PKG_BASE} "v"
    PKG_VER_LDFLAG=""
    goUpdateModules
    codeAnalysis "VENDOR"
    codeBuild "CMD"
    pkgVersion "meta"
    generateArchive ${PKG_BASE}
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
    repoPrep ${PKG_NAME} go-critic ${PKG_BASE} "v"
    PKG_VER_LDFLAG=""
    goUpdateModules
    codeAnalysis
    codeBuild "CMD"
    pkgVersion "meta"
    generateArchive ${PKG_BASE}
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
    repoPrep ${PKG_NAME} josharian ${PKG_BASE} "v"
    PKG_VER_LDFLAG=""
    goUpdateModules
    codeAnalysis
    codeBuild "MAIN"
    pkgVersion "meta"
    generateArchive ${PKG_BASE}
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
    repoPrep ${PKG_NAME} ondrajz ${PKG_BASE} "v"
    PKG_VER_LDFLAG=""
    goUpdateModules
    codeAnalysis
    codeBuild "MAIN"
    pkgVersion "meta"
    generateArchive ${PKG_BASE}
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
    repoPrep ${PKG_NAME} golang ${PKG_BASE} "v"
    PKG_VER_LDFLAG=""
    goUpdateModules
    codeAnalysis
    codeBuild "CMD"
    pkgVersion "meta"
    generateArchive ${PKG_BASE}
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
    repoPrep ${PKG_NAME} vektra ${PKG_BASE} "v"
    PKG_VER_LDFLAG=""
    goUpdateModules
    codeAnalysis
    codeBuild "MAIN"
    pkgVersion "meta"
    generateArchive ${PKG_BASE}
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
    repoPrep ${PKG_NAME} karamaru-alpha ${PKG_BASE} "v"
    PKG_VER_LDFLAG=""
    goUpdateModules
    codeAnalysis
    codeBuild "CMD"
    pkgVersion "meta"
    generateArchive ${PKG_BASE}
  )
}

function build_goleak() {
  cat << "EOF"

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
    --help|-h)
      ACTION="HELP" # Flag as help to be handled in the validation stage
      shift
    ;;
    --clean-cache)
      # Execution immediately cleans caches if the flag is present
      cleanCache
      DO_CLEAN=true
      shift
    ;;
    all)
      ACTION="all" # Set target to build all 20 tools concurrently
      shift
    ;;
    *)
      # DYNAMIC DISPATCH: Check if the argument is a valid bash function name
      if declare -f "$1" > /dev/null; then
        ACTION="$1"
        shift
      else
        echo "Error: Unknown target or option '$1'"
        ACTION="HELP" # Unknown input fallback: show usage guide
        shift
      fi
    ;;
  esac
done

# 1. Action Validation Logic Gate
if [ -z "$ACTION" ]; then
  if [ "$DO_CLEAN" = true ]; then
    echo "Clean complete. Exiting."
    exit 0
  else
    ACTION="HELP" # No arguments provided: default to help.
  fi
fi

# 2. Display Help Information
if [ "$ACTION" == "HELP" ]; then
  # NO ARGUMENTS SPECIFIED: Display Help
  echo "-------------------------------------------------------------------"
  echo " Go Build Pipeline - Usage"
  echo "-------------------------------------------------------------------"
  echo "Syntax:  $(basename "$0") [option] [target]"
  echo ""
  echo "Options:"
  echo "  --help, -h            Display this help menu"
  echo "  --clean-cache         Clean Zig and Go caches"
  echo ""
  echo "Targets:"
  echo "  all                   Build every tool in parallel"
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
  echo "Example: ./$(basename "$0") --clean-cache all"
  echo "-------------------------------------------------------------------"
  exit 1
fi

# 3. Execution Phase: Background Processing and Parallelism
mkdir -p ${LOG_PATH}
rm -f ${LOG_PATH}/*.log

if [ "$ACTION" == "all" ]; then
  # COMPREHENSIVE SUITE: List of all build targets for parallel processing
  ALL_BUILDS=(build_gofumpt build_govulncheck build_golangci-lint build_staticcheck build_gopls build_delve build_gocyclo build_goconst build_interfacebloat build_nilaway build_gosec build_gorice build_gomnd build_gocritic build_impl build_gocallvis build_benchstat build_mockery build_copyloopvar build_goleak)

  echo "Running all builds in parallel..."
  pids=() # Array to keep track of background Process IDs

  for func in "${ALL_BUILDS[@]}"; do
    # ISOLATION: Launch each build in a background subshell.
    # This prevents environment variable leakage between different tool builds.
    # Output to specific log file.
    $func > "${LOG_PATH}/${func}.log" 2>&1 &
    pids+=($!) # Capturing the PID of the backgrounded subshell
    echo "  [Started] $func (PID: $!)"
  done

  # MONITORING LOOP: Dynamically track completion status of all background jobs.
  # This loop waits for background tasks to complete. For each finished process, it 
  # captures the exit status and cross-references the PID with the ALL_BUILDS list 
  # to provide real-time feedback on which specific tool succeeded or failed.
  while [ ${#pids[@]} -gt 0 ]; do
    # Wait for the next process to exit and capture its PID and status.
    wait -n -p finished_pid
    exit_status=$?

    # Resolve the function name associated with the finished PID.
    for i in "${!pids[@]}"; do
      if [[ "${pids[$i]}" == "$finished_pid" ]]; then
        func_name="${ALL_BUILDS[$i]}"
            
        if [ $exit_status -eq 0 ]; then
          echo "  [Success] $func_name (Finished PID: $finished_pid)"
        else
          # Error handling: Point the user to the tool-specific log file on failure.
          echo "  [FAILED ] $func_name - Status: $exit_status (See ${LOG_PATH}/${func_name}.log)"
        fi
            
        # Removal: Update the array to reflect that this job is complete.
        unset "pids[$i]"
        break
      fi
    done
  done
  echo "All parallel build tasks completed."
else
  # SINGLE TARGET: Execute exactly one build function synchronously.
  echo "Running specific build: $ACTION"
  $ACTION
fi
BUILD_TOTAL_TIME=$SECONDS

echo "________________________________________________________________________________________________________________________"
echo "All builds finished in $((BUILD_TOTAL_TIME / 60))m $((BUILD_TOTAL_TIME % 60))s."
echo "Install Go tools in d:\dev\go-tools [Windows] or /u01/tools/ [linux], and make sure they are accessible via system path"
echo "On Windows, replicate to %GOPATH%\bin"
