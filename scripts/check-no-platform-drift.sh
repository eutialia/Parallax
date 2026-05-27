#!/bin/bash
# Rejects platform-conditional code inside Packages/.
# Packages must compile identically on all supported platforms.

set -e

PACKAGES_DIR="Packages"

if [ ! -d "$PACKAGES_DIR" ]; then
    echo "$PACKAGES_DIR not found — running from the repo root?"
    exit 0
fi

# Use ripgrep if available, else fall back to grep -r.
if command -v rg > /dev/null 2>&1; then
    MATCHES=$(rg -n '^\s*#if\s+os\(' "$PACKAGES_DIR" --type swift || true)
else
    MATCHES=$(grep -rn '^\s*#if\s\+os(' "$PACKAGES_DIR" --include='*.swift' || true)
fi

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
