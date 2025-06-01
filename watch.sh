#!/bin/bash

# devops/watch.sh
# Watches the Malfred service logs.
# Tries to run locally if the service is detected, otherwise SSHes to a remote server.
# Configuration is sourced from .devops.env

set -e # Exit immediately if a command fails (but we'll handle journalctl interrupt)

# Determine the directory where this script resides to locate the .env file.
SCRIPT_DIR_ENV=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEVOPS_ENV_FILE="${SCRIPT_DIR_ENV}/.devops.env"

# Check if the .devops.env file exists and source it.
if [ -f "$DEVOPS_ENV_FILE" ]; then
    set -a
    source "$DEVOPS_ENV_FILE"
    set +a
else
    echo "[ERROR] DevOps environment file not found: $DEVOPS_ENV_FILE"
    echo "[INFO]  Please ensure it exists in the same directory as this script (devops/)"
    echo "[INFO]  and contains SERVICE_NAME, LOG_LINES_TO_SHOW_WATCH, and DEFAULT_VPS_USER_HOST_PORT."
    exit 1
fi

# Validate that necessary variables were loaded
if [ -z "$SERVICE_NAME" ] || [ -z "$LOG_LINES_TO_SHOW_WATCH" ] || [ -z "$DEFAULT_VPS_USER_HOST_PORT" ]; then
    echo "[ERROR] One or more required variables (SERVICE_NAME, LOG_LINES_TO_SHOW_WATCH, DEFAULT_VPS_USER_HOST_PORT) not set in $DEVOPS_ENV_FILE."
    exit 1
fi

# --- Global Variables for remote connection (populated if needed) ---
IDENTITY_FILE_ARG=""
VPS_USER=""
VPS_HOST=""
VPS_PORT_ARG_SSH="" # For ssh -p option
SSH_CMD_BASE=""     # Base ssh command string

# --- Helper Functions ---
log_info() {
    echo "[INFO] $1"
}

log_error() {
    echo "[ERROR] $1" >&2
}

usage() {
    echo "Usage: $0 [-i /path/to/identity_file]"
    echo ""
    echo "Streams logs for the '${SERVICE_NAME}' service."
    echo "If the service is found locally, it shows local logs."
    echo "Otherwise, it attempts to connect to '${DEFAULT_VPS_USER_HOST_PORT}' to show logs."
    echo ""
    echo "Options (primarily for remote connection):"
    echo "  -i <identity_file>  Path to SSH private key for authentication if connecting remotely."
    echo ""
    echo "Example (try local first, then remote if local fails):"
    echo "  $0"
    echo "Example (if providing specific key for remote attempt):"
    echo "  $0 -i ~/.ssh/custom_vps_key"
    exit 1
}

# Function to parse VPS details
parse_vps_details() {
    local vps_address="$1" # Expects DEFAULT_VPS_USER_HOST_PORT
    if [[ ! "$vps_address" =~ ^[^@]+@ ]]; then
        log_error "Invalid VPS address format in script config: ${vps_address}. Expected user@host[:port]."
        exit 1
    fi

    VPS_USER="${vps_address%%@*}"
    local host_port_part="${vps_address#*@}"

    if [[ "$host_port_part" =~ : ]]; then
        VPS_HOST="${host_port_part%%:*}"
        local port="${host_port_part#*:}"
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            log_error "Invalid port number in script config: $port"; exit 1;
        fi
        VPS_PORT_ARG_SSH="-p ${port}"
    else
        VPS_HOST="$host_port_part"
    fi

    if [ -z "$VPS_USER" ] || [ -z "$VPS_HOST" ]; then
        log_error "Could not parse user or host from script config VPS address."; exit 1;
    fi
    # -t option forces pseudo-terminal allocation, crucial for `journalctl -f` over SSH
    SSH_CMD_BASE="ssh -t ${IDENTITY_FILE_ARG} ${VPS_PORT_ARG_SSH}"
}

# --- Main Script Logic ---

# Parse options for identity file
while getopts ":i:" opt; do
    case ${opt} in
        i)
            IDENTITY_FILE_ARG="-i ${OPTARG}"
            if [ ! -f "${OPTARG}" ]; then log_error "Identity file not found: ${OPTARG}"; exit 1; fi
            ;;
        \?)
            log_error "Invalid option: -${OPTARG}"
            usage
            ;;
        :)
            log_error "Option -${OPTARG} requires an argument."
            usage
            ;;
    esac
done
shift $((OPTIND -1)) # Remove parsed options from arguments

# Ensure no extra positional arguments are passed
if [ "$#" -ne 0 ]; then
    log_error "This script does not accept positional arguments after options."
    usage
fi

# Attempt to detect if the service is running locally
IS_LOCAL_SERVER=false
if command -v systemctl &> /dev/null; then
    # Check if the service unit file is known to systemd on this machine
    if systemctl list-unit-files --type=service | grep -q "^${SERVICE_NAME}\.service"; then
        IS_LOCAL_SERVER=true
        log_info "Service '${SERVICE_NAME}' appears to be configured locally."
    else
        log_info "Service '${SERVICE_NAME}' not found in local systemd unit files."
    fi
else
    log_info "systemctl command not found. Assuming this is not the target server."
fi

if $IS_LOCAL_SERVER; then
    log_info "Watching local logs for service: ${SERVICE_NAME}"
    log_info "Displaying last ${LOG_LINES_TO_SHOW_WATCH} lines and following. Press Ctrl+C to stop watching."
    echo "------------------------- LOCAL LOGS START -------------------------"
    
    # Use a subshell and ignore its exit code if it's from Ctrl+C (SIGINT)
    ( sudo journalctl -u "${SERVICE_NAME}" -n "${LOG_LINES_TO_SHOW_WATCH}" -f )
    # shellcheck disable=SC2181 # $? is valid here
    if [ $? -eq 130 ]; then # 130 is typically the exit code for SIGINT (Ctrl+C)
        echo # Newline after Ctrl+C
        log_info "Local log watching interrupted by user (Ctrl+C)."
    elif [ $? -ne 0 ]; then
        log_error "Local journalctl command failed or stream interrupted with an error."
    fi

    echo "-------------------------- LOCAL LOGS END --------------------------"
    log_info "Stopped watching local logs."
else
    log_info "Attempting to connect to remote VPS: ${DEFAULT_VPS_USER_HOST_PORT} to watch logs."
    
    parse_vps_details "$DEFAULT_VPS_USER_HOST_PORT" # Sets up VPS_USER, VPS_HOST, SSH_CMD_BASE

    log_info "Connecting to ${VPS_USER}@${VPS_HOST}..."
    log_info "Displaying last ${LOG_LINES_TO_SHOW_WATCH} lines and following. Press Ctrl+C to stop watching."
    echo "------------------------- REMOTE LOGS START -------------------------"

    remote_log_command="sudo journalctl -u ${SERVICE_NAME} -n ${LOG_LINES_TO_SHOW_WATCH} -f"

    # Execute the command via SSH.
    ( ${SSH_CMD_BASE} "${VPS_USER}@${VPS_HOST}" -- "${remote_log_command}" )
    # shellcheck disable=SC2181
    if [ $? -eq 130 ] || [ $? -eq 255 ]; then # SSH often exits with 255 on remote Ctrl+C
        echo # Newline after Ctrl+C
        log_info "Remote log watching interrupted by user (Ctrl+C) or SSH session ended."
    elif [ $? -ne 0 ]; then
        log_error "SSH command failed or connection to remote server lost with an error."
    fi
    
    echo "-------------------------- REMOTE LOGS END --------------------------"
    log_info "Stopped watching remote logs."
fi

exit 0
