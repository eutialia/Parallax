#!/bin/bash
# Installs git hooks into .git/hooks/. Run once after cloning.
# Backs up any existing pre-commit hook to .pre-commit.backup-<timestamp>.

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
HOOKS_DIR="$REPO_ROOT/.git/hooks"
HOOK_PATH="$HOOKS_DIR/pre-commit"
mkdir -p "$HOOKS_DIR"

if [ -e "$HOOK_PATH" ]; then
    backup="$HOOK_PATH.backup-$(date +%s)"
    mv "$HOOK_PATH" "$backup"
    echo "Existing pre-commit hook backed up to: $backup"
    echo "If it ran other checks (formatters, linters, secret scanners), chain"
    echo "them into the new hook manually after reviewing the backup."
fi

cat > "$HOOK_PATH" <<'EOF'
#!/bin/bash
set -e
REPO_ROOT=$(git rev-parse --show-toplevel)
"$REPO_ROOT/scripts/check-no-platform-drift.sh"
EOF

chmod +x "$HOOK_PATH"
echo "Installed pre-commit hook at $HOOK_PATH"
