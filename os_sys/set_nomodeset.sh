#!/usr/bin/env bash
# ----------------------------------------------
# set_nomodeset.sh
# v1.0.1xg  2025/12/15  XdG / MIS Center
# ----------------------------------------------
# Overview: 
#   Ensures 'nomodeset' is set correctly in GRUB for headless servers.
#   This parameter prevents kernel mode setting (KMS) video drivers from loading, 
#   forcing the system to use BIOS modes. This is often necessary for 
#   server hardware compatibility or remote console access.
#
# Objectives:
#   1. Detect the operating system family (RHEL vs Debian based).
#   2. Safely inject 'nomodeset' into GRUB_CMDLINE_LINUX in /etc/default/grub.
#   3. Regenerate the GRUB bootloader configuration.
# ----------------------------------------------

# --- Configuration Variables ---
GRUB_CONFIG_FILE="/etc/default/grub"
OS_RELEASE_FILE="/etc/os-release"
UPDATE_COMMAND=""
OS_FAMILY=""

# --- Function Definitions ---

# Function: check_error
# Description: Checks the exit status of the previous command ($?).
#              If non-zero (failure), prints an error message and terminates the script.
# Arguments: $1 - Error message to display.
check_error() {
    if [ $? -ne 0 ]; then
        echo "ERROR: $1" >&2
        exit 1
    fi
}

# Function: detect_os_family
# Description: Identifies the OS distribution to determine the correct GRUB update command.
#              Parses /etc/os-release for ID and ID_LIKE fields.
#              Sets global variables: OS_FAMILY, UPDATE_COMMAND.
detect_os_family() {
    # Check for required configuration files using the constant variable
    if [ ! -f "$GRUB_CONFIG_FILE" ] || [ ! -f "$OS_RELEASE_FILE" ]; then
        check_error "Required files ($GRUB_CONFIG_FILE or $OS_RELEASE_FILE) not found. Is this a Linux system using GRUB?"
    fi

    # Source OS variables reliably using the constant variable
    # shellcheck disable=SC1090 # OS_RELEASE_FILE defaults to /etc/os-release at runtime
    source "$OS_RELEASE_FILE"

    # Use a case statement for clear and maintainable OS family detection
    # Checks both ID_LIKE and ID for reliable detection
    case "$ID_LIKE $ID" in
        # RHEL Family (AlmaLinux, Rocky, CentOS, RHEL, Fedora)
        *rhel*|*centos*|*almalinux*|*rocky*|*fedora*)
            OS_FAMILY="RHEL"
            UPDATE_COMMAND="grub2-mkconfig -o /boot/grub2/grub.cfg"
            ;;
        # Debian Family (Ubuntu, Debian)
        *debian*|*ubuntu*)
            OS_FAMILY="DEBIAN"
            UPDATE_COMMAND="update-grub"
            ;;
        *)
            check_error "Could not reliably determine OS family (RHEL/DEBIAN) from $OS_RELEASE_FILE."
            ;;
    esac
    echo "--- Detected OS Family: $OS_FAMILY ---"
}

# Function: apply_nomodeset
# Description: Modifies the GRUB config file to add 'nomodeset' and applies changes.
#              Uses sed for in-place text manipulation.
apply_nomodeset() {
    echo "Processing $GRUB_CONFIG_FILE..."

    # 1. Ensure Idempotency: 
    #    Remove any existing 'nomodeset' occurrences to prevent duplicates (e.g., "nomodeset nomodeset").
    #    Regex matches word boundary \bnomodeset\b with optional surrounding whitespace.
	cp -af "$GRUB_CONFIG_FILE" "$GRUB_CONFIG_FILE.$(date '+%Y%m%d-%H%M%S')"
    sed -i 's/\s*\bnomodeset\b\s*//g' "$GRUB_CONFIG_FILE"
    check_error "Failed to remove previous 'nomodeset' entries."

    # 2. Inject 'nomodeset':
    #    Insert 'nomodeset' at the beginning of the GRUB_CMDLINE_LINUX value.
    #    Target line: Begins with GRUB_CMDLINE_LINUX=
    #    Substitution: Replaces the first equals sign and quote (=") with (="nomodeset ).
    #    Note: This assumes the value is quoted (standard in most distributions).
    sed -i '/^GRUB_CMDLINE_LINUX=/s|="|="nomodeset |' "$GRUB_CONFIG_FILE"
    check_error "Failed to insert 'nomodeset' into GRUB_CMDLINE_LINUX."
    
    echo "Inserted 'nomodeset' into GRUB_CMDLINE_LINUX."

    # 3. Regenerate Bootloader Config:
    #    Executes the command identified in detect_os_family to write changes to /boot.
    echo "Running OS-specific GRUB update command: $UPDATE_COMMAND"
    $UPDATE_COMMAND
    check_error "GRUB update command failed ($UPDATE_COMMAND). Check command output."

    echo "GRUB configuration updated successfully."
    echo "The change will take effect on the next reboot."
}

# --- Main Execution ---

# Pre-flight Check: Ensure script is run as root (EUID 0)
if [ "$EUID" -ne 0 ]; then
    echo "Please run this script with sudo (e.g., sudo ./set_nomodeset.sh)."
    exit 1
fi

# Set the execution environment to root's environment for subsequent commands
detect_os_family
apply_nomodeset
