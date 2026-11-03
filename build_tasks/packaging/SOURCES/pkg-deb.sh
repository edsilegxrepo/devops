#!/bin/bash
# ==============================================================================
# Script:      /usr/src/redhat/SOURCES/pkg-deb.sh
# Purpose:     Standalone, self-cleaning Debian (.deb) binary package builder.
# Applicability: Supports Rust, Go, and C/C++ packages (CLIs and daemon services).
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
#   * Note: If systemd units, sysusers, or tmpfiles are installed and no hooks
#     are given, safe default daemon-reload, sysusers, and tmpfiles hooks are generated.
# ==============================================================================
set -eo pipefail

NAME=""
VERSION=""
ARCH=""
MAINTAINER="Mis Center <support@criticalsys.net>"
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

# Create isolated staging environment
STAGING_DIR="$(mktemp -d -t "deb_staging_${NAME}_XXXXXX")"
trap 'rm -rf "${STAGING_DIR}"' EXIT

mkdir -p "${STAGING_DIR}/DEBIAN" \
  "${STAGING_DIR}/usr/bin" \
  "${STAGING_DIR}/usr/share/doc/${NAME}"
chmod 0755 "${STAGING_DIR}" "${STAGING_DIR}/DEBIAN"

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
    echo "WARNING: Conffile '$src' not found, skipping." >&2
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
      echo "WARNING: Data source '$src' not found, skipping." >&2
    fi
  else
    echo "WARNING: Data item '$d' missing destination (format: src:dest), skipping." >&2
  fi
done

# 4. Install systemd services
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
    dest_rel="usr/lib/sysusers.d/$(basename "$u")"
  fi
  if [ -f "$src" ]; then
    mkdir -p "$(dirname "${STAGING_DIR}/${dest_rel}")"
    cp -af "$src" "${STAGING_DIR}/${dest_rel}"
    chmod 0644 "${STAGING_DIR}/${dest_rel}"
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
    dest_rel="usr/lib/tmpfiles.d/$(basename "$t")"
  fi
  if [ -f "$src" ]; then
    mkdir -p "$(dirname "${STAGING_DIR}/${dest_rel}")"
    cp -af "$src" "${STAGING_DIR}/${dest_rel}"
    chmod 0644 "${STAGING_DIR}/${dest_rel}"
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

# 9. Install documentation
for d in "${DOCS[@]}"; do
  if [ -f "$d" ]; then
    cp -af "$d" "${STAGING_DIR}/usr/share/doc/${NAME}/"
    chmod 0644 "${STAGING_DIR}/usr/share/doc/${NAME}/$(basename "$d")"
  fi
done

# 10. Install changelog files
if [ -n "$CHANGELOG" ] && [ -f "$CHANGELOG" ]; then
  cp -af "$CHANGELOG" "${STAGING_DIR}/usr/share/doc/${NAME}/changelog"
  gzip -9n -f "${STAGING_DIR}/usr/share/doc/${NAME}/changelog"
  chmod 0644 "${STAGING_DIR}/usr/share/doc/${NAME}/changelog.gz"
fi

cat << EOF > "${STAGING_DIR}/usr/share/doc/${NAME}/changelog.Debian"
${NAME} (${VERSION}) stable; urgency=medium

  * Packages updated to latest upstream release

 -- ${MAINTAINER}  $(date -R)
EOF
gzip -9n -f "${STAGING_DIR}/usr/share/doc/${NAME}/changelog.Debian"
chmod 0644 "${STAGING_DIR}/usr/share/doc/${NAME}/changelog.Debian.gz"

# 11. Install maintainer scripts (or auto-generate systemd lifecycle hooks if needed)
[ -n "$PREINST" ] && [ -f "$PREINST" ] && cp -af "$PREINST" "${STAGING_DIR}/DEBIAN/preinst" && chmod 0755 "${STAGING_DIR}/DEBIAN/preinst"
[ -n "$POSTINST" ] && [ -f "$POSTINST" ] && cp -af "$POSTINST" "${STAGING_DIR}/DEBIAN/postinst" && chmod 0755 "${STAGING_DIR}/DEBIAN/postinst"
[ -n "$PRERM" ] && [ -f "$PRERM" ] && cp -af "$PRERM" "${STAGING_DIR}/DEBIAN/prerm" && chmod 0755 "${STAGING_DIR}/DEBIAN/prerm"
[ -n "$POSTRM" ] && [ -f "$POSTRM" ] && cp -af "$POSTRM" "${STAGING_DIR}/DEBIAN/postrm" && chmod 0755 "${STAGING_DIR}/DEBIAN/postrm"

# If systemd services, sysusers, or tmpfiles are included but no explicit postinst was provided, generate safe hooks
if [ ! -f "${STAGING_DIR}/DEBIAN/postinst" ] && { [ ${#SERVICES[@]} -gt 0 ] || [ ${#SYSUSERS[@]} -gt 0 ] || [ ${#TMPFILES[@]} -gt 0 ]; }; then
  cat << 'EOF' > "${STAGING_DIR}/DEBIAN/postinst"
#!/bin/sh
set -e
EOF
  for u in "${SYSUSERS[@]}"; do
    if [[ "$u" == *:* ]]; then
      u_installed="$(basename "${u#*:}")"
    else
      u_installed="$(basename "$u")"
    fi
    cat << EOF >> "${STAGING_DIR}/DEBIAN/postinst"
if command -v systemd-sysusers >/dev/null 2>&1; then
    systemd-sysusers "${u_installed}" >/dev/null 2>&1 || :
fi
EOF
  done
  for t in "${TMPFILES[@]}"; do
    if [[ "$t" == *:* ]]; then
      t_installed="$(basename "${t#*:}")"
    else
      t_installed="$(basename "$t")"
    fi
    cat << EOF >> "${STAGING_DIR}/DEBIAN/postinst"
if command -v systemd-tmpfiles >/dev/null 2>&1; then
    systemd-tmpfiles --create "${t_installed}" >/dev/null 2>&1 || :
fi
EOF
  done
  if [ ${#SERVICES[@]} -gt 0 ]; then
    cat << 'EOF' >> "${STAGING_DIR}/DEBIAN/postinst"
if [ -d /run/systemd/system ]; then
    systemctl daemon-reload >/dev/null 2>&1 || :
fi
EOF
  fi
  cat << 'EOF' >> "${STAGING_DIR}/DEBIAN/postinst"
exit 0
EOF
  chmod 0755 "${STAGING_DIR}/DEBIAN/postinst"
fi

if [ ${#SERVICES[@]} -gt 0 ] && [ ! -f "${STAGING_DIR}/DEBIAN/prerm" ]; then
  cat << EOF > "${STAGING_DIR}/DEBIAN/prerm"
#!/bin/sh
set -e
if [ -d /run/systemd/system ] && [ "\$1" = "remove" ]; then
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
  echo "$DESC" | sed -e 's/\\$//' -e 's/^/ /' -e 's/^[[:space:]]*$/ ./' >> "${STAGING_DIR}/DEBIAN/control"
fi

# 14. Generate conffiles list
if [ ${#CONFFILES_LIST[@]} -gt 0 ]; then
  for conf in "${CONFFILES_LIST[@]}"; do
    echo "$conf" >> "${STAGING_DIR}/DEBIAN/conffiles"
  done
  chmod 0644 "${STAGING_DIR}/DEBIAN/conffiles"
fi

# 15. Normalize directory permissions throughout the payload
find "${STAGING_DIR}" -type d -exec chmod u+rwx,go-w {} +
chmod 0755 "${STAGING_DIR}" "${STAGING_DIR}/DEBIAN"

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

# Generate md5sums for all installed package payload files
(
  cd "${STAGING_DIR}"
  find . -mindepth 1 -path "./DEBIAN" -prune -o -type f -print |
    sed 's|^\./||' | sort | while read -r file; do
    md5sum "$file"
  done > DEBIAN/md5sums
) || :
chmod 0644 "${STAGING_DIR}/DEBIAN/control" "${STAGING_DIR}/DEBIAN/md5sums" 2> /dev/null || :
[ -f "${STAGING_DIR}/DEBIAN/conffiles" ] && chmod 0644 "${STAGING_DIR}/DEBIAN/conffiles" || :
for s in preinst postinst prerm postrm; do
  [ -f "${STAGING_DIR}/DEBIAN/${s}" ] && chmod 0755 "${STAGING_DIR}/DEBIAN/${s}" || :
done

# 16. Build .deb package
rm -f "$OUTPUT"
mkdir -p "$(dirname "$OUTPUT")"
dpkg-deb --build --root-owner-group "${STAGING_DIR}" "$OUTPUT"
echo "==> Successfully created Debian package: $OUTPUT"
