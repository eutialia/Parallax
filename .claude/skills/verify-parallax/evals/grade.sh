#!/bin/bash
# Checks that a reference scenario still reproduces its case: it must fail its assertions with
# bug.patch applied and pass without it. setup.patch, when present, stays on in both runs.
# Usage: evals/grade.sh <case-dir> <scenario-file> <filter>
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ $# -eq 3 ] || { echo "usage: $0 <case-dir> <scenario-file> <filter>" >&2; exit 2; }
CASE_DIR=$(cd "$1" && pwd)
SCENARIO=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
FILTER=$3
BASE=$(case_base "$CASE_DIR")
SLOT=$(mktemp -d /tmp/eval-grade.XXXXXX)
trap 'rm -rf "$SLOT"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

T="$SLOT/tree"
tree_at "$T" "$BASE" || fail "could not read $BASE"
cp "$SCENARIO" "$T/Packages/ParallaxFeatures/Tests/ParallaxFeaturesTests/Scenarios/"
if [ -f "$CASE_DIR/setup.patch" ]; then
    git -C "$T" apply "$CASE_DIR/setup.patch" || fail "setup.patch does not apply on $BASE"
fi
git -C "$T" apply "$CASE_DIR/bug.patch" || fail "bug.patch does not apply on $BASE"

run_verify "$T" "$SLOT/with-bug.log" "$FILTER"
[ "$VERDICT" = fail ] || { show_failures "$SLOT/with-bug.log"; fail "with the bug the scenario did not fail its assertions ($VERDICT, $TESTS tests)"; }
echo "with bug: $TESTS tests, assertions failed (expected)"

git -C "$T" apply -R "$CASE_DIR/bug.patch" || fail "could not revert bug.patch"
run_verify "$T" "$SLOT/fixed.log" "$FILTER"
[ "$VERDICT" = pass ] || { show_failures "$SLOT/fixed.log"; fail "with the fix the scenario did not pass ($VERDICT, $TESTS tests)"; }
echo "fixed: $TESTS tests passed"
echo "PASS"
