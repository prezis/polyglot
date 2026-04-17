# Contributing to polyglot

Thanks for considering a contribution. The scope is intentionally narrow:
polyglot routes non-English text through local translation to save tokens.
That's it. Issues and PRs should fit that scope.

## Code of conduct

- Technical rigor over taste preferences. Evidence wins arguments.
- No personal attacks. Criticize ideas, not people.
- Authentic language is fine in issue threads — this project includes
  authentic vocabulary in its detection lists (see `languages/polish.py`).
  Same standard applies in discussion.

## What's in scope

- New language plugins (German, French, Spanish, Portuguese, Arabic, Hebrew,
  Hindi, etc.) — see `languages/template.py`
- Bug fixes in hooks, installer, MCP server
- Performance improvements (regex compile, caching, startup time)
- Documentation fixes
- Better test coverage
- New tiers (sub-Tier 0 for CPU-only translation? Tier 4 for multi-GPU?)

## What's OUT of scope

- Full-service "Claude replacement" MCP servers. The 3 tools polyglot
  exposes (`translate`, `vision`, `scrape`) are the contract. If you want a
  bigger local-AI toolkit, build it separately.
- Cloud-model integrations. polyglot assumes local (Ollama) runtime.
  Cloud-translation integration can live in a fork.
- Content moderation. The language detector is not a censor.

## Adding a new language

1. Copy `languages/template.py` → `languages/<iso>.py`
2. Fill in all the metadata fields
3. Populate `_STOPWORDS_RAW` with 200–400 tokens from **public** sources:
   - The language's National Corpus (most have free frequency lists)
   - SJP / Wiktionary / Wordnet frequency data
   - OpenSubtitles or public subtitle corpora

   **DO NOT mine stopwords from private chats, emails, or personal
   documents.** Stopword lists built from private data leak personal
   vocabulary. The author's first Polish list leaked their own first name
   — we rebuilt from scratch.
4. Add the registry entry in `languages/__init__.py`
5. Write tests under `tests/test_<iso>.py` — minimum: 20 true positives,
   20 true negatives in English
6. Measure recall (≥ 90%) and precision (≥ 99% against English)
7. Run `bash scripts/pii-scan.sh .` — must be clean
8. Open the PR with corpus attribution in the description

## Security: pre-commit scan

Install the pre-commit hook before committing:

```bash
bash scripts/install-git-hooks.sh
```

Every commit will run `scripts/pii-scan.sh` (custom PII patterns) and
`gitleaks` (if installed). Both must pass. If either flags something, the
commit is blocked — that's intentional.

The CI pipeline (`.github/workflows/security-scan.yml`) re-runs both scans
on every push and PR. Contributions that fail CI will not be merged.

## License

All contributions are under the MIT license (see `LICENSE`). By submitting
a PR you agree to license your contribution under the same terms.
