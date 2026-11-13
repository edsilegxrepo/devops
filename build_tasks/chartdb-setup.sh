#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
    cat <<'EOF'
Usage:
  ./chartdb-setup.sh --deploy <cmd> --target <path> [--host HOST]

Commands:
  install   Clone the ChartDB repository into a new target, install dependencies, and approve required install scripts.
  update    Fast-forward the local checkout, reinstall dependencies, and approve required install scripts.
  patch     Upgrade Zod and Monaco, apply the DOMPurify override, apply safe audit fixes, and list the remaining advisories.
  verify    Run the test suite.
  build     Run the production build.
  serve     Serve the built dist directory with a local HTTP server.
  dev       Start the Vite development server.
  full      Run install, patch, and build in sequence on a new target.

Examples:
  ./chartdb-setup.sh --deploy install --target D:/temp/tests/chartdb
  ./chartdb-setup.sh --deploy update --target .
  ./chartdb-setup.sh --deploy patch --target .
  ./chartdb-setup.sh --deploy verify --target .
  ./chartdb-setup.sh --deploy build --target .
  ./chartdb-setup.sh --deploy serve --target . --host 127.0.0.1
  ./chartdb-setup.sh --deploy dev --target . --host 127.0.0.1
  ./chartdb-setup.sh --deploy full --target D:/temp/tests/chartdb
EOF
}

log() {
    printf '\n==> %s\n' "$1"
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf 'Missing required command: %s\n' "$1" >&2
        exit 1
    fi
}

check_min_major() {
    local tool="$1"
    local version="$2"
    local min_major="$3"

    local clean_ver="${version#v}"
    local major="${clean_ver%%.*}"

    if ! [[ "$major" =~ ^[0-9]+$ ]] || [ "$major" -lt "$min_major" ]; then
        printf 'Error: %s >= %d is required, but found %s\n' "$tool" "$min_major" "$version" >&2
        exit 1
    fi
}

validate_node_npm() {
    require_cmd node
    require_cmd npm

    check_min_major "Node.js" "$(node -v 2>/dev/null || echo "")" 20
    check_min_major "npm" "$(npm -v 2>/dev/null || echo "")" 11
}

resolve_path() {
    if [ "$1" = "." ]; then
        pwd
    else
        printf '%s\n' "$1"
    fi
}

require_checkout_dir() {
    local repo_dir="$1"
    local action="$2"

    repo_dir="$(resolve_path "$repo_dir")"

    if [ ! -d "$repo_dir" ]; then
        printf '%s target does not exist: %s\n' "$action" "$repo_dir" >&2
        exit 1
    fi

    if [ ! -f "$repo_dir/package.json" ]; then
        printf '%s target must be an existing ChartDB checkout: %s\n' "$action" "$repo_dir" >&2
        exit 1
    fi

    if [ ! -f "$repo_dir/src/components/code-snippet/config.ts" ] || [ ! -f "$repo_dir/vite.config.ts" ]; then
        printf '%s target must be an existing ChartDB checkout: %s\n' "$action" "$repo_dir" >&2
        exit 1
    fi

    if ! grep -q '"name": "chartdb"' "$repo_dir/package.json"; then
        printf '%s target must be an existing ChartDB checkout: %s\n' "$action" "$repo_dir" >&2
        exit 1
    fi
}

install_repo() {
    local target_dir="$1"
    local parent_dir

    target_dir="$(resolve_path "$target_dir")"
    parent_dir="$(dirname "$target_dir")"

    require_cmd git
    validate_node_npm

    mkdir -p "$parent_dir"

    if [ -e "$target_dir" ]; then
        printf 'Target already exists: %s\n' "$target_dir" >&2
        exit 1
    fi

    log "Cloning repository into $target_dir"
    git clone https://github.com/chartdb/chartdb "$target_dir"

    log "Installing dependencies"
    (
        cd "$target_dir" || exit 1
        npm install
    )

    approve_install_scripts "$target_dir"
}

approve_install_scripts() {
    local repo_dir="$1"

    repo_dir="$(resolve_path "$repo_dir")"
    validate_node_npm

    log "Approving required install scripts"
    (
        cd "$repo_dir" || exit 1
        npm install-scripts approve esbuild@0.27.2
    )
}

patch_repo() {
    local repo_dir="$1"
    local python_bin="" tmp_audit=""

    repo_dir="$(resolve_path "$repo_dir")"
    validate_node_npm

    if command -v python3 >/dev/null 2>&1; then
        python_bin="python3"
    elif command -v python >/dev/null 2>&1; then
        python_bin="python"
    else
        printf 'Missing required command: python3 or python\n' >&2
        exit 1
    fi

    require_checkout_dir "$repo_dir" "Patch"

    log "Applying ChartDB patch configuration"
    "$python_bin" "$SCRIPT_DIR/chartdb-patch.py" --repo-dir "$repo_dir" --apply all

    log "Applying dependency override install"
    (
        cd "$repo_dir" || exit 1
        npm install
    )

    log "Applying safe npm audit fixes"
    (
        cd "$repo_dir" || exit 1
        npm audit fix || true
    )

    log "Listing remaining advisories"
    tmp_audit="$(mktemp 2>/dev/null || printf '%s/.audit_tmp.json' "$repo_dir")"
    (
        cd "$repo_dir" || exit 1
        npm audit --json > "$tmp_audit" 2>/dev/null || true
    )

    AUDIT_FILE="$tmp_audit" node <<'EOF'
const fs = require('fs');
const auditFile = process.env.AUDIT_FILE || '';
let raw = '';
if (auditFile && fs.existsSync(auditFile)) {
  raw = fs.readFileSync(auditFile, 'utf-8').trim();
}

if (!raw) {
  console.log('No audit data returned.');
  process.exit(0);
}

let report;
try {
  report = JSON.parse(raw);
} catch {
  console.log('No audit data returned.');
  process.exit(0);
}

const vulnerabilities = Object.values(report.vulnerabilities || {});
if (!vulnerabilities.length) {
  console.log('No remaining advisories.');
  process.exit(0);
}

const rootTargets = [];
const transitives = [];

for (const vulnerability of vulnerabilities) {
  if (vulnerability.isDirect) {
    rootTargets.push(vulnerability);
  } else {
    transitives.push(vulnerability);
  }
}

const describeFixStatus = vulnerability => {
  if (vulnerability.fixAvailable === false) {
    return 'no fix available';
  }

  if (vulnerability.fixAvailable && typeof vulnerability.fixAvailable === 'object') {
    return vulnerability.fixAvailable.isSemVerMajor
      ? `requires breaking change to ${vulnerability.fixAvailable.name}@${vulnerability.fixAvailable.version}`
      : `fix available in ${vulnerability.fixAvailable.name}@${vulnerability.fixAvailable.version}`;
  }

  return 'fixable';
};

console.log('Remaining primary advisories:');
for (const vulnerability of rootTargets.sort((a, b) => a.name.localeCompare(b.name))) {
  console.log(`- ${vulnerability.name} [${vulnerability.severity}] — ${describeFixStatus(vulnerability)}`);
}

if (transitives.length) {
  console.log('');
  console.log('Transitively affected packages:');
  for (const vulnerability of transitives.sort((a, b) => a.name.localeCompare(b.name))) {
    const via = Array.isArray(vulnerability.via)
      ? [...new Set(
          vulnerability.via
            .map(entry => typeof entry === 'string' ? entry : entry?.name)
            .filter(name => name && name !== vulnerability.name)
        )].join(', ')
      : '';

    const viaLabel = via || 'dependency chain';
    console.log(`- ${vulnerability.name} [${vulnerability.severity}] — affected via ${viaLabel}`);
  }
}
EOF
    rm -f "$tmp_audit"
}

update_repo() {
    local repo_dir="$1"

    repo_dir="$(resolve_path "$repo_dir")"
    require_cmd git
    validate_node_npm

    require_checkout_dir "$repo_dir" "Update"

    if [ ! -d "$repo_dir/.git" ]; then
        printf 'Update target is not a git repository: %s\n' "$repo_dir" >&2
        exit 1
    fi

    log "Updating repository"
    (
        cd "$repo_dir" || exit 1
        git pull --ff-only origin main
        npm install
    )

    approve_install_scripts "$repo_dir"
}

verify_repo() {
    local repo_dir="$1"

    repo_dir="$(resolve_path "$repo_dir")"
    validate_node_npm
    require_checkout_dir "$repo_dir" "Verify"

    log "Running test suite"
    (
        cd "$repo_dir" || exit 1
        npm test
    )
}

build_repo() {
    local repo_dir="$1"

    repo_dir="$(resolve_path "$repo_dir")"
    validate_node_npm
    require_checkout_dir "$repo_dir" "Build"

    log "Running production build"
    (
        cd "$repo_dir" || exit 1
        npm run build
    )
}

serve_repo() {
    local repo_dir="$1"
    local host="$2"

    repo_dir="$(resolve_path "$repo_dir")"
    validate_node_npm
    require_cmd npx
    require_checkout_dir "$repo_dir" "Serve"

    if [ ! -d "$repo_dir/dist" ]; then
        printf 'Serve target must contain a built dist directory: %s\n' "$repo_dir" >&2
        exit 1
    fi

    log "Serving production build"
    (
        cd "$repo_dir/dist" || exit 1
        npx --yes serve -s -l "tcp://${host}:8080" .
    )
}

dev_repo() {
    local repo_dir="$1"
    local host="$2"

    repo_dir="$(resolve_path "$repo_dir")"
    validate_node_npm
    require_checkout_dir "$repo_dir" "Dev"

    log "Starting development server"
    (
        cd "$repo_dir" || exit 1
        npm run dev -- --host "$host"
    )
}

main() {
    local command=""
    local target=""
    local host="localhost"

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --deploy)
                command="${2:-}"
                shift 2
                ;;
            --target)
                target="${2:-}"
                shift 2
                ;;
            --host)
                host="${2:-localhost}"
                shift 2
                ;;
            -h|--help|help)
                usage
                exit 0
                ;;
            *)
                printf 'Unknown argument: %s\n\n' "$1" >&2
                usage
                exit 1
                ;;
        esac
    done

    if [ -z "$command" ] || [ -z "$target" ]; then
        usage
        exit 1
    fi

    validate_node_npm

    case "$command" in
        install)
            install_repo "$target"
            ;;
        update)
            update_repo "$target"
            ;;
        patch)
            patch_repo "$target"
            ;;
        verify)
            verify_repo "$target"
            ;;
        build)
            build_repo "$target"
            ;;
        serve)
            serve_repo "$target" "$host"
            ;;
        dev)
            dev_repo "$target" "$host"
            ;;
        full)
            install_repo "$target"
            patch_repo "$target"
            build_repo "$target"
            ;;
        *)
            printf 'Unknown deploy command: %s\n\n' "$command" >&2
            usage
            exit 1
            ;;
    esac
}

main "$@"
