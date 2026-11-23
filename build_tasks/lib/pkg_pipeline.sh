#!/usr/bin/env bash
# ==============================================================================
# lib/pkg_pipeline.sh
#
# High-level dual-platform (Windows .zip + Linux .tar.xz) packaging pipeline.
# Requires: lib/pkg_core.sh, lib/pkg_transfer.sh, lib/pkg_archive.sh
# ==============================================================================

[[ -n "${_PKG_PIPELINE_SH_LOADED:-}" ]] && return 0
_PKG_PIPELINE_SH_LOADED=1

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

    if ! verify_archive_integrity "$out_path"; then
        log_error "Corrupted ${ext} archive generated: $pkg_name"
        ERROR_COUNT=$((ERROR_COUNT + 1))
        return 1
    fi

    if atomic_stage_package "$out_path" "$pkg_name" "$app_key" "$suffix" "$SOURCE_CYG" "$TARGET_CYG" "$DRY_RUN"; then
        UPDATED_COUNT=$((UPDATED_COUNT + 1))
        return 0
    else
        ERROR_COUNT=$((ERROR_COUNT + 1))
        return 1
    fi
}

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

    cleanup_current_build_dir

    return $rc
}
