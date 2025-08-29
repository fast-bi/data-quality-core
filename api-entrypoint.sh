#!/bin/bash
#

set -o errexit
set -o pipefail
set -o nounset

# Standard logging directory
LOG_DIR="/data/logs"
MAIN_LOG="${LOG_DIR}/api-entrypoint.log"
ERROR_LOG="${LOG_DIR}/error.log"
CRON_LOG="${LOG_DIR}/cron.log"
REDATA_LOG="${LOG_DIR}/redata.log"

# Export log variables for use in cron scripts
export LOG_DIR MAIN_LOG ERROR_LOG CRON_LOG REDATA_LOG

# Enhanced logging function that writes to both file and stderr
log() {
    local message="$1"
    local level="${2:-INFO}"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_message="[$timestamp] [$level] $message"
    # Write to stderr for Kubernetes visibility
    echo "$log_message" >&2
    # Write to log file
    echo "$log_message" >> "$MAIN_LOG"
}

# Function to safely log environment variables
log_env_var() {
    local key="$1"
    local value="$2"
    if [[ "$key" == *"PASSWORD"* ]] || [[ "$key" == *"KEY"* ]] || [[ "$key" == *"SECRET"* ]]; then
        log "Setting environment variable: $key=***"
    else
        log "Setting environment variable: $key=$value"
    fi
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
touch "$MAIN_LOG" "$ERROR_LOG" "$CRON_LOG" "$REDATA_LOG" || {
    echo "Failed to create log files" >&2
    exit 1
}

# Function to safely read secret files
read_secret() {
    local secret_path="$1"
    if [ -f "$secret_path" ]; then
        cat "$secret_path"
    else
        log "Secret file not found: $secret_path" "ERROR"
        return 1
    fi
}

log "Starting DBT Workload"
log "Checking dependencies"

dbt --version || { log "dbt command not found" "ERROR"; exit 1; }
git --version || { log "git command not found" "ERROR"; exit 1; }
pip show re_data || { log "re_data package not found" "ERROR"; exit 1; }

if [[ -f "/data/lost+found" ]]; then
    log "Removing lost+found directory"
    rm -rf /data/lost+found
fi

# Handle GCP CE Account secrets
if [ "${GCP_CE_ACC:-false}" == "true" ]; then
    log "Setting up GCP CE Account secrets"
    gcloud secrets versions access latest --secret="${DBT_SECRETS}" | base64 --decode >> /etc/environment || {
        log "Failed to access GCP secret: ${DBT_SECRETS}" "ERROR"
        exit 1
    }
    source /etc/environment
    log "DBT_SECRETS env is set!"
else
    log "GCP_CE_ACC is false or not specified - DBT_SECRETS env is not set!" "WARN"
fi

# Create data directory and clone dbt repo
mkdir -p /data/ || { log "Failed to create /data directory" "ERROR"; exit 1; }
log "Cloning dbt Repo"
git clone "${GITLINK_SECRET}" /data/dbt/ || { log "Failed to clone dbt repository" "ERROR"; exit 1; }
log "Working on dbt directory"
cd "/data/dbt/${DBT_REPO_NAME}" || { log "Failed to change to dbt directory" "ERROR"; exit 1; }

# Handle GCP Secret Key
if [ "${GCP_SECRET_KEY:-false}" == "true" ]; then
    log "Authenticating with GCP using service account"
    mkdir -p /usr/src/secret/ || { log "Failed to create secret directory" "ERROR"; exit 1; }
    echo "${SA_SECRET}" | base64 --decode > /usr/src/secret/sa.json || {
        log "Failed to decode SA secret" "ERROR"
        exit 1
    }
    gcloud auth activate-service-account "${SA_EMAIL}" --key-file /usr/src/secret/sa.json || {
        log "Failed to activate service account" "ERROR"
        exit 1
    }
    
    if [ -n "${PROJECT_NAME:-}" ]; then
        gcloud config set project "${PROJECT_NAME}"
        gcloud config set disable_prompts true
        log "Project set to: ${PROJECT_NAME}"
    else
        log "Project Name not in environment variables" "WARN"
    fi

    if [ -n "${PROFILE_SECRET_NAME:-}" ]; then
        mkdir -p /root/.dbt/
        mkdir -p /root/.re_data/
        gcloud secrets versions access latest --secret="${PROFILE_SECRET_NAME}" | base64 --decode > /root/.dbt/profiles.yml || {
            log "Failed to access profile secret" "ERROR"
            exit 1
        }
        gcloud secrets versions access latest --secret="${RE_DATA_PROFILE_SECRET_NAME}" | base64 --decode > /root/.re_data/re_data.yml || {
            log "Failed to access re_data profile secret" "ERROR"
            exit 1
        }
        log "Profile secrets configured"
    else
        log "No Secret Name described for GCP Secret Manager" "WARN"
    fi

    # Set environment variables for backward compatibility
    ENV_VARS="--env=GOOGLE_APPLICATION_CREDENTIALS=/usr/src/secret/sa.json"
    if [ -n "${PROJECT_NAME:-}" ]; then
        ENV_VARS="${ENV_VARS} --env=BIGQUERY_PROJECT_ID=${PROJECT_NAME}"
    fi
elif [ "${GCP_SECRET_KEY:-false}" == "false" ]; then
    log "Using default GCP account"
    if [ -n "${PROFILE_SECRET_NAME:-}" ]; then
        gcloud secrets versions access latest --secret="${PROFILE_SECRET_NAME}" | base64 --decode > /root/.dbt/profiles.yml || {
            log "Failed to access profile secret" "ERROR"
            exit 1
        }
    fi
else
    log "Manual dbt .dbt/profiles.yml configuration" "INFO"
fi

# Data Warehouse Secrets
if [ "${DATA_WAREHOUSE_SECRET:-}" != "" ] || [ "${DATA_WAREHOUSE_PLATFORM:-}" != "" ]; then
    if [ ! -d "/fastbi/secrets" ]; then
        log "Secrets directory /fastbi/secrets not found - skipping Data Warehouse Secrets configuration" "WARN"
    else
        # Use either DATA_WAREHOUSE_SECRET or DATA_WAREHOUSE_PLATFORM
        WAREHOUSE_TYPE="${DATA_WAREHOUSE_SECRET:-${DATA_WAREHOUSE_PLATFORM}}"
        
        # Map warehouse types to numeric values
        case "${WAREHOUSE_TYPE}" in
            "1"|"bigquery")
                # Only configure BigQuery if not already configured by GCP_SECRET_KEY
                if [ "${GCP_SECRET_KEY:-false}" != "true" ]; then
                    log "Configuring BigQuery secrets"
                    mkdir -p /usr/src/secret/ || { log "Failed to create secret directory" "ERROR"; exit 1; }
                    
                    if [ -f "/fastbi/secrets/DBT_DEPLOY_GCP_SA_SECRET" ]; then
                        log "Reading service account secret from mounted volume"
                        read_secret "/fastbi/secrets/DBT_DEPLOY_GCP_SA_SECRET" | base64 --decode > /usr/src/secret/sa.json || {
                            log "Failed to decode service account secret" "ERROR"
                            exit 1
                        }
                        gcloud auth activate-service-account --key-file /usr/src/secret/sa.json || {
                            log "Failed to activate service account" "ERROR"
                            exit 1
                        }
                        ENV_VARS="--env=GOOGLE_APPLICATION_CREDENTIALS=/usr/src/secret/sa.json"
                        log "GOOGLE_APPLICATION_CREDENTIALS is set!"
                    else
                        log "Service account secret not found in mounted volume" "ERROR"
                        exit 1
                    fi

                    if [ -f "/fastbi/secrets/BIGQUERY_PROJECT_ID" ]; then
                        ENV_VARS="${ENV_VARS} --env=BIGQUERY_PROJECT_ID=$(read_secret "/fastbi/secrets/BIGQUERY_PROJECT_ID")"
                        log "BIGQUERY_PROJECT_ID is set"
                    fi

                    if [ -f "/fastbi/secrets/BIGQUERY_REGION" ]; then
                        ENV_VARS="${ENV_VARS} --env=BIGQUERY_REGION=$(read_secret "/fastbi/secrets/BIGQUERY_REGION")"
                        log "BIGQUERY_REGION is set"
                    fi

                    if [ -f "/fastbi/secrets/DATA_ANALYSIS_GCP_SA_EMAIL" ]; then
                        ENV_VARS="${ENV_VARS} --env=DATA_ANALYSIS_GCP_SA_EMAIL=$(read_secret "/fastbi/secrets/DATA_ANALYSIS_GCP_SA_EMAIL")"
                        log "DATA_ANALYSIS_GCP_SA_EMAIL is set"
                    fi
                fi
                ;;
            "2"|"snowflake")
                log "Configuring Snowflake secrets"
                mkdir -p /snowsql/secrets/
                read_secret "/fastbi/secrets/SNOWFLAKE_PRIVATE_KEY" > /snowsql/secrets/rsa_key.p8 || {
                    log "Failed to read Snowflake private key" "ERROR"
                    exit 1
                }
                chmod 600 /snowsql/secrets/rsa_key.p8
                ENV_VARS="${ENV_VARS:-} --env=SNOWSQL_PRIVATE_KEY_PASSPHRASE=$(read_secret "/fastbi/secrets/SNOWFLAKE_PASSPHRASE")"
                log "Snowflake secrets configured"
                ;;
            "3"|"redshift")
                log "Configuring Redshift secrets"
                if [ -f "/fastbi/secrets/REDSHIFT_PASSWORD" ]; then
                    ENV_VARS="${ENV_VARS:-} --env=REDSHIFT_PASSWORD=$(read_secret "/fastbi/secrets/REDSHIFT_PASSWORD")"
                fi
                if [ -f "/fastbi/secrets/REDSHIFT_USER" ]; then
                    ENV_VARS="${ENV_VARS} --env=REDSHIFT_USER=$(read_secret "/fastbi/secrets/REDSHIFT_USER")"
                fi
                if [ -f "/fastbi/secrets/REDSHIFT_HOST" ]; then
                    ENV_VARS="${ENV_VARS} --env=REDSHIFT_HOST=$(read_secret "/fastbi/secrets/REDSHIFT_HOST")"
                fi
                if [ -f "/fastbi/secrets/REDSHIFT_PORT" ]; then
                    ENV_VARS="${ENV_VARS} --env=REDSHIFT_PORT=$(read_secret "/fastbi/secrets/REDSHIFT_PORT")"
                fi
                log "Redshift secrets configured"
                ;;
            "4"|"fabric")
                log "Configuring Fabric secrets"
                if [ -f "/fastbi/secrets/FABRIC_USER" ]; then
                    ENV_VARS="${ENV_VARS:-} --env=FABRIC_USER=$(read_secret "/fastbi/secrets/FABRIC_USER")"
                fi
                if [ -f "/fastbi/secrets/FABRIC_PASSWORD" ]; then
                    ENV_VARS="${ENV_VARS} --env=FABRIC_PASSWORD=$(read_secret "/fastbi/secrets/FABRIC_PASSWORD")"
                fi
                if [ -f "/fastbi/secrets/FABRIC_SERVER" ]; then
                    ENV_VARS="${ENV_VARS} --env=FABRIC_SERVER=$(read_secret "/fastbi/secrets/FABRIC_SERVER")"
                fi
                if [ -f "/fastbi/secrets/FABRIC_DATABASE" ]; then
                    ENV_VARS="${ENV_VARS} --env=FABRIC_DATABASE=$(read_secret "/fastbi/secrets/FABRIC_DATABASE")"
                fi
                if [ -f "/fastbi/secrets/FABRIC_PORT" ]; then
                    ENV_VARS="${ENV_VARS} --env=FABRIC_PORT=$(read_secret "/fastbi/secrets/FABRIC_PORT")"
                fi
                if [ -f "/fastbi/secrets/FABRIC_AUTHENTICATION" ]; then
                    ENV_VARS="${ENV_VARS} --env=FABRIC_AUTHENTICATION=$(read_secret "/fastbi/secrets/FABRIC_AUTHENTICATION")"
                fi
                log "Fabric secrets configured"
                ;;
            *)
                log "Invalid warehouse type value: ${WAREHOUSE_TYPE}" "ERROR"
                exit 1
                ;;
        esac
    fi
fi

log "Staying on dbt directory"
if [ "${DEBUG:-false}" == "true" ]; then
    log "dbt debug enabled"
    dbt debug || { log "dbt debug failed" "ERROR"; exit 1; }
else
    log "dbt debug disabled"
fi

log "Setting up CRON schedule"
if [ -n "${CRON_TIME:-}" ]; then
    log "Cron Schedule is ${CRON_TIME}"
else
    log "No Cron Schedule described - using default!"
    export CRON_TIME='0 6 * * *'  # Default to 6 AM daily
fi

# Creating secret file
log "Creating environment file"
if ! touch /usr/app/dbt/.env; then
    log "Failed to create environment file" "ERROR"
    exit 1
fi

# Write environment variables to the file
{
    echo "DBT_REPO_NAME=${DBT_REPO_NAME}"
    echo "GITLINK_SECRET=${GITLINK_SECRET}"
    echo "SECRET_DBT_PACKAGE_REPO_TOKEN=${SECRET_DBT_PACKAGE_REPO_TOKEN}"
    echo "SECRET_PACKAGE_REPO_TOKEN_NAME=${SECRET_PACKAGE_REPO_TOKEN_NAME}"
    echo "DBT_PROJECT_NAME=${DBT_PROJECT_NAME}"
} > /usr/app/dbt/.env || {
    log "Failed to write environment variables" "ERROR"
    exit 1
}

log "Setting up cron scheduler"
# Create a temporary environment file for cron
CRON_ENV_FILE="/tmp/cron.env"
echo "# Environment variables for cron jobs" > "$CRON_ENV_FILE" || {
    log "Failed to create cron environment file" "ERROR"
    exit 1
}

if [ -n "${ENV_VARS:-}" ]; then
    # Convert --env=KEY=VALUE format to KEY=VALUE
    echo "$ENV_VARS" | tr ' ' '\n' | sed 's/^--env=//' >> "$CRON_ENV_FILE" || {
        log "Failed to write environment variables to cron file" "ERROR"
        exit 1
    }
    log "Environment variables written to cron file"
fi

# Update cron job to source environment variables with daily schedule
CRON_JOB="${CRON_TIME} . $CRON_ENV_FILE && /usr/app/dbt/cron_redata.sh ${ENV_VARS:-} >> $LOG_DIR/redata_job.log 2>&1"
(crontab -l 2>/dev/null | grep -v "/usr/app/dbt/cron_redata.sh"; echo "$CRON_JOB") | crontab - || {
    log "Failed to update crontab" "ERROR"
    exit 1
}
log "Cron job scheduled with environment variables"

# Add cron health check job
HEALTH_CHECK_JOB="0 */6 * * * echo \"Cron health check: \$(date)\" >> $LOG_DIR/cron_up.log 2>&1"
(crontab -l 2>/dev/null | grep -v "cron_up.log"; echo "$HEALTH_CHECK_JOB") | crontab - || {
    log "Failed to add health check job to crontab" "ERROR"
    exit 1
}
log "Health check job scheduled"

# Restart cron service
log "Restarting cron service"
/etc/init.d/cron restart || {
    log "Failed to restart cron service" "ERROR"
    exit 1
}
log "Cron service restarted successfully"

# Run initial redata generation
log "Running initial redata generation"
if ! sh -c "/usr/app/dbt/cron_redata.sh ${ENV_VARS:-} 2>&1 | tee -a $LOG_DIR/redata_job.log"; then
    log "Failed to generate initial redata" "ERROR"
    log "Check $LOG_DIR/redata_job.log for details" "ERROR"
    exit 1
fi
log "Initial redata generation completed successfully"

# Monitor the logs in the background
log "Starting log monitoring"
tail -f "$LOG_DIR/redata_job.log" &

# Export environment variables for redata
if [ -n "${ENV_VARS:-}" ]; then
    log "Setting up environment variables for redata server"
    # Convert --env=KEY=VALUE format to export KEY=VALUE
    echo "$ENV_VARS" | tr ' ' '\n' | sed 's/^--env=/export /' > /tmp/redata_env.sh || {
        log "Failed to create environment file for redata server" "ERROR"
        exit 1
    }
    source /tmp/redata_env.sh || {
        log "Failed to source environment variables for redata server" "ERROR"
        exit 1
    }
    log "Environment variables set for redata server"
fi

# Start the redata server
log "Starting redata server"
# Start the server in the background and capture its PID
re_data overview serve --port 8085 --project-dir "/data/dbt/${DBT_REPO_NAME}/" 2>&1 | tee -a "$REDATA_LOG" &
REDATA_PID=$!

# Function to check if the server is still running
check_server() {
    if ! kill -0 $REDATA_PID 2>/dev/null; then
        log "Redata server process is not running" "ERROR"
        return 1
    fi
    return 0
}

# Wait for the server to start
log "Waiting for redata server to start..."
sleep 5

# Check if the server started successfully
if ! check_server; then
    log "Failed to start redata server" "ERROR"
    log "Check $REDATA_LOG for details" "ERROR"
    exit 1
fi

log "Redata server started successfully with PID $REDATA_PID"

# Keep the script running and monitor the server
while true; do
    if ! check_server; then
        log "Redata server stopped unexpectedly" "ERROR"
        log "Check $REDATA_LOG for details" "ERROR"
        exit 1
    fi
    sleep 30
done
