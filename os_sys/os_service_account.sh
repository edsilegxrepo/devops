#!/bin/bash
# =============================================================================
# FILE: os_service_account.sh
# VERSION: 1.0.0
# DATE: 2026-06-16
#
# OBJECTIVE:
#   Create an unprivileged OS service account for compliance audit automation.
#   This script provisions a dedicated service account with restricted privileges
#   to run scheduled compliance audit jobs (ga_compliance_audit.sh) against
#   GoAnywhere MFT database and configuration files.
#
# DESCRIPTION:
#   The script performs the following operations in sequence:
#   1. Validates all input parameters (account name, password, group, UID/GID)
#   2. Creates the primary group if it does not exist
#   3. Creates the service account with specified or auto-assigned UID
#   4. Configures home directory with restrictive permissions (700)
#   5. Sets password aging policy (no expiration for service accounts)
#   6. Configures .bash_profile to source global environment settings
#   7. Logs account creation to syslog for audit trail
#   8. Clears shell history to protect password from exposure
#
# SECURITY CONSIDERATIONS:
#   - Password passed via command line is cleared from shell history
#   - Uses heredoc for chpasswd to avoid password exposure in process list
#   - Home directory locked to owner-only access (chmod 700)
#   - UID/GID restricted to non-system range (5000-50000)
#   - Minimum 32-character password enforced
#   - Account creation logged to syslog for compliance audit trail
#
# DATA FLOW:
#   Input:  Command-line arguments (account, password, group, optional UID/GID)
#   Output: Configured OS account with home directory and .bash_profile
#   Audit:  Syslog entry via logger command
#
# USAGE:
#   os_service_account.sh --account <account> --password <password> --group <group> [--uid <uid>] [--gid <gid>]
#
# EXAMPLE:
#   sudo ./os_service_account.sh --account myuser --password 'MyStr0ngP@ssw0rd!WithExtra12Chars' --group gfautomation --uid 5020 --gid 5010
#
# REQUIREMENTS:
#   - Must be run as root (or via sudo)
#   - Group will be created if it does not exist
#   - Linux system with useradd, groupadd, chpasswd, chage commands
#
# EXIT CODES:
#   0   Success - account created and configured
#   1   Invalid arguments (missing, malformed, or out of range)
#   2   Not running as root
#   3   Account creation failed (e.g., account already exists)
#
# DEPENDENCIES:
#   - useradd, groupadd (shadow-utils package)
#   - chpasswd, chage (shadow-utils package)
#   - logger (util-linux package)
#   - getent (glibc-common package)
#   - sed (sed package)
# =============================================================================

set -o errexit -o pipefail -o nounset

# =============================================================================
# SHELL OPTIONS AND UMASK
# =============================================================================
# errexit  - Exit immediately if a command exits with non-zero status
# pipefail - Pipeline returns the exit status of the last command to fail
# nounset  - Treat unset variables as an error
#
# umask 027 ensures secure default permissions:
#   - Directories: 750 (rwxr-x---)
#   - Files: 640 (rw-r-----)
# =============================================================================
umask 027

# =============================================================================
# CONSTANTS
# =============================================================================
# Script metadata
readonly SCRIPT_NAME="os_service_account.sh"
# shellcheck disable=SC2034  # SCRIPT_VERSION reserved for future --version flag
readonly SCRIPT_VERSION="1.0.0"

# Security constraints - adjust these values per organizational policy
readonly MIN_PASSWORD_LENGTH=32   # Minimum password length (compliance requirement)
readonly MIN_ID_NUMBER=5000       # Minimum UID/GID to avoid system account range
readonly MAX_ID_NUMBER=50000      # Maximum UID/GID to stay within reserved range

# =============================================================================
# GLOBAL VARIABLES (populated from command-line arguments)
# =============================================================================
ACCOUNT=""      # Service account username
PASSWORD=""     # Account password (cleared from history after use)
GROUP=""        # Primary group name
UID_NUMBER=""   # User ID number (empty = use next available)
GID_NUMBER=""   # Group ID number (empty = use next available)

# =============================================================================
# FUNCTION: _usage
# PURPOSE:  Display help message with usage instructions and examples
# ARGS:     $1 - Exit code (optional, defaults to 0)
# RETURNS:  Exits script with specified code
# =============================================================================
_usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} --account <account> --password <password> --group <group> [options]

Options:
  --account <name>    Service account name (required)
  --password <pass>   Account password - 32 char minimum (required)
  --group <name>      Primary group name (required, created if not exists)
  --uid <number>      User ID number (optional, next available if not specified)
  --gid <number>      Group ID number (optional, next available if not specified)
  -h, --help          Show this help message

Example:
  # With explicit UID/GID
  sudo ./${SCRIPT_NAME} --account myuser --password 'MyStr0ngP@ssw0rd!WithExtra12Chars' --group gfautomation --uid 5020 --gid 5010

  # With auto-assigned UID/GID
  sudo ./${SCRIPT_NAME} --account myuser --password 'MyStr0ngP@ssw0rd!WithExtra12Chars' --group gfautomation

EOF
    exit "${1:-0}"
}

# =============================================================================
# FUNCTION: _error
# PURPOSE:  Display error message to stderr and exit with specified code
# ARGS:     $1 - Error message
#           $2 - Exit code (optional, defaults to 1)
# RETURNS:  Exits script with specified code
# =============================================================================
_error() {
    echo "ERROR: $1" >&2
    exit "${2:-1}"
}

# =============================================================================
# FUNCTION: _info
# PURPOSE:  Display informational message to stdout
# ARGS:     $1 - Message to display
# RETURNS:  None
# =============================================================================
_info() {
    echo "[INFO] $1"
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================
# Parses command-line arguments using a while loop with case statement.
# Supports both required (--account, --password, --group) and optional
# (--uid, --gid) parameters. Uses shift 2 to consume flag and value pairs.
# =============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --account)
            ACCOUNT="$2"
            shift 2
            ;;
        --password)
            PASSWORD="$2"
            shift 2
            ;;
        --group)
            GROUP="$2"
            shift 2
            ;;
        --uid)
            UID_NUMBER="$2"
            shift 2
            ;;
        --gid)
            GID_NUMBER="$2"
            shift 2
            ;;
        -h|--help)
            _usage 0
            ;;
        *)
            _error "Unknown option: $1" 1
            ;;
    esac
done

# =============================================================================
# INPUT VALIDATION
# =============================================================================
# Validates all inputs before making any system changes. Checks include:
# - Required arguments are present
# - Password meets minimum length requirement
# - Script is running with root privileges
# - Account/group names follow POSIX naming conventions
# - UID/GID values are numeric and within allowed range
# =============================================================================

# --- Required arguments check ---
[[ -z "${ACCOUNT}" ]] && _error "Missing required argument: --account" 1
[[ -z "${PASSWORD}" ]] && _error "Missing required argument: --password" 1
[[ -z "${GROUP}" ]] && _error "Missing required argument: --group" 1

# --- Password length validation (security requirement) ---
if [[ ${#PASSWORD} -lt ${MIN_PASSWORD_LENGTH} ]]; then
    _error "Password must be at least ${MIN_PASSWORD_LENGTH} characters" 1
fi

# --- Root privilege check ---
# shellcheck disable=SC2312  # id -u always succeeds
if [[ "$(id -u)" -ne 0 ]]; then
    _error "This script must be run as root" 2
fi

# --- Account name validation ---
# POSIX username: starts with lowercase letter or underscore,
# followed by lowercase letters, digits, underscores, or dashes
if [[ ! "${ACCOUNT}" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    _error "Invalid account name: '${ACCOUNT}'. Must be lowercase alphanumeric with _ or -" 1
fi

# --- Group name validation (same rules as account name) ---
if [[ ! "${GROUP}" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    _error "Invalid group name: '${GROUP}'. Must be lowercase alphanumeric with _ or -" 1
fi

# --- UID validation (if specified) ---
# Must be numeric and within the non-system account range
if [[ -n "${UID_NUMBER}" ]]; then
    if [[ ! "${UID_NUMBER}" =~ ^[0-9]+$ ]]; then
        _error "Invalid UID: '${UID_NUMBER}'. Must be numeric" 1
    fi
    if [[ "${UID_NUMBER}" -lt ${MIN_ID_NUMBER} || "${UID_NUMBER}" -gt ${MAX_ID_NUMBER} ]]; then
        _error "UID '${UID_NUMBER}' out of range. Must be ${MIN_ID_NUMBER}-${MAX_ID_NUMBER} (non-system accounts)" 1
    fi
fi

# --- GID validation (if specified) ---
# Must be numeric and within the non-system group range
if [[ -n "${GID_NUMBER}" ]]; then
    if [[ ! "${GID_NUMBER}" =~ ^[0-9]+$ ]]; then
        _error "Invalid GID: '${GID_NUMBER}'. Must be numeric" 1
    fi
    if [[ "${GID_NUMBER}" -lt ${MIN_ID_NUMBER} || "${GID_NUMBER}" -gt ${MAX_ID_NUMBER} ]]; then
        _error "GID '${GID_NUMBER}' out of range. Must be ${MIN_ID_NUMBER}-${MAX_ID_NUMBER} (non-system groups)" 1
    fi
fi

# =============================================================================
# GROUP CREATION
# =============================================================================
# Creates the primary group for the service account if it doesn't exist.
# Uses getent to check group existence (works with local and LDAP/NIS).
# If GID is specified, creates group with that ID; otherwise auto-assigns.
# =============================================================================
if ! getent group "${GROUP}" >/dev/null 2>&1; then
    if [[ -n "${GID_NUMBER}" ]]; then
        _info "Creating group: ${GROUP} (GID: ${GID_NUMBER})"
        groupadd -g "${GID_NUMBER}" "${GROUP}"
    else
        _info "Creating group: ${GROUP} (GID: auto-assigned)"
        groupadd "${GROUP}"
    fi
else
    _info "Group already exists: ${GROUP}"
fi

# =============================================================================
# ACCOUNT EXISTENCE CHECK
# =============================================================================
# Prevents overwriting or modifying an existing account.
# Uses 'id' command which checks both local and directory services.
# =============================================================================
if id "${ACCOUNT}" >/dev/null 2>&1; then
    _error "Account already exists: ${ACCOUNT}" 3
fi

# =============================================================================
# SERVICE ACCOUNT CREATION
# =============================================================================
# Creates the service account using useradd with the following options:
#   -c  Comment/GECOS field (description)
#   -g  Primary group
#   -u  User ID (if specified)
#   -m  Create home directory
#   -s  Login shell (/bin/bash for interactive troubleshooting)
# =============================================================================
if [[ -n "${UID_NUMBER}" ]]; then
    _info "Creating service account: ${ACCOUNT} (UID: ${UID_NUMBER}, Group: ${GROUP})"
    useradd \
        -c "Compliance Audit Service Account" \
        -g "${GROUP}" \
        -u "${UID_NUMBER}" \
        -m \
        -s /bin/bash \
        "${ACCOUNT}"
else
    _info "Creating service account: ${ACCOUNT} (UID: auto-assigned, Group: ${GROUP})"
    useradd \
        -c "Compliance Audit Service Account" \
        -g "${GROUP}" \
        -m \
        -s /bin/bash \
        "${ACCOUNT}"
fi

# =============================================================================
# HOME DIRECTORY SECURITY
# =============================================================================
# Restricts home directory access to owner only (chmod 700).
# This prevents other users from reading configuration files,
# credentials, or audit output that may be stored here.
# =============================================================================
_info "Setting home directory permissions: /home/${ACCOUNT}"
chmod 700 "/home/${ACCOUNT}"
chown -R "${ACCOUNT}:${GROUP}" "/home/${ACCOUNT}"

# =============================================================================
# PASSWORD AGING POLICY
# =============================================================================
# Configures password aging for service account (no expiration).
# chage options:
#   -I -1     Disable inactive period (no lock after password expiry)
#   -m 0      Minimum days between password changes (0 = anytime)
#   -M 99999  Maximum days password is valid (~273 years = never)
#   -E -1     Disable account expiration date
#
# NOTE: This is appropriate for service accounts that authenticate
# programmatically. Interactive accounts should have different policies.
# =============================================================================
_info "Configuring password policy (no expiration)"
chage -I -1 -m 0 -M 99999 -E -1 "${ACCOUNT}"

# =============================================================================
# PASSWORD ASSIGNMENT
# =============================================================================
# Sets the account password using chpasswd with heredoc (<<<) to avoid
# exposing the password in the process list (ps aux). The pipe method
# "echo user:pass | chpasswd" briefly shows the password in process args.
# =============================================================================
_info "Setting account password"
chpasswd <<< "${ACCOUNT}:${PASSWORD}"

# =============================================================================
# BASH PROFILE CONFIGURATION
# =============================================================================
# Configures the user's .bash_profile for interactive shell sessions.
# This file is sourced when the user logs in via SSH or console.
#
# The profile:
# 1. Sources ~/.bashrc for aliases and functions
# 2. Adds $HOME/bin to PATH for user-specific scripts
# 3. Sources /opt/scripts/settings.sh for global environment variables
#    (e.g., database credentials, file paths) if the file exists
# =============================================================================
BASH_PROFILE="/home/${ACCOUNT}/.bash_profile"
SETTINGS_FILE="/opt/scripts/settings.sh"

_info "Configuring .bash_profile"

# --- Create default .bash_profile if it doesn't exist ---
if [[ ! -f "${BASH_PROFILE}" ]]; then
    cat > "${BASH_PROFILE}" << 'EOF'
# .bash_profile

# Get the aliases and functions
if [ -f ~/.bashrc ]; then
    . ~/.bashrc
fi

# User specific environment and startup programs
PATH=$PATH:$HOME/bin
export PATH
EOF
    chown "${ACCOUNT}:${GROUP}" "${BASH_PROFILE}"
    chmod 644 "${BASH_PROFILE}"
fi

# --- Add global environment source if settings.sh exists ---
# Only adds the source line if:
# 1. The settings file exists on this system
# 2. The source line isn't already in .bash_profile (idempotent)
if [[ -f "${SETTINGS_FILE}" ]]; then
    if ! grep -q "source ${SETTINGS_FILE}" "${BASH_PROFILE}" 2>/dev/null; then
        {
            echo ""
            echo "# Global Environment"
            echo "if [[ -f ${SETTINGS_FILE} ]]; then source ${SETTINGS_FILE}; fi"
        } >> "${BASH_PROFILE}"
        _info "Added settings.sh source to .bash_profile"
    else
        _info "settings.sh source already present in .bash_profile"
    fi
else
    _info "Skipping settings.sh (${SETTINGS_FILE} not found)"
fi

# =============================================================================
# VERIFICATION AND SUMMARY
# =============================================================================
# Displays a summary of the created account for operator verification.
# Retrieves actual UID/GID from the system to confirm creation,
# displays password aging policy, and shows group membership.
# =============================================================================
echo ""
echo "============================================================"
echo "  Service Account Created Successfully"
echo "============================================================"
echo ""
ACTUAL_UID=$(id -u "${ACCOUNT}")
ACTUAL_GID=$(id -g "${ACCOUNT}")
echo "Account Details:"
echo "  Username:   ${ACCOUNT}"
echo "  UID:        ${ACTUAL_UID}"
echo "  Group:      ${GROUP}"
echo "  GID:        ${ACTUAL_GID}"
echo "  Home:       /home/${ACCOUNT}"
echo "  Shell:      /bin/bash"
echo ""
echo "Password Aging:"
chage -l "${ACCOUNT}"
echo ""
echo "Group Membership:"
groups "${ACCOUNT}"
echo ""
echo "============================================================"

# =============================================================================
# AUDIT LOGGING
# =============================================================================
# Logs account creation to syslog for compliance audit trail.
# Captures: account name, UID, executing user, and sudo user if applicable.
# Log entry can be found in /var/log/messages or /var/log/syslog.
# =============================================================================
logger -t "${SCRIPT_NAME}" "Service account '${ACCOUNT}' (UID: ${ACTUAL_UID}) created by $(whoami) (SUDO_USER=${SUDO_USER:-N/A})"

# =============================================================================
# SECURITY: SHELL HISTORY CLEANUP
# =============================================================================
# Removes this command from shell history to protect the password that was
# passed as a command-line argument. Clears from both:
# 1. Root's history (when run directly as root)
# 2. Sudo user's history (when run via sudo)
#
# NOTE: This is a best-effort cleanup. The password may still be visible in:
# - Process accounting logs (if enabled)
# - Audit logs (auditd)
# - Screen recordings or terminal logs
# Consider using a secrets manager or prompting for password interactively
# in high-security environments.
# =============================================================================
_info "Clearing this command from shell history (security)"

# --- Clear root's history ---
HISTFILE="${HOME}/.bash_history"
if [[ -f "${HISTFILE}" ]]; then
    sed -i '/os_service_account/d' "${HISTFILE}" 2>/dev/null || true
    _info "Removed os_service_account entries from ${HISTFILE}"
fi

# --- Clear sudo user's history if applicable ---
# When run via "sudo ./os_service_account.sh ...", SUDO_USER contains the
# original user's username. Their history file may contain the command.
if [[ -n "${SUDO_USER:-}" ]]; then
    SUDO_HISTFILE="/home/${SUDO_USER}/.bash_history"
    if [[ -f "${SUDO_HISTFILE}" ]]; then
        sed -i '/os_service_account/d' "${SUDO_HISTFILE}" 2>/dev/null || true
        _info "Removed os_service_account entries from ${SUDO_HISTFILE}"
    fi
fi

exit 0
