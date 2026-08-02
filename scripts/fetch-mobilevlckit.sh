#!/bin/zsh
# Fetches the VLCKit binaries the ParallaxPlayback package vendors on the 3.x
# branch. VideoLAN ships iOS and tvOS as two separately named modules built from
# the same source, and the app runs on both, so both are needed. Together they
# unpack to ~1.7 GB, so they are git-ignored and fetched on demand instead of
# committed.
set -euo pipefail

# Keep the two versions in lockstep — the hashes are the same upstream build.
MOBILE_VERSION="MobileVLCKit-3.7.3-319ed2c0-79128878"
TV_VERSION="TVVLCKit-3.7.3-319ed2c0-79128878"

DEST="$(dirname "$0")/../Packages/ParallaxPlayback/Vendor"
BASE_URL="https://download.videolan.org/pub/cocoapods/prod"

# fetch <framework name> <archive version string>
# Downloads and unpacks one xcframework, skipping the work if it is already there.
fetch() {
    local name="$1" version="$2"
    if [ -d "$DEST/$name.xcframework" ]; then
        echo "$name: already present"
        return 0
    fi
    local tmp
    tmp=$(mktemp -d)
    # The trap is per-invocation so an interrupted run cannot leave a partial
    # xcframework behind for the next run to mistake for a good one.
    trap 'rm -rf "$tmp"' EXIT
    echo "$name: downloading $version"
    curl -sSL -o "$tmp/kit.tar.xz" "$BASE_URL/$version.tar.xz"
    tar -xf "$tmp/kit.tar.xz" -C "$tmp" "$name-binary/$name.xcframework"
    mkdir -p "$DEST"
    mv "$tmp/$name-binary/$name.xcframework" "$DEST/"
    rm -rf "$tmp"
    trap - EXIT
    echo "$name: installed → $DEST/$name.xcframework"
}

fetch MobileVLCKit "$MOBILE_VERSION"
fetch TVVLCKit "$TV_VERSION"
