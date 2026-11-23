#!/usr/bin/env bash
# ==============================================================================
# lib/pkg_core.sh
#
# Core shared primitives for client packaging and upgrade tools:
#   - Host platform detection + MSYS2/Cygwin /usr/bin:/bin PATH guard
#   - ANSI colored logging (with VERBOSE-gated log_debug & optional stderr routing)
#   - Dual-layer Windows/POSIX/WSL path engine + traversal/root validation
#   - Defensive filesystem deletion (safe_rm_rf / safe_rm_f)
#   - Temp workspace lifecycle, race-free mkdir locking, and single-fire traps
#   - CLI option validation, tool verification, CSV lookup, and UI banners
# ==============================================================================
# shellcheck disable=SC2034

[[ -n "${_PKG_CORE_SH_LOADED:-}" ]] && return 0
_PKG_CORE_SH_LOADED=1

# ------------------------------------------------------------------------------
# Section 1: Platform Detection & PATH Guard
# ------------------------------------------------------------------------------
# detect_platform
# Outputs host shell environment tag: cygwin | msys2 | wsl | linux.
# On MSYS2/Cygwin, ensures /usr/bin:/bin precedes Windows System32 tools
# so GNU/POSIX binaries always win over mixed Windows PATH shadows.
detect_platform() {
    if [[ -d /usr/bin && "${PATH}:" != "/usr/bin:/bin:"* ]]; then
        export PATH="/usr/bin:/bin:${PATH}"
    fi

    local os_hint="${OSTYPE:-}"
    local uname_out
    uname_out="$(uname -s 2> /dev/null || echo "unknown")"
    case "${os_hint,,}:${uname_out,,}" in
        cygwin*:* | *:cygwin*)
            echo "cygwin"
            ;;
        msys*:* | mingw*:* | *:msys* | *:mingw* | *:windows*)
            echo "msys2"
            ;;
        linux*:* | *:linux*)
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

is_windows_platform() {
    case "$PLATFORM" in
        cygwin | msys2) return 0 ;;
        *) return 1 ;;
    esac
}

get_target_os() {
    if is_windows_platform; then
        echo "windows"
    else
        echo "linux"
    fi
}

# ------------------------------------------------------------------------------
# Section 2: Terminal Formatting & Colored Logging
# ------------------------------------------------------------------------------
_LOG_COLORS_FORCED_PLAIN=0
_COLORS_STDERR_MODE="${LOG_INFO_TO_STDERR:-0}"

_init_colors() {
    local force_plain="${1:-0}"
    [[ "$force_plain" == "1" ]] && _LOG_COLORS_FORCED_PLAIN=1

    local color_fd=1
    [[ "${LOG_INFO_TO_STDERR:-0}" == "1" ]] && color_fd=2
    if [[ "${_LOG_COLORS_FORCED_PLAIN}" == "0" && -t "$color_fd" ]]; then
        C_RESET="\033[0m"
        C_RED="\033[1;31m"
        C_GREEN="\033[1;32m"
        C_YELLOW="\033[1;33m"
        C_BLUE="\033[1;34m"
        C_CYAN="\033[1;36m"
        C_DIM="\033[0;37m"
        C_BOLD="\033[1m"
    else
        C_RESET=""
        C_RED=""
        C_GREEN=""
        C_YELLOW=""
        C_BLUE=""
        C_CYAN=""
        C_DIM=""
        C_BOLD=""
    fi
    _COLORS_STDERR_MODE="${LOG_INFO_TO_STDERR:-0}"
}
_init_colors

# _log_emit <stream:1|2> <formatted_message>
_log_emit() {
    if [[ "${_COLORS_STDERR_MODE:-}" != "${LOG_INFO_TO_STDERR:-0}" ]]; then
        _init_colors
    fi
    local stream="$1"
    shift
    if [[ "$stream" == "2" ]]; then
        echo -e "$*" >&2
    else
        echo -e "$*"
    fi
}

_info_stream() {
    if [[ "${LOG_INFO_TO_STDERR:-0}" == "1" ]]; then
        echo "2"
    else
        echo "1"
    fi
}

log_info()  { _log_emit "$(_info_stream)" "${C_CYAN}[INFO]${C_RESET} $*"; }
log_ok()    { _log_emit "$(_info_stream)" "${C_GREEN}[OK]${C_RESET} $*"; }
log_step()  { _log_emit "$(_info_stream)" "${C_BLUE}==>${C_RESET} ${C_BOLD}$*${C_RESET}"; }
log_warn()  { _log_emit "2" "${C_YELLOW}[WARN]${C_RESET} $*"; }
log_error() { _log_emit "2" "${C_RED}[ERROR]${C_RESET} $*"; }
log_debug() {
    if [[ "${VERBOSE:-0}" == "1" || "${VERBOSE:-false}" == "true" ]]; then
        _log_emit "2" "${C_DIM}[DEBUG]${C_RESET} $*"
    fi
}

# ------------------------------------------------------------------------------
# Section 3: Dual-Layer Path Engine & Directory Validation
# ------------------------------------------------------------------------------
strip_trailing_slashes() {
    local p="$1"
    while [[ ${#p} -gt 1 && "$p" == */ ]]; do
        p="${p%/}"
    done
    printf '%s' "$p"
}

# enforce_drive_path <path>
# Normalizes paths to canonical mixed drive-letter format (e.g. "c:/path/dir")
# for consistent user logging, table rendering, and configuration storage.
enforce_drive_path() {
    local p="$1"
    [[ -z "$p" ]] && return 0

    p="${p//\\//}"

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
# Converts Windows drive-letter/backslash paths to native POSIX mount paths
# (/cygdrive/c/..., /c/..., /mnt/c/...).
to_posix_path() {
    local p="$1"
    [[ -z "$p" ]] && return 0

    if command -v cygpath > /dev/null 2>&1; then
        cygpath -u "$p"
        return 0
    fi

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
}

# to_syspath <path>
# Converts a POSIX shell path to native Windows backslash format on Windows hosts.
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

# to_mixed_path <path>
# Converts any path to native Windows forward-slash format (<drive>:/path) via
# cygpath -m on Windows (suitable for native Windows binaries like 7z.exe).
to_mixed_path() {
    local p="${1:-}"
    [[ -z "$p" ]] && return 0

    local clean_p="${p//\\//}"
    if is_windows_platform && command -v cygpath > /dev/null 2>&1; then
        cygpath -m "$clean_p" 2> /dev/null || enforce_drive_path "$clean_p"
    else
        enforce_drive_path "$clean_p"
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

# _is_unsafe_system_path <posix_path>
_is_unsafe_system_path() {
    local p="$1"
    case "$p" in
        "" | "/" | "." | ".." | "/tmp" | "/var" | "/var/tmp" | "/cygdrive" | "/mnt" | "/media" | \
        /bin | /usr | /usr/* | /etc | /lib | /lib64 | /sbin | /home | /root | /boot | /dev | /proc | /sys | /opt | /srv)
            return 0
            ;;
        /[a-zA-Z] | /cygdrive/[a-zA-Z] | /mnt/[a-zA-Z] | /media/[a-zA-Z])
            return 0
            ;;
        /[cC]/[wW][iI][nN][dD][oO][wW][sS] | /[cC]/[wW][iI][nN][dD][oO][wW][sS]/* | \
        /mnt/[cC]/[wW][iI][nN][dD][oO][wW][sS] | /mnt/[cC]/[wW][iI][nN][dD][oO][wW][sS]/* | \
        /cygdrive/[cC]/[wW][iI][nN][dD][oO][wW][sS] | /cygdrive/[cC]/[wW][iI][nN][dD][oO][wW][sS]/*)
            return 0
            ;;
    esac
    return 1
}

# validate_safe_dir <label> <raw_path>
# Rejects empty values, '..' traversal segments, relative targets, system dirs,
# drive roots, and C:\Windows. Prints canonical normalized POSIX path on stdout.
validate_safe_dir() {
    local label="$1"
    local raw="$2"

    if [[ -z "${raw// /}" ]]; then
        log_error "${label} path must not be empty."
        return 1
    fi

    if [[ "$raw" =~ (^|[\\/])\.\.($|[\\/]) ]]; then
        log_error "${label} path must not contain '..' segments: ${raw}"
        return 1
    fi

    local posix
    posix="$(to_posix_path "$raw")"
    posix="$(strip_trailing_slashes "$posix")"

    if command -v realpath > /dev/null 2>&1; then
        posix="$(realpath -m "$posix")"
        posix="$(strip_trailing_slashes "$posix")"
    fi

    if [[ "$posix" != /* ]]; then
        log_error "${label} must resolve to an absolute path: ${raw} -> ${posix}"
        return 1
    fi

    if _is_unsafe_system_path "$posix"; then
        log_error "Refusing unsafe ${label} directory: ${posix}"
        return 1
    fi

    printf '%s\n' "$posix"
}

# ------------------------------------------------------------------------------
# Section 4: Defensive Filesystem Controls
# ------------------------------------------------------------------------------
# _fast_win_rmdir <posix_dir>
# Renames directory and delegates removal to native Windows rmdir in background
# for huge directory trees on NTFS; returns 1 to let caller fall back to rm -rf.
_fast_win_rmdir() {
    local dir_path="$1"
    is_windows_platform || return 1
    command -v cmd.exe > /dev/null 2>&1 || return 1

    local trash_dir="${dir_path}.trash.$$.${RANDOM}"
    mv -f -- "$dir_path" "$trash_dir" 2> /dev/null || return 1

    local win_trash
    win_trash="$(to_syspath "$trash_dir" 2> /dev/null || true)"
    [[ -n "$win_trash" ]] || {
        rm -rf -- "$trash_dir" 2> /dev/null || true
        return 0
    }

    if [[ "$PLATFORM" == "cygwin" ]]; then
        cmd.exe /c rmdir /s /q "$win_trash" > /dev/null 2>&1 &
    else
        MSYS2_ARG_CONV_EXCL="*" cmd.exe /c rmdir /s /q "$win_trash" > /dev/null 2>&1 &
    fi
    return 0
}

# safe_rm_rf [--fast-win] <target_directory>
# Rejects traversal segments, empty strings, drive roots, and system paths.
safe_rm_rf() {
    local fast_win=0
    if [[ "${1:-}" == "--fast-win" ]]; then
        fast_win=1
        shift
    fi
    local target="${1:-}"
    [[ -z "${target// /}" ]] && return 0

    if [[ "$target" =~ (^|[\\/])\.\.($|[\\/]) ]]; then
        log_warn "Refusing traversal path deletion: '${target}'"
        return 1
    fi

    local norm canon
    norm=$(to_posix_path "$target")
    norm=$(strip_trailing_slashes "$norm")

    if _is_unsafe_system_path "$norm"; then
        log_warn "Refusing unsafe directory deletion: '${norm}'"
        return 1
    fi

    if command -v realpath > /dev/null 2>&1; then
        canon="$(realpath -m "$norm" 2> /dev/null || true)"
        canon="$(strip_trailing_slashes "$canon")"
        if [[ -n "$canon" ]] && _is_unsafe_system_path "$canon"; then
            log_warn "Refusing unsafe canonical deletion target: '${canon}'"
            return 1
        fi
    fi

    if [[ -d "$norm" && ! -L "$norm" ]]; then
        if [[ "$fast_win" -eq 1 ]] && _fast_win_rmdir "$norm"; then
            return 0
        fi
        rm -rf -- "$norm" 2> /dev/null || true
    elif [[ -L "$norm" ]]; then
        rm -f -- "$norm" 2> /dev/null || true
    fi
}

# safe_rm_f <target_file>
# Defensive single-file deletion with bounds checking.
safe_rm_f() {
    local target="$1"
    [[ -z "${target// /}" ]] && return 0

    if [[ "$target" =~ (^|[\\/])\.\.($|[\\/]) ]]; then
        return 1
    fi

    local norm
    norm=$(to_posix_path "$target")
    norm=$(strip_trailing_slashes "$norm")

    if _is_unsafe_system_path "$norm"; then
        return 1
    fi

    if [[ -f "$norm" || -L "$norm" ]]; then
        rm -f -- "$norm" 2> /dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# Section 5: Temp Workspace Lifecycle, Atomic Locking & Signal Traps
# ------------------------------------------------------------------------------
detect_temp_root() {
    local candidates=()
    [[ -n "${TEMP:-}" ]] && candidates+=("$TEMP")
    [[ -n "${TMPDIR:-}" ]] && candidates+=("$TMPDIR")
    [[ -n "${TMP:-}" ]] && candidates+=("$TMP")
    candidates+=("/tmp")

    local dir posix_dir
    for dir in "${candidates[@]}"; do
        posix_dir=$(to_posix_path "$dir")
        if [[ -d "$posix_dir" && -w "$posix_dir" ]]; then
            echo "$posix_dir"
            return 0
        fi
    done

    mkdir -p "/tmp" 2> /dev/null || true
    echo "/tmp"
}

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

# _hash_scope_key <key>
_hash_scope_key() {
    local raw="$1"
    if command -v sha256sum > /dev/null 2>&1; then
        printf '%s' "$raw" | sha256sum | cut -c1-12
    elif command -v cksum > /dev/null 2>&1; then
        printf '%s' "$raw" | cksum | awk '{print $1}'
    else
        printf '%s' "${raw//[^a-zA-Z0-9._-]/_}"
    fi
}

# acquire_lock <lock_name> [scope_key]
# Acquires a race-free atomic mkdir lock directory under detect_temp_root().
# Stale locks (dead owner PID) are evicted atomically under a serialized reap dir.
_LOCK_DIR=""
_LOCK_ACQUIRED=0

_acquire_write_pid() {
    local lock_dir="$1"
    printf '%s\n' "$$" > "${lock_dir}/pid.tmp.$$"
    mv -f -- "${lock_dir}/pid.tmp.$$" "${lock_dir}/pid"
    _LOCK_DIR="$lock_dir"
    _LOCK_ACQUIRED=1
}

acquire_lock() {
    local lock_name="${1:-pkg_task}"
    local scope_key="${2:-}"
    local base_temp
    base_temp="$(detect_temp_root)"

    local suffix=""
    [[ -n "$scope_key" ]] && suffix="_$(_hash_scope_key "$scope_key")"
    local lock_dir="${base_temp}/${lock_name}${suffix}.lock.d"

    if mkdir "$lock_dir" 2> /dev/null; then
        _acquire_write_pid "$lock_dir"
        log_debug "Acquired lock ${lock_dir} (PID $$)"
        return 0
    fi

    local pid_file="${lock_dir}/pid"
    if [[ ! -f "$pid_file" ]]; then
        sleep 0.05
    fi

    local existing_pid=""
    if [[ -f "$pid_file" ]]; then
        existing_pid="$(cat "$pid_file" 2> /dev/null || true)"
    fi

    if [[ -n "$existing_pid" && "$existing_pid" =~ ^[0-9]+$ ]] && kill -0 "$existing_pid" 2> /dev/null; then
        log_error "Another instance is already running (PID ${existing_pid}, lock ${lock_dir})."
        return 1
    fi

    local reap_dir="${lock_dir}.reap"
    local reap_acquired=0
    if mkdir "$reap_dir" 2> /dev/null; then
        reap_acquired=1
    else
        # Recover if a previous reaper was SIGKILLed leaving an abandoned .reap dir
        sleep 0.05
        local reap_pid=""
        [[ -f "${reap_dir}/pid" ]] && reap_pid="$(cat "${reap_dir}/pid" 2> /dev/null || true)"
        if [[ -z "$reap_pid" ]] || ! [[ "$reap_pid" =~ ^[0-9]+$ ]] || ! kill -0 "$reap_pid" 2> /dev/null; then
            if [[ -d "$reap_dir" ]] && { [[ -n "$reap_pid" ]] || [[ -n "$(find "$reap_dir" -maxdepth 0 -mmin +1 2> /dev/null || true)" ]]; }; then
                rm -rf -- "$reap_dir" 2> /dev/null || true
                if mkdir "$reap_dir" 2> /dev/null; then
                    reap_acquired=1
                fi
            fi
        fi
    fi

    if [[ "$reap_acquired" -eq 1 ]]; then
        printf '%s\n' "$$" > "${reap_dir}/pid" 2> /dev/null || true
        existing_pid=""
        [[ -f "$pid_file" ]] && existing_pid="$(cat "$pid_file" 2> /dev/null || true)"
        if [[ -n "$existing_pid" && "$existing_pid" =~ ^[0-9]+$ ]] && kill -0 "$existing_pid" 2> /dev/null; then
            rm -rf -- "$reap_dir" 2> /dev/null || true
            log_error "Another instance is already running (PID ${existing_pid}, lock ${lock_dir})."
            return 1
        fi
        log_warn "Removing stale lock directory ${lock_dir} (previous PID: ${existing_pid:-unknown})."
        rm -rf -- "$lock_dir" 2> /dev/null || true

        if mkdir "$lock_dir" 2> /dev/null; then
            _acquire_write_pid "$lock_dir"
            rm -rf -- "$reap_dir" 2> /dev/null || true
            log_debug "Acquired lock ${lock_dir} after stale cleanup (PID $$)"
            return 0
        fi
        rm -rf -- "$reap_dir" 2> /dev/null || true
    fi

    log_error "Failed to acquire lock ${lock_dir}."
    return 1
}

release_lock() {
    if [[ "${_LOCK_ACQUIRED:-0}" -eq 1 && -n "${_LOCK_DIR:-}" && -d "$_LOCK_DIR" ]]; then
        local owner_pid=""
        owner_pid="$(cat "${_LOCK_DIR}/pid" 2> /dev/null || true)"
        if [[ "$owner_pid" == "$$" ]]; then
            rm -rf -- "$_LOCK_DIR" 2> /dev/null || true
        fi
    fi
    _LOCK_ACQUIRED=0
    _LOCK_DIR=""
}

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
    release_lock
    return "$exit_code"
}

_on_term_signal() {
    local sig_rc="${1:-143}"
    trap - INT TERM HUP
    exit "$sig_rc"
}

report_unexpected_err() {
    local err_rc=$?
    local err_src="${1:-unknown}"
    local err_line="${2:-?}"
    local err_cmd="${3:-}"
    log_error "Unexpected failure (exit=${err_rc}) in $(basename "$err_src"):${err_line}: ${err_cmd}"
}

enable_err_trap() {
    trap 'report_unexpected_err "${BASH_SOURCE[0]:-${0:-main}}" "${LINENO}" "${BASH_COMMAND}"' ERR
}

if [[ $- == *e* ]]; then
    enable_err_trap
fi
trap '_on_term_signal 130' INT
trap '_on_term_signal 143' TERM
trap '_on_term_signal 129' HUP
trap cleanup_workspace EXIT

# create_temp_workdir [prefix] [fallback_dir]
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

    if [[ -d "$base_temp" ]] && ! _is_unsafe_system_path "$base_temp"; then
        find "$base_temp" -maxdepth 1 -type d -name "${prefix}*" -mtime +1 -exec rm -rf {} + 2> /dev/null || true
    fi

    local workdir
    workdir=$(mktemp -d "${base_temp}/${prefix}XXXXXX") || return 1
    [[ -n "$workdir" && -d "$workdir" ]] || return 1
    printf '%s' "$workdir"
}

# init_exec_workspace <prefix> <source_cyg> <target_cyg> <dry_run> [update_source]
init_exec_workspace() {
    local prefix="$1"
    local source_cyg="$2"
    local target_cyg="$3"
    local dry_run="$4"
    local update_source="${5:-true}"

    [[ "$dry_run" == false || "$dry_run" == "0" ]] || return 0

    [[ -n "$target_cyg" ]] && mkdir -p "$target_cyg"
    if [[ "$update_source" == true || "$update_source" == "1" ]] && [[ -n "$source_cyg" ]]; then
        mkdir -p "$source_cyg"
    fi

    EXEC_WORKSPACE=$(create_temp_workdir "$prefix") || true
    if [[ -z "$EXEC_WORKSPACE" || ! -d "$EXEC_WORKSPACE" ]]; then
        log_error "Failed to create temporary workspace in ${TEMP_ROOT_PATH:-${TEMP_ROOT_CYG:-/tmp}}"
        exit 1
    fi
    log_info "Execution workspace initialized: $(enforce_drive_path "$EXEC_WORKSPACE")"
}

# ------------------------------------------------------------------------------
# Section 6: Shared CLI, CSV & UI Helpers
# ------------------------------------------------------------------------------
# require_opt_arg <flag> <remaining_argc> [exit_code]
require_opt_arg() {
    local flag="$1"
    local argc="$2"
    local exit_rc="${3:-1}"
    if [[ "$argc" -lt 2 ]]; then
        log_error "Option '${flag}' requires an argument."
        exit "$exit_rc"
    fi
}

# require_opt_value <flag> <value> [exit_code]
# Validates and prints a non-empty value not starting with '-' (supports --opt=val).
require_opt_value() {
    local flag="$1"
    local val="${2:-}"
    local exit_rc="${3:-1}"
    if [[ -z "$val" || "$val" == -* ]]; then
        log_error "${flag} requires an argument."
        exit "$exit_rc"
    fi
    printf '%s\n' "$val"
}

# verify_required_tools [--exit-code <n>] <tool1> [tool2...]
verify_required_tools() {
    local exit_rc="${PKG_MISSING_TOOL_RC:-1}"
    if [[ "${1:-}" == "--exit-code" ]]; then
        exit_rc="${2:-1}"
        shift 2
    fi
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
            exit "$exit_rc"
        fi
    done
}

init_log_file() {
    local log_file="$1"
    [[ -z "$log_file" ]] && return 0
    local log_cyg
    log_cyg=$(to_posix_path "$log_file")
    mkdir -p "$(dirname "$log_cyg")"
    exec > >(tee -a "$log_cyg") 2>&1
    _init_colors 1
}

# csv_contains <comma_separated_list> <item>
csv_contains() {
    local csv="$1"
    local item="$2"
    [[ ",${csv}," == *",${item},"* ]]
}

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
