#!/bin/bash
# Rejects platform-conditional code inside Packages/.
# Packages must compile identically on all supported platforms.

set -euo pipefail

# Resolve repo root via git so the script works from any cwd
# (a hook installed in .git/hooks invokes us with PWD = repo root,
# but a manual run from a subdir would otherwise silently miss the dir).
if ! REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
    echo "ERROR: must be run inside a git checkout" >&2
    exit 1
fi

PACKAGES_DIR="$REPO_ROOT/Packages"

if [ ! -d "$PACKAGES_DIR" ]; then
    echo "ERROR: $PACKAGES_DIR not found — repo layout has drifted from the architecture spec." >&2
    exit 1
fi

# Catches every form of platform-conditional compilation banned in packages:
#   #if os(iOS)          / #if !os(macOS)        — direct platform branch
#   #if canImport(UIKit) / #if canImport(AppKit) — import-based branch
#   #if targetEnvironment(simulator)             — simulator-only code
# Tested with both ripgrep and POSIX grep -E.
PATTERN='^[[:space:]]*#if[[:space:]]+(!?os\(|canImport\(|targetEnvironment\()'

if command -v rg > /dev/null 2>&1; then
    MATCHES=$(rg -n --pcre2 "$PATTERN" "$PACKAGES_DIR" --type swift || true)
else
    # BSD grep on macOS treats \s as literal 's'. Use POSIX character classes
    # via -E (ERE) so the same regex works on both GNU and BSD grep.
    MATCHES=$(grep -rnE "$PATTERN" --include='*.swift' "$PACKAGES_DIR" || true)
fi

# The one sanctioned exception: VideoLAN ships the same VLCKit under two module
# names (MobileVLCKit on iOS, TVVLCKit on tvOS), so the import line has to pick
# one. That renames a module — no logic branches on it — which is why this exact
# form is allowed and every other conditional still fails the check.
ALLOWED='#if[[:space:]]+canImport\(MobileVLCKit\)[[:space:]]*$'
MATCHES=$(printf '%s' "$MATCHES" | grep -vE "$ALLOWED" || true)

if [ -n "$MATCHES" ]; then
    echo ""
    echo "ERROR: Platform conditional found in $PACKAGES_DIR/."
    echo ""
    echo "$MATCHES"
    echo ""
    echo "Packages must compile identically on iOS, iPadOS, and (later) tvOS."
    echo "Move platform-specific code into the app target's Platform/ folder."
    echo ""
    exit 1
fi

exit 0
