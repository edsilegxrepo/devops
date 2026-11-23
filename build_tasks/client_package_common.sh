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
    uname_out="$(uname -s 2> /dev/null || echo "unknown")"
    case "${uname_out,,}" in
        msys* | mingw* | cygwin* | windows*)
            if [[ "${uname_out,,}" == cygwin* ]]; then
                echo "cygwin"
            else
                echo "msys2"
            fi
            ;;
        linux*)
            if grep -qi "microsoft" /proc/version 2> /dev/null; then
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

log_info() { echo -e "${C_CYAN}[INFO]${C_RESET} $*"; }
log_ok() { echo -e "${C_GREEN}[OK]${C_RESET} $*"; }
log_warn() { echo -e "${C_YELLOW}[WARN]${C_RESET} $*" >&2; }
log_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }
log_step() { echo -e "${C_BLUE}==>${C_RESET} ${C_BOLD}$*${C_RESET}"; }

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

    if command -v cygpath > /dev/null 2>&1; then
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

    if command -v cygpath > /dev/null 2>&1; then
        cygpath -w "$p"
    elif [[ "$p" =~ ^/([a-zA-Z])/(.*) ]] && [[ "$PLATFORM" == "msys2" ]]; then
        local drive="${BASH_REMATCH[1]^^}"
        local rest="${BASH_REMATCH[2]//\//\\}"
        echo "${drive}:\\${rest}"
    else
        echo "$p"
    fi
}

# resolve_default_path <drive_letter> <rel_path>
# Resolves a Windows drive-letter default path (or WSL/Linux /mnt or /media mount).
resolve_default_path() {
    local drive="${1,,}"
    local rel_path="${2#/}"
    if [[ "$PLATFORM" == "linux" || "$PLATFORM" == "wsl" ]]; then
        if [[ -d "/mnt/${drive}/${rel_path}" ]]; then
            echo "/mnt/${drive}/${rel_path}"
            return 0
        elif [[ -d "/media/${drive}/${rel_path}" ]]; then
            echo "/media/${drive}/${rel_path}"
            return 0
        fi
    fi
    echo "${drive}:/${rel_path}"
}

# to_wsl_path <path>
# Translates a Windows or POSIX shell path to a WSL path using wslpath.
to_wsl_path() {
    local p="$1"
    [[ -z "$p" ]] && return 1
    local drive_p
    drive_p=$(enforce_drive_path "$p")
    if [[ "$drive_p" =~ ^[a-zA-Z]:/ ]]; then
        wsl.exe -e wslpath -u "$drive_p" < /dev/null 2> /dev/null | tr -d '\r'
    else
        local sys_p
        sys_p=$(to_syspath "$p")
        wsl.exe -e wslpath -u "${sys_p//\\//}" < /dev/null 2> /dev/null | tr -d '\r'
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
        "" | "/" | "." | ".." | "/tmp" | "/var/tmp" | "/cygdrive" | "/mnt")
            log_warn "Refusing unsafe directory deletion: '$norm'"
            return 1
            ;;
        /cygdrive/[a-zA-Z] | /mnt/[a-zA-Z] | /[a-zA-Z])
            log_warn "Refusing unsafe drive root deletion: '$norm'"
            return 1
            ;;
        /bin | /usr | /usr/bin | /etc | /lib | /lib64 | /sbin | /home | /root | /boot | /dev | /proc | /sys | /opt | /srv)
            log_warn "Refusing unsafe system directory deletion: '$norm'"
            return 1
            ;;
    esac

    if [[ -d "$norm" || -L "$norm" ]]; then
        rm -rf "$norm" 2> /dev/null || true
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
        "" | "/" | "." | ".." | "/tmp" | "/var/tmp" | "/cygdrive" | "/mnt" | /cygdrive/[a-zA-Z] | /mnt/[a-zA-Z] | /[a-zA-Z])
            return 1
            ;;
    esac

    if [[ -f "$norm" || -L "$norm" ]]; then
        rm -f "$norm" 2> /dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# Section 5: Temporary Workspace Lifecycle & Signal Traps
# ------------------------------------------------------------------------------
detect_temp_root() {
    local candidates=()
    [[ -n "${TEMP:-}" ]] && candidates+=("$TEMP")
    [[ -n "${TMPDIR:-}" ]] && candidates+=("$TMPDIR")
    [[ -n "${TMP:-}" ]] && candidates+=("$TMP")
    candidates+=("/tmp")

    for dir in "${candidates[@]}"; do
        local posix_dir
        posix_dir=$(to_posix_path "$dir")
        if [[ -d "$posix_dir" && -w "$posix_dir" ]]; then
            echo "$posix_dir"
            return 0
        fi
    done

    mkdir -p "/tmp" 2> /dev/null || true
    echo "/tmp"
}

# cleanup_current_build_dir / cleanup_exec_workspace
# Shared per-item / per-run workspace teardown helpers (safe for both loops and traps).
cleanup_current_build_dir() {
    if [[ -n "${CURRENT_BUILD_DIR:-}" && -d "$CURRENT_BUILD_DIR" ]]; then
        safe_rm_rf "$CURRENT_BUILD_DIR"
    fi
    CURRENT_BUILD_DIR=""
}

cleanup_exec_workspace() {
    if [[ -n "${EXEC_WORKSPACE:-}" && -d "$EXEC_WORKSPACE" ]]; then
        safe_rm_rf "$EXEC_WORKSPACE"
    fi
    EXEC_WORKSPACE=""
}

# cleanup_workspace
# Trapped by EXIT, INT, TERM, HUP signals. Destroys active package build dirs,
# in-flight target staging temporary files, and unique per-run execution workspaces.
cleanup_workspace() {
    local exit_code=$?
    cleanup_current_build_dir
    if [[ -n "${_CURRENT_TMP_FILE:-}" && -f "$_CURRENT_TMP_FILE" ]]; then
        safe_rm_f "$_CURRENT_TMP_FILE"
        _CURRENT_TMP_FILE=""
    fi
    if [[ -n "${CURRENT_TARGET_TMP:-}" && -f "$CURRENT_TARGET_TMP" ]]; then
        safe_rm_f "$CURRENT_TARGET_TMP"
        CURRENT_TARGET_TMP=""
    fi
    cleanup_exec_workspace
    exit $exit_code
}

# report_unexpected_err <source_file> <line_no> <command>
# Trapped by ERR when set -E is enabled so unexpected aborts emit diagnostics before cleanup.
report_unexpected_err() {
    local err_rc=$?
    local err_src="${1:-unknown}"
    local err_line="${2:-?}"
    local err_cmd="${3:-}"
    log_error "Unexpected failure (exit=${err_rc}) in $(basename "$err_src"):${err_line}: ${err_cmd}"
}

enable_err_trap() {
    trap 'report_unexpected_err "${BASH_SOURCE[0]}" "${LINENO}" "${BASH_COMMAND}"' ERR
}

if [[ $- == *e* ]]; then
    enable_err_trap
fi
trap cleanup_workspace EXIT INT TERM HUP

# ------------------------------------------------------------------------------
# Section 6: Semantic Version Comparator & Local Discovery
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

# find_local_version <search_dir> <app_key> <suffix_regex> [ext]
# Scans search_dir for <app_key>-<version>-<suffix>.<ext> and prints
# "<latest_version> <canonical_file_path>" (or "none " if none found).
find_local_version() {
    local search_dir="$1"
    local app_key="$2"
    local suffix_regex="$3"
    local ext="${4:-}"

    if [[ -z "$ext" ]]; then
        if [[ "$suffix_regex" == "lnx" ]]; then
            ext="tar.xz"
        else
            ext="zip"
        fi
    fi

    if [[ ! -d "$search_dir" ]]; then
        echo "none" ""
        return 0
    fi

    shopt -s nullglob
    local files=("${search_dir}/${app_key}-"*".${ext}")
    shopt -u nullglob

    if [[ ${#files[@]} -eq 0 ]]; then
        echo "none" ""
        return 0
    fi

    local app_escaped="${app_key//./\\.}"
    app_escaped="${app_escaped//+/\\+}"
    local ext_escaped="${ext//./\\.}"
    local latest_ver="none"
    local latest_file=""

    for f in "${files[@]}"; do
        local bname
        bname=$(basename "$f")
        if [[ "$bname" =~ ^${app_escaped}-([0-9]+(\.[0-9]+)*([a-zA-Z0-9._-]*))-(${suffix_regex})\.${ext_escaped}$ ]]; then
            local ver="${BASH_REMATCH[1]}"
            if [[ "$latest_ver" == "none" ]] || is_version_newer "$ver" "$latest_ver"; then
                latest_ver="$ver"
                latest_file="$f"
            fi
        fi
    done

    if [[ -n "$latest_file" ]]; then
        latest_file=$(enforce_drive_path "$latest_file")
    fi

    echo "$latest_ver" "$latest_file"
}

# ------------------------------------------------------------------------------
# Section 7: Obsolete Version Purger & Transactional Staging Engine
# ------------------------------------------------------------------------------
# _purge_obsolete_in_dir <dir> <label> <app_key> <platform_suffix> <current_pkg> <dry_run>
_purge_obsolete_in_dir() {
    local dir="$1"
    local label="$2"
    local app_key="$3"
    local platform_suffix="$4"
    local current_pkg="$5"
    local dry_run="$6"

    [[ -n "$dir" && -d "$dir" ]] || return 0

    shopt -s nullglob
    local old_files=()
    if [[ -z "$platform_suffix" || "$platform_suffix" == "*" || "$platform_suffix" == "all" ]]; then
        old_files=("${dir}/${app_key}-"*".zip")
    else
        old_files=("${dir}/${app_key}-"*"-${platform_suffix}."*)
    fi
    shopt -u nullglob

    for old in "${old_files[@]}"; do
        local bname
        bname=$(basename "$old")
        [[ "$bname" =~ ^${app_key}-[0-9] ]] || continue
        if [[ "$bname" != "$current_pkg" ]]; then
            if [[ "$dry_run" == true ]]; then
                log_ok "[DRY-RUN] Would remove obsolete ${label} version: ${bname}"
            else
                log_info "Removing obsolete ${label} version: ${bname}"
                safe_rm_f "$old"
            fi
        fi
    done
}

# purge_legacy_suffix_packages <dir> <label> <app_key> <out_suffix> <legacy_regex> <current_pkg> [is_dry_run]
# Removes previous archives matching <app_key>-<ver>-(<legacy_regex>).<ext> whose suffix
# differs from <out_suffix> (while leaving unmentioned custom suffixes intact).
purge_legacy_suffix_packages() {
    local dir="$1" label="$2" app_key="$3" out_suffix="$4"
    local legacy_regex="$5" current_pkg="$6" dry_run="${7:-false}"
    [[ -n "$dir" && -d "$dir" && -n "$current_pkg" && -n "$legacy_regex" ]] || return 0

    local ext="${current_pkg##*.}"
    local app_escaped="${app_key//./\\.}"
    app_escaped="${app_escaped//+/\\+}"
    local ext_escaped="${ext//./\\.}"

    shopt -s nullglob
    local candidates=("${dir}/${app_key}-"*".${ext}")
    shopt -u nullglob

    local f bname
    for f in "${candidates[@]}"; do
        bname=$(basename "$f")
        [[ "$bname" != "$current_pkg" ]] || continue
        [[ "$bname" =~ ^${app_escaped}-[0-9].*-${out_suffix}\.${ext_escaped}$ ]] && continue
        if [[ "$bname" =~ ^${app_escaped}-[0-9].*-(${legacy_regex})\.${ext_escaped}$ ]]; then
            if [[ "$dry_run" == true ]]; then
                log_ok "[DRY-RUN] Would remove obsolete ${label} bundle: ${bname}"
            else
                log_info "Removing obsolete ${label} bundle: ${bname}"
                safe_rm_f "$f"
            fi
        fi
    done
}

# _paths_same_dir <dir_a> <dir_b>
# Returns 0 if both paths resolve to the same existing directory.
_paths_same_dir() {
    local a="$1" b="$2"
    [[ -n "$a" && -n "$b" && -d "$a" && -d "$b" ]] || return 1
    [[ "$(cd "$a" 2> /dev/null && pwd)" == "$(cd "$b" 2> /dev/null && pwd)" ]]
}

# _atomic_install_file <src_file> <dest_dir> <pkg_name> <label>
# Stages a file into dest_dir atomically via .tmp + mv and verifies non-empty result.
_atomic_install_file() {
    local src_file="$1" dest_dir="$2" pkg_name="$3" label="$4"
    mkdir -p "$dest_dir" 2> /dev/null || true
    local tmp_dest="${dest_dir}/${pkg_name}.tmp.$$"
    CURRENT_TARGET_TMP="$tmp_dest"
    if ! cp -f "$src_file" "$tmp_dest"; then
        log_error "Failed to stage temporary ${label} file: $tmp_dest"
        safe_rm_f "$tmp_dest"
        CURRENT_TARGET_TMP=""
        return 1
    fi
    chmod 644 "$tmp_dest" 2> /dev/null || true
    if ! mv -f "$tmp_dest" "${dest_dir}/${pkg_name}"; then
        log_error "Failed to rename $tmp_dest to ${dest_dir}/${pkg_name}"
        safe_rm_f "$tmp_dest"
        CURRENT_TARGET_TMP=""
        return 1
    fi
    CURRENT_TARGET_TMP=""
    if [[ ! -s "${dest_dir}/${pkg_name}" ]]; then
        log_error "Failed to verify staged ${label} package: ${dest_dir}/${pkg_name}"
        return 1
    fi
    return 0
}

# purge_obsolete_packages <app_key> <platform_suffix> <current_pkg_name> [source_dir] [target_dir] [is_dry_run]
# Safely purges previous builds of the same component and platform suffix
# in both source and target directories.
purge_obsolete_packages() {
    local app_key="$1"
    local platform_suffix="$2"
    local current_pkg="$3"
    local src_dir="${4:-${SOURCE_CYG:-}}"
    local tgt_dir="${5:-${TARGET_CYG:-}}"
    local dry_run="${6:-${DRY_RUN:-false}}"

    [[ -n "$current_pkg" ]] || return 0

    local purged_src=false
    if [[ "${UPDATE_SOURCE:-true}" == true && -n "$src_dir" ]]; then
        _purge_obsolete_in_dir "$src_dir" "source" "$app_key" "$platform_suffix" "$current_pkg" "$dry_run"
        purged_src=true
    fi
    if [[ -n "$tgt_dir" ]] && { [[ "$purged_src" != true ]] || ! _paths_same_dir "$src_dir" "$tgt_dir"; }; then
        _purge_obsolete_in_dir "$tgt_dir" "target" "$app_key" "$platform_suffix" "$current_pkg" "$dry_run"
    fi
}

# atomic_stage_package <src_file> <pkg_name> <app_key> <platform_suffix> [source_dir] [target_dir] [is_dry_run]
# Safely stages package to source library and target directory via intermediate .tmp
# renames BEFORE purging older versions so an interrupted copy cannot leave an empty dir.
atomic_stage_package() {
    local src_file="$1"
    local pkg_name="$2"
    local app_key="$3"
    local platform_suffix="$4"
    local src_dir="${5:-${SOURCE_CYG:-}}"
    local tgt_dir="${6:-${TARGET_CYG:-}}"
    local dry_run="${7:-${DRY_RUN:-false}}"
    local update_src="${UPDATE_SOURCE:-true}"

    if [[ "$dry_run" == true ]]; then
        if [[ "$update_src" == true && -n "$src_dir" ]]; then
            log_ok "[DRY-RUN] Would move $pkg_name to source: ${src_dir}/${pkg_name}"
        fi
        if [[ -n "$tgt_dir" ]] && { [[ "$update_src" != true ]] || ! _paths_same_dir "$src_dir" "$tgt_dir"; }; then
            log_ok "[DRY-RUN] Would stage $pkg_name in target: ${tgt_dir}/${pkg_name}"
        fi
        purge_obsolete_packages "$app_key" "$platform_suffix" "$pkg_name" "$src_dir" "$tgt_dir" "$dry_run"
        return 0
    fi

    local staged_src=false
    if [[ "$update_src" == true && -n "$src_dir" ]]; then
        log_info "Atomically moving $pkg_name to source library..."
        _atomic_install_file "$src_file" "$src_dir" "$pkg_name" "source" || return 1
        staged_src=true
    fi

    if [[ -n "$tgt_dir" ]] && { [[ "$staged_src" != true ]] || ! _paths_same_dir "$src_dir" "$tgt_dir"; }; then
        log_info "Atomically staging $pkg_name in target pending..."
        _atomic_install_file "$src_file" "$tgt_dir" "$pkg_name" "target" || return 1
        log_ok "Successfully staged in target: $pkg_name"
    fi

    purge_obsolete_packages "$app_key" "$platform_suffix" "$pkg_name" "$src_dir" "$tgt_dir" "$dry_run"
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

    if ! curl -fsSL --connect-timeout 15 --max-time 300 --retry 3 --retry-delay 2 -o "$dest_file" "$url"; then
        log_error "Failed to download asset from $url"
        return 1
    fi

    if [[ -n "$expected_hash" ]]; then
        local sum_cmd="${hash_algo}sum"
        if command -v "$sum_cmd" > /dev/null 2>&1; then
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
        rmdir "$tmp_mv" 2> /dev/null || rm -rf "$tmp_mv" 2> /dev/null || true
    fi
}

# normalize_directory_timestamps <target_dir>
# Recursively updates mtimes/atimes of all files and directories to current time,
# preventing DOS/Unix epoch timestamps (e.g. 1980-02-01, 1970-01-01) in archives.
normalize_directory_timestamps() {
    local target_dir="$1"
    [[ -d "$target_dir" ]] || return 0
    find "$target_dir" -depth \( -type f -o -type d \) -exec touch {} + 2> /dev/null || true
}

# repack_directory_to_zip <content_dir> <dest_zip>
# Packages content_dir directly into dest_zip without a top-level wrapper directory.
# Writes to a temp relative zip inside content_dir first so Cygwin zip / MSYS2 bash
# mount differences cannot misresolve POSIX temp paths.
repack_directory_to_zip() {
    local content_dir="$1"
    local dest_zip="$2"
    [[ -d "$content_dir" ]] || return 1
    safe_rm_f "$dest_zip"
    normalize_directory_timestamps "$content_dir"

    local dest_dir tmp_rel
    dest_dir=$(dirname "$dest_zip")
    mkdir -p "$dest_dir" || return 1
    tmp_rel=".__repack_tmp_$$.zip"
    rm -f "${content_dir}/${tmp_rel}" 2> /dev/null || true

    if ! (
        cd "$content_dir" || exit 1
        zip -q -r "./${tmp_rel}" .
    ); then
        rm -f "${content_dir}/${tmp_rel}" 2> /dev/null || true
        log_error "Failed creating zip archive: $(basename "$dest_zip")"
        return 1
    fi

    if ! mv -f "${content_dir}/${tmp_rel}" "$dest_zip"; then
        rm -f "${content_dir}/${tmp_rel}" 2> /dev/null || true
        log_error "Failed moving zip archive to destination: $(basename "$dest_zip")"
        return 1
    fi

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
    mkdir -p "$(dirname "$dest_tar_xz")" || return 1
    normalize_directory_timestamps "$content_dir"

    if ! (
        cd "$content_dir" || exit 1
        shopt -s nullglob dotglob
        local items=(*)
        shopt -u nullglob dotglob
        if [[ ${#items[@]} -gt 0 ]]; then
            tar --force-local --owner=0 --group=0 --numeric-owner -cf - "${items[@]}" | xz -9 -T0 > "$dest_tar_xz"
        else
            tar --force-local --owner=0 --group=0 --numeric-owner -cf - --files-from /dev/null | xz -9 -T0 > "$dest_tar_xz"
        fi
    ); then
        log_error "Failed compressing tar.xz archive: $(basename "$dest_tar_xz")"
        safe_rm_f "$dest_tar_xz"
        return 1
    fi
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
        find "$locales_dir" -type f -name "*.pak" ! -name "$keep" -delete 2> /dev/null || true
    fi
}

# recompress_folder_to_tar_xz <parent_dir> <folder_to_pack> <dest_tar_xz>
# Recompresses folder into a high-ratio .tar.xz archive with standardized root/root ownership.
recompress_folder_to_tar_xz() {
    local parent_dir="$1"
    local folder_to_pack="$2"
    local dest_tar_xz="$3"

    (cd "$parent_dir" && tar --force-local --owner=0 --group=0 --numeric-owner -cf - "$folder_to_pack" | xz -9 -T0 > "$dest_tar_xz")
    if ! tar --force-local -tJf "$dest_tar_xz" > /dev/null 2>&1; then
        log_error "Corrupted xz archive generated: $(basename "$dest_tar_xz")"
        safe_rm_f "$dest_tar_xz"
        return 1
    fi
    return 0
}

# prune_doc_clutter <target_dir>
# Recursively removes non-runtime documentation, licenses, changelogs, and man files.
prune_doc_clutter() {
    local target_dir="$1"
    [[ -d "$target_dir" ]] || return 0
    find "$target_dir" -type f \( \
        -iname 'LICENSE*' -o -iname 'LICENCE*' -o -iname 'README*' -o \
        -iname 'CHANGELOG*' -o -iname 'CHANGES*' -o -iname 'NOTICE*' -o \
        -iname 'COPYING*' -o -iname 'AUTHORS*' -o -iname 'CREDITS*' -o \
        -iname 'SECURITY*' -o -iname 'CONTRIBUTING*' -o \
        -iname '*.md' -o -iname '*.txt' -o -iname '*.1' \
        \) -delete 2> /dev/null || true
}

# verify_zip_integrity <zip_path>
verify_zip_integrity() {
    local zip_path="$1"
    unzip -tq "$zip_path" > /dev/null 2>&1
}

# verify_zip_has_entry <zip_path> <exact_entry_path>
# Returns 0 if zip_path contains exact_entry_path (case-sensitive).
verify_zip_has_entry() {
    local zip_path="$1" entry="$2"
    [[ -f "$zip_path" && -n "$entry" ]] || return 1
    grep -qxF "$entry" <<< "$(unzip -Z1 "$zip_path" 2> /dev/null || true)"
}

# verify_tar_xz_integrity <tar_xz_path>
verify_tar_xz_integrity() {
    local tar_xz_path="$1"
    tar --force-local -tJf "$tar_xz_path" > /dev/null 2>&1
}

# is_windows_platform
# Returns 0 if current host environment is Windows-based (Cygwin or MSYS2), 1 otherwise.
is_windows_platform() {
    case "$PLATFORM" in
        cygwin | msys2) return 0 ;;
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
    [[ -f "$archive" ]] || {
        log_error "Archive not found: $archive"
        return 1
    }
    mkdir -p "$dest_dir"

    case "${archive,,}" in
        *.zip)
            unzip -q "$archive" -d "$dest_dir"
            ;;
        *.tar.gz | *.tgz)
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
    rm -f "${target_dir}"/LICENSE* "${target_dir}"/LICENSES* "${target_dir}"/NOTICE* "${target_dir}"/ATTRIBUTION* "${target_dir}"/OFL*.txt 2> /dev/null || true
}

# ------------------------------------------------------------------------------
# Section 10: Shared CLI Setup, Workspace, & Summary Helpers
# ------------------------------------------------------------------------------
# require_opt_arg <flag> <remaining_argc>
# Ensures a CLI flag that expects a value was given an argument.
require_opt_arg() {
    local flag="$1"
    local argc="$2"
    if [[ "$argc" -lt 2 ]]; then
        log_error "Option '${flag}' requires an argument."
        exit 1
    fi
}

# verify_required_tools <tool1> [tool2...]
# Checks that all required CLI tools are available in PATH, exiting with
# platform-specific installation hints if any are missing.
verify_required_tools() {
    local tool
    for tool in "$@"; do
        if ! command -v "$tool" > /dev/null 2>&1; then
            case "$PLATFORM" in
                cygwin)
                    log_error "Required tool '$tool' not found. Please install it via Cygwin setup."
                    ;;
                msys2)
                    log_error "Required tool '$tool' not found. Please install it via 'pacman -S $tool'."
                    ;;
                linux | wsl)
                    log_error "Required tool '$tool' not found. Please install it via your system package manager (e.g. apt/dnf/pacman)."
                    ;;
                *)
                    log_error "Required tool '$tool' not found. Please install it and ensure it is in PATH."
                    ;;
            esac
            exit 1
        fi
    done
}

# init_log_file <log_file>
# Initializes tee logging to the specified log file if non-empty.
init_log_file() {
    local log_file="$1"
    [[ -z "$log_file" ]] && return 0
    local log_cyg
    log_cyg=$(to_posix_path "$log_file")
    mkdir -p "$(dirname "$log_cyg")"
    exec > >(tee -a "$log_cyg") 2>&1
}

# create_temp_workdir [prefix] [fallback_dir]
# Resolves temp root via detect_temp_root ($TEMP -> $TMPDIR -> $TMP -> /tmp),
# prunes stale workdirs (>1 day) matching <prefix>*, creates a unique temp directory
# via mktemp -d, and prints its POSIX path to stdout.
create_temp_workdir() {
    local prefix="${1:-work_}" fallback_dir="${2:-}"
    local base_temp="${TEMP_ROOT_CYG:-}"
    if [[ -z "$base_temp" || ! -d "$base_temp" || ! -w "$base_temp" ]]; then
        base_temp=$(detect_temp_root)
    fi
    mkdir -p "$base_temp" 2> /dev/null || true

    if [[ ! -d "$base_temp" || ! -w "$base_temp" ]] && [[ -n "$fallback_dir" ]]; then
        base_temp=$(to_posix_path "$fallback_dir")
        mkdir -p "$base_temp" 2> /dev/null || true
    fi

    if [[ -d "$base_temp" && "$base_temp" != "/" && ! "$base_temp" =~ ^(/cygdrive/|/mnt/|/)[a-zA-Z]$ ]]; then
        find "$base_temp" -maxdepth 1 -type d -name "${prefix}*" -mtime +1 -exec rm -rf {} + 2> /dev/null || true
    fi

    local workdir
    workdir=$(mktemp -d "${base_temp}/${prefix}XXXXXX") || return 1
    [[ -n "$workdir" && -d "$workdir" ]] || return 1
    printf '%s' "$workdir"
}

# init_exec_workspace <prefix> <source_cyg> <target_cyg> <dry_run> [update_source]
# Creates target/source/temp directories when not in dry-run mode, prunes stale
# workspaces older than 1 day, and populates EXEC_WORKSPACE.
init_exec_workspace() {
    local prefix="$1"
    local source_cyg="$2"
    local target_cyg="$3"
    local dry_run="$4"
    local update_source="${5:-true}"

    [[ "$dry_run" == false ]] || return 0

    [[ -n "$target_cyg" ]] && mkdir -p "$target_cyg"
    if [[ "$update_source" == true && -n "$source_cyg" ]]; then
        mkdir -p "$source_cyg"
    fi

    EXEC_WORKSPACE=$(create_temp_workdir "$prefix") || true
    if [[ -z "$EXEC_WORKSPACE" || ! -d "$EXEC_WORKSPACE" ]]; then
        log_error "Failed to create temporary workspace in ${TEMP_ROOT_PATH:-${TEMP_ROOT_CYG:-/tmp}}"
        exit 1
    fi
    log_info "Execution workspace initialized: $(enforce_drive_path "$EXEC_WORKSPACE")"
}

# print_action_banner <title> [key val ...]
# Prints a uniform action header block with padded key/value pairs.
print_action_banner() {
    local title="$1"
    shift
    echo "=============================================================================="
    echo " $title"
    echo "=============================================================================="
    while [[ $# -ge 2 ]]; do
        printf " %-15s: %s\n" "$1" "$2"
        shift 2
    done
    echo "=============================================================================="
}

# print_packaging_summary <title> <total> <updated> <skipped> <errors>
print_packaging_summary() {
    local title="$1"
    local total="$2"
    local updated="$3"
    local skipped="$4"
    local errors="$5"

    echo ""
    echo "=============================================================================="
    echo " $title"
    echo "=============================================================================="
    echo " Total packages targeted: $total"
    echo " Updated & Packaged     : $updated"
    echo " Up to date (Skipped)   : $skipped"
    echo " Errors / Warnings      : $errors"
    echo "=============================================================================="
}

# ------------------------------------------------------------------------------
# Section 11: WSL / Native-Linux Permission-Preserving Archive Repacker
# ------------------------------------------------------------------------------
# repack_tar_gz_to_xz_preserving_perms <src_tar_gz> <dest_tar_xz> <pack_target> [transform_cmds]
# Extracts src_tar_gz on a native Linux ext4 filesystem (/tmp) to preserve POSIX
# permissions (including setuid bits such as chrome-sandbox 4755 and symlinks),
# executes optional transform_cmds inside the unpack directory, and compresses
# pack_target into dest_tar_xz using root/root ownership and xz -9 -T0.
# On Cygwin/MSYS2, delegates cleanly to wsl.exe.
repack_tar_gz_to_xz_preserving_perms() {
    local src_tar_gz="$1"
    local dest_tar_xz="$2"
    local pack_target="$3"
    local transform_cmds="${4:-}"

    [[ -f "$src_tar_gz" ]] || {
        log_error "Source archive not found: $src_tar_gz"
        return 1
    }
    safe_rm_f "$dest_tar_xz"

    # Inner Linux shell script executed directly (linux/wsl) or via wsl.exe (cygwin/msys2)
    # shellcheck disable=SC2016
    local inner_script='
set -euo pipefail
in_file="$1"
out_file="$2"
pack_target="$3"
transform_cmds="$4"

lx_work=$(mktemp -d /tmp/pkg_lnx_XXXXXX)
cleanup_lx() { rm -rf "$lx_work"; }
trap cleanup_lx EXIT

mkdir -p "$lx_work/unpack"
if [[ "$in_file" == "-" ]]; then
    tar --force-local -xzpf - -C "$lx_work/unpack"
else
    tar --force-local -xzpf "$in_file" -C "$lx_work/unpack"
fi

if [[ -n "$transform_cmds" ]]; then
    (cd "$lx_work/unpack" && eval "$transform_cmds") >&2
fi

tar --force-local --owner=0 --group=0 --numeric-owner -cf - -C "$lx_work/unpack" "$pack_target" | xz -9 -T0 > "$lx_work/out.tar.xz"
tar --force-local -tJf "$lx_work/out.tar.xz" >/dev/null

if [[ "$out_file" == "-" ]]; then
    cat "$lx_work/out.tar.xz"
else
    cp -f "$lx_work/out.tar.xz" "$out_file"
fi
'

    if ! is_windows_platform; then
        bash -c "$inner_script" _ "$src_tar_gz" "$dest_tar_xz" "$pack_target" "$transform_cmds"
        return $?
    fi

    if ! command -v wsl.exe > /dev/null 2>&1; then
        log_error "wsl.exe not found; required on Windows to preserve Linux archive permissions."
        return 1
    fi

    local wsl_src wsl_dst_dir
    wsl_src=$(to_wsl_path "$src_tar_gz" || true)
    wsl_dst_dir=$(to_wsl_path "$(dirname "$dest_tar_xz")" || true)

    if [[ -n "$wsl_src" && -n "$wsl_dst_dir" ]] &&
        wsl.exe -e test -f "$wsl_src" < /dev/null 2> /dev/null &&
        wsl.exe -e test -d "$wsl_dst_dir" < /dev/null 2> /dev/null; then
        local wsl_dst
        wsl_dst="${wsl_dst_dir}/$(basename "$dest_tar_xz")"
        if ! wsl.exe -e bash -c "$inner_script" _ "$wsl_src" "$wsl_dst" "$pack_target" "$transform_cmds" < /dev/null; then
            log_error "WSL archive recompression failed for $(basename "$dest_tar_xz")"
            safe_rm_f "$dest_tar_xz"
            return 1
        fi
    else
        # Fallback when temp drive is not mounted inside WSL: stream via stdin/stdout
        if ! wsl.exe -e bash -c "$inner_script" _ "-" "-" "$pack_target" "$transform_cmds" < "$src_tar_gz" > "$dest_tar_xz"; then
            log_error "WSL streaming archive recompression failed for $(basename "$dest_tar_xz")"
            safe_rm_f "$dest_tar_xz"
            return 1
        fi
    fi

    if [[ ! -s "$dest_tar_xz" ]] || ! verify_tar_xz_integrity "$dest_tar_xz"; then
        log_error "Corrupted xz archive generated: $(basename "$dest_tar_xz")"
        safe_rm_f "$dest_tar_xz"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Section 12: Unified Dual-Platform Packaging Pipeline
# ------------------------------------------------------------------------------
# _run_single_platform_stage <platform_label> <app_key> <ver> <suffix> <ext> \
#   <local_file> <build_flag> <url> <hash> <hash_algo> <raw_name> <transform_fn> <dry_run_msg>
_run_single_platform_stage() {
    local platform_label="$1"
    local app_key="$2"
    local remote_ver="$3"
    local suffix="$4"
    local ext="$5"
    local local_file="$6"
    local do_build="$7"
    local url="$8"
    local expected_hash="$9"
    local hash_algo="${10}"
    local raw_name="${11}"
    local transform_fn="${12}"
    local dry_run_msg="${13}"

    if [[ "$do_build" != true ]]; then
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        if [[ -n "$local_file" ]]; then
            purge_obsolete_packages "$app_key" "$suffix" "$(basename "$local_file")" "$SOURCE_CYG" "$TARGET_CYG" "$DRY_RUN"
        fi
        return 0
    fi

    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    local pkg_name="${app_key}-${remote_ver}-${suffix}.${ext}"
    log_info "Processing ${platform_label} package: $pkg_name"

    if [[ "$DRY_RUN" == true ]]; then
        log_ok "[DRY-RUN] Would download: $url"
        if [[ -n "$dry_run_msg" ]]; then
            log_ok "[DRY-RUN] $dry_run_msg"
        fi
        atomic_stage_package "" "$pkg_name" "$app_key" "$suffix" "$SOURCE_CYG" "$TARGET_CYG" "$DRY_RUN"
        UPDATED_COUNT=$((UPDATED_COUNT + 1))
        return 0
    fi

    local raw_path="${CURRENT_BUILD_DIR}/${raw_name}"
    local out_path="${CURRENT_BUILD_DIR}/${pkg_name}"

    log_info "Downloading ${platform_label} asset..."
    if ! download_asset "$url" "$raw_path" "$expected_hash" "$hash_algo"; then
        ERROR_COUNT=$((ERROR_COUNT + 1))
        return 1
    fi

    if ! "$transform_fn" "$raw_path" "$CURRENT_BUILD_DIR" "$out_path" "$remote_ver"; then
        ERROR_COUNT=$((ERROR_COUNT + 1))
        return 1
    fi

    if [[ "$ext" == "zip" ]]; then
        if ! verify_zip_integrity "$out_path"; then
            log_error "Corrupted zip archive generated: $pkg_name"
            ERROR_COUNT=$((ERROR_COUNT + 1))
            return 1
        fi
    else
        if ! verify_tar_xz_integrity "$out_path"; then
            log_error "Corrupted xz archive generated: $pkg_name"
            ERROR_COUNT=$((ERROR_COUNT + 1))
            return 1
        fi
    fi

    if atomic_stage_package "$out_path" "$pkg_name" "$app_key" "$suffix" "$SOURCE_CYG" "$TARGET_CYG" "$DRY_RUN"; then
        UPDATED_COUNT=$((UPDATED_COUNT + 1))
        return 0
    else
        ERROR_COUNT=$((ERROR_COUNT + 1))
        return 1
    fi
}

# run_dual_platform_package <display_name> <app_key> <remote_ver> \
#   <win_suffix> <win_url> <win_hash> <win_algo> <win_raw_name> <win_transform_fn> <win_dry_msg> \
#   <lnx_suffix> <lnx_url> <lnx_hash> <lnx_algo> <lnx_raw_name> <lnx_transform_fn> <lnx_dry_msg>
run_dual_platform_package() {
    local display_name="$1"
    local app_key="$2"
    local remote_ver="$3"
    local win_suffix="$4"
    local win_url="$5"
    local win_hash="$6"
    local win_algo="$7"
    local win_raw_name="$8"
    local win_transform_fn="$9"
    local win_dry_msg="${10}"
    local lnx_suffix="${11}"
    local lnx_url="${12}"
    local lnx_hash="${13}"
    local lnx_algo="${14}"
    local lnx_raw_name="${15}"
    local lnx_transform_fn="${16}"
    local lnx_dry_msg="${17}"

    local win_local_ver win_local_file lnx_local_ver lnx_local_file
    read -r win_local_ver win_local_file < <(find_local_version "$SOURCE_CYG" "$app_key" "$win_suffix" "zip")
    log_info "Local Windows version: ${win_local_ver} (${win_local_file:-none})"

    local build_win=false
    if [[ "$FORCE_REPACKAGE" == true ]] || is_version_newer "$remote_ver" "$win_local_ver"; then
        build_win=true
    fi

    read -r lnx_local_ver lnx_local_file < <(find_local_version "$SOURCE_CYG" "$app_key" "$lnx_suffix" "tar.xz")
    log_info "Local Linux version  : ${lnx_local_ver} (${lnx_local_file:-none})"

    local build_lnx=false
    if [[ "$FORCE_REPACKAGE" == true ]] || is_version_newer "$remote_ver" "$lnx_local_ver"; then
        build_lnx=true
    fi

    if [[ "$build_win" == false && "$build_lnx" == false ]]; then
        log_info "${display_name} is up to date."
        [[ -n "$win_local_file" ]] && purge_obsolete_packages "$app_key" "$win_suffix" "$(basename "$win_local_file")" "$SOURCE_CYG" "$TARGET_CYG" "$DRY_RUN"
        [[ -n "$lnx_local_file" ]] && purge_obsolete_packages "$app_key" "$lnx_suffix" "$(basename "$lnx_local_file")" "$SOURCE_CYG" "$TARGET_CYG" "$DRY_RUN"
        SKIPPED_COUNT=$((SKIPPED_COUNT + 2))
        return 0
    fi

    if [[ "$DRY_RUN" == false ]]; then
        CURRENT_BUILD_DIR=$(mktemp -d "${EXEC_WORKSPACE}/${app_key}_XXXXXX")
    fi

    local rc=0
    _run_single_platform_stage "Windows" "$app_key" "$remote_ver" "$win_suffix" "zip" \
        "$win_local_file" "$build_win" "$win_url" "$win_hash" "$win_algo" \
        "$win_raw_name" "$win_transform_fn" "$win_dry_msg" || rc=1

    _run_single_platform_stage "Linux" "$app_key" "$remote_ver" "$lnx_suffix" "tar.xz" \
        "$lnx_local_file" "$build_lnx" "$lnx_url" "$lnx_hash" "$lnx_algo" \
        "$lnx_raw_name" "$lnx_transform_fn" "$lnx_dry_msg" || rc=1

    if [[ -n "$CURRENT_BUILD_DIR" && -d "$CURRENT_BUILD_DIR" ]]; then
        safe_rm_rf "$CURRENT_BUILD_DIR"
        CURRENT_BUILD_DIR=""
    fi

    return $rc
}

# ------------------------------------------------------------------------------
# Section 13: Permission-Preserving Directory Repacker & GitHub Release Engine
# ------------------------------------------------------------------------------
# repack_directory_to_tar_xz_preserving_perms <stage_dir> <dest_tar_xz> [strip_base]
# Packs <stage_dir> into <dest_tar_xz> (xz -9 -T0, root/root owner). On Windows,
# routes through WSL ext4 when available to preserve 0755 bits and symlinks, with
# an explicit local GNU tar fallback applying a+rX,u+w.
repack_directory_to_tar_xz_preserving_perms() {
    local stage_dir="$1" dest_tar_xz="$2" strip_base="${3:-true}"
    [[ -d "$stage_dir" ]] || return 1
    safe_rm_f "$dest_tar_xz"
    mkdir -p "$(dirname "$dest_tar_xz")" || return 1

    if ! is_windows_platform; then
        [[ "$strip_base" == true ]] && strip_base_directory "$stage_dir"
        repack_directory_to_tar_xz "$stage_dir" "$dest_tar_xz"
        return $?
    fi

    if command -v wsl.exe > /dev/null 2>&1; then
        local src_tar="${stage_dir}_raw.tar"
        safe_rm_f "$src_tar"
        if (
            cd "$stage_dir" || exit 1
            shopt -s nullglob dotglob
            local items=(*)
            shopt -u nullglob dotglob
            if [[ ${#items[@]} -gt 0 ]]; then
                tar --force-local -cf "$src_tar" "${items[@]}"
            else
                tar --force-local -cf "$src_tar" --files-from /dev/null
            fi
        ); then
            # shellcheck disable=SC2016
            local inner='
set -euo pipefail
strip_base="$1"
lx_work=$(mktemp -d /tmp/pkg_dir_lnx_XXXXXX)
trap "rm -rf \"$lx_work\"" EXIT
mkdir -p "$lx_work/s"
tar --force-local -xf - -C "$lx_work/s"
if [[ "$strip_base" == "true" ]]; then
    shopt -s nullglob dotglob
    top=("$lx_work/s"/*)
    shopt -u nullglob dotglob
    if [[ ${#top[@]} -eq 1 && -d "${top[0]}" ]]; then
        mv "${top[0]}" "$lx_work/m"
        rm -rf "$lx_work/s"
        mv "$lx_work/m" "$lx_work/s"
    fi
fi
find "$lx_work/s" -type f \
    ! -iname "*.txt" ! -iname "*.md" ! -iname "*.json" ! -iname "*.yml" ! -iname "*.yaml" \
    ! -iname "*.snapshot" ! -iname "*.jar" ! -iname "*.bat" ! -iname "*.cmd" ! -iname "*.ps1" \
    ! -iname "*.png" ! -iname "*.svg" ! -iname "*.css" ! -iname "*.map" ! -iname "*.wasm" ! -iname "*.xml" \
    ! -iname "*.so" ! -iname "*.so.*" ! -iname "LICENSE*" ! -iname "README*" ! -iname "NOTICE*" \
    -exec chmod a+rx {} + 2>/dev/null || true
find "$lx_work/s" -depth \( -type f -o -type d \) -exec touch {} + 2>/dev/null || true
shopt -s nullglob dotglob
pack_items=("$lx_work/s"/*)
shopt -u nullglob dotglob
if [[ ${#pack_items[@]} -gt 0 ]]; then
    tar --force-local --owner=0 --group=0 --numeric-owner -cf - -C "$lx_work/s" . | xz -9 -T0
else
    tar --force-local --owner=0 --group=0 --numeric-owner -cf - --files-from /dev/null | xz -9 -T0
fi
'
            if wsl.exe -e bash -c "$inner" _ "$strip_base" < "$src_tar" > "$dest_tar_xz" 2> /dev/null &&
                [[ -s "$dest_tar_xz" ]] && verify_tar_xz_integrity "$dest_tar_xz"; then
                safe_rm_f "$src_tar"
                return 0
            fi
        fi
        safe_rm_f "$src_tar"
        safe_rm_f "$dest_tar_xz"
    fi

    # Fallback directly with local GNU tar (applying a+rX,u+w permissions)
    [[ "$strip_base" == true ]] && strip_base_directory "$stage_dir"
    normalize_directory_timestamps "$stage_dir"
    if ! (
        cd "$stage_dir" || exit 1
        shopt -s nullglob dotglob
        local items=(*)
        shopt -u nullglob dotglob
        if [[ ${#items[@]} -gt 0 ]]; then
            tar --force-local --owner=0 --group=0 --numeric-owner --mode='a+rX,u+w' -cf - "${items[@]}" | xz -9 -T0 > "$dest_tar_xz"
        else
            tar --force-local --owner=0 --group=0 --numeric-owner --mode='a+rX,u+w' -cf - --files-from /dev/null | xz -9 -T0 > "$dest_tar_xz"
        fi
    ); then
        safe_rm_f "$dest_tar_xz"
        return 1
    fi
    if ! verify_tar_xz_integrity "$dest_tar_xz"; then
        safe_rm_f "$dest_tar_xz"
        return 1
    fi
    return 0
}

declare -A _GH_RELEASE_CACHE=()

# gh_fetch_releases_json <owner/repo> [per_page] [token] [user_agent]
gh_fetch_releases_json() {
    local repo="$1" per_page="${2:-10}" token="${3:-${GITHUB_TOKEN:-}}" ua="${4:-client-packager}"
    local cache_key="${repo}:${per_page}"

    if [[ -n "${_GH_RELEASE_CACHE[$cache_key]:-}" ]]; then
        printf '%s' "${_GH_RELEASE_CACHE[$cache_key]}"
        return 0
    fi

    local url="https://api.github.com/repos/${repo}/releases?per_page=${per_page}"
    if [[ -z "$token" ]] && command -v gh > /dev/null 2>&1; then
        token=$(gh auth token 2> /dev/null || true)
        GITHUB_TOKEN="$token"
    fi
    local auth_header=()
    [[ -n "$token" ]] && auth_header=(-H "Authorization: Bearer ${token}")

    local tmp_base="${EXEC_WORKSPACE:-${TEMP_ROOT_CYG:-}}"
    if [[ -z "$tmp_base" || ! -d "$tmp_base" ]]; then
        tmp_base=$(detect_temp_root)
    fi

    local response err_file rc=0
    err_file=$(mktemp "${tmp_base}/gh_api_err.XXXXXX")
    _CURRENT_TMP_FILE="$err_file"
    response=$(curl -fsSL --connect-timeout 10 --max-time 30 --retry 3 --retry-delay 2 \
        "${auth_header[@]}" \
        -H "Accept: application/vnd.github+json" \
        -H "User-Agent: ${ua}" \
        "$url" 2> "$err_file") || rc=$?
    local err_msg=""
    err_msg=$(tr '\r\n' '  ' < "$err_file" 2> /dev/null || true)
    rm -f "$err_file" 2> /dev/null || true
    _CURRENT_TMP_FILE=""

    if [[ $rc -ne 0 || -z "$response" ]]; then
        log_warn "GitHub API request failed (exit=${rc}) for ${repo}: ${err_msg:-empty response}"
        return 1
    fi

    if [[ "$response" == *"API rate limit exceeded"* ]]; then
        log_error "GitHub API rate limit exceeded for ${repo}. Provide --token or run 'gh auth login'."
        return 2
    fi

    _GH_RELEASE_CACHE["$cache_key"]="$response"
    printf '%s' "$response"
}

# gh_resolve_release <owner/repo> <tool_key> [tag_prefix] [token]
# Prints "<remote_ver>\t<tag_name>\t<single_release_json>". Returns 2 on rate limit.
gh_resolve_release() {
    local repo="$1" tool="$2" tag_prefix="${3:-}" token="${4:-${GITHUB_TOKEN:-}}"
    local per_page=8
    [[ -n "$tag_prefix" ]] && per_page=30

    local rels_json rc=0
    rels_json=$(gh_fetch_releases_json "$repo" "$per_page" "$token") || rc=$?
    if [[ $rc -ne 0 || -z "$rels_json" ]]; then
        return "$rc"
    fi

    # Prefer latest non-prerelease matching optional tag prefix; fall back to prerelease if none exist.
    local rel_obj=""
    rel_obj=$(jq -c --arg pfx "$tag_prefix" '
        [ .[]? | select((.draft | not) and (($pfx == "") or (.tag_name | startswith($pfx)))) ] as $cand
        | (($cand | map(select(.prerelease | not)) | first) // ($cand | first)) // empty
    ' <<< "$rels_json" 2> /dev/null || true)

    if [[ -z "$rel_obj" || "$rel_obj" == "null" ]]; then
        log_warn "No matching release found for ${tool} (${repo}, prefix='${tag_prefix}')"
        return 1
    fi

    local tag_name ver
    tag_name=$(jq -r '.tag_name // empty' <<< "$rel_obj")
    ver="$tag_name"
    [[ -n "$tag_prefix" ]] && ver="${ver#"$tag_prefix"}"
    ver="${ver#v}"
    ver="${ver#V}"

    if [[ ! "$ver" =~ ^[0-9]+(\.[0-9]+)+([A-Za-z0-9._-]*)$ ]]; then
        log_warn "Could not parse semantic version from tag '${tag_name}' for ${tool}"
        return 1
    fi

    printf '%s\t%s\t%s\n' "$ver" "$tag_name" "$rel_obj"
}

# gh_find_asset <release_json> <ere_include> [ere_exclude]
# Prints "<name>\t<download_url>\t<sha256_from_digest>" for the first matching asset.
gh_find_asset() {
    local rel_json="$1" inc="$2" exc="${3:-^$}"
    jq -r --arg inc "$inc" --arg exc "$exc" '
        [ .assets[]?
          | select(.name | test($inc; "i"))
          | select(.name | test($exc; "i") | not)
          | select(.name | test("[.](sig|asc|sigstore[.]json|sbom|sbom[.]json|provenance[.]json|pem|sha256|sha256sum|txt|json|xml|msi)$"; "i") | not)
        ] | first // empty
        | "\(.name)\t\(.browser_download_url)\t\((.digest // "") | sub("^sha256:"; ""))"
    ' <<< "$rel_json" 2> /dev/null || true
}

# gh_fetch_release_checksums <release_json> <cache_dir>
gh_fetch_release_checksums() {
    local rel_json="$1" cache_dir="$2"
    local sum_file="${cache_dir}/_checksums.txt"
    [[ -f "$sum_file" ]] && { cat "$sum_file"; return 0; }

    local sum_url
    sum_url=$(jq -r '
        [ .assets[]?
          | select(.name | test("(checksums([.]txt|[.]sha256)?|sha256[_.-]?sums?([.]txt)?|SHA256SUMS)$"; "i"))
          | select(.name | test("[.](sig|asc|sigstore[.]json|pem)$"; "i") | not)
        ] | first // empty | .browser_download_url // empty
    ' <<< "$rel_json" 2> /dev/null || true)

    if [[ -n "$sum_url" ]]; then
        if curl -fsSL --connect-timeout 10 --max-time 20 --retry 2 -o "$sum_file" "$sum_url" 2> /dev/null; then
            cat "$sum_file"
            return 0
        fi
    fi
    return 1
}

# gh_lookup_asset_sha256 <release_json> <asset_name> <digest_hint> <cache_dir>
gh_lookup_asset_sha256() {
    local rel_json="$1" asset_name="$2" digest_hint="$3" cache_dir="$4"
    if [[ "$digest_hint" =~ ^[0-9a-fA-F]{64}$ ]]; then
        printf '%s' "${digest_hint,,}"
        return 0
    fi

    local sidecar_url
    sidecar_url=$(jq -r --arg n "${asset_name}.sha256" '
        [ .assets[]? | select(.name == $n) ] | first // empty | .browser_download_url // empty
    ' <<< "$rel_json" 2> /dev/null || true)
    if [[ -n "$sidecar_url" ]]; then
        local sc_body
        sc_body=$(curl -fsSL --connect-timeout 10 --max-time 15 --retry 2 "$sidecar_url" 2> /dev/null || true)
        if [[ "$sc_body" =~ ([0-9a-fA-F]{64}) ]]; then
            printf '%s' "${BASH_REMATCH[1],,}"
            return 0
        fi
    fi

    local sum_text
    sum_text=$(gh_fetch_release_checksums "$rel_json" "$cache_dir" || true)
    if [[ -n "$sum_text" ]]; then
        # Match exact filename in standard "<sha256> [*| ]<name>" or "<sha256> <dir>/<name>" formats
        local matched_line
        matched_line=$(awk -v target="$asset_name" '
            { sub(/\r$/, "", $0) }
            NF >= 2 {
                fname = $2
                sub(/^\*/, "", fname)
                n = split(fname, parts, "/")
                if (fname == target || parts[n] == target) {
                    print $1
                    exit
                }
            }
        ' <<< "$sum_text" || true)
        if [[ "$matched_line" =~ ^([0-9a-fA-F]{64})$ ]]; then
            printf '%s' "${BASH_REMATCH[1],,}"
            return 0
        fi
    fi
    return 0
}

# gh_download_verified_asset <release_json> <label> <name> <url> <digest_hint> <dest_file> <cache_dir>
gh_download_verified_asset() {
    local rel_json="$1" label="$2" name="$3" url="$4" digest="$5" dest="$6" cache_dir="$7"
    local sha
    sha=$(gh_lookup_asset_sha256 "$rel_json" "$name" "$digest" "$cache_dir")
    log_info "Downloading ${label}: ${name}..."
    download_asset "$url" "$dest" "$sha" "sha256"
}
