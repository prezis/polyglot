"""
polyglot — language plugin template

Copy this to languages/<iso>.py (e.g. `german.py`, `french.py`) and fill in
your language's signal tokens. Every plugin exposes the same 4 symbols and
2 functions so the core hook can treat all languages uniformly.

CHECKLIST
---------
[ ] 1. LANG_CODE, LANG_NAME_EN, LANG_NAME_NATIVE, TOKEN_OVERHEAD_VS_EN set
[ ] 2. RECOMMENDED_TRANSLATOR_MODEL set to an Ollama/HuggingFace model
[ ] 3. _STOPWORDS populated with 200-400 tokens (see rules below)
[ ] 4. Diacritic/script regex defined if applicable
[ ] 5. matches() and matched_words() tested against positive (target-lang)
      and negative (English + code) samples — recall >= 90%, FP <= 2%
[ ] 6. Unit tests added under tests/test_<iso>.py

STOPWORD SELECTION RULES
------------------------
1. Every token >= 3 chars. Two-letter tokens produce English collisions.
2. Authentic vocabulary — include vulgarisms, colloquial, slang. This is
   a detection library, not a moderation layer.
3. No personal names, city names, or domain-specific jargon (these leak
   into stopword lists when they're mined from private corpora — build
   from PUBLIC linguistic resources: the language's National Corpus, SJP
   / Wiktionary frequency lists, OpenSubtitles).
4. ASCII forms whenever the language has diacritics. Users typing on
   non-native keyboards often omit them — the ASCII list is the hard case.
5. Include full verb inflection tables for the 10-15 most common verbs.

LICENSE
-------
MIT. Word lists representing common vocabulary are not copyrightable.
"""

from __future__ import annotations
import re
from typing import Final, FrozenSet


# --- Metadata -------------------------------------------------------
LANG_CODE: Final[str] = "xx"                    # ISO 639-1
LANG_NAME_EN: Final[str] = "TODO"
LANG_NAME_NATIVE: Final[str] = "TODO"
TOKEN_OVERHEAD_VS_EN: Final[float] = 1.0        # measure on your corpus
RECOMMENDED_TRANSLATOR_MODEL: Final[str] = ""   # e.g. "meta/llama-3-8b-translate"

# --- Character-class signal (diacritics / script) ------------------
# Example for Spanish: r"[áéíóúüñ¿¡]"
# Example for Cyrillic: r"[\u0400-\u04FF]"
# Example for CJK: r"[\u4e00-\u9fff\u3040-\u30ff\uac00-\ud7af]"
_DIACRITIC_RE: Final[re.Pattern] = re.compile(r"[]", re.IGNORECASE)

# --- Stopwords -----------------------------------------------------
_STOPWORDS_RAW: list = [
    # Populate with 200-400 tokens, 3+ chars, ASCII-normalized.
    # See languages/polish.py for a reference structure.
]


def _build_stopwords() -> FrozenSet[str]:
    return frozenset(w.strip().lower() for w in _STOPWORDS_RAW if len(w) >= 3)


STOPWORDS: Final[FrozenSet[str]] = _build_stopwords()


def _compile_regex() -> re.Pattern:
    if not STOPWORDS:
        return re.compile(r"(?!.*)", re.IGNORECASE)   # never matches
    sorted_words = sorted(STOPWORDS, key=len, reverse=True)
    return re.compile(
        r"\b(?:" + "|".join(re.escape(w) for w in sorted_words) + r")\b",
        re.IGNORECASE,
    )


_STOPWORD_RE = _compile_regex()


# --- Public API ----------------------------------------------------
def matches(text: str) -> bool:
    if not text:
        return False
    if _DIACRITIC_RE.search(text):
        return True
    return bool(_STOPWORD_RE.search(text))


def matched_words(text: str) -> list:
    if not text:
        return []
    return _STOPWORD_RE.findall(text.lower())
