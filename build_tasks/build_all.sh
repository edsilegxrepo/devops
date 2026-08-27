#!/bin/bash
# ==============================================================================
#  DirPoller Multi-Module Build Orchestrator
#  File      : build_all.sh
#  Version   : 1.1.1
#  Date      : 2026-07-23
#  Author    : Critical Systems / XDG
# ==============================================================================
#  Objective:
#    Discovers all active sub-projects in the codebase and triggers compilation,
#    quality auditing, and distribution packaging sequentially using the central
#    compilation engine (build_go.sh).
#
#  Design Principles:
#    1. Path Independence: Dynamically resolves absolute paths using BASH_SOURCE,
#       ensuring it can be safely executed from any working directory level.
#    2. Fail-Fast Validation: Verifies codebase directory structures and the
#       presence of build_go.sh before executing loop actions.
#    3. Isolation: Uses pushd/popd sandboxing to guarantee workspace integrity.
#
#  Syntax:
#    ./build_all.sh [--exec | --sync-templates | --git-sync]
# ==============================================================================

# Global Configuration Parameters
CODE_BASE="private"    # Target subdirectory containing sub-projects/repositories
CODE_EXCLUDES="devops" # Subdirectories to exclude from build orchestration

# Resolve absolute path of workspace root and switch to it to guarantee path independence.
# This ensures that relative directory operations (like validations and loops) execute
# predictably regardless of the user's active terminal directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
cd "${SCRIPT_DIR}" || exit 1

# Relative reference to the module compiler engine script
BUILD_GO_SCRIPT="${SCRIPT_DIR}/build_go.sh"

# Fail-Fast: Validate that the target codebase base directory actually exists.
if [ ! -d "${CODE_BASE}" ]; then
  echo "ERROR: Codebase directory '${CODE_BASE}' not found."
  exit 1
fi

# ------------------------------------------------------------------------------
# Function: sync_templates
# Objective:
#   Distributes central codebase configuration templates (.gitignore, SECURITY.md,
#   and LICENSE) to all discovered active git repositories inside the CODE_BASE.
# Returns:
#   0 on successful synchronization of all repositories.
#   1 if any repository synchronization operation fails.
# ------------------------------------------------------------------------------
sync_templates() {
  local src_gitignore="./TMPL.gitignore"
  local src_security="./SECURITY.md"
  local src_license="./LICENSE"
  local private_dir="./${CODE_BASE}"
  local repo
  local repo_name
  local copy_success

  # Pre-flight Validation: Verify that all source template files exist before copying.
  if [ ! -f "${src_gitignore}" ]; then
    echo "ERROR: Template gitignore not found at '${src_gitignore}'"
    exit 1
  fi
  if [ ! -f "${src_security}" ]; then
    echo "ERROR: Template SECURITY.md not found at '${src_security}'"
    exit 1
  fi
  if [ ! -f "${src_license}" ]; then
    echo "ERROR: Template LICENSE not found at '${src_license}'"
    exit 1
  fi
  if [ ! -d "${private_dir}" ]; then
    echo "ERROR: Private directory not found at '${private_dir}'"
    exit 1
  fi

  echo "Starting synchronization of templates..."
  echo "Source: ${src_gitignore} -> .gitignore"
  echo "Source: ${src_security} -> SECURITY.md"
  echo "Source: ${src_license} -> LICENSE"
  echo "Target directory: ${private_dir}"
  echo "================================================================================"

  local repo_count=0
  local success_count=0

  # Iterate through all subdirectories in private/ to locate active git repositories
  for repo in "${private_dir}"/*; do
    # Only target items that are directories and contain an initialized .git folder/file
    if [ -d "${repo}" ] && [ -e "${repo}/.git" ]; then
      repo_name=$(basename "${repo}")
      echo "Processing private repository: ${repo_name}"

      copy_success=true
      # Copy files and log failures if any operation fails
      cp -af "${src_gitignore}" "${repo}/.gitignore" || copy_success=false
      cp -af "${src_security}" "${repo}/SECURITY.md" || copy_success=false
      cp -af "${src_license}" "${repo}/LICENSE" || copy_success=false

      if [ "${copy_success}" = true ]; then
        echo "  [OK] Successfully synchronized all templates."
        ((success_count++))
      else
        echo "  [ERROR] Failed to copy one or more templates to ${repo_name}."
      fi
      ((repo_count++))
    fi
  done

  echo "================================================================================"
  echo "Synchronization completed."
  echo "Total repositories processed: ${repo_count}"
  echo "Successfully updated:        ${success_count}"

  # Exit with error status if any repository failed synchronization
  if [ "${repo_count}" -ne "${success_count}" ]; then
    exit 1
  fi
}

# ------------------------------------------------------------------------------
# Function: run_builds
# Objective:
#   Orchestrates compilation and deployment actions across all sub-projects
#   in the CODE_BASE by sequentially executing the build engine (build_go.sh)
#   in an isolated environment.
# Returns:
#   0 on successful build execution of all modules.
#   Exits immediately if compilation pre-requisites are not met.
#   Exits with status 1 if any of the sub-project builds failed.
# ------------------------------------------------------------------------------
run_builds() {
  # Fail-Fast: Validate that the compiler engine script is present.
  if [ ! -f "${BUILD_GO_SCRIPT}" ]; then
    echo "ERROR: Compiler script '${BUILD_GO_SCRIPT}' not found."
    exit 1
  fi

  local folder_name
  local failed_repos=()
  local total_repos=0
  # Loop through all subdirectories in CODE_BASE (excluding CODE_EXCLUDES) safely
  for d in "${CODE_BASE}"/*; do
    [ -d "${d}" ] || continue
    folder_name=$(basename "${d}")
    if [[ " ${CODE_EXCLUDES} " =~ " ${folder_name} " ]]; then
      continue
    fi
    echo -e "\n-----[${d^^}]-----------------------------------------------------------------------------------"
    ((total_repos++))
    # Execute build engine in a subshell sandboxed environment via pushd/popd to maintain path consistency
    if pushd "$d" &> /dev/null; then
      if ! "${BUILD_GO_SCRIPT}" --publish; then
        failed_repos+=("${folder_name}")
      fi
      popd &> /dev/null || true
    else
      echo "ERROR: Failed to enter directory $d"
      failed_repos+=("${folder_name}")
    fi
  done

  echo -e "\n================================================================================"
  echo "Build Execution Summary:"
  echo "Total modules processed: ${total_repos}"
  echo "Successfully built:      $((total_repos - ${#failed_repos[@]}))"
  echo "Failed builds:           ${#failed_repos[@]}"

  if [ ${#failed_repos[@]} -gt 0 ]; then
    echo "Failed modules:          ${failed_repos[*]}"
    echo "================================================================================"
    exit 1
  fi
  echo "================================================================================"
}

# ------------------------------------------------------------------------------
# Function: git_sync
# Objective:
#   Synchronizes all sub-projects/repositories within the private directory
#   to Git using the centralized autosync manager utility.
# Returns:
#   0 on successful synchronization.
#   1 if the synchronization script or directory is missing, or fails.
# ------------------------------------------------------------------------------
git_sync() {
  local sync_script="./private/devops/git_repomgr/git_autosync.sh"

  if [ ! -f "${sync_script}" ]; then
    echo "ERROR: Git autosync script not found at '${sync_script}'"
    exit 1
  fi

  echo "Starting Git synchronization across all private repositories..."
  echo "Executing: ${sync_script} --base-folder=./private --message=\"Module Updates\" --parallel"
  echo "================================================================================"

  if ! "${sync_script}" --base-folder=./private --message="Module Updates" --parallel; then
    echo "ERROR: Git synchronization failed."
    exit 1
  fi
}

# ------------------------------------------------------------------------------
# Function: usage
# Objective:
#   Displays script syntax and available options, then exits.
# Arguments:
#   $1 - Exit code (optional, default 0).
# ------------------------------------------------------------------------------
usage() {
  local exit_code="${1:-0}"
  echo "Usage: $0 [options]"
  echo ""
  echo "Options:"
  echo "  --exec             Run build orchestration on all active sub-projects"
  echo "  --sync-templates   Copy TMPL.gitignore, SECURITY.md, and LICENSE to all private repos"
  echo "  --git-sync         Synchronize all private repositories with Git"
  echo "  -h, --help         Show this help message"
  exit "${exit_code}"
}

# ------------------------------------------------------------------------------
# Function: main
# Objective:
#   Serves as the main routing logic, parsing arguments and invoking handlers.
# Arguments:
#   $@ - Array of command-line arguments.
# ------------------------------------------------------------------------------
main() {
  case "$1" in
    --sync-templates)
      sync_templates
      ;;
    --git-sync)
      git_sync
      ;;
    --exec)
      run_builds
      ;;
    -h | --help | "")
      usage 0
      ;;
    *)
      echo "ERROR: Unknown option '$1'"
      usage 1
      ;;
  esac
}

# Invoke entrypoint
main "$@"
