#!/usr/bin/env bash
# model-switch: mass-set all OpenClaw sessions and cron jobs to a target model
# Usage: switch.sh <haiku|sonnet|opus> [--dry-run]

set -euo pipefail

OPENCLAW_DIR="$HOME/.openclaw"
CONFIG="$OPENCLAW_DIR/openclaw.json"
SESSIONS="$OPENCLAW_DIR/agents/main/sessions/sessions.json"
CRON="$OPENCLAW_DIR/cron/jobs.json"

ALIAS="${1:?Usage: switch.sh <haiku|sonnet|opus> [--dry-run]}"
DRY_RUN=""
[[ "${2:-}" == "--dry-run" ]] && DRY_RUN="1"

case "$ALIAS" in
  haiku)    MODEL_ID="claude-haiku-4-5";       FULL_ID="anthropic/claude-haiku-4-5" ;;
  sonnet)   MODEL_ID="claude-sonnet-4-6";      FULL_ID="anthropic/claude-sonnet-4-6" ;;
  opus)     MODEL_ID="claude-opus-4-6";        FULL_ID="anthropic/claude-opus-4-6" ;;
  gpt-5.4)  MODEL_ID="gpt-5.4";               FULL_ID="openai-codex/gpt-5.4" ;;
  spark)    MODEL_ID="gpt-5.3-codex-spark";    FULL_ID="openai-codex/gpt-5.3-codex-spark" ;;
  codex)    MODEL_ID="gpt-5.3-codex";          FULL_ID="openai-codex/gpt-5.3-codex" ;;
  *)
    echo "[brain-swap] Unknown alias: $ALIAS (use: haiku, sonnet, opus, gpt-5.4, spark, codex)" >&2
    exit 1
    ;;
esac

echo "[brain-swap] Target: $ALIAS ($FULL_ID)"
[[ -n "$DRY_RUN" ]] && echo "[brain-swap] DRY RUN — no files will be modified"

# --- 1. Update openclaw.json ---
echo ""
echo "=== openclaw.json ==="
python3 - "$CONFIG" "$FULL_ID" "$ALIAS" "${DRY_RUN:-0}" <<'PYEOF'
import json, sys

config_path, full_id, alias, dry = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] != "0"

with open(config_path) as f:
    data = json.load(f)

changes = 0
ad = data.get("agents", {}).get("defaults", {})

model_cfg = ad.get("model", {})
old_primary = model_cfg.get("primary", "")
if old_primary != full_id:
    print(f"  primary: {old_primary} -> {full_id}")
    model_cfg["primary"] = full_id
    changes += 1
else:
    print(f"  primary: already {full_id}")

models = ad.get("models", {})
old_keys = list(models.keys())
new_models = {full_id: {"alias": alias}}
if models != new_models:
    print(f"  models allowlist: {old_keys} -> [{full_id}]")
    ad["models"] = new_models
    changes += 1
else:
    print(f"  models allowlist: already [{full_id}]")

if changes > 0 and not dry:
    with open(config_path, "w") as f:
        json.dump(data, f, indent=2)

print(f"  ({changes} changes)")
PYEOF

# --- 2. Update sessions.json ---
echo ""
echo "=== sessions.json ==="
if [[ -f "$SESSIONS" ]]; then
  [[ -z "$DRY_RUN" ]] && cp "$SESSIONS" "$SESSIONS.bak"
  python3 - "$SESSIONS" "$MODEL_ID" "${DRY_RUN:-0}" <<'PYEOF'
import json, sys

path, target, dry = sys.argv[1], sys.argv[2], sys.argv[3] != "0"

with open(path) as f:
    data = json.load(f)

counts = {"model": 0, "override": 0, "skipped": 0}

def walk(obj):
    if isinstance(obj, dict):
        for k in list(obj.keys()):
            v = obj[k]
            if k == "model" and isinstance(v, str) and v != target and "claude-" in v:
                obj[k] = target
                counts["model"] += 1
            elif k == "modelOverride" and isinstance(v, str) and v != target and "claude-" in v:
                obj[k] = target
                counts["override"] += 1
            elif k == "model" and isinstance(v, str) and "claude-" not in v:
                counts["skipped"] += 1
            else:
                walk(v)
    elif isinstance(obj, list):
        for item in obj:
            walk(item)

walk(data)

if not dry:
    with open(path, "w") as f:
        json.dump(data, f, indent=2)

print(f"  model fields: {counts['model']} changed")
print(f"  modelOverride fields: {counts['override']} changed")
if counts["skipped"]:
    print(f"  skipped (non-claude): {counts['skipped']}")
print("  (backup: sessions.json.bak)")
PYEOF
else
  echo "  (not found, skipping)"
fi

# --- 3. Update cron jobs ---
echo ""
echo "=== cron/jobs.json ==="
if [[ -f "$CRON" ]]; then
  [[ -z "$DRY_RUN" ]] && cp "$CRON" "$CRON.bak"
  python3 - "$CRON" "$ALIAS" "${DRY_RUN:-0}" <<'PYEOF'
import json, sys

path, alias, dry = sys.argv[1], sys.argv[2], sys.argv[3] != "0"

with open(path) as f:
    data = json.load(f)

changed = []
for job in data.get("jobs", []):
    payload = job.get("payload", {})
    old = payload.get("model")
    if old and old != alias:
        changed.append(f"  {job['name']}: {old} -> {alias}")
        payload["model"] = alias

if not dry and changed:
    with open(path, "w") as f:
        json.dump(data, f, indent=2)

for c in changed:
    print(c)
if not changed:
    print(f"  (all already {alias})")
print(f"  ({len(changed)} jobs changed)")
print("  (backup: jobs.json.bak)")
PYEOF
else
  echo "  (not found, skipping)"
fi

echo ""
if [[ -n "$DRY_RUN" ]]; then
  echo "[brain-swap] Dry run complete. No files modified."
else
  echo "[brain-swap] Done. All sessions and jobs now using $ALIAS ($FULL_ID)."
  echo "[brain-swap] A gateway restart may be needed for config changes to take effect."
fi
