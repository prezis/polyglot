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

read -r -d '' MSG << EOF || true
[CONTEXT COMPACTED — polyglot rule reload]

Context was just compacted. Re-anchor before next action:

1. ENGLISH OUTPUT — respond in English. Enabled source languages: ${LANGS}. Respond in the user's native language ONLY if explicitly requested.

2. LOCAL TRANSLATION — for native-language text tasks (SMS, email, document summarization, transcripts): call \`${TRANSLATE_TOOL}\`. FREE on local GPU.

3. LOCAL VISION — for screenshots / images: call \`${VISION_TOOL}\` FIRST before describing. FREE on local GPU.

Restate what you remember about the task in flight before executing more tool calls. Compaction strips procedural rules; reassert them now.
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
