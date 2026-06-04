#!/usr/bin/env bash

# ==============================================================================
# PIPELINE UTILITY: Generic Java Build & Code Quality Auditing Tool
#
# OBJECTIVES:
#   - Provide a zero-dependency build lifecycle wrapper for single-source
#     Java applications without relying on heavy frameworks (Maven, Gradle).
#   - Integrate code format inspections, error-prone static code checkers, and
#     bytecode analyzers directly into the compiler/packager workflow.
#   - Standardize builds across POSIX (Linux) and Windows-emulation layers.
#
# CORE COMPONENTS & FUNCTIONALITY:
#   1. Argument Parser: Extracts source target, class entrypoints, version tags,
#      custom compiler releases, target distribution path, archive flags, and purge toggles.
#   2. Environment Normalization: Resolves paths between Unix environments and
#      Windows host JVMs utilizing cygpath translation logic.
#   3. Tools Auto-Discovery: Dynamically checks specified home directories for
#      Checkstyle jar, PMD bin wrapper, and SpotBugs bin wrapper.
#   4. Quality Verification Engines:
#      - Checkstyle: Verifies layout and syntax rules relative to `<script>_checkstyle.xml`.
#      - PMD: Inspects code structure for best practices and error-prone templates.
#      - SpotBugs: Runs bytecode inspection to detect structural vulnerabilities.
#   5. Compiler (javac) & Archiver (jar): Handles compilation and resource-linked
#      packaging into a standalone runnable JAR.
#   6. Distribution Archiver: Builds a distribution ZIP archive targeting the
#      compatible JDK platform target and standard project version metadata.
#
# OPERATIONAL DATA FLOW:
#   [CLI Flags] ────► [Option Parser / Normalizer] ────► [Write version.txt]
#                            │
#                            ▼
#              [Quality Checking / Discovery]
#                ├── Checkstyle (XML syntax check) ──► [distrib]/logs/[main-class]_checkstyle_report.txt
#                └── PMD (Static pattern check)    ──► [distrib]/logs/[main-class]_pmd_report.txt
#                            │
#                            ▼
#                   [javac compilation]
#                            │
#                            ├─► (Compilation Fail) ──► Terminate Exit 1
#                            ▼
#              [Bytecode scanning / Packaging]
#                ├── SpotBugs (Class inspections)   ──► [distrib]/logs/[main-class]_spotbugs_report.txt
#                └── jar archiver (manifest inject) ──► [distrib]/bin/[Executable Jar]
#                            │
#                            ▼
#           [Distribution Archiver (--archive)]    ──► [distrib]/[jar-base]-[version]-[githash]-jdk[ver].zip
#                            │
#                            ▼
#                [Post-Build Quality Report]
#                            │
#                            ▼
#           [Optional Object Purge (--purge-obj)]
# ==============================================================================

# Exit script execution immediately if any command in a pipeline fails
set -o pipefail

# Dynamic script location and base name discovery
# - SCRIPT_DIR: Resolves absolute folder location of the script to look up siblings (like XML rules).
# - SCRIPT_NAME: The base filename of the executing script.
# - SCRIPT_BASE: SCRIPT_NAME stripped of its file extension, used for naming linked configuration files.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME=$(basename "${BASH_SOURCE[0]}")
SCRIPT_BASE="${SCRIPT_NAME%.*}"

# Default configuration parameters (can be overridden by command-line arguments)
SRC_FILE=""
MAIN_CLASS=""
JAR_NAME=""
RESOURCES="version.txt"
DISTRIB_DIR="."
PURGE_OBJ=false
ARCHIVE=false

# 1. Parse Command Line Arguments
# Resolves and parses standard command-line flags and parameters.
# Standard POSIX argument parsing loop checking key-value pairs.
TOOLS_PATH=""
VERSION=""
RELEASE_TARGET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tools-path)
      if [ -n "$2" ]; then
        TOOLS_PATH="$2"
        shift 2
      else
        echo "[-] Error: --tools-path requires an argument."
        exit 1
      fi
      ;;
    --version)
      if [ -n "$2" ]; then
        VERSION="$2"
        shift 2
      else
        echo "[-] Error: --version requires an argument."
        exit 1
      fi
      ;;
    --release)
      if [ -n "$2" ]; then
        RELEASE_TARGET="$2"
        shift 2
      else
        echo "[-] Error: --release requires an argument."
        exit 1
      fi
      ;;
    --srcfile|--src-file)
      if [ -n "$2" ]; then
        SRC_FILE="$2"
        shift 2
      else
        echo "[-] Error: --src-file requires an argument."
        exit 1
      fi
      ;;
    --mainclass|--main-class)
      if [ -n "$2" ]; then
        MAIN_CLASS="$2"
        shift 2
      else
        echo "[-] Error: --main-class requires an argument."
        exit 1
      fi
      ;;
    --jarname|--jar-name)
      if [ -n "$2" ]; then
        JAR_NAME="$2"
        shift 2
      else
        echo "[-] Error: --jar-name requires an argument."
        exit 1
      fi
      ;;
    --resources)
      # Check if resources list argument is provided and doesn't start with another dash parameter
      if [ -n "$2" ] && [[ ! "$2" =~ ^- ]]; then
        RESOURCES="$2"
        shift 2
      else
        RESOURCES=""
        shift 1
      fi
      ;;
    --distrib)
      if [ -n "$2" ]; then
        DISTRIB_DIR="$2"
        shift 2
      else
        echo "[-] Error: --distrib requires an argument."
        exit 1
      fi
      ;;
    --purge-obj)
      PURGE_OBJ=true
      shift 1
      ;;
    --archive)
      ARCHIVE=true
      shift 1
      ;;
    *)
      echo "[-] Error: Unknown option $1"
      echo "Usage: $0 [--tools-path <path>] [--version <version>] [--release <version>] [--src-file <file>] [--main-class <class>] [--jar-name <name>] [--resources <list>] [--distrib <path>] [--purge-obj] [--archive]"
      exit 1
      ;;
  esac
done

# Verify all mandatory build parameters are present.
# - SRC_FILE: The target Java class script to compile and analyze.
# - MAIN_CLASS: The class entry point needed by the Jar manifest configuration.
# - JAR_NAME: The target file name for output packaging.
if [ -z "$SRC_FILE" ]; then
  echo "[-] Error: --src-file is a mandatory parameter."
  exit 1
fi

if [ -z "$MAIN_CLASS" ]; then
  echo "[-] Error: --main-class is a mandatory parameter."
  exit 1
fi

if [ -z "$JAR_NAME" ]; then
  echo "[-] Error: --jar-name is a mandatory parameter."
  exit 1
fi

# Resolve and set the base distribution directory paths.
# Default to current directory if not specified.
# Setup logs, class, and bin subdirectories.
LOGS_DIR="${DISTRIB_DIR}/logs"
CLASS_DIR="${DISTRIB_DIR}/class"
BIN_DIR="${DISTRIB_DIR}/bin"

# Prepare Windows normalized output directories.
# These will be utilized when passing output directory flags to native Windows Java tools.
CLASS_DIR_WIN="$CLASS_DIR"
BIN_DIR_WIN="$BIN_DIR"
DISTRIB_DIR_WIN="$DISTRIB_DIR"

if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || "$OSTYPE" == "win32" ]]; then
  if command -v cygpath &> /dev/null; then
    CLASS_DIR_WIN=$(cygpath -w "$CLASS_DIR")
    BIN_DIR_WIN=$(cygpath -w "$BIN_DIR")
    DISTRIB_DIR_WIN=$(cygpath -w "$DISTRIB_DIR")
  fi
fi

# Resolve Default Tools Path if not explicitly defined by CLI.
# - Under Windows shells (MSYS2/Cygwin/win32), defaults to standard D drive location.
# - Under standard Unix/Linux runtimes, defaults to standard opt tools location.
if [ -z "$TOOLS_PATH" ]; then
  if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || "$OSTYPE" == "win32" ]]; then
    TOOLS_PATH="d:/dev/ci-tools"
  else
    TOOLS_PATH="/var/opt/tools"
  fi
fi

# Normalize Tools Path for Cygwin/MSYS2/Git Bash on Windows.
# Translates path patterns to make them readable by native Windows JVM runtimes.
# If default paths exist under Cygwin or Git Bash mount namespaces, mounts are prioritized.
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || "$OSTYPE" == "win32" ]]; then
  if [ "$TOOLS_PATH" = "d:/dev/ci-tools" ]; then
    if [ -d "/d/dev/ci-tools" ]; then
      CI_TOOLS_DIR="/d/dev/ci-tools"
    elif [ -d "/cygdrive/d/dev/ci-tools" ]; then
      CI_TOOLS_DIR="/cygdrive/d/dev/ci-tools"
    else
      CI_TOOLS_DIR="d:/dev/ci-tools"
    fi
  else
    # Dynamic path translation using Unix-to-Windows path translation utilities
    if command -v cygpath &> /dev/null; then
      CI_TOOLS_DIR=$(cygpath -u "$TOOLS_PATH")
    else
      CI_TOOLS_DIR="$TOOLS_PATH"
    fi
  fi
else
  CI_TOOLS_DIR="$TOOLS_PATH"
fi

echo "[*] Resolved CI tools home path to: $CI_TOOLS_DIR"

# 1.5 Handle Version Management
# Injects the application version string into a metadata version resource file (version.txt).
# If a custom version string is passed via CLI, it overwrites the file contents.
# Otherwise, it falls back to parsing the existing version file, or writes '0.0.0-DEV' as default.
if [ -n "$VERSION" ]; then
  echo "[*] Writing version to version.txt: $VERSION"
  echo "$VERSION" > version.txt
  FINAL_VERSION="$VERSION"
else
  if [ -f "version.txt" ]; then
    CURRENT_VER=$(cat version.txt)
    echo "[*] Using existing version from version.txt: $CURRENT_VER"
    FINAL_VERSION="$CURRENT_VER"
  else
    echo "0.0.0-DEV" > version.txt
    echo "[*] Created default version.txt: 0.0.0-DEV"
    FINAL_VERSION="0.0.0-DEV"
  fi
fi

# 1.6 Dynamic Tools Detection
# Searches the resolved CI_TOOLS_DIR up to two directories deep to locate executables and libraries.
# Decouples tool names from specific version numbers.

# Checkstyle Jar file matching:
CHECKSTYLE_JAR=$(find "$CI_TOOLS_DIR" -maxdepth 2 -name "checkstyle-*-all.jar" 2>/dev/null | head -n 1)
if [ -z "$CHECKSTYLE_JAR" ]; then
  CHECKSTYLE_JAR=$(find "$CI_TOOLS_DIR" -maxdepth 2 -name "checkstyle*.jar" 2>/dev/null | head -n 1)
fi

# PMD Base Home path:
PMD_HOME=$(find "$CI_TOOLS_DIR" -maxdepth 2 -type d -name "pmd-bin-*" 2>/dev/null | head -n 1)
if [ -z "$PMD_HOME" ] && [ -d "$CI_TOOLS_DIR/pmd" ]; then
  PMD_HOME="$CI_TOOLS_DIR/pmd"
fi

# SpotBugs Base Home path:
SPOTBUGS_HOME=$(find "$CI_TOOLS_DIR" -maxdepth 2 -type d -name "spotbugs-*" 2>/dev/null | head -n 1)
if [ -z "$SPOTBUGS_HOME" ] && [ -d "$CI_TOOLS_DIR/spotbugs" ]; then
  SPOTBUGS_HOME="$CI_TOOLS_DIR/spotbugs"
fi

# Resolve PMD executable command:
# Invokes batch script wrapper on Windows and Unix script wrapper on POSIX.
PMD_CMD=""
if [ -n "$PMD_HOME" ]; then
  if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || "$OSTYPE" == "win32" ]]; then
    PMD_CMD="$PMD_HOME/bin/pmd.bat"
  else
    PMD_CMD="$PMD_HOME/bin/pmd"
  fi
fi

# Resolve SpotBugs executable command:
# Invokes batch script wrapper on Windows and Unix script wrapper on POSIX.
SPOTBUGS_CMD=""
if [ -n "$SPOTBUGS_HOME" ]; then
  if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || "$OSTYPE" == "win32" ]]; then
    SPOTBUGS_CMD="$SPOTBUGS_HOME/bin/spotbugs.bat"
  else
    SPOTBUGS_CMD="$SPOTBUGS_HOME/bin/spotbugs"
  fi
fi

# 2. Tool Availability Auditing
# Evaluates which code quality analyzers are fully installed.
# Sets toggle flags. Bypasses execution of missing tools with a user warning to prevent build failures.
RUN_CHECKSTYLE=true
RUN_PMD=true
RUN_SPOTBUGS=true

if [ -z "$CHECKSTYLE_JAR" ] || [ ! -f "$CHECKSTYLE_JAR" ]; then
  echo "[!] Warning: Checkstyle jar not located under $CI_TOOLS_DIR. Skipping style check."
  RUN_CHECKSTYLE=false
fi

if [ -z "$PMD_CMD" ] || [ ! -f "$PMD_CMD" ]; then
  echo "[!] Warning: PMD not located under $CI_TOOLS_DIR. Skipping static bug checks."
  RUN_PMD=false
fi

if [ -z "$SPOTBUGS_CMD" ] || [ ! -f "$SPOTBUGS_CMD" ]; then
  echo "[!] Warning: SpotBugs not located under $CI_TOOLS_DIR. Skipping bytecode analysis."
  RUN_SPOTBUGS=false
fi

# Ensure output directory for logs exists prior to validation runs.
mkdir -p "$LOGS_DIR"

# 3. Code Style Verification (Checkstyle)
# Validates layout rules using the dynamic ruleset xml file located in the script directory.
# If running under Cygwin/MSYS2, paths are translated to Windows format.
# Outputs are redirected to logs/[main-class]_checkstyle_report.txt. If no errors are found, the log is deleted.
if [ "$RUN_CHECKSTYLE" = true ]; then
  echo "[+] Executing Checkstyle style validation rules..."
  CHECKSTYLE_CONFIG="${SCRIPT_DIR}/${SCRIPT_BASE}_checkstyle.xml"
  CHECKSTYLE_JAR_WIN="$CHECKSTYLE_JAR"
  if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || "$OSTYPE" == "win32" ]]; then
    if command -v cygpath &>/dev/null; then
      CHECKSTYLE_JAR_WIN=$(cygpath -w "$CHECKSTYLE_JAR")
      CHECKSTYLE_CONFIG=$(cygpath -w "${SCRIPT_DIR}/${SCRIPT_BASE}_checkstyle.xml")
    fi
  fi
  java -jar "$CHECKSTYLE_JAR_WIN" -c "$CHECKSTYLE_CONFIG" "$SRC_FILE" > "${LOGS_DIR}/${MAIN_CLASS}_checkstyle_report.txt" 2>&1
  CHECKSTYLE_STATUS=$?
  if [ $CHECKSTYLE_STATUS -ne 0 ]; then
    echo "[!] Checkstyle found style violations. See ${LOGS_DIR}/${MAIN_CLASS}_checkstyle_report.txt for details."
  else
    echo "[+] Checkstyle validation passed successfully."
    rm -f "${LOGS_DIR}/${MAIN_CLASS}_checkstyle_report.txt"
  fi
fi

# 4. Static Code Inspection (PMD)
# Performs rules checks on Java source files for standard Java error-prone patterns and best practices.
# Writes quality logs to logs/[main-class]_pmd_report.txt. Bypasses validation failures if not zero, deleting clean files.
if [ "$RUN_PMD" = true ]; then
  echo "[+] Executing PMD static code inspections..."
  "$PMD_CMD" check -d "$SRC_FILE" -R category/java/errorprone.xml,category/java/bestpractices.xml -f text > "${LOGS_DIR}/${MAIN_CLASS}_pmd_report.txt" 2>&1
  PMD_STATUS=$?
  if [ $PMD_STATUS -ne 0 ]; then
    echo "[!] PMD identified code quality violations. See ${LOGS_DIR}/${MAIN_CLASS}_pmd_report.txt for details."
  else
    echo "[+] PMD static code inspection passed successfully."
    rm -f "${LOGS_DIR}/${MAIN_CLASS}_pmd_report.txt"
  fi
fi

# 5. Compilation
# Invokes javac compiler directing output bytecodes to class/ directory.
# Enables maximum diagnostics logging (-Xlint:all).
# Supports release class targeting if --release is specified. Aborts build on compiler failure.
if [ -n "$RELEASE_TARGET" ]; then
  echo "[+] Compiling source class files (Release Target: Java $RELEASE_TARGET)..."
  mkdir -p "$CLASS_DIR"
  javac -d "$CLASS_DIR_WIN" -Xlint:all --release "$RELEASE_TARGET" "$SRC_FILE"
else
  echo "[+] Compiling source class files (Default Host JDK Target)..."
  mkdir -p "$CLASS_DIR"
  javac -d "$CLASS_DIR_WIN" -Xlint:all "$SRC_FILE"
fi
COMPILE_STATUS=$?
if [ "$COMPILE_STATUS" -ne 0 ]; then
  echo "[-] Failure: Java compiler invocation failed. Aborting build."
  exit 1
fi
echo "[+] Compilation successful."

# 6. Bytecode Scanning (SpotBugs)
# Performs static bug inspection on compiled class bytecode.
# Scans files under class/ and writes potential bugs to logs/[main-class]_spotbugs_report.txt.
if [ "$RUN_SPOTBUGS" = true ]; then
  echo "[+] Executing SpotBugs bytecode scans..."
  "$SPOTBUGS_CMD" -textui -low "$CLASS_DIR_WIN" > "${LOGS_DIR}/${MAIN_CLASS}_spotbugs_report.txt" 2>&1
  SPOTBUGS_STATUS=$?
  if [ $SPOTBUGS_STATUS -ne 0 ]; then
    echo "[!] SpotBugs identified potential bytecode defects. See ${LOGS_DIR}/${MAIN_CLASS}_spotbugs_report.txt for details."
  else
    echo "[+] SpotBugs bytecode scan passed successfully."
    rm -f "${LOGS_DIR}/${MAIN_CLASS}_spotbugs_report.txt"
  fi
fi

# 7. Executable Packaging
# Invokes Java archive tool (jar) packing compiled binaries and metadata resources.
# Directs executable outputs to bin/ folder. Define main class entrypoint during packaging.
echo "[+] Packaging standalone executable JAR archive..."
mkdir -p "$BIN_DIR"
# shellcheck disable=SC2086
if ! jar cvfe "${BIN_DIR_WIN}/$JAR_NAME" "$MAIN_CLASS" -C "$CLASS_DIR_WIN" . $RESOURCES; then
  echo "[-] Failure: JAR archiver invocation failed. Aborting build."
  exit 1
fi

# 7.5 Archive Generation
# If --archive option is enabled, compiles a distribution ZIP containing the built JAR.
# The filename format is: [jar-base]-[version]-[git-hash]-jdk[jdk-version].zip
# Saved directly to current directory or distrib base directory.
if [ "$ARCHIVE" = true ]; then
  echo "[+] Generating distribution ZIP archive..."
  JAR_BASE_NAME="${JAR_NAME%.*}"
  GIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "NOGIT")

  # Extract JDK compatibility version
  if [ -n "$RELEASE_TARGET" ]; then
    JDK_VERSION="$RELEASE_TARGET"
  else
    RAW_VERSION=$(javac -version 2>&1 | head -n 1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || javac -version 2>&1 | head -n 1 | grep -oE '[0-9]+' | head -n 1)
    if [[ "$RAW_VERSION" =~ ^1\.([0-9]+) ]]; then
      JDK_VERSION="${BASH_REMATCH[1]}"
    else
      JDK_VERSION="${RAW_VERSION%%.*}"
    fi
  fi
  if [ -z "$JDK_VERSION" ]; then
    JDK_VERSION="UNKNOWN"
  fi

  ZIP_NAME="${JAR_BASE_NAME}-${FINAL_VERSION}-${GIT_HASH}-jdk${JDK_VERSION}.zip"
  echo "[+] Packing ${ZIP_NAME}..."
  if command -v zip &>/dev/null; then
    zip -9mj "${DISTRIB_DIR}/${ZIP_NAME}" "${BIN_DIR}/${JAR_NAME}"
  else
    jar cf "${DISTRIB_DIR_WIN}/${ZIP_NAME}" -C "${BIN_DIR_WIN}" "${JAR_NAME}" && rm -f "${BIN_DIR}/${JAR_NAME}"
  fi
  echo "[+] Archive successfully created and JAR moved to: ${DISTRIB_DIR}/${ZIP_NAME}"
fi

# 8. Post-Build Quality Review
# Evaluates log reports archived in the logs directory.
# If style violations, PMD issues, or bytecode warnings were found, alerts user with troubleshooting tips.
QUALITY_ISSUES_FOUND=false

if [ -f "${LOGS_DIR}/${MAIN_CLASS}_checkstyle_report.txt" ]; then
  echo ""
  echo "[!] WARNING: Checkstyle code style violations were identified."
  echo "    - File: ${LOGS_DIR}/${MAIN_CLASS}_checkstyle_report.txt"
  echo "    - How to address: Review bracket layouts, imports ordering, variable naming, and line lengths."
  QUALITY_ISSUES_FOUND=true
fi

if [ -f "${LOGS_DIR}/${MAIN_CLASS}_pmd_report.txt" ]; then
  echo ""
  echo "[!] WARNING: PMD static code inspections identified quality issues."
  echo "    - File: ${LOGS_DIR}/${MAIN_CLASS}_pmd_report.txt"
  echo "    - How to address: Inspect unused variables/imports, simplify complex conditionals, and fix resource cleanups."
  QUALITY_ISSUES_FOUND=true
fi

if [ -f "${LOGS_DIR}/${MAIN_CLASS}_spotbugs_report.txt" ]; then
  echo ""
  echo "[!] WARNING: SpotBugs identified bytecode analysis warnings."
  echo "    - File: ${LOGS_DIR}/${MAIN_CLASS}_spotbugs_report.txt"
  echo "    - How to address: Resolve potential null pointers, verify concurrency locks, and secure object references."
  QUALITY_ISSUES_FOUND=true
fi

if [ "$QUALITY_ISSUES_FOUND" = true ]; then
  echo ""
  echo "[!] Tip: You can run style formatters (e.g. google-java-format or IDE cleanup plugins) to automatically resolve most style warnings."
  echo ""
fi

# 9. Intermediate Objects Purge
# If --purge-obj is enabled, deletes only the specific compiled class files generated for the main class
# (including its nested/inner classes) under the class directory.
# Linter logs and other build logs are unaffected by this operation.
if [ "$PURGE_OBJ" = true ]; then
  echo "[+] Purging intermediate compiled class files for ${MAIN_CLASS}..."
  CLASS_PATH_PREFIX="${MAIN_CLASS//.//}"
  rm -f "${CLASS_DIR}/${CLASS_PATH_PREFIX}.class" "${CLASS_DIR}/${CLASS_PATH_PREFIX}"'$'*.class
fi

echo "[+] Success: Build pipeline completed successfully."
if [ "$ARCHIVE" = true ]; then
  echo "[+] Binary archived at: ${DISTRIB_DIR}/${ZIP_NAME}"
else
  echo "[+] Binary located at: ${BIN_DIR}/${JAR_NAME}"
fi
exit 0
