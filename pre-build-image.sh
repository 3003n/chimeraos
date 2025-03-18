#! /bin/bash

set -e
set -x

BUILD_BRANCH=${BUILD_BRANCH:-}

if [ -z "${BUILD_BRANCH}" ]; then
  echo "BUILD_BRANCH must be specified"
  exit 1
fi

cp -rav branch/${BUILD_BRANCH}/rootfs/* rootfs/
