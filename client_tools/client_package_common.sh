#!/usr/bin/env bash
# ==============================================================================
# client_package_common.sh
#
# Shared foundation library for client software packaging and deployment utilities.
# Provides cross-platform path normalization, defensive filesystem controls,
# signal traps, workspace management, color logging, semantic versioning,
# transactional staging, archive manipulation, and asset download validation.
#
# Supported Environments:
#   - MSYS2 / Git Bash (Windows)
#   - Cygwin (Windows)
#   - Windows Subsystem for Linux (WSL)
#   - Native Linux (Ubuntu, Debian, RHEL, Fedora, Arch)
# ==============================================================================

# Prevent duplicate sourcing
[[ -n "${_CLIENT_PACKAGE_COMMON_SH_LOADED:-}" ]] && return 0
_CLIENT_PACKAGE_COMMON_SH_LOADED=1

# ------------------------------------------------------------------------------
# Section 1: Shell Settings & Platform Detection
# ------------------------------------------------------------------------------
detect_platform() {
    local uname_out
    uname_out="$(uname -s 2>/dev/null || echo "unknown")"
    case "${uname_out,,}" in
        msys*|mingw*|cygwin*|windows*)
            if [[ "${uname_out,,}" == cygwin* ]]; then
                echo "cygwin"
            else
                echo "msys2"
            fi
            ;;
        linux*)
            if grep -qi "microsoft" /proc/version 2>/dev/null; then
                echo "wsl"
            else
                echo "linux"
            fi
            ;;
        *)
            echo "linux"
            ;;
    esac
}

PLATFORM="$(detect_platform)"

# ------------------------------------------------------------------------------
# Section 2: Terminal Formatting & Colored Logging
# ------------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RESET="\033[0m"
    C_RED="\033[1;31m"
    C_GREEN="\033[1;32m"
    C_YELLOW="\033[1;33m"
    C_BLUE="\033[1;34m"
    C_CYAN="\033[1;36m"
    C_BOLD="\033[1m"
else
    C_RESET=""
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_BLUE=""
    C_CYAN=""
    C_BOLD=""
fi

log_info()    { echo -e "${C_CYAN}[INFO]${C_RESET} $*"; }
log_ok()      { echo -e "${C_GREEN}[OK]${C_RESET} $*"; }
log_warn()    { echo -e "${C_YELLOW}[WARN]${C_RESET} $*" >&2; }
log_error()   { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }
log_step()    { echo -e "${C_BLUE}==>${C_RESET} ${C_BOLD}$*${C_RESET}"; }

# ------------------------------------------------------------------------------
# Section 3: Dual-Layer Path Engine
# ------------------------------------------------------------------------------
# enforce_drive_path <path>
# Normalizes paths to canonical drive-letter format (e.g. "c:/path/dir") for
# consistent user logging, table rendering, and configuration storage.
enforce_drive_path() {
    local p="$1"
    [[ -z "$p" ]] && return 0

    p="${p//\\//}"

    # Cygruns / MSYS mount conversions
    if [[ "$p" =~ ^/cygdrive/([a-zA-Z])/(.*) ]]; then
        echo "${BASH_REMATCH[1],,}:/${BASH_REMATCH[2]}"
    elif [[ "$p" =~ ^/cygdrive/([a-zA-Z])$ ]]; then
        echo "${BASH_REMATCH[1],,}:/"
    elif [[ "$p" =~ ^/mnt/([a-zA-Z])/(.*) ]] && [[ "$PLATFORM" == "wsl" || -d "/mnt/${BASH_REMATCH[1]}" ]]; then
        echo "${BASH_REMATCH[1],,}:/${BASH_REMATCH[2]}"
    elif [[ "$p" =~ ^/mnt/([a-zA-Z])$ ]] && [[ "$PLATFORM" == "wsl" || -d "/mnt/${BASH_REMATCH[1]}" ]]; then
        echo "${BASH_REMATCH[1],,}:/"
    elif [[ "$p" =~ ^/([a-zA-Z])/(.*) ]] && [[ "$PLATFORM" == "msys2" ]]; then
        echo "${BASH_REMATCH[1],,}:/${BASH_REMATCH[2]}"
    elif [[ "$p" =~ ^/([a-zA-Z])$ ]] && [[ "$PLATFORM" == "msys2" ]]; then
        echo "${BASH_REMATCH[1],,}:/"
    elif [[ "$p" =~ ^([a-zA-Z]):[/\\]?(.*) ]]; then
        echo "${BASH_REMATCH[1],,}:/${BASH_REMATCH[2]}"
    else
        echo "$p"
    fi
}

# to_posix_path <path>
# Converts a Windows drive-letter path or Windows-style backslashes to the
# native POSIX shell filesystem mount path (/cygdrive/c/..., /c/..., /mnt/c/...).
to_posix_path() {
    local p="$1"
    [[ -z "$p" ]] && return 0

    if command -v cygpath >/dev/null 2>&1; then
        cygpath -u "$p"
    else
        p="${p//\\//}"
        if [[ "$p" =~ ^([a-zA-Z]):/(.*) ]]; then
            local drive="${BASH_REMATCH[1],,}"
            local rest="${BASH_REMATCH[2]}"
            if [[ "$PLATFORM" == "msys2" ]]; then
                echo "/${drive}/${rest}"
            elif [[ "$PLATFORM" == "wsl" ]] || [[ -d "/mnt/${drive}" ]]; then
                echo "/mnt/${drive}/${rest}"
            elif [[ -d "/cygdrive/${drive}" ]]; then
                echo "/cygdrive/${drive}/${rest}"
            else
                echo "/${drive}/${rest}"
            fi
        elif [[ "$p" =~ ^([a-zA-Z]):$ ]]; then
            local drive="${BASH_REMATCH[1],,}"
            if [[ "$PLATFORM" == "msys2" ]]; then
                echo "/${drive}"
            elif [[ "$PLATFORM" == "wsl" ]] || [[ -d "/mnt/${drive}" ]]; then
                echo "/mnt/${drive}"
            elif [[ -d "/cygdrive/${drive}" ]]; then
                echo "/cygdrive/${drive}"
            else
                echo "/${drive}"
            fi
        else
            echo "$p"
        fi
    fi
}

# Backward-compatible wrapper
to_cygpath() {
    to_posix_path "$@"
}

# to_syspath <path>
# Converts POSIX shell path back to Windows native backslash path if on Windows/Cygwin/MSYS.
to_syspath() {
    local p="$1"
    [[ -z "$p" ]] && return 0

    if command -v cygpath >/dev/null 2>&1; then
        cygpath -w "$p"
    elif [[ "$p" =~ ^/([a-zA-Z])/(.*) ]] && [[ "$PLATFORM" == "msys2" ]]; then
        local drive="${BASH_REMATCH[1]^^}"
        local rest="${BASH_REMATCH[2]//\//\\}"
        echo "${drive}:\\${rest}"
    else
        echo "$p"
    fi
}

# ------------------------------------------------------------------------------
# Section 4: Defensive Filesystem Controls
# ------------------------------------------------------------------------------
# safe_rm_rf <target_directory>
# Provides strict containment against accidental filesystem deletions.
safe_rm_rf() {
    local target="$1"

    # Reject empty, unset, or whitespace-only target
    [[ -z "${target// /}" ]] && return 0

    local norm
    norm=$(to_posix_path "$target")

    # Strip trailing slashes
    while [[ "$norm" != "/" && "$norm" =~ /$ ]]; do
        norm="${norm%/}"
    done

    # Refuse removal of dangerous system or root paths
    case "$norm" in
        ""|"/"|"."|".."|"/tmp"|"/var/tmp"|"/cygdrive"|"/mnt")
            log_warn "Refusing unsafe directory deletion: '$norm'"
            return 1
            ;;
        /cygdrive/[a-zA-Z]|/mnt/[a-zA-Z]|/[a-zA-Z])
            log_warn "Refusing unsafe drive root deletion: '$norm'"
            return 1
            ;;
        /bin|/usr|/usr/bin|/etc|/lib|/lib64|/sbin|/home|/root|/boot|/dev|/proc|/sys|/opt|/srv)
            log_warn "Refusing unsafe system directory deletion: '$norm'"
            return 1
            ;;
    esac

    if [[ -d "$norm" || -L "$norm" ]]; then
        rm -rf "$norm" 2>/dev/null || true
    fi
}

# safe_rm_f <target_file>
# Provides defensive single-file removal with bounds checking.
safe_rm_f() {
    local target="$1"

    # Reject empty, unset, or whitespace-only target
    [[ -z "${target// /}" ]] && return 0

    local norm
    norm=$(to_posix_path "$target")

    case "$norm" in
        ""|"/"|"."|".."|"/tmp"|"/var/tmp"|"/cygdrive"|"/mnt"|/cygdrive/[a-zA-Z]|/mnt/[a-zA-Z]|/[a-zA-Z])
            return 1
            ;;
    esac

    if [[ -f "$norm" || -L "$norm" ]]; then
        rm -f "$norm" 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# Section 5: Temporary Workspace Lifecycle & Signal Traps
# ------------------------------------------------------------------------------
detect_temp_root() {
    local candidates=()
    [[ -n "${TMP:-}" ]] && candidates+=("$TMP")
    [[ -n "${TEMP:-}" ]] && candidates+=("$TEMP")
    [[ -n "${TMPDIR:-}" ]] && candidates+=("$TMPDIR")
    candidates+=("/tmp")

    for dir in "${candidates[@]}"; do
        local posix_dir
        posix_dir=$(to_posix_path "$dir")
        if [[ -d "$posix_dir" && -w "$posix_dir" ]]; then
            echo "$posix_dir"
            return 0
        fi
    done

    mkdir -p "/tmp" 2>/dev/null || true
    echo "/tmp"
}

# cleanup_workspace
# Trapped by EXIT, INT, TERM, HUP signals. Destroys active package build dirs,
# in-flight target staging temporary files, and unique per-run execution workspaces.
cleanup_workspace() {
    local exit_code=$?
    if [[ -n "${CURRENT_BUILD_DIR:-}" && -d "$CURRENT_BUILD_DIR" ]]; then
        safe_rm_rf "$CURRENT_BUILD_DIR"
        CURRENT_BUILD_DIR=""
    fi
    if [[ -n "${CURRENT_TARGET_TMP:-}" && -f "$CURRENT_TARGET_TMP" ]]; then
        safe_rm_f "$CURRENT_TARGET_TMP"
        CURRENT_TARGET_TMP=""
    fi
    if [[ -n "${EXEC_WORKSPACE:-}" && -d "$EXEC_WORKSPACE" ]]; then
        safe_rm_rf "$EXEC_WORKSPACE"
        EXEC_WORKSPACE=""
    fi
    exit $exit_code
}

trap cleanup_workspace EXIT INT TERM HUP

# ------------------------------------------------------------------------------
# Section 6: Semantic Version Comparator
# ------------------------------------------------------------------------------
# is_version_newer <new_version> <existing_version>
# Returns 0 (true) if new_version is strictly newer than existing_version.
is_version_newer() {
    local v1="$1"
    local v2="$2"
    [[ -n "$v1" ]] || return 1
    [[ -z "$v2" || "$v2" == "none" ]] && return 0
    [[ "$v1" == "$v2" ]] && return 1

    local highest
    highest=$(printf "%s\n%s\n" "$v1" "$v2" | sort -V | tail -n1)
    if [[ "$highest" == "$v1" && "$v1" != "$v2" ]]; then
        return 0
    fi
    return 1
}

# ------------------------------------------------------------------------------
# Section 7: Obsolete Version Purger & Transactional Staging Engine
# ------------------------------------------------------------------------------
# purge_obsolete_packages <app_key> <platform_suffix> <current_pkg_name> [source_dir] [target_dir] [is_dry_run]
# Safely purges previous builds of the same component and platform suffix
# in both source and target directories using properly unquoted pathname expansion.
purge_obsolete_packages() {
    local app_key="$1"
    local platform_suffix="$2"
    local current_pkg="$3"
    local src_dir="${4:-${SOURCE_CYG:-}}"
    local tgt_dir="${5:-${TARGET_CYG:-}}"
    local dry_run="${6:-${DRY_RUN:-false}}"

    [[ -n "$current_pkg" ]] || return 0

    # Purge in source library if enabled and present
    if [[ "${UPDATE_SOURCE:-true}" == true && -n "$src_dir" && -d "$src_dir" ]]; then
        shopt -s nullglob
        local old_src_files=()
        if [[ -z "$platform_suffix" || "$platform_suffix" == "*" || "$platform_suffix" == "all" ]]; then
            old_src_files=("${src_dir}/${app_key}-"*".zip")
        else
            old_src_files=("${src_dir}/${app_key}-"*"-${platform_suffix}."*)
        fi
        shopt -u nullglob
        for old in "${old_src_files[@]}"; do
            if [[ "$(basename "$old")" != "$current_pkg" ]]; then
                if [[ "$dry_run" == true ]]; then
                    log_ok "[DRY-RUN] Would remove obsolete source version: $(basename "$old")"
                else
                    log_info "Removing obsolete source version: $(basename "$old")"
                    safe_rm_f "$old"
                fi
            fi
        done
    fi

    # Purge in target staging if present
    if [[ -n "$tgt_dir" && -d "$tgt_dir" ]]; then
        shopt -s nullglob
        local old_tgt_files=()
        if [[ -z "$platform_suffix" || "$platform_suffix" == "*" || "$platform_suffix" == "all" ]]; then
            old_tgt_files=("${tgt_dir}/${app_key}-"*".zip")
        else
            old_tgt_files=("${tgt_dir}/${app_key}-"*"-${platform_suffix}."*)
        fi
        shopt -u nullglob
        for old in "${old_tgt_files[@]}"; do
            if [[ "$(basename "$old")" != "$current_pkg" ]]; then
                if [[ "$dry_run" == true ]]; then
                    log_ok "[DRY-RUN] Would remove obsolete target version: $(basename "$old")"
                else
                    log_info "Removing obsolete target version: $(basename "$old")"
                    safe_rm_f "$old"
                fi
            fi
        done
    fi
}

# atomic_stage_package <src_file> <pkg_name> <app_key> <platform_suffix> [source_dir] [target_dir] [is_dry_run]
# Safely stages package to source library and target directory via intermediate .tmp files.
atomic_stage_package() {
    local src_file="$1"
    local pkg_name="$2"
    local app_key="$3"
    local platform_suffix="$4"
    local src_dir="${5:-${SOURCE_CYG:-}}"
    local tgt_dir="${6:-${TARGET_CYG:-}}"
    local dry_run="${7:-${DRY_RUN:-false}}"
    local update_src="${UPDATE_SOURCE:-true}"

    # 1. Purge obsolete versions first
    purge_obsolete_packages "$app_key" "$platform_suffix" "$pkg_name" "$src_dir" "$tgt_dir" "$dry_run"

    if [[ "$dry_run" == true ]]; then
        if [[ "$update_src" == true && -n "$src_dir" ]]; then
            log_ok "[DRY-RUN] Would move $pkg_name to source: ${src_dir}/${pkg_name}"
        fi
        if [[ -n "$tgt_dir" ]]; then
            log_ok "[DRY-RUN] Would stage $pkg_name in target: ${tgt_dir}/${pkg_name}"
        fi
        return 0
    fi

    # 2. Update source library
    if [[ "$update_src" == true && -n "$src_dir" ]]; then
        mkdir -p "$src_dir" 2>/dev/null || true
        log_info "Moving $pkg_name to source library..."
        if ! cp -f "$src_file" "${src_dir}/${pkg_name}"; then
            log_error "Failed to copy $pkg_name to source library: ${src_dir}/${pkg_name}"
            return 1
        fi
        chmod 644 "${src_dir}/${pkg_name}" 2>/dev/null || true
    fi

    # 3. Atomic stage to target via .tmp rename
    if [[ -n "$tgt_dir" ]]; then
        mkdir -p "$tgt_dir" 2>/dev/null || true
        log_info "Atomically staging $pkg_name in target pending..."
        local tmp_target="${tgt_dir}/${pkg_name}.tmp"
        CURRENT_TARGET_TMP="$tmp_target"
        if ! cp -f "$src_file" "$tmp_target"; then
            log_error "Failed to stage temporary file in target: $tmp_target"
            safe_rm_f "$tmp_target"
            CURRENT_TARGET_TMP=""
            return 1
        fi
        chmod 644 "$tmp_target" 2>/dev/null || true
        if ! mv -f "$tmp_target" "${tgt_dir}/${pkg_name}"; then
            log_error "Failed to rename $tmp_target to ${tgt_dir}/${pkg_name}"
            safe_rm_f "$tmp_target"
            CURRENT_TARGET_TMP=""
            return 1
        fi
        CURRENT_TARGET_TMP=""

        if [[ -s "${tgt_dir}/${pkg_name}" ]]; then
            log_ok "Successfully staged in target: $pkg_name"
        else
            log_error "Failed to verify staged target package: ${tgt_dir}/${pkg_name}"
            return 1
        fi
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Section 8: Download & Checksum Helper
# ------------------------------------------------------------------------------
# download_asset <url> <dest_file> [expected_hash] [hash_algo]
download_asset() {
    local url="$1"
    local dest_file="$2"
    local expected_hash="${3:-}"
    local hash_algo="${4:-sha512}"

    if ! curl -fsSL --retry 3 --retry-delay 2 -o "$dest_file" "$url"; then
        log_error "Failed to download asset from $url"
        return 1
    fi

    if [[ -n "$expected_hash" ]]; then
        local sum_cmd="${hash_algo}sum"
        if command -v "$sum_cmd" >/dev/null 2>&1; then
            local actual_hash
            actual_hash=$("$sum_cmd" "$dest_file" | cut -d' ' -f1)
            if [[ "$actual_hash" != "$expected_hash" ]]; then
                log_error "${hash_algo^^} checksum mismatch for $(basename "$dest_file")"
                log_error "Expected: $expected_hash"
                log_error "Actual  : $actual_hash"
                safe_rm_f "$dest_file"
                return 1
            fi
            log_info "Verified ${hash_algo^^} checksum."
        else
            log_warn "$sum_cmd not found on system; skipping checksum verification."
        fi
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Section 9: Archive Manipulation & Pruning Utilities
# ------------------------------------------------------------------------------
# is_artifact_file <filename>
# Checks if a filename matches redundant packaging files to prune:
# LICENSE*, *LICENCE*, NOTICE*, ATTRIBUTION*, OFL-*.txt, ASSETS.md, portable.txt (case-insensitive)
is_artifact_file() {
    local fname="$1"
    local lower="${fname,,}"
    if [[ "$lower" == license* || "$lower" == *licence* || "$lower" == notice* || "$lower" == attribution* || "$lower" == ofl-*.txt || "$lower" == ofl.txt || "$lower" == assets.md || "$lower" == portable.txt ]]; then
        return 0
    fi
    return 1
}

# clean_zip_artifacts <zip_path>
# Removes matching artifact files directly from a zip archive without full repacking.
clean_zip_artifacts() {
    local zip_path="$1"
    [[ -f "$zip_path" ]] || return 1

    local entries_to_remove=()
    while IFS= read -r entry || [[ -n "$entry" ]]; do
        [[ -z "$entry" ]] && continue
        local base="${entry##*/}"
        if is_artifact_file "$base" || [[ "${entry,,}" =~ (^|/)licenses(/|$) || "${entry,,}" =~ (^|/)license(/|$) ]]; then
            entries_to_remove+=("$entry")
        fi
    done < <(unzip -Z1 "$zip_path" 2>/dev/null || true)

    if [[ ${#entries_to_remove[@]} -gt 0 ]]; then
        log_info "Removing ${#entries_to_remove[@]} artifact file(s) from $(basename "$zip_path")..."
        if command -v zip >/dev/null 2>&1; then
            zip -q -d "$zip_path" "${entries_to_remove[@]}" >/dev/null 2>&1 || true
        elif command -v 7za >/dev/null 2>&1; then
            7za d "$zip_path" "${entries_to_remove[@]}" >/dev/null 2>&1 || true
        fi
    fi
}

# strip_base_directory <target_dir>
# If target_dir contains exactly one directory entry and no files, moves all contents
# of that directory up into target_dir and removes the now-empty wrapper folder.
strip_base_directory() {
    local target_dir="$1"
    [[ -d "$target_dir" ]] || return 0
    shopt -s nullglob dotglob
    local items=("${target_dir}"/*)
    shopt -u nullglob dotglob
    if [[ ${#items[@]} -eq 1 && -d "${items[0]}" ]]; then
        local base_dir="${items[0]}"
        local base_name
        base_name=$(basename "$base_dir")
        log_info "Stripping base folder: ${base_name}"
        local tmp_mv="${target_dir}_tmp_mv_$$"
        mv "$base_dir" "$tmp_mv"
        shopt -s nullglob dotglob
        local inner_items=("${tmp_mv}"/*)
        for item in "${inner_items[@]}"; do
            mv "$item" "${target_dir}/"
        done
        shopt -u nullglob dotglob
        rmdir "$tmp_mv" 2>/dev/null || rm -rf "$tmp_mv" 2>/dev/null || true
    fi
}

# prune_directory_artifacts <target_dir>
# Recursively removes artifact files (licenses, notices, attributions, OFL,
# ASSETS.md, portable.txt) and any licenses subfolder.
prune_directory_artifacts() {
    local target_dir="$1"
    [[ -d "$target_dir" ]] || return 0

    # 1. Remove licenses/ or license/ subfolders wherever they exist
    find "$target_dir" -type d \( -iname "licenses" -o -iname "license" \) -prune -exec rm -rf {} + 2>/dev/null || true

    # 2. Remove packaging artifact files
    find "$target_dir" -type f \( \
        -iname "license*" -o \
        -iname "*licence*" -o \
        -iname "notice*" -o \
        -iname "attribution*" -o \
        -iname "ofl-*.txt" -o \
        -iname "ofl.txt" -o \
        -iname "assets.md" -o \
        -iname "portable.txt" \
    \) -delete 2>/dev/null || true
}

# repack_directory_to_zip <content_dir> <dest_zip>
# Packages content_dir directly into dest_zip without a top-level wrapper directory.
repack_directory_to_zip() {
    local content_dir="$1"
    local dest_zip="$2"
    [[ -d "$content_dir" ]] || return 1
    safe_rm_f "$dest_zip"
    (cd "$content_dir" && zip -q -r "$dest_zip" .)
    if ! verify_zip_integrity "$dest_zip"; then
        log_error "Corrupted zip archive generated: $(basename "$dest_zip")"
        safe_rm_f "$dest_zip"
        return 1
    fi
    return 0
}

# repack_directory_to_tar_xz <content_dir> <dest_tar_xz>
# Recompresses content_dir into a high-ratio .tar.xz archive with standardized
# root/root ownership without a top-level wrapper directory.
repack_directory_to_tar_xz() {
    local content_dir="$1"
    local dest_tar_xz="$2"
    [[ -d "$content_dir" ]] || return 1
    safe_rm_f "$dest_tar_xz"

    (
        cd "$content_dir"
        shopt -s nullglob dotglob
        local items=(*)
        shopt -u nullglob dotglob
        if [[ ${#items[@]} -gt 0 ]]; then
            tar --force-local --owner=0 --group=0 --numeric-owner -cf - "${items[@]}" | xz -9 -T0 > "$dest_tar_xz"
        else
            tar --force-local --owner=0 --group=0 --numeric-owner -cf - --files-from /dev/null | xz -9 -T0 > "$dest_tar_xz"
        fi
    )
    if ! verify_tar_xz_integrity "$dest_tar_xz"; then
        log_error "Corrupted xz archive generated: $(basename "$dest_tar_xz")"
        safe_rm_f "$dest_tar_xz"
        return 1
    fi
    return 0
}

# prune_electron_locales <locales_dir> [keep_locale]
# Prunes unused language packs from an Electron app locales directory, keeping only en-US.pak.
prune_electron_locales() {
    local locales_dir="$1"
    local keep="${2:-en-US.pak}"
    if [[ -d "$locales_dir" ]]; then
        find "$locales_dir" -type f -name "*.pak" ! -name "$keep" -delete 2>/dev/null || true
    fi
}

# recompress_folder_to_tar_xz <parent_dir> <folder_to_pack> <dest_tar_xz>
# Recompresses folder into a high-ratio .tar.xz archive with standardized root/root ownership.
recompress_folder_to_tar_xz() {
    local parent_dir="$1"
    local folder_to_pack="$2"
    local dest_tar_xz="$3"

    (cd "$parent_dir" && tar --force-local --owner=0 --group=0 --numeric-owner -cf - "$folder_to_pack" | xz -9 -T0 > "$dest_tar_xz")
    if ! tar --force-local -tJf "$dest_tar_xz" >/dev/null 2>&1; then
        log_error "Corrupted xz archive generated: $(basename "$dest_tar_xz")"
        safe_rm_f "$dest_tar_xz"
        return 1
    fi
    return 0
}

# verify_zip_integrity <zip_path>
verify_zip_integrity() {
    local zip_path="$1"
    unzip -tq "$zip_path" >/dev/null 2>&1
}

# verify_tar_xz_integrity <tar_xz_path>
verify_tar_xz_integrity() {
    local tar_xz_path="$1"
    tar --force-local -tJf "$tar_xz_path" >/dev/null 2>&1
}

# is_windows_platform
# Returns 0 if current host environment is Windows-based (Cygwin or MSYS2), 1 otherwise.
is_windows_platform() {
    case "$PLATFORM" in
        cygwin|msys2) return 0 ;;
        *) return 1 ;;
    esac
}

# get_target_os
# Returns "windows" or "linux" based on current host platform.
get_target_os() {
    if is_windows_platform; then
        echo "windows"
    else
        echo "linux"
    fi
}

# extract_archive <archive_path> <dest_dir>
# Extracts .zip, .tar.gz, .tgz, or .tar.xz archive into destination directory.
extract_archive() {
    local archive="$1"
    local dest_dir="$2"
    [[ -f "$archive" ]] || { log_error "Archive not found: $archive"; return 1; }
    mkdir -p "$dest_dir"

    case "${archive,,}" in
        *.zip)
            unzip -q "$archive" -d "$dest_dir"
            ;;
        *.tar.gz|*.tgz)
            tar --force-local -xzf "$archive" -C "$dest_dir"
            ;;
        *.tar.xz)
            tar --force-local -xJf "$archive" -C "$dest_dir"
            ;;
        *.tar)
            tar --force-local -xf "$archive" -C "$dest_dir"
            ;;
        *)
            log_error "Unsupported archive format: $(basename "$archive")"
            return 1
            ;;
    esac
}

# prune_root_licenses <target_dir>
# Removes LICENSE*, LICENSES*, NOTICE*, ATTRIBUTION* from directory root.
prune_root_licenses() {
    local target_dir="$1"
    [[ -d "$target_dir" ]] || return 0
    rm -f "${target_dir}"/LICENSE* "${target_dir}"/LICENSES* "${target_dir}"/NOTICE* "${target_dir}"/ATTRIBUTION* "${target_dir}"/OFL*.txt 2>/dev/null || true
}

