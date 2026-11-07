#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# /opt/scripts/disktemp.sh
# v2.1.0xg  2026/11/06  XdG / MIS Center
# ------------------------------------------------------------------------------
# ==============================================================================
# SUMMARY & OBJECTIVES:
# ------------------------------------------------------------------------------
# Production Hardened Cross-Platform Storage Device Temperature Audit Utility
# (RHEL / AlmaLinux / Rocky / CentOS / Fedora / Debian / Ubuntu / Mint / Proxmox)
#
# Key Features:
#   1. Multi-Tier Temperature Engine:
#      - Tier 1: smartctl authoritative controller query (prioritized when
#                root/smartctl available). Accurately captures NVMe Composite
#                Temperature and ATA attributes while ignoring bogus/uncalibrated
#                auxiliary junction sensors (e.g. Crucial P1 Sensor 1 = 96 C).
#      - Tier 2: NVMe-CLI hardware smart-log telemetry.
#      - Tier 3: Native sysfs hwmon subsystem (/sys/class/block/*/device/hwmon,
#                /sys/class/nvme/*/hwmon). Fast, non-invasive fallback for non-root.
#   2. Virtualization & Cloud Awareness:
#      - Automatically identifies hypervisor disks (WSL, QEMU, KVM virtio, VMware,
#        Hyper-V vmbus, VirtualBox) and labels them [VIRTUAL] without crashing
#        or spamming stderr.
#   3. Clean ASCII Formatting & JSON Output:
#      - Pure ASCII degree formatting ("36 C") to avoid UTF-8 terminal encoding
#        artifacts ("Â°C").
#      - ANSI color-coded tabular output (Normal, Warning, Critical).
#      - Machine-readable JSON output (--json) for monitoring / metrics ingestion.
#   4. Actionable Diagnostics:
#      - Intelligent guidance on package installation (smartmontools) and root
#        elevation requirements when physical hardware sensors are unreadable.
# ==============================================================================
set -euo pipefail

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
        (hostname -f 2>/dev/null || hostname 2>/dev/null || uname -n || echo "localhost") | tr -dc 'a-zA-Z0-9_.-'
    }
fi

# Configuration defaults
WARN_TEMP=45
CRIT_TEMP=55
OUTPUT_JSON=false
HIDE_VIRTUAL=false
USE_COLOR=true

if [[ ! -t 1 ]] || [[ -n "${NO_COLOR:-}" ]]; then
    USE_COLOR=false
fi

# ------------------------------------------------------------------------------
# 2. CLI Usage & Argument Parsing
# ------------------------------------------------------------------------------
show_usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Cross-Platform Storage Device Temperature Audit Utility (NVMe / SATA / SAS).

Options:
  -h, --help                Show this help documentation and exit.
  -j, --json                Output drive temperature data as formatted JSON.
  -w, --warn <TEMP>         Warning temperature threshold in C (default: ${WARN_TEMP} C).
  -c, --crit <TEMP>         Critical temperature threshold in C (default: ${CRIT_TEMP} C).
  --hide-virtual            Exclude virtualized hypervisor disks from the output.
  --no-color                Disable ANSI terminal color output.

Threshold Levels:
  - Normal    : < ${WARN_TEMP} C
  - Warning   : ${WARN_TEMP} C - $((CRIT_TEMP - 1)) C
  - Critical  : >= ${CRIT_TEMP} C
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
        -w|--warn)
            if [[ -n "${2:-}" && "$2" =~ ^[0-9]+$ ]]; then
                WARN_TEMP="$2"
                shift 2
            else
                echo "[-] Error: --warn requires a numeric temperature value." >&2
                exit 1
            fi
            ;;
        -c|--crit)
            if [[ -n "${2:-}" && "$2" =~ ^[0-9]+$ ]]; then
                CRIT_TEMP="$2"
                shift 2
            else
                echo "[-] Error: --crit requires a numeric temperature value." >&2
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
            echo "[-] Usage Error: Unknown argument '$1'" >&2
            show_usage >&2
            exit 1
            ;;
    esac
done

# Ensure valid thresholds
if [[ ${WARN_TEMP} -ge ${CRIT_TEMP} ]]; then
    echo "[-] Error: Warning threshold (${WARN_TEMP} C) must be less than critical threshold (${CRIT_TEMP} C)." >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# 3. Virtualization & Subsystem Detection
# ------------------------------------------------------------------------------
is_virtual_disk() {
    local disk="$1"
    local model="${2:-}"
    local subsys="${3:-}"
    local tran="${4:-}"

    if [[ "${model}" =~ (Virtual\ Disk|QEMU|VMware|VBOX|Virtual\ IDE|VirtIO|Hyper-V) ]]; then
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
# 4. Multi-Tier Temperature Engine
# ------------------------------------------------------------------------------
get_disk_temperature() {
    local dev_name="$1"
    local dev_path="/dev/${dev_name}"
    local is_virt="$2"

    if [[ "${is_virt}" == "true" ]]; then
        echo "N/A:VIRTUAL"
        return 0
    fi

    # --------------------------------------------------------------------------
    # Tier 1: smartctl Authoritative Controller Telemetry
    # (Prioritized when available & root to accurately resolve Composite Temperature
    # and avoid uncalibrated/bogus internal junction sensors such as Crucial P1 Sensor 1 = 96 C)
    # --------------------------------------------------------------------------
    if command -v smartctl >/dev/null 2>&1; then
        local raw_smart
        raw_smart="$(smartctl -a "${dev_path}" 2>/dev/null || smartctl -A "${dev_path}" 2>/dev/null || true)"
        if [[ -n "${raw_smart}" ]]; then
            local parsed_temp=""

            # 1. NVMe Composite Temperature: "Temperature: 36 Celsius"
            # (Strictly requires digit right after "Temperature:" to avoid auxiliary "Temperature Sensor X")
            parsed_temp="$(echo "${raw_smart}" | grep -iE '^[[:space:]]*Temperature:[[:space:]]*[0-9]+' | head -n 1 | awk '{print $2}' | tr -dc '0-9' || true)"

            # 2. ATA Standard Attributes: 194 (Temperature_Celsius) or 190 (Airflow_Temperature)
            if [[ -z "${parsed_temp}" ]]; then
                parsed_temp="$(echo "${raw_smart}" | grep -E '^[[:space:]]*(194|190)[[:space:]]+(Temperature|Airflow)' | head -n 1 | awk '{print $10}' | tr -dc '0-9' || true)"
            fi

            # 3. ATA SSD Attribute 231 (Temperature_Celsius / SSD_Life_Left)
            if [[ -z "${parsed_temp}" ]]; then
                parsed_temp="$(echo "${raw_smart}" | grep -E '^[[:space:]]*231[[:space:]]+Temperature' | head -n 1 | awk '{print $10}' | tr -dc '0-9' || true)"
            fi

            # 4. SCSI/SAS Standard: "Current Drive Temperature: 32 C"
            if [[ -z "${parsed_temp}" ]]; then
                parsed_temp="$(echo "${raw_smart}" | grep -iE 'Current Drive Temperature:' | head -n 1 | awk -F: '{print $2}' | tr -dc '0-9' || true)"
            fi

            if [[ "${parsed_temp}" =~ ^[0-9]+$ ]] && [[ ${parsed_temp} -gt 0 ]] && [[ ${parsed_temp} -lt 120 ]]; then
                echo "${parsed_temp}:SMARTCTL"
                return 0
            fi
        fi
    fi

    # --------------------------------------------------------------------------
    # Tier 2: NVMe-CLI Hardware Telemetry (nvme smart-log)
    # --------------------------------------------------------------------------
    if [[ "${dev_name}" =~ ^nvme ]] && command -v nvme >/dev/null 2>&1; then
        local nvme_raw
        nvme_raw="$(nvme smart-log "${dev_path}" 2>/dev/null | grep -iE '^[[:space:]]*temperature[[:space:]]*:[[:space:]]*[0-9]+' | head -n 1 | awk '{print $3}' | tr -dc '0-9' || true)"
        if [[ "${nvme_raw}" =~ ^[0-9]+$ ]] && [[ ${nvme_raw} -gt 0 ]] && [[ ${nvme_raw} -lt 120 ]]; then
            echo "${nvme_raw}:NVME_CLI"
            return 0
        fi
    fi

    # --------------------------------------------------------------------------
    # Tier 3: Native Linux sysfs hwmon Subsystem
    # (Non-root fallback and environment where smartctl is uninstalled)
    # --------------------------------------------------------------------------
    local hwmon_candidates=(
        "/sys/class/block/${dev_name}/device/hwmon/hwmon"*
        "/sys/class/nvme/${dev_name%%n*}/hwmon/hwmon"*
        "/sys/class/nvme/${dev_name%%n*}/device/hwmon/hwmon"*
    )

    for hwmon_glob in "${hwmon_candidates[@]}"; do
        for hwmon_dir in ${hwmon_glob}; do
            if [[ -d "${hwmon_dir}" ]]; then
                # Priority 3A: Search for explicit 'Composite' sensor label
                local comp_temp=""
                for label_file in "${hwmon_dir}"/temp*_label; do
                    if [[ -r "${label_file}" ]]; then
                        if grep -qi "Composite" "${label_file}" 2>/dev/null; then
                            local input_file="${label_file%_label}_input"
                            if [[ -r "${input_file}" ]]; then
                                local r_val
                                r_val="$(cat "${input_file}" 2>/dev/null || true)"
                                if [[ "${r_val}" =~ ^[0-9]+$ ]] && [[ ${r_val} -gt 0 ]]; then
                                    comp_temp=$((r_val / 1000))
                                    break
                                fi
                            fi
                        fi
                    fi
                done

                if [[ -n "${comp_temp}" && ${comp_temp} -gt 0 && ${comp_temp} -lt 120 ]]; then
                    echo "${comp_temp}:SYSFS"
                    return 0
                fi

                # Priority 3B: Inspect all sensors, filtering out uncalibrated extreme outliers (>= 90 C)
                local -a found_temps=()
                for input_file in "${hwmon_dir}"/temp*_input; do
                    if [[ -r "${input_file}" ]]; then
                        local r_val
                        r_val="$(cat "${input_file}" 2>/dev/null || true)"
                        if [[ "${r_val}" =~ ^[0-9]+$ ]] && [[ ${r_val} -gt 0 ]]; then
                            found_temps+=($((r_val / 1000)))
                        fi
                    fi
                done

                if [[ ${#found_temps[@]} -gt 0 ]]; then
                    local chosen_temp="${found_temps[0]}"
                    for t in "${found_temps[@]}"; do
                        if [[ ${t} -lt ${chosen_temp} ]] || [[ ${chosen_temp} -ge 90 && ${t} -lt 90 ]]; then
                            chosen_temp="${t}"
                        fi
                    done
                    if [[ ${chosen_temp} -gt 0 && ${chosen_temp} -lt 120 ]]; then
                        echo "${chosen_temp}:SYSFS"
                        return 0
                    fi
                fi
            fi
        done
    done

    # --------------------------------------------------------------------------
    # Tier 4: Diagnostic status reporting
    # --------------------------------------------------------------------------
    if [[ ${EUID} -ne 0 ]]; then
        echo "N/A:NO_ROOT"
    elif ! command -v smartctl >/dev/null 2>&1; then
        echo "N/A:NO_SMARTCTL"
    else
        echo "N/A:NO_SENSOR"
    fi
    return 0
}

# ------------------------------------------------------------------------------
# 5. Device Discovery & Metric Compilation
# ------------------------------------------------------------------------------
if ! command -v lsblk >/dev/null 2>&1; then
    echo "[-] Error: 'lsblk' utility not found. Please install util-linux." >&2
    exit 1
fi

declare -a DISK_RECORDS=()
HAS_MISSING_SMARTCTL=false
HAS_MISSING_ROOT=false

while IFS= read -r blk_line; do
    [[ -z "${blk_line}" ]] && continue

    NAME=""
    TYPE=""
    MODEL=""
    TRAN=""
    SUBSYSTEMS=""
    eval "${blk_line}"

    [[ "${TYPE}" != "disk" ]] && continue

    is_virt=false
    if is_virtual_disk "${NAME}" "${MODEL}" "${SUBSYSTEMS}" "${TRAN}"; then
        is_virt=true
        [[ "${HIDE_VIRTUAL}" == "true" ]] && continue
    fi

    clean_model="$(echo "${MODEL:-}" | xargs)"
    if [[ -z "${clean_model}" || ! "${clean_model}" =~ [[:alpha:]] ]]; then
        if [[ -r "/sys/block/${NAME}/device/model" ]]; then
            clean_model="$(cat "/sys/block/${NAME}/device/model" 2>/dev/null | xargs || true)"
        fi
    fi
    if [[ -z "${clean_model}" || ! "${clean_model}" =~ [[:alpha:]] ]]; then
        clean_model="Generic Disk"
    fi

    bus_type="${TRAN:-}"
    if [[ -z "${bus_type}" ]]; then
        if [[ "${NAME}" =~ ^nvme ]]; then
            bus_type="nvme"
        elif [[ "${is_virt}" == "true" ]]; then
            bus_type="virtual"
        else
            bus_type="sata"
        fi
    fi

    temp_result="$(get_disk_temperature "${NAME}" "${is_virt}")"
    temp_val="${temp_result%%:*}"
    temp_src="${temp_result##*:}"

    status="NORMAL"
    if [[ "${is_virt}" == "true" ]]; then
        status="VIRTUAL"
    elif [[ "${temp_val}" =~ ^[0-9]+$ ]]; then
        if [[ ${temp_val} -ge ${CRIT_TEMP} ]]; then
            status="CRITICAL"
        elif [[ ${temp_val} -ge ${WARN_TEMP} ]]; then
            status="WARNING"
        else
            status="NORMAL"
        fi
    else
        status="${temp_src}"
        if [[ "${temp_src}" == "NO_SMARTCTL" ]]; then
            HAS_MISSING_SMARTCTL=true
        elif [[ "${temp_src}" == "NO_ROOT" ]]; then
            HAS_MISSING_ROOT=true
        fi
    fi

    DISK_RECORDS+=("${NAME}|${bus_type}|${temp_val}|${status}|${clean_model}|${is_virt}")

done < <(lsblk -d -P -o NAME,TYPE,MODEL,TRAN,SUBSYSTEMS 2>/dev/null)

# ------------------------------------------------------------------------------
# 6. JSON Output Generation
# ------------------------------------------------------------------------------
if [[ "${OUTPUT_JSON}" == "true" ]]; then
    json_entries=()
    for rec in "${DISK_RECORDS[@]}"; do
        IFS='|' read -r d_name d_bus d_temp d_status d_model d_virt <<< "${rec}"

        temp_json="null"
        if [[ "${d_temp}" =~ ^[0-9]+$ ]]; then
            temp_json="${d_temp}"
        fi

        json_entries+=("    {
      \"device\": \"/dev/${d_name}\",
      \"name\": \"${d_name}\",
      \"bus\": \"${d_bus}\",
      \"temperature_c\": ${temp_json},
      \"status\": \"${d_status}\",
      \"model\": \"${d_model}\",
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
# 7. Tabular Terminal Output Generation
# ------------------------------------------------------------------------------
HOSTNAME_TAG="$(get_safe_hostname)"

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
echo "================================================================================"
printf " Storage Device Temperature Report: [%s]\n" "${HOSTNAME_TAG}"
echo "================================================================================"
printf "%-16s %-8s %-10s %-12s %s\n" "Device" "Bus" "Temp" "Status" "Model"
echo "--------------------------------------------------------------------------------"

if [[ ${#DISK_RECORDS[@]} -eq 0 ]]; then
    echo "No matching storage block devices detected."
else
    for rec in "${DISK_RECORDS[@]}"; do
        IFS='|' read -r d_name d_bus d_temp d_status d_model d_virt <<< "${rec}"

        dev_label="/dev/${d_name}"

        temp_str="N/A"
        color_start="${C_RESET}"

        if [[ "${d_temp}" =~ ^[0-9]+$ ]]; then
            temp_str="${d_temp} C"
            if [[ "${d_status}" == "CRITICAL" ]]; then
                color_start="${C_RED}"
            elif [[ "${d_status}" == "WARNING" ]]; then
                color_start="${C_YELLOW}"
            else
                color_start="${C_GREEN}"
            fi
        elif [[ "${d_status}" == "VIRTUAL" ]]; then
            color_start="${C_GRAY}"
        elif [[ "${d_status}" =~ (NO_ROOT|NO_SMARTCTL) ]]; then
            color_start="${C_YELLOW}"
        fi

        printf "%-16s %-8s ${color_start}%-10s %-12s${C_RESET} %s\n" \
            "${dev_label}" "${d_bus}" "${temp_str}" "${d_status}" "${d_model}"
    done
fi

echo "================================================================================"

# Helpful diagnostic guidance
if [[ "${HAS_MISSING_SMARTCTL}" == "true" ]]; then
    echo ""
    echo "[*] Notice: 'smartctl' is not installed. To query physical disk SMART sensors:"
    if [[ -f /etc/debian_version ]]; then
        echo "    Run: sudo apt-get update && sudo apt-get install -y smartmontools"
    elif [[ -f /etc/redhat-release ]]; then
        echo "    Run: sudo dnf install -y smartmontools"
    else
        echo "    Install 'smartmontools' via your distribution package manager."
    fi
fi

if [[ "${HAS_MISSING_ROOT}" == "true" ]]; then
    echo ""
    echo "[*] Notice: Running as unprivileged user (${USER:-non-root})."
    echo "    Re-run via sudo ('sudo $(basename "$0")') to unlock hardware SMART queries."
fi

echo ""
