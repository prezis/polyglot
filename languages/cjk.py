"""
polyglot — CJK (Chinese / Japanese / Korean) detection

Character-class based: the Unicode block immediately identifies these
scripts without a stopword list. This handles zh / ja / ko uniformly —
if Claude sees any CJK codepoint in a prompt, token overhead is likely
1.5–2× and a translator pass pays for itself.

DESIGN NOTE
-----------
We deliberately DO NOT split zh/ja/ko at the detection layer. The
*translator* model differs per language, but at detection time the
signal "non-English script" is enough. Downstream routing uses
downstream language ID via the local LLM.

LICENSE
-------
MIT.
"""
from __future__ import annotations
import re
from typing import Final

# Unicode ranges for CJK
_CJK_RE: Final[re.Pattern] = re.compile(
    r"[\u4e00-\u9fff"      # CJK Unified Ideographs (Chinese + ja/ko Han)
    r"\u3040-\u309f"       # Hiragana
    r"\u30a0-\u30ff"       # Katakana
    r"\uac00-\ud7af"       # Hangul syllables
    r"\u3400-\u4dbf]"      # CJK Extension A
)

LANG_CODE: Final[str] = "cjk"
LANG_NAME_EN: Final[str] = "Chinese / Japanese / Korean"
LANG_NAME_NATIVE: Final[str] = "中文 / 日本語 / 한국어"
TOKEN_OVERHEAD_VS_EN: Final[float] = 1.75   # averaged across zh/ja/ko
RECOMMENDED_TRANSLATOR_MODEL: Final[str] = "qwen2.5:7b-instruct"


def matches(text: str) -> bool:
    if not text:
        return False
    return bool(_CJK_RE.search(text))


def matched_words(text: str) -> list:
    if not text:
        return []
    return _CJK_RE.findall(text)
