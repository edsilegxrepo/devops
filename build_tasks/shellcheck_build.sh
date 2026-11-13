#!/usr/bin/env bash
# ==============================================================================
#  ShellCheck Cross-Target Builder (Windows x86_64 & Static Linux amd64)
#  File      : shellcheck_build.sh
#  Version   : 2.0.0
#  Date      : 2026-11-13
#  Author    : Critical Systems / XDG
# ==============================================================================
#  Objective:
#    Builds up-to-date ShellCheck binaries from https://github.com/koalaman/shellcheck
#    using upstream's reproducible Docker builders:
#      - builders/linux.x86_64   -> statically linked Linux amd64 'shellcheck'
#      - builders/windows.x86_64 -> standalone Windows x86_64 'shellcheck.exe'
#
#    Fully compatible with:
#      - Windows Cygwin / MSYS2 / Git Bash (delegates Docker through WSL)
#      - Native Linux (invokes Docker directly)
#
#    Always fetches the latest commit on 'master' and embeds the 7-character
#    Git commit SHA in generated release archives for end-to-end traceability.
#
#  Syntax:
#    ./shellcheck_build.sh [--linux] [--windows] [--all]
#                          [--out-dir=<path>] [--no-package] [--no-cache]
#                          [--dry-run] [-h | --help]
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
if [ ! -f "${SCRIPT_DIR}/build.inc" ]; then
  echo "ERROR: Required include file '${SCRIPT_DIR}/build.inc' not found." >&2
  exit 4
fi
# shellcheck source=./build.inc disable=SC1091
source "${SCRIPT_DIR}/build.inc"

# Prioritize POSIX core tools on Cygwin/MSYS2 while ensuring Git is discoverable
if [ "${HOST_OS}" = "WIN" ]; then
  export PATH="/usr/bin:/bin:${PATH}"
  if ! command -v git &> /dev/null; then
    for git_dir in "/cmd" "${DEFAULT_GIT_SEARCH_PATHS[@]}" "d:/dev/git/cmd" "c:/Program Files/Git/cmd"; do
      normalize_and_add_to_path "${git_dir}" || true
      command -v git &> /dev/null && break || true
    done
  fi
fi

# ------------------------------------------------------------------------------
# Defaults & Mutable State
# ------------------------------------------------------------------------------
readonly REPO_URL="https://github.com/koalaman/shellcheck.git"
readonly GIT_BRANCH="master"
OUT_DIR="$(pwd)/dist/shellcheck"

TARGET_LINUX=false
TARGET_WINDOWS=false

DO_PACKAGE=true
NO_CACHE=false
DRY_RUN=false

CLONED_SRC_DIR=""
DETECTED_VERSION=""
COMMIT_SHORT=""

# ------------------------------------------------------------------------------
# Cleanup Trap
# ------------------------------------------------------------------------------
# shellcheck disable=SC2329 # Invoked via trap on EXIT/INT/TERM
cleanup() {
  local exit_status=$?
  cleanup_tracked_temp_dirs
  exit "${exit_status}"
}
trap cleanup EXIT INT TERM

# ------------------------------------------------------------------------------
# Usage / Help
# ------------------------------------------------------------------------------
usage() {
  cat << EOF
Usage: $(basename "$0") [OPTIONS]

Targets (at least one required):
  --linux                     Build static Linux amd64 'shellcheck' ELF binary
  --windows                   Build Windows x86_64 'shellcheck.exe'
  --all                       Build both Linux amd64 (static) and Windows x86_64

Options:
  --out-dir=<path>            Output directory for packages/binaries (default: ./dist/shellcheck)
  --no-package                Skip release archives and keep unpacked binaries in --out-dir
  --no-cache                  Pass --no-cache to Docker image builds
  --dry-run                   Print resolved paths and operations without building
  -h, --help                  Display this help message
EOF
}

# ------------------------------------------------------------------------------
# Argument Parsing
# ------------------------------------------------------------------------------
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --linux)        TARGET_LINUX=true ;;
      --windows)      TARGET_WINDOWS=true ;;
      --all)          TARGET_LINUX=true; TARGET_WINDOWS=true ;;
      --out-dir=*)    OUT_DIR="${1#*=}" ;;
      --package)      DO_PACKAGE=true ;;
      --no-package)   DO_PACKAGE=false ;;
      --no-cache)     NO_CACHE=true ;;
      --dry-run)      DRY_RUN=true ;;
      -h|--help)      usage; exit "${EXIT_SUCCESS}" ;;
      *)
        log_error "Unknown argument: $1"
        usage >&2
        exit "${EXIT_USAGE}"
        ;;
    esac
    shift
  done

  if [ "${TARGET_LINUX}" = false ] && [ "${TARGET_WINDOWS}" = false ]; then
    log_error "Specify at least one target (--linux, --windows, --all)."
    usage >&2
    exit "${EXIT_USAGE}"
  fi
}

# ------------------------------------------------------------------------------
# Cross-Platform Path & Docker Execution Bridge
# ------------------------------------------------------------------------------
to_posix_path() {
  local raw="${1:-}"
  [ -z "${raw}" ] && return 0
  if [ "${HOST_OS}" = "WIN" ] && command -v cygpath &> /dev/null; then
    cygpath -u "${raw}" 2> /dev/null || echo "${raw}"
  else
    echo "${raw}"
  fi
}

to_docker_host_path() {
  local p="${1:-}"
  if [ "${HOST_OS}" = "WIN" ]; then
    mixed_to_wsl_path "${p}"
  else
    echo "${p}"
  fi
}

# Execute a shell script via default WSL distro on Windows or directly via bash on native Linux
docker_host_exec() {
  local script_body="$1"
  if [ "${HOST_OS}" = "WIN" ]; then
    local wsl_bin="wsl"
    command -v wsl.exe &> /dev/null && wsl_bin="wsl.exe"
    printf '%s\n' "${script_body}" | MSYS_NO_PATHCONV=1 "${wsl_bin}" --cd / bash -s
  else
    printf '%s\n' "${script_body}" | bash -s
  fi
}

ensure_prereqs() {
  local missing_host=()
  local cmd
  for cmd in git mktemp awk grep sed; do
    command -v "${cmd}" &> /dev/null || missing_host+=("${cmd}")
  done

  if ! command -v sha256sum &> /dev/null && ! command -v shasum &> /dev/null && ! { [ "${HOST_OS}" = "WIN" ] && command -v certutil &> /dev/null; }; then
    missing_host+=("sha256sum|shasum|certutil")
  fi

  local context_label="native Linux"
  if [ "${HOST_OS}" = "WIN" ]; then
    context_label="default WSL distro"
    check_wsl_available || missing_host+=("wsl.exe")
    command -v cygpath &> /dev/null || missing_host+=("cygpath")
  fi

  if [ ${#missing_host[@]} -gt 0 ]; then
    log_error "Missing required host prerequisite(s): ${missing_host[*]}"
    exit "${EXIT_DEPENDENCY}"
  fi

  if [ "${DRY_RUN}" = true ]; then
    log_info "[DRY-RUN] Would verify Docker daemon access and archive tools via ${context_label}."
    return 0
  fi

  local req_docker_tools="docker tar find sed"
  [ "${DO_PACKAGE}" = true ] && [ "${TARGET_LINUX}" = true ] && req_docker_tools+=" xz"
  [ "${DO_PACKAGE}" = true ] && [ "${TARGET_WINDOWS}" = true ] && req_docker_tools+=" zip"

  local probe_out=""
  local rc=0
  probe_out="$(docker_host_exec "set -u; missing=''; for t in ${req_docker_tools}; do command -v \"\$t\" >/dev/null 2>&1 || missing=\"\${missing} \${t}\"; done; if [ -n \"\${missing}\" ]; then echo \"MISSING:\${missing# }\"; exit 10; fi; docker info >/dev/null 2>&1 || { echo 'DOCKER_DAEMON_DOWN'; exit 11; }" 2>&1)" || rc=$?

  if [ "${rc}" -ne 0 ]; then
    case "${probe_out}" in
      MISSING:*)
        log_error "Missing required tool(s) in ${context_label}: ${probe_out#MISSING:}"
        [ "${HOST_OS}" = "WIN" ] && [[ "${probe_out}" == *docker* ]] && log_info "Enable WSL integration for your default distro in Rancher Desktop / Docker Desktop (or set it with 'wsl --set-default <distro>')."
        ;;
      *DOCKER_DAEMON_DOWN*)
        log_error "Docker daemon is not reachable in ${context_label}."
        log_info "Ensure Docker / Rancher Desktop / dockerd is running and retry."
        ;;
      *)
        log_error "Prerequisite check failed in ${context_label} (exit=${rc}): ${probe_out}"
        ;;
    esac
    exit "${EXIT_DEPENDENCY}"
  fi
}

# ------------------------------------------------------------------------------
# Source Retrieval (Ephemeral Workspace, Latest 'master') & Checksums
# ------------------------------------------------------------------------------
# Resolve base temp directory cleanly ($TEMP -> $TMP -> $TMPDIR -> /tmp) for make_temp_dir
resolve_temp_base() {
  local raw="${TEMP:-${TMP:-${TMPDIR:-/tmp}}}"
  local posix_tmp
  posix_tmp="$(to_posix_path "${raw}")"
  if [ -d "${posix_tmp}" ] && [ -w "${posix_tmp}" ]; then
    echo "${posix_tmp%/}"
  else
    echo "/tmp"
  fi
}

prepare_source_repo() {
  local temp_base
  temp_base="$(resolve_temp_base)"
  TMPDIR="${temp_base}"
  export TMPDIR

  if [ "${DRY_RUN}" = true ]; then
    log_info "[DRY-RUN] Would create ephemeral workspace under ${temp_base} and clone latest '${GIT_BRANCH}' from ${REPO_URL}"
    DETECTED_VERSION="master"
    COMMIT_SHORT="<commit7>"
    return 0
  fi

  local work_root
  work_root="$(make_temp_dir "shellcheck_build")"
  TRACKED_TEMP_DIRS+=("${work_root}")
  CLONED_SRC_DIR="${work_root}/src"

  log_info "Cloning latest '${GIT_BRANCH}' from ${REPO_URL} into ${CLONED_SRC_DIR}..."
  git clone --depth 1 --branch "${GIT_BRANCH}" "${REPO_URL}" "${CLONED_SRC_DIR}"

  local cabal_ver
  cabal_ver="$(awk '/^[Vv][Ee][Rr][Ss][Ii][Oo][Nn]:[[:space:]]*/ {gsub(/\r/, "", $2); print $2; exit}' "${CLONED_SRC_DIR}/ShellCheck.cabal")"
  COMMIT_SHORT="$(git -C "${CLONED_SRC_DIR}" rev-parse --short=7 HEAD)"
  if [[ ! "${COMMIT_SHORT}" =~ ^[0-9a-f]{7}$ ]]; then
    log_error "Failed to resolve 7-character Git commit SHA in '${CLONED_SRC_DIR}'."
    exit "${EXIT_COMPILE}"
  fi
  DETECTED_VERSION="${cabal_ver:-master}"
  log_success "Source ready: version=${DETECTED_VERSION} commit=${COMMIT_SHORT} (${GIT_BRANCH})"
}

write_sha256_file() {
  local artifact="$1"
  local dir base hash
  dir="$(dirname "${artifact}")"
  base="$(basename "${artifact}")"

  if command -v sha256sum &> /dev/null; then
    (cd "${dir}" && sha256sum "${base}" > "${base}.sha256")
  elif command -v shasum &> /dev/null; then
    (cd "${dir}" && shasum -a 256 "${base}" > "${base}.sha256")
  elif [ "${HOST_OS}" = "WIN" ] && command -v certutil &> /dev/null; then
    local win_path
    win_path="$(cygpath -w "${artifact}")"
    hash="$(certutil -hashfile "${win_path}" SHA256 | tr -d '\r' | sed -n '2p' | tr -d '[:space:]')"
    printf '%s  %s\n' "${hash}" "${base}" > "${artifact}.sha256"
  else
    log_warn "No SHA256 tool found; skipping checksum for ${base}"
    return 0
  fi
  log_info "SHA256 written: ${artifact}.sha256"
}

# Resolve retired hardcoded curl.se/windows/dl-... URL in ephemeral clone if still broken upstream
patch_windows_dockerfile() {
  local dockerfile="$1"
  grep -qE 'https://curl\.se/windows/dl-[^"]+-win64-mingw\.zip' "${dockerfile}" || return 0

  local tmp_df="${dockerfile}.tmp"
  local line
  while IFS= read -r line || [ -n "${line}" ]; do
    if [[ "${line}" =~ ^RUN[[:space:]]+curl[[:space:]]+-L[[:space:]]+\"https://curl\.se/windows/dl-.*-win64-mingw\.zip\" ]]; then
      # shellcheck disable=SC2016 # Emit literal shell expansion into generated Dockerfile RUN instruction
      printf '%s\n' 'RUN curl_zip="$(curl -fsSL https://curl.se/windows/ | grep -oE '\''dl-[^"]+/curl-[^"]+-win64-mingw\.zip'\'' | head -n 1)" && test -n "${curl_zip}" && curl -fsSL "https://curl.se/windows/${curl_zip}" | busybox unzip - && mv curl-*-win64-mingw/bin/* .'
    else
      printf '%s\n' "${line}"
    fi
  done < "${dockerfile}" > "${tmp_df}"
  mv "${tmp_df}" "${dockerfile}"
  log_info "Patched ephemeral windows.x86_64 Dockerfile to resolve current curl-win64-mingw.zip URL."
}

# ------------------------------------------------------------------------------
# Unified Upstream Docker Builder (linux.x86_64 & windows.x86_64)
# ------------------------------------------------------------------------------
build_upstream_docker_target() {
  local upstream_target="$1"  # linux.x86_64 | windows.x86_64
  local bin_name="$2"         # Binary filename (.exe on Windows)
  local out_subdir="$3"       # linux-amd64 | windows-amd64

  local builder_dir="${CLONED_SRC_DIR}/builders/${upstream_target}"
  local out_target_dir="${OUT_DIR}/${out_subdir}"

  local image_tag="shellcheck-builder-${upstream_target,,}"
  local cache_opt=""
  [ "${NO_CACHE}" = true ] && cache_opt="--no-cache"

  if [ "${DRY_RUN}" = true ]; then
    log_info "[DRY-RUN] Would build upstream builder '${upstream_target}' via Docker -> ${out_target_dir}/${bin_name}"
    return 0
  fi

  mkdir -p "${out_target_dir}"

  if [ ! -f "${builder_dir}/Dockerfile" ]; then
    log_error "Upstream Dockerfile not found: ${builder_dir}/Dockerfile"
    exit "${EXIT_CONFIG}"
  fi
  if [ "${upstream_target}" = "windows.x86_64" ]; then
    patch_windows_dockerfile "${builder_dir}/Dockerfile"
  fi

  local stage_dir host_builder host_stage host_out
  stage_dir="$(make_temp_dir "sc_${out_subdir}")"
  TRACKED_TEMP_DIRS+=("${stage_dir}")
  git -C "${CLONED_SRC_DIR}" archive --format=tar.gz --prefix="shellcheck-${DETECTED_VERSION}/" HEAD > "${stage_dir}/src.tar.gz"

  host_builder="$(to_docker_host_path "${builder_dir}")"
  host_stage="$(to_docker_host_path "${stage_dir}")"
  host_out="$(to_docker_host_path "${out_target_dir}")"

  log_info "Building '${upstream_target}' (${DETECTED_VERSION}, commit ${COMMIT_SHORT}) via Docker..."
  local run_script
  read -r -d '' run_script << EOF || true
set -euo pipefail
docker build ${cache_opt} -t $(printf '%q' "${image_tag}") $(printf '%q' "${host_builder}")
docker run --rm -i $(printf '%q' "${image_tag}") < $(printf '%q' "${host_stage}/src.tar.gz") > $(printf '%q' "${host_stage}/out.tar.gz")
tar -xzf $(printf '%q' "${host_stage}/out.tar.gz") -C $(printf '%q' "${host_stage}")
found_bin=\$(find $(printf '%q' "${host_stage}") -maxdepth 3 -type f -name $(printf '%q' "${bin_name}") | sed -n '1p')
if [ -z "\$found_bin" ]; then
  echo "ERROR: Built '${bin_name}' not found in builder output archive." >&2
  exit 1
fi
mkdir -p $(printf '%q' "${host_out}")
cp "\$found_bin" $(printf '%q' "${host_out}/${bin_name}")
chmod 0755 $(printf '%q' "${host_out}/${bin_name}")
EOF

  if ! docker_host_exec "${run_script}"; then
    log_error "Docker build for '${upstream_target}' failed."
    exit "${EXIT_COMPILE}"
  fi

  verify_built_binary "${out_target_dir}/${bin_name}" "${host_out}/${bin_name}" "${bin_name}"
  write_sha256_file "${out_target_dir}/${bin_name}"
  log_success "Artifact ready: ${out_target_dir}/${bin_name}"
}

verify_built_binary() {
  local local_bin="$1"
  local docker_host_bin="$2"
  local bin_name="$3"

  if [ "${bin_name}" = "shellcheck" ]; then
    docker_host_exec "set -e; command -v file >/dev/null 2>&1 && file $(printf '%q' "${docker_host_bin}"); (command -v ldd >/dev/null 2>&1 && ldd $(printf '%q' "${docker_host_bin}") 2>&1 || true); $(printf '%q' "${docker_host_bin}") --version"
  else
    if [ "${HOST_OS}" = "WIN" ]; then
      "${local_bin}" --version
    else
      if command -v file &> /dev/null; then
        file "${local_bin}"
      fi
    fi
    if command -v objdump &> /dev/null; then
      local non_sys
      non_sys="$(objdump -p "${local_bin}" | awk '/DLL Name:/ {print $3}' | grep -iE 'libwinpthread|libgcc|libstdc\+\+|libgmp' || true)"
      if [ -n "${non_sys}" ]; then
        log_warn "Non-system DLL imports detected in ${bin_name}:"
        echo "${non_sys}" >&2
      fi
    fi
  fi
}

# ------------------------------------------------------------------------------
# Release Packaging (Includes Version + 7-char Commit SHA for Traceability)
# ------------------------------------------------------------------------------
# Package one built target directory and purge its unpacked directory once archived
package_single_target() {
  local out_subdir="$1"
  local archive_path="$2"
  local archive_kind="$3"
  local bin_name="$4"

  if [ "${DRY_RUN}" = true ]; then
    log_info "[DRY-RUN] Would package ${out_subdir}/${bin_name} -> ${archive_path} and purge ${OUT_DIR}/${out_subdir}"
    return 0
  fi

  local host_src host_dest archive_cmd
  host_src="$(to_docker_host_path "${OUT_DIR}/${out_subdir}")"
  host_dest="$(to_docker_host_path "${archive_path}")"
  case "${archive_kind}" in
    tar.xz) archive_cmd="rm -f $(printf '%q' "${host_dest}") && tar -C $(printf '%q' "${host_src}") -cJf $(printf '%q' "${host_dest}") $(printf '%q' "${bin_name}")" ;;
    zip)    archive_cmd="rm -f $(printf '%q' "${host_dest}") && (cd $(printf '%q' "${host_src}") && zip -q $(printf '%q' "${host_dest}") $(printf '%q' "${bin_name}"))" ;;
    *)      log_error "Unsupported archive format: ${archive_kind}"; exit "${EXIT_PACKAGE}" ;;
  esac

  docker_host_exec "${archive_cmd}"
  if [ ! -s "${archive_path}" ]; then
    log_error "Expected archive was not created or is empty: ${archive_path}"
    exit "${EXIT_PACKAGE}"
  fi

  write_sha256_file "${archive_path}"
  rm -rf "${OUT_DIR:?}/${out_subdir}"
  log_success "Packaged archive (unpacked ${out_subdir} purged): ${archive_path}"
}

package_outputs() {
  [ "${DO_PACKAGE}" = false ] && return 0

  local ver_tag="${DETECTED_VERSION}"
  [[ "${ver_tag}" =~ ^[0-9] ]] && ver_tag="v${ver_tag}"
  local trace_tag="${ver_tag}-${COMMIT_SHORT}"

  if [ "${TARGET_LINUX}" = true ]; then
    package_single_target "linux-amd64" "${OUT_DIR}/shellcheck-${trace_tag}-linux-amd64-static.tar.xz" "tar.xz" "shellcheck"
  fi

  if [ "${TARGET_WINDOWS}" = true ]; then
    package_single_target "windows-amd64" "${OUT_DIR}/shellcheck-${trace_tag}-windows-amd64.zip" "zip" "shellcheck.exe"
  fi
}

# ------------------------------------------------------------------------------
# Main Entry Point
# ------------------------------------------------------------------------------
main() {
  parse_args "$@"

  OUT_DIR="$(to_posix_path "${OUT_DIR}")"
  ensure_prereqs

  if [ "${DRY_RUN}" = false ]; then
    mkdir -p "${OUT_DIR}"
  fi
  prepare_source_repo

  if [ "${TARGET_LINUX}" = true ]; then
    build_upstream_docker_target "linux.x86_64" "shellcheck" "linux-amd64"
  fi

  if [ "${TARGET_WINDOWS}" = true ]; then
    build_upstream_docker_target "windows.x86_64" "shellcheck.exe" "windows-amd64"
  fi

  package_outputs
  log_success "ShellCheck build pipeline completed (version=${DETECTED_VERSION}, commit=${COMMIT_SHORT}, output=${OUT_DIR})."
}

main "$@"
