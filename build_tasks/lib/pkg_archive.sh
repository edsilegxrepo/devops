#!/usr/bin/env bash
# ==============================================================================
# lib/pkg_archive.sh
#
# Archive integrity checks, extraction, normalization, WSL permission-preserving
# repacking, semantic versioning discovery, obsolete purgers, and atomic staging.
# Requires: lib/pkg_core.sh
# ==============================================================================
# shellcheck disable=SC2034

[[ -n "${_PKG_ARCHIVE_SH_LOADED:-}" ]] && return 0
_PKG_ARCHIVE_SH_LOADED=1

if ! declare -F resolve_wsl_binary > /dev/null 2>&1; then
    _PKG_ARCHIVE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=lib/pkg_wsl.sh
    source "${_PKG_ARCHIVE_LIB_DIR}/pkg_wsl.sh"
fi

# Shared GNU tar option sets (arrays prevent word-splitting & caller collisions)
_PKG_TAR_OPTS=(--force-local)
_PKG_TAR_EXTRACT_OPTS=("${_PKG_TAR_OPTS[@]}" --warning=no-unknown-keyword)
_PKG_TAR_CREATE_OPTS=("${_PKG_TAR_OPTS[@]}" --owner=0 --group=0 --numeric-owner)

# ------------------------------------------------------------------------------
# Archive Verification & Extraction
# ------------------------------------------------------------------------------
verify_zip_integrity() {
    local zip_path="$1"
    unzip -tq "$zip_path" > /dev/null 2>&1
}

verify_zip_has_entry() {
    local zip_path="$1" entry="$2"
    [[ -f "$zip_path" && -n "$entry" ]] || return 1
    grep -qxF "$entry" <<< "$(unzip -Z1 "$zip_path" 2> /dev/null || true)"
}

verify_tar_xz_integrity() {
    local tar_xz_path="$1"
    tar "${_PKG_TAR_EXTRACT_OPTS[@]}" -tJf "$tar_xz_path" > /dev/null 2>&1
}

# verify_archive_integrity <file_path>
# Verifies .zip, .tar.xz, .tar.gz/.tgz, .tar, or .7z archives by extension;
# strips optional '.tmp.<pid>' staging suffixes cleanly.
verify_archive_integrity() {
    local archive_path="$1"
    [[ -s "$archive_path" ]] || return 1

    local clean_name="${archive_path%.tmp.*}"
    case "${clean_name,,}" in
        *.zip)
            verify_zip_integrity "$archive_path"
            ;;
        *.tar.xz)
            verify_tar_xz_integrity "$archive_path"
            ;;
        *.tar.gz | *.tgz)
            tar "${_PKG_TAR_EXTRACT_OPTS[@]}" -tzf "$archive_path" > /dev/null 2>&1
            ;;
        *.tar)
            tar "${_PKG_TAR_EXTRACT_OPTS[@]}" -tf "$archive_path" > /dev/null 2>&1
            ;;
        *.7z)
            local sz_bin="${SEVENZIP_BIN:-7z}"
            local sz_pos
            sz_pos=$(to_posix_path "$sz_bin")
            if ! command -v "$sz_pos" > /dev/null 2>&1; then
                log_error "7z binary not available to verify: $(basename "$archive_path")"
                return 1
            fi
            local sz_target
            sz_target=$(to_mixed_path "$archive_path")
            "$sz_pos" t "$sz_target" > /dev/null 2>&1
            ;;
        *)
            return 0
            ;;
    esac
}

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
            tar "${_PKG_TAR_EXTRACT_OPTS[@]}" -xzf "$archive" -C "$dest_dir"
            ;;
        *.tar.xz)
            tar "${_PKG_TAR_EXTRACT_OPTS[@]}" -xJf "$archive" -C "$dest_dir"
            ;;
        *.tar)
            tar "${_PKG_TAR_EXTRACT_OPTS[@]}" -xf "$archive" -C "$dest_dir"
            ;;
        *.7z)
            local sz_bin="${SEVENZIP_BIN:-7z}"
            local sz_pos
            sz_pos=$(to_posix_path "$sz_bin")
            if ! command -v "$sz_pos" > /dev/null 2>&1; then
                log_error "7z binary not available to extract: $(basename "$archive")"
                return 1
            fi
            local sz_dest sz_arc
            sz_dest=$(to_mixed_path "$dest_dir")
            sz_arc=$(to_mixed_path "$archive")
            "$sz_pos" x -y "-o${sz_dest}" "$sz_arc" > /dev/null
            ;;
        *)
            log_error "Unsupported archive format: $(basename "$archive")"
            return 1
            ;;
    esac
}

# ------------------------------------------------------------------------------
# Repacking & Normalization
# ------------------------------------------------------------------------------
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

normalize_directory_timestamps() {
    local target_dir="$1"
    [[ -d "$target_dir" ]] || return 0
    find "$target_dir" -depth \( -type f -o -type d \) -exec touch {} + 2> /dev/null || true
}

repack_directory_to_zip() {
    local content_dir="$1"
    local dest_zip="$2"
    [[ -d "$content_dir" ]] || return 1
    normalize_directory_timestamps "$content_dir"

    local dest_dir tmp_rel tmp_zip
    dest_dir=$(dirname "$dest_zip")
    mkdir -p "$dest_dir" || return 1
    tmp_rel=".__repack_tmp_${BASHPID:-$$}.zip"
    tmp_zip="${content_dir}/${tmp_rel}"
    rm -f "$tmp_zip" 2> /dev/null || true
    _CURRENT_TMP_FILE="$tmp_zip"

    if ! (
        cd "$content_dir" || exit 1
        zip -q -r "./${tmp_rel}" .
    ); then
        rm -f "$tmp_zip" 2> /dev/null || true
        _CURRENT_TMP_FILE=""
        log_error "Failed creating zip archive: $(basename "$dest_zip")"
        return 1
    fi

    if ! verify_zip_integrity "$tmp_zip"; then
        log_error "Corrupted zip archive generated: $(basename "$dest_zip")"
        rm -f "$tmp_zip" 2> /dev/null || true
        _CURRENT_TMP_FILE=""
        return 1
    fi

    if ! mv -f -- "$tmp_zip" "$dest_zip"; then
        rm -f "$tmp_zip" 2> /dev/null || true
        _CURRENT_TMP_FILE=""
        log_error "Failed moving zip archive to destination: $(basename "$dest_zip")"
        return 1
    fi
    _CURRENT_TMP_FILE=""
    return 0
}

# _tar_dir_to_xz <content_dir> <dest_tar_xz> [extra_tar_flags...]
_tar_dir_to_xz() {
    local content_dir="$1"
    local dest_tar_xz="$2"
    shift 2
    local -a extra_flags=("$@")

    (
        set -o pipefail
        cd "$content_dir" || exit 1
        shopt -s nullglob dotglob
        local items=(*)
        shopt -u nullglob dotglob
        if [[ ${#items[@]} -gt 0 ]]; then
            tar "${_PKG_TAR_CREATE_OPTS[@]}" "${extra_flags[@]}" -cf - "${items[@]}" | xz -9 -T0 > "$dest_tar_xz"
        else
            tar "${_PKG_TAR_CREATE_OPTS[@]}" "${extra_flags[@]}" -cf - --files-from /dev/null | xz -9 -T0 > "$dest_tar_xz"
        fi
    )
}

# _finalize_tmp_tar_xz <tmp_xz> <dest_tar_xz>
# Verifies non-empty xz integrity on tmp_xz before atomically promoting it.
_finalize_tmp_tar_xz() {
    local tmp_xz="$1"
    local dest_tar_xz="$2"

    if [[ ! -s "$tmp_xz" ]] || ! verify_tar_xz_integrity "$tmp_xz"; then
        log_error "Corrupted xz archive generated: $(basename "$dest_tar_xz")"
        safe_rm_f "$tmp_xz"
        _CURRENT_TMP_FILE=""
        return 1
    fi
    chmod 644 "$tmp_xz" 2> /dev/null || true
    if ! mv -f -- "$tmp_xz" "$dest_tar_xz"; then
        log_error "Failed finalizing xz archive: $(basename "$dest_tar_xz")"
        safe_rm_f "$tmp_xz"
        _CURRENT_TMP_FILE=""
        return 1
    fi
    _CURRENT_TMP_FILE=""
    return 0
}

repack_directory_to_tar_xz() {
    local content_dir="$1"
    local dest_tar_xz="$2"
    [[ -d "$content_dir" ]] || return 1
    mkdir -p "$(dirname "$dest_tar_xz")" || return 1
    normalize_directory_timestamps "$content_dir"

    local tmp_xz="${dest_tar_xz}.tmp.${BASHPID:-$$}"
    _CURRENT_TMP_FILE="$tmp_xz"

    if ! _tar_dir_to_xz "$content_dir" "$tmp_xz"; then
        log_error "Failed compressing tar.xz archive: $(basename "$dest_tar_xz")"
        safe_rm_f "$tmp_xz"
        _CURRENT_TMP_FILE=""
        return 1
    fi
    _finalize_tmp_tar_xz "$tmp_xz" "$dest_tar_xz"
}

# recompress_folder_to_tar_xz <parent_dir> <entry_to_pack> <dest_tar_xz>
# Preserves entry_to_pack (directory or file) as the single top-level entry in
# dest_tar_xz, normalizes timestamps, and writes atomically via a temporary sibling file.
recompress_folder_to_tar_xz() {
    local parent_dir="$1"
    local folder_to_pack="$2"
    local dest_tar_xz="$3"
    local target_sub="${parent_dir}/${folder_to_pack}"

    [[ -n "$folder_to_pack" && ( -e "$target_sub" || -L "$target_sub" ) ]] || {
        log_error "Entry to compress not found: $target_sub"
        return 1
    }
    mkdir -p "$(dirname "$dest_tar_xz")" || return 1
    if [[ -d "$target_sub" ]]; then
        normalize_directory_timestamps "$target_sub"
    elif [[ -f "$target_sub" ]]; then
        touch "$target_sub" 2> /dev/null || true
    fi

    local tmp_xz="${dest_tar_xz}.tmp.${BASHPID:-$$}"
    _CURRENT_TMP_FILE="$tmp_xz"

    if ! (set -o pipefail; cd "$parent_dir" && tar "${_PKG_TAR_CREATE_OPTS[@]}" -cf - "$folder_to_pack" | xz -9 -T0 > "$tmp_xz"); then
        log_error "Failed creating xz archive: $(basename "$dest_tar_xz")"
        safe_rm_f "$tmp_xz"
        _CURRENT_TMP_FILE=""
        return 1
    fi
    _finalize_tmp_tar_xz "$tmp_xz" "$dest_tar_xz"
}

prune_electron_locales() {
    local locales_dir="$1"
    local keep="${2:-en-US.pak}"
    if [[ -d "$locales_dir" ]]; then
        find "$locales_dir" -type f -name "*.pak" ! -name "$keep" -delete 2> /dev/null || true
    fi
}

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

prune_root_licenses() {
    local target_dir="$1"
    [[ -d "$target_dir" ]] || return 0
    rm -f "${target_dir}"/LICENSE* "${target_dir}"/LICENSES* "${target_dir}"/NOTICE* "${target_dir}"/ATTRIBUTION* "${target_dir}"/OFL*.txt 2> /dev/null || true
}

repack_tar_gz_to_xz_preserving_perms() {
    local src_tar_gz="$1"
    local dest_tar_xz="$2"
    local pack_target="$3"
    local transform_cmds="${4:-}"

    [[ -f "$src_tar_gz" ]] || {
        log_error "Source archive not found: $src_tar_gz"
        return 1
    }
    mkdir -p "$(dirname "$dest_tar_xz")" || return 1

    local tmp_xz="${dest_tar_xz}.tmp.${BASHPID:-$$}"
    _CURRENT_TMP_FILE="$tmp_xz"

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
tar --force-local --warning=no-unknown-keyword -xzpf "$in_file" -C "$lx_work/unpack"

if [[ -n "$transform_cmds" ]]; then
    (cd "$lx_work/unpack" && eval "$transform_cmds") >&2
fi

tar --force-local --owner=0 --group=0 --numeric-owner -cf - -C "$lx_work/unpack" "$pack_target" | xz -9 -T0 > "$lx_work/out.tar.xz"
tar --force-local -tJf "$lx_work/out.tar.xz" >/dev/null

if [[ "$out_file" == "-" ]]; then
    cat "$lx_work/out.tar.xz"
else
    cp -f "$lx_work/out.tar.xz" "$out_file"
    chmod 644 "$out_file" 2>/dev/null || true
fi
'

    if ! is_windows_platform; then
        if ! bash -c "$inner_script" _ "$src_tar_gz" "$tmp_xz" "$pack_target" "$transform_cmds"; then
            safe_rm_f "$tmp_xz"
            _CURRENT_TMP_FILE=""
            return 1
        fi
        _finalize_tmp_tar_xz "$tmp_xz" "$dest_tar_xz"
        return $?
    fi

    local wsl_bin
    if ! wsl_bin="$(resolve_wsl_binary)"; then
        log_error "wsl.exe not found; required on Windows to preserve Linux archive permissions."
        _CURRENT_TMP_FILE=""
        return 1
    fi

    local wsl_src wsl_dst_dir
    wsl_src=$(to_wsl_path "$src_tar_gz" || true)
    wsl_dst_dir=$(to_wsl_path "$(dirname "$dest_tar_xz")" || true)

    if [[ -n "$wsl_src" && -n "$wsl_dst_dir" ]] &&
        "$wsl_bin" -e test -f "$wsl_src" < /dev/null 2> /dev/null &&
        "$wsl_bin" -e test -d "$wsl_dst_dir" < /dev/null 2> /dev/null; then
        local wsl_tmp_dst
        wsl_tmp_dst="${wsl_dst_dir}/$(basename "$tmp_xz")"
        if ! "$wsl_bin" -e bash -c "$inner_script" _ "$wsl_src" "$wsl_tmp_dst" "$pack_target" "$transform_cmds" < /dev/null; then
            log_error "WSL archive recompression failed for $(basename "$dest_tar_xz")"
            safe_rm_f "$tmp_xz"
            _CURRENT_TMP_FILE=""
            return 1
        fi
    else
        if ! "$wsl_bin" -e bash -c "$inner_script" _ "-" "-" "$pack_target" "$transform_cmds" < "$src_tar_gz" > "$tmp_xz"; then
            log_error "WSL streaming archive recompression failed for $(basename "$dest_tar_xz")"
            safe_rm_f "$tmp_xz"
            _CURRENT_TMP_FILE=""
            return 1
        fi
    fi

    _finalize_tmp_tar_xz "$tmp_xz" "$dest_tar_xz"
}

repack_directory_to_tar_xz_preserving_perms() {
    local stage_dir="$1" dest_tar_xz="$2" strip_base="${3:-true}"
    [[ -d "$stage_dir" ]] || return 1
    mkdir -p "$(dirname "$dest_tar_xz")" || return 1

    if ! is_windows_platform; then
        [[ "$strip_base" == true ]] && strip_base_directory "$stage_dir"
        repack_directory_to_tar_xz "$stage_dir" "$dest_tar_xz"
        return $?
    fi

    local tmp_xz="${dest_tar_xz}.tmp.${BASHPID:-$$}"
    _CURRENT_TMP_FILE="$tmp_xz"

    local wsl_bin
    if wsl_bin="$(resolve_wsl_binary)"; then
        local src_tar="${stage_dir}_raw.${BASHPID:-$$}.tar"
        safe_rm_f "$src_tar"
        if (
            cd "$stage_dir" || exit 1
            shopt -s nullglob dotglob
            local items=(*)
            shopt -u nullglob dotglob
            if [[ ${#items[@]} -gt 0 ]]; then
                tar "${_PKG_TAR_OPTS[@]}" -cf "$src_tar" "${items[@]}"
            else
                tar "${_PKG_TAR_OPTS[@]}" -cf "$src_tar" --files-from /dev/null
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
            if "$wsl_bin" -e bash -c "$inner" _ "$strip_base" < "$src_tar" > "$tmp_xz" 2> /dev/null &&
                _finalize_tmp_tar_xz "$tmp_xz" "$dest_tar_xz"; then
                safe_rm_f "$src_tar"
                return 0
            fi
        fi
        safe_rm_f "$src_tar"
        safe_rm_f "$tmp_xz"
    fi

    [[ "$strip_base" == true ]] && strip_base_directory "$stage_dir"
    normalize_directory_timestamps "$stage_dir"
    _CURRENT_TMP_FILE="$tmp_xz"
    if ! _tar_dir_to_xz "$stage_dir" "$tmp_xz" "--mode=a+rX,u+w"; then
        safe_rm_f "$tmp_xz"
        _CURRENT_TMP_FILE=""
        return 1
    fi
    _finalize_tmp_tar_xz "$tmp_xz" "$dest_tar_xz"
}

# ------------------------------------------------------------------------------
# Semantic Versioning, Obsolete Pruning & Transactional Publishing
# ------------------------------------------------------------------------------
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

    local f bname ver
    for f in "${files[@]}"; do
        bname=$(basename "$f")
        if [[ "$bname" =~ ^${app_escaped}-([0-9]+(\.[0-9]+)*([a-zA-Z0-9._-]*))-(${suffix_regex})\.${ext_escaped}$ ]]; then
            ver="${BASH_REMATCH[1]}"
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

    local old bname
    for old in "${old_files[@]}"; do
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

_paths_same_dir() {
    local a="$1" b="$2"
    [[ -n "$a" && -n "$b" && -d "$a" && -d "$b" ]] || return 1
    [[ "$(cd "$a" 2> /dev/null && pwd)" == "$(cd "$b" 2> /dev/null && pwd)" ]]
}

# atomic_publish_file <src_file> <dest_file> [label] [verify_archive:true|false]
# Stages src_file via a sibling .tmp.<pid>, verifies non-empty size (and archive
# integrity for .zip/.tar.xz before rename when verify_archive=true), then moves atomically.
atomic_publish_file() {
    local src_file="$1"
    local dest_file="$2"
    local label="${3:-target}"
    local verify_archive="${4:-true}"

    local dest_dir
    dest_dir=$(dirname "$dest_file")
    mkdir -p "$dest_dir" || return 1

    local tmp_dest="${dest_file}.tmp.${BASHPID:-$$}"
    CURRENT_TARGET_TMP="$tmp_dest"

    if ! cp -f -- "$src_file" "$tmp_dest"; then
        log_error "Failed to stage temporary ${label} file: $tmp_dest"
        safe_rm_f "$tmp_dest"
        CURRENT_TARGET_TMP=""
        return 1
    fi
    chmod 644 "$tmp_dest" 2> /dev/null || true

    if [[ "$verify_archive" == true ]]; then
        if ! verify_archive_integrity "$tmp_dest"; then
            log_error "Pre-rename integrity check failed for staged ${label} file: $tmp_dest"
            safe_rm_f "$tmp_dest"
            CURRENT_TARGET_TMP=""
            return 1
        fi
    elif [[ ! -s "$tmp_dest" ]]; then
        log_error "Empty staged ${label} file: $tmp_dest"
        safe_rm_f "$tmp_dest"
        CURRENT_TARGET_TMP=""
        return 1
    fi

    if ! mv -f -- "$tmp_dest" "$dest_file"; then
        log_error "Failed to rename $tmp_dest to $dest_file"
        safe_rm_f "$tmp_dest"
        CURRENT_TARGET_TMP=""
        return 1
    fi
    CURRENT_TARGET_TMP=""

    if [[ ! -s "$dest_file" ]]; then
        log_error "Failed to verify published ${label} package: $dest_file"
        return 1
    fi
    return 0
}

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
        atomic_publish_file "$src_file" "${src_dir}/${pkg_name}" "source" true || return 1
        staged_src=true
    fi

    if [[ -n "$tgt_dir" ]] && { [[ "$staged_src" != true ]] || ! _paths_same_dir "$src_dir" "$tgt_dir"; }; then
        log_info "Atomically staging $pkg_name in target pending..."
        atomic_publish_file "$src_file" "${tgt_dir}/${pkg_name}" "target" true || return 1
        log_ok "Successfully staged in target: $pkg_name"
    fi

    purge_obsolete_packages "$app_key" "$platform_suffix" "$pkg_name" "$src_dir" "$tgt_dir" "$dry_run"
    return 0
}
