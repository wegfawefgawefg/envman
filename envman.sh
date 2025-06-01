#!/bin/bash

# envman.sh - Simplified environment configuration manager
# Manages environment files on a remote VPS.
# Configuration is sourced from .devops.env.

# Determine the directory where this script resides to locate the .env file.
SCRIPT_DIR_ENV=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEVOPS_ENV_FILE="${SCRIPT_DIR_ENV}/.devops.env" # Using dot-prefixed .devops.env

# Check if the .devops.env file exists and source it.
if [ -f "$DEVOPS_ENV_FILE" ]; then
    set -a
    source "$DEVOPS_ENV_FILE"
    set +a
else
    echo "[ERROR] DevOps environment file not found: $DEVOPS_ENV_FILE"
    echo "[INFO]  Please ensure it exists in the same directory as this script (devops/)"
    echo "[INFO]  and contains necessary envman configurations."
    exit 1
fi

# Validate that necessary variables were loaded
REQUIRED_ENVMAN_VARS=(
    "DEFAULT_VPS_USER_HOST_PORT"
    "REMOTE_ENVMAN_CONFIG_BASE_DIR"
    "REMOTE_ENVMAN_LOG_FILE"
    "LOCAL_ENV_FILE_DEFAULT_NAME"
    "ENVMAN_SYMLINK_NAME"
    "ENVMAN_UNNAMED_PREFIX"
)
for var_name in "${REQUIRED_ENVMAN_VARS[@]}"; do
    if [ -z "${!var_name}" ]; then
        echo "[ERROR] Required envman variable '$var_name' is not set or empty in $DEVOPS_ENV_FILE."
        exit 1
    fi
done

# --- Internal Constants ---
TS_GLOB_SUFFIX="????_??_??_??_??_??.env"

# --- Global Variables (for script's runtime state) ---
GLOBAL_IDENTITY_FILE_ARG="" # For global -i option
VPS_USER=""
VPS_HOST=""
VPS_PORT_ARG_SSH=""
VPS_PORT_ARG_SCP=""
SSH_CMD_BASE=""
SCP_CMD_BASE=""

# --- Helper Functions ---
log_info() { echo "[INFO] $1"; }
log_error() { echo "[ERROR] $1" >&2; }
log_success() { echo "[SUCCESS] $1"; }
log_remote_stderr() {
    local line
    while IFS= read -r line; do echo "[REMOTE STDERR] $line" >&2; done
}

usage() {
    echo "Usage: $0 [-i /path/to/identity_file] <COMMAND> [COMMAND_ARGS...]"
    echo ""
    echo "Manages environment configurations on a remote VPS."
    echo "Server connection and paths are configured in '${DEVOPS_ENV_FILE}'."
    echo ""
    echo "Global Options:"
    echo "  -i <identity_file>    Path to SSH private key for authentication."
    echo ""
    echo "Commands:"
    echo "  save [nickname] [-i /path/to/input_file]"
    echo "                          Save a local file to VPS. If 'nickname' is provided,"
    echo "                          remote file is 'nickname_YYYY_MM_DD_HH_MM_SS.env'."
    echo "                          Otherwise, '${ENVMAN_UNNAMED_PREFIX}_YYYY_MM_DD_HH_MM_SS.env'."
    echo "                          If -i is not used, saves content from '${LOCAL_ENV_FILE_DEFAULT_NAME}'."
    echo "                          The '${ENVMAN_SYMLINK_NAME}' on remote is updated."
    echo ""
    echo "  load [target] [-o /path/to/output_file]"
    echo "                          Load a remote config. 'target' can be:"
    echo "                            (empty)             - Loads '${ENVMAN_SYMLINK_NAME}' (the absolute latest save)."
    echo "                            <nickname>          - Finds matching 'nickname_*.env' or 'nickname-*.env'."
    echo "                                                Loads the newest if multiple found."
    echo "                            <full_filename.env> - Loads the specific timestamped file."
    echo "                          If -o is not used, loads to local '${LOCAL_ENV_FILE_DEFAULT_NAME}'."
    echo ""
    echo "  ls [prefix_filter]      List remote configuration filenames."
    echo "  latest                  Show what the '${ENVMAN_SYMLINK_NAME}' symlink points to on remote."
    echo "  review [target]         Display content of a remote config. 'target' resolution is same as 'load'."
    echo ""
    exit 1
}

parse_default_vps_details() {
    if [[ "${DEFAULT_VPS_USER_HOST_PORT}" == "your_user@your_server.com" ]]; then
        log_error "FATAL: DEFAULT_VPS_USER_HOST_PORT in ${DEVOPS_ENV_FILE} is a placeholder. Please configure it."
        exit 1
    fi
    if [[ ! "${DEFAULT_VPS_USER_HOST_PORT}" =~ ^[^@]+@ ]]; then
        log_error "Invalid DEFAULT_VPS_USER_HOST_PORT format in ${DEVOPS_ENV_FILE}. Expected user@host[:port]."
        exit 1
    fi

    VPS_USER="${DEFAULT_VPS_USER_HOST_PORT%%@*}"
    local host_port_part="${DEFAULT_VPS_USER_HOST_PORT#*@}"

    if [[ "$host_port_part" =~ : ]]; then
        VPS_HOST="${host_port_part%%:*}"
        local port="${host_port_part#*:}"
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            log_error "Invalid port number in DEFAULT_VPS_USER_HOST_PORT: $port"; exit 1;
        fi
        VPS_PORT_ARG_SSH="-p ${port}"
        VPS_PORT_ARG_SCP="-P ${port}"
    else
        VPS_HOST="$host_port_part"
    fi

    if [ -z "$VPS_USER" ] || [ -z "$VPS_HOST" ]; then
        log_error "Could not parse user or host from DEFAULT_VPS_USER_HOST_PORT."; exit 1;
    fi

    SSH_CMD_BASE="ssh -T ${GLOBAL_IDENTITY_FILE_ARG} ${VPS_PORT_ARG_SSH}"
    SCP_CMD_BASE="scp -q ${GLOBAL_IDENTITY_FILE_ARG} ${VPS_PORT_ARG_SCP}"
}

remote_exec_interactive() {
    local remote_cmd_string="$1"
    if ! ${SSH_CMD_BASE} "${VPS_USER}@${VPS_HOST}" -- "${remote_cmd_string}"; then
        log_error "Remote command execution failed: ${remote_cmd_string}"
        return 1
    fi
    return 0
}

remote_exec_get_stdout() {
    local remote_cmd_string="$1"
    local output
    if ! output=$(${SSH_CMD_BASE} "${VPS_USER}@${VPS_HOST}" -- "${remote_cmd_string}" 2> >(log_remote_stderr)); then
        return 1
    fi
    echo -n "$output"
    return 0
}

remote_log() {
    local action="$1"
    local config_name_effective="$2"
    local details="$3"
    local local_user; local_user_tmp=$(whoami) || local_user_tmp="unknown_user"; local_user="$local_user_tmp"
    local timestamp; timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local log_message="${timestamp} - User: ${local_user} (envman.sh) - Action: ${action} - Config: '${config_name_effective}' - Details: ${details}"
    local quoted_log_message; quoted_log_message=$(printf "%s" "$log_message" | sed "s/'/'\\\\''/g; 1s/^/'/; \$s/\$/'/")
    local log_dir; log_dir=$(dirname "${REMOTE_ENVMAN_LOG_FILE}")
    local remote_log_cmd="sudo mkdir -p '${log_dir}' && echo ${quoted_log_message} | sudo tee -a '${REMOTE_ENVMAN_LOG_FILE}' >/dev/null"
    if ! remote_exec_get_stdout "${remote_log_cmd}"; then
        log_error "Failed to write to remote log. Log message was: ${log_message}"
    fi
}

calculate_hash() {
    local filepath="$1"
    if [ ! -f "$filepath" ]; then log_error "Hash: File '$filepath' not found."; return 1; fi
    sha256sum "$filepath" | awk '{print $1}'
}

get_formatted_timestamp() {
    date -u +"%Y_%m_%d_%H_%M_%S"
}
resolve_remote_target_path_and_name() {
    local requested_target="$1"
    local result_path_var="$2"
    local result_name_var="$3"
    local result_match_details_var="$4"
    local target_filepath=""
    local effective_name=""
    local match_details=""

    if [ -z "$requested_target" ] || [ "$requested_target" == "latest" ]; then
        target_filepath=$(remote_exec_get_stdout "sudo readlink -f '${REMOTE_ENVMAN_CONFIG_BASE_DIR}/${ENVMAN_SYMLINK_NAME}'")
        if [ $? -ne 0 ] || [ -z "$target_filepath" ] || [[ "$target_filepath" != "${REMOTE_ENVMAN_CONFIG_BASE_DIR}/"* ]]; then
            log_error "Could not resolve '${ENVMAN_SYMLINK_NAME}' symlink on remote, it is missing, or points outside config dir."
            eval "$result_match_details_var=\"error_symlink_resolve\""
            return 1
        fi
        effective_name=$(basename "$target_filepath")
        match_details="exact_latest"
    elif [[ "$requested_target" == *"_"${TS_GLOB_SUFFIX} ]] || [[ "$requested_target" == *"-"${TS_GLOB_SUFFIX} ]]; then
        target_filepath="${REMOTE_ENVMAN_CONFIG_BASE_DIR}/${requested_target}"
        effective_name="$requested_target"
        match_details="exact_fullname"
    else
        local find_cmd
        find_cmd="sudo find '${REMOTE_ENVMAN_CONFIG_BASE_DIR}' -maxdepth 1 -type f \\( -name '${requested_target}_${TS_GLOB_SUFFIX}' -o -name '${requested_target}-${TS_GLOB_SUFFIX}' \\) -printf '%f\\n'"
        local matched_files_str
        matched_files_str=$(remote_exec_get_stdout "$find_cmd")
        local find_exit_code=$?
        if [ "$find_exit_code" -ne 0 ]; then
            log_error "Error searching for remote configs with prefix '${requested_target}'."
            eval "$result_match_details_var=\"error_find_prefix\""
            return 1
        fi
        if [ -z "$matched_files_str" ]; then
            log_error "No remote config found for nickname prefix '${requested_target}_*.env' or '${requested_target}-*.env'."
            eval "$result_match_details_var=\"no_fuzzy_match\""
            return 1
        fi
        local -a matched_files_arr
        readarray -t matched_files_arr <<<"$matched_files_str"
        local num_matches=${#matched_files_arr[@]}
        if [ "$num_matches" -eq 1 ]; then
            effective_name="${matched_files_arr[0]}"
            target_filepath="${REMOTE_ENVMAN_CONFIG_BASE_DIR}/${effective_name}"
            match_details="single_fuzzy_match"
        else
            local sorted_matches_str
            sorted_matches_str=$(echo "$matched_files_str" | sort)
            effective_name=$(echo "$sorted_matches_str" | tail -n 1)
            target_filepath="${REMOTE_ENVMAN_CONFIG_BASE_DIR}/${effective_name}"
            local all_matches_space_separated
            all_matches_space_separated=$(echo "$sorted_matches_str" | tr '\n' ' ')
            all_matches_space_separated=${all_matches_space_separated%% }
            match_details="multiple_fuzzy_matches_newest_selected ${all_matches_space_separated}"
        fi
    fi
    if ! remote_exec_get_stdout "sudo test -f '${target_filepath}' && echo exists" | grep -q "exists"; then
        log_error "Resolved remote file '${target_filepath}' does not exist or is not a regular file."
        eval "$result_match_details_var=\"error_target_not_found_or_not_file\""
        return 1
    fi
    eval "$result_path_var=\"${target_filepath}\""
    eval "$result_name_var=\"${effective_name}\""
    eval "$result_match_details_var=\"${match_details}\""
    return 0
}

# --- Command Implementations ---

save_command() {
    local nickname_arg=""
    local source_local_file="$LOCAL_ENV_FILE_DEFAULT_NAME" # Default input file

    # Parse arguments for save_command: [nickname] [-i input_file]
    # Need to make OPTIND local for getopts within a function
    local OPTIND
    OPTIND=1 
    
    # Process options first
    while getopts ":i:" opt "$@"; do
        case $opt in
            i)
                source_local_file="$OPTARG"
                ;;
            \?)
                # This case means an unknown option was passed to 'save'
                # OR it's the nickname if it starts with '-'
                # We'll let the positional argument handling below catch the nickname.
                # If it's truly an unknown option, the script will error later or usage will be shown.
                # For robust POSIX, options should precede non-option arguments.
                # This getopts loop is primarily for the -i flag.
                # We'll reset OPTIND and re-evaluate positional args after this loop.
                # For now, if it's not -i, break and assume it's a positional arg.
                break # Stop option processing if it's not -i
                ;;
            :)
                log_error "save: Option -$OPTARG requires an argument." >&2
                echo "Usage: envman save [-i /path/to/input_file] [nickname]" >&2
                return 1
                ;;
        esac
    done
    shift $((OPTIND - 1)) # Remove parsed options (-i and its arg)

    # Remaining argument(s) should be the nickname (at most one)
    if [ "$#" -gt 1 ]; then
        log_error "save: Too many positional arguments. Expected [nickname] after options."
        echo "Usage: envman save [-i /path/to/input_file] [nickname]" >&2
        return 1
    elif [ "$#" -eq 1 ]; then
        nickname_arg="$1"
    fi
    # If $# is 0, nickname_arg remains empty (default behavior)

    log_info "Using source file: '${source_local_file}'"
    local file_prefix
    if [ -n "$nickname_arg" ]; then
        if [[ ! "$nickname_arg" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
            log_error "Invalid nickname. Use alphanumeric characters, underscores, dashes, or dots."
            return 1
        fi
        file_prefix="$nickname_arg"
    else
        file_prefix="$ENVMAN_UNNAMED_PREFIX"
    fi

    if [ ! -f "$source_local_file" ]; then
        log_error "Local source file '${source_local_file}' not found."
        return 1
    fi

    local content_hash; content_hash=$(calculate_hash "$source_local_file") || return 1
    local current_timestamp; current_timestamp=$(get_formatted_timestamp)
    local remote_timestamped_filename="${file_prefix}_${current_timestamp}.env"
    local remote_timestamped_filepath="${REMOTE_ENVMAN_CONFIG_BASE_DIR}/${remote_timestamped_filename}"
    local remote_symlink_filepath="${REMOTE_ENVMAN_CONFIG_BASE_DIR}/${ENVMAN_SYMLINK_NAME}"
    local temp_remote_filename="envman_upload_tmp_$(date +%s%N)_${remote_timestamped_filename}"
    local temp_remote_path="/tmp/${temp_remote_filename}"

    log_info "Uploading '${source_local_file}' to remote temporary location..."
    if ! ${SCP_CMD_BASE} "$source_local_file" "${VPS_USER}@${VPS_HOST}:${temp_remote_path}"; then
        log_error "SCP upload to temporary location failed."; return 1;
    fi

    local remote_setup_cmds_arr=(
        "sudo mkdir -p '${REMOTE_ENVMAN_CONFIG_BASE_DIR}'"
        "sudo mv '${temp_remote_path}' '${remote_timestamped_filepath}'"
        "sudo chown root:root '${remote_timestamped_filepath}'"
        "sudo chmod 640 '${remote_timestamped_filepath}'"
        "sudo rm -f '${remote_symlink_filepath}'"
        "sudo ln -s '${remote_timestamped_filename}' '${remote_symlink_filepath}'"
        "sudo chown -h root:root '${remote_symlink_filepath}'"
        "sudo rm -f '${temp_remote_path}'"
    )
    local combined_cmd; printf -v combined_cmd '%s && ' "${remote_setup_cmds_arr[@]}"; combined_cmd="${combined_cmd%% && }"

    log_info "Finalizing file and symlink on remote server..."
    if ! remote_exec_interactive "${combined_cmd}" >/dev/null; then
        log_error "Failed to finalize file and symlink on remote server."
        remote_exec_interactive "sudo rm -f '${temp_remote_path}' '${remote_timestamped_filepath}'" >/dev/null
        return 1
    fi
    
    remote_log "SAVE" "${remote_timestamped_filename} (symlinked by ${ENVMAN_SYMLINK_NAME})" \
               "Nickname: ${nickname_arg:-${ENVMAN_UNNAMED_PREFIX}}, Source: ${source_local_file}, Hash: ${content_hash}"
    log_success "Saved '${source_local_file}' to remote as '${remote_timestamped_filename}'. '${ENVMAN_SYMLINK_NAME}' now points to this file."
}


load_command() {
    local requested_target=""
    local output_file_path="$LOCAL_ENV_FILE_DEFAULT_NAME" # Default output file

    local OPTIND
    OPTIND=1

    # Process options first
    while getopts ":o:" opt "$@"; do
        case $opt in
            o)
                output_file_path="$OPTARG"
                ;;
            \?)
                # Similar to save, break and let positional arg handling take over.
                break 
                ;;
            :)
                log_error "load: Option -$OPTARG requires an argument." >&2
                echo "Usage: envman load [-o /path/to/output_file] [target]" >&2
                return 1
                ;;
        esac
    done
    shift $((OPTIND - 1)) # Remove parsed options

    # Remaining argument(s) should be the target (at most one)
    if [ "$#" -gt 1 ]; then
        log_error "load: Too many positional arguments. Expected [target] after options."
        echo "Usage: envman load [-o /path/to/output_file] [target]" >&2
        return 1
    elif [ "$#" -eq 1 ]; then
        requested_target="$1"
    fi
    # If $# is 0, requested_target remains empty (implies "latest")

    log_info "Using output file: '${output_file_path}'"
    local remote_source_path
    local effective_config_name_for_log
    local match_details_str

    if ! resolve_remote_target_path_and_name "$requested_target" \
                                             remote_source_path \
                                             effective_config_name_for_log \
                                             match_details_str; then
        remote_log "LOAD_FAIL" "${requested_target:-${ENVMAN_SYMLINK_NAME}}" "Resolution failed: ${match_details_str} for target local file ${output_file_path}"
        return 1
    fi
    
    if [[ "$match_details_str" == "single_fuzzy_match" ]]; then
        log_info "Single match found for '${requested_target}': '${effective_config_name_for_log}'. Loading it."
    elif [[ "$match_details_str" == "multiple_fuzzy_matches_newest_selected"* ]]; then
        log_info "Multiple matches found for '${requested_target}':"
        local all_matches_list="${match_details_str#multiple_fuzzy_matches_newest_selected }"
        for matched_file in $all_matches_list; do
            echo "  - ${matched_file}"
        done
        log_info "Loading the newest match: '${effective_config_name_for_log}'. To load a different specific version, use its full filename."
    fi

    local local_dir; local_dir=$(dirname "$output_file_path")
    if ! mkdir -p "$local_dir"; then
        log_error "Failed to create local directory '${local_dir}' for output file '${output_file_path}'."
        return 1
    fi
    
    log_info "Attempting to download '${effective_config_name_for_log}' from remote to '${output_file_path}'..."
    if ! ${SSH_CMD_BASE} "${VPS_USER}@${VPS_HOST}" -- "sudo cat '${remote_source_path}'" > "$output_file_path" 2> >(log_remote_stderr) ; then
        log_error "Failed to download file from VPS: ${remote_source_path} to ${output_file_path}"
        rm -f "$output_file_path"
        remote_log "LOAD_FAIL" "$effective_config_name_for_log" "Download failed from ${remote_source_path} to ${output_file_path}"
        return 1
    fi
    
    if [ ! -s "$output_file_path" ]; then
         if remote_exec_get_stdout "sudo test -s '${remote_source_path}' && echo has_content" | grep -q "has_content"; then
            log_error "Downloaded '${output_file_path}' is empty, but remote source '${remote_source_path}' has content. Download may have been interrupted."
            rm -f "$output_file_path";
            remote_log "LOAD_FAIL" "$effective_config_name_for_log" "Downloaded file empty, source not. Target: ${output_file_path}";
            return 1;
        else
            log_info "Downloaded '${output_file_path}' is empty, and remote source '${remote_source_path}' is also empty."
        fi
    fi
    
    local content_hash; content_hash=$(calculate_hash "$output_file_path") || content_hash="N/A_if_empty_or_error"
    remote_log "LOAD" "$effective_config_name_for_log" "Dest: ${output_file_path}, Hash: ${content_hash}"
    log_success "Loaded '${effective_config_name_for_log}' from remote to '${output_file_path}'."
}

ls_command() {
    local prefix_filter="$1"
    local find_cmd
    if [ -n "$prefix_filter" ]; then
        find_cmd="sudo find '${REMOTE_ENVMAN_CONFIG_BASE_DIR}' -maxdepth 1 -type f \\( -name '${prefix_filter}_${TS_GLOB_SUFFIX}' -o -name '${prefix_filter}-${TS_GLOB_SUFFIX}' \\) -printf '%f\\n'"
    else
        find_cmd="sudo find '${REMOTE_ENVMAN_CONFIG_BASE_DIR}' -maxdepth 1 -type f \\( -name '*_${TS_GLOB_SUFFIX}' -o -name '*-${TS_GLOB_SUFFIX}' -o -name '${ENVMAN_SYMLINK_NAME}' \\) -printf '%f\\n'"
    fi
    local files_list
    files_list=$(remote_exec_get_stdout "$find_cmd")
    local find_exit_code=$?
    if [ "$find_exit_code" -ne 0 ]; then
        echo "(Error executing list command on remote)"
    elif [ -z "$files_list" ]; then
        if [ -n "$prefix_filter" ]; then
            echo "(No remote configurations found matching prefix '${prefix_filter}' in ${REMOTE_ENVMAN_CONFIG_BASE_DIR})"
        else
            echo "(No timestamped remote configurations or '${ENVMAN_SYMLINK_NAME}' found in ${REMOTE_ENVMAN_CONFIG_BASE_DIR})"
        fi
    else
        echo "$files_list" | sort
    fi
    remote_log "LIST" "${prefix_filter:-ALL_AND_LATEST_SYMLINK}" "Listed configurations"
}

latest_command() {
    local symlink_target
    symlink_target=$(remote_exec_get_stdout "sudo readlink '${REMOTE_ENVMAN_CONFIG_BASE_DIR}/${ENVMAN_SYMLINK_NAME}' 2>/dev/null")
    if [ $? -eq 0 ] && [ -n "$symlink_target" ]; then
        echo "$symlink_target"
        remote_log "LATEST" "${ENVMAN_SYMLINK_NAME}" "Displayed symlink target: ${symlink_target}"
    else
        log_error "'${ENVMAN_SYMLINK_NAME}' symlink not found or error checking it in ${REMOTE_ENVMAN_CONFIG_BASE_DIR}."
        remote_log "LATEST_FAIL" "${ENVMAN_SYMLINK_NAME}" "Failed to display symlink target"
        exit 1
    fi
}

review_command() {
    local requested_target="$1"
    local remote_target_path
    local effective_config_name_for_log
    local match_details_str
    if ! resolve_remote_target_path_and_name "$requested_target" \
                                             remote_target_path \
                                             effective_config_name_for_log \
                                             match_details_str; then
        remote_log "REVIEW_FAIL" "${requested_target:-${ENVMAN_SYMLINK_NAME}}" "Resolution failed: ${match_details_str}"
        exit 1
    fi
    if [[ "$match_details_str" == "single_fuzzy_match" ]]; then
        log_info "Single match found for '${requested_target}': '${effective_config_name_for_log}'. Reviewing it."
    elif [[ "$match_details_str" == "multiple_fuzzy_matches_newest_selected"* ]]; then
        log_info "Multiple matches found for '${requested_target}':"
        local all_matches_list="${match_details_str#multiple_fuzzy_matches_newest_selected }"
        for matched_file in $all_matches_list; do
            echo "  - ${matched_file}"
        done
        log_info "Reviewing the newest match: '${effective_config_name_for_log}'. To review a different specific version, use its full filename."
    fi
    echo "--- START OF REMOTE FILE: ${effective_config_name_for_log} ---"
    if remote_exec_interactive "sudo cat '${remote_target_path}'"; then
        echo "--- END OF REMOTE FILE: ${effective_config_name_for_log} ---"
        remote_log "REVIEW" "$effective_config_name_for_log" "Content displayed"
    else
        echo "--- END OF REMOTE FILE: ${effective_config_name_for_log} (Error reading or file not found) ---"
        remote_log "REVIEW_FAIL" "$effective_config_name_for_log" "Failed to cat remote file: ${remote_target_path}"
        exit 1
    fi
}


# --- Main Script Logic ---

if [ "$#" -lt 1 ]; then usage; fi

# Parse global options like -i for SSH identity file
# This getopts loop is for options that apply to the script as a whole,
# BEFORE the command is determined.
ORIG_OPTIND=$OPTIND # Save global OPTIND
OPTIND=1 # Reset for this getopts
while getopts ":i:" opt; do
    case ${opt} in
        i) GLOBAL_IDENTITY_FILE_ARG="-i ${OPTARG}"; 
           if [ ! -f "${OPTARG}" ]; then log_error "Identity file not found: ${OPTARG}"; exit 1; fi ;;
        # If other global options were needed, they'd go here.
        # For now, only -i is global.
        \?) # This means an unknown option or a command was encountered.
            # We need to put it back for the command parsing.
            OPTIND=$((OPTIND - 1)) # Decrement OPTIND to re-evaluate this arg
            break # Stop global option processing
            ;; 
        :) log_error "Global option -${OPTARG} requires an argument."; usage ;;
    esac
done
shift $((OPTIND - 1)) # Remove parsed global options
OPTIND=$ORIG_OPTIND # Restore global OPTIND (though not strictly necessary if sub-commands manage their own)

COMMAND_NAME="$1"; if [ -z "$COMMAND_NAME" ]; then log_error "No command specified."; usage; fi
shift # Remove command name, remaining args ($@) are for the command function

parse_default_vps_details # Sets up SSH_CMD_BASE and SCP_CMD_BASE using GLOBAL_IDENTITY_FILE_ARG

case "$COMMAND_NAME" in
    save)
        # Pass all remaining arguments to save_command for its own getopts
        save_command "$@" ;;
    load)
        # Pass all remaining arguments to load_command for its own getopts
        load_command "$@" ;;
    ls)
        if [ "$#" -gt 1 ]; then log_error "'ls' takes at most one [prefix_filter] argument."; usage; fi
        ls_command "$1" ;;
    latest)
        if [ "$#" -ne 0 ]; then log_error "'latest' command takes no arguments."; usage; fi
        latest_command ;;
    review)
        if [ "$#" -gt 1 ]; then log_error "'review' takes at most one [target] argument."; usage; fi
        review_command "$1" ;;
    *) log_error "Unknown command: ${COMMAND_NAME}"; usage ;;
esac

exit 0
