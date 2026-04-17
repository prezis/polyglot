#!/usr/bin/env bash
# polyglot — install wizard
#
# Detects GPU, picks a tier, pulls required Ollama models, merges hooks
# into ~/.claude/settings.json (never overwrites), and registers the MCP
# server.
#
# Usage:
#   bash install.sh                  # interactive
#   bash install.sh --tier 1 --lang pl --noninteractive
#
# LICENSE: MIT

set -euo pipefail

# Pretty printing
BOLD='\033[1m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
BLUE='\033[34m'
NC='\033[0m'

info()  { printf "${BLUE}→${NC} %s\n" "$1"; }
ok()    { printf "${GREEN}✓${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}!${NC} %s\n" "$1"; }
fail()  { printf "${RED}✗${NC} %s\n" "$1"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TIER=""
LANG="pl"
NONINTERACTIVE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --tier) TIER="$2"; shift 2 ;;
        --lang) LANG="$2"; shift 2 ;;
        --noninteractive) NONINTERACTIVE=1; shift ;;
        -h|--help)
            echo "Usage: $0 [--tier 0|1|2|3] [--lang pl|ru|zh|...] [--noninteractive]"
            exit 0
            ;;
        *) fail "Unknown arg: $1" ;;
    esac
done

printf "${BOLD}polyglot installer${NC}\n\n"

# ----------------------------------------------------------------------
# Prereq checks
# ----------------------------------------------------------------------
info "Checking prerequisites..."
command -v python3 >/dev/null 2>&1 || fail "python3 not found"
PYVER=$(python3 -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")')
ok "python3 $PYVER"

command -v jq >/dev/null 2>&1 || warn "jq not found (settings merge will use python instead)"

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
[ -d "$CLAUDE_HOME" ] || fail "Claude Code config not found at $CLAUDE_HOME (set CLAUDE_HOME env var if elsewhere)"
ok "Claude Code home: $CLAUDE_HOME"

# ----------------------------------------------------------------------
# GPU detection
# ----------------------------------------------------------------------
info "Detecting GPU..."
GPU_VRAM_MB=0
if command -v nvidia-smi >/dev/null 2>&1; then
    GPU_VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || echo 0)
    [ -z "$GPU_VRAM_MB" ] && GPU_VRAM_MB=0
    if [ "$GPU_VRAM_MB" -gt 0 ]; then
        ok "NVIDIA GPU: ${GPU_VRAM_MB} MB VRAM"
    fi
fi
if [ "$GPU_VRAM_MB" -eq 0 ] && command -v rocm-smi >/dev/null 2>&1; then
    warn "AMD GPU detected — Ollama supports ROCm but less tested. Treating as GPU-available."
    GPU_VRAM_MB=16000   # conservative default
fi

# ----------------------------------------------------------------------
# Tier suggestion
# ----------------------------------------------------------------------
if [ -z "$TIER" ]; then
    if [ "$GPU_VRAM_MB" -eq 0 ]; then
        SUGGEST=0
    elif [ "$GPU_VRAM_MB" -lt 12000 ]; then
        SUGGEST=0
    elif [ "$GPU_VRAM_MB" -lt 24000 ]; then
        SUGGEST=1
    elif [ "$GPU_VRAM_MB" -lt 32000 ]; then
        SUGGEST=2
    else
        SUGGEST=3
    fi

    if [ "$NONINTERACTIVE" -eq 1 ]; then
        TIER=$SUGGEST
    else
        printf "\n${BOLD}Tier selection${NC}\n"
        printf "  0 — baseline (language detection only, no GPU)\n"
        printf "  1 — +text translation (Bielik/Qwen, 12GB+ VRAM)\n"
        printf "  2 — +vision (Qwen-VL, 24GB+ VRAM)\n"
        printf "  3 — +scrape + full stack (32GB+ VRAM)\n\n"
        printf "Suggested based on detected hardware: ${BOLD}%s${NC}\n" "$SUGGEST"
        read -r -p "Select tier [0-3, default $SUGGEST]: " USER_TIER
        TIER="${USER_TIER:-$SUGGEST}"
    fi
fi

case "$TIER" in
    0|1|2|3) ok "Tier $TIER selected" ;;
    *) fail "Invalid tier: $TIER" ;;
esac

# Warn if requested tier exceeds detected GPU capacity
MIN_VRAM_FOR_TIER_MB=0
case "$TIER" in
    1) MIN_VRAM_FOR_TIER_MB=12000 ;;
    2) MIN_VRAM_FOR_TIER_MB=24000 ;;
    3) MIN_VRAM_FOR_TIER_MB=32000 ;;
esac
if [ "$TIER" -ge 1 ] && [ "$GPU_VRAM_MB" -lt "$MIN_VRAM_FOR_TIER_MB" ]; then
    warn "Tier $TIER expects >= ${MIN_VRAM_FOR_TIER_MB}MB VRAM but only ${GPU_VRAM_MB}MB detected."
    warn "Models may run on CPU (slow) or fail. Consider --tier $((TIER-1))."
    if [ "$NONINTERACTIVE" -eq 0 ]; then
        read -r -p "Continue anyway? [y/N]: " CONT
        [[ "$CONT" =~ ^[Yy]$ ]] || fail "Aborted. Re-run with appropriate --tier."
    fi
fi

# ----------------------------------------------------------------------
# Language
# ----------------------------------------------------------------------
AVAILABLE_LANGS=$(python3 -c "import sys; sys.path.insert(0, '$SCRIPT_DIR'); from languages import available; print(','.join(available()))")
if [ "$NONINTERACTIVE" -eq 0 ]; then
    printf "\n${BOLD}Language selection${NC}\n"
    printf "Available: %s\n" "$AVAILABLE_LANGS"
    read -r -p "Native language [default $LANG]: " USER_LANG
    LANG="${USER_LANG:-$LANG}"
fi
ok "Language: $LANG"

# ----------------------------------------------------------------------
# Ollama models (for tier >= 1)
# ----------------------------------------------------------------------
if [ "$TIER" -ge 1 ]; then
    info "Checking Ollama..."
    command -v ollama >/dev/null 2>&1 || fail "Ollama not installed. See https://ollama.com/download"
    ok "ollama found"

    TIER_CONFIG="$SCRIPT_DIR/config/settings.tier${TIER}.json"
    [ -f "$TIER_CONFIG" ] || fail "Missing tier config: $TIER_CONFIG"

    MODELS=$(python3 -c "import json; d=json.load(open('$TIER_CONFIG')); print('\n'.join(d.get('_requires_ollama_models', [])))")
    while IFS= read -r model; do
        [ -z "$model" ] && continue
        info "Pulling Ollama model: $model"
        ollama pull "$model" || warn "Failed to pull $model — continuing"
    done <<< "$MODELS"
fi

# ----------------------------------------------------------------------
# State directories (polyglot-scoped, not claude-scoped)
# ----------------------------------------------------------------------
mkdir -p "$HOME/.polyglot/state" "$HOME/.polyglot/session-logs"
ok "polyglot state dirs at $HOME/.polyglot/"

# ----------------------------------------------------------------------
# Merge hooks into settings.json (NEVER overwrite)
# ----------------------------------------------------------------------
info "Merging hooks into $CLAUDE_HOME/settings.json..."
TIER_CONFIG="$SCRIPT_DIR/config/settings.tier${TIER}.json"

python3 - "$TIER_CONFIG" "$CLAUDE_HOME/settings.json" "$SCRIPT_DIR" << 'PY'
import json, sys, copy
from pathlib import Path

tier_path, target_path, script_dir = sys.argv[1:4]
target = Path(target_path)

# Backup if exists
if target.exists():
    bak = target.with_suffix(target.suffix + ".polyglot-bak")
    bak.write_text(target.read_text())
    print(f"  backup: {bak}")
    existing = json.loads(target.read_text())
else:
    existing = {}

tier_cfg = json.loads(Path(tier_path).read_text())

# Template the POLYGLOT_ROOT placeholder
def template(obj):
    if isinstance(obj, str):
        return obj.replace("${POLYGLOT_ROOT}", script_dir)
    if isinstance(obj, dict):
        return {k: template(v) for k, v in obj.items() if not k.startswith("_")}
    if isinstance(obj, list):
        return [template(x) for x in obj]
    return obj

tier_hooks = template(tier_cfg.get("hooks", {}))

existing_hooks = existing.setdefault("hooks", {})
for event, entries in tier_hooks.items():
    existing_hooks.setdefault(event, [])
    for entry in entries:
        # Dedupe by command string
        cmd_sig = json.dumps(entry, sort_keys=True)
        exists = any(json.dumps(e, sort_keys=True) == cmd_sig for e in existing_hooks[event])
        if not exists:
            existing_hooks[event].append(entry)

target.write_text(json.dumps(existing, indent=4))
print(f"  wrote: {target}")
PY

ok "Hooks merged"

# ----------------------------------------------------------------------
# MCP server registration (tier >= 1)
# ----------------------------------------------------------------------
if [ "$TIER" -ge 1 ]; then
    MCP_FILE="$CLAUDE_HOME/settings.json"
    info "Registering polyglot MCP server in $MCP_FILE..."
    python3 - "$TIER_CONFIG" "$MCP_FILE" "$SCRIPT_DIR" << 'PY'
import json, sys
from pathlib import Path

tier_path, target_path, script_dir = sys.argv[1:4]
target = Path(target_path)
existing = json.loads(target.read_text()) if target.exists() else {}
tier_cfg = json.loads(Path(tier_path).read_text())

def template(obj):
    if isinstance(obj, str):
        return obj.replace("${POLYGLOT_ROOT}", script_dir)
    if isinstance(obj, dict):
        return {k: template(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [template(x) for x in obj]
    return obj

mcp_servers = template(tier_cfg.get("_mcp_servers", {}))
existing.setdefault("mcpServers", {}).update(mcp_servers)
target.write_text(json.dumps(existing, indent=4))
print(f"  MCP servers: {list(mcp_servers.keys())}")
PY
    ok "MCP server registered"

    info "Installing Python deps for MCP server..."
    pip install --user "mcp[cli]>=1.0.0" httpx 2>&1 | tail -3 || warn "pip install failed — install manually: pip install 'mcp[cli]>=1.0.0' httpx"
fi

# ----------------------------------------------------------------------
# Done
# ----------------------------------------------------------------------
echo
printf "${GREEN}${BOLD}✓ polyglot installed (tier %s, language %s)${NC}\n" "$TIER" "$LANG"
printf "\nNext:\n"
printf "  1. Restart Claude Code (new session picks up the hooks)\n"
printf "  2. Try a prompt in %s — you'll see the English-output reminder fire\n" "$LANG"
printf "  3. Check README.md for customization options\n"
echo
