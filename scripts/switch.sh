#!/usr/bin/env bash
# shell-swap: provider/model-AGNOSTIC mass model switch for OpenClaw.
#
# The target is resolved against the LIVE config alias map
# (agents.defaults.models) — the single source of truth — so it never goes
# stale and works for ANY provider/model the config knows about. The resolved
# {model, provider} pair is then stamped together across config + every session
# store, so model and provider can never diverge (the bug that broke routing
# before). No hardcoded alias table, no per-provider special cases.
#
# Usage: switch.sh <alias|provider/model|full_id> [--agent NAME] [--all-agents] [--crons] [--dry-run]

set -euo pipefail

OPENCLAW_DIR="${OPENCLAW_DIR:-$HOME/.openclaw}"
CONFIG="${CONFIG:-$OPENCLAW_DIR/openclaw.json}"
CRON="${CRON:-$OPENCLAW_DIR/cron/jobs.json}"
AGENTS_DIR="${AGENTS_DIR:-$OPENCLAW_DIR/agents}"

usage() {
  cat <<'EOF'
Usage: switch.sh <target> [--agent NAME] [--all-agents] [--crons] [--dry-run]

<target> is resolved against the live config alias map and may be:
  - alias          : any alias defined in agents.defaults.models (e.g. opus, gpt, minimax, grok-4.3)
  - provider/model : a full config key (e.g. anthropic/claude-opus-4-8, venice/grok-4-20)
  - raw id         : any "provider/model" not yet in config (agnostic passthrough)

Bare model names (no "/" and not a known alias) are rejected: the same model
can map to multiple providers, so the provider cannot be guessed safely.

Flags:
  --agent NAME   Only rewrite this agent's session store (default: every agent under agents/)
  --all-agents   Rewrite every agent's session store (this is the default; flag is explicit opt-in)
  --crons        Also rewrite cron payload.model values, if a legacy cron/jobs.json exists
  --dry-run      Show what would change without writing files
  -h, --help     Show this help
EOF
}

TARGET=""
DRY_RUN=0
TOUCH_CRONS=0
AGENT_FILTER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --crons|-c) TOUCH_CRONS=1 ;;
    --all-agents) AGENT_FILTER="" ;;
    --agent)
      shift
      [[ $# -gt 0 ]] || { echo "[shell-swap] --agent requires a name" >&2; exit 1; }
      AGENT_FILTER="$1"
      ;;
    -h|--help) usage; exit 0 ;;
    --*) echo "[shell-swap] Unknown flag: $1" >&2; usage >&2; exit 1 ;;
    *)
      if [[ -z "$TARGET" ]]; then TARGET="$1"
      else echo "[shell-swap] Unexpected extra argument: $1" >&2; usage >&2; exit 1; fi
      ;;
  esac
  shift
done

if [[ -z "$TARGET" ]]; then usage >&2; exit 1; fi

# --- Resolve target -> canonical {full_id, provider, model_id} from LIVE config ---
RESOLVED="$(python3 - "$CONFIG" "$TARGET" <<'PYEOF'
import json, sys

config_path, target = sys.argv[1], sys.argv[2]
with open(config_path) as f:
    data = json.load(f)

models = (data.get("agents", {}).get("defaults", {}).get("models", {}) or {})
alias_map = {}
keys = set()
for key, cfg in models.items():
    keys.add(key)
    if isinstance(cfg, dict):
        a = cfg.get("alias")
        if isinstance(a, str) and a:
            alias_map[a] = key

if target in alias_map:
    full_id = alias_map[target]
elif target in keys:
    full_id = target
elif "/" in target:
    # Agnostic passthrough: any provider/model, even if not yet in the allowlist.
    full_id = target
else:
    sys.stderr.write(
        f"[shell-swap] '{target}' is not a known alias and has no provider prefix.\n"
        f"[shell-swap] Pass a full id like 'anthropic/claude-opus-4-8' or a configured alias.\n"
    )
    sys.exit(3)

provider, _, model_id = full_id.partition("/")
if not provider or not model_id:
    sys.stderr.write(f"[shell-swap] target must be 'provider/model', got '{full_id}'\n")
    sys.exit(3)

print(full_id)
print(provider)
print(model_id)
PYEOF
)" || exit $?

FULL_ID="$(sed -n '1p' <<<"$RESOLVED")"
PROVIDER="$(sed -n '2p' <<<"$RESOLVED")"
MODEL_ID="$(sed -n '3p' <<<"$RESOLVED")"

echo "[shell-swap] Target input     : $TARGET"
echo "[shell-swap] Resolved full id  : $FULL_ID"
echo "[shell-swap] Session model     : $MODEL_ID"
echo "[shell-swap] Session provider  : $PROVIDER"
if [[ -n "$AGENT_FILTER" ]]; then
  echo "[shell-swap] Agent scope       : $AGENT_FILTER"
else
  echo "[shell-swap] Agent scope       : ALL agents"
fi
[[ "$TOUCH_CRONS" -eq 1 ]] && echo "[shell-swap] Cron updates      : enabled" || echo "[shell-swap] Cron updates      : disabled (pass --crons)"
[[ "$DRY_RUN" -eq 1 ]] && echo "[shell-swap] DRY RUN — no files will be modified"

# --- 1. config: primary model only (allowlist + fallbacks left untouched) ---
echo ""
echo "=== openclaw.json ==="
python3 - "$CONFIG" "$FULL_ID" "$DRY_RUN" <<'PYEOF'
import json, sys
config_path, full_id, dry = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
with open(config_path) as f:
    data = json.load(f)
ad = data.setdefault("agents", {}).setdefault("defaults", {})
model_cfg = ad.setdefault("model", {})
old = model_cfg.get("primary", "")
if old != full_id:
    print(f"  primary: {old or '<unset>'} -> {full_id}")
    model_cfg["primary"] = full_id
    if not dry:
        with open(config_path, "w") as f:
            json.dump(data, f, indent=2)
    print("  (1 change)")
else:
    print(f"  primary: already {full_id}")
    print("  (0 changes)")
print("  models allowlist + fallbacks: unchanged (intentional)")
PYEOF

# --- 2. sessions: stamp {model, provider} together across agent stores ---
rewrite_sessions() {
  local sessions_file="$1"
  [[ -f "$sessions_file" ]] || return 0
  [[ "$DRY_RUN" -eq 0 ]] && cp "$sessions_file" "$sessions_file.bak"
  python3 - "$sessions_file" "$MODEL_ID" "$PROVIDER" "$DRY_RUN" <<'PYEOF'
import json, sys
path, model_id, provider, dry = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
with open(path) as f:
    data = json.load(f)

stale_fallback_fields = {
    "modelOverrideFallbackOriginProvider",
    "modelOverrideFallbackOriginModel",
    "modelOverrideFallbackNotice",
}
c = {"model": 0, "override": 0, "provider": 0, "source": 0, "stale": 0}

def walk(obj):
    if isinstance(obj, dict):
        for k in list(obj.keys()):
            v = obj[k]
            if k in ("model", "modelOverride") and isinstance(v, str):
                if v != model_id:
                    obj[k] = model_id
                    c["override" if k == "modelOverride" else "model"] += 1
            elif k in ("modelProvider", "providerOverride") and isinstance(v, str):
                if v != provider:
                    obj[k] = provider
                    c["provider"] += 1
            elif k == "modelOverrideSource" and isinstance(v, str):
                if v != "user":
                    obj[k] = "user"
                    c["source"] += 1
            elif k in stale_fallback_fields:
                del obj[k]
                c["stale"] += 1
            else:
                walk(v)
    elif isinstance(obj, list):
        for item in obj:
            walk(item)

walk(data)
total = sum(c.values())
if not dry and total:
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
print(f"  {path}")
print(f"    model={c['model']} modelOverride={c['override']} provider={c['provider']} "
      f"source={c['source']} staleRemoved={c['stale']}")
PYEOF
}

echo ""
echo "=== sessions ==="
shopt -s nullglob
found=0
for store in "$AGENTS_DIR"/*/sessions/sessions.json; do
  agent_name="$(basename "$(dirname "$(dirname "$store")")")"
  if [[ -n "$AGENT_FILTER" && "$agent_name" != "$AGENT_FILTER" ]]; then
    continue
  fi
  found=1
  rewrite_sessions "$store"
done
shopt -u nullglob
[[ "$found" -eq 0 ]] && echo "  (no matching session stores under $AGENTS_DIR)"

# --- 3. cron (opt-in, legacy path; format may have migrated) ---
echo ""
echo "=== cron/jobs.json ==="
if [[ "$TOUCH_CRONS" -eq 0 ]]; then
  echo "  skipped (pass --crons to enable)"
elif [[ -f "$CRON" ]]; then
  [[ "$DRY_RUN" -eq 0 ]] && cp "$CRON" "$CRON.bak"
  python3 - "$CRON" "$FULL_ID" "$DRY_RUN" <<'PYEOF'
import json, sys
path, full_id, dry = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
with open(path) as f:
    data = json.load(f)
changed = []
for job in data.get("jobs", []):
    payload = job.get("payload", {})
    old = payload.get("model")
    if isinstance(old, str) and old != full_id:
        changed.append(f"  {job.get('name', '<unnamed>')}: {old} -> {full_id}")
        payload["model"] = full_id
if not dry and changed:
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
for line in changed:
    print(line)
print(f"  ({len(changed)} jobs changed)")
PYEOF
else
  echo "  (legacy cron/jobs.json not found — cron format may have migrated; skipping)"
fi

echo ""
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[shell-swap] Dry run complete. No files modified."
else
  echo "[shell-swap] Done. Config primary + sessions set to $FULL_ID."
fi
