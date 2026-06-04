#!/bin/bash
# ==============================================================================
# Script Name: jdk_packaging.sh
#
# Objectives:
#   Repackage multiple Azul Zulu JDK distributions (for both Linux and Windows 
#   platforms) by stripping unneeded artifacts (demos, samples, source zips, 
#   unsupported localized manpages), compressing active manual pages, updating 
#   JVM security policies (removing limited policies, enforcing unlimited crypto, 
#   and strengthening PKCS#12 key protection), integrating a dynamic Maven 
#   installation stripped of OS-incompatible scripts/libs, and embedding 
#   the JTLSTester diagnostic utility.
#
# Core Components:
#   1. Directory Setup: Configures PKG_DIR, SOURCES, DISTRIB, and STAGING.
#   2. Maven Detection: Dynamically resolves Maven archives and version strings
#      from the SOURCES directory to avoid hardcoded Maven versions.
#   3. JTLSTester Extraction: Extracts prebuilt TLS diagnostics utility jars.
#   4. process_jdk(): Core parametric function to repackage a single JDK package.
#   5. Concurrency Manager: Parallelizes the repackaging jobs using background 
#      processes, limiting concurrent execution based on available CPU cores.
#
# Data Flows:
#   SOURCES/zulu*.{tar.gz,zip} + SOURCES/apache-maven-*.{tar.gz,zip}
#      |
#      v [Extract & Merge]
#   STAGING/work/build_zulu*
#      |
#      v [Apply Cleanups, JTLSTester & Symlinks]
#   Packaged Target Root (e.g., jdk-11u31-linux-x86_64)
#      |
#      v [Compress / Pack]
#   DISTRIB/openjdk*-zulu-*.{tar.xz,zip}
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# 1. Directory Path Definitions
# ------------------------------------------------------------------------------
# PKG_DIR acts as the base packaging workspace.
# SOURCES holds raw Zulu JDKs, Maven archives, and the JTLSTester zip.
# DISTRIB is where completed target archives will be created.
# STAGING is the temporary scratch area for extraction and logging.
PKG_DIR="/usr/src/packages"
SOURCE_DIR="${PKG_DIR}/SOURCES"
TARGET_DIR="${PKG_DIR}/DISTRIB"
STAGING_DIR="${PKG_DIR}/STAGING"
WORK_DIR="${STAGING_DIR}/work"
JTLSTESTER_EXTRACT_DIR="${STAGING_DIR}/jtlstester_jars"
LOGS_DIR="${STAGING_DIR}/logs"

echo "=== Initializing Directories ==="
# Ensure directories exist and clear any old build artifacts in the work dir.
mkdir -p "${TARGET_DIR}"
mkdir -p "${STAGING_DIR}"
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"


# ------------------------------------------------------------------------------
# 2. Dynamic Maven Detection
# ------------------------------------------------------------------------------
# Instead of hardcoding Maven version numbers, this block scans the SOURCES
# directory for both Linux (.tar.gz) and Windows (.zip) distributions.
# It extracts the version string from the filename to name symlinks and markers
# dynamically during compilation.
echo -e "\n=== Detecting Maven Version ==="
MAVEN_LINUX_ARCHIVE=""
MAVEN_WIN_ARCHIVE=""
MAVEN_VERSION=""

# Locate the first Maven Linux tarball and extract its version (e.g. 3.9.16)
if MAVEN_LINUX_PATH=$(find "${SOURCE_DIR}" -maxdepth 1 -name "apache-maven-*-bin.tar.gz" | head -n 1) && [ -n "${MAVEN_LINUX_PATH}" ]; then
  MAVEN_LINUX_ARCHIVE=$(basename "${MAVEN_LINUX_PATH}")
  # Uses PCRE regex to capture version string immediately following 'apache-maven-'
  MAVEN_VERSION=$(echo "${MAVEN_LINUX_ARCHIVE}" | grep -oP 'apache-maven-\K[0-9]+\.[0-9]+\.[0-9]+')
else
  echo "ERROR: Could not find apache-maven-*-bin.tar.gz in ${SOURCE_DIR}"
  exit 1
fi

# Locate the first Maven Windows zip file
if MAVEN_WIN_PATH=$(find "${SOURCE_DIR}" -maxdepth 1 -name "apache-maven-*-bin.zip" | head -n 1) && [ -n "${MAVEN_WIN_PATH}" ]; then
  MAVEN_WIN_ARCHIVE=$(basename "${MAVEN_WIN_PATH}")
else
  echo "ERROR: Could not find apache-maven-*-bin.zip in ${SOURCE_DIR}"
  exit 1
fi

echo "Detected Maven (Version: ${MAVEN_VERSION})"
echo "  + Linux Archive: ${MAVEN_LINUX_ARCHIVE}"
echo "  + Windows Archive: ${MAVEN_WIN_ARCHIVE}"


# ------------------------------------------------------------------------------
# 3. JTLSTester Diagnostic Tools Extraction
# ------------------------------------------------------------------------------
# Unzips the JTLSTester utility package into a staging subdirectory.
# This extracts 'jtlstester8.jar' and 'jtlstester11.jar', which will later be
# copied and renamed to 'tools/jtlstester.jar' inside target JDKs.
echo -e "\n=== Extracting JTLSTester jars ==="
rm -rf "${JTLSTESTER_EXTRACT_DIR}"
mkdir -p "${JTLSTESTER_EXTRACT_DIR}"
JTLSTESTER_ZIP=$(find "${SOURCE_DIR}" -maxdepth 1 -name "jtlstester-*-java.zip" | head -n 1)
if [ -n "${JTLSTESTER_ZIP}" ]; then
  JTLSTESTER_VERSION=$(echo "$(basename "${JTLSTESTER_ZIP}")" | grep -oP 'jtlstester-\K[0-9]+\.[0-9]+\.[0-9]+-[a-f0-9]+')
  unzip -q -d "${JTLSTESTER_EXTRACT_DIR}" "${JTLSTESTER_ZIP}"
  echo "JTLSTester jars extracted successfully (Version: ${JTLSTESTER_VERSION})."
else
  echo "ERROR: jtlstester zip file not found in ${SOURCE_DIR}"
  exit 1
fi


# ------------------------------------------------------------------------------
# 4. Core Repackaging Function
# ------------------------------------------------------------------------------
# process_jdk extracts a single JDK archive, organizes its structure to match
# target requirements, applies cleanups, overlays Maven and JTLSTester,
# and bundles the final package.
#
# Arguments:
#   $1 - Name of the source JDK archive (e.g. zulu11.88.17-ca-jdk11.0.31-linux_x64.tar.gz)
#   $2 - Target OS Platform ("linux" or "windows")
process_jdk() {
  local jdk_archive="$1"
  local os="$2" # "linux" or "windows"

  echo "----------------------------------------"
  echo "Processing: ${jdk_archive} (${os})"

  # Extract the basename of the archive for staging folder naming
  local jdk_base
  jdk_base=$(basename "${jdk_archive}")

  # Parse version details from filename
  # Example: zulu11.88.17-ca-jdk11.0.31-linux_x64.tar.gz -> 11.0.31
  # Example: zulu8.94.0.17-ca-jdk8.0.492-win_x64.zip -> 8.0.492
  local version_str
  version_str=$(echo "${jdk_base}" | grep -oP 'jdk\K[0-9]+\.[0-9]+\.[0-9]+')

  # Parse major, minor, patch (using dots as delimiters)
  local major patch
  major=$(echo "${version_str}" | cut -d. -f1)
  patch=$(echo "${version_str}" | cut -d. -f3)

  # Build target short-version string (e.g. 11u31, 8u492, 25u3)
  # Strips patch leading zeros naturally (e.g. 25.0.3 -> 25u3)
  local short_ver="${major}u${patch}"

  # Inner directory naming convention (e.g. jdk110, jdk80)
  local inner_jdk_dir="jdk${major}0"

  # Create a clean temporary directory for this specific package build
  local build_temp="${WORK_DIR}/build_${jdk_base}"
  rm -rf "${build_temp}"
  mkdir -p "${build_temp}"

  # Extract JDK
  echo "Extracting JDK archive..."
  local extracted_jdk_root
  if [ "${os}" = "linux" ]; then
    # Extract Linux tarballs
    tar -C "${build_temp}" -xf "${SOURCE_DIR}/${jdk_archive}"
    # Find the top directory name inside extracted archive (usually starts with zulu)
    extracted_jdk_root=$(find "${build_temp}" -maxdepth 1 -type d -name "zulu*" | head -n 1)
  else
    # Extract Windows zip archives
    unzip -q -d "${build_temp}" "${SOURCE_DIR}/${jdk_archive}"
    extracted_jdk_root=$(find "${build_temp}" -maxdepth 1 -type d -name "zulu*" | head -n 1)
  fi

  # Define target root folder name based on platform
  local target_root_name
  if [ "${os}" = "linux" ]; then
    target_root_name="jdk-${short_ver}-linux-x86_64"
  else
    target_root_name="jdk-${short_ver}-windows-x64"
  fi

  # Create the target root folder layout
  local target_root="${build_temp}/${target_root_name}"
  mkdir -p "${target_root}"

  # Move extracted JDK contents to the target inner folder (e.g., jdk110/)
  local target_jdk_path="${target_root}/${inner_jdk_dir}"
  mv "${extracted_jdk_root}" "${target_jdk_path}"

  # Create a 0-byte JDK source marker file to log the original Zulu filename
  local original_folder_name
  original_folder_name=$(basename "${extracted_jdk_root}")
  touch "${target_jdk_path}/${original_folder_name}"

  # Clean up inner JDK artifacts (CleanAll rule)
  # Removes:
  #   - demo/ and sample/ folders (repacks should contain binaries only).
  #   - man/ja* (removes localized Japanese manual pages to save space).
  # Compresses remaining manual pages in man/man1 using maximum gzip compression.
  echo "Cleaning up inner JDK artifacts (CleanAll)..."
  (
    cd "${target_jdk_path}"
    rm -rf demo man/ja* sample
    if [ -d man/man1 ]; then
      gzip -f -9 man/man1/*.1 2> /dev/null || true
    fi
  )

  # Version-specific JDK cleanups
  # - JDK 8: Removes src.zip and limited policies under 'jre/'. Backs up and modifies
  #   'java.security' to enable unlimited crypto policy and reinforce PKCS#12 key protection.
  # - JDK 11+: Removes limited policies under 'conf/' and drops 'lib/src.zip'.
  if [ "${major}" -eq 8 ]; then
    echo "Applying JDK8 cleanups..."
    rm -rf "${target_jdk_path}/src.zip"
    rm -rf "${target_jdk_path}/jre/lib/security/policy/limited"

    # Modify java.security configuration
    local sec_conf="${target_jdk_path}/jre/lib/security/java.security"
    if [ -f "${sec_conf}" ]; then
      cp -af "${sec_conf}" "${target_jdk_path}/jre/lib/security/java.security.dist"
      # Uncomment the crypto.policy property to activate unlimited cryptographic strength
      sed -i "/#crypto.policy=unlimited/s|^#||" "${sec_conf}"
      # Append stronger PKCS#12 configuration to the file
      cat << EOF >> "${sec_conf}"

# Stronger algorithm for PKCS#12 and the SUN Provider
keystore.pkcs12.keyProtectionAlgorithm=PBEWithHmacSHA256AndAES_256
EOF
    fi
  else
    echo "Applying JDK11+ cleanups..."
    rm -rf "${target_jdk_path}/conf/security/policy/limited"
    rm -rf "${target_jdk_path}/lib/src.zip" "${target_jdk_path}/lib/src"*
  fi

  # Extract & modify Maven
  # Merges Maven into the JDK target and removes platform-incompatible parts.
  echo "Extracting and merging Maven..."
  local maven_temp="${build_temp}/maven_extract"
  mkdir -p "${maven_temp}"

  if [ "${os}" = "linux" ]; then
    tar -C "${maven_temp}" -xf "${SOURCE_DIR}/${MAVEN_LINUX_ARCHIVE}"

    local maven_extracted_dir
    maven_extracted_dir=$(find "${maven_temp}" -maxdepth 1 -type d -name "apache-maven-*" | head -n 1)

    # Move Maven directory to target structure
    mv "${maven_extracted_dir}" "${target_root}/maven"

    # Strip Windows executable cmd/bat scripts from bin
    rm -f "${target_root}/maven/bin/"*.cmd

    # Remove Windows native libraries (only needed for Windows builds)
    rm -rf "${target_root}/maven/lib/jansi-native/Windows"

    # Create symlink using dynamic version
    ln -sf maven "${target_root}/maven-${MAVEN_VERSION}"
  else
    unzip -q -d "${maven_temp}" "${SOURCE_DIR}/${MAVEN_WIN_ARCHIVE}"

    local maven_extracted_dir
    maven_extracted_dir=$(find "${maven_temp}" -maxdepth 1 -type d -name "apache-maven-*" | head -n 1)

    # Move Maven directory to target structure
    mv "${maven_extracted_dir}" "${target_root}/maven"

    # Strip Unix files (bash scripts)
    rm -f "${target_root}/maven/bin/mvn" "${target_root}/maven/bin/mvnDebug" "${target_root}/maven/bin/mvnyjp"

    # Keep only Windows x86_64 in jansi-native (remove arm64, x86 directories)
    local jansi_win_dir="${target_root}/maven/lib/jansi-native/Windows"
    if [ -d "${jansi_win_dir}" ]; then
      find "${jansi_win_dir}" -mindepth 1 -maxdepth 1 ! -name "x86_64" -exec rm -rf {} +
    fi

    # Create empty marker file using dynamic version
    touch "${target_root}/apache-maven-${MAVEN_VERSION}-bin"
  fi

  # Apply system directory
  # Creates the empty system/var structure required by target layouts
  mkdir -p "${target_root}/system/var"

  # Apply tools directory and copy correct JTLSTester jar
  # Map JDK 8 to jtlstester8.jar, and JDK 11+ to jtlstester11.jar
  mkdir -p "${target_root}/tools"
  if [ "${major}" -eq 8 ]; then
    cp "${JTLSTESTER_EXTRACT_DIR}/jtlstester8.jar" "${target_root}/tools/jtlstester.jar"
  else
    cp "${JTLSTESTER_EXTRACT_DIR}/jtlstester11.jar" "${target_root}/tools/jtlstester.jar"
  fi

  # Apply OS-specific link/marker details
  if [ "${os}" = "linux" ]; then
    # Create version symlink in root folder (e.g. jdk-11.0.31 -> jdk110)
    ln -sf "${inner_jdk_dir}" "${target_root}/jdk-${version_str}"
  else
    # Create 0-byte bin marker file in root folder (e.g. jdk-11.0.31.bin)
    touch "${target_root}/jdk-${version_str}.bin"
  fi

  # Build target archive
  # Packages Linux targets as tar.xz and Windows targets as zip.
  echo "Building final target package..."
  local target_file
  if [ "${os}" = "linux" ]; then
    target_file="openjdk${major}u-${version_str}-zulu-x86_64.tar.xz"
    tar -C "${build_temp}" -cJf "${TARGET_DIR}/${target_file}" "${target_root_name}"
  else
    target_file="openjdk${major}u-${version_str}-zulu-windows-x64.zip"
    # Runs zip inside build_temp directory to avoid prepending absolute path strings
    (cd "${build_temp}" && zip -q -r "${TARGET_DIR}/${target_file}" "${target_root_name}")
  fi

  echo "Target generated successfully: ${target_file}"

  # Cleanup temp workspace files for this package build to save disk space
  rm -rf "${build_temp}"
}


# ------------------------------------------------------------------------------
# 5. Parallel Execution and Concurrency Controller
# ------------------------------------------------------------------------------
# Loops through all Linux and Windows Zulu JDKs. Backgrounds each task and 
# redirects their output to individual files to prevent log interleaving. 
# Sequential logs are merged and printed at the end.
echo -e "\n=== Processing all packages dynamically in parallel ==="

# Dynamically determine and numerically sort unique major JDK versions present in SOURCES
# Example output list format: 8 11 17 21 25
MAJOR_VERSIONS=$(find "${SOURCE_DIR}" -maxdepth 1 -name "zulu*" | grep -oP 'jdk\K[0-9]+' | sort -un)
echo "Detected JDK Major Versions: $(echo ${MAJOR_VERSIONS} | tr '\n' ' ')"

MAX_JOBS=$(nproc)
echo "Max concurrent processes: ${MAX_JOBS}"

mkdir -p "${LOGS_DIR}"
pids=()
log_files=()
jdk_names=()

# Process all Linux JDKs dynamically (JDK 8 to 25, sorted numerically)
for major in ${MAJOR_VERSIONS}; do
  for f in "${SOURCE_DIR}"/zulu*-jdk${major}.*-linux_x64.tar.gz; do
    if [ -f "$f" ]; then
      echo "[START] Repackaging $(basename "$f") (linux)..."
      log_file="${LOGS_DIR}/$(basename "$f").log"
      # Launch job in background and redirect output to individual log file
      process_jdk "$(basename "$f")" "linux" > "${log_file}" 2>&1 &
      pids+=($!)
      log_files+=("${log_file}")
      jdk_names+=("$(basename "$f")")

      # Restrict concurrency to MAX_JOBS cores
      while [ "$(jobs -p | wc -l)" -ge "${MAX_JOBS}" ]; do
        sleep 0.5
      done
    fi
  done
done

# Process all Windows JDKs dynamically (JDK 8 to 25, sorted numerically)
for major in ${MAJOR_VERSIONS}; do
  for f in "${SOURCE_DIR}"/zulu*-jdk${major}.*-win_x64.zip; do
    if [ -f "$f" ]; then
      echo "[START] Repackaging $(basename "$f") (windows)..."
      log_file="${LOGS_DIR}/$(basename "$f").log"
      # Launch job in background and redirect output to individual log file
      process_jdk "$(basename "$f")" "windows" > "${log_file}" 2>&1 &
      pids+=($!)
      log_files+=("${log_file}")
      jdk_names+=("$(basename "$f")")

      # Restrict concurrency to MAX_JOBS cores
      while [ "$(jobs -p | wc -l)" -ge "${MAX_JOBS}" ]; do
        sleep 0.5
      done
    fi
  done
done

# Wait for all background jobs to complete, print logs sequentially, and check for failures
# Ensures logs are readable, and exits with code 1 if any build thread fails.
echo -e "Waiting for remaining packaging tasks to finish...\n"
failed=0
for i in "${!pids[@]}"; do
  pid="${pids[$i]}"
  log_file="${log_files[$i]}"
  jdk_name="${jdk_names[$i]}"

  if wait "$pid"; then
    echo "=== SUCCESS: ${jdk_name} ==="
  else
    echo "=== FAILURE: ${jdk_name} ==="
    failed=1
  fi
  cat "${log_file}"
  echo "----------------------------------------"
done

# Cleanup work area subfolders while keeping STAGING_DIR intact
rm -rf "${WORK_DIR}"
rm -rf "${JTLSTESTER_EXTRACT_DIR}"
rm -rf "${LOGS_DIR}"

if [ "${failed}" -ne 0 ]; then
  echo "ERROR: One or more packaging tasks failed!"
  exit 1
fi

echo "=== Repackaging completed successfully! ==="
