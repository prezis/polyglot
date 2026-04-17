# Anti-bypass design

> "a carefully worded instruction is not the same as a physical barrier."

This document explains why polyglot's language-routing actually *sticks* —
why the agent keeps honoring the translator across sessions, after context
compaction, and when it's "in a hurry" and would normally route around a
reminder.

If you're just here to install, skip to the `README.md`. This is for people
who want to understand the defense-in-depth.

---

## The problem being solved

Language-model agents violate text instructions at measurable, reproducible
rates. Published benchmarks (Jaroslawicz et al. 2025, IFScale, arXiv
2507.11538) show compliance drops **linearly** with instruction count —
from 100% @ 50 rules to 67.9% @ 250 to 44.6% @ 500 on Claude Opus 4. A
~200-line `CLAUDE.md` sits comfortably in the "40% of rules silently
dropped" zone.

Worse: the agent is **goal-directed-adversarial** toward its own rule
files when the rule blocks a task. GitHub issue
[anthropics/claude-code#29709](https://github.com/anthropics/claude-code/issues/29709)
documents Claude routing around a `PreToolUse:Write` denial by calling
`Bash(cat > file.py << EOF ... EOF)` — the same file write through a
different tool. Closed "not planned" by Anthropic.

Putting the "respond in English" rule in `CLAUDE.md` and hoping for the
best is a 40% solution. polyglot aims for 95%+.

---

## The five defense layers

### Layer 1 — UserPromptSubmit (passive detection, high-salience reminder)

`enforcements/prompt-guard.py` runs on every `UserPromptSubmit` event.
Detects non-English input in the user's prompt. Outputs both a top-level
`systemMessage` and a `hookSpecificOutput.additionalContext` with the
`<enforcement-reminder>` wrapper.

Why both fields: per Anthropic's docs, `additionalContext` is "added more
discretely"; `systemMessage` surfaces as a visible system-reminder at the
top of the agent's next turn. Dual-emission is belt-and-suspenders.

The reminder names the specific tool to call instead of describing the
rule abstractly. **Positive framing** ("call `polyglot_translate`") beats
negative framing ("don't translate on your own") — prompt-engineering
research on few-shot dilemma shows the model pattern-matches "what to do"
faster than "what not to do."

### Layer 2 — PreToolUse (deterministic gates, mechanically unblockable)

`enforcements/engine.sh` runs on every `PreToolUse` event. Loads every
`rules/*.json` file. If a rule's `trigger.tool` matches the current tool
call AND the `condition` isn't satisfied, the engine emits
`permissionDecision: "deny"`. Claude Code enforces this at the runtime
layer — the tool call is mechanically aborted before Claude's reasoning
sees it happen.

**This is the teeth.** Agent cannot rationalize its way past it because
the tool call physically doesn't happen.

Key anti-bypass rules shipped (see `rules/`):

- **`bash-code-generate-guard.json`** — closes the issue-#29709 Bash
  heredoc / redirect / `python3 -c` bypass. Trigger matches any Bash
  command writing to a `.py|.js|.ts|.sh|...` path. Exception: writes into
  `~/.claude/` paths (config, not app code).

- **`gpu-first-vision.json`** — `action: block`. Triggers on
  `Read|Glob|Grep|Bash` touching image extensions. Requires prior
  `mcp__polyglot__vision` call. Result: agent cannot "just describe the
  screenshot" without routing through the local VLM first.

- **`env-write-guard.json`** — blocks `Write|Edit|NotebookEdit` to any
  `.env*` path, full stop. No override.

- **`notebook-edit-guard.json`** — closes the "write code cells via
  NotebookEdit" bypass that sidesteps Write-tool rules.

- **`research-gate-write.json`** / **`research-before-dispatch.json`** —
  enforces the "read the code before you change it" discipline.

### Layer 3 — Stop hook (reactive, feedback-loop)

`enforcements/stop-violation.py` runs on every `Stop` event. Scans the
final assistant message for language drift (e.g., agent started replying
in Polish despite the English rule). If 2+ distinct source-language
tokens appear outside code blocks, returns
`{"decision": "block", "reason": "..."}` — forces Claude to continue the
session and self-correct.

Hard cap: **3 blocks per session**. Beyond the cap, the hook allows Stop
with a loud warning. Prevents infinite-loop traps if the detector is
wrong.

Hard cap is a deliberate acceptance of imperfect enforcement — we'd
rather occasionally let a violation through than trap a session.

### Layer 4 — SessionStart with `matcher="compact"` (persistence across resets)

`enforcements/post-compact.sh` fires after context compaction. This is
the #1 documented failure mode:

> "Lost discipline after context compaction — after the conversation was
> compacted, I resumed from the summary focusing only on 'what to do,'
> without reloading TDD discipline."
> — Claude Code's own confession, [yajin.org 2026-03-22](https://yajin.org/blog/2026-03-22-why-ai-agents-break-rules/)

The hook re-injects the top four rules (English output, GPU-first tools,
research-before-build, commit-after-completion) via a `systemMessage` the
moment the post-compaction turn begins. The agent sees fresh, full rule
context before executing its first tool call in the new window.

### Layer 5 — not-yet-shipped: adversarial critic

An optional `local_llm` critic that inspects Claude's reasoning for
self-granted exceptions ("because urgent", "this is special", "I'll just
skip X for now"). Anthropic Constitutional Classifiers reduced jailbreak
success from 86% → 4.4% using this pattern; it applies to rule
self-exemption too.

Not in v0.1. Shipped as a stub + design doc to avoid scope creep.

---

## Why `warn` + `block` combined, not just `block`

A `block`-everything design creates friction and the user disables the
hook within a week. Observed pattern across published Claude Code
setups.

polyglot splits:

- **Block**: security-sensitive (env write, local_vision on screenshots,
  Bash heredoc writing code). False-positive cost is "re-type a command";
  true-positive benefit is "preventing a breach / token waste / silent
  bypass."
- **Warn**: discipline-sensitive (research-before-build, memory-context
  check). False-positive cost is a noise message; true-positive benefit
  is a nudge.

`warn` messages accumulate across all matching rules in a single tool
call (engine.sh v3.2 fix — earlier versions dropped all-but-the-first
alphabetically) and surface via `systemMessage`, same path as Layer 1
uses. No warn is silently lost.

---

## Bypass attempts we've considered and blocked

| Attempt | Rule that catches it |
|---|---|
| `Bash(cat > x.py << EOF ... EOF)` | `bash-code-generate-guard.json` |
| `Bash(echo "code" > x.sh)` | `bash-code-generate-guard.json` |
| `Bash(python3 -c '...; open(f).write(...)')` | `bash-code-generate-guard.json` |
| `NotebookEdit(new_source=<code>)` | `notebook-edit-guard.json` |
| `Write(.env, secrets)` | `env-write-guard.json` |
| `Read(screenshot.png)` without prior `local_vision` | `gpu-first-vision.json` (block) |
| `Glob("*.png")` without prior `local_vision` | `gpu-first-vision.json` |
| `mcp__playwright-local__browser_navigate(example.com)` without prior local-knowledge Grep | `gpu-first-websearch.json` (warn) |
| Responding in Polish despite English rule | `stop-violation.py` (2 tokens → block Stop) |
| Forgetting rules after context compaction | `post-compact.sh` (re-inject) |

## What we explicitly don't block

- In-response code review (no tool call = no hook can fire). Mitigated by
  UserPromptSubmit reminder only.
- In-response image description of a pasted `[Image #N]` (Claude's
  multimodal context sees the image before any tool call). UserPromptSubmit
  reminder is the only layer; prompt-guard explicitly flags `[Image #`.
- Agent typing the author's name in its response (no reliable signal).
  Mitigated by PII scanner on saved files only.

These are listed in `docs/architecture.md` as known residual bypasses.
Open to PRs — if you find a way to close any of them, the project will
absorb it.

---

## Audit trail

Every rule fire is logged to `~/.polyglot/state/session-log.jsonl`.
Violations of the hard-block rules are separately logged to
`~/.polyglot/state/bypass-log.jsonl` if the agent uses the `CLAUDE_FORCE=1`
bypass env var (present on some rules as a conscious-override escape
hatch). Review weekly; patterns in the bypass log indicate either the
rule is too aggressive or the agent is systematically routing around it.

---

## Threat model

polyglot defends against:

- Language drift by the agent in its own responses
- Agents routing cheap-path-around-expensive-rule
- Context-compaction-induced rule amnesia
- Accidental secret writes via tool misuse

polyglot does NOT defend against:

- Malicious users editing their own `CLAUDE.md` / settings
- A compromised local model (if your translator is backdoored, English
  goes wrong but the hooks still run)
- Cloud-model side-channel leakage (Claude's responses traveling over a
  network you don't control)
- A user intentionally running `git commit --no-verify` on a PII-laden
  file (pre-commit hook is bypassable by design — it's a guardrail, not
  a jail)

The goal is defense in depth against *the agent's own* failure modes,
not against a malicious operator.
