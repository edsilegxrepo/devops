#!/usr/bin/env bash
# ==============================================================================
# client_package_common.sh
#
# Unified facade entrypoint for the shared client packaging & upgrade library.
# Loads focused domain modules from ./lib/:
#   - lib/pkg_paths.sh    : Platform/OS detection & Windows/POSIX/WSL path engine
#   - lib/pkg_wsl.sh      : WSL binary resolution & execution bridge
#   - lib/pkg_core.sh     : Logging, safe rm, workspaces, locks, traps, CLI helpers
#   - lib/pkg_transfer.sh : URL guard, checksum verifier, download_asset, gh_* API
#   - lib/pkg_archive.sh  : Integrity checks, repacking/WSL, semver, atomic publish
#   - lib/pkg_pipeline.sh : Dual-platform packaging orchestration pipeline
# ==============================================================================

[[ -n "${_CLIENT_PACKAGE_COMMON_SH_LOADED:-}" ]] && return 0
_CLIENT_PACKAGE_COMMON_SH_LOADED=1

_CPC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"

# shellcheck source=lib/pkg_core.sh
source "${_CPC_LIB_DIR}/pkg_core.sh"
# shellcheck source=lib/pkg_wsl.sh
source "${_CPC_LIB_DIR}/pkg_wsl.sh"
# shellcheck source=lib/pkg_transfer.sh
source "${_CPC_LIB_DIR}/pkg_transfer.sh"
# shellcheck source=lib/pkg_archive.sh
source "${_CPC_LIB_DIR}/pkg_archive.sh"
# shellcheck source=lib/pkg_pipeline.sh
source "${_CPC_LIB_DIR}/pkg_pipeline.sh"
