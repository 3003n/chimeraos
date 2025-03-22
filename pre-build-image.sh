#! /bin/bash

set -e
set -x

BUILD_BRANCH=${BUILD_BRANCH:-}

if [ -z "${BUILD_BRANCH}" ]; then
  echo "BUILD_BRANCH must be specified"
  exit 1
fi

echo "Merging branch ${BUILD_BRANCH} into rootfs"
cp -rav branch/${BUILD_BRANCH}/rootfs/* rootfs/
cp -f branch/${BUILD_BRANCH}/sub-manifest .

source ./manifest
source ./sub-manifest

mv aur-pkgs aur-pkgs-ori
mv pkgs pkgs-ori

mkdir -p aur-pkgs
mkdir -p pkgs


echo "Copying branch aur packages"
# branch aur packages
for package in ${SUB_AUR_PACKAGES}; do
  # echo "copying ${package}"
  cp -rv "aur-pkgs-ori/[${package}]-"*.pkg.tar* aur-pkgs/ || true
done

# public aur packages
for package in ${AUR_PACKAGES}; do
  # echo "copying ${package}"
  cp -rv "aur-pkgs-ori/[${package}]-"*.pkg.tar* aur-pkgs/ || true
done

# branch local packages
for package in ${SUB_LOCAL_PACKAGES}; do
  # echo "copying ${package}"
  cp -rv "pkgs-ori/[${package}]-"*.pkg.tar* pkgs/ || true
done

rm -rf aur-pkgs-ori
rm -rf pkgs-ori

tree