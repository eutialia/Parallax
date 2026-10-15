#!/bin/bash
# Rejects literal Swift Testing `.timeLimit(` outside the trait that defines it.
# Tests use `.scaledTimeLimit(...)` so CI hardware gets a scaled ceiling.

set -euo pipefail

if ! REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
    echo "ERROR: must be run inside a git checkout" >&2
    exit 1
fi

TRAIT="Packages/ParallaxCore/Sources/ParallaxTestScaling/CITimeScale.swift"

MATCHES=$(cd "$REPO_ROOT" && grep -rnF --include='*.swift' --exclude-dir=.build '.timeLimit(' \
        Packages/*/Tests Packages/*/Sources ParallaxTests \
    | grep -vF "$TRAIT:" || true)

if [ -n "$MATCHES" ]; then
    echo ""
    echo "ERROR: literal .timeLimit( found."
    echo ""
    echo "$MATCHES"
    echo ""
    echo "Use .scaledTimeLimit(minutes:) from ParallaxTestScaling so CI scales the ceiling."
    echo ""
    exit 1
fi

exit 0
