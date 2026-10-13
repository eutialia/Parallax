#!/bin/bash
# Builds a history-free sandbox for one eval case: the base tree with the bug applied, committed once
# in a fresh repository, so neither `git log` nor `git diff` shows the fix or the bug. SKILL.md comes
# from the working tree, so an edited skill is evaluated without a new base. setup.patch is for the
# graders only: the agent builds whatever fakes it needs.
# Usage: evals/sandbox.sh <case-dir> <sandbox-dir>
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CASE=$(cd "$1" && pwd)
SANDBOX=$2
BASE=$(case_base "$CASE")

[ -e "$SANDBOX" ] && { echo "ERROR: $SANDBOX already exists" >&2; exit 1; }
tree_at "$SANDBOX" "$BASE"
rm -rf "$SANDBOX/.claude/skills/verify-parallax/evals"
cp "$REPO/.claude/skills/verify-parallax/SKILL.md" "$SANDBOX/.claude/skills/verify-parallax/SKILL.md"
git -C "$SANDBOX" apply "$CASE/bug.patch"
git -C "$SANDBOX" add -A
git -C "$SANDBOX" -c user.name=eval -c user.email=eval@localhost commit -q -m "Parallax"
echo "$SANDBOX"
