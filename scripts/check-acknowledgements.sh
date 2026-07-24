#!/bin/bash
# Every SPM dependency in Package.resolved must be credited on the in-app About screen
# (Acknowledgements.swift) AND in CREDITS.md. Catches the silent-rot failure: a new
# dependency lands, the acknowledgements don't, and the shipped binary stops meeting
# its license terms.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

RESOLVED=Parallax.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
ACK=Parallax/Features/Settings/About/Acknowledgements.swift
CREDITS=CREDITS.md

MISSING=0
for identity in $(python3 -c "
import json
for pin in json.load(open('$RESOLVED'))['pins']:
    print(pin['identity'])
"); do
  if ! grep -q "\"${identity}\"" "$ACK"; then
    echo "UNCREDITED dependency: '${identity}' is in Package.resolved but not in ${ACK}" >&2
    MISSING=1
  fi
  # CREDITS.md uses display names, not quoted identities, so match the identity as a
  # case-insensitive word (e.g. identity 'get' ↔ '[Get](…)').
  if ! grep -qiE "\b${identity}\b" "$CREDITS"; then
    echo "UNCREDITED dependency: '${identity}' is in Package.resolved but not in ${CREDITS}" >&2
    MISSING=1
  fi
done

[ "$MISSING" -eq 0 ] && echo "acknowledgements: all $(python3 -c "
import json; print(len(json.load(open('$RESOLVED'))['pins']))") resolved packages are credited."
exit $MISSING
