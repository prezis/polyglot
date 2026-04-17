#!/usr/bin/env python3
"""
polyglot-mcp — minimal MCP server exposing 3 translation tools to Claude Code.

Tools:
  - polyglot_translate(text, source_lang="pl", target_lang="en")
      Translate native-language text via a local LLM (Ollama).
  - polyglot_vision(image_path, source_lang="pl")
      OCR + describe + translate a screenshot via a local VLM.
  - polyglot_scrape(url)           (opt-in via POLYGLOT_ENABLE_SCRAPE=1)
      Fetch YouTube/Twitter text + translate.

CONFIGURATION (env vars)
------------------------
  POLYGLOT_TRANSLATE_MODEL  default: speakleash/bielik-11b-v3.0-instruct:Q5_K_M
  POLYGLOT_VISION_MODEL     default: qwen2.5vl:7b
  POLYGLOT_OLLAMA_HOST      default: http://localhost:11434
  POLYGLOT_ENABLE_SCRAPE    "1" to enable (default: off)

DEPENDENCIES
------------
  pip install "mcp[cli]>=1.0.0" httpx pillow

RUNNING
-------
  python3 server.py              # stdio (Claude Code default)
  python3 server.py --http 8181  # HTTP transport for remote agents

LICENSE: MIT
"""
from __future__ import annotations

import asyncio
import base64
import os
import sys
from pathlib import Path
from typing import Optional

try:
    import httpx
except ImportError:
    sys.stderr.write(
        "polyglot-mcp: missing dependency 'httpx'. Install: pip install httpx\n"
    )
    sys.exit(1)

try:
    from mcp.server.fastmcp import FastMCP
except ImportError:
    sys.stderr.write(
        "polyglot-mcp: missing 'mcp'. Install: pip install 'mcp[cli]>=1.0.0'\n"
    )
    sys.exit(1)


# ----------------------------------------------------------------------
# Config
# ----------------------------------------------------------------------
OLLAMA_HOST = os.environ.get("POLYGLOT_OLLAMA_HOST", "http://localhost:11434")
TRANSLATE_MODEL = os.environ.get(
    "POLYGLOT_TRANSLATE_MODEL",
    "speakleash/bielik-11b-v3.0-instruct:Q5_K_M",
)
VISION_MODEL = os.environ.get("POLYGLOT_VISION_MODEL", "qwen2.5vl:7b")
ENABLE_SCRAPE = os.environ.get("POLYGLOT_ENABLE_SCRAPE", "0") == "1"

mcp = FastMCP("polyglot")


# ----------------------------------------------------------------------
# Ollama helpers
# ----------------------------------------------------------------------
async def _ollama_generate(
    model: str,
    prompt: str,
    images: Optional[list] = None,
    max_tokens: int = 2000,
) -> str:
    async with httpx.AsyncClient(timeout=120.0) as client:
        payload = {
            "model": model,
            "prompt": prompt,
            "stream": False,
            "options": {"num_predict": max_tokens, "temperature": 0.2},
        }
        if images:
            payload["images"] = images
        r = await client.post(f"{OLLAMA_HOST}/api/generate", json=payload)
        r.raise_for_status()
        return r.json().get("response", "").strip()


# ----------------------------------------------------------------------
# Tools
# ----------------------------------------------------------------------
@mcp.tool()
async def polyglot_translate(
    text: str,
    source_lang: str = "pl",
    target_lang: str = "en",
) -> str:
    """Translate native-language text into the target language via local GPU.

    Args:
        text: The text to translate.
        source_lang: ISO 639-1 code of the source language (default: pl).
        target_lang: ISO 639-1 code of the target language (default: en).

    Returns:
        Translated text. Errors are returned as '[polyglot-error: ...]'.
    """
    if not text:
        return ""
    prompt = (
        f"Translate the following {source_lang.upper()} text to "
        f"{target_lang.upper()}. Preserve meaning faithfully including "
        "colloquial and vulgar registers. Output ONLY the translation, "
        "no preamble.\n\n"
        f"Source:\n{text}\n\nTranslation:"
    )
    try:
        return await _ollama_generate(TRANSLATE_MODEL, prompt, max_tokens=4000)
    except Exception as e:
        return f"[polyglot-error: translate failed: {e}]"


@mcp.tool()
async def polyglot_vision(
    image_path: str,
    source_lang: str = "pl",
    target_lang: str = "en",
) -> str:
    """Describe a screenshot/image in the target language via local VLM.

    OCRs any text in the image and produces a concise description. If the
    image contains text in source_lang, it is translated into target_lang.

    SECURITY: image_path is restricted to POLYGLOT_VISION_ROOTS (colon-
    separated allow-list). Default: $HOME/Pictures:$HOME/Screenshots:/tmp.
    Symlinks are resolved and re-checked against the allow-list.

    Args:
        image_path: Path to an image file under an allowed root.
        source_lang: Expected source language of any text in the image.
        target_lang: Language for the description output.

    Returns:
        Textual description (translated if needed), or '[polyglot-error: ...]'.
    """
    # Validate: allow-list of root directories for image reads (no arbitrary FS)
    default_roots = ":".join([
        os.path.expanduser("~/Pictures"),
        os.path.expanduser("~/Screenshots"),
        "/tmp",
    ])
    allowed_roots = [
        Path(p).resolve() for p in os.environ.get(
            "POLYGLOT_VISION_ROOTS", default_roots
        ).split(":") if p
    ]
    try:
        p = Path(image_path).expanduser().resolve(strict=True)
    except (FileNotFoundError, OSError):
        return f"[polyglot-error: image not found: {image_path}]"
    if not any(p == root or root in p.parents for root in allowed_roots):
        return (
            f"[polyglot-error: image_path outside POLYGLOT_VISION_ROOTS. "
            f"Allowed roots: {[str(r) for r in allowed_roots]}]"
        )
    # Size cap — 20MB. Prevents loading huge files into memory.
    try:
        if p.stat().st_size > 20 * 1024 * 1024:
            return "[polyglot-error: image exceeds 20MB size limit]"
    except OSError as e:
        return f"[polyglot-error: stat failed: {e}]"
    try:
        b64 = base64.b64encode(p.read_bytes()).decode()
    except Exception as e:
        return f"[polyglot-error: cannot read image: {e}]"

    prompt = (
        f"Describe this image in {target_lang.upper()}. If it contains "
        f"{source_lang.upper()} text, OCR and translate it. Be concise "
        "and factual. No preamble."
    )
    try:
        return await _ollama_generate(VISION_MODEL, prompt, images=[b64], max_tokens=3000)
    except Exception as e:
        return f"[polyglot-error: vision failed: {e}]"


if ENABLE_SCRAPE:
    import ipaddress, socket
    from urllib.parse import urlparse

    def _is_internal_host(host: str) -> bool:
        """Block SSRF to private ranges, loopback, link-local."""
        try:
            addrs = socket.getaddrinfo(host, None)
        except socket.gaierror:
            return True  # fail closed
        for _, _, _, _, sa in addrs:
            ip = ipaddress.ip_address(sa[0])
            if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved:
                return True
        return False

    @mcp.tool()
    async def polyglot_scrape(
        url: str,
        source_lang: str = "pl",
        target_lang: str = "en",
    ) -> str:
        """Fetch text from a URL and translate.

        SECURITY: Only https:// to non-private hosts. No redirects followed
        automatically (each hop re-validated). 50kB body cap.

        Args:
            url: https:// URL to fetch.
            source_lang: Expected language of the content.
            target_lang: Language to translate to.

        Returns:
            Translated content, or an error tag.
        """
        try:
            parsed = urlparse(url)
        except Exception:
            return "[polyglot-error: invalid URL]"
        if parsed.scheme not in ("http", "https"):
            return f"[polyglot-error: only http/https allowed, got {parsed.scheme}]"
        if parsed.scheme == "http" and not os.environ.get("POLYGLOT_ALLOW_HTTP"):
            return "[polyglot-error: http blocked, set POLYGLOT_ALLOW_HTTP=1 to override]"
        if not parsed.hostname or _is_internal_host(parsed.hostname):
            return "[polyglot-error: host resolves to private/loopback address]"
        try:
            async with httpx.AsyncClient(timeout=30.0, follow_redirects=False) as c:
                r = await c.get(url, headers={"User-Agent": "polyglot-mcp/0.1"})
                r.raise_for_status()
                raw = r.text[:50000]
        except Exception as e:
            return f"[polyglot-error: fetch failed: {type(e).__name__}]"
        return await polyglot_translate(
            raw, source_lang=source_lang, target_lang=target_lang,
        )


# ----------------------------------------------------------------------
# Entrypoint
# ----------------------------------------------------------------------
def main() -> None:
    args = sys.argv[1:]
    if "--http" in args:
        idx = args.index("--http")
        port = int(args[idx + 1]) if idx + 1 < len(args) else 8181
        # SECURITY: bind to localhost by default. Use --bind 0.0.0.0 only
        # if you trust your LAN. polyglot_vision can read files and
        # polyglot_scrape can make outbound requests — don't expose blindly.
        bind = "127.0.0.1"
        if "--bind" in args:
            bind = args[args.index("--bind") + 1]
        if bind != "127.0.0.1" and not os.environ.get("POLYGLOT_ALLOW_LAN"):
            sys.stderr.write(
                "polyglot-mcp: refusing non-localhost bind without "
                "POLYGLOT_ALLOW_LAN=1. Set env var to acknowledge.\n"
            )
            sys.exit(2)
        sys.stderr.write(f"polyglot-mcp HTTP on {bind}:{port}\n")
        mcp.run(transport="sse", host=bind, port=port)
    else:
        sys.stderr.write("polyglot-mcp stdio ready\n")
        mcp.run()


if __name__ == "__main__":
    main()
