#!/bin/bash
# -----------------------------------------
#  /opt/scripts/proxmox_tune.sh
#  v1.0.2xg  2026/06/04  XdG / MIS Center
# -----------------------------------------

PROXMOX_UI="/usr/share/javascript/proxmox-widget-toolkit"

pushd "${PROXMOX_UI}" &>/dev/null || exit 1

# 1. Check if the patch has already been applied
if grep -q "void({//" proxmoxlib.js; then
    echo "Patch already applied. Skipping."
else
    echo "Applying subscription notice patch..."

    # Clear out old backups to ensure a clean slate
    rm -f ./*.bak

    # Apply the regex substitution
    sed -Ezi.dist "s/(Ext.Msg.show\(\{\s+title: gettext\('No valid sub)/void\(\{\/\/\1/g" \
      proxmoxlib.js && systemctl restart pveproxy

    echo "Patch applied successfully and pveproxy restarted."
    diff -ub proxmoxlib.js.dist proxmoxlib.js
fi

popd &>/dev/null || exit 1
