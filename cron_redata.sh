#!/bin/bash
#

set -o errexit
set -o pipefail
set -o nounset

# Standard logging directory
LOG_DIR="/data/logs"
REDATA_LOG="${LOG_DIR}/redata.log"
ERROR_LOG="${LOG_DIR}/error.log"

# Enhanced logging function that writes to both file and stderr
log() {
    local message="$1"
    local level="${2:-INFO}"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_message="[$timestamp] [$level] $message"
    # Write to stderr for Kubernetes visibility
    echo "$log_message" >&2
    # Write to log file
    echo "$log_message" >> "$REDATA_LOG"
}

# Enhanced error handling
catch() {
    local exit_code=$1
    local line_number=$2
    # Only log errors (non-zero exit codes)
    if [ $exit_code -ne 0 ]; then
        local error_message="Error $exit_code occurred on line $line_number"
        log "$error_message" "ERROR"
        echo "$error_message" >> "$ERROR_LOG"
        exit $exit_code
    fi
}

trap 'catch $? $LINENO' EXIT

# Create required directories
mkdir -p /data || {
    echo "Failed to create /data directory" >&2
    exit 1
}

mkdir -p "$LOG_DIR" || {
    echo "Failed to create log directory: $LOG_DIR" >&2
    exit 1
}

# Initialize log files
touch "$REDATA_LOG" "$ERROR_LOG" || {
    echo "Failed to create log files" >&2
    exit 1
}

# Load environment variables from .env file
if [ ! -f "/usr/app/dbt/.env" ]; then
    log "Environment file not found: /usr/app/dbt/.env" "ERROR"
    exit 1
fi
source /usr/app/dbt/.env

# Export any passed environment variables
while [ $# -gt 0 ]; do
    case "$1" in
        --env=*)
            export "${1#*=}"
            ;;
    esac
    shift
done

log "Starting DBT Workload reload"
source /etc/environment
log "Checking dependencies"

# Clone or update dbt repository
if cd "/data/dbt/${DBT_REPO_NAME}"; then 
    log "Updating existing dbt repository"
    git config pull.rebase true
    git reset --hard
    git pull || { log "Failed to pull latest changes" "ERROR"; exit 1; }
else 
    log "Cloning new dbt repository"
    git clone "${GITLINK_SECRET}" "/data/dbt/" || { log "Failed to clone repository" "ERROR"; exit 1; }
fi

#update the dbt packages
log "Updating DBT catalog"
/usr/local/bin/dbt deps --profiles-dir "/data/dbt/${DBT_REPO_NAME}/" --project-dir "/data/dbt/${DBT_REPO_NAME}/" || {
    log "Failed to update dbt dependencies" "ERROR"
    exit 1
}

# Check and update dbt_project.yml with target-path: "target" if necessary
DBT_PROJECT_FILE="/data/dbt/${DBT_REPO_NAME}/dbt_project.yml"
TARGET_PATH_LINE="target-path: \"target\""

if ! grep -qF "${TARGET_PATH_LINE}" "${DBT_PROJECT_FILE}"; then
    log "Adding target-path configuration to dbt_project.yml"
    echo "${TARGET_PATH_LINE}" >> "${DBT_PROJECT_FILE}"
else
    log "target-path is already configured in dbt_project.yml"
fi

# Date calculations
YESTERDAY=$(date '+%F' --date="+1 days ago")
TODAY=$(date '+%F')
TOMORROW=$(date '+%F' --date="-1 days ago")
YEAR_START=$(date +'%Y-01-01')
THIS_MONTH_START=$(date -d "$TODAY" '+%Y-%m-01')
THIS_MONTH_CURRENTTIME=$(date -d "$TODAY" '+%Y-%m-%d')
LAST_MONTH_START=$(date -d "$THIS_MONTH_START -1 month" '+%F')
LAST_MONTH_END=$(date -d "$LAST_MONTH_START +1 month -1 day" '+%F')

# Generate re_data reports based on configuration
if [ "${REDATA_YEAR:-false}" == "true" ]; then
    log "Generating yearly re_data report"
    /usr/local/bin/re_data overview generate --start-date "$YEAR_START" --end-date "$TOMORROW" --interval days:1 --profiles-dir "/data/dbt/${DBT_REPO_NAME}/" --project-dir "/data/dbt/${DBT_REPO_NAME}/" || {
        log "Failed to generate yearly report" "ERROR"
        exit 1
    }
elif [ "${REDATA_LAST_QUARTER:-false}" == "true" ]; then
    log "Generating quarterly re_data report"
    CURR_MONTH=$(date +%-m)
    CURR_YEAR=$(date +%Y)
    if ((CURR_MONTH >= 1 && CURR_MONTH <= 3)); then
        CURR_QUARTER_START="${CURR_YEAR}-01-01"
        CURR_QUARTER_END="${CURR_YEAR}-03-31"
    elif ((CURR_MONTH >= 4 && CURR_MONTH <= 6)); then
        CURR_QUARTER_START="${CURR_YEAR}-04-01"
        CURR_QUARTER_END="${CURR_YEAR}-06-30"
    elif ((CURR_MONTH >= 7 && CURR_MONTH <= 9)); then
        CURR_QUARTER_START="${CURR_YEAR}-07-01"
        CURR_QUARTER_END="${CURR_YEAR}-09-30"
    else
        CURR_QUARTER_START="${CURR_YEAR}-10-01"
        CURR_QUARTER_END="${CURR_YEAR}-12-31"
    fi
    /usr/local/bin/re_data overview generate --start-date "$CURR_QUARTER_START" --end-date "$CURR_QUARTER_END" --interval days:1 --profiles-dir "/data/dbt/${DBT_REPO_NAME}/" --project-dir "/data/dbt/${DBT_REPO_NAME}/" || {
        log "Failed to generate quarterly report" "ERROR"
        exit 1
    }
else
    log "Generating monthly re_data report"
    /usr/local/bin/re_data overview generate --start-date "$THIS_MONTH_START" --end-date "$TOMORROW" --interval days:1 --profiles-dir "/data/dbt/${DBT_REPO_NAME}/" --project-dir "/data/dbt/${DBT_REPO_NAME}/" || {
        log "Failed to generate monthly report" "ERROR"
        exit 1
    }
fi

# Handle notifications
if [ "${REDATA_NOTIFY:-false}" == "true" ]; then
    log "Processing notifications"
    if [ "${REDATA_NOTIFY_SLACK:-false}" == "true" ]; then
        log "Sending Slack notification"
        /usr/local/bin/re_data notify slack --start-date "$TODAY" --end-date "$TOMORROW" --profiles-dir "/data/dbt/${DBT_REPO_NAME}/" --project-dir "/data/dbt/${DBT_REPO_NAME}/" || {
            log "Failed to send Slack notification" "ERROR"
            exit 1
        }
    fi
    
    if [ "${REDATA_NOTIFY_EMAIL:-false}" == "true" ]; then
        log "Sending Email notification"
        /usr/local/bin/re_data notify email --start-date "$YESTERDAY" --end-date "$TOMORROW" --profiles-dir "/data/dbt/${DBT_REPO_NAME}/" --project-dir "/data/dbt/${DBT_REPO_NAME}/" || {
            log "Failed to send Email notification" "ERROR"
            exit 1
        }
    fi
fi

log "ReData job completed successfully"