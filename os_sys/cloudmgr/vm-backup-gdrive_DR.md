# Disaster Recovery Runbook
**Host:** `cs-us-pweb001.criticalsys.net`  
**OS:** AlmaLinux 9 (x86_64)  
**Storage Architecture:** MBR / BIOS Boot (`/dev/vda1` on XFS `/boot`), LVM2 (`/dev/vda2` -> VG `almalinux` -> LV `root` on XFS, LV `swap`)  
**Core Workloads:** Podman Quadlet Containers (`caddy:2-alpine`, `uptime-kuma:2`, `ntfy:latest`)  
**Backup Frequency:** Daily at 08:00 UTC via `vm-backup.timer`  
**Storage Targets:** Google Drive (`gdrive:cs-us-pweb001`) via Rclone + Local Cache (2d)  

---

## 1. Emergency "Break-Glass" Prerequisites

Before initiating recovery, ensure you have the following credentials from your secure offsite vault:

1. **AES-256 Symmetric Passphrase**: Stored in `/root/.secrets/backup-passphrase`.
2. **Rclone Configuration**: `~/.config/rclone/rclone.conf` (with Google Drive OAuth tokens / credentials).
3. **Target VM / Hardware**: A VM or server with at least 80 GB disk storage and 2 GB RAM.

---

## 2. Pre-Flight: Downloading & Verifying the Backup Archive

### A. Download Archive & SHA-256 Checksum from Google Drive
On your recovery environment or rescue system:
```bash
# Configure rclone with your vault-escrowed rclone.conf
rclone lsd gdrive:cs-us-pweb001

# Identify the latest backup archive
LATEST_BACKUP=$(rclone lsf gdrive:cs-us-pweb001 --include "cs-pweb001-backup-*.tar.zst.gpg" | sort -r | head -n 1)

# Download both the archive and its companion SHA-256 checksum
rclone copy "gdrive:cs-us-pweb001/${LATEST_BACKUP}" ./
rclone copy "gdrive:cs-us-pweb001/${LATEST_BACKUP}.sha256" ./
```

### B. Verify Transport Integrity
```bash
sha256sum -c "${LATEST_BACKUP}.sha256"
# Expected output: cs-pweb001-backup-YYYYMMDD_HHMMSS.tar.zst.gpg: OK
```
> [!IMPORTANT]
> If the checksum test fails, do not proceed with the corrupted file. Redownload or fetch the preceding day's archive from Google Drive.

---

## 3. Scenario A: Complete Bare-Metal or Cloud VM Recovery

Use this procedure when recovering onto a blank disk, replacement cloud instance, or rescue ISO.

### Step 1: Boot into Live Rescue Shell
Boot the replacement VM using an **AlmaLinux 9 Minimal or Rescue ISO**.

### Step 2: Extract Disaster Recovery Manifest
You can inspect the DR manifest without full system extraction:
```bash
mkdir -p /tmp/dr-manifest
gpg --batch --passphrase-file /path/to/backup-passphrase -d "${LATEST_BACKUP}" \
  | tar --use-compress-program=unzstd -xvf - -C /tmp/dr-manifest var/recovery-manifest/
```

### Step 3: Replay Partition Table
Rebuild the exact partition table onto the new target disk (e.g. `/dev/vda`):
```bash
sfdisk /dev/vda < /tmp/dr-manifest/var/recovery-manifest/storage/partition-table-vda.sfdisk
partprobe /dev/vda
```

### Step 4: Restore LVM Volume Group
Import the raw LVM metadata dump captured during backup:
```bash
# Restore LVM configuration to /dev/vda2
vgcfgrestore -f /tmp/dr-manifest/var/recovery-manifest/storage/lvm-backup/almalinux.vgcfg almalinux

# Activate all logical volumes in the volume group
vgchange -ay almalinux

# Verify logical volumes are available
lvs
# Expected: root (77.47G), swap (2.00G)
```

### Step 5: Format Filesystems & Initialize Swap
```bash
# Format /boot (vda1) and / (almalinux-root)
mkfs.xfs -f /dev/vda1
mkfs.xfs -f /dev/mapper/almalinux-root

# Format swap
mkswap /dev/mapper/almalinux-swap
```

### Step 6: Mount Filesystem Hierarchy
```bash
mkdir -p /mnt/sysimage
mount /dev/mapper/almalinux-root /mnt/sysimage
mkdir -p /mnt/sysimage/boot
mount /dev/vda1 /mnt/sysimage/boot
```

### Step 7: Decrypt and Restore Archive Payload
```bash
gpg --batch --passphrase-file /path/to/backup-passphrase -d "${LATEST_BACKUP}" \
  | tar --use-compress-program=unzstd -xpvf - -C /mnt/sysimage/
```

### Step 8: Reinstall Bootloader (GRUB2)
Bind mount system virtual filesystems and chroot into the restored system:
```bash
for dir in dev proc sys run; do
    mount --bind "/${dir}" "/mnt/sysimage/${dir}"
done

chroot /mnt/sysimage /bin/bash <<'EOF'
# Verify fstab UUIDs match current block devices
blkid

# Reinstall GRUB on MBR
grub2-install /dev/vda
grub2-mkconfig -o /boot/grub2/grub.cfg

# Recreate initramfs for the active kernel
dracut --regenerate-all --force
EOF
```

### Step 9: Clean Unmount and Reboot
```bash
umount -R /mnt/sysimage
reboot
```

---

## 4. Scenario B: Granular / Selective Service Recovery

Use this procedure when the server is running, but a specific container, configuration, or database was corrupted or lost.

### Restoring Uptime Kuma or ntfy SQLite Databases:
```bash
# 1. Stop the target Quadlet service
systemctl stop uptime-kuma.service

# 2. Extract specific directory into temporary sandbox
mkdir -p /tmp/restore-sandbox
gpg --batch --passphrase-file /root/.secrets/backup-passphrase -d /var/backups/vm-snapshots/cs-pweb001-backup-*.tar.zst.gpg \
  | tar --use-compress-program=unzstd -xvf - -C /tmp/restore-sandbox var/lib/uptime-kuma/

# 3. Restore the staged SQLite database
cp -a /tmp/restore-sandbox/var/lib/uptime-kuma/data/kuma.db /var/lib/uptime-kuma/data/kuma.db

# 4. Clean up and restart service
rm -rf /tmp/restore-sandbox
systemctl start uptime-kuma.service
systemctl status uptime-kuma.service
```

### Restoring Web Server Configuration (Caddy):
```bash
mkdir -p /tmp/restore-sandbox
gpg --batch --passphrase-file /root/.secrets/backup-passphrase -d /var/backups/vm-snapshots/cs-pweb001-backup-*.tar.zst.gpg \
  | tar --use-compress-program=unzstd -xvf - -C /tmp/restore-sandbox etc/caddy/ var/lib/caddy/

cp -a /tmp/restore-sandbox/etc/caddy/* /etc/caddy/
cp -a /tmp/restore-sandbox/var/lib/caddy/* /var/lib/caddy/
rm -rf /tmp/restore-sandbox

systemctl restart caddy.service
```

---

## 5. Post-Recovery Verification Checklist

Once the restored machine boots:

1. **Containers & Systemd Services**:
   ```bash
   podman ps -a
   systemctl --failed
   ```
2. **Web Endpoints & TLS**:
   ```bash
   curl -I https://localhost
   curl -I http://127.0.0.1:3001  # Uptime Kuma
   curl -I http://127.0.0.1:2586  # ntfy
   ```
3. **Backup & Update Automation**:
   ```bash
   systemctl list-timers | grep -E 'vm-backup|container-update'
   /opt/scripts/check-container-updates.sh --check-only
   ```
4. **Disaster Recovery Manifest Reference**:
   Compare running system state against `/var/recovery-manifest/` for package divergence:
   ```bash
   rpm -qa --qf "%{NAME}\n" | sort -u > /tmp/current-pkgs.txt
   diff -u /var/recovery-manifest/installed-packages.txt /tmp/current-pkgs.txt
   ```
