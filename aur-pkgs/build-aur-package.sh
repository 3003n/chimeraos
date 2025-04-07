#!/bin/bash

set -e
set -x

source manifest;

sudo mkdir -p /temp/package
sudo chown build:build /temp/package
sudo chown build:build /workdir/aur-pkgs

git clone --depth=1 https://aur.archlinux.org/${1}.git /temp/package

PIKAUR_CMD="PKGDEST=/workdir/aur-pkgs MAKEFLAGS=-j$(nproc) pikaur --noconfirm --build-gpgdir /etc/pacman.d/gnupg -S -P /temp/package/PKGBUILD"
PIKAUR_RUN=(bash -c "${PIKAUR_CMD}")

# 重试次数
MAX_RETRIES=3
RETRY_COUNT=0

set +e
while [ ${RETRY_COUNT} -lt ${MAX_RETRIES} ]; do
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo ">>>>>> Build (${RETRY_COUNT}/${MAX_RETRIES})"
    "${PIKAUR_RUN[@]}"
    if [ $? -ne 0 ]; then
        continue
    fi
    # remove any epoch (:) in name, replace with -- since not allowed in artifacts
    find /workdir/aur-pkgs/*.pkg.tar* -type f -name '*:*' -execdir bash -c 'mv "$1" "${1//:/--}"' bash {} \;
    if [ $? -ne 0 ]; then
        continue
    fi
    break
done
set -e

# 如果重试3次后仍然失败，则退出
if [ ${RETRY_COUNT} -eq ${MAX_RETRIES} ]; then
    echo ">>>>>> Build failed after ${MAX_RETRIES} attempts. Stopping..."
    exit 1
fi
