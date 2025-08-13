#!/bin/bash

set -e

ACTION=$1


release_info=$(curl -sL "https://www.cursor.com/api/download?platform=linux-x64&releaseTrack=latest")

version=$(echo "$release_info" | grep -Po '"version":"\K[^"]+')
download_url=$(echo "$release_info" | grep -Po '"downloadUrl":"\K[^"]+')

case $ACTION in
    "version")
        echo $version
        ;;
    "download_url")
        echo $download_url
        ;;
    "download")
        curl -L -o "cursor-${version}.Appimage" "${download_url}"
        ;;
    *)
        echo "Usage: $0 [version|download_url|download]"
        ;;
esac
