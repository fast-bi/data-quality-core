##
#  Generic dockerfile for dbt image building.
#  See README for operational details
##

ARG build_for=linux/amd64

##
# Base: system deps + Python + dbt + re_data (single stage for clarity and to ensure all tools in final image)
##
FROM --platform=$build_for python:3.11.11-slim-bullseye AS base
LABEL maintainer=support@fast.bi

# System packages (jq, git, gcloud, cron, etc.)
RUN apt-get update \
  && apt-get dist-upgrade -y \
  && apt-get install -y --no-install-recommends \
    jq \
    git \
    ssh-client \
    software-properties-common \
    make \
    build-essential \
    ca-certificates \
    libpq-dev \
    curl \
    apt-transport-https \
    gnupg \
    coreutils \
    cron \
  && echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] http://packages.cloud.google.com/apt cloud-sdk main" | tee -a /etc/apt/sources.list.d/google-cloud-sdk.list \
  && curl -sSf https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key --keyring /usr/share/keyrings/cloud.google.gpg add - \
  && apt-get update -y \
  && apt-get install -y google-cloud-cli \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Python env
ENV PYTHONIOENCODING=utf-8
ENV LANG=C.UTF-8
ENV PYTHONWARNINGS=ignore
ENV RE_DATA_SEND_ANONYMOUS_USAGE_STATS=0

# Pin setuptools < 81 for re_data 0.11.0 (pkg_resources)
RUN python -m pip install --no-cache-dir --upgrade pip "setuptools<81" wheel

# dbt adapters + re_data + yq (one layer for better cache)
RUN python -m pip install --no-cache-dir \
    yq \
    pytz \
    pandas \
    colorama \
    re-data==0.11.0 \
    dbt-bigquery==1.9.2 \
    dbt-snowflake==1.9.4 \
    dbt-redshift==1.9.5 \
    dbt-fabric==1.9.6

# Symlinks for CLI
RUN ln -sf /usr/local/bin/dbt /usr/bin/dbt \
  && ln -sf /usr/local/bin/re_data /usr/bin/re_data

# Verify jq (and other tools) are present so build fails if apt layer is cached wrong
RUN command -v jq >/dev/null 2>&1 || (echo "FATAL: jq not found in image" && exit 1)

WORKDIR /usr/app/dbt/

##
# Final: add scripts only (rebuild when scripts change)
##
FROM base AS final
LABEL maintainer=support@fast.bi

COPY ./api-entrypoint.sh ./cron_redata.sh ./backfill_redata.sh /usr/app/dbt/
RUN chmod 755 /usr/app/dbt/api-entrypoint.sh /usr/app/dbt/cron_redata.sh /usr/app/dbt/backfill_redata.sh

ENTRYPOINT ["/bin/bash", "-c", "/usr/app/dbt/api-entrypoint.sh"]
