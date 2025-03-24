#!/bin/bash

set -e

module_path="aur-pkgs/"

for module in "$module_path"*; do
    if [ -d "$module" ]; then
        echo "Removing $(basename "$module")"
        git submodule deinit -f "$module"
        git rm -f "$module"
        rm -rf "$module" || true
    fi
done
