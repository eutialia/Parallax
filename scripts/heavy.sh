#!/bin/bash
# Runs a command under a machine-wide lock, at low priority.
# Usage: scripts/heavy.sh <command...>
#
# One heavy job at a time: parallel builds and simulators nearly deadlocked the machine.
# The lock is a kernel flock on a file in /tmp, shared by every checkout and worktree.
# It is released when the holder exits, however it dies. Waiters queue indefinitely.
# /tmp/parallax-heavy.holder names the current holder's command.
exec /usr/bin/lockf -k /tmp/parallax-heavy.lock \
    sh -c 'echo "$*" > /tmp/parallax-heavy.holder; exec nice -n 10 "$@"' _ "$@"
