#!/bin/bash
# Rejects a SwiftUI struct that reads @Environment(\.dismiss) and also owns a
# NavigationStack or .navigationDestination. DismissAction changes whenever the
# stack's pushed state changes, so the owner re-renders; tvHidesTabSidebar changes
# it on every pass and the app spins at 100% CPU (hit three times).

set -euo pipefail

if ! ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
    echo "ERROR: must be run inside a git checkout" >&2
    exit 1
fi

APP_DIR="$ROOT/Parallax"

if [ ! -d "$APP_DIR" ]; then
    echo "ERROR: $APP_DIR not found — repo layout has drifted from the architecture spec." >&2
    exit 1
fi

# Struct-scoped, not file-scoped: a leaf view that reads dismiss may share a file
# with views that own navigation. Extensions count toward the type they extend, and
# a match belongs to the innermost struct/extension containing it.
exec python3 -I -c '
import os, re, sys

DISMISS = re.compile(r"@Environment\(\\\.dismiss\)")
NAV = re.compile(r"\bNavigationStack\b|navigationDestination")
HEADER = re.compile(r"\b(?:struct|extension)\s+([A-Za-z_][\w.]*)[^{};]*\{")

def blank(src):
    """Blank comments and string contents, keeping offsets and newlines."""
    out, i, n = [], 0, len(src)
    keep = lambda s: "".join(c if c == "\n" else " " for c in s)
    while i < n:
        two = src[i:i + 2]
        if two == "//":
            j = src.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i)); i = j
        elif two == "/*":
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append(keep(src[i:j])); i = j
        elif src[i] == "\"":
            end = "\"\"\"" if src[i:i + 3] == "\"\"\"" else "\""
            j = i + len(end)
            while j < n and src[j:j + len(end)] != end:
                j += 2 if src[j] == "\\" else 1
            j = min(j + len(end), n)
            out.append(keep(src[i:j])); i = j
        else:
            out.append(src[i]); i += 1
    return "".join(out)

def blocks(text):
    found = []
    for m in HEADER.finditer(text):
        depth, j = 1, m.end()
        while j < len(text) and depth:
            depth += (text[j] == "{") - (text[j] == "}")
            j += 1
        found.append((m.group(1), m.end(), j))
    return found

def innermost(found, pos):
    inside = [b for b in found if b[1] <= pos < b[2]]
    return min(inside, key=lambda b: b[2] - b[1])[0] if inside else None

owners = {}
for dirpath, _, files in os.walk(sys.argv[1]):
    for f in sorted(files):
        if not f.endswith(".swift"):
            continue
        path = os.path.join(dirpath, f)
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = blank(fh.read())
        found = blocks(text)
        for kind, rx in (("dismiss", DISMISS), ("nav", NAV)):
            for m in rx.finditer(text):
                name = innermost(found, m.start())
                if name:
                    owners.setdefault(name, {})[kind] = (path, text.count("\n", 0, m.start()) + 1)

violations = [(name, h["dismiss"], h["nav"]) for name, h in owners.items() if len(h) == 2]

if violations:
    print()
    print("ERROR: a view reads @Environment(\\.dismiss) and owns navigation in the same struct.")
    print()
    for name, (dp, d), (np, n) in sorted(violations):
        print(f"{dp}:{d}: {name} reads dismiss; owns navigation at {np}:{n}")
    print()
    print("DismissAction changes with the stack state, so the owner re-renders on every")
    print("change; on tvOS tvHidesTabSidebar changes it every pass and the app freezes.")
    print("Move the dismiss read into a leaf view, or pass an explicit close callback.")
    print()
    sys.exit(1)
' "$APP_DIR"
