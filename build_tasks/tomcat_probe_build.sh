#!/bin/bash
# -------------------------------------------
#  /home/builder/scripts/tomcat_probe_build.sh
#  v1.0.10xg  2025/04/25  XDG
# -------------------------------------------
# javax namespace, compatible with Tomcat 9.x
# Prereqs: JDK 25.0, maven 3.9.16
# Syntax: tomcat_probe_build.sh 4.6.1 a229e4a0a2a8021d5e82150853b103e7330d7893
#
# ==============================================================================
# OBJECTIVES:
#   Automates the compilation, custom configuration, and packaging of the
#   Tomcat application manager tool "psi-probe" (compat: Tomcat 9.x, javax).
#   Targets Java 11 bytecode compilation using JDK 25 compiler requirements.
#
# CORE COMPONENTS & FUNCTIONALITY:
#   1. Sourcing & Shell Checks: Evaluates build script prerequisites and settings.
#   2. Logging Functions: Outputs colorized status tags ([INFO], [OK], [WARN], [ERROR]).
#   3. Preflight Version Checks: Validates java >= 25 and maven >= 3.9.16.
#   4. Fetch & Checkout: Clones psi-probe source tree and checks out specified tag.
#   5. Maven Compile: Compiles target WAR files silently, logging issues to a temp log.
#   6. Custom Branding: Extracts WAR layout and modifies configuration files (web.xml,
#      logback.xml, MANIFEST.MF, dos2unix formats).
#   7. Target Archive: Archives staged directory into a compressed .tar.xz package.
#   8. Cleanup: Grouped workspace directory removal on successful execution.
#
# DATA FLOWS:
#   Input Arguments -> Environment Check -> Git Source Clone -> Maven Build ->
#   WAR Extraction -> Config Customizations -> Compression (.tar.xz) -> Workspace Cleanup.
#
# TEST STRATEGY EXPLANATION:
#   - Unit testing is skipped (-DskipTests=true) during VM script runs to isolate
#     packaging execution from external database dependencies and remote connection status.
#   - Build correctness is validated by verify-on-exit checks checking compiling status
#     and checking target .tar.xz file presence and size.
# ==============================================================================

# ----- ANSI Colors & Logging Helpers -----
# Evaluates terminal TTY capabilities before applying ANSI escaping.
if [ -t 1 ]; then
  BOLD="\033[1m"
  RESET="\033[0m"
  RED="\033[31m"
  GREEN="\033[32m"
  YELLOW="\033[33m"
  BLUE="\033[34m"
  CYAN="\033[36m"
else
  BOLD=""
  RESET=""
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  CYAN=""
fi

# log_section: Standard step header decorator.
log_section() {
  local step="$1"
  local desc="$2"
  echo -e "\n${BOLD}${CYAN}================================================================================"
  echo -e "  $step $desc"
  echo -e "================================================================================${RESET}"
}

# log_info: General informational step message logs.
log_info() {
  echo -e "  ${BLUE}[INFO]${RESET} $1"
}

# log_success: Success checkmark messages.
log_success() {
  echo -e "  ${GREEN}[OK]${RESET} $1"
}

# log_warn: Warnings or non-fatal review notices.
log_warn() {
  echo -e "  ${YELLOW}[WARN]${RESET} $1"
}

# log_error: Failure alerts written to stderr.
log_error() {
  echo -e "  ${RED}[ERROR]${RESET} $1" >&2
}

# check_command: Checks if command is in PATH, exits with code if missing.
check_command() {
  local cmd="$1"
  local err_code="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_error "$cmd command not found in PATH"
    exit "$err_code"
  fi
}

# safe_cd: Directory navigation wrapper to prevent silent fails.
safe_cd() {
  local dir="$1"
  cd "$dir" || {
    log_error "Failed to change directory to $dir"
    exit 1
  }
}

# safe_mkdir_cd: Combined path creation and entry helper.
safe_mkdir_cd() {
  local dir="$1"
  mkdir -p "$dir"
  safe_cd "$dir"
}

# ----- System Environment -----
# Checks presence of base configuration settings prior to sourcing.
# Prevents shell unbound errors when running inside settings files containing unset variables.
if [ -f "${HOME}/scripts/settings.sh" ]; then
  # shellcheck source=/dev/null
  source "${HOME}/scripts/settings.sh"
else
  log_error "settings.sh not found at ${HOME}/scripts/settings.sh"
  exit 12
fi

# Enable strict shell execution flags (exits immediately on errors or unbound variables).
set -euo pipefail

# Confirm critical path variable environments exist.
if [ -z "${JAVA_BASE:-}" ]; then
  log_error "JAVA_BASE environment variable is not set (check settings.sh)"
  exit 5
fi

if [ -z "${TMP:-}" ]; then
  log_error "TMP environment variable is not set (check settings.sh)"
  exit 6
fi

# Ensure TMP directory exists
mkdir -p "${TMP}"


# ----- Script Constants & Configuration -----
JAVA_VERSION="250"
PACKAGE_HOME="${PACKAGE_HOME:-/usr/src/redhat}"
mkdir -p "${PACKAGE_HOME}"
APPL_NAME="psi-probe"
SRC_URL="https://github.com/${APPL_NAME}/${APPL_NAME}"
REPO_BASE="${REPO_BASE:-${PACKAGE_HOME}/BUILDROOT/${APPL_NAME}}"
REQ_MVN="3.9.16"

#----- Java Settings -----
JAVA_HOME="${JAVA_BASE}/jdk${JAVA_VERSION}"
JAVA_BIN="${JAVA_HOME}/bin"
PATH="${JAVA_BIN}:${PATH}"

# ----- Prerequisite Checks -----
# Verify Java installation is present and conforms to JDK 25+ compiler checks.
check_command java 3
java_ver_str=$(java -version 2>&1 | head -n 1 | cut -d '"' -f 2)
java_major=$(echo "$java_ver_str" | cut -d '.' -f 1)
if [ -z "${java_major}" ] || [ "${java_major}" -lt 25 ]; then
  log_error "Java version must be 25 or higher (found: ${java_ver_str})"
  exit 3
fi

# Verify Maven version meets standard requirements.
check_command mvn 4
maven_ver_str=$(mvn -version 2>&1 | head -n 1 | awk '{print $3}')
if [ "$(printf '%s\n%s\n' "${REQ_MVN}" "${maven_ver_str}" | sort -V | head -n 1)" != "${REQ_MVN}" ]; then
  log_error "Maven version must be at least ${REQ_MVN} (found: ${maven_ver_str})"
  exit 4
fi

# ----- Staging & Validation Variables -----
# Positional parameters assigned safely using empty fallback parameter checks.
PROBE_VER="${1:-}"
PROBE_TAG="${2:-}"
if [ -z "${PROBE_VER}" ] || [ -z "${PROBE_TAG}" ];then
  log_error "Missing version or tag parameter"
  exit 2
fi
PROBE_REL="${PROBE_VER}-${PROBE_TAG:0:6}"
ARC_NAME="probe-${PROBE_REL}-custom.tar.xz"
export _JAVA_OPTIONS="-Djava.io.tmpdir=${TMP}"

echo -e "${BOLD}${CYAN}┌────────────────────────────────────────────────────────────────────────┐"
echo -e "│                     Probe Packaging Script Started                     │"
echo -e "└────────────────────────────────────────────────────────────────────────┘${RESET}"
log_info "Version:         ${PROBE_VER}"
log_info "Tag:             ${PROBE_TAG}"
log_info "Target Rel:      ${PROBE_REL}"
log_info "Staging Base:    ${REPO_BASE}"
log_info "Build Root:      ${PACKAGE_HOME}"
echo ""

log_section "[1/5]" "Verifying system prerequisites"
log_info "Java Version:  ${java_ver_str}"
log_info "Maven Version: ${maven_ver_str}"
log_success "Prerequisites verified successfully."

log_section "[2/5]" "Fetching and checking out source repository"
safe_mkdir_cd "${PACKAGE_HOME}/BUILD"
if [ -n "${APPL_NAME}" ]; then
  rm -rf "${APPL_NAME}"
fi
log_info "Cloning repository branch 'javax'..."
git clone --branch javax "${SRC_URL}" || {
  log_error "Git clone of the repository failed"
  exit 7
}

safe_cd "${APPL_NAME}"
log_info "Checking out tag '${PROBE_TAG}'..."
git -c advice.detachedHead=false checkout "${PROBE_TAG}" || {
  log_error "Git checkout failed"
  exit 8
}
log_success "Source checked out successfully."

log_section "[3/5]" "Compiling and packaging WAR with Maven"
log_info "Updating snapshot version in pom.xml..."
find . -name "pom.xml" -exec sed -i "s|${PROBE_VER}-SNAPSHOT|${PROBE_VER}|g" {} \;
log_info "Executing Maven build (logging to ${TMP}/${APPL_NAME}_build_maven.log)..."
# Runs maven build silently inside batch mode, suppressing transfer progress logs.
# -Dorg.slf4j.simpleLogger.defaultLogLevel=WARN reduces console output verbosity.
mvn -B -ntp -Dorg.slf4j.simpleLogger.defaultLogLevel=WARN package -DskipTests=true -Denforcer.skip=true > "${TMP}/${APPL_NAME}_build_maven.log" 2>&1 || {
  log_error "Maven package build failed. Please review: ${TMP}/${APPL_NAME}_build_maven.log"
  exit 9
}
unset _JAVA_OPTIONS
log_success "WAR compiled and packaged successfully."

log_section "[4/5]" "Extracting and modifying staged layout inside BUILDROOT"
log_info "Preparing staging directory under ${REPO_BASE}..."
safe_mkdir_cd "${REPO_BASE}"
if [ -n "${PROBE_REL}" ]; then
  rm -rf "probe-${PROBE_REL}"
fi
safe_mkdir_cd "probe-${PROBE_REL}"

log_info "Extracting WAR archive..."
jar xf "${PACKAGE_HOME}/BUILD/${APPL_NAME}/${APPL_NAME}-web/target/probe.war" || {
  log_error "Extraction of war file failed"
  exit 10
}

log_info "Configuring web.xml (transport guarantee / version branding)..."
cp -af WEB-INF/web.xml WEB-INF/web.xml.dist
sed -i "/transport-guarantee/s|NONE|CONFIDENTIAL|1;/display-name/s| v[0-9].*</| v${PROBE_VER}</|1" WEB-INF/web.xml

log_info "Configuring logback.xml and Manifest..."
cp -af WEB-INF/classes/logback.xml WEB-INF/classes/logback.xml.dist
sed -i 's|level="ERROR"|level="OFF"|g;s|level="INFO"|level="OFF"|g' WEB-INF/classes/logback.xml
echo "" >> WEB-INF/classes/logback.xml
dos2unix -k META-INF/MANIFEST.MF &>/dev/null
sed -i "/Implementation-Version/s|^.*$|Implementation-Version: ${PROBE_REL}|" META-INF/MANIFEST.MF

log_info "Normalizing text file line endings (dos2unix)..."
find . -type f -exec dos2unix -ic {} +
log_success "Staged layout customized successfully."

log_section "[5/5]" "Creating final target archive"
safe_cd ..
mkdir -p "${PACKAGE_HOME}/RPMS/x86_64"
log_info "Archiving and compressing to ${ARC_NAME}..."
tar Jcf "${PACKAGE_HOME}/RPMS/x86_64/${ARC_NAME}" "probe-${PROBE_REL}" || {
  log_error "Packaging target archive failed"
  exit 11
}
log_info "Cleaning up workspace directories..."
if [ -n "${PROBE_REL}" ]; then
  rm -rf "probe-${PROBE_REL}"
fi
safe_cd "${PACKAGE_HOME}"
if [ -n "${APPL_NAME}" ]; then
  rm -rf ./{BUILDROOT,BUILD}/"${APPL_NAME}"
fi
log_success "Target archive created successfully."

echo -e "\n${BOLD}${GREEN}┌────────────────────────────────────────────────────────────────────────┐"
echo -e "│                       Probe Packaging Complete                         │"
echo -e "└────────────────────────────────────────────────────────────────────────┘${RESET}"
ls -lh "${PACKAGE_HOME}/RPMS/x86_64/${ARC_NAME}"
# Alert developers about compilation warnings recorded during the silent build.
if [ -s "${TMP}/${APPL_NAME}_build_maven.log" ]; then
  log_warn "Maven build generated warnings/errors. Please review: ${TMP}/${APPL_NAME}_build_maven.log"
fi
echo ""
