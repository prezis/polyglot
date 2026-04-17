# polyglot

> Write in your native language. Claude Code responds in English.
> Local GPU translates your inputs — docs, screenshots, voice-note
> transcripts — before they hit Claude's context.
>
> And unlike a `CLAUDE.md` rule, this one the agent **cannot route around.**

---

## Two problems polyglot solves

### 1. Token waste on non-English input

Non-English text fragments through Claude's BPE tokenizer. A 100-word
Polish paragraph = ~1.22× the tokens of the English equivalent. Chinese
= ~1.75×. Russian = ~1.5×. Your bill pays that tax on every turn.

**Token savings per language** (switching output from native → English):

| Language | BPE overhead | Savings on translated output |
|----------|--------------|------------------------------|
| Chinese / Japanese / Korean | 1.75× | ~43% |
| Russian (Cyrillic) | 1.50× | ~33% |
| Arabic / Hebrew | 1.40× | ~29% |
| Polish | 1.22× | ~18% |

### 2. Agents don't reliably follow `CLAUDE.md`

[IFScale (arXiv 2507.11538)](https://arxiv.org/abs/2507.11538) measured
Claude Opus 4 dropping from 100% rule compliance at 50 instructions to
44.6% at 500. A 200-line `CLAUDE.md` sits in the zone where ~30–40% of
rules silently fade.

Worse: [issue #29709](https://github.com/anthropics/claude-code/issues/29709)
documents Claude actively routing around `PreToolUse:Write` denials by
using `Bash(cat > file.py << EOF ... EOF)` — the same file write through
a different tool. Closed by Anthropic as "not planned."

**polyglot combines:** soft prompt-level reminders (advisory) + hard
runtime gates (mechanical). The agent can't `cat > file` its way past a
tool that's physically blocked from running.

See [`docs/anti-bypass-design.md`](docs/anti-bypass-design.md) for the
full multi-layer defense walkthrough.

---

## Install (one line)

```bash
git clone https://github.com/prezis/polyglot && cd polyglot && bash install.sh
```

The wizard:
- Detects your GPU via `nvidia-smi`
- Picks a tier based on available VRAM (see table below)
- Asks your native language (default: `pl`)
- Pulls required Ollama models (if tier ≥ 1)
- Merges hooks into `~/.claude/settings.json` (never overwrites — backs
  up the original to `settings.json.polyglot-bak`)
- Registers the polyglot MCP server

Restart Claude Code. Your next non-English prompt fires the reminder.
Your next screenshot goes through local vision first. Your next attempt
to write Python via `Bash(cat > x.py ...)` is blocked unless you ran the
local code-draft tool first.

**Recommended — enable the pre-commit leak scanner for contributors:**

```bash
bash scripts/install-git-hooks.sh
```

---

## Tiers

| Tier | VRAM | What runs locally | What Claude sees |
|------|------|-------------------|------------------|
| **0** | none | Language detection + rule-enforcement hooks only | Your prompt + `<enforcement-reminder>` + runtime blocks on cheat-paths |
| **1** | 12 GB | +Translator LLM (Bielik-11B-PL or equivalent) | +Pre-translated English for long native text, PDFs, transcripts |
| **2** | 24 GB | +Vision-language model (Qwen2.5-VL) | +Screenshots OCR'd and translated before Claude sees |
| **3** | 32 GB | +YouTube / X transcript scraper | +Social-media content auto-translated |

**Tier 0 works with zero GPU.** The anti-bypass rules don't need a model
— they're deterministic shell/Python scripts running as Claude Code
hooks. You only need GPU for the *translation* payload (Tiers 1+).

---

## Architecture

```
  ┌─────────────┐ UserPromptSubmit  ┌────────────────────────┐
  │ user prompt │─────────────────▶│ enforcements/          │
  └─────────────┘ (native language) │   prompt-guard.py      │
                                    │   (language detection) │
                                    └────────────┬───────────┘
                                                 │ systemMessage
                                                 ▼
  ┌────────────────────┐ PreToolUse  ┌──────────────────────┐
  │ Claude's tool call │────────────▶│ enforcements/        │
  │ (Read/Bash/Write/  │             │   engine.sh          │
  │  Glob/Grep/…)      │  DENY if    │   loads rules/*.json │
  └────────────────────┘◀────────────│   evaluates each     │
                                     └──────────┬───────────┘
                                                │ allow
                                                ▼
                            ┌──────────────────────────────┐
                            │   MCP call to polyglot-mcp   │
                            │   (translate/vision/scrape)  │
                            └──────────────────────────────┘
                                              │
                                              ▼ localhost stdio / HTTP
                                   ┌──────────────────────┐
                                   │ Ollama on local GPU  │
                                   │  Bielik / Qwen-VL    │
                                   └──────────────────────┘
```

Four Claude Code hook surfaces:

- **`UserPromptSubmit` → `prompt-guard.py`** — detects non-English input,
  injects a high-salience `<enforcement-reminder>` naming the exact tool
  to call.
- **`PreToolUse` → `engine.sh`** — runs every matching rule in
  `enforcements/rules/*.json`. Emits `permissionDecision: "deny"` on
  violation — the tool call is mechanically aborted.
- **`SessionStart` matcher="compact"` → `post-compact.sh`** — re-injects
  top-4 rules after context compaction. Attacks the documented
  [post-compaction discipline-loss failure mode](https://yajin.org/blog/2026-03-22-why-ai-agents-break-rules/).
- **`Stop` → `stop-violation.py`** — scans the final assistant message
  for language drift (agent replying in Polish despite the rule). Blocks
  Stop with a remediation prompt. Hard cap: 3 blocks per session.

Plus one MCP server (`mcp-server/server.py`) exposing three tools to
Claude: `polyglot_translate`, `polyglot_vision`, `polyglot_scrape`.

---

## The rule set (enforcements/rules/)

Twelve `.json` rule files ship by default. The ones that actually close
bypass vectors:

| Rule | Action | What it prevents |
|------|--------|------------------|
| `gpu-first-vision.json` | **block** | Read/Glob/Grep/Bash on image files without prior `local_vision` |
| `bash-code-generate-guard.json` | **warn** | `Bash(cat > x.py << EOF)` — the issue #29709 heredoc bypass |
| `env-write-guard.json` | **block** | Writing to `.env*` files via any tool |
| `notebook-edit-guard.json` | warn | Code written via `NotebookEdit` bypassing Write rules |
| `gpu-first-code-generate.json` | warn | Writing new code without consulting local draft |
| `gpu-first-code-review.json` | warn | Reviewing code without using local reviewer |
| `gpu-first-websearch.json` | warn | WebSearch/WebFetch/browser without local-knowledge Grep |
| `research-before-dispatch.json` | warn | Dispatching build agents before research agents |
| `research-gate-write.json` | warn | Writing code files without prior reading |
| `bash-safety.json` | block | `sudo`, `rm -rf`, `curl | bash`, `.env` direct writes |
| `removal-proposal.json` | warn | Edits to CLAUDE.md / memory / settings that delete content |
| `memory-context-check.json` | warn | Edits to project files without reading index first |

Customize for your setup — every rule is a plain JSON file. See
`docs/anti-bypass-design.md` for the rule schema and the engine.sh
semantics (pipe-separated tool lists, regex args_pattern, recency-aware
`has_prior_tool`, `bypass_env` for conscious overrides).

---

## Adding a language

See `languages/template.py`. Checklist:

1. Copy `template.py` → `languages/<iso>.py`
2. Fill metadata (`LANG_CODE`, `TOKEN_OVERHEAD_VS_EN`, translator model)
3. Populate `_STOPWORDS_RAW` with 200–400 tokens from **public** corpora
   (National Corpus / Wiktionary / OpenSubtitles). Never mine from your
   own chat logs — see `CONTRIBUTING.md` for why.
4. Add to the registry in `languages/__init__.py`
5. Add tests under `tests/test_<iso>.py` — aim for ≥90% recall, ≥99%
   precision against English
6. Open PR

Included: Polish (full, 335 tokens), Russian (stub + Cyrillic detection),
CJK (character-class detection).

---

## Security

Before every commit, `scripts/pii-scan.sh` + `gitleaks` run through the
pre-commit hook. The custom scanner blocks on:

- Absolute home paths (`/home/<user>/`)
- Solana / Ethereum wallet addresses
- Private keys (base58 long-form)
- API tokens (Helius RPC, Telegram bot, etc.)
- Personal identifier patterns from the original author (never ship)
- Private project names that leaked during v0.1 development

The CI workflow at `.github/workflows/security-scan.yml` re-runs both
scans on every push + PR. Build fails on any finding.

**If you contribute and your commit fails the scan, that's working as
intended — the rule set is wide by design.**

The MCP server itself:
- HTTP mode binds `127.0.0.1` by default; `--bind 0.0.0.0` refused
  unless `POLYGLOT_ALLOW_LAN=1` explicitly set
- `polyglot_vision(image_path)` restricted to `POLYGLOT_VISION_ROOTS`
  allow-list (default: `~/Pictures:~/Screenshots:/tmp`) + 20 MB file-size cap
- `polyglot_scrape(url)` blocks private-IP targets (SSRF guard),
  disables auto-redirect, requires `https://` by default

See `docs/anti-bypass-design.md` §Threat model for what polyglot does
*not* defend against.

---

## Contact

Bugs, feature requests, language contributions: open an
[issue](https://github.com/prezis/polyglot/issues) or start a
[discussion](https://github.com/prezis/polyglot/discussions).

No email contact. GitHub's built-in channels are the project's front
door — keeps the conversation public and searchable.

---

## Related projects

- [heretic](https://github.com/p-e-w/heretic) — if your local translator
  refuses authentic vulgar vocabulary (common for instruct-tuned models),
  abliteration fixes that. Orthogonal to polyglot.
- [Ollama](https://ollama.com) — the local model runtime polyglot uses
  for tiers 1+.
- [Claude Code hooks docs](https://docs.claude.com/en/docs/claude-code/hooks) —
  the platform mechanism polyglot builds on.

---

## License

MIT.
