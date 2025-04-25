#!/bin/bash

set -e

module_path="aur-pkgs/"

for module in "$module_path"*; do
    if [ -d "$module" ]; then
        echo "Updating $(basename "$module")"
        git submodule update --remote --init "$module" || true
        sleep 1
    fi
done
