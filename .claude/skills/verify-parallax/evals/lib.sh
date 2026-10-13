# Sourced by the eval scripts. Sets EVALS and REPO, and defines case_base, tree_at and run_verify.

EVALS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(git -C "$EVALS" rev-parse --show-toplevel)

case_base() { # <case-dir>: the last commit that changed the case's patches
    # Each case is rolled against the tree its patches were last written for, so editing a script,
    # the README or another case never moves it. A SHA written into a script would not survive the
    # rebase-merge into main; this lookup does.
    echo "${EVAL_BASE:-$(git -C "$REPO" log -1 --format=%H -- "$1/bug.patch" "$1/setup.patch")}"
}

tree_at() { # <dir> <rev> [repo]: <rev>'s tree in a fresh one-directory git repo, so patches apply
    mkdir -p "$1" && git -C "${3:-$REPO}" archive "$2" | tar -x -C "$1" && git -C "$1" init -q
}

kill_tree() { # <pid>: TERM the process and everything under it
    local child
    for child in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$child"; done
    kill -TERM "$1" 2>/dev/null
}

run_verify() { # <dir> <log> [filter]; sets TESTS and VERDICT: pass, fail, none, timeout, crash or error
    local status
    if command -v timeout >/dev/null; then
        (cd "$1" && timeout 1500 scripts/verify.sh ${3:+"$3"}) >"$2" 2>&1
        status=$?
    elif command -v gtimeout >/dev/null; then
        (cd "$1" && gtimeout 1500 scripts/verify.sh ${3:+"$3"}) >"$2" 2>&1
        status=$?
    else
        (cd "$1" && exec scripts/verify.sh ${3:+"$3"}) >"$2" 2>&1 &
        local job=$!
        ( sleep 1500; kill_tree "$job" ) &
        local watchdog=$!
        wait "$job"
        status=$?
        kill "$watchdog" 2>/dev/null
        wait "$watchdog" 2>/dev/null
        [ "$status" -eq 143 ] && status=124
    fi
    TESTS=$(sed -nE 's/^total: ([0-9]+) tests? .*/\1/p' "$2" | tail -1)
    TESTS=${TESTS:-0}
    if [ "$status" -eq 124 ]; then VERDICT=timeout
    elif grep -qE "unexpected signal|Fatal error" "$2"; then VERDICT=crash
    elif [ "$TESTS" -eq 0 ]; then VERDICT=none
    elif [ "$status" -eq 0 ]; then VERDICT=pass
    elif grep -q "recorded an issue" "$2"; then VERDICT=fail
    else VERDICT=error
    fi
}

show_failures() { # <log>
    grep -E '^(✘|error:)' "$1" | head -20
}
