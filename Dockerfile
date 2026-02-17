##
#  Generic dockerfile for dbt image building.
#  See README for operational details
##

# Top level build args
ARG build_for=linux/amd64

##
# base image (abstract)
##
FROM --platform=$build_for python:3.11.11-slim-bullseye as base
LABEL maintainer=support@fast.bi

# System setup
RUN apt-get update \
  && apt-get dist-upgrade -y \
  && apt-get install -y --no-install-recommends \
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
    cl-base64 \
    cron
RUN echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] http://packages.cloud.google.com/apt cloud-sdk main" | tee -a /etc/apt/sources.list.d/google-cloud-sdk.list && curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key --keyring /usr/share/keyrings/cloud.google.gpg  add - && apt-get update -y && apt-get install google-cloud-cli -y
RUN apt-get clean \
  && rm -rf \
    /var/lib/apt/lists/* \
    /tmp/* \
    /var/tmp/*

# Env vars
ENV PYTHONIOENCODING=utf-8
ENV LANG=C.UTF-8

# Update python
# Pin setuptools < 81 to ensure pkg_resources is available for re_data 0.11.0
RUN python -m pip install --upgrade pip "setuptools<81" wheel yq pytz pandas colorama --no-cache-dir

# Set up work directory
WORKDIR /usr/app/dbt/

##
# dbt packages layer - this will be cached
##
FROM base as dbt-packages
# Ensure setuptools with pkg_resources is installed before re_data
RUN python -m pip install --no-cache-dir "setuptools<81"
RUN python -m pip install --no-cache-dir dbt-bigquery==1.9.2
RUN python -m pip install --no-cache-dir dbt-snowflake==1.9.4
RUN python -m pip install --no-cache-dir dbt-redshift==1.9.5
RUN python -m pip install --no-cache-dir dbt-fabric==1.9.6
RUN python -m pip install --no-cache-dir re-data==0.11.0

# Create symlinks for commands
RUN ln -s /usr/local/bin/dbt /usr/bin/dbt
RUN ln -s /usr/local/bin/re_data /usr/bin/re_data

##
# Final image with scripts - this layer will be rebuilt when scripts change
##
FROM dbt-packages as dbt-bigquery-re-data
LABEL maintainer=support@fast.bi

# Copy scripts at the end so only this layer is rebuilt when scripts change
COPY ./api-entrypoint.sh /usr/app/dbt/
COPY ./cron_redata.sh /usr/app/dbt/
COPY ./backfill_redata.sh /usr/app/dbt/

# Set permissions in a single layer
RUN chmod 755 /usr/app/dbt/api-entrypoint.sh \
    && chmod 755 /usr/app/dbt/cron_redata.sh \
    && chmod 755 /usr/app/dbt/backfill_redata.sh

ENV RE_DATA_SEND_ANONYMOUS_USAGE_STATS=0

ENTRYPOINT ["/bin/bash", "-c", "/usr/app/dbt/api-entrypoint.sh" ]