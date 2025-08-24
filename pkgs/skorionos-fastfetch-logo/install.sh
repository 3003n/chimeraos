#!/bin/bash

# SkorionOS Fastfetch Logo Installation Script
# For system image pre-installation or manual installation

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGO_FILE="$SCRIPT_DIR/skorionos-logo.txt"
CONFIG_FILE="$SCRIPT_DIR/config.jsonc"

# System-wide installation paths
SYSTEM_LOGO_DIR="/usr/share/fastfetch/logos"
SYSTEM_CONFIG_DIR="/etc/xdg/fastfetch"

echo "Installing SkorionOS fastfetch logo..."

# Create directories
mkdir -p "$SYSTEM_LOGO_DIR"
mkdir -p "$SYSTEM_CONFIG_DIR"

# Install logo file
cp "$LOGO_FILE" "$SYSTEM_LOGO_DIR/skorionos.txt"
echo "✅ Installed logo: $SYSTEM_LOGO_DIR/skorionos.txt"

# Install system default config
cp "$CONFIG_FILE" "$SYSTEM_CONFIG_DIR/config.jsonc"
echo "✅ Installed config: $SYSTEM_CONFIG_DIR/config.jsonc"

echo "🎉 SkorionOS fastfetch logo installed successfully!"
echo
echo "Usage:"
echo "  fastfetch                           # Use system default config with SkorionOS logo"
echo "  fastfetch --logo skorionos          # Use SkorionOS logo specifically"
