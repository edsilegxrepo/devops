#!/bin/bash
# -----------------------------------------------------------------------------
# python_buildenv.sh
# v1.3.0xg  2026/04/28  XDG
# -----------------------------------------------------------------------------
# OBJECTIVE:
#   Provides a centralized orchestration layer for Python RPM packaging.
#   Ensures PEP 376 compliant metadata, conflict-free binary versioning,
#   and standardized build environments across multiple Python versions.
#
# CORE COMPONENTS:
#   1. Environment Bootstrap: Ensures build tools (pip, build, wheel) are present.
#   2. Build/Install Logic: Handles standard wheel creation and root-installs.
#   3. Binary Management: Versions binaries and patches RECORD metadata to match.
# -----------------------------------------------------------------------------

# ----- Environment Configuration -----
distrib_path="dist" # Directory where build artifacts (.whl) are stored

# Smart sudo detection: skip if root, use non-interactive if possible
if [[ $EUID -eq 0 ]]; then
  python_sudo=""
elif sudo -n true &> /dev/null; then
  python_sudo="sudo -n"
else
  python_sudo="sudo"
fi

# ----- Functions -----

# Verify installed python and return normalized version string.
# Arguments:
#   $1 - python_version (optional, defaults to $python_version env var)
# Returns:
#   Echoes version string (e.g. "3.13")
#   Exit codes: 0 (Success), 1 (No version provided), 2 (Python not found)
function check_python_id() {
  local py_ver="$1"
  if [[ -z "${py_ver}" ]]; then
    # Fallback to environment variable if argument is missing
    py_ver=${python_version:-}
    [[ -z "${py_ver}" ]] && return 1
  fi
  # Verify the binary exists in the system PATH
  command -v python"${py_ver}" &> /dev/null || return 2
  echo "${py_ver}"
  return 0
}

# Determine if the package is platform-specific (x64) or universal (noarch).
# Analyzes generated wheel filenames in $distrib_path.
# Returns:
#   Echoes "noarch" or "x64"
#   Exit codes: 0 (Success), 1 (No dist dir), 2 (No wheels), 3 (Unknown type)
function check_wheel_type() {
  [[ ! -d "${distrib_path}" ]] && return 1

  local wheel_files=()
  mapfile -t wheel_files < <(find "${distrib_path}" -type f -name "*.whl")
  [[ ${#wheel_files[@]} -eq 0 ]] && return 2

  if [[ "${wheel_files[*]}" =~ "none-any" ]]; then
    echo "noarch"
    return 0
  elif [[ "${wheel_files[*]}" =~ "linux_x86_64" ]]; then
    echo "x64"
    return 0
  else
    return 3
  fi
}

# Resolve the absolute site-packages path for the target Python version.
# Uses sysconfig to prevent hardcoding paths.
# Arguments:
#   $1 - python_version
# Returns:
#   Echoes absolute path to site-packages
function get_python_lib() {
  local py_ver
  py_ver=$(check_python_id "$1") || return 1

  local check_wheel
  check_wheel=$(check_wheel_type) || return 1

  # Map wheel type to sysconfig path keys
  local p_lib=""
  if [[ "${check_wheel}" == "noarch" ]]; then
    p_lib="purelib"
  elif [[ "${check_wheel}" == "x64" ]]; then
    p_lib="platlib"
  else
    return 1
  fi

  local python_lib_base
  # Data Flow: Query Python's internal config to find its own library prefix
  python_lib_base=$(python"${py_ver}" -Ic "import sysconfig; print(sysconfig.get_path('${p_lib}'))" 2> /dev/null)
  echo "${python_lib_base}"
  return 0
}

# Consolidate metadata for a specific package to ensure only one version exists.
# Objective:
#   Resolves 'RPM vs pip' conflicts by keeping only the metadata that matches
#   the currently active version, purging all "dangling" or older metadata.
# Arguments:
#   $1 - python_version
#   $2 - package_name
function consolidate_package_metadata() {
  local py_ver=$1
  local pkg=$2

  # Get the site-packages paths
  local p_lib
  for p_lib in "purelib" "platlib"; do
    local site_packages
    site_packages=$(python"${py_ver}" -Ic "import sysconfig; print(sysconfig.get_path('${p_lib}'))" 2> /dev/null)
    [[ -z "${site_packages}" || ! -d "${site_packages}" ]] && continue

    # Identify the version pip actually considers active.
    # If pip is broken, this might fail, so we use a fallback to just clean known-broken dirs.
    local active_version
    active_version=$(pip"${py_ver}" show "${pkg}" 2> /dev/null | grep "^Version:" | cut -d' ' -f2)

    # Normalize package name for file matching (replaces '-' with '_')
    local pkg_norm
    pkg_norm=$(echo "${pkg}" | tr '-' '_')

    local metadata_path
    # Pattern match both modern and legacy metadata for this specific package
    for metadata_path in "${site_packages}"/"${pkg}"-*.dist-info "${site_packages}"/"${pkg_norm}"-*.dist-info "${site_packages}"/"${pkg}"-*.egg-info; do
      [[ ! -d "${metadata_path}" ]] && continue

      # CRITICAL SAFETY: Always remove metadata if the METADATA file is missing (corrupted).
      if [[ ! -f "${metadata_path}/METADATA" && ! -f "${metadata_path}/PKG-INFO" ]]; then
        ${python_sudo} rm -rf "${metadata_path}"
        continue
      fi

      # If we found an active version, remove any metadata that DOES NOT match it.
      # We escape dots in the version for literal matching and allow for optional tags (like -py3.13).
      if [[ -n "${active_version}" ]]; then
        local escaped_version
        escaped_version="${active_version//./\\.}"
        local version_regex="-${escaped_version}([-.].*)?\.(dist-info|egg-info)$"
        if [[ ! "$(basename "${metadata_path}")" =~ ${version_regex} ]]; then
          echo "Consolidating metadata: Removing dangling version -> $(basename "${metadata_path}")"
          ${python_sudo} rm -rf "${metadata_path}"
        fi
      fi
    done
  done
}

# Verify that a Python package is properly installed via a 3-tier check:
#   1. Metadata Health (pip show)
#   2. Dependency Integrity (pip check)
#   3. Functional Import (python -c import)
# Arguments:
#   $1 - python_version
#   $2 - package_name
#   $3 - import_name (optional, defaults to normalized package_name)
#   $4 - verbose (optional, 1=Enable detailed logging)
function verify_python_package() {
  local py_ver
  py_ver=$(check_python_id "$1") || return 1
  local pkg=$2
  local import_name=${3:-$(echo "${pkg}" | tr '-' '_')}
  local verbose=${4:-0}

  local log_out="/dev/null"
  [[ "${verbose}" == "1" ]] && log_out="/dev/stdout"
  [[ "${verbose}" == "1" ]] && echo "[VERIFY] Starting 3-tier check for ${pkg} (import: ${import_name})..."

  # Tier 1: Metadata Check
  [[ "${verbose}" == "1" ]] && echo "[VERIFY] Tier 1: Checking metadata (pip show)..."
  if ! python"${py_ver}" -m pip show "${pkg}" &> "${log_out}"; then
    [[ "${verbose}" == "1" ]] && echo "[VERIFY] Tier 1 FAILED: Metadata for ${pkg} is missing or corrupted."
    return 1
  fi

  # Tier 2: Dependency Check
  [[ "${verbose}" == "1" ]] && echo "[VERIFY] Tier 2: Auditing dependencies (pip check)..."
  if ! python"${py_ver}" -m pip check &> "${log_out}"; then
    [[ "${verbose}" == "1" ]] && echo "[VERIFY] Tier 2 FAILED: Global dependency conflict detected."
    return 2
  fi

  # Tier 3: Import Check
  [[ "${verbose}" == "1" ]] && echo "[VERIFY] Tier 3: Testing functional import..."
  if ! python"${py_ver}" -c "import ${import_name}" &> "${log_out}"; then
    [[ "${verbose}" == "1" ]] && echo "[VERIFY] Tier 3 FAILED: Could not import '${import_name}'."
    return 3
  fi

  [[ "${verbose}" == "1" ]] && echo "[VERIFY] SUCCESS: ${pkg} passed all integrity checks."
  return 0
}

# Ensure essential build-time modules are installed and healthy.
# Implements "Try-Then-Force" recovery for broken system metadata.
# Arguments:
#   $1 - python_version
function bootstrap_python_devtools() {
  local py_ver
  py_ver=$(check_python_id "$1") || return 1

  local pkgs="pip build setuptools wheel"

  # Bootstrap pip itself if missing (non-destructive)
  ${python_sudo} python"${py_ver}" -m ensurepip --default-pip 2> /dev/null || true
  echo

  local pkg
  for pkg in ${pkgs}; do
    # OBJECTIVE: Fast update for healthy packages, automatic repair for broken ones.
    # If a package has broken RECORD metadata, standard upgrade fails; --ignore-installed fixes it.
    # We use '|| true' to ensure the bootstrap doesn't kill the RPM build if sudo/network is restricted.
    ${python_sudo} pip"${py_ver}" install --upgrade "${pkg}" --no-warn-script-location 2> /dev/null ||
      ${python_sudo} pip"${py_ver}" install --upgrade "${pkg}" --ignore-installed --no-warn-script-location 2> /dev/null || true

    # POST-INSTALL CONSOLIDATION:
    # After pip runs, we clean up any "dangling" metadata (e.g. RPM-owned folders)
    # to ensure pip only sees the version it just installed.
    consolidate_package_metadata "${py_ver}" "${pkg}"
  done

  return 0
}

# Compile source code into a standard Python Wheel.
# Arguments:
#   $1 - python_version
function python_build() {
  local py_ver
  py_ver=$(check_python_id "$1") || return 1
  shift # Remove version from args

  [[ ! -s "pyproject.toml" ]] && return 2

  # Standard PEP 517 build, allowing for extra arguments (like --no-isolation)
  python"${py_ver}" -m build --wheel "$@"

  local wheel_files=()
  mapfile -t wheel_files < <(find "${distrib_path}" -type f -name "*.whl")
  if [[ ${#wheel_files[@]} -eq 0 ]]; then return 2; else return 0; fi
}

# Perform a root-aware installation into the RPM BUILDROOT.
# Ensures standard PEP 376 RECORD files are generated for downstream tracking.
# Arguments:
#   $1 - python_version
#   $2 - buildroot path
function python_install() {
  local py_ver
  py_ver=$(check_python_id "$1") || return 1
  local buildroot="$2"
  [[ -z "${buildroot}" ]] && return 2

  local wheel_files=()
  mapfile -t wheel_files < <(find "${distrib_path}" -name "*.whl")
  [[ ${#wheel_files[@]} -eq 0 ]] && return 3

  # OBJECTIVE: Use native pip mechanisms to generate trusted metadata.
  # --root redirects the install to the RPM staging area.
  # --ignore-installed ensures a clean slate regardless of host state.
  pip"${py_ver}" install "${wheel_files[@]}" --root "${buildroot}" --no-deps --ignore-installed --no-warn-script-location
}

# Automate binary versioning and metadata synchronization.
# Objective:
#   1. Prevent /usr/bin conflicts by suffixing binaries (e.g. tool -> tool-3.13)
#   2. Patch RECORD files so 'pip list' and 'pip uninstall' remain accurate.
# Arguments:
#   $1 - python_version
#   $2 - buildroot path
#   $3 - pypi_name (for global symlinking)
#   $4 - is_global_default (1=Create global symlinks like /usr/bin/wheel)
function python_binaries() {
  local py_ver
  py_ver=$(check_python_id "$1") || return 1
  local buildroot="$2"
  local pypi_name="$3"
  local is_default="$4"

  # Identity Synchronization:
  # Ensure the INSTALLER identity is set to 'rpm' for all packages in the buildroot.
  # This is done globally for all metadata found in the buildroot.
  find "${buildroot}" -name INSTALLER -exec sh -c 'printf "rpm\n" > "$1"' _ {} \;

  local bindir="${buildroot}/usr/bin"
  [[ ! -d "${bindir}" ]] && return 0

  pushd "${bindir}" &> /dev/null || return 0
  local sed_expr=""
  local f
  local major_ver="${py_ver%%.*}"

  # PHASE 1: Purge only IDENTIFIED redundant upstream aliases.
  # We only delete versioned binaries if their base counterpart exists (e.g. purge pip3 if pip exists).
  for f in *; do
    [[ ! -f "$f" ]] && continue
    local base=""
    if [[ "$f" == *"${py_ver}" ]]; then
      base="${f%"${py_ver}"}"
    elif [[ "$f" == *"${major_ver}" ]]; then
      base="${f%"${major_ver}"}"
    fi

    # If base is non-empty and exists as a separate file, f is a redundant alias.
    if [[ -n "${base}" && -f "${base}" ]]; then
      rm -f "$f"
      sed_expr="${sed_expr}/bin\/${f},/d; "
    fi
  done

  # PHASE 2: Standardize the remaining base binaries.
  for f in *; do
    [[ ! -f "$f" ]] && continue
    # Skip if we already versioned it (or if it was a protected versioned tool)
    [[ "$f" == *"-${py_ver}" || "$f" == *"${py_ver}" ]] && continue

    # 1. Physical Rename: version the tool (e.g. wheel -> wheel-3.13)
    mv -f "$f" "${f}-${py_ver}"
    # 2. Compatibility Link: create direct version link (e.g. wheel3.13)
    ln -sf "${f}-${py_ver}" "${f}${py_ver}"

    # 3. Metadata Synchronization:
    sed_expr="${sed_expr}s|bin/${f},|bin/${f}-${py_ver},|g; "
  done

  # Batch update all metadata records found in the buildroot
  if [[ -n "${sed_expr}" ]]; then
    find "${buildroot}" -name RECORD -exec sed -i "${sed_expr}" {} +
  fi

  # 4. Global Link Management:
  # Only executed for the designated "Global Default" Python version.
  if [[ -n "${pypi_name}" && "${is_default}" == "1" ]]; then
    if [[ -L "${pypi_name}-${py_ver}" || -f "${pypi_name}-${py_ver}" ]]; then
      ln -sf "${pypi_name}-${py_ver}" "${pypi_name}-3"
      ln -sf "${pypi_name}${py_ver}" "${pypi_name}3"
      ln -sf "${pypi_name}3" "${pypi_name}"
    fi
  fi
  popd &> /dev/null || return 0
}
