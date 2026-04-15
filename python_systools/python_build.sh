#!/bin/bash
# -----------------------------------------------------------------------------
#  /usr/src/redhat/SPECS/python_build.sh
#  v2.0.2  2026/04/13  XdG (Orchestrator)
# -----------------------------------------------------------------------------
# OBJECTIVE:
#   Achieve a fully isolated, relocatable, and production-grade Python 3.13+
#   build specifically optimized for EL9 IT Engineering and Data Processes.
#
# CORE COMPONENTS:
#   1. Configuration Registry (CONF): Centralized state management for the build.
#   2. Orchestrator (Phase Manager): Supports standalone and RPM-spec lifecycles.
#   3. Isolation Engine: Uses $ORIGIN RPATHs to ensure relocatability.
#   4. Validation Layer: Automated auditing of binary and internal Python state.
#   5. Bootstrap Suite: Core "Business-Class" PyPI bundle for immediate utility.
#
# FUNCTIONALITY:
#   - Standalone: Handles full lifecycle (Deps -> Prep -> Compile -> Package).
#   - RPM Mode: Maps to %prep, %build, %install phases via the --step flag.
#   - Relocatability: Decouples bin/lib/site-packages from absolute paths.
#
# DATA FLOW:
#   User CLI Input -> parse_args -> setup_globals (Registry Init) -> 
#   Phase Execution (Prep -> Compile -> Install -> Bootstrap -> Validate -> Package) ->
#   Final redistributable artifact (.tar.xz)
#
# USAGE EXAMPLES:
#   - Build latest 3.13 (Full Lifecycle):
#       ./python_build.sh --python-version=3.13.13 --custom-libs --all
#
#   - Specialized Build (RPM Phase):
#       ./python_build.sh --python-version=3.13.13 --step=compile
#
#   - Maintenance Re-validation:
#       ./python_build.sh --python-version=3.13.13 --step=validate
#
#   - Production Purge (Clean up after build):
#       ./python_build.sh --python-version=3.13.13 --purge --all
# -----------------------------------------------------------------------------

set -euo pipefail

# ----- 1. Global Configuration Registry -----
# The CONF associative array acts as the single source of truth for the script.
# This prevents "scattered variables" and ensures that global state is 
# predictably initialized and accessible across all modular functions.
declare -A CONF
CONF[SRC_BASE]="/usr/src/redhat"
CONF[DISTRIB_BASE]="/opt/done"
CONF[TARGET_BASE]="/opt/lib"
CONF[SHELL_BUILDUSER]="builder"
CONF[OWNER]="${CONF[SHELL_BUILDUSER]}:users"
CONF[PLATLIBDIR]="lib64"
CONF[PYREPO_URL]="https://www.python.org/ftp/python"

# ----- 2. Log and Error Handling -----
# Standardized logging and error reporting to ensure a consistent UX.
log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

# cleanup(): Triggered on EXIT (via trap). Ensures that temporary states 
# or partial build/install artifacts are handled if the script crashes.
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log "Build failed with exit code $exit_code. Cleaning up..."
    fi
}
trap cleanup EXIT

# ----- 3. Argument Parsing & CLI Logic -----
usage() {
    cat <<EOF
Usage: $(basename "$0") --python-version=<version> [OPTIONS]

Required:
  --python-version=<v>    Python version to build (e.g., 3.13.13)

Options:
  --openssl-version=<v>   Required for --custom-libs (e.g., 3.6.2)
  --custom-libs           Link against isolated OpenSSL, Expat, and SQLite.
  --purge                 Delete source and installation after packaging.
  --all                   Execute full lifecycle (Default standalone behavior).
  --step=<phase>          Execute a specific phase: prep, compile, install, bootstrap, validate, package.
  --no-deps               Skip DNF dependency check (automatic in RPM builds).
  --mt                    Enable Free-Threading (MT) build (Python 3.14+).
EOF
}

# parse_args(): Transforms CLI flags into the CONF registry state.
# Detects RPM environments automatically to adjust default behaviors.
parse_args() {
    [ $# -eq 0 ] && usage && exit 1
    
    CONF[STEP]="all"
    CONF[CUSTOM_LIBS]=false
    CONF[PURGE]=false
    CONF[NO_DEPS]=false
    
    # Detect if we are running inside an 'rpmbuild' shell.
    if [ -n "${RPM_BUILD_ROOT:-}" ]; then
        CONF[NO_DEPS]=true
        CONF[RPM_MODE]=true
        log "Detected RPM build environment; skipping host dependency auditing."
    fi

    for arg in "$@"; do
        case $arg in
            --help) usage; exit 0 ;;
            --python-version=*) CONF[PYTHON_VERSION]="${arg#*=}" ;;
            --openssl-version=*) CONF[OPENSSL_VERSION]="${arg#*=}" ;;
            --custom-libs) CONF[CUSTOM_LIBS]=true ;;
            --all) CONF[STEP]="all" ;;
            --purge) CONF[PURGE]=true ;;
            --no-deps) CONF[NO_DEPS]=true ;;
            --mt) CONF[MT]=true ;;
            --distrib=*) CONF[DISTRIB_OVERRIDE]="${arg#*=}" ;;
            --step=*) CONF[STEP]="${arg#*=}" ;;
            *) error "Unknown argument: $arg" ;;
        esac
    done

    [ -z "${CONF[PYTHON_VERSION]:-}" ] && error "--python-version is required."
    if ${CONF[CUSTOM_LIBS]} && [ -z "${CONF[OPENSSL_VERSION]:-}" ]; then
        error "--openssl-version is required when using --custom-libs."
    fi
}

# setup_globals(): Derived paths and version-neutral identifiers.
# This phase handles the transformation of raw versions into build paths.
setup_globals() {
    # Version Derivations
    CONF[PV]="${CONF[PYTHON_VERSION]:-}"
    [ -z "${CONF[PV]}" ] && error "Python version not found. Use --python-version."
    
    CONF[PBV]="${CONF[PV]%.*}"
    CONF[PBID]="${CONF[PBV]%%.*}" # "3" prefix for /opt/lib/python3 (Version-neutral)

    # 3.14+ Free-Threading (MT) Detection and Configuration.
    # Python 3.13 introduced experimental free-threading, but 3.14 standardizes
    # 't' suffixing and GIL-disable flags. We gate this to 3.14+ per requirements.
    CONF[V_MAJOR]=$(echo "${CONF[PYTHON_VERSION]}" | cut -d. -f1)
    CONF[V_MINOR]=$(echo "${CONF[PYTHON_VERSION]}" | cut -d. -f2)
    CONF[MT_ENABLED]=false
    CONF[BIN_SUFFIX]=""
    CONF[COMPILE_OPTS]=""

    if [[ "${CONF[MT]:-false}" == "true" ]]; then
        if [ "${CONF[V_MAJOR]}" -eq 3 ] && [ "${CONF[V_MINOR]}" -ge 14 ]; then
            log "Configuring Free-Threading (MT) build for Python ${CONF[PBV]}"
            CONF[MT_ENABLED]=true
            CONF[BIN_SUFFIX]="t"           # Standard suffix for GIL-less builds (python3.14t)
            CONF[COMPILE_OPTS]="--disable-gil"
        else
            log "WARNING: --mt requested but not supported for version ${CONF[PV]} (Requires 3.14+)"
        fi
    fi
    # PBVT: Version-neutral identifier including the 't' suffix if enabled (e.g., 3.14t).
    # Used for binary names and shared library linking.
    CONF[PBVT]="${CONF[PBV]}${CONF[BIN_SUFFIX]}"
    
    # Dynamic Distribution Detection: 
    # Prioritizes CLI override (--distrib); then /etc/distrib; 
    # then auto-parsing /etc/os-release.
    if [ -n "${CONF[DISTRIB_OVERRIDE]:-}" ]; then
        CONF[DISTRIB]="${CONF[DISTRIB_OVERRIDE]}"
    elif [ -f /etc/distrib ]; then
        CONF[DISTRIB]=$(cat /etc/distrib | tr -d '[:space:]')
    else
        # Fallback: Extract major version and prefix with 'el'.
        local os_v=$(grep -oP '(?<=VERSION_ID=")\d+' /etc/os-release || echo "unknown")
        if [ "$os_v" != "unknown" ]; then
            CONF[DISTRIB]="el${os_v}"
        else
            CONF[DISTRIB]="unknown"
        fi
        log "WARNING: /etc/distrib missing; auto-detected distribution as ${CONF[DISTRIB]}"
    fi

    # Path Registry
    CONF[BUILD_BASE]="${CONF[SRC_BASE]}/BUILD"
    CONF[SPECS_BASE]="${CONF[SRC_BASE]}/SPECS"
    CONF[SOURCES_BASE]="${CONF[SRC_BASE]}/SOURCES"
    # Staging Registry: Prioritize RPM_BUILD_ROOT if orchestrated by an RPM spec.
    CONF[BUILDROOT]="${RPM_BUILD_ROOT:-${CONF[SRC_BASE]}/BUILDROOT}"
    if [ -n "${RPM_BUILD_ROOT:-}" ]; then
        CONF[INSTALL_BASE]="${RPM_BUILD_ROOT}"
    else
        CONF[INSTALL_BASE]="${CONF[BUILDROOT]}/Python-${CONF[PV]}"
    fi
    CONF[PYTHON_SOURCE]="${CONF[BUILD_BASE]}/Python-${CONF[PV]}"
    CONF[PYTHON_OPT_TARGET]="${CONF[TARGET_BASE]}/python${CONF[PBID]}"
    CONF[AUDITOR]="${CONF[SOURCES_BASE]}/inspect_python.py"
    # Specialized Naming Convention for 3.14+ (GIL vs MT isolation).
    # Legacy versions (< 3.14) maintain the original dash-less naming.
    local name_tag=""
    if [ "${CONF[V_MAJOR]}" -eq 3 ] && [ "${CONF[V_MINOR]}" -ge 14 ]; then
        if ${CONF[MT_ENABLED]}; then name_tag="-MT"; else name_tag="-GIL"; fi
    fi

    CONF[ARCHIVE_PATH]="${CONF[DISTRIB_BASE]}/python-${CONF[PV]}${name_tag}-binaries-${CONF[DISTRIB]}-$(uname -m).tar.xz"
    
    # Log Registry: Timestamped logs stored in /opt/done/ for historical auditing.
    BUILD_LOG="${CONF[DISTRIB_BASE]}/python-${CONF[PV]}${name_tag}-build-${CONF[DISTRIB]}-$(date +%Y%m%d).log"
    
    # Standalone Identity Check: Ensure script runs as the build user to maintain correct permissions.
    if [ -z "${RPM_BUILD_ROOT:-}" ] && [ "$(id -n -u)" != "${CONF[SHELL_BUILDUSER]}" ]; then
        error "Shell user must be '${CONF[SHELL_BUILDUSER]}' for standalone builds to avoid permission pollution."
    fi

    # Ensure Core Hierarchy: Prevents "directory not found" errors during staging.
    mkdir -p "${CONF[BUILD_BASE]}" "${CONF[INSTALL_BASE]}" "${CONF[DISTRIB_BASE]}" "${CONF[TARGET_BASE]}" "${CONF[SOURCES_BASE]}"
}

# ----- 5. Phase Modules -----

# check_dependencies(): Audits the host for compilers and dependent libs.
# Skip this in RPM builds as the Spec file handles this via BuildRequires.
check_dependencies() {
    if ${CONF[NO_DEPS]}; then
        log "Skipping dependency check as requested (assuming RPM environment)."
        return 0
    fi
    
    log "Checking host dependencies (DNF)..."
    local rpms=(
        autoconf automake bluez-libs-devel bzip2-devel gcc gdbm-devel git-core 
        glibc-devel libffi-devel libuuid-devel make mpdecimal-devel ncurses-devel 
        pkgconf-pkg-config readline-devel xz-devel zlib-ng-devel wget
    )
    
    if ${CONF[CUSTOM_LIBS]}; then
        rpms+=( "openssl-cs-devel" "expat-cs-devel" "sqlite-cs-devel" )
    fi
    
    for rpm in "${rpms[@]}"; do
        if ! rpm -q "$rpm" &>/dev/null; then
            # 'libb2-devel' is marked as an external requirement (abort if missing).
            if [[ "$rpm" == "libb2-devel" ]]; then
                error "External package '$rpm' is not installed. This is a hard requirement. Aborting."
            fi
            log "Attempting automated install of missing package: $rpm"
            sudo dnf install -y "$rpm"
        fi
    done
    sudo ldconfig
}

# prep(): Manages source acquisition and initial code patching.
# Mirrors the RPM %prep phase.
prep() {
    log "Phase: PREP (Downloading and Extracting)"
    local url="${CONF[PYREPO_URL]}/${CONF[PV]}/Python-${CONF[PV]}.tar.xz"
    local arch="Python-${CONF[PV]}.tar.xz"
    
    # wget -qN respects local timestamps; only downloads if the server version is newer.
    # Gate this to standalone mode to prevent unauthorized network calls during RPM builds.
    pushd "${CONF[SOURCES_BASE]}" &>/dev/null
    if ! ${CONF[RPM_MODE]:-false}; then
        log "wget -qN ${url}"
        wget -qN --no-check-certificate "${url}"
    else
        log "RPM Mode: Skipping binary download (expecting pre-staged source)."
    fi
    [ ! -s "$arch" ] && error "Failed to acquire source archive $arch. In RPM mode, ensure SOURCE0 is present in ${CONF[SOURCES_BASE]}"
    popd &>/dev/null
    
    # Unpack into the BUILD directory.
    pushd "${CONF[BUILD_BASE]}" &>/dev/null
    rm -rf "Python-${CONF[PV]}"
    tar Jxf "${CONF[SOURCES_BASE]}/$arch"
    [ ! -d "Python-${CONF[PV]}" ] && error "Extraction of $arch failed."
    
    cd "Python-${CONF[PV]}"
    # Optimization Patching: Skip slow PGO tests to speed up the automated build process.
    sed -i '/PROFILE_TASK/{s|-m test --pgo|-V|g;s| --timeout=.*)||}' configure.ac
    sed -i '/PROFILE_TASK/{s|-m test.regrtest --pgo|-V|g;s| --timeout=.*)||}' Makefile*
    find . -name '*.exe' -delete
    rm -f configure pyconfig.h.in
    
    # Rebuild configuration binary from patched templates.
    # Python 3.14+ source requires autoconf 2.72. EL9 provides 2.69.
    # We patch the requirement down to 2.69 as it is functionally compatible 
    # for the generated configure script in this environment.
    if [[ "${CONF[V_MAJOR]}" -eq 3 ]] && [[ "${CONF[V_MINOR]}" -ge 14 ]]; then
        log "Patching configure.ac for autoconf 2.69 compatibility (Python 3.14+)"
        sed -i "s/AC_PREREQ(\[2\.72\])/AC_PREREQ([2.69])/" configure.ac
    fi
    autoconf && autoheader
    popd &>/dev/null
}

# compile(): Orchestrates the binary build using optimized flags.
# Mirrors the RPM %build phase.
compile() {
    log "Phase: COMPILE (Configure & Make)"
    pushd "${CONF[PYTHON_SOURCE]}" &>/dev/null
    
    # PLATLIBDIR (lib64) ensures architecture-dependent modules are correctly segmented.
    export PLATLIBDIR="${CONF[PLATLIBDIR]}"
    
    local cflags="-I${CONF[PYTHON_OPT_TARGET]}/include ${CFLAGS:-}"
    # Prioritize the isolated library prefix for linking.
    local ldflags="-L${CONF[PYTHON_OPT_TARGET]}/${CONF[PLATLIBDIR]} ${LDFLAGS:-}"
    local ldflags_opts="-Wl,-Bsymbolic -Wl,-z,relro -Wl,-z,now -Wl,-s -Wl,--disable-new-dtags"
    local ssl_opts=""
    
    if ${CONF[CUSTOM_LIBS]}; then
        # Configure deep-linking for isolated OpenSSL, Expat, and SQLite.
        local os_root="${CONF[TARGET_BASE]}/openssl"
        local ex_root="${CONF[TARGET_BASE]}/expat"
        local sq_root="${CONF[TARGET_BASE]}/sqlite"
        
        export PKG_CONFIG_PATH="${ex_root}/${CONF[PLATLIBDIR]}/pkgconfig:${sq_root}/${CONF[PLATLIBDIR]}/pkgconfig:${os_root}/${CONF[PLATLIBDIR]}/pkgconfig:${PKG_CONFIG_PATH:-}"
        
        local os_id=$(echo "${CONF[OPENSSL_VERSION]}" | cut -d. -f1,2 | tr -d '.')
        local isollibs="$(pkg-config --libs expat sqlite3 openssl${os_id})"
        local isolcflags="$(pkg-config --cflags expat sqlite3 openssl${os_id})"
        
        # Specialized flags to decouple from system expat.
        export LIBEXPAT_CFLAGS="$(pkg-config --cflags expat)"
        export LIBEXPAT_LDFLAGS="${ldflags_opts} -Wl,-rpath,${ex_root}/${CONF[PLATLIBDIR]} $(pkg-config --libs expat)"
        ssl_opts="--with-ssl-default-suites=openssl --with-openssl=${os_root} --with-openssl-rpath=${os_root}/${CONF[PLATLIBDIR]}"
        
        cflags="$isolcflags $cflags"
        # The complex RPATH below uses $ORIGIN to ensure the binary is relocatable.
        # It searches localized PLATLIBDIR and the version-neutral root.
        ldflags="$isollibs $ldflags -Wl,-rpath,${ex_root}/${CONF[PLATLIBDIR]} -Wl,-rpath,${sq_root}/${CONF[PLATLIBDIR]} -Wl,-rpath,${os_root}/${CONF[PLATLIBDIR]} -Wl,-rpath,${CONF[PYTHON_OPT_TARGET]}/${CONF[PLATLIBDIR]} -Wl,-rpath,'\$\$ORIGIN:\$\$ORIGIN/../lib64:\$\$ORIGIN/../..' -Wl,-z,origin ${ldflags_opts}"
    else
        # Fallback to system OpenSSL headers if custom libraries are not used.
        cflags="$cflags $(pkg-config --cflags openssl)"
        ldflags="$ldflags $(pkg-config --libs-only-L openssl)"
    fi
    
    export CFLAGS="$cflags"
    export LDFLAGS="$ldflags"
    export CPPFLAGS="${CPPFLAGS:-}"

    # Core Configuration:
    # --enable-optimizations: Enables PGO (Profile Guided Optimization) and LTO for maximum performance.
    # --prefix: Sets the version-neutral installation root (/opt/lib/python3).
    # --libdir & --with-platlibdir: Ensures architecture-specific modules are correctly placed in lib64.
    # --disable-test-modules: Prevents installation of the large 'test' suite to keep the bin size lean.
    # --with-ensurepip: Automatically installs 'pip' during the initial install phase.
    # --enable-ipv6 & --enable-shared: Standard requirements for modern network and extension module support.
    # --with-dbmliborder: Explicitly sets the resolution order for DBM modules to avoid system pollution.
    # --with-system-expat: Vital for isolation; ensures we link against our custom expat in /opt/lib/expat.
    # --with-lto: Link-time optimization for reduced binary size and increased execution speed.
    # --without-static-libpython: Prevents creation of bulky static libraries, favoring the shared object.
    ./configure \
        --enable-optimizations \
        --prefix="${CONF[PYTHON_OPT_TARGET]}" \
        --libdir="${CONF[PYTHON_OPT_TARGET]}/${CONF[PLATLIBDIR]}" \
        --with-platlibdir="${CONF[PLATLIBDIR]}" \
        --disable-test-modules \
        --with-ensurepip=install \
        --enable-ipv6 --enable-shared \
        --with-dbmliborder=gdbm:ndbm:bdb \
        --enable-loadable-sqlite-extensions \
        --with-system-expat \
        --with-lto ${ssl_opts} \
        --without-static-libpython \
        ${CONF[COMPILE_OPTS]}

    # BUILD FLOW: Parallel compilation using as many threads as visible CPUs.
    make -j "$(nproc)"
    popd &>/dev/null
}

# install(): Manages the 'make install' into the BUILDROOT staging area.
# Mirrors the RPM %install phase.
install() {
    log "Phase: INSTALL (Staging to BUILDROOT)"
    pushd "${CONF[PYTHON_SOURCE]}" &>/dev/null
    
    # 0. Selective Purge: Only clean the staging area if NOT running in an orchestrated 
    # RPM build environment. This enables additive staging for dual GIL/MT packages.
    if [ -z "${RPM_BUILD_ROOT:-}" ]; then
        find "${CONF[INSTALL_BASE]}" -mindepth 1 -delete 2>/dev/null || true
    fi

    # 1. Standard Installation
    # We inject LD_LIBRARY_PATH to ensure 'ensurepip' can resolve isolated libs (like SSL)
    # in the newly built interpreter during the staging process.
    LD_LIBRARY_PATH=".:${CONF[INSTALL_BASE]}${CONF[PYTHON_OPT_TARGET]}/${CONF[PLATLIBDIR]}" \
    make install DESTDIR="${CONF[INSTALL_BASE]}"
    
    # 2. Robustness Check & Manual Fallback
    # If 'make install' failed to deploy pip (common in isolated/staged builds),
    # we manually trigger 'ensurepip' using the staged resident interpreter.
    local staged_python="${CONF[INSTALL_BASE]}${CONF[PYTHON_OPT_TARGET]}/bin/python${CONF[PBVT]}"
    local site_packages="${CONF[INSTALL_BASE]}${CONF[PYTHON_OPT_TARGET]}/lib/python${CONF[PBVT]}/site-packages"
    
    if [ ! -d "${site_packages}/pip" ]; then
        log "WARNING: pip missing after 'make install'. Attempting manual ensurepip fallback..."
        LD_LIBRARY_PATH="${CONF[INSTALL_BASE]}${CONF[PYTHON_OPT_TARGET]}/${CONF[PLATLIBDIR]}" \
            "${staged_python}" -m ensurepip --default-pip
    fi
    
    local bindir="${CONF[INSTALL_BASE]}${CONF[PYTHON_OPT_TARGET]}/bin"
    pushd "$bindir" &>/dev/null
    
    # Metadata: Install essential Python development tools (i18n, pathfix) for bin directory accessibility.
    for tool in pygettext msgfmt; do
        cp -p "${CONF[PYTHON_SOURCE]}/Tools/i18n/${tool}.py" "${tool}${CONF[PBVT]}.py"
        # Tool symlinks are GIL foundation assets; skip for MT delta.
        if ! ${CONF[MT_ENABLED]}; then
            ln -sf "${tool}${CONF[PBVT]}.py" "${tool}3.py"
            ln -sf "${tool}${CONF[PBVT]}.py" "${tool}.py"
        fi
    done
    cp -p "${CONF[SOURCES_BASE]}/pathfix.py" "pathfix${CONF[PBVT]}.py"
    if ! ${CONF[MT_ENABLED]}; then
        ln -sf "pathfix${CONF[PBVT]}.py" "pathfix3.py"
        ln -sf "pathfix${CONF[PBVT]}.py" "pathfix.py"
    fi
    
    # Execute pathfix utility to update shebang lines globally across the new installation.
    # We invoke the newly built interpreter (python3.14t) to perform the fix.
    LD_LIBRARY_PATH="${CONF[INSTALL_BASE]}${CONF[PYTHON_OPT_TARGET]}/${CONF[PLATLIBDIR]}" \
        ./python"${CONF[PBVT]}" "./pathfix${CONF[PBVT]}.py" \
        -i "${CONF[PYTHON_OPT_TARGET]}/bin/python${CONF[PBVT]}" -pn \
        "${CONF[INSTALL_BASE]}${CONF[PYTHON_OPT_TARGET]}" \
        *"${CONF[PBVT]}".py >/dev/null
    popd &>/dev/null
    
    # Configuration: Configure runtime linker (ld.so) to recognize the isolated library path.
    # Gate this to GIL builds to prevent MT delta-stripping from removing common metadata.
    if ! ${CONF[MT_ENABLED]}; then
        mkdir -p "${CONF[INSTALL_BASE]}/etc/ld.so.conf.d"
        echo "${CONF[PYTHON_OPT_TARGET]}/${CONF[PLATLIBDIR]}" > "${CONF[INSTALL_BASE]}/etc/ld.so.conf.d/python${CONF[PBID]}.conf"
    fi
    
    # Sanity Check: Verify if 'pip' is present in the staged site-packages.
    # Missing pip here indicates an 'ensurepip' failure during 'make install'.
    local site_packages="${CONF[INSTALL_BASE]}${CONF[PYTHON_OPT_TARGET]}/lib/python${CONF[PBVT]}/site-packages"
    if [ ! -d "${site_packages}/pip" ]; then
        error "BOOTSTRAP FAILURE: 'pip' module not found in staged site-packages: ${site_packages}"
    fi
    
    popd &>/dev/null
}

# bootstrap(): Enriches the core Python environment with the "IT Business Bundle."
# Ensures developers have modern packaging and connectivity tools immediately.
bootstrap() {
    log "Phase: BOOTSTRAP (PyPI Packages)"
    # Note: setuptools/wheel are no longer default in 3.12+ ensurepip.
    local target_root="${CONF[INSTALL_BASE]}${CONF[PYTHON_OPT_TARGET]}"
    local python_bin="${target_root}/bin/python${CONF[PBVT]}"
    
    # The 13 IT related packages.
    local pkgs=(pip setuptools wheel build certifi requests virtualenv python-dateutil packaging installer pip-tools cython cffi)
    
    # Use LD_LIBRARY_PATH to ensure 'pip' can see its own libpython shared library.
    export LD_LIBRARY_PATH="${target_root}/${CONF[PLATLIBDIR]}"
    for pkg in "${pkgs[@]}"; do
        log "Enriching core bundle: $pkg"
        "$python_bin" -m pip install --upgrade --ignore-installed --no-warn-script-location "$pkg"
    done
    
    # User Convenience: Standardized Binary Versioning & Symlinking.
    # We ensure all tool binaries follow the 'toolPBV' naming convention (e.g., cython3.14)
    # and provide version-neutral symlinks for immediate CLI accessibility.
    pushd "${target_root}/bin" &>/dev/null
    
    # Tool List: Binaries to be version-suffixed and symlinked.
    local tools=(pip wheel virtualenv cython cythonize cygdb pip-compile pip-sync pyproject-build normalizer)
    
    # 0. Interpreter Aliases: Ensure generic 'python' exists.
    # Standard GIL installs provide 'python3' and 'python3.14' by default.
    # We add 'python' to satisfy legacy script requirements and RPM manifests.
    if ! ${CONF[MT_ENABLED]}; then
        [ -e "python" ] || ln -sf "python${CONF[PBVT]}" "python"
    fi
    
    for tool in "${tools[@]}"; do
        # 1. Versioned Binary Creation (if not already versioned by the package)
        if [ -f "${tool}" ] && [ ! -f "${tool}${CONF[PBVT]}" ]; then
            log "Versioning tool: ${tool} -> ${tool}${CONF[PBVT]}"
            mv "${tool}" "${tool}${CONF[PBVT]}"
        fi
        
        # 2. Establish version-neutral symlinks (GIL only).
        # MT builds skip generic symlinks to avoid overwriting the GIL foundation 
        # while co-staged in the BuildRoot.
        if ! ${CONF[MT_ENABLED]} && [ -f "${tool}${CONF[PBVT]}" ]; then
            # Both 'tool' and 'tool3' aliases (e.g., cython and cython3 -> cython3.14)
            ln -sf "${tool}${CONF[PBVT]}" "${tool}"
            ln -sf "${tool}${CONF[PBVT]}" "${tool}3"
        fi
    done
    
    # Pathfix: Comprehensive shebang correction for all generated scripts. 
    # Pip-installed tools often capture the absolute BuildRoot path in their shebangs.
    # We strip this prefix to ensure the binaries are relocatable to /opt/lib/python3.
    log "Performing global shebang correction for generated tools..."
    local leaked_scripts=$(grep -rlI "${CONF[INSTALL_BASE]}" . || true)
    if [ -n "$leaked_scripts" ]; then
        log "Correcting leaked BuildRoot paths in scripts..."
        sed -i "s|${CONF[INSTALL_BASE]}||g" $leaked_scripts
    fi
    popd &>/dev/null
    
    # Enforce GIL/MT Isolation for 3.14+ (Zero-Overlap)
    if [ "${CONF[V_MAJOR]}" -eq 3 ] && [ "${CONF[V_MINOR]}" -ge 14 ] && ${CONF[MT_ENABLED]}; then
        cleanup_mt_delta
    fi
    unset LD_LIBRARY_PATH
}

# cleanup_mt_delta(): Enforces strict GIL/MT isolation for 3.14+ builds.
# Strips all artifacts already provided by the parallel GIL installation.
cleanup_mt_delta() {
    log "Enforcing MT-Delta Isolation: Stripping GIL-redundant artifacts from BuildRoot..."
    local staged_root="${CONF[INSTALL_BASE]}${CONF[PYTHON_OPT_TARGET]}"
    
    # 1. Strip binaries/scripts lacking the 't' suffix.
    find "${staged_root}/bin" -maxdepth 1 -type f ! -name "*t" ! -name "*t-config" ! -name "*t.py" -delete
    find "${staged_root}/bin" -maxdepth 1 -type l ! -name "*t" ! -name "*t-config" ! -name "*t.py" -delete

    # 2. Strip standard library and include headers that lack the 't' suffix.
    rm -rf "${staged_root}/lib/python${CONF[PBV]}"
    rm -rf "${staged_root}/${CONF[PLATLIBDIR]}/python${CONF[PBV]}"
    rm -rf "${staged_root}/include/python${CONF[PBV]}"

    # 3. Strip shared libraries and pkg-config files handled by the GIL package.
    rm -f "${staged_root}/${CONF[PLATLIBDIR]}/libpython3.so"
    rm -f "${staged_root}/${CONF[PLATLIBDIR]}/pkgconfig/python3.pc"
    rm -f "${staged_root}/${CONF[PLATLIBDIR]}/pkgconfig/python3-embed.pc"
    rm -f "${staged_root}/${CONF[PLATLIBDIR]}/pkgconfig/python-${CONF[PBV]}.pc"
    rm -f "${staged_root}/${CONF[PLATLIBDIR]}/pkgconfig/python-${CONF[PBV]}-embed.pc"
    
    # 4. Strip version-neutral configuration and documentation.
    rm -rf "${CONF[INSTALL_BASE]}/etc/ld.so.conf.d"
    rm -rf "${staged_root}/share"
    
    log "MT-Delta Isolation complete (Zero-overlap confirmed)."
}

# validate(): Performs a strict automated audit of the build results.
# If these checks fail, the build is blocked from packaging.
validate() {
    log "Phase: VALIDATE (Strict Integrity Auditing)"
    local target_root="${CONF[INSTALL_BASE]}${CONF[PYTHON_OPT_TARGET]}"
    local python_bin="${target_root}/bin/python${CONF[PBVT]}"
    
    # Audit 1: RPATH Leaks (Binary Header level)
    log "Auditing RPATH headers for build-path pollution..."
    local leaks=$(readelf -d "$python_bin" | grep RPATH | grep "${CONF[SRC_BASE]}" || true)
    if [ -n "$leaks" ]; then
        error "BUILD FAILURE: RPATH leak detected in binary! $leaks"
    fi
    
    # Audit 2: Deep Logic Check (Runtime level)
    # Invokes the standalone 'inspect_python.py' utility using the newly built interpreter.
    log "Invoking deep inspection audit..."
    export LD_LIBRARY_PATH="${target_root}/${CONF[PLATLIBDIR]}"
    "$python_bin" "${CONF[AUDITOR]}"
    unset LD_LIBRARY_PATH

    # Audit 3: Path Leaks (File Content level)
    # Scans all text files in the installation for absolute BuildRoot staging paths.
    log "Auditing for absolute BuildRoot path leaks in installed files..."
    local path_leaks=$(grep -rI "${CONF[INSTALL_BASE]}" "${target_root}" | head -n 20 || true)
    if [ -n "$path_leaks" ]; then
        error "BUILD FAILURE: BuildRoot path leak detected in installed files! \n$path_leaks"
    fi
    
    log "Validation successful; build integrity confirmed."
}

# package(): Finalizes the redistributable tarball and purges temporary files.
package() {
    log "Phase: PACKAGE (Artifact Creation)"
    
    pushd "${CONF[INSTALL_BASE]}" &>/dev/null
    log "Generating final redistributable archive: ${CONF[ARCHIVE_PATH]}"
    # Capture the entire target hierarchy starting from the prefix root (e.g., opt/lib).
    tar Jcf "${CONF[ARCHIVE_PATH]}" "${CONF[TARGET_BASE]##/}"
    ls -l "${CONF[ARCHIVE_PATH]}"
    popd &>/dev/null
    
    # Optional Purge: Use during CI runs to save storage space.
    if ${CONF[PURGE]}; then
        log "Purging intermediate build artifacts and versioned sandbox..."
        rm -rf "${CONF[PYTHON_SOURCE]}" "${CONF[INSTALL_BASE]}"
    fi
}

# ----- 6. Orchestration & Exit Layer -----
# main(): The primary entry point. Orchestrates the flow based on CLI --step.
main() {
    parse_args "$@"
    setup_globals

    # Automated Logging: Dumps full build output to file while preserving TTY visibility.
    # Note: Disabled if specific steps are run without --all to avoid TTY issues with sudo.
    if [ "${CONF[STEP]}" == "all" ]; then
        exec &> >(tee -a "${BUILD_LOG}")
    fi
    
    case ${CONF[STEP]} in
        prep)       prep ;;
        compile)    compile ;;
        install)    install ;;
        bootstrap)  bootstrap ;;
        validate)   validate ;;
        package)    package ;;
        all)
            check_dependencies
            prep
            compile
            install
            bootstrap
            validate
            package
            ;;
        *) error "Invalid build step requested: ${CONF[STEP]}" ;;
    esac
    
    log "Unified Build process for Python ${CONF[PV]} completed successfully."
}

# EXECUTION ENTRY POINT
main "$@"
