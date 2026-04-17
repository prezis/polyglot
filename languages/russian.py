"""
polyglot — Russian language plugin (stub)

Cyrillic script detection + a minimal stopword seed. Expand the
stopword list following the model in languages/polish.py.

CONTRIBUTING
------------
1. Expand _STOPWORDS_RAW with Russian verb inflections, pronouns,
   and colloquial forms. Reference source: RusCorpora frequency list
   (http://ruscorpora.ru).
2. ASCII transliteration is NOT required for Russian — Cyrillic is an
   instant signal.
3. Target: 200-300 tokens, recall >= 90% on RusCorpora sample,
   precision >= 99% against English.

LICENSE
-------
MIT.
"""
from __future__ import annotations
import re
from typing import Final, FrozenSet

LANG_CODE: Final[str] = "ru"
LANG_NAME_EN: Final[str] = "Russian"
LANG_NAME_NATIVE: Final[str] = "русский"
TOKEN_OVERHEAD_VS_EN: Final[float] = 1.5   # BPE fragmentation on Cyrillic
RECOMMENDED_TRANSLATOR_MODEL: Final[str] = "qwen2.5:7b-instruct"

# Cyrillic block — instant positive signal
_CYRILLIC_RE: Final[re.Pattern] = re.compile(r"[\u0400-\u04FF]")

# Seed list — expand from RusCorpora for better precision on Latin-script
# typed Russian (rare but happens on non-Cyrillic keyboards).
_STOPWORDS_SEED: list = [
    # High-frequency function words (Latinized common variants)
    "privet", "spasibo", "pozhaluista", "da", "net",
    "kak", "chto", "gde", "pochemu", "kogda",
    "eto", "etot", "eta", "vsyo", "takzhe",
    # Common verbs (1st person present)
    "delayu", "skazat", "govoryu", "mogu", "khochu", "budu",
]


def _build_stopwords() -> FrozenSet[str]:
    return frozenset(w.lower() for w in _STOPWORDS_SEED if len(w) >= 3)


STOPWORDS: Final[FrozenSet[str]] = _build_stopwords()


def _compile_regex() -> re.Pattern:
    if not STOPWORDS:
        return re.compile(r"(?!.*)", re.IGNORECASE)
    sorted_words = sorted(STOPWORDS, key=len, reverse=True)
    return re.compile(
        r"\b(?:" + "|".join(re.escape(w) for w in sorted_words) + r")\b",
        re.IGNORECASE,
    )


_STOPWORD_RE = _compile_regex()


def matches(text: str) -> bool:
    if not text:
        return False
    # Cyrillic is near-100% precision for Russian-family
    if _CYRILLIC_RE.search(text):
        return True
    return bool(_STOPWORD_RE.search(text))


def matched_words(text: str) -> list:
    if not text:
        return []
    hits = _STOPWORD_RE.findall(text.lower())
    if _CYRILLIC_RE.search(text):
        hits.append("<cyrillic>")
    return hits
