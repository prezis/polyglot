#!/usr/bin/env bash
# polyglot PII scanner — runs in pre-commit + CI. Any hit = FAIL.
#
# Two sources of patterns:
#
#   1. BUILT-IN (shipped, always active) — universal leaks everyone cares
#      about: wallet addresses, private keys, API token shapes, absolute
#      home paths. Lives in this file. Safe to be public.
#
#   2. LOCAL (.pii-patterns.local, gitignored) — contributor-specific
#      identifiers: your real name, handles, private project names, your
#      home path. NEVER tracked by git (see .gitignore). Copy
#      .pii-patterns.example to .pii-patterns.local and fill it in.
#
# This split prevents the classic anti-pattern where a scanner file
# publishes exactly the identifiers it was written to block. (That's what
# an earlier version of this file did.)

set -u
FAIL=0
ROOT="${1:-.}"

ALLOWLIST_STRINGS_FILE="${ROOT}/.pii-allowlist"
LOCAL_PATTERNS_FILE="${ROOT}/.pii-patterns.local"

# -- BUILT-IN universal patterns -----------------------------------------
# Each line: pattern|reason. Case-insensitive.
PATTERNS=(
    # Generic absolute paths — replace with $HOME / env vars
    '/home/[a-z][a-z0-9_-]{2,}/|absolute home path (use $HOME or placeholder)'
    '/Users/[A-Za-z][A-Za-z0-9_-]{2,}/|absolute macOS home path'

    # Crypto wallet addresses (entropy-heavy — false positives possible)
    '\b0x[a-fA-F0-9]{40}\b|possible Ethereum/EVM wallet address'

    # Private key shapes
    '-----BEGIN (RSA |OPENSSH |EC |DSA )?PRIVATE KEY-----|PEM private key header'
    '-----BEGIN PGP PRIVATE KEY BLOCK-----|PGP private key header'

    # API / auth tokens
    'AKIA[0-9A-Z]{16}|AWS access key'
    'ghp_[A-Za-z0-9]{36,}|GitHub personal access token'
    '\bxox[aboprs]-[0-9A-Za-z-]{10,48}|Slack token'
    '\b\d{8,10}:[A-Za-z0-9_-]{35}|Telegram bot token'

    # Env-file leakage
    '\b(AWS_SECRET_ACCESS_KEY|DATABASE_URL|JWT_SECRET|OPENAI_API_KEY|ANTHROPIC_API_KEY)\s*=\s*[^\s]{8,}|env-style secret assignment'
)

# -- LOCAL patterns (optional, gitignored) ------------------------------
if [ -f "$LOCAL_PATTERNS_FILE" ]; then
    while IFS= read -r line; do
        # Skip comments and blank lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$line" || "$line" =~ ^[[:space:]]*$ ]] && continue
        PATTERNS+=("$line")
    done < "$LOCAL_PATTERNS_FILE"
fi

# -- Allowlist (optional file with one exact substring per line) -------
ALLOWLIST_STRINGS=()
ALLOWLIST_FILES='(README\.md|CONTRIBUTING\.md|LICENSE)$'
if [ -f "$ALLOWLIST_STRINGS_FILE" ]; then
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$line" || "$line" =~ ^[[:space:]]*$ ]] && continue
        ALLOWLIST_STRINGS+=("$line")
    done < "$ALLOWLIST_STRINGS_FILE"
fi

# -- Scan --------------------------------------------------------------
for entry in "${PATTERNS[@]}"; do
    pattern="${entry%%|*}"
    reason="${entry#*|}"
    hits=$(grep -rInEi \
        --exclude-dir=.git \
        --exclude-dir=__pycache__ \
        --exclude-dir=node_modules \
        --exclude=".gitleaks.toml" \
        --exclude=".pii-patterns.local" \
        --exclude=".pii-allowlist" \
        "$pattern" "$ROOT" 2>/dev/null || true)

    # Filter: a hit is allowed IFF it's in an ALLOWLIST_FILES file AND
    # the matched line contains an ALLOWLIST_STRINGS substring.
    if [ -n "$hits" ]; then
        filtered=""
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            file_path="${line%%:*}"
            rest="${line#*:}"
            allowed=0
            if echo "$file_path" | grep -qE "$ALLOWLIST_FILES"; then
                for s in "${ALLOWLIST_STRINGS[@]}"; do
                    if echo "$rest" | grep -qiF "$s"; then
                        allowed=1
                        break
                    fi
                done
            fi
            [ "$allowed" -eq 0 ] && filtered+="$line"$'\n'
        done <<< "$hits"

        if [ -n "$filtered" ]; then
            printf '\033[31mLEAK (%s):\033[0m %s\n' "$reason" "$pattern"
            printf '%s\n' "$filtered"
            FAIL=1
        fi
    fi
done

if [ "$FAIL" -eq 0 ]; then
    printf '\033[32mOK\033[0m — no PII / private identifiers detected in %s\n' "$ROOT"
else
    printf '\033[31mFAIL\033[0m — fix the above before pushing.\n'
fi
exit $FAIL
