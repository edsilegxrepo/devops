#!/usr/bin/env bash
# -----------------------------------------------------------------------------
#  python_systools/py_module_manager.sh
#  v1.0.1  2026/04/15  XdG
# -----------------------------------------------------------------------------
# OBJECTIVE:
#   A modular, cross-platform utility to manage the lifecycle of Python packages.
#   It facilitates environment replication through registry-based backups and 
#   restores, while providing direct package management (install/remove) with 
#   automatic registry synchronization.
#
# CORE COMPONENTS:
#   1. Configuration Registry (CONF): An associative array providing a single 
#      source of truth for script state, resolving priorities (CLI > Env > Defaults).
#   2. Portability Layer (normalize_path): Bridges the gap between Windows paths 
#      and Unix-style environments (Cygwin/MSYS2) using cygpath.
#   3. Action Handlers: High-level logic for individual lifecycle operations.
#   4. Reconciliation Engine: A status action that audits the live environment 
#      against a target registry file to identify version drift or missing pkgs.
#
# FUNCTIONALITY:
#   - backup: Fully syncs the registry file with the current environment.
#   - restore: Installs all packages listed in the registry via 'pip install -r'.
#   - list: Renders the registry in text or structured JSON (via jq).
#   - install: Installs specific packages and auto-refreshes the registry.
#   - remove: Uninstalls packages and auto-refreshes the registry.
#   - status: Produces a reconciliation report between live state and registry.
#
# DATA FLOW:
#   [Input Layer]      --> [Normalization]  --> [Validation]   --> [Execution]
#   CLI Args/Env Vars      cygpath -u/-w        Dependency Check    Pip Ops
#                                               Path Existence      Refine Registry
#
# USAGE EXAMPLES:
#   1. Backup:
#      ./py_module_manager.sh --python=/usr/bin/python3 --action=backup --registry=pkgs.txt
#
#   2. Restore:
#      ./py_module_manager.sh --python=/usr/bin/python3 --action=restore --registry=pkgs.txt
#
#   3. List (JSON):
#      ./py_module_manager.sh --action=list --registry=pkgs.txt --format=json
#
#   4. Managed Lifecycle (Install/Remove/Status):
#      ./py_module_manager.sh --action=install:requests,urllib3 --registry=pkgs.txt
#      ./py_module_manager.sh --action=status:requests --registry=pkgs.txt
# -----------------------------------------------------------------------------

set -euo pipefail

# ----- 1. Global Configuration Registry -----
# CONF associative array holds the script's global state.
# Priorities: Command Line Args > Environment Variables > Defaults.
declare -A CONF
CONF[PYTHON_BIN]="${PYTHON:-}"
CONF[JQ_BIN]="${JQ:-jq}"
CONF[REGISTRY_FILE]="${PYTHON_PKG_REGISTRY:-}"
CONF[ACTION]=""
CONF[PKG_LIST]=""
CONF[FORMAT]="text"

# Suppress persistent pip root-user warnings in DevOps contexts
export PIP_ROOT_USER_ACTION=ignore

# ----- 2. Log and Error Handling -----
log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

# normalize_path(): Seamlessly handles Windows/Unix path conversion on Cygwin/MSYS.
normalize_path() {
    local p="$1"
    [ -z "$p" ] && return 0
    if [[ "${OSTYPE:-}" == "cygwin" || "${OSTYPE:-}" == "msys" ]] && command -v cygpath &>/dev/null; then
        cygpath -u "$p"
    else
        echo "$p"
    fi
}

# ----- 3. Argument Parsing & CLI Logic -----
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Required:
  --action=<action>   Action to perform: backup, restore, list,
                      install:<pkgs>, remove:<pkgs>, status:<pkgs>|all

Options:
  --python=<path>     Path to the python binary (Default: \$PYTHON)
  --jq=<path>         Path to the jq binary (Default: \$JQ or 'jq' in PATH)
  --registry=<path>   Registry file for packages (Default: \$PYTHON_PKG_REGISTRY)
  --format=<format>   Output format for 'list' action: text (default), json
  --help              Display this help message

Environment Variables:
  PYTHON              Used if --python is not specified.
  JQ                  Used if --jq is not specified.
  PYTHON_PKG_REGISTRY Used if --registry is not specified.

Examples:
  ./py_module_manager.sh --python=/opt/bin/python3.14 --action=backup --registry=current.txt
  ./py_module_manager.sh --action=list --registry=current.txt --format=json
  ./py_module_manager.sh --action=install:requests,urllib3 --registry=current.txt
  ./py_module_manager.sh --action=status:requests,missing_pkg --registry=current.txt
  ./py_module_manager.sh --action=status:all --registry=current.txt
EOF
}

parse_args() {
    # Normalize any paths sourced from environment variables initially
    CONF[PYTHON_BIN]=$(normalize_path "${CONF[PYTHON_BIN]}")
    CONF[JQ_BIN]=$(normalize_path "${CONF[JQ_BIN]}")
    CONF[REGISTRY_FILE]=$(normalize_path "${CONF[REGISTRY_FILE]}")

    [ $# -eq 0 ] && usage && exit 0

    for arg in "$@"; do
        case $arg in
            --help) usage; exit 0 ;;
            --python=*) CONF[PYTHON_BIN]=$(normalize_path "${arg#*=}") ;;
            --jq=*)     CONF[JQ_BIN]=$(normalize_path "${arg#*=}") ;;
            --action=install:*)
                CONF[ACTION]="install"
                CONF[PKG_LIST]="${arg#*install:}"
                ;;
            --action=remove:*)
                CONF[ACTION]="remove"
                CONF[PKG_LIST]="${arg#*remove:}"
                ;;
            --action=remove::*) # Handle double-colon case from request
                CONF[ACTION]="remove"
                CONF[PKG_LIST]="${arg#*remove::}"
                ;;
            --action=status:*)
                CONF[ACTION]="status"
                CONF[PKG_LIST]="${arg#*status:}"
                ;;
            --action=*) CONF[ACTION]="${arg#*=}" ;;
            --registry=*) CONF[REGISTRY_FILE]=$(normalize_path "${arg#*=}") ;;
            --format=*)   CONF[FORMAT]="${arg#*=}" ;;
            *) error "Unknown argument: $arg" ;;
        esac
    done

    # Final validation of required fields after priority resolution
    [ -z "${CONF[ACTION]}" ] && error "--action is required (backup, restore, list, install, remove, status)."
    [ -z "${CONF[REGISTRY_FILE]}" ] && error "Registry file not specified and \$PYTHON_PKG_REGISTRY is empty."
    
    # Python binary is required for most actions
    if [[ "${CONF[ACTION]}" == "backup" || "${CONF[ACTION]}" == "restore" || "${CONF[ACTION]}" == "install" || "${CONF[ACTION]}" == "remove" || "${CONF[ACTION]}" == "status" ]]; then
        if [ -z "${CONF[PYTHON_BIN]}" ]; then
            error "Python binary not specified and \$PYTHON is empty."
        fi
    fi

    # PKG_LIST check
    if [[ "${CONF[ACTION]}" == "install" || "${CONF[ACTION]}" == "remove" || "${CONF[ACTION]}" == "status" ]]; then
        if [ -z "${CONF[PKG_LIST]}" ]; then
            error "Action ${CONF[ACTION]} requires a package list (action:${CONF[ACTION]}:pkg1,pkg2)."
        fi
    fi
}

# ----- 4. Validation Layer -----
# validate_env: Performs pre-flight checks on binaries and file system access.
# Ensures the Python binary exists, pip is available, and the registry file
# is accessible based on the requested action.
validate_env() {
    # Check Python binary if needed
    if [[ "${CONF[ACTION]}" == "backup" || "${CONF[ACTION]}" == "restore" || "${CONF[ACTION]}" == "install" || "${CONF[ACTION]}" == "remove" || "${CONF[ACTION]}" == "status" ]]; then
        if [ ! -x "${CONF[PYTHON_BIN]}" ]; then
            error "Python binary not found or not executable: ${CONF[PYTHON_BIN]}"
        fi
        
        # Verify pip accessibility
        if ! "${CONF[PYTHON_BIN]}" -m pip --version &>/dev/null; then
            error "The 'pip' module is not available for ${CONF[PYTHON_BIN]}"
        fi
    fi

    # Verify site-packages (purelib/platlib) writability for state-changing actions
    if [[ "${CONF[ACTION]}" == "restore" || "${CONF[ACTION]}" == "install" || "${CONF[ACTION]}" == "remove" ]]; then
        log "Checking writability of Python library paths..."
        # Fetch unique install paths to avoid redundant checks
        local lib_paths=$("${CONF[PYTHON_BIN]}" -c "import sysconfig; s={sysconfig.get_path('purelib'), sysconfig.get_path('platlib')}; print('\n'.join(p for p in s if p))" | tr -d '\r')
        
        for path in $lib_paths; do
            if [ ! -w "$path" ]; then
                error "Python library path is not writable: $path. This prevents global package management. Please check permissions."
            fi
        done
    fi

    # Check Registry Access
    case "${CONF[ACTION]}" in
        backup)
            local reg_dir=$(dirname "${CONF[REGISTRY_FILE]}")
            if [ ! -d "$reg_dir" ]; then
                log "Creating registry directory: $reg_dir"
                mkdir -p "$reg_dir"
            fi
            if [ ! -w "$reg_dir" ]; then
                error "Registry directory is not writable: $reg_dir"
            fi
            ;;
        restore|list)
            if [ ! -f "${CONF[REGISTRY_FILE]}" ]; then
                error "Registry file not found: ${CONF[REGISTRY_FILE]}"
            fi
            if [ ! -r "${CONF[REGISTRY_FILE]}" ]; then
                error "Registry file is not readable: ${CONF[REGISTRY_FILE]}"
            fi
            ;;
    esac

    # Hard dependency check for JSON output.
    # The --jq flag is optional; if missing, we fall back to JQ env var or 'jq' in PATH.
    if [[ "${CONF[ACTION]}" == "list" && "${CONF[FORMAT]}" == "json" ]]; then
        if ! command -v "${CONF[JQ_BIN]}" &>/dev/null && [ ! -x "${CONF[JQ_BIN]}" ]; then
            error "JSON output format requires 'jq'. Please install it or use --format=text / --jq=<path>."
        fi
    fi
}

# ----- 5. Action Handlers -----

# backup_packages: Synchronizes the registry file with the current environment.
# Uses 'pip freeze' to capture exact versions and installation sources.
backup_packages() {
    log "Initiating backup for Python: ${CONF[PYTHON_BIN]}"
    log "Target Registry: ${CONF[REGISTRY_FILE]}"
    
    # Use --all to ensure core packages like 'pip' and 'setuptools' are captured.
    if "${CONF[PYTHON_BIN]}" -m pip freeze --all | tr -d '\r' > "${CONF[REGISTRY_FILE]}"; then
        log "Backup successful. Captured $(wc -l < "${CONF[REGISTRY_FILE]}") packages."
    else
        error "Failed to capture package state using pip freeze."
    fi
}

# restore_packages: Reinstalls an environment from the registry file.
# Relies on 'pip install -r' which handles dependency resolution and skipping
# already-satisfied requirements.
restore_packages() {
    log "Initiating restore for Python: ${CONF[PYTHON_BIN]}"
    log "Source Registry: ${CONF[REGISTRY_FILE]}"
    
    if "${CONF[PYTHON_BIN]}" -m pip install -r "${CONF[REGISTRY_FILE]}"; then
        log "Restore process completed successfully."
    else
        error "Pip installation failed during restore process."
    fi
}

# list_packages: Renders the registry content for human or machine consumption.
# Supports plain text listing or structured JSON via jq.
list_packages() {
    local data_file="${CONF[REGISTRY_FILE]}"
    
    if [[ "${CONF[FORMAT]}" == "text" ]]; then
        log "Listing packages from registry (Sorted):"
        grep -v '^#' "$data_file" | grep -v '^$' | tr -d '\r' | sort
    elif [[ "${CONF[FORMAT]}" == "json" ]]; then
        # Parse registry into a structured JSON array
        # Handles standard 'pkg==version' and 'pkg @ url' formats.
      grep -v '^#' "$data_file" | grep -v '^$' | tr -d '\r' | sort | "${CONF[JQ_BIN]}" -R -n '
            [ inputs | 
              if contains("==") then
                split("==") | {name: .[0], version: .[1], source: "pypi"}
              elif contains(" @ ") then
                split(" @ ") | {name: .[0], version: "latest", source: .[1]}
              else
                {name: ., version: "unknown", source: "unknown"}
              end
            ]
        '
    else
        error "Unsupported format requested: ${CONF[FORMAT]}"
    fi
}

# install_pkg_list: Installs targeted packages and updates the registry.
# Re-running backup_packages after install ensures the registry captures
# the exact versions and dependencies that were just added.
install_pkg_list() {
    local pkgs=${CONF[PKG_LIST]//,/ }
    log "Installing packages: $pkgs"
    if "${CONF[PYTHON_BIN]}" -m pip install $pkgs; then
        log "Installation successful. Refreshing registry..."
        backup_packages
    else
        error "Failed to install packages: $pkgs"
    fi
}

remove_pkg_list() {
    local pkgs=${CONF[PKG_LIST]//,/ }
    log "Removing packages: $pkgs"
    if "${CONF[PYTHON_BIN]}" -m pip uninstall -y $pkgs; then
        log "Removal successful. Refreshing registry..."
        backup_packages
    else
        error "Failed to remove packages: $pkgs"
    fi
}

# status_pkg_list: Analyzes a subset of packages for drift against the registry.
# For each package, it calculates a reconciliation state (MATCH, MISMATCH, etc.)
# by auditing the live 'pip show' data against the stored registry entry.
status_pkg_list() {
    local data_file="${CONF[REGISTRY_FILE]}"
    
    # 1. Bulk Fetch Live Status (High Performance: 1 process spawn instead of N)
    log "Auditing live environment state..."
    declare -A live_map
    while IFS=: read -r name ver; do
        [ -n "$name" ] && live_map["$name"]="$ver"
    done < <( "${CONF[PYTHON_BIN]}" -c "import importlib.metadata as m; print('\n'.join(f'{d.metadata[\"Name\"].lower()}:{d.version}' for d in m.distributions()))" | tr -d '\r' )

    # 2. Bulk Fetch Registry Status
    log "Parsing registry metadata..."
    declare -A reg_map
    while read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^# ]] && continue
        [[ -z "$line" ]] && continue
        
        local p="" v=""
        if [[ "$line" == *"=="* ]]; then
            p="${line%%==*}"; v="${line##*==}"
        elif [[ "$line" == *" @ "* ]]; then
            p="${line%% @ *}"; v="${line##* @ }"
        else
            p="$line"; v=""
        fi
        local ln=$(echo "$p" | tr '[:upper:]' '[:lower:]')
        reg_map["$ln"]="$v"
    done < <( tr -d '\r' < "$data_file" )

    # 3. Determine Target List
    local pkgs_str=${CONF[PKG_LIST]//,/ }
    local target_list=""
    if [[ "$pkgs_str" == "all" ]]; then
        target_list=$(printf "%s\n" "${!live_map[@]}" "${!reg_map[@]}" | sort -u)
    else
        target_list=$(echo "$pkgs_str" | tr '[:upper:]' '[:lower:]')
    fi
    
    # 4. Reconcile and Report
    log "Reconciling Live environment with Registry: $data_file"
    printf "%-30s | %-18s | %-18s | %-10s\n" "Package" "Live Version" "Registry Ver" "Status"
    printf "%30s-+-%18s-+-%18s-+-%10s\n" "------------------------------" "------------------" "------------------" "----------"

    for pkg in $target_list; do
        local live_ver="${live_map[$pkg]:-N/A}"
        local reg_ver="${reg_map[$pkg]:-N/A}"
        
        local status="MATCH"
        if [ "$live_ver" == "N/A" ] && [ "$reg_ver" != "N/A" ]; then
            status="MISSING_LIVE"
        elif [ "$live_ver" != "N/A" ] && [ "$reg_ver" == "N/A" ]; then
            status="UNTRACKED"
        elif [ "$live_ver" != "$reg_ver" ]; then
            status="MISMATCH"
        fi

        printf "%-30s | %-18s | %-18s | %-10s\n" "$pkg" "$live_ver" "$reg_ver" "$status"
    done
}

# ----- 6. Orchestration & Main -----
main() {
    parse_args "$@"
    validate_env

    case "${CONF[ACTION]}" in
        backup)  backup_packages ;;
        restore) restore_packages ;;
        list)    list_packages ;;
        install) install_pkg_list ;;
        remove)  remove_pkg_list ;;
        status)  status_pkg_list ;;
        *)       error "Unrecognized action: ${CONF[ACTION]}" ;;
    esac
}

# Execution Entry Point
main "$@"
