# Proxmox VE Package Maintenance & Kernel Lifecycle Utility (`proxmox_update.sh`)

Enterprise-grade automated package update, distribution upgrade, and kernel lifecycle management utility designed specifically for **Proxmox Virtual Environment (PVE)** nodes running on Debian GNU/Linux.

---

## 1. Architectural Motivation & Vulnerability Analysis

### The Failure Mode of Legacy `package_update.sh`
In legacy implementations of `package_update.sh`, a common catastrophic failure mode was **root (`/`) partition exhaustion (`ENOSPC`) during distribution upgrades**, frequently rendering hypervisors completely unbootable:

```
[apt-get update] 
       │
       ▼
[apt-get dist-upgrade -y] ──► 1. Downloads 1-3 GB .deb archives into /var/cache/apt/archives/
       │                  ──► 2. Unpacks new kernel & dependencies into /
       │                  ──► 3. Root partition hits 100% capacity (ENOSPC)
       │                  ──► 4. update-initramfs fails or writes truncated 0-byte initrd.img
       │                  ──► 5. FATAL CRASH: dpkg transaction aborts in broken half-installed state
       ▼
[Cleanup Steps] ────────────► NEVER EXECUTED (Dead last in script lifecycle)
```

Upon host reboot, GRUB or systemd-boot attempts to load the corrupted/truncated initramfs image, triggering:
```text
Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(0,0)
```
Or on ZFS-based Proxmox installations:
```text
Cannot import 'rpool': no such pool or dataset
```
Because the truncated initramfs lacks required OpenZFS kernel modules or block drivers, the host drops to an initramfs rescue prompt or kernel panics, requiring physical IPMI or live USB rescue media.

### Why `ubuntu_upgrade.sh` CANNOT Be Used on Proxmox VE

| Hazard Category | `ubuntu_upgrade.sh` Behavior | Impact on Proxmox VE |
| :--- | :--- | :--- |
| **Mainline Kernel Deployment** | Chain-loads `ubuntu_kernel_updater.sh`, which pulls generic mainline Linux kernels from `kernel.ubuntu.com`. | **Fatal**: PVE requires the official Proxmox kernel containing out-of-tree OpenZFS modules, KVM virtualization patches, and cluster hooks. Generic kernels cannot import ZFS `rpool` or initialize KVM acceleration. |
| **`apt upgrade` Violation** | Executes `apt-get upgrade` before `apt-get dist-upgrade`. | **Prohibited by Proxmox**: Proxmox documentation strictly prohibits `apt-get upgrade` because it does not resolve changed dependencies. Running it creates broken partial upgrade states across `pve-manager`, `qemu-server`, and `corosync`. |
| **Ubuntu Telemetry Hooks** | Targets Canonical ESM (`apt-news`, `esm-cache`, `ubuntu-advantage`). | Non-existent on Debian/PVE, causing log clutter. |
| **Desktop / Flatpak Overhead** | Spawns background Flatpak updaters and purges `gstreamer1.0-vaapi`. | Unnecessary overhead on a headless server/hypervisor. |
| **Bootloader Tooling** | Assumes standard GRUB only. | Misses `proxmox-boot-tool refresh` required for UEFI/ZFS systemd-boot Proxmox configurations. |

---

## 2. Hardened Architecture & Safeguards in `proxmox_update.sh`

`proxmox_update.sh` (v2.0.0xg) implements deterministic pre-flight storage gating, early archive purging, strict non-interactive `dist-upgrade` semantics, and automated bootloader synchronization to prevent root partition exhaustion and package manager corruption.

```mermaid
flowchart TD
    Start(["sudo proxmox_update.sh"]) --> Lib["Source lib/system.sh<br/>(Idempotent Facade & Router)"]
    Lib --> Lock["Acquire flock /run/proxmox_update.lock<br/>& 4-Point APT Lock Inspection"]
    Lock --> CapCheck{"Pre-Flight Storage Audit<br/>(/ >= 2048 MB, /boot >= 250 MB)"}
    
    CapCheck -- Insufficient Headroom --o AutoClean["Auto-run max_root.sh<br/>(Vacuum journal, prune rotated logs,<br/>purge stale .cache and /var/lib/vz/dump tmp)"]
    AutoClean --> CapRecheck{"Re-evaluate Storage"}
    CapRecheck -- Still Insufficient & !--force --> Abort(["Abort Safely BEFORE APT Download<br/>(Prevents ENOSPC Crash)"])
    
    CapCheck -- OK --> AptClean["apt-get clean<br/>(Wipe .deb cache BEFORE download)"]
    CapRecheck -- OK --> AptClean
    
    AptClean --> AptSync["apt-get update<br/>(Refresh repository indices)"]
    AptSync --> DistUpgrade["apt-get dist-upgrade -y<br/>(Strict Proxmox Policy, Non-Interactive)"]
    DistUpgrade --> PostClean["Post-Upgrade Maintenance<br/>(dpkg --configure -a, autoremove --purge, rc purge)"]
    PostClean --> PveKernel{"--purge-kernels flag?"}
    
    PveKernel -- Yes --> PruneK["Purge Obsolete PVE Kernels<br/>(Strictly preserves active & newest kernels)"]
    PveKernel -- No --> TuneCheck
    PruneK --> BootSync["proxmox-boot-tool refresh || update-grub"]
    BootSync --> TuneCheck{"proxmox_tune.sh exists & !--skip-tune?"}
    
    TuneCheck -- Yes --> ExecTune["Execute proxmox_tune.sh<br/>(Subscription nag patch, pveproxy restart)"]
    TuneCheck -- No --> RebootCheck
    ExecTune --> RebootCheck["Audit Reboot Discrepancy<br/>(uname -r vs highest sorted PVE kernel)"]
    RebootCheck --> Done(["Report Metrics & Exit"])
```

### 2.1 Technical Specifications and Safety Controls

1. **Pre-Flight Disk Capacity Checks & `max_root.sh` Integration**:
   - Audits free capacity on `/` (recommended $\ge$ 2048 MB) and `/boot` (recommended $\ge$ 250 MB).
   - If free space is below safety margins (or if `--max-root` is supplied), it automatically invokes `max_root.sh` *before* touching package managers.
   - If capacity remains critically constrained, it aborts cleanly *before* any packages are downloaded or unpacked, guaranteeing that `update-initramfs` will never suffer an out-of-space failure.
2. **Inverted Archive Cleanup ("Pre-Clean" Paradigm)**:
   - Always runs `apt-get clean` *before* `apt-get update`. This purges cached `.deb` archives from prior transactions to ensure maximum physical headroom for incoming packages.
3. **Strict Proxmox `dist-upgrade` Semantics**:
   - Exclusively executes `apt-get dist-upgrade` with non-interactive flags (`DEBIAN_FRONTEND=noninteractive`, DPkg lock timeouts, and automatic configuration conflict resolution via `--force-confdef --force-confold`).
   - Plain `apt-get upgrade` is strictly forbidden.
4. **PVE Kernel Lifecycle & Safe Pruning (`--purge-kernels`)**:
   - Discovers all installed `pve-kernel-*` and `proxmox-kernel-*` images.
   - Identifies active kernel (`uname -r`) and the highest installed version. Both are **strictly protected**.
   - Identifies older superseded kernel versions and cleanly removes them via `apt-get purge`, freeing hundreds of megabytes in `/boot` and `/lib/modules`.
5. **Bootloader Synchronization**:
   - Dynamically checks for `proxmox-boot-tool` (standard on UEFI ZFS nodes) and executes `proxmox-boot-tool refresh`. Falls back to `update-grub` on BIOS/MBR nodes.
6. **Robust Dual-Naming Reboot Discrepancy Detection**:
   - Inspects `/boot` for both legacy `vmlinuz-*-pve` and modern `proxmox-kernel-*` image conventions.
   - Cross-references `/var/run/reboot-required` and version sorting to alert system operators when a reboot is necessary.
7. **Proxmox Tuning Integration**:
   - Safely executes `/opt/scripts/proxmox_tune.sh` (or `os_sys/proxmox_tune.sh`) to maintain subscription notice patches and UI optimizations.

---

## 3. Command Line Interface & Usage

```bash
sudo ./proxmox_update.sh [OPTIONS]
```

### Options

| Flag | Parameter | Description |
| :--- | :--- | :--- |
| `-h`, `--help` | None | Displays help documentation and usage examples. |
| `-n`, `--dry-run`, `--detect` | None | Simulates package transactions, evaluates disk capacity, and previews updates without modifying files. |
| `-f`, `--force` | None | Bypasses pre-flight storage threshold warnings. |
| `--max-root` | None | Explicitly invokes `max_root.sh` before upgrading to maximize available root space. |
| `--purge-kernels` | None | Safely purges obsolete PVE kernels while protecting the active running and newest fallback kernels. |
| `--tune-only` | None | Executes the Proxmox tuning script (`proxmox_tune.sh`) and exits immediately. |
| `--skip-tune` | None | Skips execution of the Proxmox tuning script during the upgrade cycle. |

---

## 4. Operational Examples

### 1. Standard Safe Maintenance Run
Executes lock checks, storage capacity verification, pre-cleaning, distribution upgrade, post-maintenance cleanup, and tuning:
```bash
sudo /opt/scripts/proxmox_update.sh
```

### 2. Comprehensive Pre-Upgrade Space Reclamation
Optimizes root space via `max_root.sh`, runs the distribution upgrade, and purges older inactive PVE kernels:
```bash
sudo /opt/scripts/proxmox_update.sh --max-root --purge-kernels
```

### 3. Dry-Run / Audit Mode
Inspects active locks, calculates filesystem headroom, simulates the upgrade via `apt-get -s dist-upgrade`, and checks reboot status:
```bash
sudo /opt/scripts/proxmox_update.sh --dry-run
```

### 4. Tuning Only
Applies the Proxmox UI subscription notice patch without running package updates:
```bash
sudo /opt/scripts/proxmox_update.sh --tune-only
```

---

## 5. File Structure & Dependencies

```
os_sys/
├── lib/
│   ├── system.sh                 # Universal entry point & dynamic library router
│   ├── debian_sys.sh             # Debian/PVE domain library (locks, storage, sort)
│   └── rhel_sys.sh               # Enterprise Linux domain library
├── max_root.sh                   # Root partition storage maximizer
├── max_root_README.md            # max_root.sh documentation
├── proxmox_update.sh             # Hardened Proxmox maintenance utility
├── proxmox_update_README.md      # This guide
└── proxmox_tune.sh               # Proxmox UI patch and tuning script
```

### Centralized Logging
All runtime executions and diagnostic outputs are logged concurrently to:
- **Console Standard Output / Standard Error**
- **Log File**: `/var/log/proxmox_update.log`

