#!/bin/bash

# SkorionOS Fastfetch Wrapper Script
# Automatically uses skorionos logo when no arguments provided
# Preserves all other fastfetch functionality

# Path to original fastfetch binary
FASTFETCH_BIN="/usr/bin/fastfetch.orig"

# Path to skorionos config preset
SKORIONOS_CONFIG="skorionos"

# Check if no arguments provided
if [[ $# -eq 0 ]]; then
    # No arguments - use skorionos config
    exec "$FASTFETCH_BIN" --config "$SKORIONOS_CONFIG"
else
    # Arguments provided - pass through to original fastfetch
    exec "$FASTFETCH_BIN" "$@"
fi
