#!/usr/bin/env bash
# ==============================================================================
# lib/pkg_json.sh
#
# Portable JSON escaping, NDJSON audit logging, and 4-tier JSON extraction
# (jq -> python3 -> python -> awk fallback). Zero side-effect traps.
# ==============================================================================

[[ -n "${_PKG_JSON_SH_LOADED:-}" ]] && return 0
_PKG_JSON_SH_LOADED=1

NDJSON_LOG_FILE="${NDJSON_LOG_FILE:-}"

# json_escape <raw_string>
# Sanitizes raw strings for RFC 8259 JSON embedding (escapes backslashes,
# double quotes, and flattens newlines/carriage returns/tabs to spaces).
json_escape() {
    local s="${1:-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="$(printf '%s' "${s}" | tr '\n' ' ' | tr '\r' ' ' | tr '\t' ' ')"
    printf '%s' "${s}"
}

# log_ndjson <level> <event> <message> [extra_json_object]
# Appends structured NDJSON audit entries to $NDJSON_LOG_FILE (no-op when unset).
log_ndjson() {
    local level="$1"
    local event="$2"
    local msg="$3"
    local extra="${4:-}"

    [ -z "${NDJSON_LOG_FILE:-}" ] && return 0

    local timestamp
    timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2> /dev/null || date +"%Y-%m-%dT%H:%M:%SZ")"
    local esc_module esc_level esc_event esc_msg
    esc_module="$(json_escape "${APP_NAME:-$(basename "$(pwd)")}")"
    esc_level="$(json_escape "${level}")"
    esc_event="$(json_escape "${event}")"
    esc_msg="$(json_escape "${msg}")"

    local line="{\"timestamp\":\"${timestamp}\",\"module\":\"${esc_module}\",\"level\":\"${esc_level}\",\"event\":\"${esc_event}\",\"message\":\"${esc_msg}\""
    if [ -n "${extra}" ]; then
        line="${line},\"details\":${extra}}"
    else
        line="${line}}"
    fi

    printf '%s\n' "${line}" >> "${NDJSON_LOG_FILE}" 2> /dev/null || true
}

# _find_python_bin
# Discovers an available Python interpreter (python3 before python).
_find_python_bin() {
    if command -v python3 &> /dev/null; then
        echo "python3"
    elif command -v python &> /dev/null; then
        echo "python"
    else
        return 1
    fi
}

# parse_json_field <json_file> <key> [default_val]
# Extracts a top-level string/scalar field using jq -> python3/python -> awk.
parse_json_field() {
    local json_file="${1:-}"
    local key="${2:-}"
    local default_val="${3:-}"
    local result="" py_bin=""

    if [ ! -f "${json_file}" ]; then
        echo "${default_val}"
        return
    fi

    if command -v jq &> /dev/null; then
        result=$(jq -r --arg k "${key}" '.[$k] // empty' "${json_file}" 2> /dev/null || true)
    elif py_bin="$(_find_python_bin)"; then
        result=$("$py_bin" -c "import json, sys; d=json.load(open(sys.argv[1], encoding='utf-8')); v=d.get(sys.argv[2], ''); print(v if v is not None else '')" "${json_file}" "${key}" 2> /dev/null || true)
    else
        result=$(awk -v k="\"${key}\"" '
          $0 ~ "^[[:space:]]*" k "[[:space:]]*:" {
            sub(/^[^:]*:[[:space:]]*/, "");
            sub(/,[[:space:]]*$/, "");
            sub(/^"/, "");
            sub(/"$/, "");
            print;
            exit;
          }
        ' "${json_file}" 2> /dev/null || true)
    fi

    if [ -n "${result}" ] && [ "${result}" != "null" ]; then
        echo "${result}"
    else
        echo "${default_val}"
    fi
}

# parse_json_history <json_file>
# Extracts .history array entries or multi-line string from a JSON manifest.
parse_json_history() {
    local json_file="${1:-}"
    [ ! -f "${json_file}" ] && return

    local result="" py_bin=""
    if command -v jq &> /dev/null; then
        result=$(jq -r 'if .history == null then empty elif (.history | type) == "array" then .history[] elif (.history | type) == "string" then .history else empty end' "${json_file}" 2> /dev/null || true)
    elif py_bin="$(_find_python_bin)"; then
        result=$("$py_bin" -c "import json, sys; d=json.load(open(sys.argv[1], encoding='utf-8')); h=d.get('history'); (sys.stdout.write('\n'.join(h) + '\n') if isinstance(h, list) else sys.stdout.write(str(h) + '\n')) if h else None" "${json_file}" 2> /dev/null || true)
    else
        result=$(awk '
          BEGIN { in_arr = 0; }
          /"history"[[:space:]]*:[[:space:]]*\[/ {
            in_arr = 1;
            next;
          }
          in_arr {
            if ($0 ~ /\]/) {
              in_arr = 0;
              next;
            }
            line = $0;
            sub(/^[[:space:]]*"/, "", line);
            sub(/",?[[:space:]]*$/, "", line);
            gsub(/\\"/, "\"", line);
            print line;
            next;
          }
          /"history"[[:space:]]*:[[:space:]]*"/ {
            line = $0;
            sub(/^[^:]*:[[:space:]]*"/, "", line);
            sub(/"[[:space:]]*,?[[:space:]]*$/, "", line);
            gsub(/\\n/, "\n", line);
            gsub(/\\"/, "\"", line);
            print line;
          }
        ' "${json_file}" 2> /dev/null || true)
    fi

    echo "${result}"
}
