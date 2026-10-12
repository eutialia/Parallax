#!/bin/bash
# Runs `swift test` on the macOS host for every host-capable package.
# Usage: scripts/verify.sh [filter]   (filter is passed to `swift test --filter`)
#
# Counts come from Swift Testing's "Test run with N tests" line: XCTest's
# "Executed N tests" omits these suites, so it can read zero on a real run.
set -euo pipefail

# Resolved from the script's own location, so any cwd works.
if ! REPO_ROOT=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null); then
    echo "ERROR: must be run inside a git checkout" >&2
    exit 1
fi

# Append here when a package becomes host-capable.
PACKAGES=(
    ParallaxCore
    ParallaxJellyfin
    ParallaxFileBrowse
    ParallaxSubtitles
)
# Packages that only build for a simulator; every other directory under Packages/ must be listed above.
SIMULATOR_ONLY=(
    ParallaxPlayback
)

UNLISTED=()
for dir in "$REPO_ROOT"/Packages/*/; do
    name=$(basename "$dir")
    case " ${PACKAGES[*]} ${SIMULATOR_ONLY[*]} " in
        *" $name "*) ;;
        *) UNLISTED+=("$name") ;;
    esac
done
if [ "${#UNLISTED[@]}" -ne 0 ]; then
    echo "ERROR: add ${UNLISTED[*]} to PACKAGES or SIMULATOR_ONLY in scripts/verify.sh" >&2
    exit 1
fi

FILTER=${1:-}
ARGS=()
[ -n "$FILTER" ] && ARGS=(--filter "$FILTER")

LOG=$(mktemp)
STATUS=$(mktemp)
trap 'rm -f "$LOG" "$STATUS"' EXIT

# swift test starts swiftpm-testing-helper in a process group of its own, so neither this
# script's death nor a signal to its group reaches the helper. Each package therefore runs as a
# background job in its own group (set -m), which keeps `timeout`'s group signal off swift test,
# and the trap walks the tree from here while every parent link is still intact.
set -m

kill_tree() {
    local child
    for child in $(pgrep -P "$1"); do kill_tree "$child"; done
    kill -TERM "$1" 2>/dev/null || true
}

on_signal() {
    trap - TERM INT HUP
    local child
    for child in $(pgrep -P $$); do kill_tree "$child"; done
    exit "$1"
}
trap 'on_signal 143' TERM
trap 'on_signal 130' INT
trap 'on_signal 129' HUP

START=$SECONDS
FAILED=0
TOTAL=0
SUMMARY=()

for pkg in "${PACKAGES[@]}"; do
    echo "==> $pkg"
    { (cd "$REPO_ROOT/Packages/$pkg" && swift test ${ARGS[@]+"${ARGS[@]}"}) 2>&1 \
        && echo 0 >"$STATUS" || echo $? >"$STATUS"; } | tee "$LOG" &
    wait $! || true
    status=$(cat "$STATUS")

    count=$(sed -nE 's/.*Test run with ([0-9]+) tests? .*/\1/p' "$LOG" | tail -1)
    count=${count:-0}
    TOTAL=$((TOTAL + count))

    if [ "$status" -ne 0 ]; then
        FAILED=1
        SUMMARY+=("FAIL  $pkg ($count tests run, exit $status)")
    elif [ -z "$FILTER" ] && [ "$count" -eq 0 ]; then
        FAILED=1
        SUMMARY+=("FAIL  $pkg (no tests ran)")
    else
        SUMMARY+=("ok    $pkg ($count tests passed)")
    fi
done

echo ""
printf '%s\n' "${SUMMARY[@]}"
echo "total: $TOTAL tests in $((SECONDS - START))s"

if [ "$FAILED" -ne 0 ]; then
    exit 1
fi

if [ "$TOTAL" -eq 0 ]; then
    echo "ERROR: no tests ran${FILTER:+ (filter '$FILTER' matched nothing in any package)}." >&2
    exit 1
fi
