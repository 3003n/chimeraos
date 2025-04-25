#! /bin/bash

set -e
set -x

BUILD_BRANCH=${BUILD_BRANCH:-}

if [ -z "${BUILD_BRANCH}" ]; then
  echo "BUILD_BRANCH must be specified"
  exit 1
fi

echo "Merging branch ${BUILD_BRANCH} into rootfs"

cp -f branch/manifest-${BUILD_BRANCH} sub-manifest
cp -f branch/base-* .

source ./manifest
source ./sub-manifest

if [ -n "${POSTCOPY}" ]; then
  echo "Copying postcopy files"
  for dir in ${POSTCOPY}; do
    echo "Copying ${dir}"
    cp -rav postcopy/${dir}/* rootfs/
  done
fi

mv aur-pkgs aur-pkgs-ori
mv pkgs pkgs-ori

mkdir -p aur-pkgs-ori-clean
mkdir -p pkgs-ori-clean

mkdir -p aur-pkgs
mkdir -p pkgs

# Function to clean duplicate packages
clean_duplicate_packages() {
  local src_dir=$1
  local dest_dir=$2
  local -A seen_packages

  # Process each package file
  for pkg_file in "${src_dir}"/*.pkg.tar*; do
    if [ ! -f "$pkg_file" ]; then
      continue
    fi

    # Extract package name without the [source] prefix
    local pkg_name=$(basename "$pkg_file" | sed -E 's/^\[[^]]*\]-//')
    
    # If we haven't seen this package name before, copy it
    if [ -z "${seen_packages[$pkg_name]}" ]; then
      cp -v "$pkg_file" "$dest_dir/"
      seen_packages[$pkg_name]=1
    else
      echo "Skipping duplicate package: $pkg_name"
    fi
  done
}

# Clean duplicate packages
echo "Cleaning duplicate packages in aur-pkgs-ori"
clean_duplicate_packages "aur-pkgs-ori" "aur-pkgs-ori-clean"

echo "Cleaning duplicate packages in pkgs-ori"
clean_duplicate_packages "pkgs-ori" "pkgs-ori-clean"

echo "Copying branch aur packages"
# branch aur packages
for package in ${SUB_AUR_PACKAGES}; do
  # echo "copying ${package}"
  cp -rv "aur-pkgs-ori-clean/[${package}]-"*.pkg.tar* aur-pkgs/ || true
done

# public aur packages
for package in ${AUR_PACKAGES}; do
  # echo "copying ${package}"
  cp -rv "aur-pkgs-ori-clean/[${package}]-"*.pkg.tar* aur-pkgs/ || true
done

# branch local packages
for package in ${SUB_LOCAL_PACKAGES}; do
  # echo "copying ${package}"
  cp -rv "pkgs-ori-clean/[${package}]-"*.pkg.tar* pkgs/ || true
done

rm -rf aur-pkgs-ori
rm -rf pkgs-ori
rm -rf aur-pkgs-ori-clean
rm -rf pkgs-ori-clean

tree