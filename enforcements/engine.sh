#!/usr/bin/env bash
# enforce-engine v3.3: PreToolUse hook — closes the warn-rationalization gap.
# v3.3 changes from v3.2:
#   - Per-rule bypass_env: conscious override via env var (e.g., CLAUDE_FORCE=1).
#     Bypasses are logged to ~/.polyglot/state/bypass-log.jsonl for audit.
#   - has_prior_tool: max_age_seconds filter (default 3600s). Stale matches no
#     longer silently suppress warnings (fixes Agent 3 audit finding).
#   - Session log: prefer parsed.session_id over date-keyed. No more cross-session
#     pollution (fixes Agent 3 audit finding).
#   - Bypass events logged to ~/.polyglot/state/bypass-log.jsonl for transparency.
# v3.2 changes from v3.1:
#   - New condition type: bash_heredoc_content_guard (closes Write/Edit->Bash bypass)
# v3.1 changes from v3.0:
#   - Accumulate ALL warn messages (not first-alpha-wins) → join at emit
#   - Use top-level systemMessage (high salience) instead of additionalContext (discrete)
#   - Recency-aware has_prior_tool: scans last 500 lines newest-first
set -euo pipefail

# Rule directory resolution (priority order):
#   1. POLYGLOT_RULES_DIR env var (set by install.sh — points at polyglot/enforcements/rules)
#   2. <script-dir>/rules (works when invoked via absolute path to this script)
#   3. Walk up for .claude/enforcements (backward-compat with non-polyglot setups)
find_rules_dir() {
    if [ -n "${POLYGLOT_RULES_DIR:-}" ] && [ -d "$POLYGLOT_RULES_DIR" ]; then
        echo "$POLYGLOT_RULES_DIR"; return 0
    fi
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    if [ -d "$script_dir/rules" ]; then
        echo "$script_dir/rules"; return 0
    fi
    local dir="$PWD"
    while [ "$dir" != "/" ]; do
        [ -d "$dir/.claude/enforcements" ] && echo "$dir/.claude/enforcements" && return 0
        dir=$(dirname "$dir")
    done
    return 1
}

ENFORCEMENTS_DIR=$(find_rules_dir 2>/dev/null) || exit 0
RULE_FILES=$(find "$ENFORCEMENTS_DIR" -name "*.json" -type f 2>/dev/null)
[ -z "$RULE_FILES" ] && exit 0

INPUT=$(cat)
export ENFORCE_INPUT="$INPUT"
export ENFORCE_DIR="$ENFORCEMENTS_DIR"
# v3.3: prefer session_id-scoped log over date-keyed; python layer picks the right one.
# Kept for backward compat: python fallback uses date if no session_id.
: "${ENFORCE_SESSION_LOG_DIR:=$HOME/.polyglot/session-logs}"
export ENFORCE_SESSION_LOG_DIR
: "${ENFORCE_BYPASS_LOG:=$HOME/.polyglot/state/bypass-log.jsonl}"
export ENFORCE_BYPASS_LOG

timeout 3 python3 -c '
import json, sys, os, re, glob, fnmatch, fcntl, time

raw_input = os.environ.get("ENFORCE_INPUT", "{}")
try:
    parsed = json.loads(raw_input)
except (json.JSONDecodeError, ValueError):
    print(json.dumps({"hookSpecificOutput": {"permissionDecision": "deny", "permissionDecisionReason": "enforce: malformed hook input, failing closed"}}))
    sys.exit(0)

tool_name = parsed.get("tool_name", "")
tool_input = parsed.get("tool_input", {})
if not tool_name:
    sys.exit(0)

# v3.3: session_id-scoped log if available, else date-keyed fallback.
session_id = parsed.get("session_id", "") or ""
log_dir = os.environ.get("ENFORCE_SESSION_LOG_DIR", os.path.expanduser("~/.polyglot/session-logs"))
if session_id:
    session_log = os.path.join(log_dir, "session-" + session_id + ".jsonl")
else:
    session_log = os.environ.get("ENFORCE_SESSION_LOG") or os.path.join(log_dir, time.strftime("%Y-%m-%d", time.gmtime()) + ".jsonl")
bypass_log = os.environ.get("ENFORCE_BYPASS_LOG", os.path.expanduser("~/.polyglot/state/bypass-log.jsonl"))
enforcements_dir = os.environ.get("ENFORCE_DIR", "")

# Log tool call (skip in test mode)
if session_log and tool_name and not os.environ.get("ENFORCE_TEST_MODE"):
    try:
        os.makedirs(os.path.dirname(session_log), exist_ok=True)
        detail = json.dumps(tool_input) if isinstance(tool_input, dict) else str(tool_input)
        entry = json.dumps({"tool": tool_name, "detail": detail[:500], "ts": time.time()})
        with open(session_log, "a") as lf:
            fcntl.flock(lf.fileno(), fcntl.LOCK_EX)
            lf.write(entry + "\n")
            fcntl.flock(lf.fileno(), fcntl.LOCK_UN)
    except (IOError, OSError):
        pass

rules = []
for f in sorted(glob.glob(os.path.join(enforcements_dir, "*.json"))):
    try:
        with open(f) as fh:
            rules.append(json.load(fh))
    except (json.JSONDecodeError, IOError):
        pass

if not rules:
    sys.exit(0)

def has_prior_tool(required_tool, args_pattern="", max_age_seconds=3600):
    """v3.3: adds max_age_seconds filter. Default 3600s kills stale matches that
    silently suppress warnings hours after the original call. Pass 0 to disable."""
    if not os.path.exists(session_log):
        return False
    # Support "Tool1|Tool2|Tool3" — match ANY
    valid_tools = set(required_tool.split("|")) if required_tool else set()
    cutoff = time.time() - max_age_seconds if max_age_seconds > 0 else 0
    try:
        import subprocess
        result = subprocess.run(
            ["tail", "-n", "500", session_log],
            capture_output=True, text=True, timeout=2
        )
        for line in reversed(result.stdout.splitlines()):
            try:
                e = json.loads(line.strip())
                # v3.3: enforce recency cutoff
                if cutoff and e.get("ts", 0) < cutoff:
                    continue
                if e.get("tool") in valid_tools:
                    if not args_pattern:
                        return True
                    # args_pattern is treated as regex (case-insensitive)
                    if re.search(args_pattern, e.get("detail", ""), re.IGNORECASE):
                        return True
            except json.JSONDecodeError:
                pass
    except (IOError, OSError, subprocess.TimeoutExpired):
        pass
    return False

final_action = None
block_message = ""
warn_messages = []  # v3.1: accumulate ALL warns (was: first-alpha-wins)

for rule in rules:
    trigger = rule.get("trigger", {})
    trigger_tools = trigger.get("tool", "").split("|")
    if tool_name not in trigger_tools:
        continue

    args_filter = trigger.get("args_filter", "")
    if args_filter:
        input_str = json.dumps(tool_input)
        if not re.search(args_filter, input_str, re.IGNORECASE):
            continue

    condition = rule.get("condition", {})
    cond_type = condition.get("type", "")
    action = rule.get("action", "block")
    message = rule.get("message", "Blocked by: " + rule.get("name", "unknown"))
    blocked = False

    if cond_type == "require_prior_tool":
        # v3.3: condition.max_age_seconds (default 3600). 0 = disable filter.
        max_age = condition.get("max_age_seconds", 3600)
        if not has_prior_tool(condition.get("tool", ""), condition.get("args_pattern", ""), max_age):
            blocked = True
    elif cond_type == "block_tool":
        blocked = True
    elif cond_type == "block_args":
        p = condition.get("pattern", "")
        if p and re.search(p, json.dumps(tool_input), re.IGNORECASE):
            blocked = True
    elif cond_type == "require_args":
        p = condition.get("pattern", "")
        if p and not re.search(p, json.dumps(tool_input), re.IGNORECASE):
            blocked = True
    elif cond_type == "block_file_pattern":
        fp = tool_input.get("file_path", tool_input.get("command", ""))
        for pat in condition.get("patterns", []):
            if fnmatch.fnmatch(fp, pat):
                blocked = True; break
    elif cond_type == "content_guard":
        content = tool_input.get("content", "") or tool_input.get("new_string", "")
        for pat in condition.get("patterns", []):
            if re.search(pat, content, re.IGNORECASE):
                blocked = True; break
    elif cond_type == "scoped_content_guard":
        fp = tool_input.get("file_path", "")
        scope = condition.get("scope", "")
        excludes = condition.get("exclude_scope", "")
        if isinstance(excludes, str): excludes = [excludes] if excludes else []
        content = tool_input.get("content", "") or tool_input.get("new_string", "")
        if scope and fnmatch.fnmatch(fp, scope):
            if any(fnmatch.fnmatch(fp, ex) for ex in excludes):
                pass
            else:
                for pat in condition.get("patterns", []):
                    if re.search(pat, content, re.IGNORECASE):
                        blocked = True; break
    elif cond_type == "bash_heredoc_content_guard":
        # v3.2: closes Write/Edit->Bash bypass for scoped_content_guard rules.
        # Extracts dest path + payload from a Bash command, applies scope+patterns.
        # Supported: cat/tee > FILE <<DELIM .. DELIM | echo/printf "..." > FILE | echo/printf "..." | tee FILE
        cmd = tool_input.get("command", "")
        scope = condition.get("scope", "")
        excludes = condition.get("exclude_scope", "")
        if isinstance(excludes, str): excludes = [excludes] if excludes else []
        dest_path = ""
        payload = ""
        m = re.search(r"(?:cat|tee)\s+[^<>|]*?>\s*[\x27\"]?([^\x27\"\s|&;]+)[\x27\"]?\s*<<-?\s*[\x27\"]?(\w+)[\x27\"]?\s*\n([\s\S]*?)\n\s*\2\s*$", cmd, re.MULTILINE)
        if m:
            dest_path = m.group(1)
            payload = m.group(3)
        else:
            m3 = re.search(r"(?:echo|printf)\s+(?:-[a-zA-Z]+\s+)*([\x27\"])(.+?)\1\s*>+\s*[\x27\"]?([^\x27\"\s|&;]+)[\x27\"]?", cmd, re.DOTALL)
            if m3:
                payload = m3.group(2)
                dest_path = m3.group(3)
            else:
                m4 = re.search(r"(?:echo|printf)\s+(?:-[a-zA-Z]+\s+)*([\x27\"])(.+?)\1\s*\|\s*tee\s+(?:-[a-zA-Z]+\s+)*[\x27\"]?([^\x27\"\s|&;]+)[\x27\"]?", cmd, re.DOTALL)
                if m4:
                    payload = m4.group(2)
                    dest_path = m4.group(3)
        if dest_path and scope and fnmatch.fnmatch(dest_path, scope):
            if any(fnmatch.fnmatch(dest_path, ex) for ex in excludes):
                pass
            else:
                for pat in condition.get("patterns", []):
                    if re.search(pat, payload, re.IGNORECASE):
                        blocked = True; break

    if blocked:
        directive = rule.get("directive", "")
        full_msg = "enforce: " + message
        if directive:
            full_msg += " (CLAUDE.md: \"" + directive[:80] + "\")"

        # v3.3: conscious override via env var. Bypass is logged for audit.
        bypass_env = rule.get("bypass_env", "")
        if bypass_env and os.environ.get(bypass_env):
            try:
                os.makedirs(os.path.dirname(bypass_log), exist_ok=True)
                entry = json.dumps({
                    "ts": time.time(),
                    "rule": rule.get("name", "unknown"),
                    "tool": tool_name,
                    "bypass_env": bypass_env,
                    "session_id": session_id or "unknown",
                    "intended_action": action,
                })
                with open(bypass_log, "a") as bf:
                    fcntl.flock(bf.fileno(), fcntl.LOCK_EX)
                    bf.write(entry + "\n")
                    fcntl.flock(bf.fileno(), fcntl.LOCK_UN)
            except (IOError, OSError):
                pass
            sys.stderr.write("enforce-bypass: " + rule.get("name","?") + " (via " + bypass_env + ")\n")
            continue  # skip this rule, move on

        if action == "block":
            final_action = "block"
            block_message = full_msg  # block short-circuits — first block wins
            break  # v3.1: stop iterating once we have a block
        elif action == "warn":
            warn_messages.append(full_msg)  # v3.1: accumulate, not overwrite

if final_action == "block":
    print(json.dumps({"hookSpecificOutput": {"permissionDecision": "deny", "permissionDecisionReason": block_message}}))
elif warn_messages:
    # v3.1: ALL warns emitted, via top-level systemMessage (high salience per Anthropic docs)
    joined = " | ".join(warn_messages)
    sys.stderr.write("enforce-warn: " + joined + "\n")
    print(json.dumps({
        "systemMessage": "<enforcement-warning>" + joined + "</enforcement-warning>",
        "hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": "<enforcement-warning>" + joined + "</enforcement-warning>"}
    }))
'
