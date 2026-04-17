#!/usr/bin/env python3
"""
polyglot — UserPromptSubmit hook

Detects non-English input (Polish / Russian / CJK / …) in the user's
prompt and injects a high-salience <enforcement-reminder> asking the
agent to:

  1. Respond in English (saves ~20% tokens on Polish, ~50% on CJK —
     Claude's BPE tokenizer fragments non-English heavily).
  2. Route Polish text tasks (SMS / email / translation) through the
     local translator (e.g. `polyglot_translate` from polyglot-mcp).
  3. Route pasted images through local vision + translator.

CONFIGURATION
-------------
  $POLYGLOT_LANGS          comma-separated ISO codes (default: "pl")
  $POLYGLOT_TRANSLATE_TOOL MCP tool name (default: mcp__polyglot__translate)
  $POLYGLOT_VISION_TOOL    MCP tool name (default: mcp__polyglot__vision)
  $POLYGLOT_CODE_DIR       skip detection if prompt is pure code from
                           these dirs (colon-separated, optional)

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

# Add the languages dir to path (assumes ../languages relative to this hook)
_REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_REPO_ROOT))

from languages import load as load_language, available as available_languages  # noqa: E402


# ----------------------------------------------------------------------
# Config
# ----------------------------------------------------------------------
_ENABLED_LANGS = [
    c.strip() for c in os.environ.get("POLYGLOT_LANGS", "pl").split(",") if c.strip()
]
_TRANSLATE_TOOL = os.environ.get("POLYGLOT_TRANSLATE_TOOL", "mcp__polyglot__translate")
_VISION_TOOL = os.environ.get("POLYGLOT_VISION_TOOL", "mcp__polyglot__vision")


# ----------------------------------------------------------------------
# Detection utilities
# ----------------------------------------------------------------------
def _is_pure_code(text: str) -> bool:
    """Skip detection if prompt looks like pure code with no prose."""
    if not text:
        return False
    stripped = text.strip()
    # [Image #N] image markers are prose, not code — don't short-circuit
    if re.match(r"^\[Image #", stripped, re.IGNORECASE):
        return False
    has_prose_punct = bool(re.search(r"[.!?]\s+[A-Za-z]", stripped[:2000]))
    looks_codey = bool(re.match(
        r"^(import|def |function |class |const |let |var |#|//|/\*|\{)",
        stripped,
    ))
    return looks_codey and not has_prose_punct


def _detect_language(text: str) -> tuple:
    """Return (lang_code, plugin) for the first matching plugin, or (None, None)."""
    for code in _ENABLED_LANGS:
        try:
            plugin = load_language(code)
        except ImportError:
            continue
        if plugin.matches(text):
            return code, plugin
    return None, None


def _detect_image(text: str) -> bool:
    return bool(re.search(
        r"\[Image #|Screenshot from|\.(png|jpg|jpeg|webp|bmp|gif)\b",
        text,
        re.IGNORECASE,
    ))


def _detect_code_task(text: str) -> bool:
    return bool(re.search(
        r"\b(write|create|implement|build|scaffold|generate)\b.*"
        r"(func|function|class|script|module|test|component)",
        text,
        re.IGNORECASE,
    ))


# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------
def main() -> None:
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        sys.exit(0)

    # Guard: stdin might be a non-dict JSON value (list, string, number, null)
    if not isinstance(data, dict):
        sys.exit(0)

    prompt = data.get("prompt", "") or ""
    if not isinstance(prompt, str) or not prompt or _is_pure_code(prompt):
        sys.exit(0)

    reminders = []

    # Rule 1: non-English language detection
    code, plugin = _detect_language(prompt)
    if code and plugin:
        lang_name = plugin.LANG_NAME_EN
        overhead = plugin.TOKEN_OVERHEAD_VS_EN
        # Correct formula: if English takes N tokens, target-lang takes N*overhead.
        # Switching output from target-lang to English saves (N*overhead - N) / (N*overhead)
        # = 1 - 1/overhead fraction. For overhead=1.75 (CJK), that's 43%, not 75%.
        pct = int(round((1.0 - 1.0 / overhead) * 100)) if overhead > 1.0 else 0
        reminders.append(
            f"LANGUAGE: {lang_name} detected. Respond in ENGLISH to save "
            f"~{pct}% tokens ({lang_name} BPE overhead is {overhead:.1f}× English). "
            f"For {lang_name} text tasks (SMS/email/translation), call "
            f"`{_TRANSLATE_TOOL}` on local GPU. Respond in {lang_name} ONLY if "
            "the user explicitly asks."
        )

    # Rule 2: image in prompt
    if _detect_image(prompt):
        reminders.append(
            f"VISION: Image detected. Call `{_VISION_TOOL}` FIRST before "
            "analyzing — FREE on local GPU. Image is in your context, but "
            "analysis/description must route through local vision."
        )

    # Rule 3: code-writing task
    if _detect_code_task(prompt):
        reminders.append(
            "CODE-GEN: Code-writing task detected. Draft via a local LLM "
            "when available to save tokens on the first pass — then polish "
            "with your own attention. See docs/code-routing.md."
        )

    if not reminders:
        sys.exit(0)

    body = (
        "<enforcement-reminder>\n"
        + "\n\n".join(f"[{i+1}] {r}" for i, r in enumerate(reminders))
        + "\n</enforcement-reminder>"
    )

    # Dual output: systemMessage (high salience) + additionalContext (docs path)
    print(json.dumps({
        "systemMessage": body,
        "hookSpecificOutput": {
            "hookEventName": "UserPromptSubmit",
            "additionalContext": body,
        },
    }))


if __name__ == "__main__":
    main()
