#!/bin/bash
# =================================================================
#  rust_cachemgr.sh - Rust & Cargo Cache Management Utility
# =================================================================
#  Supports inspecting (metadata, counts, sizes) and safely purging
#  various Rust caches (Cargo Registry, Git DB, Sccache compiler 
#  cache, and project build target directories).
#
#  Compatible platforms: Linux, Cygwin, and MSYS2.
# =================================================================

# -----------------------------------------------------------------
#  1. Global State & Color Configurations
# -----------------------------------------------------------------
# Flags modified during argument parsing
JSON_OUTPUT=0
LOG_FILE=""
ACTION=""
PRUNE_DAYS=0

# Dynamic paths resolved at runtime based on environment
CARGO_DIR=""
SCCACHE_PATH=""

# Lockfile details for concurrency protection (fallback sequence: TMPDIR -> TEMP -> TMP -> /tmp)
LOCK_DIR=""
if [ -n "$TMPDIR" ]; then
    LOCK_DIR="$TMPDIR"
elif [ -n "$TEMP" ]; then
    LOCK_DIR="$TEMP"
elif [ -n "$TMP" ]; then
    LOCK_DIR="$TMP"
else
    LOCK_DIR="/tmp"
fi
LOCK_FILE="${LOCK_DIR}/rust_cachemgr.lock"

# ANSI Colors: Enabled only if running interactively in a TTY
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    NC='\033[0m' # No Color (Reset)
    BOLD='\033[1m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' NC='' BOLD=''
fi

# -----------------------------------------------------------------
#  2. Path Conversion Helpers
# -----------------------------------------------------------------
# normalizes paths from Windows/Cygwin formats (C:\path) to Unix POSIX
to_posix_path() {
    local raw_path="$1"
    if [ -z "$raw_path" ]; then
        echo ""
        return
    fi
    # If running on Cygwin/MSYS2, utilize native cygpath utility
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -u "$raw_path"
    else
        # Fallback naive normalization for Unix-like environments without cygpath
        if [[ "$raw_path" =~ ^[a-zA-Z]:\\ ]]; then
            echo "$raw_path" | sed 's|\\|/|g' | sed -r 's|^([a-zA-Z]):|/\1|'
        else
            echo "$raw_path"
        fi
    fi
}

# -----------------------------------------------------------------
#  3. Concurrency Protection (Lockfile Management)
# -----------------------------------------------------------------
# Removes the lockfile upon script completion or termination
cleanup_lock() {
    rm -f "$LOCK_FILE"
}

# Ensures only one instance of the script executes at a time
acquire_lock() {
    # Check if a lockfile from a previous/current execution exists
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        # Verify if the process ID recorded in the lockfile is still active
        if [ -n "$lock_pid" ] && ps -p "$lock_pid" >/dev/null 2>&1; then
            if [ "$JSON_OUTPUT" -eq 1 ]; then
                echo "{\"status\": \"error\", \"message\": \"Another instance of rust_cachemgr is already running (PID: $lock_pid).\"}"
            else
                echo -e "${RED}${BOLD}ERROR: Another instance of rust_cachemgr is already running (PID: $lock_pid).${NC}"
            fi
            exit 6
        fi
    fi

    # Write current process ID to the lockfile
    echo "$$" > "$LOCK_FILE" 2>/dev/null
    
    # Establish trap handlers to ensure the lockfile is cleared on exit or break signals
    trap cleanup_lock EXIT INT TERM
}

# -----------------------------------------------------------------
#  4. Cache Path Resolution
# -----------------------------------------------------------------
# Resolves Cargo and Sccache cache roots considering Env overrides
resolve_caches() {
    # Resolve Cargo Home location
    if [ -n "$CARGO_HOME" ]; then
        CARGO_DIR=$(to_posix_path "$CARGO_HOME")
    else
        # Handle Windows/Cygwin/MSYS2 defaults
        if [ -n "$USERPROFILE" ]; then
            CARGO_DIR=$(to_posix_path "$USERPROFILE/.cargo")
        else
            CARGO_DIR=$(to_posix_path "$HOME/.cargo")
        fi
    fi

    # Resolve Sccache (compiler caching) directory
    if [ -n "$SCCACHE_DIR" ]; then
        SCCACHE_PATH=$(to_posix_path "$SCCACHE_DIR")
    else
        if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
            # Windows AppData local folder fallback
            local local_app_data
            local_app_data=$(to_posix_path "$LOCALAPPDATA")
            if [ -n "$local_app_data" ]; then
                SCCACHE_PATH="$local_app_data/Mozilla/sccache"
            else
                SCCACHE_PATH=$(to_posix_path "$HOME/.cache/sccache")
            fi
        else
            # Linux & macOS standard XDG base directory fallback
            if [ -n "$XDG_CACHE_HOME" ]; then
                SCCACHE_PATH=$(to_posix_path "$XDG_CACHE_HOME/sccache")
            else
                SCCACHE_PATH=$(to_posix_path "$HOME/.cache/sccache")
            fi
        fi
    fi
}

# -----------------------------------------------------------------
#  5. Data Aggregation & Stat Inquiries (Text & JSON)
# -----------------------------------------------------------------

# Outputs formatted disk size and total file count for a folder
get_dir_stats() {
    local dir="$1"
    if [ -d "$dir" ]; then
        local size files
        size=$(du -sh "$dir" 2>/dev/null | cut -f1)
        # Find count of files recursively
        files=$(find "$dir" -type f 2>/dev/null | wc -l | tr -d ' ')
        echo -e "${GREEN}${size}${NC} (${files} files)"
    else
        echo -e "${YELLOW}Empty/Not Created${NC}"
    fi
}

# Generates clean, unformatted JSON statistics for a directory
json_dir_stats() {
    local dir="$1"
    if [ -d "$dir" ]; then
        local size files
        size=$(du -sh "$dir" 2>/dev/null | cut -f1)
        files=$(find "$dir" -type f 2>/dev/null | wc -l | tr -d ' ')
        echo "{\"exists\": true, \"size\": \"$size\", \"files\": $files}"
    else
        echo "{\"exists\": false, \"size\": \"0\", \"files\": 0}"
    fi
}

# Plain-text metadata reporting on all resolved caches
get_info_text() {
    echo -e "${BOLD}${BLUE}=== Rust Cache Manager Info ===${NC}\n"
    echo -e "OS Detected: ${CYAN}${OSTYPE:-linux}${NC}"

    resolve_caches

    # Section 1: Global Cargo Directories
    echo -e "\n${BOLD}1. Global Cargo Cache (${CARGO_DIR}):${NC}"
    if [ -d "$CARGO_DIR" ]; then
        echo -n "   Total size:               "
        get_dir_stats "$CARGO_DIR"
        
        echo -n "   Crate Registry Tarballs:  "
        get_dir_stats "$CARGO_DIR/registry/cache"
        
        echo -n "   Crate Extracted Sources:  "
        get_dir_stats "$CARGO_DIR/registry/src"
        
        echo -n "   Git Repository Caches:    "
        get_dir_stats "$CARGO_DIR/git"

        echo -n "   Installed Binaries (bin): "
        get_dir_stats "$CARGO_DIR/bin"
    else
        echo -e "   ${YELLOW}Global cargo directory does not exist.${NC}"
    fi

    # Section 2: Sccache Directories
    echo -e "\n${BOLD}2. Sccache Compiler Cache (${SCCACHE_PATH}):${NC}"
    if [ -d "$SCCACHE_PATH" ]; then
        echo -n "   Total size:               "
        get_dir_stats "$SCCACHE_PATH"
        if command -v sccache >/dev/null 2>&1; then
            echo -e "   Sccache stats:"
            sccache --show-stats | sed 's/^/      /'
        fi
    else
        echo -e "   ${YELLOW}Sccache cache directory does not exist / is empty.${NC}"
    fi

    # Section 3: Workspace Cargo Project target/ check
    echo -e "\n${BOLD}3. Local Project Target Directories (under current path):${NC}"
    local found_projects=0
    local proj_dir target_dir
    # Recursively searches directories (up to 4 levels) for Cargo.toml files
    while IFS= read -r -d '' manifest; do
        proj_dir=$(dirname "$manifest")
        target_dir="$proj_dir/target"
        if [ -d "$target_dir" ]; then
            found_projects=1
            echo -n "   $(basename "$proj_dir") ($(to_posix_path "$target_dir")): "
            get_dir_stats "$target_dir"
        fi
    done < <(find . -maxdepth 4 -name "Cargo.toml" -print0 2>/dev/null)

    if [ "$found_projects" -eq 0 ]; then
        echo -e "   ${YELLOW}No active project target directories found in $(pwd)${NC}"
    fi
    echo ""
}

# Structured JSON reporting for CI/CD integrations
get_info_json() {
    resolve_caches
    local global_stats sccache_stats local_projects_json=""
    
    # Analyze Global Cargo Folder
    if [ -d "$CARGO_DIR" ]; then
        local total_size total_files
        total_size=$(du -sh "$CARGO_DIR" 2>/dev/null | cut -f1)
        total_files=$(find "$CARGO_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
        global_stats="{\"exists\": true, \"path\": \"$CARGO_DIR\", \"size\": \"$total_size\", \"files\": $total_files, \"registry_cache\": $(json_dir_stats "$CARGO_DIR/registry/cache"), \"registry_src\": $(json_dir_stats "$CARGO_DIR/registry/src"), \"git\": $(json_dir_stats "$CARGO_DIR/git"), \"bin\": $(json_dir_stats "$CARGO_DIR/bin")}"
    else
        global_stats="{\"exists\": false, \"path\": \"$CARGO_DIR\"}"
    fi

    # Analyze Sccache Folder
    if [ -d "$SCCACHE_PATH" ]; then
        local sc_size sc_files
        sc_size=$(du -sh "$SCCACHE_PATH" 2>/dev/null | cut -f1)
        sc_files=$(find "$SCCACHE_PATH" -type f 2>/dev/null | wc -l | tr -d ' ')
        sccache_stats="{\"exists\": true, \"path\": \"$SCCACHE_PATH\", \"size\": \"$sc_size\", \"files\": $sc_files}"
    else
        sccache_stats="{\"exists\": false, \"path\": \"$SCCACHE_PATH\"}"
    fi

    # Scan Local Project target/ directories
    local proj_dir target_dir size files
    while IFS= read -r -d '' manifest; do
        proj_dir=$(dirname "$manifest")
        target_dir="$proj_dir/target"
        if [ -d "$target_dir" ]; then
            size=$(du -sh "$target_dir" 2>/dev/null | cut -f1)
            files=$(find "$target_dir" -type f 2>/dev/null | wc -l | tr -d ' ')
            local_projects_json="${local_projects_json}, {\"name\": \"$(basename "$proj_dir")\", \"path\": \"$(to_posix_path "$target_dir")\", \"size\": \"$size\", \"files\": $files}"
        fi
    done < <(find . -maxdepth 4 -name "Cargo.toml" -print0 2>/dev/null)
    
    local_projects_json="[${local_projects_json#, }]"

    cat <<EOF
{
  "os": "${OSTYPE:-linux}",
  "global_cargo_cache": $global_stats,
  "sccache": $sccache_stats,
  "local_projects": $local_projects_json
}
EOF
}

# -----------------------------------------------------------------
#  6. Safety Checks (Active Processes Validation)
# -----------------------------------------------------------------
# Prevents purging caches while active Rust compilation processes are running
check_active_processes() {
    local running_proc=""
    for proc in cargo rustc; do
        # Checks process table using pgrep, with a fallback to raw ps search (matching word boundaries + windows .exe extension)
        if pgrep -x "$proc" >/dev/null 2>&1 || ps -ef 2>/dev/null | grep -v grep | grep -E "\<${proc}(\.exe)?\>" >/dev/null; then
            running_proc="$running_proc $proc"
        fi
    done

    # Abort execution if conflicts are found
    if [ -n "$running_proc" ]; then
        if [ "$JSON_OUTPUT" -eq 1 ]; then
            echo "{\"status\": \"error\", \"message\": \"Active Rust processes detected (${running_proc:1}).\"}"
        else
            echo -e "${RED}${BOLD}ERROR: Active Rust processes detected (${running_proc:1}).${NC}"
            echo -e "Please stop all active compilation processes before purging caches."
        fi
        exit 5
    fi
}

# -----------------------------------------------------------------
#  7. Deletion Logic (Safety-First implementation)
# -----------------------------------------------------------------

# Wipes directories cleanly without utilizing risky wildcard * syntax
purge_caches() {
    check_active_processes
    resolve_caches
    
    # Detect local target/ directories to include in the deletion list
    local local_targets=()
    local proj_dir target_dir
    while IFS= read -r -d '' manifest; do
        proj_dir=$(dirname "$manifest")
        target_dir="$proj_dir/target"
        if [ -d "$target_dir" ]; then
            local_targets+=("$target_dir")
        fi
    done < <(find . -maxdepth 4 -name "Cargo.toml" -print0 2>/dev/null)

    # 7A. Non-interactive automated JSON mode (suitable for CI/CD environments)
    if [ "$JSON_OUTPUT" -eq 1 ]; then
        # Check non-empty directory variables before running rm -rf
        if [ -n "$CARGO_DIR" ] && [ -d "$CARGO_DIR" ]; then
            # Delete directory and recreate it to clean contents safely (avoids wildcard /* errors)
            rm -rf "$CARGO_DIR/registry/cache" && mkdir -p "$CARGO_DIR/registry/cache"
            rm -rf "$CARGO_DIR/registry/src" && mkdir -p "$CARGO_DIR/registry/src"
            rm -rf "$CARGO_DIR/git" && mkdir -p "$CARGO_DIR/git"
        fi
        if [ -n "$SCCACHE_PATH" ] && [ -d "$SCCACHE_PATH" ]; then
            rm -rf "$SCCACHE_PATH" && mkdir -p "$SCCACHE_PATH"
        fi
        command -v sccache >/dev/null 2>&1 && sccache --zero-stats >/dev/null 2>&1
        
        local local_pjs=""
        local target
        for target in "${local_targets[@]}"; do
            rm -rf "$target"
            local_pjs="${local_pjs}, \"$(to_posix_path "$target")\""
        done
        local_pjs="[${local_pjs#, }]"
        
        cat <<EOF
{
  "status": "success",
  "cleared": {
    "global_cargo_cache": true,
    "sccache": true,
    "local_projects": $local_pjs
  }
}
EOF
        exit 0
    fi

    # 7B. Interactive User CLI mode
    echo -e "${RED}${BOLD}WARNING: You are about to purge the following Rust caches:${NC}"
    echo -e "  - Cargo registry download cache (${CARGO_DIR}/registry/cache)"
    echo -e "  - Cargo registry extracted sources (${CARGO_DIR}/registry/src)"
    echo -e "  - Cargo git checkouts (${CARGO_DIR}/git)"
    echo -e "  - Compiler cache (${SCCACHE_PATH})"
    
    if [ ${#local_targets[@]} -gt 0 ]; then
        echo -e "  - Local targets:"
        local target
        for target in "${local_targets[@]}"; do
            echo -e "    * $(to_posix_path "$target")"
        done
    fi

    # Prompt interactive confirmation if stdin is a standard terminal
    if [ -t 0 ]; then
        local confirm
        read -p "Are you sure you want to proceed? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[yY](es)?$ ]]; then
            echo -e "${BLUE}Aborted.${NC}"
            exit 0
        fi
    fi

    echo -e "\n${YELLOW}Purging Global Cargo Cache...${NC}"
    if [ -n "$CARGO_DIR" ] && [ -d "$CARGO_DIR" ]; then
        rm -rf "$CARGO_DIR/registry/cache" && mkdir -p "$CARGO_DIR/registry/cache" && echo -e "  [${GREEN}OK${NC}] Cleared registry cache tarballs"
        rm -rf "$CARGO_DIR/registry/src" && mkdir -p "$CARGO_DIR/registry/src" && echo -e "  [${GREEN}OK${NC}] Cleared registry extracted sources"
        rm -rf "$CARGO_DIR/git" && mkdir -p "$CARGO_DIR/git" && echo -e "  [${GREEN}OK${NC}] Cleared git registry database"
    fi

    echo -e "${YELLOW}Purging Sccache Compiler Cache...${NC}"
    if [ -n "$SCCACHE_PATH" ] && [ -d "$SCCACHE_PATH" ]; then
        rm -rf "$SCCACHE_PATH" && mkdir -p "$SCCACHE_PATH"
        echo -e "  [${GREEN}OK${NC}] Cleared sccache contents"
    fi
    if command -v sccache >/dev/null 2>&1; then
        sccache --zero-stats >/dev/null 2>&1
    fi

    if [ ${#local_targets[@]} -gt 0 ]; then
        echo -e "${YELLOW}Purging Local Project target/ Directories...${NC}"
        local target
        for target in "${local_targets[@]}"; do
            rm -rf "$target"
            echo -e "  [${GREEN}OK${NC}] Cleared $(to_posix_path "$target")"
        done
    fi

    echo -e "\n${GREEN}${BOLD}Purge complete!${NC}\n"
}

# Wipes ONLY the extracted source dependencies, keeping cached package tarballs
clean_extracted_sources() {
    check_active_processes
    resolve_caches

    if [ "$JSON_OUTPUT" -eq 1 ]; then
        if [ -n "$CARGO_DIR" ] && [ -d "$CARGO_DIR/registry/src" ]; then
            rm -rf "$CARGO_DIR/registry/src" && mkdir -p "$CARGO_DIR/registry/src"
        fi
        cat <<EOF
{
  "status": "success",
  "cleared": {
    "global_cargo_registry_src": true
  }
}
EOF
        exit 0
    fi

    echo -e "${RED}${BOLD}WARNING: You are about to clear only the extracted crate source files under:${NC}"
    echo -e "  - ${CARGO_DIR}/registry/src"
    echo -e "${CYAN}Note: Downloaded package tarballs (.crate files) will be preserved, allowing offline rebuilds.${NC}"

    if [ -t 0 ]; then
        local confirm
        read -p "Proceed with clearing extracted sources? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[yY](es)?$ ]]; then
            echo -e "${BLUE}Aborted.${NC}"
            exit 0
        fi
    fi

    if [ -n "$CARGO_DIR" ] && [ -d "$CARGO_DIR/registry/src" ]; then
        rm -rf "$CARGO_DIR/registry/src" && mkdir -p "$CARGO_DIR/registry/src"
        echo -e "  [${GREEN}OK${NC}] Cleared cargo extracted sources"
    fi
    echo -e "\n${GREEN}${BOLD}Crate source purge complete!${NC}\n"
}

# Scan local projects and clean target/ folders that have no changes in N days
prune_target_directories() {
    check_active_processes
    
    local prune_days="$PRUNE_DAYS"
    # Identify target folders that haven't been compiled/modified in N days
    local stale_targets=()
    local proj_dir target_dir is_stale
    while IFS= read -r -d '' manifest; do
        proj_dir=$(dirname "$manifest")
        target_dir="$proj_dir/target"
        if [ -d "$target_dir" ]; then
            # Checks if any files in target folder are modified less than N days ago
            is_stale=$(find "$target_dir" -mtime -"$prune_days" -print -quit 2>/dev/null)
            if [ -z "$is_stale" ]; then
                stale_targets+=("$target_dir")
            fi
        fi
    done < <(find . -maxdepth 4 -name "Cargo.toml" -print0 2>/dev/null)

    # 7A. JSON execution mode
    if [ "$JSON_OUTPUT" -eq 1 ]; then
        local cleared_pjs=""
        local target
        for target in "${stale_targets[@]}"; do
            rm -rf "$target"
            cleared_pjs="${cleared_pjs}, \"$(to_posix_path "$target")\""
        done
        cleared_pjs="[${cleared_pjs#, }]"
        
        cat <<EOF
{
  "status": "success",
  "pruned_days_threshold": $prune_days,
  "cleared": {
    "local_projects": $cleared_pjs
  }
}
EOF
        exit 0
    fi

    # 7B. Text interactive mode
    if [ ${#stale_targets[@]} -eq 0 ]; then
        echo -e "${GREEN}No local build target directories found that are older than ${prune_days} days.${NC}"
        exit 0
    fi

    echo -e "${RED}${BOLD}WARNING: You are about to purge target directories that have not been modified in ${prune_days}+ days:${NC}"
    local target
    for target in "${stale_targets[@]}"; do
        echo -e "  - $(to_posix_path "$target")"
    done

    if [ -t 0 ]; then
        local confirm
        read -p "Proceed with pruning these stale target directories? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[yY](es)?$ ]]; then
            echo -e "${BLUE}Aborted.${NC}"
            exit 0
        fi
    fi

    for target in "${stale_targets[@]}"; do
        rm -rf "$target"
        echo -e "  [${GREEN}OK${NC}] Cleared stale target: $(to_posix_path "$target")"
    done
    echo -e "\n${GREEN}${BOLD}Target pruning complete!${NC}\n"
}

# -----------------------------------------------------------------
#  8. User Instruction / Help Interface
# -----------------------------------------------------------------
show_help() {
    cat <<EOF
Rust Cache Manager - Utility to inspect and purge Rust/Cargo caches.

Usage:
  $0 [--get-info | --purge | --clean-src | --prune-targets <days>] [--json] [--log <file_path>]
  $0 -h | --help

Options:
  --get-info            Show location, file count, and disk size of all Rust caches.
  --purge               Clean Cargo index, download registry, git caches, sccache, and local targets.
  --clean-src           Wipe ONLY extracted dependency sources (preserves .crate zip downloads).
  --prune-targets <N>   Purge local target/ folders that have no modifications in the last N days.
  --json                Format output as JSON (ideal for CI/CD pipelines).
  --log <file_path>     Redirect all console outputs to a log file.
  -h, --help            Display this help message.

Examples:
  # Get cache sizes
  $0 --get-info

  # Clear extracted sources safely (retains offline downloads)
  $0 --clean-src

  # Purge project targets untouched for more than 14 days
  $0 --prune-targets 14

  # Purge all caches safely
  $0 --purge
EOF
}

# -----------------------------------------------------------------
#  9. Argument Parser & Redirections
# -----------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --get-info)
            ACTION="get-info"
            shift
            ;;
        --purge)
            ACTION="purge"
            shift
            ;;
        --clean-src)
            ACTION="clean-src"
            shift
            ;;
        --prune-targets)
            ACTION="prune-targets"
            # Ensure next parameter is a positive integer
            if [ -z "$2" ] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
                echo "Error: --prune-targets requires a positive integer argument (number of days)"
                exit 1
            fi
            PRUNE_DAYS="$2"
            shift 2
            ;;
        --json)
            JSON_OUTPUT=1
            shift
            ;;
        --log)
            # Ensure next parameter is provided and is not another option flag
            if [ -z "$2" ] || [[ "$2" == -* ]]; then
                echo "Error: --log requires a file path argument"
                exit 1
            fi
            LOG_FILE="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Error: Unknown option $1"
            echo "Usage: $0 [--get-info | --purge | --clean-src | --prune-targets <days>] [--json] [--log <file_path>]"
            exit 1
            ;;
    esac
done

# Set up logging redirection to the log file via 'tee' if specified
if [ -n "$LOG_FILE" ]; then
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
    exec > >(tee -i "$LOG_FILE") 2>&1
fi

# Confirm that an action has been selected
if [ -z "$ACTION" ]; then
    show_help
    exit 1
fi

# Acquire lockfile to prevent race conditions during operations
acquire_lock

# Execute corresponding handler
if [ "$ACTION" = "get-info" ]; then
    if [ "$JSON_OUTPUT" -eq 1 ]; then
        get_info_json
    else
        get_info_text
    fi
elif [ "$ACTION" = "purge" ]; then
    purge_caches
elif [ "$ACTION" = "clean-src" ]; then
    clean_extracted_sources
elif [ "$ACTION" = "prune-targets" ]; then
    prune_target_directories
fi
