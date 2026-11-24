#!/usr/bin/env bash
# ==============================================================================
# lib/pkg_wsl.sh
#
# Shared WSL availability checks and command execution bridge.
# Requires: lib/pkg_paths.sh (mixed_to_wsl_path).
# ==============================================================================

[[ -n "${_PKG_WSL_SH_LOADED:-}" ]] && return 0
_PKG_WSL_SH_LOADED=1

if ! declare -F mixed_to_wsl_path > /dev/null 2>&1; then
    _PKG_WSL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=lib/pkg_paths.sh
    source "${_PKG_WSL_LIB_DIR}/pkg_paths.sh"
fi

# resolve_wsl_binary
# Locates wsl.exe / wsl on PATH or standard Windows System32 locations.
resolve_wsl_binary() {
    if [[ -n "${RESOLVED_WSL_BIN:-}" ]] && { command -v "$RESOLVED_WSL_BIN" &> /dev/null || [[ -x "$RESOLVED_WSL_BIN" ]]; }; then
        echo "$RESOLVED_WSL_BIN"
        return 0
    fi
    local cand=""
    if cand="$(command -v wsl.exe 2> /dev/null || command -v wsl 2> /dev/null)" && [[ -n "$cand" ]]; then
        echo "$cand"
        return 0
    fi
    if [[ -f "/c/Windows/System32/wsl.exe" ]]; then
        echo "/c/Windows/System32/wsl.exe"
        return 0
    fi
    if [[ -f "C:/Windows/System32/wsl.exe" ]]; then
        echo "C:/Windows/System32/wsl.exe"
        return 0
    fi
    return 1
}

# check_wsl_available
# Verifies whether the WSL CLI tool (wsl or wsl.exe) is available on the host.
check_wsl_available() {
    resolve_wsl_binary > /dev/null 2>&1
}

# run_in_wsl <target_dir> <cmd...>
# Executes commands inside the default WSL distribution using an interactive
# login shell (bash -lc) in the converted target working directory.
run_in_wsl() {
    local target_dir="$1"
    shift
    local wsl_bin wsl_cwd cmd
    wsl_bin="$(resolve_wsl_binary)" || return 127
    wsl_cwd="$(mixed_to_wsl_path "${target_dir}")"

    cmd="$(printf '%q ' "$@")"
    "${wsl_bin}" --cd / bash -lc "cd \"${wsl_cwd}\" && ${cmd}"
}
