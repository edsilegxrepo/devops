#!/usr/bin/env bash
# ==============================================================================
# lib/pkg_paths.sh
#
# Stateless host platform detection and cross-platform path normalizers
# (Windows drive/mixed <-> Cygwin/MSYS2 POSIX <-> WSL /mnt/<drive>).
# Zero side-effect traps or logging dependencies; safe to source anywhere.
# ==============================================================================
# shellcheck disable=SC2034

[[ -n "${_PKG_PATHS_SH_LOADED:-}" ]] && return 0
_PKG_PATHS_SH_LOADED=1

# ------------------------------------------------------------------------------
# Platform Detection & PATH Precedence
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

# detect_host_os
# Coarse host OS tag used by Go/WSL build orchestrators: WIN | LINUX.
detect_host_os() {
    if [[ "${OS:-}" == "Windows_NT" ]] || is_windows_platform; then
        echo "WIN"
    else
        echo "LINUX"
    fi
}

# ------------------------------------------------------------------------------
# Dual-Layer Windows / POSIX / WSL Path Normalizers
# ------------------------------------------------------------------------------
strip_trailing_slashes() {
    local p="$1"
    while [[ ${#p} -gt 1 && "$p" == */ ]]; do
        p="${p%/}"
    done
    printf '%s' "$p"
}

# _regex_to_drive_path <path> <strict_scope:0|1>
# Shared regex normalizer for mixed <drive>:/path output.
# strict_scope=1 restricts /mnt/<d> to WSL/mounted Linux and /<d> to MSYS2.
# Returns 0 on match (printing drive path), 1 if no drive/mount pattern matched.
_regex_to_drive_path() {
    local p="$1" strict_scope="${2:-1}"
    p="${p//\\//}"

    if [[ "$p" =~ ^/cygdrive/([a-zA-Z])/(.*) ]]; then
        echo "${BASH_REMATCH[1],,}:/${BASH_REMATCH[2]}"
    elif [[ "$p" =~ ^/cygdrive/([a-zA-Z])$ ]]; then
        echo "${BASH_REMATCH[1],,}:/"
    elif [[ "$p" =~ ^/mnt/([a-zA-Z])/(.*) ]] && [[ "$strict_scope" -eq 0 || "$PLATFORM" == "wsl" || -d "/mnt/${BASH_REMATCH[1]}" ]]; then
        echo "${BASH_REMATCH[1],,}:/${BASH_REMATCH[2]}"
    elif [[ "$p" =~ ^/mnt/([a-zA-Z])$ ]] && [[ "$strict_scope" -eq 0 || "$PLATFORM" == "wsl" || -d "/mnt/${BASH_REMATCH[1]}" ]]; then
        echo "${BASH_REMATCH[1],,}:/"
    elif [[ "$p" =~ ^/([a-zA-Z])/(.*) ]] && [[ "$strict_scope" -eq 0 || "$PLATFORM" == "msys2" ]]; then
        echo "${BASH_REMATCH[1],,}:/${BASH_REMATCH[2]}"
    elif [[ "$p" =~ ^/([a-zA-Z])$ ]] && [[ "$strict_scope" -eq 0 || "$PLATFORM" == "msys2" ]]; then
        echo "${BASH_REMATCH[1],,}:/"
    elif [[ "$p" =~ ^([a-zA-Z]):[/\\]?(.*) ]]; then
        echo "${BASH_REMATCH[1],,}:/${BASH_REMATCH[2]}"
    else
        echo "$p"
        return 1
    fi
}

# enforce_drive_path <path>
# Normalizes paths to canonical mixed drive-letter format (e.g. "c:/path/dir")
# for consistent user logging, table rendering, and configuration storage.
enforce_drive_path() {
    local p="${1:-}"
    [[ -z "$p" ]] && return 0
    _regex_to_drive_path "$p" 1 || true
}

# to_posix_path <path>
# Converts Windows drive-letter/backslash paths to native POSIX mount paths
# (/cygdrive/c/..., /c/..., /mnt/c/...).
to_posix_path() {
    local p="$1"
    [[ -z "$p" ]] && return 0

    if command -v cygpath > /dev/null 2>&1; then
        cygpath -u "$p" 2> /dev/null || echo "$p"
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

# normalize_to_mixed_path <path>
# Windows-only host converter (no-op on pure Linux hosts). Converts Windows,
# Cygwin (/cygdrive/c), MSYS (/c), and /mnt/c paths into canonical drive:/path.
normalize_to_mixed_path() {
    local p="${1:-}"
    [[ -z "$p" ]] && return 0
    if [[ "${HOST_OS:-$(detect_host_os)}" != "WIN" ]]; then
        echo "$p"
        return 0
    fi
    local matched
    if matched="$(_regex_to_drive_path "$p" 0)"; then
        echo "$matched"
    elif command -v cygpath > /dev/null 2>&1; then
        cygpath -m "$p"
    else
        echo "$p"
    fi
}

# normalize_to_posix_path <path>
# Converts any Windows/mixed path to native POSIX mount path when running on a
# Windows host shell with cygpath; returns unchanged on Linux hosts.
normalize_to_posix_path() {
    local raw="${1:-}"
    [[ -z "$raw" ]] && return 0
    if [[ "${HOST_OS:-$(detect_host_os)}" == "WIN" ]] && command -v cygpath > /dev/null 2>&1; then
        to_posix_path "$raw"
    else
        echo "$raw"
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

# mixed_to_wsl_path <path>
# Zero-subprocess pure-bash converter from drive:/path (or Windows/POSIX mounts)
# into standard WSL mount path (/mnt/<drive>/<subpath>).
mixed_to_wsl_path() {
    local p="${1:-}"
    [[ -z "$p" ]] && return 0
    if [[ "$p" =~ ^/mnt/([a-zA-Z])/(.*) ]]; then
        echo "$p"
        return 0
    fi
    local mixed
    mixed="$(normalize_to_mixed_path "$p")"
    if [[ "$mixed" =~ ^([a-zA-Z]):/(.*) ]]; then
        echo "/mnt/${BASH_REMATCH[1],,}/${BASH_REMATCH[2]}"
    else
        echo "$mixed"
    fi
}

# to_wsl_path <path>
# Translates a Windows or POSIX shell path to a WSL path using wslpath when
# available (honoring RESOLVED_WSL_BIN), falling back to pure-bash mixed_to_wsl_path.
to_wsl_path() {
    local p="$1"
    [[ -z "$p" ]] && return 1

    local wsl_bin="${RESOLVED_WSL_BIN:-wsl.exe}"
    local wsl_out=""
    if command -v "$wsl_bin" > /dev/null 2>&1 || [[ -x "$wsl_bin" ]]; then
        local drive_p
        drive_p=$(enforce_drive_path "$p")
        if [[ "$drive_p" =~ ^[a-zA-Z]:/ ]]; then
            wsl_out=$("$wsl_bin" -e wslpath -u "$drive_p" < /dev/null 2> /dev/null | tr -d '\r\n' || true)
        else
            local sys_p
            sys_p=$(to_syspath "$p")
            wsl_out=$("$wsl_bin" -e wslpath -u "${sys_p//\\//}" < /dev/null 2> /dev/null | tr -d '\r\n' || true)
        fi
    fi

    if [[ -n "$wsl_out" ]]; then
        echo "$wsl_out"
    else
        HOST_OS="WIN" mixed_to_wsl_path "$p"
    fi
}

# normalize_and_add_to_path <dir>
# Converts a Windows/mixed directory to POSIX form and prepends it to $PATH if present.
normalize_and_add_to_path() {
    local target_dir="${1:-}"
    [[ -z "$target_dir" ]] && return 1

    if [[ -d "$target_dir" ]]; then
        target_dir="$(to_posix_path "$target_dir")"
        export PATH="${target_dir}:${PATH:-}"
        return 0
    fi
    return 1
}
