#!/bin/bash
# --------------------------------------------------------------------------------
#  e:/data/devel/build/code/private/devops/git_repomgr/git_userchange.sh
#  v1.0.0xg  2026/03/31  XDG
# --------------------------------------------------------------------------------
# OBJECTIVES:
#   Mass-update Git 'origin' URLs by replacing a specific username/owner segment.
#   Designed for migrations where a user or organization name has changed.
#
# CORE COMPONENTS:
#   1. Argument Parsing: Normalizes input and processes flags for simulation/commit.
#   2. Path Normalization: Ensures portability between Windows/Linux (Cygwin/MSYS).
#   3. Discovery Loop: Recursively finds .git folders via 'find'.
#   4. Safety Layer: Validates connectivity to the new URL before committing changes.
#   5. Recovery Mechanism: Optional (via --safe-recover). Generates a timestamped
#      'undo' script in a centralized temp directory for instant rollback.
#
# FUNCTIONALITY & DATA FLOW:
#   - Input: Base directory, current owner (OLD_USER), target owner (NEW_USER).
#   - Logic: Uses Bash regex to target the "owner" segment of a URL (credential-based
#            like user@host or path-based like https://host/user/repo).
#   - Recovery: If --safe-recover is used, the script logs the reverse 'set-url'
#            command for every successful update to a temporary rollback script.
# --------------------------------------------------------------------------------

# --- Script Setup ---
# -e: Exit on error, -u: Error on unset variables, -o pipefail: Error if pipe fails
set -euo pipefail

# Initialize variables
BASE_PATH=""
OLD_USER=""
NEW_USER=""
MODE=""

# --- Usage Information ---
usage() {
    cat <<EOF >&2
Usage: $(basename "$0") --base-path=<path> --old-gituser=<old_user> --new-gituser=<new_user> [--simulate | --commit] [--safe-recover]

Description:
  Targeted Git repository management tool. Scans a directory tree for Git 
  repositories and updates the 'origin' remote URL. Specifically targets 
  the 'owner' or 'username' segment of the URL (e.g., in HTTPS or SSH formats).

Options:
  --base-path=<path>      : The root directory to start searching for .git folders.
  --old-gituser=<old>     : Standard Mode: The existing username/org to replace.
  --new-gituser=<new>     : Standard Mode: The target username/org to update to.
  --simulate              : DRY RUN. Prints URLs to be changed without updating config.
  --commit                : COMMIT MODE. Updates Git remote URLs only after verifying 
                            connectivity to the new URL. 
  --safe-recover          : Optional. If used during --commit, generates a timestamped 
                            undo script in your temporary directory for rollback.
  --display-remotes       : Exclusive Mode: List all remotes and URLs for all repositories 
                            found in the base path. Does not require username flags.
  -h, --help              : Display this help message.

Windows Path Safety:
  In Bash environments (Cygwin/MSYS), backslashes (\) are escape characters. 
  To prevent the shell from 'stripping' your path, please:
  1. Use forward slashes: --base-path=E:/data/repos (Recommended)
  2. Use single quotes:  --base-path='E:\data\repos'

Example:
  $(basename "$0") --base-path=E:/data/repos --display-remotes
  $(basename "$0") --base-path=E:/data/repos --old-gituser=old-org --new-gituser=new-org --simulate
EOF
    exit 1
}

# 1. Parse Arguments (Processes command line parameters)
SAFE_RECOVER=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-path=*)
      BASE_PATH="${1#*=}"
      shift
      ;;
    --old-gituser=*)
      OLD_USER="${1#*=}"
      shift
      ;;
    --new-gituser=*)
      NEW_USER="${1#*=}"
      shift
      ;;
    --simulate)
      MODE="SIMULATE"
      shift
      ;;
    --commit)
      MODE="COMMIT"
      shift
      ;;
    --safe-recover)
      SAFE_RECOVER=1
      shift
      ;;
    --display-remotes)
      MODE="DISPLAY"
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      ;;
  esac
done

# --- Path Normalization (Ensures portability for Cygwin/MSYS environments) ---
# This block allows usage of Windows-style paths (e.g., E:\repos) in shell environments.
if [[ "${OSTYPE:-}" == "cygwin" || "${OSTYPE:-}" == "msys" ]] && command -v cygpath >/dev/null 2>&1; then
    # HEURISTIC: Detect if the shell stripped backslashes (e.g., C:Users instead of C:/Users)
    if [[ "$BASE_PATH" =~ ^[a-zA-Z]:[^/\\]+ ]]; then
        echo "ERROR: Base path '$BASE_PATH' looks like its slashes were stripped by the shell."
        printf '%s\n' "HINT:  Use forward slashes (E:/path/to/repo) or wrap the path in single quotes ('E:\path\to\repo')."
        exit 1
    fi
    [[ -n "$BASE_PATH" ]] && BASE_PATH=$(cygpath -u "$BASE_PATH")
    [[ -n "${TMPDIR:-}" ]] && TMPDIR=$(cygpath -u "$TMPDIR")
    [[ -n "${TMP:-}" ]] && TMP=$(cygpath -u "$TMP")
    [[ -n "${TEMP:-}" ]] && TEMP=$(cygpath -u "$TEMP")
fi

# 2. Mandatory Argument Check (Ensures all required flags are present)
if [[ "$MODE" == "DISPLAY" ]]; then
    if [[ -z "$BASE_PATH" ]]; then usage; fi
else
    if [[ -z "$BASE_PATH" || -z "$OLD_USER" || -z "$NEW_USER" || -z "$MODE" ]]; then
        usage
    fi
fi

# 3. Path Validation (Confirms the search start point is a valid directory)
if [[ ! -d "$BASE_PATH" ]]; then
    echo "ERROR: Base path '$BASE_PATH' does not exist or is not a directory."
    exit 1
fi

# --- Recovery Configuration (Undo Log Settings) ---
# Portable temporary directory resolution (Cygwin/Linux/macOS)
TEMP_BASE="${TMPDIR:-${TMP:-${TEMP:-/tmp}}}"
UNDO_DIR="${TEMP_BASE}/git"
UNDO_LOG="${UNDO_DIR}/undo_git_changes_$(date +%Y%m%d_%H%M%S).sh"

# Ensure the undo directory exists only if recovery is enabled
if [[ "$SAFE_RECOVER" -eq 1 ]]; then
    mkdir -p "$UNDO_DIR" 2>/dev/null || { echo "ERROR: Could not create recovery directory at $UNDO_DIR"; exit 1; }
fi

echo "--- Target: $BASE_PATH ---"
if [[ "$MODE" == "DISPLAY" ]]; then
    echo "--- Action: Display All Remotes ---"
else
    echo "--- Action: '$OLD_USER' -> '$NEW_USER' (Mode: $MODE) ---"
fi

# --- Recovery Strategy Overview (Always Displayed for Pre-flight) ---
if [[ "$MODE" != "DISPLAY" ]]; then
    if [[ "$SAFE_RECOVER" -eq 1 ]]; then
        # Initialize the undo script with metadata (only physically created in COMMIT mode)
        if [[ "$MODE" == "COMMIT" ]]; then
            {
                echo "#!/bin/bash"
                echo "################################################################################"
                echo "# RECOVERY SCRIPT for git_userchange.sh (Generated $(date))"
                echo "# Target Base Path: $BASE_PATH"
                echo "################################################################################"
            } > "$UNDO_LOG"
        fi
        
        echo "--- RECOVERY ENABLED: $UNDO_LOG ---"
        [[ "$MODE" == "SIMULATE" ]] && echo "--- [Info] An undo script will be generated when you run with --commit. ---"
        [[ "$MODE" == "COMMIT" ]] && echo "--- [Safety] An undo script has been generated to restore URLs if needed. ---"
    else
        # Audible warning if committing without a safety net
        echo "--- [WARNING] RECOVERY NOT ENABLED ($UNDO_LOG will NOT be created) ---"
        echo "--- [Warning] Use --safe-recover if you want an automated rollback script. ---"
    fi
fi

# 4. Discovery & Execution Logic
# Recursively scans for .git directories. Errors on restricted paths are hidden (2>/dev/null).
find "$BASE_PATH" -type d -name ".git" -print0 2>/dev/null | while IFS= read -r -d '' gitdir; do
    repo_dir=$(dirname "$gitdir")
    
    # Process each repo in an isolated subshell to preserve environment & prevent 'cd' drift
    (
        # Disable password prompts to prevent script hanging on unauthorized remotes
        export GIT_TERMINAL_PROMPT=0
        
        if ! cd "$repo_dir" 2>/dev/null; then
            echo "[ERROR] Could not enter directory: $repo_dir"
            exit 0 # Subshell exit only
        fi

        # --- EXCLUSIVE MODE: Display Remotes ---
        if [[ "$MODE" == "DISPLAY" ]]; then
            echo "[INFO] Repo: $repo_dir"
            git remote -v | sed 's/^/       /'
            exit 0
        fi

        # We exclusively target 'origin' to prevent unintended side effects on secondary remotes
        if ! git remote | grep -q "^origin$"; then
            exit 0
        fi

        # Retrieve current remote URL; fallback to empty string if command fails
        CURRENT_URL=$(git remote get-url origin 2>/dev/null || echo "")
        [[ -z "$CURRENT_URL" ]] && exit 0

        NEW_URL="$CURRENT_URL"

        # --- Segmented Replacement Data Flow (Safety Logic) ---
        
        # CASE 1: Credential-based URLs (e.g., user@host:repo or https://user@host)
        if [[ "$CURRENT_URL" =~ ^([^@]+)@(.*)$ ]]; then
            user_part="${BASH_REMATCH[1]}"
            host_path="${BASH_REMATCH[2]}"
            # Sub-segment match to target EXACT owner name within the credentials
            if [[ "$user_part" == *"$OLD_USER"* ]]; then
                new_user_part="${user_part//$OLD_USER/$NEW_USER}"
                NEW_URL="${new_user_part}@${host_path}"
            fi

        # CASE 2: Path-based URLs (e.g., https://github.com/OWNER/REPO)
        # Regex targets the first path segment immediately following the scheme and domain.
        elif [[ "$CURRENT_URL" =~ ^(https?://[^/]+/)([^/]+)(/.*)$ ]]; then
            prefix="${BASH_REMATCH[1]}"
            owner_segment="${BASH_REMATCH[2]}"
            repo_path="${BASH_REMATCH[3]}"
            
            # String comparison ensures we only change the owner segment, not the repo name
            if [[ "$owner_segment" == "$OLD_USER" ]]; then
                NEW_URL="${prefix}${NEW_USER}${repo_path}"
            fi
        fi

        # Skip if the logic determined no transformation was necessary
        if [[ "$NEW_URL" == "$CURRENT_URL" ]]; then
            exit 0
        fi

        if [[ "$MODE" == "SIMULATE" ]]; then
            echo "[DRY-RUN] Found: $repo_dir"
            echo "          Current: $CURRENT_URL"
            echo "          Target:  $NEW_URL"
        else
            echo "[COMMIT] Checking $repo_dir..."
            
            # --- Pre-Commit Connectivity Guard ---
            # Verifies that the new target actually exists/is reachable BEFORE updating local config.
            # Using GIT_TERMINAL_PROMPT=0 ensures this fails fast instead of hanging.
            if ! git ls-remote --heads "$NEW_URL" >/dev/null 2>&1; then
                echo "         [ABORT] Cannot verify new URL: $NEW_URL"
                echo "                 Check your network/permissions/credentials."
                exit 0
            fi

            # Execute the Update and Log the Revert command (only if recovery is enabled)
            if git remote set-url origin "$NEW_URL"; then
                echo "         Success: Updated to $NEW_URL"
                [[ "$SAFE_RECOVER" -eq 1 ]] && echo "cd \"$repo_dir\" && git remote set-url origin \"$CURRENT_URL\"" >> "$UNDO_LOG"
            else
                echo "         [ERROR] Git failed to update remote."
            fi
        fi
    ) || true # Ensure the parent loop ignores subshell failure status
done

# Finalize the Undo Log (Make it executable and report location)
if [[ "$MODE" == "COMMIT" && "$SAFE_RECOVER" -eq 1 ]]; then
    chmod +x "$UNDO_LOG"
    echo "--- FINAL RECOVERY SCRIPT (Action required if needed): $UNDO_LOG ---"
fi

echo "------------------------------------------------------------"
echo "Operation $MODE Finished."
