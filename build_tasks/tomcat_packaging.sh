#!/bin/bash
# ==============================================================================
# Tomcat Packaging Script (Safe and Array-Looping Version)
# Version: 1.1.0
# Date: 2026-06-23
#
# OBJECTIVES:
# Reconstructs a customized target Apache Tomcat layout starting from the 
# original upstream distribution, applying customizations extracted from a 
# custom reference Tomcat archive, and packaging the final structure.
#
# CORE COMPONENTS & FUNCTIONALITY:
# 1. Option Parsing: Parses options like --purge to clean up build resources.
# 2. Archive & Version Detection: Scans SOURCES/ to locate source tarballs, 
#    checks for exactly one original and custom archive, and extracts their versions.
# 3. Extraction & Initialization: Extracts original and custom tarballs under BUILD/,
#    and initializes target buildroot by copying original files.
# 4. Preparation Work: Removes unwanted batch files and default webapps, and renames
#    original files to '.dist' to prepare for patching.
# 5. Patching Customizations: Evaluates differences between the customized reference
#    files and their corresponding '.dist' baselines, generates patches, applies 
#    them to target files, and restores exact permissions.
# 6. Direct Copies: Directly transfers template scripts and assets not requiring patches.
# 7. Library Version Resolution: Matches and resolves lib/ext JARs, automatically
#    upgrading to newer versions found in SOURCES/ (e.g. MariaDB JDBC).
# 8. Archive Packaging: Packages the resulting layout into an xz-compressed archive 
#    in RPMS/x86_64/ with the correct root directory folder.
# 9. Clean Up: Deletes BUILD/ and BUILDROOT/ staging folders if --purge is specified.
# ==============================================================================

set -euo pipefail

# ==============================================================================
# BASE DIRECTORY PATHS
# BASE_DIR: The root workspace path for the RPM structure (/usr/src/redhat).
# SOURCES_DIR: Staging folder containing tarballs and JDBC driver updates.
# BUILD_DIR: Folder used for extracting source archives.
# BUILDROOT_DIR: Folder used for building the customized target directory.
# ==============================================================================
BASE_DIR="/usr/src/redhat"
SOURCES_DIR="${BASE_DIR}/SOURCES"
BUILD_DIR="${BASE_DIR}/BUILD"
BUILDROOT_DIR="${BASE_DIR}/BUILDROOT"

# ==============================================================================
# Packaging Configuration Arrays
# ==============================================================================

# Files under the bin/ directory to backup as .dist prior to patching (Step 4)
# Represents original scripts that will be customized via diff patches.
bin_files=(
  "bin/shutdown.sh"
  "bin/startup.sh"
)

# Configuration files under the conf/ directory to backup as .dist prior to patching (Step 4)
# Represents XML and properties configuration templates that will be customized.
conf_files=(
  "conf/catalina.properties"
  "conf/context.xml"
  "conf/server.xml"
  "conf/tomcat-users.xml"
  "conf/web.xml"
)

# Configuration files in manager/host-manager webapps to backup as .dist prior to patching (Step 4)
# Represents component-specific deployment descriptors and configurations.
webapp_files=(
  "webapps/manager/META-INF/context.xml"
  "webapps/manager/WEB-INF/web.xml"
  "webapps/host-manager/META-INF/context.xml"
  "webapps/host-manager/WEB-INF/web.xml"
)

# Standard customizations applied by patching the target file using a diff between 
# the reference customized file and its corresponding .dist baseline backup (Step 6)
# Represents target files that keep their original extension after customizations.
standard_customizations=(
  "bin/shutdown.sh"
  "bin/startup.sh"
  "conf/catalina.properties"
  "conf/web.xml"
  "webapps/manager/META-INF/context.xml"
  "webapps/manager/WEB-INF/web.xml"
  "webapps/host-manager/META-INF/context.xml"
  "webapps/host-manager/WEB-INF/web.xml"
  "webapps/ROOT/tools/index.jsp"
)

# Template customizations where the target patched filename uses the '.tmpl' extension
# instead of replacing the original file directly (Step 6)
# Used specifically for conf/ context, server, and tomcat-users templates.
tmpl_customizations=(
  "conf/context.xml"
  "conf/server.xml"
  "conf/tomcat-users.xml"
)

# Mappings of custom reference assets to copy directly into the target buildroot (Step 7)
# Format is "source_relative_path:destination_relative_path".
# These files do not exist as '.dist' baselines and are copied without diff patching.
direct_copies=(
  "bin/setenv.sh.tmpl:bin/"
  "scripts:/"
  "webapps/ROOT/favicon.ico:webapps/ROOT/"
  "webapps/ROOT/tools/health.jsp:webapps/ROOT/tools/"
  "webapps/ROOT/tools/index.html.blank:webapps/ROOT/tools/"
  "webapps/ROOT/tools/index.html.redirect:webapps/ROOT/tools/"
)

# ==============================================================================
# SAFETY HELPER FUNCTIONS
# ==============================================================================

# Safety helper: Copy preserving metadata, failing if source doesn't exist
# Validates path existence before running cp -a to prevent silent copy failures.
safe_cp() {
  local src="$1"
  local dest="$2"
  if [ -e "$src" ]; then
    cp -a "$src" "$dest"
  else
    echo "ERROR: Copy source not found: $src"
    exit 1
  fi
}

# Safety helper: Move/Rename, failing if source doesn't exist
# Validates path existence before running mv -f to prevent silent rename failures.
safe_mv() {
  local src="$1"
  local dest="$2"
  if [ -e "$src" ]; then
    mv -f "$src" "$dest"
  else
    echo "ERROR: Rename source not found: $src"
    exit 1
  fi
}

# Safety helper: Remove files/directories recursively only if they reside within BASE_DIR
# Prevents accidental deletion of system directories (/ or parent traversal /..)
# by validating that paths are non-empty and reside strictly under BASE_DIR.
safe_rm_rf() {
  if [ -z "${BASE_DIR:-}" ]; then
    echo "ERROR: BASE_DIR is not set before calling safe_rm_rf"
    exit 1
  fi
  for path in "$@"; do
    if [ -z "$path" ]; then
      echo "ERROR: Attempted to delete an empty path"
      exit 1
    fi
    # Check for root directory and parent directory traversal attempts
    if [ "$path" = "/" ] || [ "$path" = "/*" ] || [[ "$path" == *".."* ]]; then
      echo "ERROR: Dangerous path in safe_rm_rf: $path"
      exit 1
    fi
    # Ensure it starts with BASE_DIR to prevent deletions outside the workspace
    if [[ "$path" != "$BASE_DIR"* ]]; then
      echo "ERROR: Path '$path' is outside BASE_DIR '$BASE_DIR'"
      exit 1
    fi
    rm -rf "$path"
  done
}

# ==============================================================================
# CLI OPTION PARSING
# Parses options like --purge to determine if cleanup should be executed on completion.
# Remaining arguments are collected in the ARGS array.
# ==============================================================================
PURGE_ON_SUCCESS=false
ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --purge)
      PURGE_ON_SUCCESS=true
      shift
      ;;
    -*)
      echo "ERROR: Unknown option: $1"
      exit 1
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

# ==============================================================================
# ARCHIVE PATH RESOLUTION & DYNAMIC VERSION EXTRACTION
# Automatically detects source files in SOURCES/ if not explicitly overridden via ARGS.
# Enforces that exactly one archive matches each pattern to prevent ambiguity.
# ==============================================================================

# Locate original archive (allow argument override, else auto-detect)
if [ -n "${ARGS[0]:-}" ]; then
  ORIG_TAR="${ARGS[0]}"
else
  shopt -s nullglob
  orig_tars=("${SOURCES_DIR}"/apache-tomcat-*.tar.gz)
  shopt -u nullglob
  
  if [ ${#orig_tars[@]} -eq 0 ]; then
    echo "ERROR: No apache-tomcat-*.tar.gz found in ${SOURCES_DIR}"
    exit 1
  fi
  if [ ${#orig_tars[@]} -gt 1 ]; then
    echo "ERROR: Expected exactly one apache-tomcat-*.tar.gz in ${SOURCES_DIR}, but found ${#orig_tars[@]}: ${orig_tars[*]}"
    exit 1
  fi
  ORIG_TAR="${orig_tars[0]}"
fi

# Locate custom reference archive (allow argument override, else auto-detect)
if [ -n "${ARGS[1]:-}" ]; then
  CUSTOM_TAR="${ARGS[1]}"
else
  shopt -s nullglob
  custom_tars=("${SOURCES_DIR}"/apache-tomcat-*-custom.tar.xz)
  shopt -u nullglob
  
  if [ ${#custom_tars[@]} -eq 0 ]; then
    echo "ERROR: No apache-tomcat-*-custom.tar.xz found in ${SOURCES_DIR}"
    exit 1
  fi
  if [ ${#custom_tars[@]} -gt 1 ]; then
    echo "ERROR: Expected exactly one apache-tomcat-*-custom.tar.xz in ${SOURCES_DIR}, but found ${#custom_tars[@]}: ${custom_tars[*]}"
    exit 1
  fi
  CUSTOM_TAR="${custom_tars[0]}"
fi

# Validate archive files exist
if [ ! -f "$ORIG_TAR" ]; then
  echo "ERROR: Original Tomcat archive file not found: $ORIG_TAR"
  exit 1
fi
if [ ! -f "$CUSTOM_TAR" ]; then
  echo "ERROR: Custom Tomcat archive file not found: $CUSTOM_TAR"
  exit 1
fi

# Extract and validate version names from files (regex-matched version tokens)
ORIG_FILENAME=$(basename "$ORIG_TAR")
ORIG_VER=$(echo "$ORIG_FILENAME" | sed -E 's/^apache-tomcat-(.*)\.tar\.gz$/\1/')
if [ "$ORIG_VER" = "$ORIG_FILENAME" ] || [ -z "$ORIG_VER" ]; then
  echo "ERROR: Original archive filename does not match expected pattern (apache-tomcat-*.tar.gz): $ORIG_FILENAME"
  exit 1
fi

CUSTOM_FILENAME=$(basename "$CUSTOM_TAR")
CUSTOM_VER=$(echo "$CUSTOM_FILENAME" | sed -E 's/^apache-tomcat-(.*)-custom\.tar\.xz$/\1/')
if [ "$CUSTOM_VER" = "$CUSTOM_FILENAME" ] || [ -z "$CUSTOM_VER" ]; then
  echo "ERROR: Custom archive filename does not match expected pattern (apache-tomcat-*-custom.tar.xz): $CUSTOM_FILENAME"
  exit 1
fi

# ==============================================================================
# SETUP STAGING PATHS
# ==============================================================================
# Extraction and target directory paths
EXTRACT_ORIG="${BUILD_DIR}/apache-tomcat-${ORIG_VER}"
EXTRACT_CUSTOM="${BUILD_DIR}/apache-tomcat-${CUSTOM_VER}-custom"
TARGET_DIR="${ARGS[2]:-$BUILDROOT_DIR/apache-tomcat-${ORIG_VER}-custom}"

echo "=========================================================================="
echo "=== Tomcat Packaging Script Started ==="
echo "=========================================================================="
echo "Original Archive:         $ORIG_TAR (version: $ORIG_VER)"
echo "Custom Archive:           $CUSTOM_TAR (version: $CUSTOM_VER)"
echo "Original Extraction:      $EXTRACT_ORIG"
echo "Custom Reference:         $EXTRACT_CUSTOM"
echo "Target Buildroot:         $TARGET_DIR"
echo ""

# Clean up existing directories to ensure a clean build
safe_rm_rf "$EXTRACT_ORIG" "$EXTRACT_CUSTOM" "$TARGET_DIR"
mkdir -p "$EXTRACT_ORIG" "$EXTRACT_CUSTOM" "$TARGET_DIR"

# ==============================================================================
# STEP 1 & 2: EXTRACT SOURCE ARCHIVES
# Extracts upstream tarball and customized reference archives to BUILD/ directory.
# ==============================================================================

# 1. Extract original Tomcat to BUILD/apache-tomcat-${ORIG_VER}
echo "[1/8] Extracting Source Archives..."
echo "Extracting original Tomcat..."
tar -xzf "$ORIG_TAR" -C "$EXTRACT_ORIG" --strip-components=1

# 2. Extract custom Tomcat to BUILD/apache-tomcat-${CUSTOM_VER}-custom
echo "Extracting custom reference Tomcat..."
tar -xJf "$CUSTOM_TAR" -C "$EXTRACT_CUSTOM" --strip-components=1
echo ""

# ==============================================================================
# STEP 3 & 4: INITIALIZE BUILDROOT & PREP WORK
# Copies original Tomcat directory into target buildroot preserving timestamps,
# removes batch files, docs/examples webapps, and backs up original configs as '.dist'.
# ==============================================================================

# 3. Initialize target buildroot by copying original files
echo "[2/8] Initializing Buildroot & Performing Prep Work..."
echo "Initializing target buildroot..."
cp -a "$EXTRACT_ORIG"/. "$TARGET_DIR"/

# 4. Perform original prep work in target buildroot
echo "Performing preparation work on buildroot Tomcat..."
# Remove batch files and unwanted webapps
safe_rm_rf "$TARGET_DIR"/bin/*.bat
safe_rm_rf "$TARGET_DIR"/webapps/docs
safe_rm_rf "$TARGET_DIR"/webapps/examples

# Rename files in bin
for f in "${bin_files[@]}"; do
  safe_mv "$TARGET_DIR/$f" "$TARGET_DIR/${f}.dist"
done

# Rename files in conf
for f in "${conf_files[@]}"; do
  safe_mv "$TARGET_DIR/$f" "$TARGET_DIR/${f}.dist"
done

# Rename files in webapps
for f in "${webapp_files[@]}"; do
  safe_mv "$TARGET_DIR/$f" "$TARGET_DIR/${f}.dist"
done
echo ""

# ==============================================================================
# STEP 5: RESTRUCTURE ROOT WEBAPP
# Moves ROOT contents into tools/ subfolder, explicitly excluding 'tools' itself 
# and the servlet metadata 'WEB-INF' folder to avoid breaking configurations.
# Backs up baseline index.jsp and favicon.ico files.
# ==============================================================================

# 5. Restructure ROOT webapp
echo "[3/8] Restructuring ROOT Webapp..."
echo "Restructuring ROOT webapp..."
mkdir -p "$TARGET_DIR/webapps/ROOT/tools"
# Move files directly under webapps/ROOT/ (excluding tools and WEB-INF directories themselves) to tools/
find "$TARGET_DIR/webapps/ROOT" -maxdepth 1 -mindepth 1 -not -name "tools" -not -name "WEB-INF" -exec mv -t "$TARGET_DIR/webapps/ROOT/tools" {} +
# Create baseline .dist files for files that will be customized
safe_cp "$TARGET_DIR/webapps/ROOT/tools/index.jsp" "$TARGET_DIR/webapps/ROOT/tools/index.jsp.dist"
safe_mv "$TARGET_DIR/webapps/ROOT/tools/favicon.ico" "$TARGET_DIR/webapps/ROOT/tools/favicon.ico.dist"
echo ""

# ==============================================================================
# CUSTOMIZATION PATCHING HELPERS
# ==============================================================================

# Helper function to generate and apply unified diffs
# Generates a unified diff between custom.dist and custom reference files,
# applies this diff to original.dist to create target file (preserving upstream updates),
# and copies the exact file permissions of the customized reference file.
apply_patch() {
  local custom_dist="$1"
  local custom_val="$2"
  local orig_dist="$3"
  local target_val="$4"

  echo "Applying custom diff from $(basename "$custom_dist") -> $(basename "$custom_val") to $(basename "$orig_dist")"

  # Generate unified diff
  local patch_file
  patch_file=$(mktemp)
  diff -u "$custom_dist" "$custom_val" > "$patch_file" || true

  # Apply patch
  if ! patch "$orig_dist" -i "$patch_file" -o "$target_val"; then
    echo "ERROR: Failed to apply patch to $orig_dist. Patch contents:"
    cat "$patch_file"
    rm -f "$patch_file"
    exit 1
  fi
  rm -f "$patch_file"

  # Copy permissions from custom reference file
  chmod --reference="$custom_val" "$target_val"
}

# Helper function to decide whether to patch (if custom dist file exists) or copy directly
# If a baseline .dist file exists in the custom reference archive, it generates/applies a patch.
# Otherwise, it treats it as a direct copy asset and handles it using safe_cp.
apply_customization() {
  local custom_dist="$1"
  local custom_val="$2"
  local orig_dist="$3"
  local target_val="$4"

  # Source customization reference file must exist
  if [ ! -f "$custom_val" ]; then
    echo "ERROR: Customized reference file not found: $custom_val"
    exit 1
  fi

  if [ -f "$custom_dist" ]; then
    # original backup file to be patched must exist
    if [ ! -f "$orig_dist" ]; then
      echo "ERROR: Original backup file for patching not found: $orig_dist"
      exit 1
    fi
    apply_patch "$custom_dist" "$custom_val" "$orig_dist" "$target_val"
  else
    echo "No dist file found for $(basename "$custom_val"), copying directly..."
    safe_cp "$custom_val" "$target_val"
  fi
}

# ==============================================================================
# STEP 6 & 7: APPLY CUSTOMIZATIONS & DIRECT COPIES
# Loops through configuration arrays to perform patch application, 
# and processes direct copy mappings for unpatched templates, scripts, and assets.
# ==============================================================================

# 6. Reapply customizations in buildroot using array loops
echo "[4/8] Applying Custom Configuration Patches..."
echo "Applying custom configurations..."

for path in "${standard_customizations[@]}"; do
  apply_customization "$EXTRACT_CUSTOM/${path}.dist" "$EXTRACT_CUSTOM/${path}" \
                      "$TARGET_DIR/${path}.dist" "$TARGET_DIR/${path}"
done

for base_path in "${tmpl_customizations[@]}"; do
  apply_customization "$EXTRACT_CUSTOM/${base_path}.dist" "$EXTRACT_CUSTOM/${base_path}.tmpl" \
                      "$TARGET_DIR/${base_path}.dist" "$TARGET_DIR/${base_path}.tmpl"
done
echo ""

# 7. Copy new template/script files and assets directly
echo "[5/8] Copying Direct Templates & Assets..."
echo "Copying custom files and scripts directly..."

for item in "${direct_copies[@]}"; do
  src="${item%%:*}"
  dest="${item##*:}"
  safe_cp "$EXTRACT_CUSTOM/$src" "$TARGET_DIR/$dest"
done
echo ""

# ==============================================================================
# STEP 9: RESOLVE & SET UP EXTERNAL LIBRARIES (lib/ext/)
# Populates lib/ext/ target folder. Scans the custom reference libraries,
# resolves their prefix names, checks if a matching library exists in SOURCES/,
# compares versions using sort -V, and automatically upgrades if a newer
# JAR is found (preferring SOURCES/ versions, like Mariadb-java-client).
# ==============================================================================

# 9. Set up lib/ext/ and resolve library versions
echo "[6/8] Resolving & Setting Up External Libraries (lib/ext)..."
echo "Setting up lib/ext database drivers..."
mkdir -p "$TARGET_DIR/lib/ext"

# Ensure reference lib/ext folder exists in custom reference
if [ -d "$EXTRACT_CUSTOM/lib/ext" ]; then
  for custom_jar in "$EXTRACT_CUSTOM"/lib/ext/*.jar; do
    # Handle the case where no jars match the glob pattern
    [ -e "$custom_jar" ] || continue
    
    jar_filename=$(basename "$custom_jar")
    # Strip version suffix to get prefix (e.g., mariadb-java-client)
    prefix=$(echo "$jar_filename" | sed -E 's/-[0-9].*//')

    echo "  Resolving version for $jar_filename (library: $prefix)"
    # Check if a jar with the same prefix exists in SOURCES
    sources_match=$(find "$SOURCES_DIR" -maxdepth 1 -name "${prefix}-*.jar" | head -n 1)

    if [ -n "$sources_match" ]; then
      sources_jar_filename=$(basename "$sources_match")
      echo "    Found matching jar in SOURCES: $sources_jar_filename"

      custom_ver=$(echo "$jar_filename" | sed -E "s/^${prefix}-//" | sed 's/\.jar$//')
      sources_ver=$(echo "$sources_jar_filename" | sed -E "s/^${prefix}-//" | sed 's/\.jar$//')

      # Compare versions using sort -V
      newer_ver=$(printf '%s\n%s\n' "$custom_ver" "$sources_ver" | sort -V | tail -n 1)

      if [ "$newer_ver" = "$sources_ver" ] && [ "$custom_ver" != "$sources_ver" ]; then
        echo "    --> UPGRADING to version in SOURCES: $sources_jar_filename"
        safe_cp "$sources_match" "$TARGET_DIR/lib/ext/"
      else
        echo "    --> KEEPING version from custom archive: $jar_filename"
        safe_cp "$custom_jar" "$TARGET_DIR/lib/ext/"
      fi
    else
      echo "    --> COPYING from custom archive: $jar_filename"
      safe_cp "$custom_jar" "$TARGET_DIR/lib/ext/"
    fi
  done
else
  echo "WARNING: lib/ext directory not found in custom reference"
fi
echo ""

# 10. (Permissions are automatically preserved via cp -a and chmod --reference)

# ==============================================================================
# STEP 11: PACKAGE TARGET BUILDROOT & EXECUTE CLEAN UP
# Creates a temporary staging directory to package Tomcat with the correct root
# directory folder format (apache-tomcat-ORIG_VER). Generates the custom 
# tar.xz archive in RPMS/x86_64/ and purges extraction directories if --purge is set.
# ==============================================================================

# 11. Create correctly named xz archive in RPMS/x86_64/
echo "[7/8] Creating Final Target Archive..."
echo "Creating target archive in RPMS/x86_64/..."
mkdir -p "${BASE_DIR}/RPMS/x86_64"

# Set up a temp folder to control archive root path name
local_temp_parent="${BUILD_DIR}/temp_archive_$$"
local_temp_build="${local_temp_parent}/apache-tomcat-${ORIG_VER}"
safe_rm_rf "$local_temp_parent"
mkdir -p "$local_temp_parent"

# Copy target buildroot directly to the temp folder (renaming root folder name to apache-tomcat-ORIG_VER)
safe_cp "$TARGET_DIR" "$local_temp_build"

# Package using tar xz compression (tar -cJf)
tar -cJf "${BASE_DIR}/RPMS/x86_64/apache-tomcat-${ORIG_VER}-custom.tar.xz" -C "$local_temp_parent" "apache-tomcat-${ORIG_VER}"

# Clean up temp folder
safe_rm_rf "$local_temp_parent"
echo ""

echo "[8/8] Completing Packaging & Staging Status..."
echo "=========================================================================="
echo "=== Tomcat Packaging Complete ==="
echo "=========================================================================="
if [ "$PURGE_ON_SUCCESS" = true ]; then
  echo "Purging temporary build and buildroot folders..."
  safe_rm_rf "$EXTRACT_ORIG" "$EXTRACT_CUSTOM" "$TARGET_DIR"
  echo "Successfully cleaned up: $EXTRACT_ORIG, $EXTRACT_CUSTOM, and $TARGET_DIR"
else
  echo "Original extracted files kept in: $EXTRACT_ORIG"
  echo "Custom reference files kept in:   $EXTRACT_CUSTOM"
  echo "Buildroot customized Tomcat in:   $TARGET_DIR"
fi
echo "Target archive created in:        ${BASE_DIR}/RPMS/x86_64/apache-tomcat-${ORIG_VER}-custom.tar.xz"
