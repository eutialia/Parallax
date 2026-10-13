# verify-parallax evals

Each case is a past Parallax bug re-introduced into today's code. An agent that has only the skill and the user's report must reproduce it with a scenario, find the cause and fix it. The sandbox deletes this directory, so nothing here reaches the agent.

A case directory holds:

- `report.md`: the user's report, the only input the agent gets
- `bug.patch`: re-introduces the bug, including the comments the historical fix added
- `setup.patch` (optional): test seams the reference scenario needs; only the graders apply it
- `reference/`: a scenario that proves the case is solvable
- `expected.md`: the root cause, for the human reviewing the run

## Running a case

1. `evals/sandbox.sh <case> <dir>` builds a one-commit repository from the base with the bug applied.
2. Give a fresh agent `evals/agent-prompt.md` with `{{SANDBOX}}` and `{{REPORT}}` filled in.
3. `evals/grade-run.sh <case> <dir> <SuiteType>` grades the result. Its header lists the four checks.
4. Compare the agent's root cause with `expected.md`.

`evals/grade.sh <case> <reference-file> <SuiteType>` checks that a reference scenario still fails with the bug and passes without it. Run it for every case after the code a case touches changes.

## The base

Each case has its own base: the last commit that changed its `bug.patch` or `setup.patch` (`case_base` in `lib.sh`). Edits to scripts, this README or another case do not move it. After the code a case touches moves, re-roll its patches against the current tree and commit them; that commit becomes the case's new base. `EVAL_BASE=<rev>` overrides it for one run.

## Limits

The sandbox has no history, but the agent runs on the same machine as the real repository. Isolation holds only while the agent stays inside the sandbox as its prompt says. Check its transcript for paths outside the sandbox before trusting a pass.
