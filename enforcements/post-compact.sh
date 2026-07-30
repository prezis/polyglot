#!/usr/bin/env bash
# polyglot — SessionStart hook with matcher="compact"
#
# Fires after context compaction. Re-anchors the language-routing rule
# set before the agent keeps working. Attacks the documented
# post-compaction discipline-loss failure mode.
#
# Usage in settings.json:
#   "SessionStart": [{
#     "matcher": "compact",
#     "hooks": [{"type":"command","command":"bash /path/to/post-compact.sh"}]
#   }]
#
# LICENSE: MIT

set -euo pipefail

# Consume stdin (Claude sends JSON; we don't read it)
cat >/dev/null 2>&1 || true

LANGS="${POLYGLOT_LANGS:-pl}"
TRANSLATE_TOOL="${POLYGLOT_TRANSLATE_TOOL:-mcp__polyglot__translate}"
VISION_TOOL="${POLYGLOT_VISION_TOOL:-mcp__polyglot__vision}"

# 2026-07-30 — this message must NOT restate the user's language or tool-routing policy.
# It used to order "ENGLISH OUTPUT — respond in English" and "call the vision tool FIRST"
# after every compaction. On any install where the user's CLAUDE.md says otherwise (this
# machine: Polish conversation since 2026-07-27; the local vision tool forbidden since
# 2026-05-11), the hook was actively fighting the user at the exact moment the model is
# most suggestible — and the drift looked like the model ignoring the user, when it was
# obeying a stale hook. A reminder is a COPY of the user's canon, and copies drift; the
# durable design is to POINT at the canon, which the harness re-injects from disk anyway.
read -r -d '' MSG << EOF || true
[CONTEXT COMPACTED — polyglot rule reload]

Context was just compacted. Re-anchor before next action:

1. LANGUAGE — follow YOUR project's CLAUDE.md language policy; this hook does not define it
   and must never override it. Do not assume English. Translation source languages enabled
   here: ${LANGS}.

2. LOCAL TRANSLATION — for native-language text tasks (SMS, email, document summarization,
   transcripts): \`${TRANSLATE_TOOL}\` is available on the local GPU, IF your CLAUDE.md
   tool-routing policy routes such tasks there.

3. VISION — route screenshots/images per YOUR CLAUDE.md tool policy. (\`${VISION_TOOL}\`
   exists on this install; whether to use it is the canon's call, not this reminder's.)

Restate what you remember about the task in flight before executing more tool calls.
Compaction strips procedural rules — re-read them from CLAUDE.md, do not recall them.
EOF

# Prefer jq; fall back to python3 if jq unavailable (install.sh warns but doesn't require)
if command -v jq >/dev/null 2>&1; then
    jq -nc --arg m "$MSG" '{systemMessage: $m}'
else
    python3 -c "
import json, sys
msg = sys.argv[1]
print(json.dumps({'systemMessage': msg}))
" "$MSG"
fi
