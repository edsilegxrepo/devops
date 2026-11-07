#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# /opt/scripts/list_disks.sh
# v2.0.0xg  2026/11/06  XdG / MIS Center
# ------------------------------------------------------------------------------
# ==============================================================================
# SUMMARY & OBJECTIVES:
# ------------------------------------------------------------------------------
# Production-Grade Storage Device Topology, Hardware Asset Inventory, and Health
# Audit Utility for Enterprise Linux (RHEL, AlmaLinux, Rocky, CentOS, Fedora),
# Debian-family (Debian, Ubuntu, Mint), and Proxmox VE.
#
# Key Features:
#   1. Robust Device Enumeration & Sanitization:
#      - Structured key-value parsing (lsblk -d -P) completely immune to whitespace
#        in vendor/model strings and empty bus parameters.
#      - Automatic fallback to sysfs and SCSI inquiry for unnamed OEM disks.
#   2. Hardware Classification & Hypervisor Disambiguation:
#      - Programmatically distinguishes NVMe, SATA SSD, rotational HDD, and
#        hypervisor virtual disks (virtio, vmbus, VMware, QEMU, VirtualBox, WSL).
#   3. Storage Topology & Filesystem/Pool Mapping:
#      - Pre-aggregates mounts, swap allocations, ZFS pools, LVM volume groups,
#        and MDADM arrays to identify disk usage across partitions.
#   4. SMART Health, Endurance (Wear Level), and Thermal Telemetry:
#      - Fast SMART health self-assessment (PASSED/FAILED).
#      - SSD/NVMe endurance wear percentage (Percentage Used / Life Remaining).
#      - Non-invasive temperature acquisition with NVMe composite resolution.
#   5. Dual Output Formatting:
#      - Formatted aligned ASCII table with ANSI status highlighting.
#      - Structured JSON array payload (--json) for CMDB and automation pipelines.
# ==============================================================================
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

# ------------------------------------------------------------------------------
# 1. Foundation Library & Environment Initialization
# ------------------------------------------------------------------------------
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
LIB_SYSTEM="${SCRIPT_DIR}/lib/system.sh"
[[ -f "${LIB_SYSTEM}" ]] || LIB_SYSTEM="/opt/scripts/lib/system.sh"

if [[ -f "${LIB_SYSTEM}" ]]; then
    # shellcheck source=/dev/null
    source "${LIB_SYSTEM}"
    validate_os "any" >/dev/null 2>&1 || true
fi

# Fallback helper if library is unavailable
if ! declare -f get_safe_hostname >/dev/null 2>&1; then
    get_safe_hostname() {
        local raw_host
        raw_host="$(hostname -f 2>/dev/null || hostname 2>/dev/null || uname -n 2>/dev/null || echo "localhost")"
        echo "${raw_host}" | tr -dc 'a-zA-Z0-9_.-'
    }
fi

# ------------------------------------------------------------------------------
# 2. CLI Options and Argument Parsing
# ------------------------------------------------------------------------------
WARN_TEMP=50
CRIT_TEMP=65
NVME_WARN_TEMP=60
NVME_CRIT_TEMP=75
OUTPUT_JSON=false
HIDE_VIRTUAL=false
USE_COLOR=true
SHOW_VERBOSE=false

show_usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Production-grade storage topology, hardware asset inventory, and health audit utility.

OPTIONS:
    -h, --help          Show this help documentation and exit.
    -j, --json          Emit structured JSON array payload.
    -v, --verbose       Show extended attributes (Firmware Revision, WWN, Partition Scheme).
    -w, --warn <TEMP>   Warning threshold for SATA/SAS/HDD in C (default: ${WARN_TEMP} C).
    -c, --crit <TEMP>   Critical threshold for SATA/SAS/HDD in C (default: ${CRIT_TEMP} C).
    --nvme-warn <TEMP>  Warning threshold for NVMe SSDs in C (default: ${NVME_WARN_TEMP} C).
    --nvme-crit <TEMP>  Critical threshold for NVMe SSDs in C (default: ${NVME_CRIT_TEMP} C).
    --hide-virtual      Suppress hypervisor virtual disks from output.
    --no-color          Disable ANSI color formatting.

Default Thermal Profiles:
    - SATA / SAS / HDD : Normal < ${WARN_TEMP} C, Warning ${WARN_TEMP}-$((CRIT_TEMP - 1)) C, Critical >= ${CRIT_TEMP} C
    - NVMe SSD         : Normal < ${NVME_WARN_TEMP} C, Warning ${NVME_WARN_TEMP}-$((NVME_CRIT_TEMP - 1)) C, Critical >= ${NVME_CRIT_TEMP} C

EXAMPLES:
    $(basename "$0")
    $(basename "$0") --json
    $(basename "$0") --hide-virtual -v
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_usage
            exit 0
            ;;
        -j|--json)
            OUTPUT_JSON=true
            shift
            ;;
        -v|--verbose)
            SHOW_VERBOSE=true
            shift
            ;;
        -w|--warn)
            if [[ -n "${2:-}" && "$2" =~ ^[0-9]+$ ]]; then
                WARN_TEMP="$2"
                shift 2
            else
                echo "Error: --warn requires a numeric temperature value." >&2
                exit 1
            fi
            ;;
        -c|--crit)
            if [[ -n "${2:-}" && "$2" =~ ^[0-9]+$ ]]; then
                CRIT_TEMP="$2"
                shift 2
            else
                echo "Error: --crit requires a numeric temperature value." >&2
                exit 1
            fi
            ;;
        --nvme-warn)
            if [[ -n "${2:-}" && "$2" =~ ^[0-9]+$ ]]; then
                NVME_WARN_TEMP="$2"
                shift 2
            else
                echo "Error: --nvme-warn requires a numeric temperature value." >&2
                exit 1
            fi
            ;;
        --nvme-crit)
            if [[ -n "${2:-}" && "$2" =~ ^[0-9]+$ ]]; then
                NVME_CRIT_TEMP="$2"
                shift 2
            else
                echo "Error: --nvme-crit requires a numeric temperature value." >&2
                exit 1
            fi
            ;;
        --hide-virtual)
            HIDE_VIRTUAL=true
            shift
            ;;
        --no-color)
            USE_COLOR=false
            shift
            ;;
        *)
            echo "Error: Unknown parameter '$1'" >&2
            show_usage >&2
            exit 1
            ;;
    esac
done

if [[ ${WARN_TEMP} -ge ${CRIT_TEMP} ]]; then
    echo "Error: Warning threshold (${WARN_TEMP} C) must be less than critical threshold (${CRIT_TEMP} C)." >&2
    exit 1
fi
if [[ ${NVME_WARN_TEMP} -ge ${NVME_CRIT_TEMP} ]]; then
    echo "Error: NVMe warning threshold (${NVME_WARN_TEMP} C) must be less than critical threshold (${NVME_CRIT_TEMP} C)." >&2
    exit 1
fi

if [[ ! -t 1 ]]; then
    USE_COLOR=false
fi

# ------------------------------------------------------------------------------
# 3. Virtualization & Subsystem Detection
# ------------------------------------------------------------------------------
is_virtual_disk() {
    local disk="$1"
    local model="${2:-}"
    local subsys="${3:-}"
    local tran="${4:-}"
    local vendor="${5:-}"

    if [[ "${model}" =~ (Virtual\ Disk|QEMU|VMware|VBOX|Virtual\ IDE|VirtIO|Hyper-V) ]]; then
        return 0
    fi
    if [[ "${vendor}" =~ (Msft|VMware|QEMU|VBOX) ]]; then
        return 0
    fi
    if [[ "${subsys}" =~ (vmbus|virtio) || "${tran}" =~ (vmbus|virtio) ]]; then
        return 0
    fi
    if [[ -d "/sys/block/${disk}" ]]; then
        local target_path
        target_path="$(readlink -f "/sys/block/${disk}" 2>/dev/null || true)"
        if [[ "${target_path}" =~ /devices/virtual/block/ || "${target_path}" =~ /vmbus/ || "${target_path}" =~ /virtio/ ]]; then
            return 0
        fi
    fi
    return 1
}

# ------------------------------------------------------------------------------
# 4. Storage Topology & Mount Aggregation Engine
# ------------------------------------------------------------------------------
declare -A DISK_USAGE_MAP=()

build_topology_map() {
    # Scan all block devices and child partitions in key-value mode
    while IFS= read -r blk_item; do
        [[ -z "${blk_item}" ]] && continue
        local PKNAME=""
        local NAME=""
        local MOUNTPOINT=""
        local FSTYPE=""
        eval "${blk_item}"

        local parent_disk="${PKNAME:-${NAME}}"
        # Strip partition suffixes (nvme0n1p1 -> nvme0n1, sda1 / sdb3 -> sda / sdb)
        if [[ "${parent_disk}" =~ ^(nvme[0-9]+n[0-9]+)p[0-9]+$ ]]; then
            parent_disk="${BASH_REMATCH[1]}"
        elif [[ "${parent_disk}" =~ ^([a-zA-Z]+)[0-9]+$ ]]; then
            parent_disk="${BASH_REMATCH[1]}"
        fi

        local marker=""
        if [[ -n "${MOUNTPOINT}" ]]; then
            marker="${MOUNTPOINT}"
        elif [[ "${FSTYPE}" == "zfs_member" ]]; then
            marker="ZFS"
        elif [[ "${FSTYPE}" == "LVM2_member" ]]; then
            marker="LVM"
        elif [[ "${FSTYPE}" == "linux_raid_member" ]]; then
            marker="MDADM"
        elif [[ "${FSTYPE}" == "crypto_LUKS" ]]; then
            marker="LUKS"
        elif [[ "${FSTYPE}" == "swap" ]]; then
            marker="[SWAP]"
        fi

        if [[ -n "${marker}" ]]; then
            if [[ -z "${DISK_USAGE_MAP[${parent_disk}]:-}" ]]; then
                DISK_USAGE_MAP["${parent_disk}"]="${marker}"
            elif [[ ! "${DISK_USAGE_MAP[${parent_disk}]}" =~ (^|[[:space:]]|,)"${marker}"(,|$) ]]; then
                DISK_USAGE_MAP["${parent_disk}"]="${DISK_USAGE_MAP[${parent_disk}]}, ${marker}"
            fi
        fi
    done < <(lsblk -P -o PKNAME,NAME,MOUNTPOINT,FSTYPE 2>/dev/null || true)
}

build_topology_map

# ------------------------------------------------------------------------------
# 5. SMART Health, Wear Level, and Thermal Telemetry Engine
# ------------------------------------------------------------------------------
get_device_telemetry() {
    local dev_name="$1"
    local dev_path="/dev/${dev_name}"
    local is_virt="$2"
    local bus_type="$3"

    local temp_c="N/A"
    local health="N/A"
    local wear="N/A"

    if [[ "${is_virt}" == "true" ]]; then
        echo "N/A|VIRTUAL|N/A"
        return 0
    fi

    # 1. Temperature Telemetry (Fast query: sysfs hwmon -> smartctl)
    if [[ -d "/sys/class/block/${dev_name}/device/hwmon" ]]; then
        for hw_path in "/sys/class/block/${dev_name}/device/hwmon"/hwmon*; do
            if [[ -r "${hw_path}/temp1_input" ]]; then
                local raw_t
                raw_t="$(cat "${hw_path}/temp1_input" 2>/dev/null || true)"
                if [[ "${raw_t}" =~ ^[0-9]+$ && ${raw_t} -gt 0 ]]; then
                    temp_c="$((raw_t / 1000)) C"
                    break
                fi
            fi
        done
    elif [[ -d "/sys/class/nvme/${dev_name}/hwmon" ]]; then
        for hw_path in "/sys/class/nvme/${dev_name}/hwmon"/hwmon*; do
            if [[ -r "${hw_path}/temp1_input" ]]; then
                local raw_t
                raw_t="$(cat "${hw_path}/temp1_input" 2>/dev/null || true)"
                if [[ "${raw_t}" =~ ^[0-9]+$ && ${raw_t} -gt 0 ]]; then
                    temp_c="$((raw_t / 1000)) C"
                    break
                fi
            fi
        done
    fi

    # 2. SMART Telemetry via smartctl (requires root privileges)
    if command -v smartctl >/dev/null 2>&1 && [[ "$(id -u)" -eq 0 ]]; then
        local smart_info
        smart_info="$(smartctl -H -a "${dev_path}" 2>/dev/null || true)"

        if [[ -n "${smart_info}" ]]; then
            # Health check
            if echo "${smart_info}" | grep -qEi 'SMART overall-health self-assessment test result:[[:space:]]*PASSED|SMART Health Status:[[:space:]]*OK'; then
                health="PASSED"
            elif echo "${smart_info}" | grep -qEi 'SMART overall-health self-assessment test result:[[:space:]]*FAILED|SMART Health Status:[[:space:]]*FAILED'; then
                health="FAILED"
            elif echo "${smart_info}" | grep -qEi 'SMART overall-health'; then
                health="WARNING"
            else
                health="UNKNOWN"
            fi

            # Accurate Composite Temperature if not found via hwmon or if NVMe
            if [[ "${temp_c}" == "N/A" || "${bus_type}" == "nvme" ]]; then
                local smart_t
                smart_t="$(echo "${smart_info}" | awk '
                    /^[[:space:]]*Temperature:[[:space:]]*[0-9]+/ { print $2; exit }
                    /^[[:space:]]*194[[:space:]]+Temperature_Celsius/ { print $10; exit }
                    /^[[:space:]]*190[[:space:]]+Airflow_Temperature_Cel/ { print $10; exit }
                    /^[[:space:]]*231[[:space:]]+Temperature_Celsius/ { print $10; exit }
                    /^[[:space:]]*Current Drive Temperature:[[:space:]]*[0-9]+/ { print $4; exit }
                ')"
                if [[ "${smart_t}" =~ ^[0-9]+$ && ${smart_t} -gt 0 && ${smart_t} -lt 125 ]]; then
                    temp_c="${smart_t} C"
                fi
            fi

            # Endurance / Wear level parsing
            if [[ "${bus_type}" == "nvme" ]]; then
                local pct_used
                pct_used="$(echo "${smart_info}" | grep -iE 'Percentage Used:' | grep -oE '[0-9]+%' | head -n 1 || true)"
                if [[ -n "${pct_used}" ]]; then
                    wear="${pct_used} Used"
                fi
            else
                # ATA SSD wear attributes (Crucial/Micron, Kingston, Samsung, Intel, SanDisk)
                local wear_val
                wear_val="$(echo "${smart_info}" | awk '
                    /^[[:space:]]*202[[:space:]]+Percent_Lifetime/ { print $4 "% Left"; exit }
                    /^[[:space:]]*231[[:space:]]+SSD_Life_Left/ { print $4 "% Left"; exit }
                    /^[[:space:]]*233[[:space:]]+Media_Wearout_Indicator/ { print $4 "% Left"; exit }
                    /^[[:space:]]*177[[:space:]]+Wear_Leveling_Count/ { print $4 "% Left"; exit }
                    /^[[:space:]]*169[[:space:]]+Remaining_Lifetime_Perc/ { print $4 "% Left"; exit }
                    /^[[:space:]]*232[[:space:]]+Available_Reservd_Space/ { print $4 "% Left"; exit }
                ')"
                if [[ -z "${wear_val}" ]]; then
                    wear_val="$(echo "${smart_info}" | awk '/^[[:space:]]*202[[:space:]]+/ { print $4 "% Left"; exit }')"
                fi
                if [[ -n "${wear_val}" ]]; then
                    wear="${wear_val}"
                fi
            fi
        fi
    fi

    # Fallback diagnostics if smartctl could not query
    if [[ "${health}" == "N/A" ]]; then
        if ! command -v smartctl >/dev/null 2>&1; then
            health="NO_SMARTCTL"
        elif [[ "$(id -u)" -ne 0 ]]; then
            health="NO_ROOT"
        fi
    fi

    local smart_is_ssd=false
    local smart_serial=""
    if [[ -n "${smart_info:-}" ]]; then
        if echo "${smart_info}" | grep -qEi 'Rotation Rate:[[:space:]]*Solid State|Solid State Device'; then
            smart_is_ssd=true
        fi
        smart_serial="$(echo "${smart_info}" | awk -F: '/^[[:space:]]*Serial Number:[[:space:]]*/ { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit }' || true)"
    fi

    echo "${temp_c}|${health}|${wear}|${smart_is_ssd}|${smart_serial}"
}

# ------------------------------------------------------------------------------
# 6. Block Device Enumeration & Normalization
# ------------------------------------------------------------------------------
# Dynamically validate lsblk columns to ensure backward-compatibility across older
# util-linux releases (e.g. Enterprise Linux 8/7 lacking PTTYPE or SUBSYSTEMS)
LSBLK_BASE_COLS="NAME,SIZE,ROTA,TYPE,TRAN,VENDOR,MODEL,REV,SERIAL,WWN"
LSBLK_HELP_TEXT="$(lsblk --help 2>&1 || true)"
LSBLK_OPT_COLS=""
if echo "${LSBLK_HELP_TEXT}" | grep -qw "SUBSYSTEMS"; then
    LSBLK_OPT_COLS="${LSBLK_OPT_COLS},SUBSYSTEMS"
fi
if echo "${LSBLK_HELP_TEXT}" | grep -qw "PTTYPE"; then
    LSBLK_OPT_COLS="${LSBLK_OPT_COLS},PTTYPE"
fi
LSBLK_COLS="${LSBLK_BASE_COLS}${LSBLK_OPT_COLS}"

declare -a INVENTORY_RECORDS=()

while IFS= read -r dev_line; do
    [[ -z "${dev_line}" ]] && continue

    NAME=""
    SIZE=""
    ROTA=""
    TYPE=""
    TRAN=""
    VENDOR=""
    MODEL=""
    REV=""
    SERIAL=""
    WWN=""
    PTTYPE=""
    SUBSYSTEMS=""
    eval "${dev_line}"

    [[ "${TYPE}" != "disk" ]] && continue

    # 1. Virtualization Check
    is_virt=false
    if is_virtual_disk "${NAME}" "${MODEL}" "${SUBSYSTEMS:-}" "${TRAN}" "${VENDOR}"; then
        is_virt=true
        [[ "${HIDE_VIRTUAL}" == "true" ]] && continue
    fi

    # 2. Model & Vendor Sanitization
    clean_vendor="$(echo "${VENDOR:-}" | xargs || true)"
    clean_model="$(echo "${MODEL:-}" | xargs || true)"
    if [[ -z "${clean_model}" || ! "${clean_model}" =~ [[:alpha:]] ]]; then
        if [[ -r "/sys/block/${NAME}/device/model" ]]; then
            clean_model="$(cat "/sys/block/${NAME}/device/model" 2>/dev/null | xargs || true)"
        fi
    fi
    if [[ -z "${clean_model}" || ! "${clean_model}" =~ [[:alpha:]] ]]; then
        if [[ -n "${clean_vendor}" && "${clean_vendor}" =~ [[:alpha:]] && ! "${clean_vendor}" =~ ^(ATA|NVMe|SCSI)$ ]]; then
            clean_model="${clean_vendor} Disk"
        elif [[ "${is_virt}" == "true" ]]; then
            clean_model="Virtual Disk"
        else
            clean_model="Generic Disk"
        fi
    fi

    # Combined vendor/model display (suppress generic transport identifiers like ATA/NVMe/SCSI)
    full_model="${clean_model}"
    if [[ -n "${clean_vendor}" && ! "${clean_vendor}" =~ ^(ATA|NVMe|SCSI)$ && ! "${clean_model}" =~ ^"${clean_vendor}" ]]; then
        full_model="${clean_vendor} ${clean_model}"
    fi

    # 3. Transport Bus Identification
    bus_type="${TRAN:-}"
    if [[ -z "${bus_type}" ]]; then
        if [[ "${NAME}" =~ ^nvme ]]; then
            bus_type="nvme"
        elif [[ "${is_virt}" == "true" ]]; then
            bus_type="virtual"
        else
            # Check sysfs target path for usb
            dev_sys_path="$(readlink -f "/sys/block/${NAME}/device" 2>/dev/null || true)"
            if [[ "${dev_sys_path}" =~ /usb[0-9]+/ ]]; then
                bus_type="usb"
            else
                bus_type="sata"
            fi
        fi
    fi
    bus_type="$(echo "${bus_type}" | tr '[:upper:]' '[:lower:]')"

    # 4. Thermal & SMART Telemetry
    telemetry="$(get_device_telemetry "${NAME}" "${is_virt}" "${bus_type}")"
    IFS='|' read -r temp_c health wear smart_is_ssd smart_serial <<< "${telemetry}"

    # 5. Drive Type Classification (NVMe / SSD / HDD / VIRTUAL)
    drive_type="UNKNOWN"
    if [[ "${is_virt}" == "true" ]]; then
        drive_type="VIRTUAL"
    elif [[ "${bus_type}" == "nvme" || "${NAME}" =~ ^nvme ]]; then
        drive_type="NVMe"
    elif [[ "${smart_is_ssd}" == "true" || "${ROTA}" == "0" ]]; then
        drive_type="SSD"
    elif [[ "${ROTA}" == "1" ]]; then
        drive_type="HDD"
    fi

    # 6. Serial Number Discovery (prioritize controller SMART serial if USB bridge reports 0s)
    clean_serial="$(echo "${SERIAL:-}" | xargs || true)"
    if [[ (-z "${clean_serial}" || "${clean_serial}" =~ ^0+$) && -n "${smart_serial}" ]]; then
        clean_serial="${smart_serial}"
    elif [[ -z "${clean_serial}" && -r "/sys/block/${NAME}/device/serial" ]]; then
        clean_serial="$(cat "/sys/block/${NAME}/device/serial" 2>/dev/null | xargs || true)"
    fi
    if [[ -z "${clean_serial}" ]]; then
        clean_serial="N/A"
    fi

    # 7. Usage / Mountpoint / Pool Mapping
    usage="${DISK_USAGE_MAP[${NAME}]:-Unused}"

    # 8. Extended Attributes
    clean_rev="$(echo "${REV:-}" | xargs || echo "N/A")"
    clean_wwn="$(echo "${WWN:-}" | xargs || echo "N/A")"
    clean_pttype="$(echo "${PTTYPE:-}" | xargs || echo "N/A")"
    clean_size="${SIZE:-N/A}"

    INVENTORY_RECORDS+=("${NAME}|${drive_type}|${bus_type}|${clean_size}|${temp_c}|${health}|${wear}|${clean_serial}|${full_model}|${usage}|${clean_rev}|${clean_wwn}|${clean_pttype}|${is_virt}")

done < <(lsblk -d -P -o "${LSBLK_COLS}" 2>/dev/null || lsblk -d -P -o "${LSBLK_BASE_COLS}" 2>/dev/null || lsblk -d -P 2>/dev/null || true)

# ------------------------------------------------------------------------------
# 7. Structured JSON Output Generation
# ------------------------------------------------------------------------------
if [[ "${OUTPUT_JSON}" == "true" ]]; then
    if [[ ${#INVENTORY_RECORDS[@]} -eq 0 ]]; then
        echo "[]"
        exit 0
    fi

    declare -a json_entries=()
    for rec in "${INVENTORY_RECORDS[@]}"; do
        IFS='|' read -r d_name d_type d_bus d_size d_temp d_health d_wear d_serial d_model d_usage d_rev d_wwn d_pttype d_virt <<< "${rec}"

        temp_num="null"
        if [[ "${d_temp}" =~ ^([0-9]+)[[:space:]]*C$ ]]; then
            temp_num="${BASH_REMATCH[1]}"
        fi

        wear_json="null"
        if [[ "${d_wear}" != "N/A" ]]; then
            wear_json="\"${d_wear}\""
        fi

        json_entries+=("    {
      \"device\": \"/dev/${d_name}\",
      \"name\": \"${d_name}\",
      \"type\": \"${d_type}\",
      \"bus\": \"${d_bus}\",
      \"size\": \"${d_size}\",
      \"temperature_c\": ${temp_num},
      \"health\": \"${d_health}\",
      \"wear\": ${wear_json},
      \"serial\": \"${d_serial}\",
      \"model\": \"${d_model}\",
      \"usage\": \"${d_usage}\",
      \"revision\": \"${d_rev}\",
      \"wwn\": \"${d_wwn}\",
      \"pttype\": \"${d_pttype}\",
      \"is_virtual\": ${d_virt}
    }")
    done

    echo "["
    IFS=','
    joined_json="$(printf ",\n%s" "${json_entries[@]}")"
    echo "${joined_json:2}"
    echo "]"
    exit 0
fi

# ------------------------------------------------------------------------------
# 8. Tabular Terminal Output Generation
# ------------------------------------------------------------------------------
HOSTNAME_TAG="$(get_safe_hostname)"
FRAME_BORDER="$(printf '=%.0s' {1..160})"
FRAME_SUBBORDER="$(printf -- '-%.0s' {1..160})"

C_RESET=""
C_GREEN=""
C_YELLOW=""
C_RED=""
C_CYAN=""
C_GRAY=""

if [[ "${USE_COLOR}" == "true" ]]; then
    C_RESET="\033[0m"
    C_GREEN="\033[32m"
    C_YELLOW="\033[33m"
    C_RED="\033[1;31m"
    C_CYAN="\033[36m"
    C_GRAY="\033[90m"
fi

echo ""
echo "${FRAME_BORDER}"
printf " Storage Device Inventory & Topology Report: [%s]\n" "${HOSTNAME_TAG}"
echo "${FRAME_BORDER}"

if [[ "${SHOW_VERBOSE}" == "true" ]]; then
    printf "%-14s %-8s %-8s %-9s %-8s %-10s %-11s %-20s %-28s %-8s %-22s %s\n" \
        "Device" "Type" "Bus" "Size" "Temp" "Health" "Wear" "Serial" "Model" "Rev" "WWN" "Usage / Mount"
    echo "${FRAME_SUBBORDER}"
else
    printf "%-14s %-8s %-8s %-9s %-8s %-10s %-11s %-20s %-28s %s\n" \
        "Device" "Type" "Bus" "Size" "Temp" "Health" "Wear" "Serial" "Model" "Usage / Mount"
    echo "${FRAME_SUBBORDER}"
fi

if [[ ${#INVENTORY_RECORDS[@]} -eq 0 ]]; then
    echo "No matching storage block devices detected."
else
    for rec in "${INVENTORY_RECORDS[@]}"; do
        IFS='|' read -r d_name d_type d_bus d_size d_temp d_health d_wear d_serial d_model d_usage d_rev d_wwn d_pttype d_virt <<< "${rec}"

        dev_label="/dev/${d_name}"

        # Colorize Health
        health_color="${C_RESET}"
        if [[ "${d_health}" == "PASSED" ]]; then
            health_color="${C_GREEN}"
        elif [[ "${d_health}" == "FAILED" ]]; then
            health_color="${C_RED}"
        elif [[ "${d_health}" =~ (WARNING|NO_ROOT|NO_SMARTCTL) ]]; then
            health_color="${C_YELLOW}"
        elif [[ "${d_health}" == "VIRTUAL" ]]; then
            health_color="${C_GRAY}"
        fi

        # Colorize Type
        type_color="${C_RESET}"
        if [[ "${d_type}" == "NVMe" ]]; then
            type_color="${C_CYAN}"
        elif [[ "${d_type}" == "SSD" ]]; then
            type_color="${C_GREEN}"
        elif [[ "${d_type}" == "HDD" ]]; then
            type_color="${C_YELLOW}"
        elif [[ "${d_type}" == "VIRTUAL" ]]; then
            type_color="${C_GRAY}"
        fi

        # Colorize Temperature (Bus-aware: NVMe operates hotter than SATA/SAS)
        temp_color="${C_RESET}"
        if [[ "${d_temp}" =~ ^([0-9]+)[[:space:]]*C$ ]]; then
            t_num="${BASH_REMATCH[1]}"
            if [[ "${d_bus}" == "nvme" || "${d_type}" == "NVMe" ]]; then
                if [[ ${t_num} -ge ${NVME_CRIT_TEMP} ]]; then
                    temp_color="${C_RED}"
                elif [[ ${t_num} -ge ${NVME_WARN_TEMP} ]]; then
                    temp_color="${C_YELLOW}"
                else
                    temp_color="${C_GREEN}"
                fi
            else
                if [[ ${t_num} -ge ${CRIT_TEMP} ]]; then
                    temp_color="${C_RED}"
                elif [[ ${t_num} -ge ${WARN_TEMP} ]]; then
                    temp_color="${C_YELLOW}"
                else
                    temp_color="${C_GREEN}"
                fi
            fi
        elif [[ "${d_temp}" == "N/A" ]]; then
            temp_color="${C_GRAY}"
        fi

        # Complete unclipped attributes (no truncation)
        serial_display="${d_serial}"
        model_display="${d_model}"

        if [[ "${SHOW_VERBOSE}" == "true" ]]; then
            printf "%-14s ${type_color}%-8s${C_RESET} %-8s %-9s ${temp_color}%-8s${C_RESET} ${health_color}%-10s${C_RESET} %-11s %-20s %-28s %-8s %-22s %s\n" \
                "${dev_label}" "${d_type}" "${d_bus}" "${d_size}" "${d_temp}" "${d_health}" "${d_wear}" "${serial_display}" "${model_display}" "${d_rev}" "${d_wwn}" "${d_usage}"
        else
            printf "%-14s ${type_color}%-8s${C_RESET} %-8s %-9s ${temp_color}%-8s${C_RESET} ${health_color}%-10s${C_RESET} %-11s %-20s %-28s %s\n" \
                "${dev_label}" "${d_type}" "${d_bus}" "${d_size}" "${d_temp}" "${d_health}" "${d_wear}" "${serial_display}" "${model_display}" "${d_usage}"
        fi
    done
fi

echo "${FRAME_BORDER}"

# Guidance on root elevation if physical hardware health is unreadable
if [[ "$(id -u)" -ne 0 ]]; then
    for rec in "${INVENTORY_RECORDS[@]}"; do
        if [[ "${rec}" =~ NO_ROOT ]]; then
            echo ""
            echo "[*] Notice: Execute via 'sudo' to query physical drive SMART health and SSD wear metrics."
            break
        fi
    done
fi
