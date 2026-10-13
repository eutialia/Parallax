#!/bin/bash
# Grades an evaluated agent's sandbox (made by sandbox.sh) after it finished.
# Usage: evals/grade-run.sh <case-dir> <sandbox-dir> <filter>
#
# The agent's tests are what it changed under Tests/ or *TestSupport/; everything else is its fix.
# Changes to scripts/ are rejected, and every run uses the base tree's verify.sh. PASS needs:
#   1. reproduces: the bugged tree plus the agent's tests fails <filter> on its assertions
#   2. fixed:      the bugged tree plus the agent's tests and fix passes <filter> and the full suite
#   3. agrees:     the bugged tree with the historical fix restored, plus the agent's tests, passes
#                  <filter>, so the tests pin the reported behavior and not the agent's fix
#   4. reference:  the bugged tree plus the agent's fix alone, with the original tests and the case's
#                  reference scenarios, passes the full suite. This catches a fix that breaks the
#                  behavior next door or edits an existing test to get through.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ $# -eq 3 ] || { echo "usage: $0 <case-dir> <sandbox-dir> <filter>" >&2; exit 2; }
CASE_DIR=$(cd "$1" && pwd)
SANDBOX=$(cd "$2" && pwd)
FILTER=$3
SLOT=$(mktemp -d /tmp/eval-run.XXXXXX)
trap 'rm -rf "$SLOT"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
TESTS_ONLY=(':(glob)**/Tests/**' ':(glob)**/*TestSupport/**')
PRODUCT_ONLY=(. ':(exclude,glob)**/Tests/**' ':(exclude,glob)**/*TestSupport/**')

ROOT=$(git -C "$SANDBOX" rev-list --max-parents=0 HEAD) || fail "$SANDBOX is not a sandbox repository"
git -C "$SANDBOX" add -A
git -C "$SANDBOX" diff --cached --quiet "$ROOT" -- scripts || fail "the agent changed scripts/"
git -C "$SANDBOX" diff --cached --binary "$ROOT" -- "${TESTS_ONLY[@]}" >"$SLOT/tests.patch"
git -C "$SANDBOX" diff --cached --binary "$ROOT" -- "${PRODUCT_ONLY[@]}" >"$SLOT/product.patch"
[ -s "$SLOT/tests.patch" ] || fail "the agent changed no tests"
echo "agent's fix:"
git -C "$SANDBOX" diff --cached --stat "$ROOT" -- "${PRODUCT_ONLY[@]}"

bugged() { # <dir> [patch...]: the tree the agent started from, plus the given patches
    local dir=$1
    shift
    tree_at "$dir" "$ROOT" "$SANDBOX" || fail "could not copy the sandbox root"
    local patch
    for patch in "$@"; do
        [ -s "$patch" ] || continue
        git -C "$dir" apply "$patch" || fail "$(basename "$patch") does not apply to the bugged tree"
    done
}

bugged "$SLOT/reproduces" "$SLOT/tests.patch"
run_verify "$SLOT/reproduces" "$SLOT/reproduces.log" "$FILTER"
[ "$VERDICT" = fail ] || { show_failures "$SLOT/reproduces.log"; fail "on the bugged tree the agent's tests did not fail their assertions ($VERDICT, $TESTS tests)"; }
echo "reproduces: $TESTS tests, assertions failed"

bugged "$SLOT/fixed" "$SLOT/tests.patch" "$SLOT/product.patch"
run_verify "$SLOT/fixed" "$SLOT/fixed.log" "$FILTER"
[ "$VERDICT" = pass ] || { show_failures "$SLOT/fixed.log"; fail "the agent's fix fails its own tests ($VERDICT, $TESTS tests)"; }
run_verify "$SLOT/fixed" "$SLOT/full.log"
[ "$VERDICT" = pass ] || { show_failures "$SLOT/full.log"; fail "the agent's fix fails the full suite ($VERDICT)"; }
echo "fixed: $FILTER and the full suite pass"

bugged "$SLOT/agrees" "$SLOT/tests.patch"
git -C "$SLOT/agrees" apply -R --exclude='*/Tests/*' --exclude='*TestSupport/*' "$CASE_DIR/bug.patch" \
    || fail "could not restore the historical fix under the agent's tests"
run_verify "$SLOT/agrees" "$SLOT/agrees.log" "$FILTER"
[ "$VERDICT" = pass ] || { show_failures "$SLOT/agrees.log"; fail "the agent's tests fail against the historical fix ($VERDICT, $TESTS tests)"; }
echo "agrees: the historical fix passes the agent's tests"

bugged "$SLOT/reference" "$SLOT/product.patch"
[ -f "$CASE_DIR/setup.patch" ] && { git -C "$SLOT/reference" apply "$CASE_DIR/setup.patch" || fail "setup.patch does not apply"; }
cp "$CASE_DIR"/reference/*.swift "$SLOT/reference/Packages/ParallaxFeatures/Tests/ParallaxFeaturesTests/Scenarios/"
run_verify "$SLOT/reference" "$SLOT/reference.log"
[ "$VERDICT" = pass ] || { show_failures "$SLOT/reference.log"; fail "the agent's fix fails the original tests or the reference scenarios ($VERDICT)"; }
echo "reference: the agent's fix passes the original tests and the reference scenarios"
echo "PASS"
