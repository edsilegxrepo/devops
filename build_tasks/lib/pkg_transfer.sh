#!/usr/bin/env bash
# ==============================================================================
# lib/pkg_transfer.sh
#
# Shared transfer, cryptographic verification, and GitHub Release API helpers.
# Requires: lib/pkg_core.sh
# ==============================================================================

[[ -n "${_PKG_TRANSFER_SH_LOADED:-}" ]] && return 0
_PKG_TRANSFER_SH_LOADED=1

# ------------------------------------------------------------------------------
# URL Guard & Cryptographic Checksum Helpers
# ------------------------------------------------------------------------------
# validate_download_url <url> [allow_file_scheme]
# Enforces HTTPS downloads unless allow_file_scheme is true (for local fixtures).
validate_download_url() {
    local url="$1"
    local allow_file="${2:-false}"

    if [[ "$allow_file" == true || "$allow_file" == "1" ]]; then
        if [[ "$url" != https://* && "$url" != file://* ]]; then
            log_error "Invalid download URL scheme (expected https:// or file://): ${url}"
            return 1
        fi
    else
        if [[ "$url" != https://* ]]; then
            log_error "Refusing non-HTTPS download URL: ${url}"
            return 1
        fi
    fi
    return 0
}

# _compute_file_hash <file_path> <hash_algo:sha256|sha512>
_compute_file_hash() {
    local file_path="$1"
    local hash_algo="$2"
    local bits=256
    [[ "$hash_algo" == "sha512" ]] && bits=512

    local dir_part base_part
    dir_part=$(dirname "$file_path")
    base_part=$(basename "$file_path")

    if command -v "${hash_algo}sum" > /dev/null 2>&1; then
        (cd "$dir_part" && "${hash_algo}sum" -- "$base_part" | awk '{print $1}')
    elif command -v shasum > /dev/null 2>&1; then
        (cd "$dir_part" && shasum -a "$bits" -- "$base_part" | awk '{print $1}')
    else
        return 2
    fi
}

# verify_file_checksum <file_path> <expected_hash> [hash_algo]
# Supports sha256 and sha512 using sha*sum with portable shasum fallback.
verify_file_checksum() {
    local file_path="$1"
    local expected="$2"
    local hash_algo="${3:-sha512}"
    local expected_lower="${expected,,}"
    local expected_len=128
    [[ "$hash_algo" == "sha256" ]] && expected_len=64

    [[ -f "$file_path" ]] || {
        log_error "Cannot checksum missing file: ${file_path}"
        return 1
    }

    local actual="" rc=0
    actual=$(_compute_file_hash "$file_path" "$hash_algo") || rc=$?
    if [[ $rc -eq 2 ]]; then
        log_warn "Neither ${hash_algo}sum nor shasum found; skipping ${hash_algo^^} check for $(basename "$file_path")."
        return 0
    fi
    actual="${actual,,}"

    if [[ ${#actual} -ne $expected_len || ! "$actual" =~ ^[0-9a-f]+$ ]]; then
        log_error "Failed to compute ${hash_algo^^} checksum for $(basename "$file_path")"
        return 1
    fi

    if [[ "$actual" != "$expected_lower" ]]; then
        log_error "${hash_algo^^} checksum mismatch for $(basename "$file_path")"
        log_error "Expected: $expected_lower"
        log_error "Actual  : $actual"
        return 1
    fi

    return 0
}

# fetch_text <url> [max_time] [allow_file_scheme] [user_agent] [bearer_token] [accept_header]
# Unified HTTP(S) text/JSON fetcher with scheme validation, retries, timeouts,
# and subshell-safe temporary stderr capture (cleans up even inside $(...)).
fetch_text() {
    local url="$1"
    local max_time="${2:-20}"
    local allow_file="${3:-false}"
    local ua="${4:-client-packager}"
    local token="${5:-}"
    local accept="${6:-}"

    validate_download_url "$url" "$allow_file" || return 1

    local tmp_base="${EXEC_WORKSPACE:-${TEMP_ROOT_CYG:-}}"
    if [[ -z "$tmp_base" || ! -d "$tmp_base" || ! -w "$tmp_base" ]]; then
        tmp_base=$(detect_temp_root)
    fi

    local err_file
    err_file=$(mktemp "${tmp_base}/fetch_err.XXXXXX") || return 1
    # Clean up err_file on function return even when called inside $(...) subshells
    trap 'rm -f -- "${err_file:-}" 2>/dev/null || true' RETURN

    local -a headers=()
    [[ -n "$token" ]] && headers+=(-H "Authorization: Bearer ${token}")
    [[ -n "$accept" ]] && headers+=(-H "Accept: ${accept}")
    [[ -n "$ua" ]] && headers+=(-H "User-Agent: ${ua}")

    local response rc=0
    response=$(curl -fsSL --connect-timeout 10 --max-time "$max_time" --retry 3 --retry-delay 2 \
        "${headers[@]}" \
        "$url" 2> "$err_file") || rc=$?

    local err_msg=""
    err_msg=$(tr '\r\n' '  ' < "$err_file" 2> /dev/null || true)
    rm -f -- "$err_file" 2> /dev/null || true
    trap - RETURN

    if [[ $rc -ne 0 ]]; then
        log_warn "Request failed (exit=${rc}) for ${url}: ${err_msg:-curl error}"
        return "$rc"
    fi

    printf '%s' "$response"
}

# write_sha256_manifest <output_file> <file1> [file2...]
# Computes SHA-256 digests with basename entries via sha256sum or shasum -a 256
# and writes the manifest atomically to output_file.
write_sha256_manifest() {
    local out_file="$1"
    shift
    [[ $# -ge 1 ]] || {
        log_error "write_sha256_manifest requires at least one file."
        return 1
    }

    mkdir -p "$(dirname "$out_file")" || return 1
    local tmp_out="${out_file}.tmp.$$"
    _CURRENT_TMP_FILE="$tmp_out"
    : > "$tmp_out"

    local f hash_val
    for f in "$@"; do
        [[ -f "$f" ]] || {
            log_error "Cannot hash missing file for manifest: $f"
            safe_rm_f "$tmp_out"
            _CURRENT_TMP_FILE=""
            return 1
        }
        hash_val=$(_compute_file_hash "$f" "sha256") || {
            log_error "SHA-256 tool unavailable (need sha256sum or shasum)."
            safe_rm_f "$tmp_out"
            _CURRENT_TMP_FILE=""
            return 1
        }
        printf '%s  %s\n' "${hash_val,,}" "$(basename "$f")" >> "$tmp_out"
    done

    if ! mv -f -- "$tmp_out" "$out_file"; then
        safe_rm_f "$tmp_out"
        _CURRENT_TMP_FILE=""
        return 1
    fi
    _CURRENT_TMP_FILE=""
    return 0
}

# download_asset <url> <dest_file> [expected_hash] [hash_algo] [allow_file_scheme]
# Validates scheme, streams via curl with timeouts/retries into a temp .part file,
# validates optional checksum, and atomically promotes to dest_file.
download_asset() {
    local url="$1"
    local dest_file="$2"
    local expected_hash="${3:-}"
    local hash_algo="${4:-sha512}"
    local allow_file="${5:-false}"

    validate_download_url "$url" "$allow_file" || return 1
    mkdir -p "$(dirname "$dest_file")" || return 1

    local part_file="${dest_file}.part.$$"
    _CURRENT_TMP_FILE="$part_file"

    if ! curl -fsSL --connect-timeout 15 --max-time 300 --retry 3 --retry-delay 2 -o "$part_file" "$url"; then
        log_error "Failed to download asset from $url"
        safe_rm_f "$part_file"
        _CURRENT_TMP_FILE=""
        return 1
    fi

    if [[ -n "$expected_hash" ]]; then
        if ! verify_file_checksum "$part_file" "$expected_hash" "$hash_algo"; then
            safe_rm_f "$part_file"
            _CURRENT_TMP_FILE=""
            return 1
        fi
        log_debug "Verified ${hash_algo^^} checksum for $(basename "$dest_file")."
    fi

    if ! mv -f -- "$part_file" "$dest_file"; then
        log_error "Failed to finalize downloaded file: $dest_file"
        safe_rm_f "$part_file"
        _CURRENT_TMP_FILE=""
        return 1
    fi
    _CURRENT_TMP_FILE=""
    return 0
}

# ------------------------------------------------------------------------------
# GitHub Releases API Engine
# ------------------------------------------------------------------------------
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

    local response=""
    if ! response=$(fetch_text "$url" 30 false "$ua" "$token" "application/vnd.github+json") || [[ -z "$response" ]]; then
        log_warn "GitHub API request failed or returned empty response for ${repo}"
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
        if download_asset "$sum_url" "$sum_file" "" "sha256" false 2> /dev/null; then
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
        sc_body=$(fetch_text "$sidecar_url" 15 false 2> /dev/null || true)
        if [[ "$sc_body" =~ ([0-9a-fA-F]{64}) ]]; then
            printf '%s' "${BASH_REMATCH[1],,}"
            return 0
        fi
    fi

    local sum_text
    sum_text=$(gh_fetch_release_checksums "$rel_json" "$cache_dir" || true)
    if [[ -n "$sum_text" ]]; then
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
