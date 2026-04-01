#!/usr/bin/env bash
set -euo pipefail

RELEASES_API="https://api.github.com/repos/fantom-lang/fantom/releases/latest"
DOWNLOAD_BASE="https://github.com/fantom-lang/fantom/releases/download"

# Fetch latest version tag
echo "Fetching latest Fantom version..."
LATEST=$(curl -sf "$RELEASES_API" | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')
if [ -z "$LATEST" ]; then
  echo "Warning: could not fetch latest version, defaulting to 1.0.83"
  LATEST="1.0.83"
fi

# Ask for version
read -rp "Fantom version to download [$LATEST]: " VERSION
VERSION="${VERSION:-$LATEST}"

# Ask for destination
read -rp "Destination directory [/tmp]: " DEST
DEST="${DEST:-/tmp}"

ZIP_NAME="fantom-${VERSION}.zip"
URL="${DOWNLOAD_BASE}/v${VERSION}/${ZIP_NAME}"
ZIP_PATH="${DEST}/${ZIP_NAME}"
INSTALL_DIR="${DEST}/fantom-${VERSION}"

echo ""
echo "Downloading Fantom ${VERSION} from:"
echo "  $URL"
echo "into: $DEST"
echo ""

mkdir -p "$DEST"
curl -L --progress-bar "$URL" -o "$ZIP_PATH"

echo "Unzipping..."
unzip -q "$ZIP_PATH" -d "$DEST"
chmod +x "$INSTALL_DIR"/bin/*

echo ""
echo "Done! Fantom ${VERSION} installed at:"
echo "  $INSTALL_DIR"
echo ""
echo "Run with:"
echo "  $INSTALL_DIR/bin/fan <build.fan>"
