#!/bin/bash
#

set -o errexit
catch() {
    echo 'catching!'
    if [ "$1" != "0" ]; then
    # error handling goes here
    echo "Error $1 occurred on $2"
    fi
}
trap 'catch $? $LINENO' EXIT

echo 'Starting DBT Workload'
echo 'Checking dependencies'

dbt --version

git --version

pip show re_data

if [[ -f "/data/lost+found" ]]
then
    echo "This lost+found exists on your filesystem."
    rm -rf /data/lost+found
fi

if [ "${GCP_CE_ACC}" == "true" ]; then
    gcloud secrets versions access latest --secret="${DBT_SECRETS}" | base64 --decode >> /etc/environment
    source /etc/environment
    echo "DBT_SECRETS env is set!"
else
    echo "var GCP_CE_ACC is false or not specified"
    echo "DBT_SECRETS env is not set!"
fi

mkdir -p /data/
echo 'Cloning dbt Repo'
git clone ${GITLINK_SECRET} /data/dbt/
echo 'Working on dbt directory'
cd /data/dbt/${DBT_REPO_NAME}

if [ "${GCP_SECRET_KEY}" == "true" ]; then
    echo "Authentificate at GCP"
    echo "Decrypting and saving sa.json file"
    mkdir /usr/src/secret/
    echo "${SA_SECRET}" | base64 --decode > /usr/src/secret/sa.json
    gcloud auth activate-service-account ${SA_EMAIL} --key-file /usr/src/secret/sa.json
    echo 'The Project set'
    if test "${PROJECT_NAME}"; then
        gcloud config set project ${PROJECT_NAME}
        gcloud config set disable_prompts true
    else
        echo "Project Name not in environment variables ${PROJECT_NAME}"
    fi
    echo 'Use Google Cloud Secret Manager Secret'
    if test "${PROFILE_SECRET_NAME}"; then
        mkdir -p /root/.dbt/
        mkdir -p /root/.re_data/
        gcloud secrets versions access latest --secret="${PROFILE_SECRET_NAME}" | base64 --decode > /root/.dbt/profiles.yml
        gcloud secrets versions access latest --secret="${RE_DATA_PROFILE_SECRET_NAME}" | base64 --decode > /root/.re_data/re_data.yml
    else
        echo 'No Secret Name described - GCP Secret Manager'
    fi        
elif [ "${GCP_SECRET_KEY}" == "false" ]; then
    echo "GCP Secret will be taken with default account."
    gcloud secrets versions access latest --secret="${PROFILE_SECRET_NAME}" | base64 --decode > /root/.dbt/profiles.yml
else
    echo "dbt .dbt/profiles.yml Secret will be added manually."    
fi

echo "Set ReData_Job thread ammount to 26"
sed -i 's/threads: 1/threads: 26/' /root/.dbt/profiles.yml

echo 'Staying on dbt directory'
if [ "${DBT_DEPS}" == "true" ]; then
    echo "dbt debug enabled."
    dbt debug
    dbt deps
else
    echo "dbt debug disabled."
fi

echo "Start BackFill ReData_Report_Historical_Data"
#start='2022-01-01' example
#end='2022-12-31' example
DBT_COMMAND=run
MODEL_1="package:re_data"

start=$BACKFILL_START_DATE
end=$BACKFILL_END_DATE
start=$(date -d $start +%Y%m%d)
end=$(date -d $end +%Y%m%d)
startin=$(date -d $start +"%Y-%m-%d 00:00:00")
startend=$(date -d"$start + 1 day" +"%Y-%m-%d 00:00:00")

while [[ $start -le $end ]]
do
        DBT_VAR='{"re_data:time_window_start": "'$startin'", "re_data:time_window_end": "'$startend'"}'
        echo "Running dbt command with variables: dbt ${DBT_COMMAND} model ${MODEL_1} --vars "${DBT_VAR}"."
        printf -v execute_1 "dbt ${DBT_COMMAND} --select ${MODEL_1} --vars '${DBT_VAR}'"
        eval $execute_1
        start=$(date -d"$start + 1 day" +"%Y%m%d")
        startin=$(date -d"$startin + 1 day" +"%Y-%m-%d 00:00:00")
        startend=$(date -d"$startend + 1 day" +"%Y-%m-%d 00:00:00")
done

echo "Backfill is Done!"
exit 0