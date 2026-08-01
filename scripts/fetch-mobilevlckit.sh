#!/bin/zsh
# Fetches the MobileVLCKit binary the ParallaxPlayback package vendors on the
# 3.x branch. The xcframework is ~1 GB unpacked, so it is git-ignored and
# fetched on demand instead of committed.
set -euo pipefail
VERSION="MobileVLCKit-3.7.3-319ed2c0-79128878"
DEST="$(dirname "$0")/../Packages/ParallaxPlayback/Vendor"
[ -d "$DEST/MobileVLCKit.xcframework" ] && { echo "already present"; exit 0; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -sSL -o "$TMP/kit.tar.xz" "https://download.videolan.org/pub/cocoapods/prod/$VERSION.tar.xz"
tar -xf "$TMP/kit.tar.xz" -C "$TMP" MobileVLCKit-binary/MobileVLCKit.xcframework
mkdir -p "$DEST"
mv "$TMP/MobileVLCKit-binary/MobileVLCKit.xcframework" "$DEST/"
echo "installed → $DEST/MobileVLCKit.xcframework"
