#!/usr/bin/env python3
"""
polyglot — Stop hook

Scans the final assistant message for language-drift (agent started
responding in the user's native language despite the English rule) and
blocks Stop with a remediation prompt. Hard cap at 3 blocks per session
to prevent infinite loops.

CONFIGURATION
-------------
  $POLYGLOT_LANGS       comma-separated ISO codes to scan for (default "pl")
  $POLYGLOT_MAX_BLOCKS  max Stop-blocks per session (default 3)
  $POLYGLOT_STATE_DIR   where to store block counter (default $HOME/.polyglot/state)

LICENSE
-------
MIT.
"""
from __future__ import annotations
import json
import os
import re
import sys
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_REPO_ROOT))

from languages import load as load_language  # noqa: E402


_ENABLED_LANGS = [
    c.strip() for c in os.environ.get("POLYGLOT_LANGS", "pl").split(",") if c.strip()
]
_MAX_BLOCKS = int(os.environ.get("POLYGLOT_MAX_BLOCKS", "3"))
_STATE_DIR = Path(
    os.environ.get("POLYGLOT_STATE_DIR")
    or os.path.expanduser("~/.polyglot/state")
)
_COUNTER_FILE = _STATE_DIR / "stop-block-counter.json"


def _load_counters() -> dict:
    if not _COUNTER_FILE.exists():
        return {}
    try:
        return json.loads(_COUNTER_FILE.read_text())
    except json.JSONDecodeError:
        return {}


def _save_counters(counters: dict) -> None:
    try:
        _STATE_DIR.mkdir(parents=True, exist_ok=True)
        _COUNTER_FILE.write_text(json.dumps(counters))
    except (IOError, OSError):
        pass


def _strip_code_blocks(text: str) -> str:
    """Remove fenced code and inline code so we don't flag PL identifiers."""
    text = re.sub(r"```[\s\S]*?```", "", text, flags=re.MULTILINE)
    text = re.sub(r"`[^`]+`", "", text)
    return text


def _last_assistant_text(transcript_path: str) -> str:
    if not transcript_path or not Path(transcript_path).exists():
        return ""
    try:
        lines = Path(transcript_path).read_text().splitlines()
    except (IOError, OSError):
        return ""

    # Scan from the end — find the most recent assistant message.
    # Blocks WITHIN one message are in source order, so append (not prepend).
    for line in reversed(lines[-200:]):
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        if ev.get("type") != "assistant":
            continue
        content = ev.get("message", {}).get("content", [])
        if not isinstance(content, list):
            continue
        parts = []
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                parts.append(block.get("text", ""))
        text = "\n".join(parts)
        if text.strip():
            return text
    return ""


def main() -> None:
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        sys.exit(0)

    if data.get("stop_hook_active"):
        sys.exit(0)   # infinite-loop guard

    session_id = data.get("session_id", "unknown")
    counters = _load_counters()
    current = counters.get(session_id, 0)
    if current >= _MAX_BLOCKS:
        sys.exit(0)   # cap reached, allow stop

    text = _last_assistant_text(data.get("transcript_path", ""))
    if not text.strip():
        sys.exit(0)

    prose = _strip_code_blocks(text)

    violations = []
    for code in _ENABLED_LANGS:
        try:
            plugin = load_language(code)
        except ImportError:
            continue
        hits = plugin.matched_words(prose)
        if len(set(hits)) >= 3:   # 3+ distinct hits = drift, not just a quote
            sample = ", ".join(sorted(set(hits))[:5])
            violations.append(
                f"{plugin.LANG_NAME_EN} drift: {len(set(hits))} distinct "
                f"{plugin.LANG_NAME_EN.lower()} tokens in assistant prose "
                f"(sample: {sample}). Respond in ENGLISH."
            )

    if not violations:
        sys.exit(0)

    counters[session_id] = current + 1
    _save_counters(counters)

    remaining = _MAX_BLOCKS - counters[session_id]
    reason = (
        "[Stop blocked — language drift detected]\n"
        + "\n".join(f"  - {v}" for v in violations)
        + f"\n\nFix before stopping. {remaining} Stop-block(s) left this "
        "session before cap auto-allows."
    )
    print(json.dumps({"decision": "block", "reason": reason}))


if __name__ == "__main__":
    main()
