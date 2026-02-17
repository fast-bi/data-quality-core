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

init_version="v0.1.3"

# docker buildx build . \
#   --pull \
#   --tag europe-central2-docker.pkg.dev/fast-bi-common/bi-platform/tsb-redata-core:${init_version} \
#   --platform linux/amd64 \
#   --push

docker buildx build . \
  --pull \
  --tag 4fastbi/data-quality-core:${init_version} \
  --tag 4fastbi/data-quality-core:latest \
  --platform linux/amd64 \
  --push