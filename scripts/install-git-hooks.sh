#!/usr/bin/env bash
# polyglot — install pre-commit hook that runs pii-scan + gitleaks
# Run from repo root. Creates .git/hooks/pre-commit.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$REPO_ROOT" ]; then
    echo "✗ not a git repo — run 'git init' first"
    exit 1
fi

HOOK="$REPO_ROOT/.git/hooks/pre-commit"
mkdir -p "$(dirname "$HOOK")"

# Write a small shim. We avoid nesting heredocs.
cat > "$HOOK" << 'INNEREOF'
#!/usr/bin/env bash
# polyglot pre-commit — blocks commits that leak PII or secrets
set -e
REPO_ROOT="$(git rev-parse --show-toplevel)"

# 1. Custom PII scan (always runs)
bash "$REPO_ROOT/scripts/pii-scan.sh" "$REPO_ROOT"

# 2. gitleaks (optional — warns if not installed)
if command -v gitleaks >/dev/null 2>&1; then
    gitleaks protect --staged --config "$REPO_ROOT/.gitleaks.toml" -v
else
    echo "WARN: gitleaks not installed (recommended)."
    echo "      Install: https://github.com/gitleaks/gitleaks#installing"
fi
INNEREOF
chmod +x "$HOOK"
echo "✓ pre-commit hook installed at $HOOK"
echo "  It runs pii-scan.sh + gitleaks (if available) before every commit."
echo "  To bypass (not recommended): git commit --no-verify"
