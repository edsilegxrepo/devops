#!/bin/bash
# ==============================================================================
#  Multi-Module Build Orchestrator
#  File      : build_orchestrate.sh
#  Version   : 2.0.0
#  Date      : 2026-10-22
#  Author    : Critical Systems / XDG
# ==============================================================================
#  Objective:
#    Discovers all active sub-projects in the codebase and triggers compilation,
#    quality auditing, and distribution packaging sequentially or in parallel
#    using the central compilation engine (build_go.sh).
#
#  Core Components:
#    1. Execution Router: Parses CLI flags, manages operational modes (--exec,
#       --clean, --sync-templates, --git-sync, --generate-key).
#    2. Sub-Project Discovery Engine: Automatically identifies active Git modules
#       in CODE_BASE ('private/'), enforcing CODE_EXCLUDES ('devops').
#    3. Process Orchestrator & Workpool: Dispatches jobs sequentially or throttles
#       concurrent background processes up to max_jobs (--parallel, --jobs=N).
#    4. Log Multiplexer & Buffer: Captures per-module stdout/stderr into isolated
#       temporary files to eliminate terminal interleaving during parallel execution.
#    5. Template Synchronizer: Broadcasts central .gitignore, SECURITY.md, and
#       LICENSE files across all private sub-projects (--sync-templates).
#    6. Git AutoSync Manager: Bridges to centralized repository synchronizer (--git-sync).
#    7. Signal & Process Reaper Trap: Guarantees termination of background workers
#       and cleanup of temporary directories upon EXIT, INT, or TERM signals.
#
#  Functionality & Data Flows:
#    - Startup: Sources build.inc, validates CODE_BASE, and prepares output directories.
#    - Pre-Clean (Optional): If --clean is passed, wipes ../bin and ../distrib.
#    - Discovery: Iterates CODE_BASE folders, filtering out non-directories and exclusions.
#    - Execution Loop: Dispatches build_go.sh inside each module with forwarded flags.
#    - Monitoring & Reaping: In parallel mode, polls running child PIDs, reaps finished
#      tasks, prints execution status, and flushes failure logs upon error.
#    - Summary & Exit: Outputs module completion metrics and exits with 0 on success
#      or the first encountered non-zero diagnostic code on failure.
#
#  Test Strategy Explanation:
#    - Test Suite Orchestration: Forwarding --testsuite runs automated Go unit and
#      coverage tests across every discovered sub-module in the workspace.
#    - Output Isolation: In parallel execution, test output and coverage summaries
#      are buffered in per-module log files; failures immediately print the trailing
#      diagnostic lines to stderr without corrupting the progress display.
#    - Fail-Fast Regression Protection: With --fail-fast enabled, the first failing
#      module test immediately aborts pending dispatches and terminates active jobs,
#      minimizing feedback latency in CI/CD environments.
#
#  Design Principles:
#    1. Path Independence: Dynamically resolves absolute paths using BASH_SOURCE.
#    2. Fail-Fast Validation: Verifies codebase directory structures and the
#       presence of build_go.sh before executing loop actions.
#    3. Granular Diagnostics: Standardized exit codes across all execution paths.
#    4. Scalability: Optional multi-job parallel compilation with log buffering.
#
#  Syntax:
#    ./build_orchestrate.sh [--exec] [--clean] [--parallel] [--jobs=N] [--fail-fast]
#                   [--windows] [--linux] [--all-platform] [--archive] [--rpm] [--deb] [--all-pkg] [--verify-pkg]
#                   [--compile-only] [--lint-only] [--ignore-audit] [--testsuite]
#                   [--sync-templates] [--git-sync]
# ==============================================================================

set -euo pipefail

# Resolve script directory and code home root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
CODE_HOME="$(cd "${SCRIPT_DIR}/../../.." &> /dev/null && pwd)"
cd "${CODE_HOME}" || exit 1

# Load central build include (constants, exit codes, defaults, and shared utilities)
if [ ! -f "${SCRIPT_DIR}/build.inc" ]; then
  echo "ERROR: Required configuration file '${SCRIPT_DIR}/build.inc' not found." >&2
  exit 4
fi
# shellcheck source=./build.inc disable=SC1091
source "${SCRIPT_DIR}/build.inc"

BUILD_GO_SCRIPT="${SCRIPT_DIR}/${DEFAULT_BUILD_GO_SCRIPT}"
BIN_DIR="${DEFAULT_BIN_DIR}"
DIST_DIR="${DEFAULT_DIST_DIR}"
export BIN_DIR
export DIST_DIR

# Function: cleanup_bin_dir
# Objective: Removes intermediate compiled binaries from the binary directory
#            after distribution packaging completes.
cleanup_bin_dir() {
  if [ -d "${BIN_DIR}" ]; then
    rm -rf "${BIN_DIR:?}"/* 2> /dev/null || true
  fi
  mkdir -p "${BIN_DIR}" 2> /dev/null || true
}

# ------------------------------------------------------------------------------
# Temp Directory Tracking & Cleanup Trap
# ------------------------------------------------------------------------------
CHILD_PIDS=()

# Function: cleanup_orchestrator
# Objective: Signal and exit trap handler. Terminates all active child processes
#            and removes tracked temporary directories before process exit.
# shellcheck disable=SC2329
cleanup_orchestrator() {
  local exit_status=$?
  # Terminate any remaining background child processes
  if [ ${#CHILD_PIDS[@]} -gt 0 ]; then
    for pid in "${CHILD_PIDS[@]}"; do
      kill "${pid}" 2> /dev/null || true
    done
  fi
  # Clean up tracked temp directories
  cleanup_tracked_temp_dirs
  exit "${exit_status}"
}
trap cleanup_orchestrator EXIT INT TERM

# ------------------------------------------------------------------------------
# Helper: Exclusion Checker
# ------------------------------------------------------------------------------
# Function: is_excluded
# Objective: Checks if a target sub-project directory matches the exclude list.
# Arguments:
#   $1 - Sub-project folder name to evaluate
# Returns: 0 if excluded, 1 if active candidate.
is_excluded() {
  local target_name="$1"
  for excl in "${CODE_EXCLUDES[@]}"; do
    if [ "${target_name}" == "${excl}" ]; then
      return 0
    fi
  done
  return 1
}

# ------------------------------------------------------------------------------
# Function: sync_templates
# Objective:
#   Distributes central codebase configuration templates (.gitignore, SECURITY.md,
#   and LICENSE) to all discovered active git repositories inside the CODE_BASE.
# Returns: EXIT_SUCCESS on full success, EXIT_SYNC on one or more copy failures.
# ------------------------------------------------------------------------------
sync_templates() {
  local src_gitignore="${DEFAULT_TEMPLATE_GITIGNORE}"
  local src_security="${DEFAULT_TEMPLATE_SECURITY}"
  local src_license="${DEFAULT_TEMPLATE_LICENSE}"
  local target_dir="${CODE_BASE}"
  local repo repo_name copy_success

  # Pre-flight Validation
  for tpl in "${src_gitignore}" "${src_security}" "${src_license}"; do
    if [ ! -f "${tpl}" ]; then
      echo "ERROR: Template not found at '${tpl}'" >&2
      exit "${EXIT_CONFIG}"
    fi
  done
  if [ ! -d "${target_dir}" ]; then
    echo "ERROR: Codebase directory not found at '${target_dir}'" >&2
    exit "${EXIT_CONFIG}"
  fi

  echo "Starting synchronization of templates..."
  echo "Source: ${src_gitignore} -> .gitignore"
  echo "Source: ${src_security} -> SECURITY.md"
  echo "Source: ${src_license} -> LICENSE"
  echo "Target directory: ${target_dir}"
  echo "================================================================================"

  local repo_count=0
  local success_count=0

  for repo in "${target_dir}"/*; do
    if [ -d "${repo}" ] && [ -e "${repo}/.git" ]; then
      repo_name=$(basename "${repo}")
      echo "Processing private repository: ${repo_name}"

      copy_success=true
      cp -af "${src_gitignore}" "${repo}/.gitignore" || copy_success=false
      cp -af "${src_security}" "${repo}/SECURITY.md" || copy_success=false
      cp -af "${src_license}" "${repo}/LICENSE" || copy_success=false

      if [ "${copy_success}" = true ]; then
        echo "  [OK] Successfully synchronized all templates."
        success_count=$((success_count + 1))
      else
        echo "  [ERROR] Failed to copy one or more templates to ${repo_name}." >&2
      fi
      repo_count=$((repo_count + 1))
    fi
  done

  echo "================================================================================"
  echo "Synchronization completed."
  echo "Total repositories processed: ${repo_count}"
  echo "Successfully updated:        ${success_count}"

  if [ "${repo_count}" -ne "${success_count}" ]; then
    exit "${EXIT_SYNC}"
  fi
  exit "${EXIT_SUCCESS}"
}

# ------------------------------------------------------------------------------
# Function: git_sync
# Objective:
#   Synchronizes all sub-projects/repositories within the private directory
#   to Git using the centralized autosync manager utility.
# Returns: EXIT_SUCCESS on full success, EXIT_SYNC on Git synchronization failure.
# ------------------------------------------------------------------------------
git_sync() {
  local sync_script="${DEFAULT_GIT_AUTOSYNC_SCRIPT}"
  local sync_msg="${DEFAULT_GIT_SYNC_MESSAGE}"

  if [ ! -f "${sync_script}" ]; then
    echo "ERROR: Git autosync script not found at '${sync_script}'" >&2
    exit "${EXIT_DEPENDENCY}"
  fi

  echo "Starting Git synchronization across all repositories in '${CODE_BASE}'..."
  echo "Executing: ${sync_script} --base-folder=${CODE_BASE} --message=\"${sync_msg}\" --parallel"
  echo "================================================================================"

  if ! "${sync_script}" --base-folder="${CODE_BASE}" --message="${sync_msg}" --parallel; then
    echo "ERROR: Git synchronization failed." >&2
    exit "${EXIT_SYNC}"
  fi
  exit "${EXIT_SUCCESS}"
}

# ------------------------------------------------------------------------------
# Function: run_builds
# Objective:
#   Orchestrates compilation and deployment actions across all sub-projects.
#   Supports sequential execution or multi-job parallel compilation (--parallel / --jobs=N).
# Arguments:
#   $1 - is_parallel (true/false)
#   $2 - max_jobs (integer concurrency limit)
#   $3 - fail_fast (true/false)
#   $@ - target_flags forwarded to build_go.sh
# ------------------------------------------------------------------------------
run_builds() {
  local is_parallel="$1"
  local max_jobs="$2"
  local fail_fast="$3"
  shift 3
  local target_flags=("$@")

  # Fail-Fast: Validate that the compiler engine script is present.
  if [ ! -f "${BUILD_GO_SCRIPT}" ]; then
    echo "ERROR: Compiler script '${BUILD_GO_SCRIPT}' not found." >&2
    exit "${EXIT_DEPENDENCY}"
  fi

  # Check if any packaging action was requested
  local has_packaging=false
  for flag in "${target_flags[@]}"; do
    case "${flag}" in
      --archive | --rpm | --deb | --all-pkg | --all)
        has_packaging=true
        ;;
    esac
  done

  # If packaging was requested, ensure clean bin folder before starting
  if [ "${has_packaging}" = true ]; then
    cleanup_bin_dir
  fi

  # Collect candidate sub-project directories
  local candidate_dirs=()
  for d in "${CODE_BASE}"/*; do
    [ -d "${d}" ] || continue
    local folder_name
    folder_name=$(basename "${d}")
    if is_excluded "${folder_name}"; then
      continue
    fi
    candidate_dirs+=("${d}")
  done

  local total_repos=${#candidate_dirs[@]}
  local failed_repos=()
  local first_error_code=0
  local success_count=0

  echo "Build Configuration:"
  echo "  Codebase path        : ${CODE_BASE}"
  echo "  Target modules       : ${total_repos}"
  echo "  Execution mode       : $([ "${is_parallel}" = true ] && echo "Parallel (Jobs: ${max_jobs})" || echo "Sequential")"
  echo "  Fail-Fast enabled    : ${fail_fast}"
  echo "  Forwarded flags      : ${target_flags[*]}"
  echo "================================================================================"

  if [ "${is_parallel}" = false ]; then
    # --------------------------------------------------------------------------
    # Sequential Execution Mode
    # --------------------------------------------------------------------------
    for d in "${candidate_dirs[@]}"; do
      local folder_name
      folder_name=$(basename "${d}")
      echo -e "\n-----[${d^^}]-----------------------------------------------------------------------------------"
      if pushd "$d" &> /dev/null; then
        local job_exit=0
        "${BUILD_GO_SCRIPT}" "${target_flags[@]}" || job_exit=$?
        popd &> /dev/null || true

        if [ "${job_exit}" -ne 0 ]; then
          failed_repos+=("${folder_name}")
          [ "${first_error_code}" -eq 0 ] && first_error_code="${job_exit}"
          if [ "${fail_fast}" = true ]; then
            echo "ERROR: Fail-fast enabled. Aborting remaining builds after failure in ${folder_name}." >&2
            break
          fi
        else
          success_count=$((success_count + 1))
        fi
      else
        echo "ERROR: Failed to enter directory $d" >&2
        failed_repos+=("${folder_name}")
        [ "${first_error_code}" -eq 0 ] && first_error_code="${EXIT_GENERAL}"
        if [ "${fail_fast}" = true ]; then
          break
        fi
      fi
    done
  else
    # --------------------------------------------------------------------------
    # Parallel Execution Mode (with isolated log buffering)
    # --------------------------------------------------------------------------
    local log_dir
    log_dir="$(make_temp_dir "orch_logs")"
    local running_jobs=0
    declare -A job_pids=()
    declare -A job_modules=()
    declare -A job_logs=()

    # Function: reap_job
    # Objective: Waits for any completed background worker process, inspects its exit status,
    #            logs the completion or failure output, and manages the active job counter.
    reap_job() {
      local finished_pid=""
      local job_exit=0

      if wait -n -p finished_pid 2> /dev/null; then
        job_exit=$?
      else
        job_exit=$?
        if [ -z "${finished_pid}" ]; then
          for pid in "${!job_pids[@]}"; do
            if ! kill -0 "${pid}" 2> /dev/null; then
              finished_pid="${pid}"
              wait "${pid}" 2> /dev/null || true
              break
            fi
          done
        fi
      fi

      if [ -n "${finished_pid}" ] && [ -n "${job_modules[${finished_pid}]:-}" ]; then
        local mod_name="${job_modules[${finished_pid}]}"
        local mod_log="${job_logs[${finished_pid}]}"

        if [ ${job_exit} -eq 0 ]; then
          echo "  [OK] Successfully completed: ${mod_name}"
          success_count=$((success_count + 1))
        else
          echo "  [ERROR] Build failed for ${mod_name} (Exit code: ${job_exit}):" >&2
          echo "-------------------- Last 25 log lines (${mod_name}) --------------------" >&2
          tail -n 25 "${mod_log}" 2> /dev/null || true >&2
          echo "------------------------------------------------------------------------" >&2
          failed_repos+=("${mod_name}")
          [ ${first_error_code} -eq 0 ] && first_error_code=${job_exit}
        fi

        unset "job_pids[${finished_pid}]"
        unset "job_modules[${finished_pid}]"
        unset "job_logs[${finished_pid}]"
        running_jobs=$((running_jobs - 1))
      fi
    }

    for d in "${candidate_dirs[@]}"; do
      local folder_name
      folder_name=$(basename "${d}")
      local log_file="${log_dir}/${folder_name}.log"

      # Throttle concurrency to max_jobs
      while [ ${running_jobs} -ge "${max_jobs}" ]; do
        reap_job
        if [ "${fail_fast}" = true ] && [ ${#failed_repos[@]} -gt 0 ]; then
          echo "ERROR: Fail-fast triggered. Halting further dispatches and terminating active jobs." >&2
          for pid in "${!job_pids[@]}"; do
            kill "${pid}" 2> /dev/null || true
          done
          break 2
        fi
      done

      # Launch next module build in background
      echo "  [>>] Dispatching build: ${folder_name}"
      (
        cd "${d}" && "${BUILD_GO_SCRIPT}" "${target_flags[@]}"
      ) > "${log_file}" 2>&1 &
      local child_pid=$!

      CHILD_PIDS+=("${child_pid}")
      job_pids["${child_pid}"]=1
      job_modules["${child_pid}"]="${folder_name}"
      job_logs["${child_pid}"]="${log_file}"
      running_jobs=$((running_jobs + 1))
    done

    # Reap all remaining parallel jobs
    while [ ${running_jobs} -gt 0 ]; do
      reap_job
      if [ "${fail_fast}" = true ] && [ ${#failed_repos[@]} -gt 0 ]; then
        for pid in "${!job_pids[@]}"; do
          kill "${pid}" 2> /dev/null || true
        done
      fi
    done
  fi

  # Clean up bin folder if packaging was requested
  if [ "${has_packaging}" = true ]; then
    echo "  [INFO] Packaging requested: cleaning up binary directory (${BIN_DIR})..."
    cleanup_bin_dir
  fi

  echo -e "\n================================================================================"
  echo "Build Execution Summary:"
  echo "Total modules discovered: ${total_repos}"
  if [ "${fail_fast}" = true ] && [ $((success_count + ${#failed_repos[@]})) -lt "${total_repos}" ]; then
    echo "Modules attempted:        $((success_count + ${#failed_repos[@]}))"
  fi
  echo "Successfully built:       ${success_count}"
  echo "Failed builds:            ${#failed_repos[@]}"

  if [ ${#failed_repos[@]} -gt 0 ]; then
    echo "Failed modules:          ${failed_repos[*]}"
    echo "================================================================================"
    exit "${first_error_code:-$EXIT_GENERAL}"
  fi
  echo "================================================================================"
  exit "${EXIT_SUCCESS}"
}

# ------------------------------------------------------------------------------
# Function: usage
# Objective: Displays script syntax, operational modes, platform flags, and exit codes.
# Arguments:
#   $1 - Exit code to exit with (optional, defaults to 0)
# ------------------------------------------------------------------------------
usage() {
  local exit_code="${1:-0}"
  cat << EOF
Usage: $0 [modes] [codebase-options] [parallel-options] [build-flags...]

Modes:
  --exec             Run build orchestration on all active sub-projects (default)
  --clean            Clean all built artifacts in ../bin/ and ../distrib/ (additive or standalone)
  --sync-templates   Copy TMPL.gitignore, SECURITY.md, and LICENSE to all codebase repos
  --git-sync         Synchronize all codebase repositories with Git
  --help             Show this help message

Codebase Options:
  --code-base=<path> Set codebase directory containing sub-projects (default: ${DEFAULT_CODE_BASE})

Parallel Execution Options:
  --parallel         Execute module builds in parallel (default jobs: $(nproc 2> /dev/null || echo 4))
  --jobs=N           Set maximum parallel jobs (e.g. --jobs=4)
  --fail-fast        Stop processing remaining builds on the first error

Platform Flags (forwarded to build_go.sh):
  --windows          Target Windows (builds ../bin/<name>.exe; default on Windows)
  --linux            Target Linux (builds static ../bin/<name>; default on Linux)
  --all-platform     Target both Windows and Linux

Packaging Flags (forwarded to build_go.sh):
  --archive          Build release archive (.zip for Windows, .tar.xz for Linux)
                     and dedicated .sha256 hash files (default packaging action)
  --rpm              Build RPM package in ../distrib/ (Linux target; builds via WSL on Windows)
  --deb              Build DEB package in ../distrib/ (Linux target; builds via WSL on Windows)
  --all-pkg          Build all release artifacts (--archive --rpm --deb; builds via WSL on Windows)
  --verify-pkg       Verify checksums, RPM/DEB metadata, and archive integrity in ../distrib/
  --sign             Sign release archives with default SSH key (~/.ssh/signing/release_key)
  --sign=<path>      Sign release archives with specified SSH private key
  --genkey           Generate Ed25519 signing key pair at ~/.ssh/signing/release_key and exit (requires --identity=<id>)
  --genkey=<path>    Generate a new Ed25519 SSH signing key pair at <path> and exit (requires --identity=<id>)
  --identity=<id>    Signer identity email/name (mandatory with --genkey, e.g. mis@criticalsys.net)
  --comment=<text>   Custom key comment (optional, defaults to 'Critical Systems Release Signing <<id>>')

Operational Flags (forwarded to build_go.sh):
  --compile-only     Skip code quality checks, tests, and linters
  --lint-only        Run linters/audits only, then exit
  --ignore-audit     Continue compilation even if linters find warnings
  --testsuite        Execute Go test suite with coverage
  --update-modules   Update Go modules to latest release
  --vendor           Sync vendor directory
  --log=<file>       Append all operations to an NDJSON audit log file

Exit Codes:
  0 = Success
  1 = General Error
  2 = Usage / CLI Syntax Error
  3 = Configuration Error
  4 = Missing Prerequisite Dependency
  5 = Code Quality / Audit Failure
  6 = Test Suite Failure
  7 = Compilation Failure
  8 = Packaging Failure
  9 = Sync Failure
EOF
  exit "${exit_code}"
}

# ------------------------------------------------------------------------------
# Function: main
# Objective:
#   Serves as the main routing logic, parsing arguments, handling mode selection,
#   triggering standalone cleanup, and invoking execution dispatchers.
# ------------------------------------------------------------------------------
main() {
  local build_flags=()
  local run_mode=""
  local is_parallel=false
  local max_jobs="${DEFAULT_PARALLEL_JOBS}"
  local fail_fast=false
  local do_clean=false
  local generate_key_cmd=""
  local key_identity=""
  local key_comment=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --sync-templates)
        run_mode="sync-templates"
        shift
        ;;
      --git-sync)
        run_mode="git-sync"
        shift
        ;;
      --clean)
        do_clean=true
        shift
        ;;
      --code-base=*)
        CODE_BASE="${1#*=}"
        shift
        ;;
      --code-base)
        echo "ERROR: --code-base requires a directory path. Format: --code-base=<path>" >&2
        exit "${EXIT_USAGE}"
        ;;
      --exec)
        run_mode="exec"
        shift
        ;;
      --parallel)
        is_parallel=true
        shift
        ;;
      --jobs=*)
        is_parallel=true
        max_jobs="${1#*=}"
        shift
        ;;
      --jobs)
        echo "ERROR: --jobs requires an argument. Format: --jobs=N" >&2
        exit "${EXIT_USAGE}"
        ;;
      --fail-fast)
        fail_fast=true
        shift
        ;;
      --log=*)
        local user_log="${1#*=}"
        local log_dir abs_log
        log_dir="$(mkdir -p "$(dirname "${user_log}")" 2> /dev/null && cd "$(dirname "${user_log}")" &> /dev/null && pwd)"
        abs_log="${log_dir}/$(basename "${user_log}")"
        build_flags+=("--log=${abs_log}")
        shift
        ;;
      --log)
        echo "ERROR: --log requires a file path. Format: --log=<path>" >&2
        exit "${EXIT_USAGE}"
        ;;
      --sign)
        build_flags+=("--sign")
        shift
        ;;
      --sign=*)
        local user_key
        user_key="$(resolve_signing_key_path "${1#*=}")"
        build_flags+=("--sign=${user_key}")
        shift
        ;;
      --identity=*)
        key_identity="${1#*=}"
        shift
        ;;
      --identity)
        log_error "--identity requires a value. Format: --identity=<email-or-id>"
        exit "${EXIT_USAGE}"
        ;;
      --comment=*)
        key_comment="${1#*=}"
        shift
        ;;
      --comment)
        log_error "--comment requires a value. Format: --comment=<text>"
        exit "${EXIT_USAGE}"
        ;;
      --genkey | --generate-key)
        generate_key_cmd="--genkey"
        shift
        ;;
      --genkey=* | --generate-key=*)
        generate_key_cmd="$1"
        shift
        ;;
      --help)
        usage "${EXIT_SUCCESS}"
        ;;
      *)
        build_flags+=("$1")
        shift
        ;;
    esac
  done

  # Strip trailing slash from codebase path
  CODE_BASE="${CODE_BASE%/}"

  if [ -n "${generate_key_cmd}" ]; then
    if [ -z "${key_identity}" ]; then
      log_error "--identity=<id> is MANDATORY when generating a signing key."
      log_error "Example: $0 ${generate_key_cmd} --identity=${DEFAULT_IDENTITY}"
      exit "${EXIT_USAGE}"
    fi
    local gen_key_path="${DEFAULT_SIGN_KEY}"
    if [[ "${generate_key_cmd}" == *=* ]]; then
      gen_key_path="${generate_key_cmd#*=}"
    fi
    generate_signing_key "${gen_key_path}" "${key_identity}" "${key_comment}"
  fi

  if [ "${do_clean}" = true ]; then
    clean_workspace_artifacts "${BIN_DIR}" "${DIST_DIR}"
    if [ -z "${run_mode}" ] && [ ${#build_flags[@]} -eq 0 ]; then
      exit "${EXIT_SUCCESS}"
    fi
  fi

  # Validate that target codebase directory exists before executing build operations
  if [ ! -d "${CODE_BASE}" ]; then
    log_error "Codebase directory '${CODE_BASE}' not found."
    exit "${EXIT_CONFIG}"
  fi

  case "${run_mode}" in
    sync-templates)
      sync_templates
      ;;
    git-sync)
      git_sync
      ;;
    exec | "")
      run_builds "${is_parallel}" "${max_jobs}" "${fail_fast}" "${build_flags[@]}"
      ;;
  esac
}

main "$@"
