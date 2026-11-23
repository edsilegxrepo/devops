#!/usr/bin/env bash
# ==============================================================================
# dotnet_packaging.sh - .NET Windows Installer Bundle Synchronization & Staging
# ==============================================================================
# Compares local dotnetfx-<major>.0-win.zip archives against official Microsoft
# .NET release metadata for specified channels (--version) or discovered local
# archives >= 8 (--auto). Downloads and verifies updated Windows installers via
# SHA-512 when missing or outdated, rebuilds the flat ZIP archive
# transactionally, stages the bundle for upload, and updates the archive library.
# ==============================================================================

set -Eeuo pipefail

# Route informational telemetry to stderr so stdout carries only summary output.
LOG_INFO_TO_STDERR=1
VERBOSE=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_LIB="${SCRIPT_DIR}/client_package_common.sh"
if [[ ! -f "${COMMON_LIB}" ]]; then
    printf '[ERROR] Shared library not found: %s\n' "${COMMON_LIB}" >&2
    exit 1
fi
# shellcheck source=client_package_common.sh
source "${COMMON_LIB}"

# ------------------------------------------------------------------------------
# Defaults & Constants
# ------------------------------------------------------------------------------
readonly SCRIPT_NAME="dotnet_packaging.sh"
DEFAULT_ARCHIVE_WIN="$(resolve_default_path "n" "softlib/software/public/devel/dotnet")"
DEFAULT_STAGING_WIN="$(resolve_default_path "f" "stage/upload/pending")"
readonly DEFAULT_ARCHIVE_WIN
readonly DEFAULT_STAGING_WIN
readonly METADATA_BASE_URL="${DOTNET_METADATA_BASE_URL:-https://builds.dotnet.microsoft.com/dotnet/release-metadata}"
readonly MIN_DOTNET_MAJOR=8

# Runtime configuration
REQUESTED_VERSIONS=""
AUTO_MODE=0
ARCHIVE_RAW="${DEFAULT_ARCHIVE_WIN}"
STAGING_RAW="${DEFAULT_STAGING_WIN}"
ARCHIVE_DIR=""
STAGING_DIR=""
DRY_RUN=0
FORCE=0
NO_STAGING=0
NO_UPDATE_ARCHIVE=0

# Mutable execution state (cleaned up via shared EXIT/signal traps)
EXEC_WORKSPACE=""

# Summary tracking arrays
declare -a CHANNELS=()
declare -a SUMMARY_ROWS=()

# ------------------------------------------------------------------------------
# Dependencies
# ------------------------------------------------------------------------------
check_dependencies() {
    verify_required_tools curl jq zip unzip mktemp realpath
    if ! command -v sha512sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
        log_error "Required SHA-512 tool not found: need sha512sum or shasum in PATH."
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# CLI Usage & Argument Parsing
# ------------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} (--version <list> | --auto) [options]

Synchronize local Windows .NET installer archives (dotnetfx-<X>.0-win.zip)
with official Microsoft release metadata and stage updated packages for upload.

Target Selection (mutually exclusive, one required):
  --version <list>        Target .NET major channel (>= ${MIN_DOTNET_MAJOR}) or comma-separated
                          list (e.g. 11, 10, 8, or 11.0, 10.0, 8.0).
                          Example: --version 11  or  --version 11,10,8
  --auto                  Inspect --archive for existing dotnetfx-<major>.0-win.zip
                          archives with major >= ${MIN_DOTNET_MAJOR} and update as needed

Options:
  --archive <path>        Archive repository directory containing
                          dotnetfx-<X>.0-win.zip
                          (default: ${DEFAULT_ARCHIVE_WIN})
  --staging <path>        Staging output directory for updated ZIP bundles
                          (default: ${DEFAULT_STAGING_WIN})
  --dry-run               Compare local archives against Microsoft metadata and
                          report status without downloading or writing files
  --force                 Force full download, rebuild, and re-staging even if
                          versions already match
  --no-staging            Update archive directory only; skip staging copy
  --no-update-archive     Stage updated ZIP without modifying archive directory
  --verbose               Enable detailed diagnostic logging
  -h, --help              Show this help message and exit

Environment Overrides:
  DOTNET_METADATA_BASE_URL   Base URL for release-metadata JSON feed
                             (default: https://builds.dotnet.microsoft.com/dotnet/release-metadata)
EOF
}

parse_versions_list() {
    local raw="$1"
    if [[ -z "${raw}" ]]; then
        log_error "--version value must not be empty."
        exit 1
    fi

    local -a tokens=()
    local -A seen=()
    local token normalized
    IFS=',' read -r -a tokens <<< "${raw}"

    for token in "${tokens[@]}"; do
        token="${token#"${token%%[![:space:]]*}"}"
        token="${token%"${token##*[![:space:]]}"}"
        if [[ -z "${token}" ]]; then
            log_error "Empty entry in --version list: ${raw}"
            exit 1
        elif [[ "${token}" =~ ^([0-9]+)(\.0)?$ ]]; then
            local major_num=$((10#${BASH_REMATCH[1]}))
            if (( major_num < MIN_DOTNET_MAJOR )); then
                log_error "Unsupported .NET version '${token}'. Major version must be >= ${MIN_DOTNET_MAJOR}."
                exit 1
            fi
            normalized="${major_num}.0"
        else
            log_error "Unsupported .NET version '${token}'. Expected major >= ${MIN_DOTNET_MAJOR} (e.g. 11, 10, 8 or 11.0, 10.0, 8.0)."
            exit 1
        fi

        if [[ -z "${seen[${normalized}]:-}" ]]; then
            CHANNELS+=("${normalized}")
            seen["${normalized}"]=1
        fi
    done

    if [[ "${#CHANNELS[@]}" -eq 0 ]]; then
        log_error "No valid .NET channels resolved from --version '${raw}'."
        exit 1
    fi
}

discover_auto_channels() {
    if [[ ! -d "${ARCHIVE_DIR}" ]]; then
        log_error "--auto cannot scan non-existent archive directory: $(enforce_drive_path "${ARCHIVE_DIR}")"
        exit 1
    fi

    local -a found_majors=()
    local zip_file base major_num
    for zip_file in "${ARCHIVE_DIR}"/dotnetfx-*-win.zip; do
        [[ -f "${zip_file}" ]] || continue
        base="${zip_file##*/}"
        if [[ "${base}" =~ ^dotnetfx-([0-9]+)\.0-win\.zip$ ]]; then
            major_num=$((10#${BASH_REMATCH[1]}))
            if (( major_num >= MIN_DOTNET_MAJOR )); then
                found_majors+=("${major_num}")
            fi
        fi
    done

    if [[ "${#found_majors[@]}" -eq 0 ]]; then
        log_error "No dotnetfx-<major>.0-win.zip archives with major >= ${MIN_DOTNET_MAJOR} found in $(enforce_drive_path "${ARCHIVE_DIR}"). Use --version <major> to create an initial archive."
        exit 1
    fi

    local -a sorted_majors=()
    mapfile -t sorted_majors < <(printf '%s\n' "${found_majors[@]}" | sort -rn -u)

    local m
    for m in "${sorted_majors[@]}"; do
        CHANNELS+=("${m}.0")
    done

    log_info "Auto-discovered .NET channels (>= ${MIN_DOTNET_MAJOR}): ${CHANNELS[*]}"
}

parse_args() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --version)
                REQUESTED_VERSIONS="$(require_opt_value "$1" "${2:-}")"
                shift 2
                ;;
            --version=*)
                REQUESTED_VERSIONS="$(require_opt_value "${1%%=*}" "${1#*=}")"
                shift
                ;;
            --auto)
                AUTO_MODE=1
                shift
                ;;
            --archive)
                ARCHIVE_RAW="$(require_opt_value "$1" "${2:-}")"
                shift 2
                ;;
            --archive=*)
                ARCHIVE_RAW="$(require_opt_value "${1%%=*}" "${1#*=}")"
                shift
                ;;
            --staging)
                STAGING_RAW="$(require_opt_value "$1" "${2:-}")"
                shift 2
                ;;
            --staging=*)
                STAGING_RAW="$(require_opt_value "${1%%=*}" "${1#*=}")"
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --force)
                FORCE=1
                shift
                ;;
            --no-staging)
                NO_STAGING=1
                shift
                ;;
            --no-update-archive)
                NO_UPDATE_ARCHIVE=1
                shift
                ;;
            --verbose)
                VERBOSE=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown argument: $1"
                usage >&2
                exit 1
                ;;
        esac
    done

    if [[ "${AUTO_MODE}" -eq 1 && -n "${REQUESTED_VERSIONS}" ]]; then
        log_error "--auto and --version are mutually exclusive."
        usage >&2
        exit 1
    fi

    if [[ "${AUTO_MODE}" -eq 0 && -z "${REQUESTED_VERSIONS}" ]]; then
        log_error "Either --version <list> or --auto is required."
        usage >&2
        exit 1
    fi

    ARCHIVE_DIR="$(validate_safe_dir "archive" "${ARCHIVE_RAW}")" || exit 1
    STAGING_DIR="$(validate_safe_dir "staging" "${STAGING_RAW}")" || exit 1

    if [[ "${DRY_RUN}" -eq 0 && "${NO_STAGING}" -eq 1 && "${NO_UPDATE_ARCHIVE}" -eq 1 ]]; then
        log_error "Cannot combine --no-staging and --no-update-archive without --dry-run (no outputs enabled)."
        exit 1
    fi

    if [[ "${DRY_RUN}" -eq 0 && "${NO_STAGING}" -eq 0 && "${NO_UPDATE_ARCHIVE}" -eq 0 && "${ARCHIVE_DIR}" == "${STAGING_DIR}" ]]; then
        log_error "--archive and --staging must not resolve to the same directory: ${ARCHIVE_DIR}"
        exit 1
    fi

    if [[ "${AUTO_MODE}" -eq 1 ]]; then
        discover_auto_channels
    else
        parse_versions_list "${REQUESTED_VERSIONS}"
    fi
}

# ------------------------------------------------------------------------------
# Metadata & Archive Inspection Helpers
# ------------------------------------------------------------------------------
_allow_file_scheme() {
    [[ "${METADATA_BASE_URL}" == file://* ]]
}

# Fetches releases.json for a channel and emits resolved fields.
# Output lines written to <out_manifest>:
#   Line 1: <latest_release>\t<latest_sdk>
#   Lines 2..6: <component_key>\t<filename>\t<url>\t<sha512>
fetch_upstream_metadata() {
    local channel="$1"
    local out_manifest="$2"

    local feed_url="${METADATA_BASE_URL%/}/${channel}/releases.json"
    local json_path="${EXEC_WORKSPACE}/releases-${channel}.json"
    local allow_file=false
    _allow_file_scheme && allow_file=true

    log_debug "Fetching metadata feed for .NET ${channel}: ${feed_url}"
    if ! download_asset "${feed_url}" "${json_path}" "" "sha512" "${allow_file}"; then
        log_error "Failed to fetch release metadata from ${feed_url}"
        return 1
    fi

    # Feed jq via stdin to avoid cross-runtime MSYS2/Cygwin path translation issues
    local jq_output
    if ! jq_output="$(jq -er '
        (."latest-release" // empty) as $rel |
        (."latest-sdk" // empty) as $sdk |
        (.releases[] | select(."release-version" == $rel)) as $r |
        def pick($files; $fname):
            ($files // [])[] | select(.name == $fname);
        ($r."aspnetcore-runtime".files // []) as $asp_files |
        ($r.runtime.files // []) as $rt_files |
        (($r | (first(((.sdks[]? // empty), .sdk) | select(.version == $sdk)) // .sdk)).files // []) as $sdk_files |
        ($r.windowsdesktop.files // []) as $wd_files |
        [
            ["aspnetcore-runtime", (pick($asp_files; "aspnetcore-runtime-win-x64.exe") | .url, .hash)],
            ["dotnet-hosting",     (pick($asp_files; "dotnet-hosting-win.exe")     | .url, .hash)],
            ["dotnet-runtime",     (pick($rt_files;  "dotnet-runtime-win-x64.exe") | .url, .hash)],
            ["dotnet-sdk",         (pick($sdk_files; "dotnet-sdk-win-x64.exe")     | .url, .hash)],
            ["windowsdesktop",     (pick($wd_files;  "windowsdesktop-runtime-win-x64.exe") | .url, .hash)]
        ] as $rows |
        if ($rows | length) != 5 then error("missing expected Windows installer entries") else . end |
        ([$rel, $sdk] | @tsv), ($rows[] | @tsv)
    ' < "${json_path}")"; then
        log_error "Failed to extract release metadata and Windows x64 installers for .NET ${channel} from ${feed_url}."
        return 1
    fi

    : > "${out_manifest}"

    local line_no=0 count=0
    local key url hash fname
    while IFS=$'\t' read -r key url hash; do
        if [[ "${line_no}" -eq 0 ]]; then
            if [[ -z "${key}" || -z "${url}" ]]; then
                log_error "Could not parse latest-release / latest-sdk from ${feed_url}"
                return 1
            fi
            printf '%s\t%s\n' "${key}" "${url}" >> "${out_manifest}"
            line_no=1
            continue
        fi
        if [[ -z "${key}" || -z "${url}" || -z "${hash}" ]]; then
            log_error "Incomplete metadata entry for ${key:-unknown} in .NET ${channel}."
            return 1
        fi
        validate_download_url "${url}" "${allow_file}" || return 1
        if [[ ! "${hash}" =~ ^[0-9a-fA-F]{128}$ ]]; then
            log_error "Invalid SHA-512 digest format for ${key}: ${hash}"
            return 1
        fi
        fname="${url##*/}"
        fname="${fname%%\?*}"
        if [[ -z "${fname}" || "${fname}" != *.exe ]]; then
            log_error "Unexpected installer filename '${fname}' derived from URL: ${url}"
            return 1
        fi
        printf '%s\t%s\t%s\t%s\n' "${key}" "${fname}" "${url}" "${hash,,}" >> "${out_manifest}"
        count=$((count + 1))
    done <<< "${jq_output}"

    if [[ "${count}" -ne 5 ]]; then
        log_error "Expected 5 installer components for .NET ${channel}, found ${count}."
        return 1
    fi

    return 0
}

# Inspects local zip archive; echoes "<status>\t<runtime_ver>\t<sdk_ver>\t<entry_list_csv>"
inspect_local_archive() {
    local zip_path="$1"

    if [[ ! -f "${zip_path}" ]]; then
        printf 'MISSING\t-\t-\t\n'
        return 0
    fi

    if ! verify_zip_integrity "${zip_path}"; then
        printf 'CORRUPT\t?\t?\t\n'
        return 0
    fi

    local entries_raw
    entries_raw="$(unzip -Z1 "${zip_path}" 2>/dev/null || true)"
    if [[ -z "${entries_raw}" ]]; then
        printf 'CORRUPT\t?\t?\t\n'
        return 0
    fi

    local rt_ver="-"
    local sdk_ver="-"
    local entry_count=0
    local invalid_layout=0
    local csv=""
    local entry

    while IFS= read -r entry; do
        [[ -z "${entry}" ]] && continue
        entry_count=$((entry_count + 1))
        if [[ "${entry}" == */* ]]; then
            invalid_layout=1
        fi
        if [[ "${entry}" =~ ^dotnet-runtime-(.+)-win-x64\.exe$ ]]; then
            rt_ver="${BASH_REMATCH[1]}"
        elif [[ "${entry}" =~ ^dotnet-sdk-(.+)-win-x64\.exe$ ]]; then
            sdk_ver="${BASH_REMATCH[1]}"
        fi
        if [[ -z "${csv}" ]]; then
            csv="${entry}"
        else
            csv="${csv},${entry}"
        fi
    done <<< "${entries_raw}"

    if [[ "${invalid_layout}" -eq 1 || "${entry_count}" -ne 5 ]]; then
        printf 'INCOMPLETE\t%s\t%s\t%s\n' "${rt_ver}" "${sdk_ver}" "${csv}"
        return 0
    fi

    printf 'PRESENT\t%s\t%s\t%s\n' "${rt_ver}" "${sdk_ver}" "${csv}"
}

# ------------------------------------------------------------------------------
# Channel Processing
# ------------------------------------------------------------------------------
record_summary() {
    local ch="$1" l_rt="$2" l_sdk="$3" u_rt="$4" u_sdk="$5" res="$6"
    SUMMARY_ROWS+=("${ch}|${l_rt}|${l_sdk}|${u_rt}|${u_sdk}|${res}")
}

fail_channel() {
    record_summary "$1" "$2" "$3" "$4" "$5" "ERROR"
    return 1
}

_publish_zip() {
    local src_zip="$1"
    local dest_zip="$2"
    local label="$3"
    local padded_label

    atomic_publish_file "${src_zip}" "${dest_zip}" "${label}" true || return 1
    printf -v padded_label '%-10s' "[${label}]"
    log_info "  ${padded_label}   $(enforce_drive_path "${dest_zip}")"
}

process_channel() {
    local channel="$1"
    local zip_name="dotnetfx-${channel}-win.zip"
    local local_zip="${ARCHIVE_DIR}/${zip_name}"
    local staging_zip="${STAGING_DIR}/${zip_name}"
    local manifest="${EXEC_WORKSPACE}/manifest-${channel}.tsv"
    local allow_file=false
    _allow_file_scheme && allow_file=true

    log_info "=== Processing .NET ${channel} (${zip_name}) ==="

    if ! fetch_upstream_metadata "${channel}" "${manifest}"; then
        fail_channel "${channel}" "?" "?" "?" "?" || return 1
    fi

    local upstream_rel="" upstream_sdk=""
    local -a comp_keys=() comp_files=() comp_urls=() comp_hashes=()
    local line_idx=0
    while IFS=$'\t' read -r col1 col2 col3 col4; do
        if [[ "${line_idx}" -eq 0 ]]; then
            upstream_rel="${col1}"
            upstream_sdk="${col2}"
        else
            comp_keys+=("${col1}")
            comp_files+=("${col2}")
            comp_urls+=("${col3}")
            comp_hashes+=("${col4}")
        fi
        line_idx=$((line_idx + 1))
    done < "${manifest}"

    local local_info local_state local_rt local_sdk local_csv
    local_info="$(inspect_local_archive "${local_zip}")"
    IFS=$'\t' read -r local_state local_rt local_sdk local_csv <<< "${local_info}"

    local need_update=0
    local reason=""

    if [[ "${FORCE}" -eq 1 ]]; then
        need_update=1
        reason="forced rebuild"
    elif [[ "${local_state}" == "MISSING" ]]; then
        need_update=1
        reason="archive missing"
    elif [[ "${local_state}" == "CORRUPT" || "${local_state}" == "INCOMPLETE" ]]; then
        need_update=1
        reason="archive ${local_state,,}"
    elif [[ "${local_rt}" != "${upstream_rel}" || "${local_sdk}" != "${upstream_sdk}" ]]; then
        need_update=1
        reason="version mismatch"
    else
        local missing_comp=0
        local fname
        for fname in "${comp_files[@]}"; do
            if ! csv_contains "${local_csv}" "${fname}"; then
                missing_comp=1
                break
            fi
        done
        if [[ "${missing_comp}" -eq 1 ]]; then
            need_update=1
            reason="component filenames differ"
        fi
    fi

    log_info ".NET ${channel}: local=[${local_state}: runtime=${local_rt}, sdk=${local_sdk}] vs upstream=[runtime=${upstream_rel}, sdk=${upstream_sdk}]"

    if [[ "${need_update}" -eq 0 ]]; then
        log_info ".NET ${channel}: Archive is up to date. Skipping build and staging."
        record_summary "${channel}" "${local_rt}" "${local_sdk}" "${upstream_rel}" "${upstream_sdk}" "UP-TO-DATE"
        return 0
    fi

    if [[ "${DRY_RUN}" -eq 1 ]]; then
        log_info "[DRY-RUN] Would update ${zip_name} (reason: ${reason})."
        record_summary "${channel}" "${local_rt}" "${local_sdk}" "${upstream_rel}" "${upstream_sdk}" "WOULD_UPDATE (${reason})"
        return 0
    fi

    log_info "Updating ${zip_name} (reason: ${reason})..."

    local payload_dir="${EXEC_WORKSPACE}/payload-${channel}"
    local build_dir="${EXEC_WORKSPACE}/build-${channel}"
    mkdir -p "${payload_dir}" "${build_dir}"

    local idx fname url expected_hash reused
    for idx in "${!comp_files[@]}"; do
        fname="${comp_files[${idx}]}"
        url="${comp_urls[${idx}]}"
        expected_hash="${comp_hashes[${idx}]}"
        reused=0

        if [[ "${FORCE}" -eq 0 && "${local_state}" != "MISSING" && "${local_state}" != "CORRUPT" ]] && csv_contains "${local_csv}" "${fname}"; then
            log_debug "Attempting reuse of ${fname} from ${local_zip}"
            if (cd "${payload_dir}" && unzip -q -j "${local_zip}" "${fname}" >/dev/null 2>&1) && [[ -f "${payload_dir}/${fname}" ]]; then
                if verify_file_checksum "${payload_dir}/${fname}" "${expected_hash}" "sha512"; then
                    log_info "  [Reused]     ${fname} (SHA-512 verified)"
                    reused=1
                else
                    log_warn "  Local copy of ${fname} failed SHA-512 check; re-downloading."
                    safe_rm_f "${payload_dir}/${fname}"
                fi
            fi
        fi

        if [[ "${reused}" -eq 0 ]]; then
            log_info "  [Download]   ${fname}"
            log_debug "    URL: ${url}"
            if ! download_asset "${url}" "${payload_dir}/${fname}" "${expected_hash}" "sha512" "${allow_file}"; then
                fail_channel "${channel}" "${local_rt}" "${local_sdk}" "${upstream_rel}" "${upstream_sdk}" || return 1
            fi
            log_info "  [Verified]   ${fname} (SHA-512 OK)"
        fi
    done

    local built_zip="${build_dir}/${zip_name}"
    log_info "  Packaging ${zip_name}..."
    if ! (cd "${payload_dir}" && zip -q "../build-${channel}/${zip_name}" "${comp_files[@]}"); then
        log_error "Failed to create ${zip_name}"
        fail_channel "${channel}" "${local_rt}" "${local_sdk}" "${upstream_rel}" "${upstream_sdk}" || return 1
    fi

    if ! verify_zip_integrity "${built_zip}"; then
        log_error "Built archive failed unzip integrity check: ${built_zip}"
        fail_channel "${channel}" "${local_rt}" "${local_sdk}" "${upstream_rel}" "${upstream_sdk}" || return 1
    fi

    # Stage BEFORE committing to the archive repository so a staging failure
    # leaves the archive out-of-date and recoverable on retry without --force.
    local status_tags=()

    if [[ "${NO_STAGING}" -eq 0 ]]; then
        if ! _publish_zip "${built_zip}" "${staging_zip}" "Staged"; then
            fail_channel "${channel}" "${local_rt}" "${local_sdk}" "${upstream_rel}" "${upstream_sdk}" || return 1
        fi
        status_tags+=("STAGED")
    fi

    if [[ "${NO_UPDATE_ARCHIVE}" -eq 0 ]]; then
        if ! _publish_zip "${built_zip}" "${local_zip}" "Archived"; then
            fail_channel "${channel}" "${local_rt}" "${local_sdk}" "${upstream_rel}" "${upstream_sdk}" || return 1
        fi
        status_tags+=("ARCHIVED")
    fi

    local final_action
    final_action="$(IFS='+'; printf '%s' "${status_tags[*]}")"
    record_summary "${channel}" "${local_rt}" "${local_sdk}" "${upstream_rel}" "${upstream_sdk}" "${final_action}"
    return 0
}

print_summary() {
    printf '\n'
    printf '%-8s %-14s %-14s %-14s %-14s %s\n' \
        "CHANNEL" "LOCAL_RUNTIME" "LOCAL_SDK" "UPSTREAM_RT" "UPSTREAM_SDK" "RESULT"
    printf '%-8s %-14s %-14s %-14s %-14s %s\n' \
        "-------" "-------------" "-------------" "-------------" "-------------" "------"

    local row ch l_rt l_sdk u_rt u_sdk res
    for row in "${SUMMARY_ROWS[@]}"; do
        IFS='|' read -r ch l_rt l_sdk u_rt u_sdk res <<< "${row}"
        printf '%-8s %-14s %-14s %-14s %-14s %s\n' \
            "${ch}" "${l_rt}" "${l_sdk}" "${u_rt}" "${u_sdk}" "${res}"
    done
    printf '\n'
}

# ------------------------------------------------------------------------------
# Main Entry Point
# ------------------------------------------------------------------------------
main() {
    check_dependencies
    parse_args "$@"

    if [[ "${DRY_RUN}" -eq 0 ]]; then
        acquire_lock "dotnet_packaging" "${ARCHIVE_DIR}|${STAGING_DIR}" || exit 1
    fi

    EXEC_WORKSPACE="$(create_temp_workdir "dotnet_pkg_")"
    log_debug "Platform: ${PLATFORM}"
    log_debug "Workspace: ${EXEC_WORKSPACE}"
    log_info "Archive directory: $(enforce_drive_path "${ARCHIVE_DIR}")"
    if [[ "${NO_STAGING}" -eq 0 ]]; then
        log_info "Staging directory: $(enforce_drive_path "${STAGING_DIR}")"
    else
        log_info "Staging directory: <disabled via --no-staging>"
    fi

    local overall_rc=0
    local channel
    for channel in "${CHANNELS[@]}"; do
        if ! process_channel "${channel}"; then
            overall_rc=1
        fi
    done

    print_summary
    trap - ERR
    return "${overall_rc}"
}

main "$@"
