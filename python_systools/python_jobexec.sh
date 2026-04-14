#!/bin/bash
# -----------------------------------------------------------------------------
# Python Job Executor (python_jobexec.sh)
# v1.0.4xg  2026/04/14  XdG
#
# OBJECTIVE:
# Provides a robust entry point for executing Python scripts within a strictly
# controlled and isolated environment. It orchestrates environment setup,
# argument parsing, and final script invocation.
#
# CORE COMPONENTS:
# - Environment Sourcing: Leverages python_env.inc for environment isolation.
# - Argument Dispatcher: Separates script metadata (version, model, path) from
#   the target script's own parameters.
# - Validation: Ensures target scripts and Python runtimes are valid before execution.
#
# DATA FLOW:
# [Caller] -> python_jobexec.sh [METADATA ARGS] [JOB ARGS]
#               |
#               +-- Parse version/model/path
#               +-- Source python_env.inc (Init PATH, PYTHONPATH, etc.)
#               +-- Invoke $PYTHON $PY_JOB_PATH [JOB ARGS]
#
# -----------------------------------------------------------------------------

# ----- System Environment -----
source /opt/scripts/settings.sh
# set -o pipefail -o errexit

ENV_SCRIPT="$(dirname $0)/python_env.inc"
if [ ! -s "${ENV_SCRIPT}" ];then
  echo "ERROR: Invalid environment script [${ENV_SCRIPT}], aborting execution"
  exit 1
fi

# Default values
PYTHON_ID="3.14"
PY_JOB_PATH=""
ARG_MANDATORY=3
PYTHON_MODEL=""

# ----- Execution Logic -----
function scriptHelp() {
  cat << EOF
-----
Syntax: $0 --python-version=<version> --python-model=[gil|mt] --job-path=<full path/job.py> <job_arguments>
Example: $0 --python-version=3.14 --job-path=${WEBAPPS_BASE}/system/python_sysdiags.py --env

EOF
  exit 0
}

function argParse() {
  # Loop through command-line first 3 arguments
  ac=1
  while [ $ac -le ${ARG_MANDATORY} ]; do
    case "$1" in
      --help)
        scriptHelp
      ;;
      --python-version=*)
        PYTHON_ID="${1#*=}"
      ;;
      --python-model=*)
        PYTHON_MODEL="${1#*=}"
      ;;
      --job-path=*)
        PY_JOB_PATH="${1#*=}"
      ;;
      *)
        scriptHelp
      ;;
    esac
    shift
    ((ac++))
  done

  if [ -z "${PYTHON_ID}" ] || [ -z "${PY_JOB_PATH}" ] || ! [ -s "${PY_JOB_PATH}" ];then
    echo "ERROR: Invalid python version or job path, aborting execution"
    exit 2
  fi
}

# ----- Main -----
argParse $@
source ${ENV_SCRIPT} ${PYTHON_ID} ${PYTHON_MODEL} --env-load

# Discard the first 3 arguments
shift;shift;shift

# Execute the job with arguments
echo "Executing job: [${PY_JOB_PATH}] with python version: [${PYTHON_ID}] and model: [${PYTHON_MODEL_LABEL}]"
${PYTHON} ${PY_JOB_PATH} $@
