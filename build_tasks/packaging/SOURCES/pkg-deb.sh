#!/bin/bash
# ==============================================================================
# Script:      /usr/src/packages/TEMPLATE/SOURCES/pkg-deb.sh
# Purpose:     Standalone, self-cleaning Debian (.deb) binary package builder.
# Applicability: Supports Rust, Go, and C/C++ packages (CLIs and daemon services).
#
# Objectives:
#   Produce deterministic, Debian-Policy-conscious .deb archives directly from
#   RPM staging artifacts without requiring debhelper/dpkg-buildpackage on EL hosts.
#
# Core Components:
#   - Section 1 (CLI Parser & Defaults)    : Parses metadata, payload, hook & lint flags; reads MAINTAINER from pkg-common.inc.
#   - Section 2 (Validation & Staging)     : Normalizes Debian arch; creates mktemp staging tree with cleanup trap.
#   - Section 3 (Payload Assembly)         : Installs dirs, binaries, conffiles, data, systemd assets, completions, man, docs, changelogs.
#   - Section 4 (Hooks, Control & md5sums) : Generates default systemd maintainer scripts, computes Installed-Size & DEBIAN/{control,conffiles,md5sums}.
#   - Section 5 (.deb Build & Lintian)     : Invokes `dpkg-deb --build --root-owner-group` and delegates QA to pkg-verify.sh / lintian.
#
# Functionality & Data Flows:
#   1. Parses CLI flags -> validates required fields (`--name`, `--version`, `--arch`, `--out`).
#   2. Copies payload into isolated mktemp staging tree with canonical modes, gzip -9n compression,
#      and LICENSE -> copyright mapping.
#   3. Writes DEBIAN/{control,conffiles,postinst,prerm,postrm,md5sums} -> packs .deb -> runs lintian.
#
# Synopsis:
#   pkg-deb.sh --name <pkg> --version <ver> --arch <arch> --out <pkg.deb> [OPTIONS]
#
# Metadata Options:
#   --name <name>            : Package name (e.g. broot, sftpgo, caddy)
#   --version <ver>          : Semantic version + release (e.g. 1.0.0-1.el.xg)
#   --arch <arch>            : Architecture (auto-normalizes x86_64->amd64, etc.)
#   --maintainer <maint>     : Maintainer email/name (RFC 822 format)
#   --summary <short_desc>   : One-line summary
#   --desc <long_desc>       : Multi-line description (indented automatically)
#   --homepage <url>         : Upstream project homepage
#   --section <section>      : Debian archive section (default: utils, net, httpd)
#   --priority <priority>    : Priority (default: optional)
#   --depends <pkgs>         : Package dependencies (e.g. ca-certificates)
#   --recommends <pkgs>      : Recommended packages
#   --suggests <pkgs>        : Suggested packages
#   --provides <pkgs>        : Virtual packages provided
#   --conflicts <pkgs>       : Conflicting packages
#   --replaces <pkgs>        : Packages replaced by this package
#   --out <file.deb>         : Output destination path for the .deb file
#
# Payload Installation Options:
#   --bin <src>[:<dest>]     : Installs binary or binary dir (dest default: usr/bin/)
#   --conffile <src>[:<dst>[:<m>]]: Installs config (with mode) & registers in conffiles
#   --dir <path>[:<mode>]    : Creates empty directory with mode (default: 0755)
#   --doc <file...>          : Installs documentation to usr/share/doc/<name>/
#   --changelog <file>       : Compresses and installs changelog to doc dir
#   --data <src>:<dest>      : Installs arbitrary file or directory recursively
#   --service <file>         : Installs systemd unit to usr/lib/systemd/system/
#   --sysusers <file>        : Installs sysusers config to usr/lib/sysusers.d/
#   --tmpfiles <file>        : Installs tmpfiles config to usr/lib/tmpfiles.d/
#   --completion-bash <file> : Installs bash completion
#   --completion-zsh <file>  : Installs zsh completion
#   --completion-fish <file> : Installs fish completion
#   --man <file...>          : Installs man pages into usr/share/man/man<sec>/
#
# Maintainer Lifecycle Scripts:
#   --preinst <script>       : Pre-installation hook script (mode 0755)
#   --postinst <script>      : Post-installation hook script (mode 0755)
#   --prerm <script>         : Pre-removal hook script (mode 0755)
#   --postrm <script>        : Post-removal hook script (mode 0755)
#
# Lintian Verification Options:
#   --lintian                : Fail if lintian reports policy violations or is missing
#   --no-lintian             : Skip automatic post-build lintian execution
#   --lintian-suppress <tags>: Comma-separated lintian tags to suppress
#   * Note: By default, lintian runs in advisory mode when installed.
#   * Note: If systemd units, sysusers, or tmpfiles are installed and no hooks
#     are given, safe default daemon-reload, sysusers, and tmpfiles hooks are generated.
# ==============================================================================
set -eo pipefail

# ------------------------------------------------------------------------------
# 1. Defaults & CLI Argument Parsing
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
NAME=""
VERSION=""
ARCH=""
MAINTAINER=""
# Synchronize default Maintainer metadata from shared pkg-common.inc when co-located
if [ -f "${SCRIPT_DIR}/pkg-common.inc" ]; then
  MAINTAINER="$(awk '/^%global[[:space:]]+maintainer[[:space:]]+/{sub(/^%global[[:space:]]+maintainer[[:space:]]+/,""); print; exit}' "${SCRIPT_DIR}/pkg-common.inc")"
fi
MAINTAINER="${MAINTAINER:-Mis Center <support@criticalsys.net>}"
SUMMARY=""
DESC=""
HOMEPAGE=""
SECTION="utils"
PRIORITY="optional"
OUTPUT=""
DEPENDS=""
RECOMMENDS=""
SUGGESTS=""
PROVIDES=""
CONFLICTS=""
REPLACES=""
CHANGELOG=""
PREINST=""
POSTINST=""
PRERM=""
POSTRM=""
LINTIAN_MODE="auto"
LINTIAN_SUPPRESS=""

BINARIES=()
CONFFILES=()
DIRS=()
DOCS=()
DATA_ITEMS=()
SERVICES=()
SYSUSERS=()
TMPFILES=()
COMPLETIONS_BASH=()
COMPLETIONS_ZSH=()
COMPLETIONS_FISH=()
MANPAGES=()

# Argument Parsing
while [ $# -gt 0 ]; do
  case "$1" in
    --name)
      NAME="$2"
      shift 2
      ;;
    --version)
      VERSION="$2"
      shift 2
      ;;
    --arch)
      ARCH="$2"
      shift 2
      ;;
    --maintainer)
      MAINTAINER="$2"
      shift 2
      ;;
    --summary)
      SUMMARY="$2"
      shift 2
      ;;
    --desc)
      DESC="$2"
      shift 2
      ;;
    --homepage)
      HOMEPAGE="$2"
      shift 2
      ;;
    --section)
      SECTION="$2"
      shift 2
      ;;
    --priority)
      PRIORITY="$2"
      shift 2
      ;;
    --depends)
      DEPENDS="${DEPENDS:+${DEPENDS}, }$2"
      shift 2
      ;;
    --recommends)
      RECOMMENDS="${RECOMMENDS:+${RECOMMENDS}, }$2"
      shift 2
      ;;
    --suggests)
      SUGGESTS="${SUGGESTS:+${SUGGESTS}, }$2"
      shift 2
      ;;
    --provides)
      PROVIDES="${PROVIDES:+${PROVIDES}, }$2"
      shift 2
      ;;
    --conflicts)
      CONFLICTS="${CONFLICTS:+${CONFLICTS}, }$2"
      shift 2
      ;;
    --replaces)
      REPLACES="${REPLACES:+${REPLACES}, }$2"
      shift 2
      ;;
    --changelog)
      CHANGELOG="$2"
      shift 2
      ;;
    --preinst)
      PREINST="$2"
      shift 2
      ;;
    --postinst)
      POSTINST="$2"
      shift 2
      ;;
    --prerm)
      PRERM="$2"
      shift 2
      ;;
    --postrm)
      POSTRM="$2"
      shift 2
      ;;
    --lintian)
      LINTIAN_MODE="strict"
      shift
      ;;
    --no-lintian)
      LINTIAN_MODE="off"
      shift
      ;;
    --lintian-suppress)
      LINTIAN_SUPPRESS="${LINTIAN_SUPPRESS:+${LINTIAN_SUPPRESS},}$2"
      shift 2
      ;;
    --out)
      OUTPUT="$2"
      shift 2
      ;;
    --bin)
      shift
      while [ $# -gt 0 ] && [[ "$1" != --* ]]; do
        for item in $1; do BINARIES+=("$item"); done
        shift
      done
      ;;
    --conffile)
      shift
      while [ $# -gt 0 ] && [[ "$1" != --* ]]; do
        for item in $1; do CONFFILES+=("$item"); done
        shift
      done
      ;;
    --doc)
      shift
      while [ $# -gt 0 ] && [[ "$1" != --* ]]; do
        for item in $1; do DOCS+=("$item"); done
        shift
      done
      ;;
    --data)
      shift
      while [ $# -gt 0 ] && [[ "$1" != --* ]]; do
        for item in $1; do DATA_ITEMS+=("$item"); done
        shift
      done
      ;;
    --service)
      shift
      while [ $# -gt 0 ] && [[ "$1" != --* ]]; do
        for item in $1; do SERVICES+=("$item"); done
        shift
      done
      ;;
    --sysusers)
      shift
      while [ $# -gt 0 ] && [[ "$1" != --* ]]; do
        for item in $1; do SYSUSERS+=("$item"); done
        shift
      done
      ;;
    --tmpfiles)
      shift
      while [ $# -gt 0 ] && [[ "$1" != --* ]]; do
        for item in $1; do TMPFILES+=("$item"); done
        shift
      done
      ;;
    --completion-bash)
      shift
      while [ $# -gt 0 ] && [[ "$1" != --* ]]; do
        for item in $1; do COMPLETIONS_BASH+=("$item"); done
        shift
      done
      ;;
    --completion-zsh)
      shift
      while [ $# -gt 0 ] && [[ "$1" != --* ]]; do
        for item in $1; do COMPLETIONS_ZSH+=("$item"); done
        shift
      done
      ;;
    --completion-fish)
      shift
      while [ $# -gt 0 ] && [[ "$1" != --* ]]; do
        for item in $1; do COMPLETIONS_FISH+=("$item"); done
        shift
      done
      ;;
    --man)
      shift
      while [ $# -gt 0 ] && [[ "$1" != --* ]]; do
        for item in $1; do MANPAGES+=("$item"); done
        shift
      done
      ;;
    --dir)
      shift
      while [ $# -gt 0 ] && [[ "$1" != --* ]]; do
        for item in $1; do DIRS+=("$item"); done
        shift
      done
      ;;
    *)
      echo "ERROR: Unknown parameter: $1" >&2
      exit 1
      ;;
  esac
done

# ------------------------------------------------------------------------------
# 2. Validation, Architecture Normalization & Staging Directory Setup
# ------------------------------------------------------------------------------
# Basic Validation
if [ -z "$NAME" ] || [ -z "$VERSION" ] || [ -z "$ARCH" ] || [ -z "$OUTPUT" ]; then
  echo "Usage: $(basename "$0") --name <name> --version <ver> --arch <arch> --out <file.deb> [options]" >&2
  exit 1
fi

if ! command -v dpkg-deb > /dev/null 2>&1; then
  echo "ERROR: dpkg-deb not found in PATH. Please install dpkg (BuildRequires: dpkg)." >&2
  exit 1
fi

# Normalize architecture to Debian canonical strings
case "$ARCH" in
  x86_64) ARCH="amd64" ;;
  aarch64) ARCH="arm64" ;;
  i[3-6]86) ARCH="i386" ;;
  armv7*) ARCH="armhf" ;;
  ppc64le) ARCH="ppc64el" ;;
  s390x) ARCH="s390x" ;;
  riscv64) ARCH="riscv64" ;;
esac

# Create isolated staging environment and ensure safe cleanup on exit
STAGING_DIR="$(mktemp -d -t "deb_staging_${NAME}_XXXXXX")"
# Safely remove the temporary staging directory on script exit
cleanup_staging_dir() {
  if [ -n "${STAGING_DIR:-}" ] && [ "${STAGING_DIR}" != "/" ] && [ -d "${STAGING_DIR}" ]; then
    rm -rf -- "${STAGING_DIR}"
  fi
}
trap cleanup_staging_dir EXIT

mkdir -p "${STAGING_DIR}/DEBIAN" \
  "${STAGING_DIR}/usr/share/doc/${NAME}"
chmod 0755 "${STAGING_DIR}" "${STAGING_DIR}/DEBIAN"

# ------------------------------------------------------------------------------
# 3. Payload Installation (Dirs, Binaries, Configs, Systemd, Docs)
# ------------------------------------------------------------------------------

# 1. Create explicitly specified empty directories
for d in "${DIRS[@]}"; do
  if [[ "$d" == *:* ]]; then
    path="${d%%:*}"
    mode="${d#*:}"
  else
    path="$d"
    mode="0755"
  fi
  path_rel="${path#/}"
  mkdir -p "${STAGING_DIR}/${path_rel}"
  chmod "$mode" "${STAGING_DIR}/${path_rel}"
done

# 2. Install binaries
for b in "${BINARIES[@]}"; do
  if [[ "$b" == *:* ]]; then
    src="${b%%:*}"
    dest="${b#*:}"
    dest_rel="${dest#/}"
    if [ -d "$src" ]; then
      mkdir -p "${STAGING_DIR}/${dest_rel}"
      cp -af "${src}/." "${STAGING_DIR}/${dest_rel}/"
      find "${STAGING_DIR}/${dest_rel}" -type f -exec chmod 0755 {} +
    elif [ -f "$src" ]; then
      if [[ "$dest" == */ ]] || [ -d "${STAGING_DIR}/${dest_rel}" ]; then
        mkdir -p "${STAGING_DIR}/${dest_rel}"
        cp -af "$src" "${STAGING_DIR}/${dest_rel}/"
        chmod 0755 "${STAGING_DIR}/${dest_rel}/$(basename "$src")"
      else
        mkdir -p "$(dirname "${STAGING_DIR}/${dest_rel}")"
        cp -af "$src" "${STAGING_DIR}/${dest_rel}"
        chmod 0755 "${STAGING_DIR}/${dest_rel}"
      fi
    else
      echo "ERROR: Binary '$src' does not exist." >&2
      exit 1
    fi
  else
    if [ -f "$b" ]; then
      mkdir -p "${STAGING_DIR}/usr/bin"
      cp -af "$b" "${STAGING_DIR}/usr/bin/"
      chmod 0755 "${STAGING_DIR}/usr/bin/$(basename "$b")"
    else
      echo "ERROR: Binary '$b' does not exist." >&2
      exit 1
    fi
  fi
done

# 3. Install configuration files (registered in DEBIAN/conffiles)
CONFFILES_LIST=()
for c in "${CONFFILES[@]}"; do
  mode="0644"
  IFS=':' read -r -a parts <<< "$c"
  if [ ${#parts[@]} -ge 3 ]; then
    src="${parts[0]}"
    dest="${parts[1]}"
    mode="${parts[2]}"
  elif [ ${#parts[@]} -eq 2 ]; then
    src="${parts[0]}"
    dest="${parts[1]}"
  else
    src="$c"
    if [[ "$c" == /* ]]; then
      dest="$c"
    else
      dest="/etc/${NAME}/$(basename "$c")"
    fi
  fi
  dest_rel="${dest#/}"
  if [ -f "$src" ]; then
    mkdir -p "$(dirname "${STAGING_DIR}/${dest_rel}")"
    cp -af "$src" "${STAGING_DIR}/${dest_rel}"
    chmod "$mode" "${STAGING_DIR}/${dest_rel}"
    CONFFILES_LIST+=("/${dest_rel}")
  else
    echo "ERROR: Conffile '$src' not found!" >&2
    exit 1
  fi
done

# 4. Install arbitrary data files and directory trees
for d in "${DATA_ITEMS[@]}"; do
  if [[ "$d" == *:* ]]; then
    src="${d%%:*}"
    dest="${d#*:}"
    dest_rel="${dest#/}"
    if [ -d "$src" ]; then
      mkdir -p "${STAGING_DIR}/${dest_rel}"
      cp -af "${src}/." "${STAGING_DIR}/${dest_rel}/"
      find "${STAGING_DIR}/${dest_rel}" -type d -exec chmod 0755 {} +
      find "${STAGING_DIR}/${dest_rel}" -type f ! -perm /0111 -exec chmod 0644 {} +
      find "${STAGING_DIR}/${dest_rel}" -type f -perm /0111 -exec chmod 0755 {} +
    elif [ -f "$src" ]; then
      mkdir -p "$(dirname "${STAGING_DIR}/${dest_rel}")"
      cp -af "$src" "${STAGING_DIR}/${dest_rel}"
      if [ -x "$src" ]; then
        chmod 0755 "${STAGING_DIR}/${dest_rel}"
      else
        chmod 0644 "${STAGING_DIR}/${dest_rel}"
      fi
    else
      echo "ERROR: Data source '$src' not found!" >&2
      exit 1
    fi
  else
    echo "ERROR: Data item '$d' missing destination (format: src:dest)!" >&2
    exit 1
  fi
done

# 4b. Install systemd services
for s in "${SERVICES[@]}"; do
  if [[ "$s" == *:* ]]; then
    src="${s%%:*}"
    dest="${s#*:}"
    dest_rel="${dest#/}"
  else
    src="$s"
    dest_rel="usr/lib/systemd/system/$(basename "$s")"
  fi
  if [ -f "$src" ]; then
    mkdir -p "$(dirname "${STAGING_DIR}/${dest_rel}")"
    cp -af "$src" "${STAGING_DIR}/${dest_rel}"
    chmod 0644 "${STAGING_DIR}/${dest_rel}"
  else
    echo "ERROR: Service file '$src' not found!" >&2
    exit 1
  fi
done

# 5. Install systemd sysusers
for u in "${SYSUSERS[@]}"; do
  if [[ "$u" == *:* ]]; then
    src="${u%%:*}"
    dest="${u#*:}"
    dest_rel="${dest#/}"
  else
    src="$u"
    base_u="$(basename "$u")"
    [[ "$base_u" == *.sysusers.conf ]] && base_u="${NAME}.conf"
    dest_rel="usr/lib/sysusers.d/${base_u}"
  fi
  if [ -f "$src" ]; then
    mkdir -p "$(dirname "${STAGING_DIR}/${dest_rel}")"
    cp -af "$src" "${STAGING_DIR}/${dest_rel}"
    chmod 0644 "${STAGING_DIR}/${dest_rel}"
  else
    echo "ERROR: Sysusers file '$src' not found!" >&2
    exit 1
  fi
done

# 6. Install systemd tmpfiles
for t in "${TMPFILES[@]}"; do
  if [[ "$t" == *:* ]]; then
    src="${t%%:*}"
    dest="${t#*:}"
    dest_rel="${dest#/}"
  else
    src="$t"
    base_t="$(basename "$t")"
    [[ "$base_t" == *.tmpfiles.conf ]] && base_t="${NAME}.conf"
    dest_rel="usr/lib/tmpfiles.d/${base_t}"
  fi
  if [ -f "$src" ]; then
    mkdir -p "$(dirname "${STAGING_DIR}/${dest_rel}")"
    cp -af "$src" "${STAGING_DIR}/${dest_rel}"
    chmod 0644 "${STAGING_DIR}/${dest_rel}"
  else
    echo "ERROR: Tmpfiles file '$src' not found!" >&2
    exit 1
  fi
done

# 7. Install shell completions
for cb in "${COMPLETIONS_BASH[@]}"; do
  if [[ "$cb" == *:* ]]; then
    src="${cb%%:*}"
    dest="${cb#*:}"
    dest_rel="${dest#/}"
  else
    src="$cb"
    dest_rel="usr/share/bash-completion/completions/${NAME}"
  fi
  if [ -f "$src" ]; then
    mkdir -p "$(dirname "${STAGING_DIR}/${dest_rel}")"
    cp -af "$src" "${STAGING_DIR}/${dest_rel}"
    chmod 0644 "${STAGING_DIR}/${dest_rel}"
  fi
done

for cz in "${COMPLETIONS_ZSH[@]}"; do
  if [[ "$cz" == *:* ]]; then
    src="${cz%%:*}"
    dest="${cz#*:}"
    dest_rel="${dest#/}"
  else
    src="$cz"
    dest_rel="usr/share/zsh/vendor-completions/_${NAME}"
  fi
  if [ -f "$src" ]; then
    mkdir -p "$(dirname "${STAGING_DIR}/${dest_rel}")"
    cp -af "$src" "${STAGING_DIR}/${dest_rel}"
    chmod 0644 "${STAGING_DIR}/${dest_rel}"
  fi
done

for cf in "${COMPLETIONS_FISH[@]}"; do
  if [[ "$cf" == *:* ]]; then
    src="${cf%%:*}"
    dest="${cf#*:}"
    dest_rel="${dest#/}"
  else
    src="$cf"
    dest_rel="usr/share/fish/vendor_completions.d/${NAME}.fish"
  fi
  if [ -f "$src" ]; then
    mkdir -p "$(dirname "${STAGING_DIR}/${dest_rel}")"
    cp -af "$src" "${STAGING_DIR}/${dest_rel}"
    chmod 0644 "${STAGING_DIR}/${dest_rel}"
  fi
done

# 8. Install man pages (with standard gzip -9n compression)
for m in "${MANPAGES[@]}"; do
  if [ -f "$m" ]; then
    base="$(basename "$m")"
    if [[ "$base" == *.gz ]]; then
      uncompressed="${base%.gz}"
      sec="${uncompressed##*.}"
      if [[ ! "$sec" =~ ^[1-8]$ ]]; then
        sec="1"
      fi
      mandir="usr/share/man/man${sec}"
      mkdir -p "${STAGING_DIR}/${mandir}"
      cp -af "$m" "${STAGING_DIR}/${mandir}/${base}"
      chmod 0644 "${STAGING_DIR}/${mandir}/${base}"
    else
      sec="${base##*.}"
      if [[ ! "$sec" =~ ^[1-8]$ ]]; then
        sec="1"
      fi
      mandir="usr/share/man/man${sec}"
      mkdir -p "${STAGING_DIR}/${mandir}"
      cp -af "$m" "${STAGING_DIR}/${mandir}/${base}"
      gzip -9n -f "${STAGING_DIR}/${mandir}/${base}"
      chmod 0644 "${STAGING_DIR}/${mandir}/${base}.gz"
    fi
  fi
done

# 9. Install documentation (map LICENSE/COPYING -> copyright per Debian Policy §12.5)
HAS_COPYRIGHT=0
for d in "${DOCS[@]}"; do
  [ "$(basename "$d")" = "copyright" ] && HAS_COPYRIGHT=1
done
for d in "${DOCS[@]}"; do
  if [ -f "$d" ]; then
    base_d="$(basename "$d")"
    if [ "$HAS_COPYRIGHT" -eq 0 ] && [[ "$base_d" =~ ^(LICENSE|COPYING)(\..*)?$ ]]; then
      cp -af "$d" "${STAGING_DIR}/usr/share/doc/${NAME}/copyright"
      chmod 0644 "${STAGING_DIR}/usr/share/doc/${NAME}/copyright"
      HAS_COPYRIGHT=1
    else
      cp -af "$d" "${STAGING_DIR}/usr/share/doc/${NAME}/"
      chmod 0644 "${STAGING_DIR}/usr/share/doc/${NAME}/${base_d}"
    fi
  fi
done

# 10. Install changelog files
if [ -n "$CHANGELOG" ] && [ -f "$CHANGELOG" ]; then
  cp -af "$CHANGELOG" "${STAGING_DIR}/usr/share/doc/${NAME}/changelog"
  gzip -9n -f "${STAGING_DIR}/usr/share/doc/${NAME}/changelog"
  chmod 0644 "${STAGING_DIR}/usr/share/doc/${NAME}/changelog.gz"
fi

DEB_DATE="$(LC_ALL=C date -R -d "@${SOURCE_DATE_EPOCH:-$(date +%s)}" 2>/dev/null || LC_ALL=C date -R)"
cat << EOF > "${STAGING_DIR}/usr/share/doc/${NAME}/changelog.Debian"
${NAME} (${VERSION}) stable; urgency=medium

  * Packages updated to latest upstream release

 -- ${MAINTAINER}  ${DEB_DATE}
EOF
gzip -9n -f "${STAGING_DIR}/usr/share/doc/${NAME}/changelog.Debian"
chmod 0644 "${STAGING_DIR}/usr/share/doc/${NAME}/changelog.Debian.gz"

# ------------------------------------------------------------------------------
# 4. Maintainer Hooks, DEBIAN Control Metadata & Permission Normalization
# ------------------------------------------------------------------------------
# 11. Install maintainer scripts (or auto-generate systemd lifecycle hooks if needed)
[ -n "$PREINST" ] && [ -f "$PREINST" ] && cp -af "$PREINST" "${STAGING_DIR}/DEBIAN/preinst" && chmod 0755 "${STAGING_DIR}/DEBIAN/preinst"
[ -n "$POSTINST" ] && [ -f "$POSTINST" ] && cp -af "$POSTINST" "${STAGING_DIR}/DEBIAN/postinst" && chmod 0755 "${STAGING_DIR}/DEBIAN/postinst"
[ -n "$PRERM" ] && [ -f "$PRERM" ] && cp -af "$PRERM" "${STAGING_DIR}/DEBIAN/prerm" && chmod 0755 "${STAGING_DIR}/DEBIAN/prerm"
[ -n "$POSTRM" ] && [ -f "$POSTRM" ] && cp -af "$POSTRM" "${STAGING_DIR}/DEBIAN/postrm" && chmod 0755 "${STAGING_DIR}/DEBIAN/postrm"

# Single-quote-escape helper for safely emitting literal values into generated POSIX sh hooks
_deb_sq() {
  printf '%s' "${1//\'/\'\\\'\'}"
}

# Emit POSIX /bin/sh user/group creation fallback lines from a sysusers.d(5) config
_deb_emit_sysusers_fallback() {
  local conf_file="$1"
  local raw_line="" s_type="" s_name="" s_id="" s_rest="" s_gecos="" s_home="" s_shell=""
  while IFS= read -r raw_line || [ -n "$raw_line" ]; do
    raw_line="${raw_line#"${raw_line%%[![:space:]]*}"}"
    case "$raw_line" in
      ""|\#*) continue ;;
    esac
    read -r s_type s_name s_id s_rest <<< "$raw_line"
    { [ -n "$s_type" ] && [ -n "$s_name" ]; } || continue
    : "$s_id"
    case "$s_type" in
      g)
        printf "        getent group '%s' >/dev/null 2>&1 || groupadd -r '%s' >/dev/null 2>&1 || :\n" \
          "$(_deb_sq "$s_name")" "$(_deb_sq "$s_name")"
        ;;
      u)
        s_gecos=""
        s_home=""
        s_shell=""
        s_rest="${s_rest#"${s_rest%%[![:space:]]*}"}"
        if [[ "$s_rest" == \"*\"* ]]; then
          s_rest="${s_rest#\"}"
          s_gecos="${s_rest%%\"*}"
          s_rest="${s_rest#*\"}"
          read -r s_home s_shell _ <<< "$s_rest"
        else
          read -r s_gecos s_home s_shell _ <<< "$s_rest"
        fi
        [ "$s_gecos" = "-" ] && s_gecos=""
        { [ -z "$s_home" ] || [ "$s_home" = "-" ]; } && s_home="/nonexistent"
        printf "        getent group '%s' >/dev/null 2>&1 || groupadd -r '%s' >/dev/null 2>&1 || :\n" \
          "$(_deb_sq "$s_name")" "$(_deb_sq "$s_name")"
        printf "        if ! getent passwd '%s' >/dev/null 2>&1; then\n" "$(_deb_sq "$s_name")"
        if [ -z "$s_shell" ] || [ "$s_shell" = "-" ]; then
          printf "            _nologin=/usr/sbin/nologin; [ -x \"\$_nologin\" ] || _nologin=/sbin/nologin\n"
        else
          printf "            _nologin='%s'\n" "$(_deb_sq "$s_shell")"
        fi
        printf "            useradd -r -g '%s' -d '%s' -s \"\$_nologin\" -c '%s' '%s' >/dev/null 2>&1 || :\n" \
          "$(_deb_sq "$s_name")" "$(_deb_sq "$s_home")" "$(_deb_sq "$s_gecos")" "$(_deb_sq "$s_name")"
        printf "        fi\n"
        ;;
    esac
  done < "$conf_file"
}

# Emit POSIX /bin/sh directory and permission fallback lines from a tmpfiles.d(5) config
_deb_emit_tmpfiles_fallback() {
  local conf_file="$1"
  local raw_line="" t_type="" t_path="" t_mode="" t_user="" t_group="" _rest=""
  while IFS= read -r raw_line || [ -n "$raw_line" ]; do
    raw_line="${raw_line#"${raw_line%%[![:space:]]*}"}"
    case "$raw_line" in
      ""|\#*) continue ;;
    esac
    read -r t_type t_path t_mode t_user t_group _rest <<< "$raw_line"
    { [ -n "$t_type" ] && [ -n "$t_path" ]; } || continue
    : "$_rest"
    case "$t_type" in
      d)
        { [ -z "$t_mode" ] || [ "$t_mode" = "-" ]; } && t_mode="0755"
        { [ -z "$t_user" ] || [ "$t_user" = "-" ]; } && t_user="root"
        { [ -z "$t_group" ] || [ "$t_group" = "-" ]; } && t_group="root"
        printf "        install -d -m '%s' -o '%s' -g '%s' '%s' >/dev/null 2>&1 || :\n" \
          "$(_deb_sq "$t_mode")" "$(_deb_sq "$t_user")" "$(_deb_sq "$t_group")" "$(_deb_sq "$t_path")"
        ;;
      z)
        printf "        if [ -e '%s' ]; then\n" "$(_deb_sq "$t_path")"
        if [ -n "$t_user" ] && [ "$t_user" != "-" ] && [ -n "$t_group" ] && [ "$t_group" != "-" ]; then
          printf "            chown '%s:%s' '%s' >/dev/null 2>&1 || :\n" \
            "$(_deb_sq "$t_user")" "$(_deb_sq "$t_group")" "$(_deb_sq "$t_path")"
        elif [ -n "$t_user" ] && [ "$t_user" != "-" ]; then
          printf "            chown '%s' '%s' >/dev/null 2>&1 || :\n" \
            "$(_deb_sq "$t_user")" "$(_deb_sq "$t_path")"
        elif [ -n "$t_group" ] && [ "$t_group" != "-" ]; then
          printf "            chgrp '%s' '%s' >/dev/null 2>&1 || :\n" \
            "$(_deb_sq "$t_group")" "$(_deb_sq "$t_path")"
        fi
        if [ -n "$t_mode" ] && [ "$t_mode" != "-" ]; then
          printf "            chmod '%s' '%s' >/dev/null 2>&1 || :\n" \
            "$(_deb_sq "$t_mode")" "$(_deb_sq "$t_path")"
        fi
        printf "        fi\n"
        ;;
    esac
  done < "$conf_file"
}

# If systemd services, sysusers, or tmpfiles are included but no explicit postinst was provided, generate safe hooks
# Guards sysusers, tmpfiles, and service actions inside dpkg "$1 = configure" with explicit new-install (-z "$2") vs upgrade (-n "$2") paths
if [ ! -f "${STAGING_DIR}/DEBIAN/postinst" ] && { [ ${#SERVICES[@]} -gt 0 ] || [ ${#SYSUSERS[@]} -gt 0 ] || [ ${#TMPFILES[@]} -gt 0 ]; }; then
  cat << 'EOF' > "${STAGING_DIR}/DEBIAN/postinst"
#!/bin/sh
set -e
if [ "$1" = "configure" ]; then
EOF
  for u in "${SYSUSERS[@]}"; do
    if [[ "$u" == *:* ]]; then
      u_src="${u%%:*}"
      u_installed="$(basename "${u#*:}")"
    else
      u_src="$u"
      u_installed="$(basename "$u")"
      [[ "$u_installed" == *.sysusers.conf ]] && u_installed="${NAME}.conf"
    fi
    _u_fallback="$(_deb_emit_sysusers_fallback "$u_src")"
    cat << EOF >> "${STAGING_DIR}/DEBIAN/postinst"
    # Create dedicated system user/group idempotently (with fallback when systemd-sysusers is absent)
    if command -v systemd-sysusers >/dev/null 2>&1; then
        systemd-sysusers "${u_installed}" >/dev/null 2>&1 || :
EOF
    if [ -n "$_u_fallback" ]; then
      printf "    else\n%s\n" "$_u_fallback" >> "${STAGING_DIR}/DEBIAN/postinst"
    fi
    echo "    fi" >> "${STAGING_DIR}/DEBIAN/postinst"
  done
  for t in "${TMPFILES[@]}"; do
    if [[ "$t" == *:* ]]; then
      t_src="${t%%:*}"
      t_installed="$(basename "${t#*:}")"
    else
      t_src="$t"
      t_installed="$(basename "$t")"
      [[ "$t_installed" == *.tmpfiles.conf ]] && t_installed="${NAME}.conf"
    fi
    _t_fallback="$(_deb_emit_tmpfiles_fallback "$t_src")"
    cat << EOF >> "${STAGING_DIR}/DEBIAN/postinst"
    # Ensure runtime dirs exist and enforce safe permissions without modifying config/data contents
    if command -v systemd-tmpfiles >/dev/null 2>&1; then
        systemd-tmpfiles --create "${t_installed}" >/dev/null 2>&1 || :
EOF
    if [ -n "$_t_fallback" ]; then
      printf "    else\n%s\n" "$_t_fallback" >> "${STAGING_DIR}/DEBIAN/postinst"
    fi
    echo "    fi" >> "${STAGING_DIR}/DEBIAN/postinst"
  done
  if [ ${#SERVICES[@]} -gt 0 ]; then
    cat << 'EOF' >> "${STAGING_DIR}/DEBIAN/postinst"
    if [ -d /run/systemd/system ]; then
        systemctl daemon-reload >/dev/null 2>&1 || :
EOF
    for s in "${SERVICES[@]}"; do
      if [[ "$s" == *:* ]]; then
        s_installed="$(basename "${s#*:}")"
      else
        s_installed="$(basename "$s")"
      fi
      cat << EOF >> "${STAGING_DIR}/DEBIAN/postinst"
        # Fresh install (-z "\$2"): apply unit preset; upgrade (-n "\$2"): restart only if active
        if [ -z "\$2" ]; then
            systemctl preset '${s_installed}' >/dev/null 2>&1 || :
        else
            systemctl try-restart '${s_installed}' >/dev/null 2>&1 || :
        fi
EOF
    done
    cat << 'EOF' >> "${STAGING_DIR}/DEBIAN/postinst"
    fi
EOF
  fi
  cat << 'EOF' >> "${STAGING_DIR}/DEBIAN/postinst"
fi
exit 0
EOF
  chmod 0755 "${STAGING_DIR}/DEBIAN/postinst"
fi

if [ ${#SERVICES[@]} -gt 0 ] && [ ! -f "${STAGING_DIR}/DEBIAN/prerm" ]; then
  cat << 'EOF' > "${STAGING_DIR}/DEBIAN/prerm"
#!/bin/sh
set -e
if [ -d /run/systemd/system ] && [ "$1" = "remove" ]; then
EOF
  for s in "${SERVICES[@]}"; do
    if [[ "$s" == *:* ]]; then
      s_installed="$(basename "${s#*:}")"
    else
      s_installed="$(basename "$s")"
    fi
    echo "    systemctl --no-reload disable --now '${s_installed}' >/dev/null 2>&1 || :" >> "${STAGING_DIR}/DEBIAN/prerm"
  done
  cat << 'EOF' >> "${STAGING_DIR}/DEBIAN/prerm"
fi
exit 0
EOF
  chmod 0755 "${STAGING_DIR}/DEBIAN/prerm"
fi

if [ ${#SERVICES[@]} -gt 0 ] && [ ! -f "${STAGING_DIR}/DEBIAN/postrm" ]; then
  cat << 'EOF' > "${STAGING_DIR}/DEBIAN/postrm"
#!/bin/sh
set -e
if [ -d /run/systemd/system ]; then
    systemctl daemon-reload >/dev/null 2>&1 || :
    if [ "$1" = "purge" ]; then
        systemctl reset-failed >/dev/null 2>&1 || :
    fi
fi
exit 0
EOF
  chmod 0755 "${STAGING_DIR}/DEBIAN/postrm"
fi

# 12. Compute Installed-Size (in KB)
INSTALLED_SIZE=$(du -sk --exclude=DEBIAN "${STAGING_DIR}" | cut -f1)

# 13. Generate Debian control file
cat << EOF > "${STAGING_DIR}/DEBIAN/control"
Package: ${NAME}
Version: ${VERSION}
Architecture: ${ARCH}
Maintainer: ${MAINTAINER}
Installed-Size: ${INSTALLED_SIZE}
Section: ${SECTION}
Priority: ${PRIORITY}
EOF

[ -n "$HOMEPAGE" ] && echo "Homepage: ${HOMEPAGE}" >> "${STAGING_DIR}/DEBIAN/control"
[ -n "$DEPENDS" ] && echo "Depends: ${DEPENDS}" >> "${STAGING_DIR}/DEBIAN/control"
[ -n "$RECOMMENDS" ] && echo "Recommends: ${RECOMMENDS}" >> "${STAGING_DIR}/DEBIAN/control"
[ -n "$SUGGESTS" ] && echo "Suggests: ${SUGGESTS}" >> "${STAGING_DIR}/DEBIAN/control"
[ -n "$PROVIDES" ] && echo "Provides: ${PROVIDES}" >> "${STAGING_DIR}/DEBIAN/control"
[ -n "$CONFLICTS" ] && echo "Conflicts: ${CONFLICTS}" >> "${STAGING_DIR}/DEBIAN/control"
[ -n "$REPLACES" ] && echo "Replaces: ${REPLACES}" >> "${STAGING_DIR}/DEBIAN/control"

echo "Description: ${SUMMARY:-$NAME}" >> "${STAGING_DIR}/DEBIAN/control"
if [ -n "$DESC" ]; then
  echo "$DESC" | sed -e 's/\\$//' -e 's/[[:space:]]*$//' -e 's/^/ /' -e 's/^[[:space:]]*$/ ./' >> "${STAGING_DIR}/DEBIAN/control"
fi

# 14. Generate conffiles list
if [ ${#CONFFILES_LIST[@]} -gt 0 ]; then
  for conf in "${CONFFILES_LIST[@]}"; do
    echo "$conf" >> "${STAGING_DIR}/DEBIAN/conffiles"
  done
  chmod 0644 "${STAGING_DIR}/DEBIAN/conffiles"
fi

# 15. Normalize directory permissions throughout the payload (umask-safe)
find "${STAGING_DIR}" -type d -exec chmod 0755 {} +

# Re-apply explicit permissions for user-specified directories
for d in "${DIRS[@]}"; do
  if [[ "$d" == *:* ]]; then
    path="${d%%:*}"
    mode="${d#*:}"
  else
    path="$d"
    mode="0755"
  fi
  chmod "$mode" "${STAGING_DIR}/${path#/}" 2> /dev/null || :
done

# Generate md5sums for non-conffile payload files (matches dh_md5sums best practice)
(
  cd "${STAGING_DIR}"
  FIND_EXCLUDES=(-path "./DEBIAN")
  for conf in "${CONFFILES_LIST[@]}"; do
    FIND_EXCLUDES+=(-o -path ".${conf}")
  done
  find . -mindepth 1 \( "${FIND_EXCLUDES[@]}" \) -prune -o -type f -print0 |
    sed -z 's|^\./||' | LC_ALL=C sort -z | xargs -0 -r md5sum > DEBIAN/md5sums
)
chmod 0644 "${STAGING_DIR}/DEBIAN/control" "${STAGING_DIR}/DEBIAN/md5sums" 2> /dev/null || :
[ -f "${STAGING_DIR}/DEBIAN/conffiles" ] && chmod 0644 "${STAGING_DIR}/DEBIAN/conffiles" || :
for s in preinst postinst prerm postrm; do
  [ -f "${STAGING_DIR}/DEBIAN/${s}" ] && chmod 0755 "${STAGING_DIR}/DEBIAN/${s}" || :
done

# ------------------------------------------------------------------------------
# 5. Archive Assembly (dpkg-deb) & Post-Build Lintian Verification
# ------------------------------------------------------------------------------
# 16. Build .deb package
rm -f "$OUTPUT"
mkdir -p "$(dirname "$OUTPUT")"
dpkg-deb --build --root-owner-group "${STAGING_DIR}" "$OUTPUT"
echo "==> Successfully created Debian package: $OUTPUT"

# 17. Run Lintian verification unless disabled (--no-lintian)
if [ "$LINTIAN_MODE" != "off" ]; then
  _strict_lint=0
  [ "$LINTIAN_MODE" = "strict" ] && _strict_lint=1
  if [ -f "${SCRIPT_DIR}/pkg-verify.sh" ]; then
    bash "${SCRIPT_DIR}/pkg-verify.sh" check-deb "$OUTPUT" "$_strict_lint" "$LINTIAN_SUPPRESS"
  elif command -v lintian >/dev/null 2>&1; then
    _lint_args=(--tag-display-limit 0)
    [ -n "$LINTIAN_SUPPRESS" ] && _lint_args+=(--suppress-tags "$LINTIAN_SUPPRESS")
    set +e
    lintian "${_lint_args[@]}" "$OUTPUT"
    _lint_rc=$?
    set -e
    if [ "$_lint_rc" -eq 2 ]; then
      if [ "$_strict_lint" -eq 1 ]; then
        exit 1
      fi
    elif [ "$_lint_rc" -ne 0 ]; then
      exit 1
    fi
  elif [ "$_strict_lint" -eq 1 ]; then
    echo "ERROR: lintian not found in PATH (requested via --lintian)!" >&2
    exit 1
  fi
fi
