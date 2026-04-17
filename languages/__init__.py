"""
polyglot — language plugin registry

Each language ships a module exposing:
    matches(text: str) -> bool
    matched_words(text: str) -> list[str]
    LANG_CODE: str            # ISO 639-1
    LANG_NAME_EN: str
    LANG_NAME_NATIVE: str
    TOKEN_OVERHEAD_VS_EN: float   # BPE token-count ratio vs English
    RECOMMENDED_TRANSLATOR_MODEL: str | None
"""
from __future__ import annotations

from typing import Dict, Protocol


class LanguagePlugin(Protocol):
    LANG_CODE: str
    LANG_NAME_EN: str
    LANG_NAME_NATIVE: str
    TOKEN_OVERHEAD_VS_EN: float
    RECOMMENDED_TRANSLATOR_MODEL: str

    def matches(self, text: str) -> bool: ...
    def matched_words(self, text: str) -> list: ...


# Built-in plugins — extend via plugins= kwarg or packaging entry points
_REGISTRY: Dict[str, str] = {
    "pl": "polyglot.languages.polish",
    "ru": "polyglot.languages.russian",
    # CJK are character-class detectors, no stopword list needed
    "zh": "polyglot.languages.cjk",
    "ja": "polyglot.languages.cjk",
    "ko": "polyglot.languages.cjk",
}


def load(code: str):
    """Load a language plugin by ISO 639-1 code. Raises ImportError if missing.

    Tries both installed ('polyglot.languages.<name>') and in-place
    ('languages.<name>') import paths so the hook works whether polyglot
    is pip-installed or cloned as a raw directory.
    """
    if code not in _REGISTRY:
        raise ImportError(
            f"No plugin registered for '{code}'. "
            f"Available: {sorted(_REGISTRY.keys())}. "
            "See languages/template.py to add a new language."
        )
    import importlib
    module_path = _REGISTRY[code]
    # Try installed path first; fall back to in-place
    try:
        return importlib.import_module(module_path)
    except ImportError:
        fallback = module_path.replace("polyglot.", "")
        return importlib.import_module(fallback)


def available() -> list:
    return sorted(_REGISTRY.keys())
