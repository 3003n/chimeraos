#!/bin/bash

set -e

module_path="aur-pkgs/"

for module in $(ls $module_path); do
    if [ -d "$module_path/$module" ]; then
        echo "Removing $module"
        git submodule deinit -f "$module_path/$module"
        git rm -f "$module_path/$module"
        rm -rf "$module_path/$module" || true
    fi
done
