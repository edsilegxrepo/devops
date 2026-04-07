#!/bin/bash
# -----------------------------------------------------------------------------
# OpenSSL Build Tool (openssl_build.sh)
# v1.1.6xg  2026/04/07  XdG
#
# OBJECTIVE:
# Provide a unified, automated script for building OpenSSL from source in three 
# primary scenarios:
#   1. ARCHIVE mode: Standalone full-lifecycle build for developers. Handles 
#      source downloading, logging, and packaging into a distributable archive.
#   2. RPM mode: Phased build integrated into an RPM spec pipeline. Decouples
#      compilation from installation/patching to support standard RPM stages.
#   3. ALL mode: A hybrid mode for spec files that performs RPM-style phased
#      builds but also generates a standalone .tar.xz archive for distribution.
#
# CORE COMPONENTS:
# - Mode-specific Env Setup: Dynamically calculates paths based on build mode.
# - Isolated Staging: Uses DESTDIR to install into a controlled directory tree.
# - Metadata Patching: Modifies ELF headers (SONAME/RPATH)
#   of all artifacts (bins, libs, modules) to allow side-by-side installations
#   in isolated prefixes without system-wide library conflicts.
# - Hardened Stripping: Uses link-time stripping (-Wl,-s) to prevent dynamic 
#   loader crashes caused by post-build table misalignment.
# - Path Normalization: Standardizes manpages, docs, and config layouts.
#
# DATA FLOW:
#   [CLI Args] -> [parse_args] -> [setup_build_env]
#      |
#      +-- ARCHIVE: [download] -> [compile] -> [install] -> [patch] -> [tar]
#      |
#      +-- RPM (build):   [compile]
#      +-- RPM (install): [install] -> [patch]
#      +-- ALL (build):   [compile]
#      +-- ALL (install): [install] -> [patch] -> [tar]
#
# PREREQUISITES:
# - patchelf: Mandatory for binary/library header modification.
# - gcc, make, perl: Standard build toolchain.
# - wget: Used for source download in ARCHIVE mode.
# - tar: Used for archive creation in ARCHIVE mode.
# - gzip: Used for manpage compression in ARCHIVE mode.
# - sed: Used for path normalization in ARCHIVE mode.
# - zlib-devel: headers used for openssl compilation
# - rpm-build: Used to build RPMs from spec file.
# -----------------------------------------------------------------------------

set -o pipefail
set -o errexit
set -o nounset

# --- Global Logic Variables ---
VERSION_INPUT=""       # Target version to build (e.g., 3.6.1)
BUILD_MODE_INPUT=""    # Build strategy: 'RPM', 'ARCHIVE', or 'ALL'
ACTION_INPUT=""        # Targeted phase: 'build' or 'install' (RPM/ALL modes only)
OPENSSL_BASE="${OPENSSL_BASE:-}" # Installation prefix (Inherited from environment or auto-calculated)
SSL_ARCH="${SSL_ARCH:-}"         # Target architecture (Inherited from environment or auto-detected)

# --- Path & Metadata Variables ---
# These are populated dynamically in setup_build_env()
BUILD_FOLDER=""        # Staging root (RPM_BUILD_ROOT or local ./build)
OPENSSL_TAG=""         # Version tag without dots (e.g. 36)
OPENSSL_SONAME=""      # Custom library identifier (based on tag)
OPENSSL_VERSION=""     # Fully qualified version string
OPENSSL_VERSION_BASE="" # Major version (e.g. 3)
SOURCES_BASE=""        # Source download location
BUILD_LOG=""           # Build log path (Archive mode only)
OPENSSL_URL=""         # Upstream download URL (Populated for ARCHIVE/ALL modes)
OPENSSL_INSTALL_BASE="" # Unpacked source directory (e.g. openssl-3.6.1)
OPENSSL_INSTALL_ARCH="" # Filename of source tarball (e.g. openssl-3.6.1.tar.gz)
OPENSSL_BIN_ARCH=""     # Final binary archive name (Archive mode only)

# --- Constant Layout & environment Variables ---
BINDIR=bin
LIBDIR=lib64
CONFDIR=conf.d
PKIDIR=pki
TLSDIR=${PKIDIR}/tls
MAKE_BUILD="make -j $(nproc 2>/dev/null || echo 1)"

# Default paths and identifiers (can be overridden by environment if needed)
DEFAULT_TARGET_BASE="${DEFAULT_TARGET_BASE:-/opt/lib}" # Shared location for all OpenSSL versions
DEFAULT_BUILD_BASE="/opt/done"      # Archives and logs are saved here
DEFAULT_SRC_BASE="/usr/src/redhat"  # Root of the local workspace
DEFAULT_BUILD_USER="builder"        # Authorized user for ARCHIVE builds
DEFAULT_ARCH_TAG="$(uname -m)"      # Dynamic architecture detection for archives
DISTRIB_INFO_FILE="/etc/distrib"    # File containing distribution ID
LD_SO_CONF_ROOT="etc/ld.so.conf.d"  # System linker configuration directory
OPENSSL_SRC_URL_BASE="https://www.openssl.org/source" # Upstream source location

# --- Helper Functions ---

# usage: Display script usage and exit
usage() {
  cat <<EOF
Usage: $(basename "$0") --version=X.Y.Z --build-mode=[RPM|ARCHIVE]

Description:
  This script builds OpenSSL from source in one of two modes:

  RPM Mode (Integrated):
    - Designed to be called from inside an RPM .spec file.
    - Requires environmental variables:
        RPM_BUILD_ROOT: The staging directory for the build.
        OPENSSL_BASE: The base path where OpenSSL will be installed (e.g., /var/opt/openssl3).
        SSL_ARCH: The OpenSSL target architecture (e.g., linux-x86_64).
    - It performs building, installation to \$RPM_BUILD_ROOT, and custom SONAME/RPATH patching.

  ARCHIVE Mode (Standalone):
    - Manual standalone build for testing or local distribution.
    - Downloads source directly from OpenSSL.org.
    - Installs into a local staging directory and creates a .tar.xz archive.
    - Logs all output to a log file in /opt/done.
    - Prerequisites: Must be run as user 'builder'.

  ALL Mode (Interpreted):
    - Designed to be called from inside an RPM .spec file.
    - Behaves like RPM mode (phased build/install) but also generates a standalone 
      .tar.xz archive during the 'install' phase.

Arguments:
  --version=X.Y.Z      The OpenSSL version to build (e.g., 3.6.1).
  --build-mode=MODE    The build mode, either 'RPM', 'ARCHIVE', or 'ALL'.
  --action=ACTION      (RPM/ALL Mode only) Action to perform: 'build' or 'install'.
  -h, --help           Display this help message and exit.

Example:
  $(basename "$0") --version=3.6.1 --build-mode=ARCHIVE
  $(basename "$0") --version=3.6.1 --build-mode=RPM --action=build
EOF
  exit 0
}

# log_err: Formatted error output for diagnostic visibility
log_err() {
  echo "*** Error: $*" >&2
}

# die: Terminate script with an error message and specific exit code
die() {
  local code=$1
  shift
  log_err "$*"
  exit "$code"
}

# parse_args: Extracts flags and values from command line
parse_args() {
  if [[ $# -eq 0 ]]; then
    usage
  fi

  for i in "$@"; do
    case "$i" in
      -h|--help)
        usage
        ;;
      --version=*)
        VERSION_INPUT="${i#*=}"
        ;;
      --build-mode=*)
        BUILD_MODE_INPUT="${i#*=}"
        ;;
      --action=*)
        ACTION_INPUT="${i#*=}"
        ;;
      *)
        usage
        ;;
    esac
  done
}

# validate_input: Performs sanity checks on CLI arguments for structural safety
validate_input() {
  if [[ ! "$VERSION_INPUT" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    die 1 "--version=X.Y[.Z] must be specified (e.g. 3.6.1)."
  fi

  if [[ "$BUILD_MODE_INPUT" != "RPM" ]] && [[ "$BUILD_MODE_INPUT" != "ARCHIVE" ]] && [[ "$BUILD_MODE_INPUT" != "ALL" ]]; then
    die 7 "--build-mode must be 'RPM', 'ARCHIVE', or 'ALL'."
  fi

  if [[ "$BUILD_MODE_INPUT" == "RPM" ]] || [[ "$BUILD_MODE_INPUT" == "ALL" ]]; then
    if [[ "$ACTION_INPUT" != "build" ]] && [[ "$ACTION_INPUT" != "install" ]]; then
      die 8 "RPM/ALL mode requires --action to be either 'build' or 'install'."
    fi
  fi
}

# check_prerequisites: Verify that all mandatory system tools are available
check_prerequisites() {
  local tools=("patchelf" "gcc" "make" "wget" "tar" "gzip" "sed" "rpm")
  
  for tool in "${tools[@]}"; do
    if ! command -v "$tool" &>/dev/null; then
      die 9 "Mandatory tool '$tool' is not installed. Please install the required toolchain."
    fi
  done
}

# setup_build_env: Pre-calculates internal variables and paths
# This function is the "brain" of the script, determining where files are
# downloaded, where they are staged, and how they are tagged for isolation.
setup_build_env() {
  # Version Deconstruction: Splits 3.6.1 into major/minor components
  OPENSSL_VERSION_BASE=$(echo "$VERSION_INPUT" | cut -d. -f1) # Expected: 3
  local v_maj
  local v_min
  v_maj=$(echo "$VERSION_INPUT" | cut -d. -f2)
  v_min=$(echo "$VERSION_INPUT" | cut -d. -f3)

  # Construct tags used for isolated path naming (e.g. 3.6.1 -> 36)
  local openssl_v_major="${OPENSSL_VERSION_BASE}.${v_maj}"
  OPENSSL_VERSION="${openssl_v_major}${v_min:+.${v_min}}"
  OPENSSL_TAG="${openssl_v_major//./}"
  OPENSSL_SONAME="${OPENSSL_TAG}"

  if [[ "$BUILD_MODE_INPUT" == "RPM" ]] || [[ "$BUILD_MODE_INPUT" == "ALL" ]]; then
    # RPM/ALL Builds: Inherit BUILDROOT from spec file and validate mandatory exports
    if [[ -z "${RPM_BUILD_ROOT:-}" ]]; then
      die 4 "RPM_BUILD_ROOT must be set in RPM/ALL mode."
    fi
    if [[ -z "${OPENSSL_BASE:-}" ]] || [[ -z "${SSL_ARCH:-}" ]]; then
      die 5 "OPENSSL_BASE and SSL_ARCH must be exported by the spec file."
    fi
    BUILD_FOLDER="${RPM_BUILD_ROOT}"
  else
    # ARCHIVE Mode: Standalone build with local defaults (requires 'builder' user)
    if [[ "$(id -n -u)" != "$DEFAULT_BUILD_USER" ]]; then
      die 2 "Shell user must be $DEFAULT_BUILD_USER to install a local openssl."
    fi
    BUILD_FOLDER="./build"
  fi

  # Metadata & Pathing: Hybrid logic for ARCHIVE and ALL modes
  if [[ "$BUILD_MODE_INPUT" == "ARCHIVE" ]] || [[ "$BUILD_MODE_INPUT" == "ALL" ]]; then
    local target_base="${DEFAULT_TARGET_BASE}"
    local build_base="${DEFAULT_BUILD_BASE}"
    local src_base="${DEFAULT_SRC_BASE}"

    # Validation: Ensure all ARCHIVE/ALL mode prerequisites exist before proceeding
    if [[ ! -d "$target_base" ]]; then die 3 "Target base ($target_base) is missing."; fi
    if [[ ! -d "$build_base" ]]; then die 3 "Build base ($build_base) is missing."; fi
    if [[ ! -d "$src_base" ]]; then die 3 "Source base ($src_base) is missing."; fi
    if [[ ! -f "$DISTRIB_INFO_FILE" ]]; then die 3 "Distribution info file ($DISTRIB_INFO_FILE) is missing."; fi

    SOURCES_BASE="${src_base}/SOURCES"
    if [[ ! -d "$SOURCES_BASE" ]]; then die 3 "Source directory ($SOURCES_BASE) is missing."; fi
    
    # In ALL mode, we might override the OPENSSL_BASE if it wasn't inherited
    if [[ -z "${OPENSSL_BASE:-}" ]]; then
      OPENSSL_BASE="${target_base}/openssl"
    fi

    # Initialize Archive metadata
    OPENSSL_INSTALL_BASE="openssl-${OPENSSL_VERSION}"
    OPENSSL_INSTALL_ARCH="${OPENSSL_INSTALL_BASE}.tar.gz"
    OPENSSL_URL="${OPENSSL_SRC_URL_BASE}/${OPENSSL_INSTALL_ARCH}"

    local build_prefix="${build_base}/${OPENSSL_INSTALL_BASE}-binaries-$(cat "$DISTRIB_INFO_FILE")-${DEFAULT_ARCH_TAG}"
    BUILD_LOG="${build_prefix}.log"
    OPENSSL_BIN_ARCH="${build_prefix}.tar.xz"

    # Set architecture if not inherited (Manual/Archive modes)
    if [[ -z "$SSL_ARCH" ]]; then
      SSL_ARCH="$(rpm --eval %{_os})-$(rpm --eval %{_target_cpu})"
    fi
  fi
}

# prepare_sources: Handles source retrieval and log capturing (Archive mode only)
prepare_sources() {
  if [[ "$BUILD_MODE_INPUT" != "ARCHIVE" ]]; then
    return 0 # RPM mode handles source extraction via %setup
  fi

  # Redirect stdout/stderr to a persistent log for Archive builds
  rm -f "${BUILD_LOG}"
  exec > >(tee -a "${BUILD_LOG}") 2>&1

  cd "${SOURCES_BASE}"
  rm -rf "${OPENSSL_INSTALL_BASE}"

  wget -qN "${OPENSSL_URL}"
  tar -zxf "${OPENSSL_INSTALL_ARCH}"
  if [ $? -eq 0 ] && [[ "$*" =~ "--purge"  ]];then
    rm -f "${OPENSSL_INSTALL_ARCH}"
  fi
  cd "${OPENSSL_INSTALL_BASE}"
}

# compile_source: Executes ./Configure and make
compile_source() {
  # Key Configuration Directives:
  # - openssldir: Sets the runtime location for config/certs (Isolated)
  # - -Bsymbolic: Prevents symbol preemption, improving performance and isolation.
  # - relro/now: Security hardening for the GOT.
  # - -s: Link-time stripping. Ensures atomic ELF creation without a symbol table,
  #       preventing .gnu.version misalignment and "undefined symbol" crashes.
  # - rpath: Hardcodes the library search path so binaries find their local libs.
  ./Configure \
    --prefix="${OPENSSL_BASE}" \
    --openssldir="${OPENSSL_BASE}/${TLSDIR}" \
    -Wl,-Bsymbolic \
    -Wl,-z,relro -Wl,-z,now \
    -Wl,-s \
    -Wl,-rpath,"${OPENSSL_BASE}/${LIBDIR}" \
    zlib enable-camellia enable-seed enable-rfc3779 enable-sctp \
    enable-cms enable-md2 enable-rc5 enable-ktls enable-fips -D_GNU_SOURCE \
    enable-ec_nistp_64_gcc_128 no-mdc2 no-ec2m no-sm2 no-sm4 no-atexit \
    no-tests -DOPENSSL_PEDANTIC_ZEROIZATION -fPIC \
    shared "${SSL_ARCH}" '-DDEVRANDOM="\"/dev/urandom\""'

  ${MAKE_BUILD}
}

# install_to_staging: Installs OpenSSL artifacts into the build root
install_to_staging() {
  ${MAKE_BUILD} install DESTDIR="${BUILD_FOLDER}" MANSUFFIX=""
}

# apply_post_install: Fixes binaries, libraries, and modules after installation
# This is the CORE of the "XG" Strategy. It performs surgical modification of
# headers and paths within the staging directory to allow version isolation.
# NOTE: Manual stripping (strip/objcopy) is avoided here to preserve ELF 
# structural integrity; stripping is handled atomically by the linker (-Wl,-s).
apply_post_install() {
  cd "${BUILD_FOLDER}"
  if [[ "$BUILD_MODE_INPUT" == "ARCHIVE" ]] || [[ "$BUILD_MODE_INPUT" == "ALL" ]]; then
    # Create system-level registration for standalone distribution
    mkdir -p "./${LD_SO_CONF_ROOT}"
    echo "${OPENSSL_BASE}/${LIBDIR}" > "./${LD_SO_CONF_ROOT}/openssl${OPENSSL_TAG}.conf"
  fi

  # Enter staging install directory relative to the current staging folder
  pushd ".${OPENSSL_BASE}" &>/dev/null
    # Remove dist files to finalize configuration
    rm -f ./${TLSDIR}/*.dist

    # Normalize manpages: Move config to openssl.cnf.5 and compress everything
    pushd "share/man" &>/dev/null
      mv -f man5/config.5 man5/openssl.cnf.5
      find man[1-9] -type f ! -name "*.gz" -print0 | xargs -0 -P "$(nproc)" gzip -9
    popd &>/dev/null
    pushd "share/doc" &>/dev/null
      rm -rf openssl/html # Save space by removing redundant HTML docs
    popd &>/dev/null

    # Metadata Isolation & Optimization: Delete static libraries to force shared linkage
    find ./${LIBDIR} -name "*.a" -delete

    # Refactor internal hierarchy: Move misc scripts and prepare PKI structures
    mv -f ./${TLSDIR}/misc/* ./${BINDIR}/
    mkdir -p -m755 ./${TLSDIR}/${CONFDIR}
    mkdir -p -m755 ./${PKIDIR}/CA/{private,certs,crl,newcerts}

    # Update openssl.cnf to support modular includes from conf.d
    sed -i '/#.include filename/a \\n# Includes custom configuration\n.include ${__DIR__}/conf.d' ./${TLSDIR}/openssl.cnf
  popd &>/dev/null

  # Fix library naming and SONAMEs to support side-by-side versions
  pushd ".${OPENSSL_BASE}/${LIBDIR}" &>/dev/null
    # 1. Rename pkgconfig files to include the version tag (e.g. libcrypto36.pc)
    mv pkgconfig/libcrypto.pc pkgconfig/libcrypto${OPENSSL_SONAME}.pc
    mv pkgconfig/libssl.pc pkgconfig/libssl${OPENSSL_SONAME}.pc
    mv pkgconfig/openssl.pc pkgconfig/openssl${OPENSSL_SONAME}.pc

    # 2. Update internal .pc content so downstream apps request the tagged names
    sed -i "s|libcrypto$|libcrypto${OPENSSL_SONAME}|;s|-lcrypto|-lcrypto${OPENSSL_SONAME}|" pkgconfig/libcrypto${OPENSSL_SONAME}.pc
    sed -i "s|libssl$|libssl${OPENSSL_SONAME}|;s|-lssl|-lssl${OPENSSL_SONAME}|;s|libcrypto|libcrypto${OPENSSL_SONAME}|g" pkgconfig/libssl${OPENSSL_SONAME}.pc
    sed -i "s|libssl libcrypto|libssl${OPENSSL_SONAME} libcrypto${OPENSSL_SONAME}|" pkgconfig/openssl${OPENSSL_SONAME}.pc

    # 3. Patch internal SONAME metadata so the loader sees 'libcrypto36.so'
    patchelf --set-soname "libssl${OPENSSL_SONAME}.so" "libssl.so.${OPENSSL_VERSION_BASE}"
    patchelf --set-soname "libcrypto${OPENSSL_SONAME}.so" "libcrypto.so.${OPENSSL_VERSION_BASE}"

    # 4. Repoint internal linkage so libssl finds libcrypto36.so and update RPATH
    patchelf --replace-needed "libcrypto.so.${OPENSSL_VERSION_BASE}" "libcrypto${OPENSSL_SONAME}.so" "libssl.so.${OPENSSL_VERSION_BASE}"
    patchelf --set-rpath "${OPENSSL_BASE}/${LIBDIR}" "libssl.so.${OPENSSL_VERSION_BASE}"
    patchelf --set-rpath "${OPENSSL_BASE}/${LIBDIR}" "libcrypto.so.${OPENSSL_VERSION_BASE}"

    # Symlinking
    # 5. Rename files on disk to match the new SONAMEs
    mv -f "libcrypto.so.${OPENSSL_VERSION_BASE}" "libcrypto${OPENSSL_SONAME}.so"
    mv -f "libssl.so.${OPENSSL_VERSION_BASE}" "libssl${OPENSSL_SONAME}.so"

    # 6. Reconstruct the symlink chain for standard linker lookup
    ln -sf "libssl${OPENSSL_SONAME}.so" libssl.so.${OPENSSL_VERSION}
    ln -sf "libcrypto${OPENSSL_SONAME}.so" libcrypto.so.${OPENSSL_VERSION}
    ln -sf "libssl.so.${OPENSSL_VERSION}" libssl.so.${OPENSSL_VERSION_BASE}
    ln -sf "libcrypto.so.${OPENSSL_VERSION}" libcrypto.so.${OPENSSL_VERSION_BASE}
    ln -sf "libssl.so.${OPENSSL_VERSION_BASE}" libssl.so
    ln -sf "libcrypto.so.${OPENSSL_VERSION_BASE}" libcrypto.so

    # Diagnostic Audit: Print ELF metadata to confirm patching
    readelf -d "libcrypto${OPENSSL_SONAME}.so" | grep -E 'RPATH|SONAME|NEEDED|SYMBOLIC'
    readelf -d "libssl${OPENSSL_SONAME}.so" | grep -E 'RPATH|SONAME|NEEDED|SYMBOLIC'
  popd &>/dev/null

  # Binary Linkage Fix: Ensure the openssl binary finds its private libraries
  pushd ".${OPENSSL_BASE}/bin/" &>/dev/null
    patchelf --replace-needed "libssl.so.${OPENSSL_VERSION_BASE}" "libssl${OPENSSL_SONAME}.so" openssl
    patchelf --replace-needed "libcrypto.so.${OPENSSL_VERSION_BASE}" "libcrypto${OPENSSL_SONAME}.so" openssl
    patchelf --set-rpath "${OPENSSL_BASE}/${LIBDIR}" openssl

    readelf -d openssl | grep -E 'RUNPATH|RPATH|SONAME|NEEDED'
  popd &>/dev/null

  # Module Patching: Recursively find and patch all providers and engines
  # This ensures 'fips.so' and 'legacy.so' are also isolated.
  find ".${OPENSSL_BASE}/${LIBDIR}/ossl-modules" ".${OPENSSL_BASE}/${LIBDIR}/engines-${OPENSSL_VERSION_BASE}" -name "*.so" -type f 2>/dev/null | xargs -r -I {} bash -c '
    patchelf --replace-needed "libcrypto.so.${1}" "libcrypto${2}.so" "$3" 2>/dev/null || :
    patchelf --replace-needed "libssl.so.${1}" "libssl${2}.so" "$3" 2>/dev/null || :
    patchelf --set-rpath "${4}" "$3"
  ' -- "${OPENSSL_VERSION_BASE}" "${OPENSSL_SONAME}" "{}" "${OPENSSL_BASE}/${LIBDIR}"

}

# packaging: Creates the final distribution tarball (Archive and ALL modes)
# Target archive contains the installation prefix (e.g. /opt) and any
# system registration files created in ./etc during the patching phase.
packaging() {
  if [[ "$BUILD_MODE_INPUT" == "ARCHIVE" ]] || [[ "$BUILD_MODE_INPUT" == "ALL" ]]; then
    echo "Generating Archive of binaries: ${OPENSSL_BIN_ARCH}"
    # Dynamic discovery of the installation root (handles /opt, /var, etc.)
    local install_root
    install_root=$(echo "${OPENSSL_BASE}" | cut -d/ -f2)
    tar Jcf "${OPENSSL_BIN_ARCH}" etc "${install_root}"
  fi
}

# --- Main Entry Point ---
# Orchestrates the build sequence from config parsing down to result generation
main() {
  parse_args "$@"
  validate_input
  check_prerequisites
  setup_build_env
  prepare_sources # Redundant in RPM mode

  if [[ "$BUILD_MODE_INPUT" == "ARCHIVE" ]]; then
    # Archive Mode performs the entire lifecycle in one pass
    compile_source
    install_to_staging
    apply_post_install
    packaging
  elif [[ "$BUILD_MODE_INPUT" == "RPM" ]] || [[ "$BUILD_MODE_INPUT" == "ALL" ]]; then
    # RPM/ALL Mode: Strictly decoupled phases called by the SPEC file stages
    if [[ "$ACTION_INPUT" == "build" ]]; then
      compile_source
    elif [[ "$ACTION_INPUT" == "install" ]]; then
      install_to_staging
      apply_post_install
      # Extra step for ALL mode: generate the tarball during installation
      if [[ "$BUILD_MODE_INPUT" == "ALL" ]]; then
        packaging
        # Clean up registration files so they don't leak into the RPM payload
        # (The RPM should remain identical across RPM and ALL modes)
        rm -rf "${BUILD_FOLDER}/etc"
      fi
    fi
  fi
}

# Initialize execution with CLI arguments
main "$@"
