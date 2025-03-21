#!/bin/bash

set -e

module_path="aur-pkgs/"

for module in $(ls $module_path); do
    if [ -d "$module_path/$module" ]; then
        echo "Updating $module"
        git submodule update --remote --init "$module_path/$module"
        sleep 1
    fi
done
