#!/bin/bash

set -e

sub_manifest_paths=(branch/manifest-*)

source ./manifest

for sub_manifest in "${sub_manifest_paths[@]}"; do
  source "${sub_manifest}"
  AUR_PACKAGES="${AUR_PACKAGES} ${SUB_AUR_PACKAGES}"
done

# remove duplicates
AUR_PACKAGES=$(echo ${AUR_PACKAGES} | tr ' ' '\n' | sort -u | tr '\n' ' ')

echo ${AUR_PACKAGES} | tr -s ' \n' ' ' | jq -R -s -c 'split(" ") | map(select(length > 0))'
json_list=$(echo ${AUR_PACKAGES} | tr -s ' \n' ' ' | jq -R -s -c 'split(" ") | map(select(length > 0))')
echo ${json_list}

if [ -f "${GITHUB_OUTPUT}" ]; then
  echo "matrix=${json_list}" >> "${GITHUB_OUTPUT}"
fi
