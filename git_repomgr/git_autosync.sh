#!/bin/bash
# -------------------------------------
#  $HOME/scripts/git_autosync.sh
#  v1.0.0xg  2025/12/30  XDG
# -------------------------------------
# Syntax: ./git_autosync.sh --base-folder=<base_folder> [options]
# Options: [--detect-only|--message="<msg>"|--verbose|--parallel=N,T|--logfile=<path>]
# Prereqs: git

# Summary of Global Configs for a Clean Workflow
# ------------------------------------------+-------------------------------------------------------------------------------
#               Command                     |                                  What it does
# ------------------------------------------+-------------------------------------------------------------------------------
# git config --global pull.rebase true      | Makes rebase the default for every pull
# git config --global rebase.autoStash true | Automatically handles dirty working trees during rebase
# git config --global fetch.prune true      | Automatically removes local "ghost" branches that were deleted on the server
# ------------------------------------------+-------------------------------------------------------------------------------

# --- Default values ---
# BASE_DEV_DIR: The root directory to start searching for git repositories.
# DETECT_ONLY: If true, only reports changes without committing or pushing.
# CUSTOM_COMMIT_MSG: User-provided commit message (via --message).
# VERBOSE: If true, prints extra separators for better readability.
# PARALLEL_JOBS: Max number of background processes (default 1).
# PARALLEL_DELAY: Sleep timer before starting another background process (default 0).
# LOG_FILE: Path to a file where all output will be saved (optional).
BASE_DEV_DIR=""
DETECT_ONLY=false
CUSTOM_COMMIT_MSG=""
VERBOSE=false
PARALLEL_JOBS=1
PARALLEL_DELAY=0
LOG_FILE=""

# Detect number of processors for parallel default
if command -v nproc &>/dev/null; then
  NPROC=$(nproc)
elif [[ -n "$NUMBER_OF_PROCESSORS" ]]; then
  NPROC="$NUMBER_OF_PROCESSORS"
elif command -v sysctl &>/dev/null; then
  NPROC=$(sysctl -n hw.ncpu 2>/dev/null || echo 1)
else
  NPROC=1
fi

# --- Usage ---
# Displays script syntax and available options, then exits.
# Arguments: $1 = exit code (optional, default 1)
usage() {
  local exit_code="${1:-1}"
  echo "Usage: $0 --base-folder=<path> [options]"
  echo ""
  echo "Mandatory:"
  echo "  --base-folder=<path>  Base directory to search for git repos"
  echo ""
  echo "Options:"
  echo "  --detect-only         Only show changes, do not commit or push"
  echo "  --message=\"<msg>\"     Custom commit message"
  echo "  --verbose             Show more output"
  echo "  --parallel[=N,T]      Enable parallel sync (N=processes, T=delay in sec)"
  echo "                        N defaults to $NPROC cores, T defaults to 0s"
  echo "  --logfile=<path>      Save all output to the specified log file"
  echo "  --help                Show this help message"
  exit "$exit_code"
}

# --- Parsing Arguments ---
# Iterates through command-line arguments to set configuration.
while [[ $# -gt 0 ]]; do
  case $1 in
    --base-folder=*)
      BASE_DEV_DIR="${1#*=}"
      shift
    ;;
    --detect-only)
      DETECT_ONLY=true
      shift
    ;;
    --message=*)
      CUSTOM_COMMIT_MSG="${1#*=}"
      shift
    ;;
    --verbose)
      VERBOSE=true
      shift
    ;;
    --parallel)
      PARALLEL_JOBS="$NPROC"
      shift
    ;;
    --parallel=*)
      val="${1#*=}"
      if [[ -z "$val" ]]; then
        PARALLEL_JOBS="$NPROC"
      elif [[ $val =~ ^([0-9]+),([0-9]+)$ ]]; then
        PARALLEL_JOBS="${BASH_REMATCH[1]}"
        PARALLEL_DELAY="${BASH_REMATCH[2]}"
      elif [[ $val =~ ^[0-9]+$ ]]; then
        PARALLEL_JOBS="$val"
      else
        echo "Error: Invalid parallel format. Use --parallel=N or --parallel=N,T"
        exit 1
      fi
      
      # Safety validation: ensure at least 1 job
      if [ "$PARALLEL_JOBS" -lt 1 ]; then
        echo "Error: --parallel must specify at least 1 process."
        exit 1
      fi
      shift
    ;;
    --logfile=*)
      LOG_FILE="${1#*=}"
      shift
    ;;
    --help)
      usage 0
    ;;
    *)
      echo "Unknown option: $1"
      usage
    ;;
  esac
done

# Ensure Git operations are non-interactive to prevent hangs in automation
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="ssh -o BatchMode=yes"

# --- Setup Logging ---
# If a log file is specified, redirect all stdout and stderr to it using tee.
if [[ -n "$LOG_FILE" ]]; then
  # Ensure the directory for the log file exists
  LOG_DIR=$(dirname "$LOG_FILE")
  if [[ ! -d "$LOG_DIR" ]]; then
    if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
      echo "Error: Could not create directory for log file: $LOG_DIR"
      exit 6
    fi
  fi
  # Redirect stdout and stderr to the log file while still printing to terminal
  exec > >(tee -a "$LOG_FILE") 2>&1
fi

echo "*** Git Autosync Utility - Job Stamp: $(date '+%Y/%m/%d-%H:%M:%S')"

# --- Validation ---
# Ensure required parameters are provided and environment is ready.
if [[ -z "$BASE_DEV_DIR" ]]; then
  echo "Error: --base-folder is required."
  usage
fi

# Create a temporary directory for tracking results.
# This allows background processes to communicate their status and log output
# to the parent process, ensuring atomic and ordered reporting.
if ! TMP_RESULTS_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t 'git_autosync'); then
  echo "Error: Failed to create temporary directory."
  exit 5
fi

# Cleanup function to be called on exit or interruption
cleanup() {
  local exit_code=$?
  # Kill any remaining background jobs if we're interrupted
  if [[ $exit_code -ne 0 ]]; then
    local raw_pids
    raw_pids=$(jobs -p)
    if [[ -n "$raw_pids" ]]; then
      local -a pids=()
      local pid
      while IFS= read -r pid; do
        [[ -n "$pid" ]] && pids+=("$pid")
      done <<< "$raw_pids"
      if [[ ${#pids[@]} -gt 0 ]]; then
        echo -e "\n[!] Interrupted. Cleaning up background jobs..."
        # Use kill -TERM (15) for graceful exit, then wait slightly and KILL if needed
        kill -TERM "${pids[@]}" 2>/dev/null
        (sleep 1; kill -KILL "${pids[@]}" 2>/dev/null) &
      fi
    fi
  fi
  [[ -d "$TMP_RESULTS_DIR" ]] && rm -rf "$TMP_RESULTS_DIR"
  exit $exit_code
}

trap cleanup EXIT SIGINT SIGTERM

# Prints each line of a multiline string with a fixed prefix
prefix_lines() {
  local prefix="$1"
  local text="$2"
  local line
  while IFS= read -r line; do
    printf '%s%s\n' "$prefix" "$line"
  done <<< "$text"
}

# --- Sync Function ---
# Performs the sequential sync logic for a single repository.
# Arguments: $1 = project path, $2 = project index
sync_repo() {
  local proj_dir="$1"
  local index="$2"
  local log_file="$TMP_RESULTS_DIR/log_$index"
  local status_file="$TMP_RESULTS_DIR/status_$index"
  local msg branch outcome pull_output push_output status_output action_taken head_before head_after pull_exit push_exit

  # Initialize status as unknown in case of crash
  echo "unknown" > "$status_file"
  action_taken=false

  # Redirect all output for this project to a log file.
  # This prevents interleaving in parallel mode and allows for ordered 
  # sequential reporting at the end of the script execution.
  {
    echo "[$index] Syncing: $proj_dir"
    
    # Move into the project directory
    if ! pushd "$proj_dir" &> /dev/null; then
      echo "  [X] Failed to enter directory"
      echo "fail" > "$status_file"
      [[ "$VERBOSE" == true ]] && echo "------------------------------------------"
      return
    fi

    # Capture state before operations (MUST be after pushd)
    head_before=$(git rev-parse HEAD 2>/dev/null || echo "empty")
    curr_hash=$(git rev-parse --short HEAD 2>/dev/null || echo "none")

    # Check if we have a remote named origin
    if ! git remote | grep -q "^origin$"; then
      echo "  [.] No 'origin' remote found. Skipping sync."
      echo "skip" > "$status_file"
      popd &> /dev/null || return
      [[ "$VERBOSE" == true ]] && echo "------------------------------------------"
      return
    fi

    # 1. Handle local changes (Stage and Commit)
    if [[ -n "$(git status --porcelain)" ]]; then
      if [[ "$DETECT_ONLY" == true ]]; then
        echo "  [!] Local changes detected (Skipping commit in detect-only mode). <$curr_hash>"
        echo "found" > "$status_file"
      else
        echo "  [!] Local changes detected. Committing... <$curr_hash>"

        # Determine commit message
        if [[ -n "$CUSTOM_COMMIT_MSG" ]]; then
          msg="$CUSTOM_COMMIT_MSG"
        else
          msg="Auto-sync: $(date +'%Y-%m-%d %H:%M:%S')"
        fi

        # Stage all changes and commit
        git add -A
        if ! git commit -m "$msg"; then
          echo "  [X] Error: Commit failed."
          echo "fail" > "$status_file"
          popd &> /dev/null || return
          [[ "$VERBOSE" == true ]] && echo "------------------------------------------"
          return
        fi
        action_taken=true
      fi
    fi

    # 2. Sync with remote (Pull and Push)
    # This block executes even if there were no local changes to commit,
    # ensuring that we pull remote updates and push existing local commits.
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [[ -z "$branch" ]]; then
      echo "  [X] Error: Could not detect current branch."
      echo "fail" > "$status_file"
      popd &> /dev/null || return
      [[ "$VERBOSE" == true ]] && echo "------------------------------------------"
      return
    fi

    if [[ "$DETECT_ONLY" == true ]]; then
      # In detect-only mode, we check if we are ahead/behind without pulling/pushing
      if [[ "$branch" != "HEAD" ]]; then
        status_output=$(git status -uno 2>/dev/null)
        if echo "$status_output" | grep -q "Your branch is ahead"; then
          echo "  [!] Branch is ahead of remote. <$curr_hash>"
          echo "found" > "$status_file"
        fi
        if echo "$status_output" | grep -q "Your branch is behind"; then
          echo "  [!] Branch is behind remote. <$curr_hash>"
          echo "found" > "$status_file"
        fi
      fi
      # If nothing was found yet, mark as skip
      if grep -q "unknown" "$status_file"; then
        echo "  [.] No changes detected. <$curr_hash>"
        echo "skip" > "$status_file"
      fi
    else
      # Safety check for detached HEAD state
      if [[ "$branch" == "HEAD" ]]; then
        echo "  [X] Error: Detached HEAD detected. Skipping network sync."
        echo "fail" > "$status_file"
        popd &> /dev/null || return
        [[ "$VERBOSE" == true ]] && echo "------------------------------------------"
        return
      fi

      # Check if an upstream tracking branch is set
      if ! git rev-parse --abbrev-ref --symbolic-full-name '@{u}' &> /dev/null; then
        echo "  [!] No upstream branch set. Attempting to set origin/$branch... <$curr_hash>"
        # Only try to set upstream if the remote branch actually exists
        if git ls-remote --exit-code --heads origin "$branch" &> /dev/null; then
          git branch --set-upstream-to="origin/$branch" "$branch" &> /dev/null
        else
          echo "  [?] Remote branch origin/$branch does not exist yet."
        fi
      fi

      # Pull remote changes using rebase
      pull_output=$(git pull --rebase origin "$branch" 2>&1)
      pull_exit=$?
      
      # In verbose mode, show the pull output
      if [[ "$VERBOSE" == true ]]; then
        prefix_lines "      Pull: " "$pull_output"
      fi

      # Check for conflicts immediately after pull
      if [[ $pull_exit -ne 0 ]]; then
        if [[ -d ".git/rebase-merge" || -d ".git/rebase-apply" ]]; then
          echo "  [X] Error: Conflict detected during pull --rebase. Aborting..."
          git rebase --abort &> /dev/null
          echo "fail" > "$status_file"
          popd &> /dev/null || return
          [[ "$VERBOSE" == true ]] && echo "------------------------------------------"
          return
        fi
        echo "  [?] Note: Pull failed or branch doesn't exist on origin yet."
      fi

      # Push local changes to remote
      push_output=$(git push origin "$branch" 2>&1)
      push_exit=$?

      # In verbose mode, show the push output
      if [[ "$VERBOSE" == true ]]; then
        prefix_lines "      Push: " "$push_output"
      fi

      # Check if HEAD moved (meaning pull changed something or commit was made)
      head_after=$(git rev-parse HEAD 2>/dev/null || echo "empty")
      curr_hash=$(git rev-parse --short HEAD 2>/dev/null || echo "none")
      if [[ "$head_before" != "$head_after" ]]; then
        action_taken=true
      fi

      if [[ $push_exit -eq 0 ]]; then
        # If push output doesn't contain 'up-to-date', then we pushed something
        if [[ ! "$push_output" =~ "Everything up-to-date" ]]; then
          action_taken=true
        fi
        
        if [[ "$action_taken" == true ]]; then
          echo "  [+] Successfully synced $branch (Pulled/Committed/Pushed). <$curr_hash>"
          echo "success" > "$status_file"
        else
          echo "  [.] No sync required (Local/Remote already matching). <$curr_hash>"
          echo "skip" > "$status_file"
        fi
      else
        echo "  [X] Error: Push failed for $proj_dir. Check for conflicts or permissions."
        prefix_lines "      " "$push_output"
        echo "fail" > "$status_file"
      fi
    fi

    popd &> /dev/null || return
    [[ "$VERBOSE" == true ]] && echo "------------------------------------------"
  } > "$log_file" 2>&1

  # The log is captured in $log_file and will be printed in order at the end
  # of the script execution to ensure clean, non-interleaved output.
}

# Check if git is installed
if ! command -v git &> /dev/null; then
  echo "Error: git is not installed or not in PATH."
  exit 4
fi

if [[ "$VERBOSE" == true ]]; then
  if [[ "$DETECT_ONLY" == true ]]; then
    echo "Mode: Detection only (no commits or pushes will be made)."
  else
    echo "Mode: Full sync enabled."
  fi

  if [[ "$PARALLEL_JOBS" -gt 1 ]]; then
    echo "Execution: Parallel mode ($PARALLEL_JOBS processes, delay ${PARALLEL_DELAY}s)."
  else
    echo "Execution: Sequential mode."
  fi
fi

# Check the directory exists and show start header
if [[ ! -d "$BASE_DEV_DIR" ]]; then
  echo "Error: $BASE_DEV_DIR is not a directory."
  exit 3
fi

if [[ "$VERBOSE" == true ]]; then
  echo "Starting recursive sync in: $BASE_DEV_DIR"
  echo "------------------------------------------"
fi

# Counters for final summary report
TOTAL_REPOS=0
SYNCED_REPOS=0
FAILED_REPOS=0
SKIPPED_REPOS=0
SYNC_PIDS=()

# Find all directories/files named .git (to support submodules and worktrees)
# Logic for parallel or sequential execution
while IFS= read -r -d '' git_item; do
  ((TOTAL_REPOS++))
  proj_dir=$(dirname "$git_item")
  
  # Progress indicator for all modes
  if [[ "$VERBOSE" == true ]]; then
     echo -ne "Processing repositories... ($TOTAL_REPOS found)\r"
  fi

  # Run sync_repo
  if [[ "$PARALLEL_JOBS" -gt 1 ]]; then
    # Background the process
    sync_repo "$proj_dir" "$TOTAL_REPOS" &
    SYNC_PIDS+=($!)
    
    # Sleep if requested
    if [[ "$PARALLEL_DELAY" -gt 0 ]]; then
      sleep "$PARALLEL_DELAY"
    fi
    
    # Job management: ensure we don't exceed PARALLEL_JOBS
    # We filter SYNC_PIDS to only count those still running
    while true; do
      RUNNING_COUNT=0
      for pid in "${SYNC_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
          ((RUNNING_COUNT++))
        fi
      done
      [[ "$RUNNING_COUNT" -lt "$PARALLEL_JOBS" ]] && break
      sleep 0.1
    done
  else
    # Sequential execution
    sync_repo "$proj_dir" "$TOTAL_REPOS"
  fi
done < <(find "$BASE_DEV_DIR" -name ".git" -prune -print0 2>/dev/null)

# Wait for all background jobs to finish (no-op in sequential mode)
if [[ ${#SYNC_PIDS[@]} -gt 0 ]]; then
  wait "${SYNC_PIDS[@]}"
fi
[[ "$VERBOSE" == true ]] && echo -e "\nAll repositories processed. Generating summary...\n"

# Aggregate results and display captured logs in order.
# This ensures that even in parallel mode, the output for each project
# is displayed atomically and in the sequence they were discovered.
for (( i=1; i<=TOTAL_REPOS; i++ )); do
  status_f="$TMP_RESULTS_DIR/status_$i"
  log_f="$TMP_RESULTS_DIR/log_$i"
  
  [[ -e "$status_f" ]] || continue
  
  outcome=$(cat "$status_f" 2>/dev/null)
  
  # Display log if criteria met
  if [[ "$VERBOSE" == true || "$outcome" == "success" || "$outcome" == "fail" || "$outcome" == "found" ]]; then
    if [[ -f "$log_f" ]]; then
      cat "$log_f"
    fi
  fi

  case "$outcome" in
    success) ((SYNCED_REPOS++)) ;;
    fail)    ((FAILED_REPOS++)) ;;
    found)   ((SKIPPED_REPOS++)) ;;
    skip)    ((SKIPPED_REPOS++)) ;;
    unknown) ((FAILED_REPOS++)) ;;
  esac
done

echo -e "\nRecursive sync complete."
echo "Total repositories found: $TOTAL_REPOS"
echo "Successfully synced:      $SYNCED_REPOS"
echo "Failed/Conflicts:         $FAILED_REPOS"
echo "Skipped/No changes:       $SKIPPED_REPOS"
