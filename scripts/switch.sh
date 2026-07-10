#!/usr/bin/env bash
# shell-swap: provider/model-AGNOSTIC mass model switch for OpenClaw.
#
# The target is resolved against the LIVE config alias map
# (agents.defaults.models) — the single source of truth — so it never goes
# stale and works for ANY provider/model the config knows about. The resolved
# {model, provider} pair is stamped together across config + every session
# store, so model and provider can never diverge (the bug that broke routing).
#
# Provider is the resolved model entry's agentRuntime.id when set, otherwise the
# first path segment of the config key. This matters: anthropic/claude-opus-4-6
# runs on the claude-cli runtime, so its sessions carry provider "claude-cli",
# not "anthropic". Deriving provider from the key prefix alone would re-create
# the divergence bug.
#
# Usage: switch.sh [<alias|provider/model|full_id>] [--think LEVEL] [--fast MODE] [--agent NAME] [--all-agents] [--crons] [--dry-run]

set -euo pipefail

OPENCLAW_DIR="${OPENCLAW_DIR:-$HOME/.openclaw}"
CONFIG="${CONFIG:-$OPENCLAW_DIR/openclaw.json}"
CRON="${CRON:-$OPENCLAW_DIR/cron/jobs.json}"
AGENTS_DIR="${AGENTS_DIR:-$OPENCLAW_DIR/agents}"

usage() {
  cat <<'EOF'
Usage:
  switch.sh <target> [--agent NAME] [--all-agents] [--crons] [--dry-run]
  switch.sh --think LEVEL [--fast MODE] [--agent NAME] [--dry-run]
  switch.sh --fast MODE [--agent NAME] [--dry-run]

<target> is resolved against the live config alias map and may be:
  - alias          : any alias defined in agents.defaults.models (e.g. opus, gpt, minimax, grok-4.3)
  - provider/model : a full config key (e.g. anthropic/claude-opus-4-8, venice/grok-4-20)
  - raw id         : any "provider/model" not yet in config (agnostic passthrough)

Bare model names (no "/" and not a known alias) are rejected: the same model
can map to multiple providers, so the provider cannot be guessed safely.

Flags:
  --think LEVEL  Set the session thinking override on every selected session.
                 LEVEL: off|minimal|low|medium|high|xhigh|adaptive|max|default.
                 "default" clears the session override so config/provider defaults win.
  --fast MODE    Set the session fast-mode override on every selected session.
                 MODE: on|off|auto|default. "default" clears the session override.
  --session-mode MODE
                 How --think/--fast are written: "gateway" (default; warm-session
                 safe via sessions.patch) or "offline" (direct sessions.json repair).
  --agent NAME   Only rewrite this agent's session store; leaves the global
                 config primary untouched (scoped switch). Errors on unknown agent.
                 Use "--agent current" for the active agent (OPENCLAW_MCP_AGENT_ID).
  --current-agent  Shorthand for "--agent current"
  --all-agents   Rewrite every agent's session store + the config primary (default)
  --crons        Also rewrite cron payload.model values, if a legacy cron/jobs.json exists
  --dry-run      Show what would change without writing files
  -h, --help     Show this help
EOF
}

TARGET=""
DRY_RUN=0
TOUCH_CRONS=0
AGENT_FILTER=""
THINK_MODE_SET=0
THINK_MODE=""
FAST_MODE_SET=0
FAST_MODE=""
SESSION_MODE="gateway"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --crons|-c) TOUCH_CRONS=1 ;;
    --think|--thinking|-t)
      shift
      [[ $# -gt 0 ]] || { echo "[shell-swap] --think requires a level" >&2; exit 1; }
      THINK_MODE_SET=1
      THINK_MODE="$1"
      ;;
    --fast)
      shift
      [[ $# -gt 0 ]] || { echo "[shell-swap] --fast requires a mode" >&2; exit 1; }
      FAST_MODE_SET=1
      FAST_MODE="$1"
      ;;
    --session-mode)
      shift
      [[ $# -gt 0 ]] || { echo "[shell-swap] --session-mode requires gateway or offline" >&2; exit 1; }
      SESSION_MODE="$1"
      ;;
    --offline-session-overrides) SESSION_MODE="offline" ;;
    --all-agents) AGENT_FILTER="" ;;
    --agent)
      shift
      [[ $# -gt 0 ]] || { echo "[shell-swap] --agent requires a name (or 'current')" >&2; exit 1; }
      AGENT_FILTER="$1"
      ;;
    --current-agent) AGENT_FILTER="current" ;;
    -h|--help) usage; exit 0 ;;
    --*) echo "[shell-swap] Unknown flag: $1" >&2; usage >&2; exit 1 ;;
    *)
      if [[ -z "$TARGET" ]]; then TARGET="$1"
      else echo "[shell-swap] Unexpected extra argument: $1" >&2; usage >&2; exit 1; fi
      ;;
  esac
  shift
done

if [[ -z "$TARGET" && "$THINK_MODE_SET" -eq 0 && "$FAST_MODE_SET" -eq 0 ]]; then
  usage >&2
  exit 1
fi
[[ -f "$CONFIG" ]] || { echo "[shell-swap] Config not found: $CONFIG" >&2; exit 1; }

case "$SESSION_MODE" in
  gateway|offline) ;;
  *) echo "[shell-swap] --session-mode must be gateway or offline, got '$SESSION_MODE'" >&2; exit 1 ;;
esac

normalize_think() {
  local key
  key="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr '_' '-' | xargs)"
  case "$key" in
    default|inherit|clear|reset|unpin) printf 'null' ;;
    off|minimal|low|medium|high|xhigh|adaptive|max) printf '%s' "$key" ;;
    x-high|extra-high) printf 'xhigh' ;;
    highest) printf 'high' ;;
    *) return 1 ;;
  esac
}

normalize_fast() {
  local key
  key="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | xargs)"
  case "$key" in
    default|inherit|clear|reset|unpin) printf 'null' ;;
    on|true|yes|1|enable|enabled|fast) printf 'true' ;;
    off|false|no|0|disable|disabled|normal) printf 'false' ;;
    auto|automatic) printf 'auto' ;;
    *) return 1 ;;
  esac
}

THINK_VALUE=""
FAST_VALUE=""
if [[ "$THINK_MODE_SET" -eq 1 ]]; then
  THINK_VALUE="$(normalize_think "$THINK_MODE")" || {
    echo "[shell-swap] Invalid --think '$THINK_MODE' (use off|minimal|low|medium|high|xhigh|adaptive|max|default)" >&2
    exit 1
  }
fi
if [[ "$FAST_MODE_SET" -eq 1 ]]; then
  FAST_VALUE="$(normalize_fast "$FAST_MODE")" || {
    echo "[shell-swap] Invalid --fast '$FAST_MODE' (use on|off|auto|default)" >&2
    exit 1
  }
fi

# "current" resolves to the active agent from the OpenClaw runtime env.
if [[ "$AGENT_FILTER" == "current" ]]; then
  AGENT_FILTER="${OPENCLAW_MCP_AGENT_ID:-${OPENCLAW_AGENT_ID:-}}"
  if [[ -z "$AGENT_FILTER" ]]; then
    echo "[shell-swap] --agent current: cannot determine the active agent (OPENCLAW_MCP_AGENT_ID unset). Pass an explicit name." >&2
    exit 1
  fi
fi

# --- Resolve target -> canonical {full_id, provider, model_id} from LIVE config ---
# provider = resolved entry's agentRuntime.id if set, else first path segment.
if [[ -n "$TARGET" ]]; then
  RESOLVED="$(python3 - "$CONFIG" "$TARGET" <<'PYEOF'
import json, sys

config_path, target = sys.argv[1], sys.argv[2]
try:
    with open(config_path) as f:
        data = json.load(f)
except (OSError, ValueError) as e:
    sys.stderr.write(f"[shell-swap] Cannot read config {config_path}: {e}\n")
    sys.exit(2)

models = (data.get("agents", {}).get("defaults", {}).get("models", {}) or {})
alias_map = {}
for key, cfg in models.items():
    if isinstance(cfg, dict):
        a = cfg.get("alias")
        if isinstance(a, str) and a:
            alias_map[a] = key

if target in alias_map:
    full_id = alias_map[target]
elif target in models:
    full_id = target
elif "/" in target:
    full_id = target  # agnostic passthrough: any provider/model, even if not in allowlist
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

# Runtime-aware provider: the session 'modelProvider' reflects the model entry's
# agentRuntime, not necessarily the key prefix.
entry = models.get(full_id)
if isinstance(entry, dict):
    rt = entry.get("agentRuntime")
    if isinstance(rt, dict) and isinstance(rt.get("id"), str) and rt["id"]:
        provider = rt["id"]

print(full_id)
print(provider)
print(model_id)
PYEOF
  )" || exit $?

  FULL_ID="$(sed -n '1p' <<<"$RESOLVED")"
  PROVIDER="$(sed -n '2p' <<<"$RESOLVED")"
  MODEL_ID="$(sed -n '3p' <<<"$RESOLVED")"
else
  FULL_ID=""
  PROVIDER=""
  MODEL_ID=""
fi

if [[ -n "$TARGET" ]]; then
  echo "[shell-swap] Target input     : $TARGET"
  echo "[shell-swap] Resolved full id  : $FULL_ID"
  echo "[shell-swap] Session model     : $MODEL_ID"
  echo "[shell-swap] Session provider  : $PROVIDER"
else
  echo "[shell-swap] Target input     : <none; session overrides only>"
fi
if [[ -n "$AGENT_FILTER" ]]; then
  echo "[shell-swap] Agent scope       : $AGENT_FILTER (config primary NOT changed)"
elif [[ -z "$TARGET" ]]; then
  echo "[shell-swap] Agent scope       : ALL agents (session overrides only)"
else
  echo "[shell-swap] Agent scope       : ALL agents (+ config primary)"
fi
if [[ "$THINK_MODE_SET" -eq 1 || "$FAST_MODE_SET" -eq 1 ]]; then
  [[ "$THINK_MODE_SET" -eq 1 ]] && echo "[shell-swap] Thinking override: $THINK_VALUE"
  [[ "$FAST_MODE_SET" -eq 1 ]] && echo "[shell-swap] Fast override    : $FAST_VALUE"
  echo "[shell-swap] Session mode     : $SESSION_MODE"
fi
[[ "$TOUCH_CRONS" -eq 1 ]] && echo "[shell-swap] Cron updates      : enabled" || echo "[shell-swap] Cron updates      : disabled (pass --crons)"
[[ "$DRY_RUN" -eq 1 ]] && echo "[shell-swap] DRY RUN — no files will be modified"

# --- Build the list of session stores to touch (and validate the agent name) ---
shopt -s nullglob
STORES=()
for store in "$AGENTS_DIR"/*/sessions/sessions.json; do
  agent_name="$(basename "$(dirname "$(dirname "$store")")")"
  if [[ -n "$AGENT_FILTER" && "$agent_name" != "$AGENT_FILTER" ]]; then
    continue
  fi
  STORES+=("$store")
done
shopt -u nullglob

if [[ -n "$AGENT_FILTER" && ${#STORES[@]} -eq 0 ]]; then
  echo "[shell-swap] No session store for agent '$AGENT_FILTER' under $AGENTS_DIR — aborting (no changes made)." >&2
  exit 4
fi

# --- Pre-validate ALL targets as parseable JSON before writing anything ---
# Prevents a split-fleet state where some files are switched and a later
# malformed file aborts the run mid-way.
echo ""
echo "=== pre-flight (validating JSON) ==="
preflight_ok=1
PREFLIGHT_FILES=("$CONFIG" "${STORES[@]}")
if [[ "$TOUCH_CRONS" -eq 1 && -f "$CRON" ]]; then
  PREFLIGHT_FILES+=("$CRON")
fi
python3 - "${PREFLIGHT_FILES[@]}" <<'PYEOF' || preflight_ok=0
import json, sys
bad = []
for p in sys.argv[1:]:
    try:
        with open(p) as f:
            json.load(f)
    except (OSError, ValueError) as e:
        bad.append(f"{p}: {e}")
if bad:
    for b in bad:
        sys.stderr.write(f"  INVALID {b}\n")
    sys.exit(1)
print(f"  {len(sys.argv) - 1} file(s) parse OK")
PYEOF
[[ "$preflight_ok" -eq 1 ]] || { echo "[shell-swap] Pre-flight failed — aborting with no changes." >&2; exit 5; }

# Atomic JSON writer used by the steps below (tmp file + os.replace).
write_atomic_py='
import json, os, tempfile
def write_atomic(path, data):
    d = os.path.dirname(path) or "."
    try:
        mode = os.stat(path).st_mode & 0o777
    except OSError:
        mode = None
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".shellswap-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2)
        if mode is not None:
            os.chmod(tmp, mode)  # mkstemp is 0600; preserve original perms
        os.replace(tmp, path)
    except BaseException:
        try: os.unlink(tmp)
        except OSError: pass
        raise
'

# --- 1. config: primary model only (skipped for scoped --agent runs) ---
echo ""
echo "=== openclaw.json ==="
if [[ -z "$TARGET" ]]; then
  echo "  skipped (no model target; session overrides only)"
elif [[ -n "$AGENT_FILTER" ]]; then
  echo "  skipped (scoped --agent run; primary left as-is)"
else
  [[ "$DRY_RUN" -eq 0 ]] && cp "$CONFIG" "$CONFIG.bak"
  python3 - "$CONFIG" "$FULL_ID" "$DRY_RUN" <<PYEOF
$write_atomic_py
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
        write_atomic(config_path, data)
    print("  (1 change, backup: openclaw.json.bak)")
else:
    print(f"  primary: already {full_id}")
    print("  (0 changes)")
print("  models allowlist + fallbacks: unchanged (intentional)")
PYEOF
fi

# --- 2. sessions: stamp {model, provider} together on session entries ---
# Scoped to direct session-entry keys only (never nested report/budget/origin
# blocks). Skips "auto" sentinels. Provenance (modelOverrideSource) is only
# flipped to "user" on sessions whose model identity we actually changed.
rewrite_sessions() {
  local sessions_file="$1"
  [[ -f "$sessions_file" ]] || return 0
  [[ "$DRY_RUN" -eq 0 ]] && cp "$sessions_file" "$sessions_file.bak"
  python3 - "$sessions_file" "$MODEL_ID" "$PROVIDER" "$DRY_RUN" <<PYEOF
$write_atomic_py
import json, sys
path, model_id, provider, dry = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
with open(path) as f:
    data = json.load(f)

stale_fallback_fields = (
    "modelOverrideFallbackOriginProvider",
    "modelOverrideFallbackOriginModel",
    "modelOverrideFallbackNotice",
)
c = {"model": 0, "override": 0, "provider": 0, "source": 0, "stale": 0, "pinCleared": 0, "autoSkipped": 0}

# Store schema: { sessionKey: sessionDict }. Only touch direct keys.
entries = data.values() if isinstance(data, dict) else []
for s in entries:
    if not isinstance(s, dict):
        continue
    m = s.get("model")
    if m == "auto" or s.get("modelOverride") == "auto":
        c["autoSkipped"] += 1
        continue
    model_changed = False
    if isinstance(m, str) and m != model_id:
        s["model"] = model_id; c["model"] += 1; model_changed = True
    mo = s.get("modelOverride")
    if isinstance(mo, str) and mo != model_id:
        s["modelOverride"] = model_id; c["override"] += 1; model_changed = True
    # Repair provider on any session now on the target model (fixes divergence
    # even where the model field was already correct). Note: "on target" is
    # judged by model id, so when two providers share a model id (e.g.
    # claude-sonnet-4-6 under both venice and claude-cli), a fleet switch to one
    # re-homes the other's provider to the target. That's intended — a fleet
    # switch means "everyone on THIS provider+model" — but it does mean a
    # session deliberately on venice/claude-sonnet-4-6 moves to the target
    # provider when you switch to a different claude-sonnet-4-6 lane.
    on_target = (s.get("model") == model_id) or (s.get("modelOverride") == model_id)
    if on_target:
        for pf in ("modelProvider", "providerOverride"):
            v = s.get(pf)
            if isinstance(v, str) and v != provider:
                s[pf] = provider; c["provider"] += 1
    # Provenance + stale cleanup only where we actively switched the model.
    if model_changed:
        if isinstance(s.get("modelOverrideSource"), str) and s["modelOverrideSource"] != "user":
            s["modelOverrideSource"] = "user"; c["source"] += 1
        for fld in stale_fallback_fields:
            if fld in s:
                del s[fld]; c["stale"] += 1
        # Clear stale harness/runtime pins so routing can't deadlock on a dead
        # harness. The codex-out-of-quota bug: a session pinned to
        # agentHarnessId:"codex" keeps hitting the codex harness even after its
        # model is switched, and liveModelSwitchPending only clears on a
        # *successful* turn that never comes (codex is out of quota) -> deadlock.
        # File-surgery hard-sets the model, so any pending live switch is already
        # resolved; and a harness/runtime pin is only valid when we're switching
        # INTO that explicit-runtime lane (provider == agentRuntime.id, e.g.
        # "codex"). Healthy sessions carry no pin and re-derive the harness from
        # the model, so removing these is safe for normal model-derived runtimes.
        if s.pop("liveModelSwitchPending", None) is not None:
            c["pinCleared"] += 1
        if provider != "codex":
            for pin in ("agentHarnessId", "agentRuntimeOverride"):
                if s.pop(pin, None) is not None:
                    c["pinCleared"] += 1

total = c["model"] + c["override"] + c["provider"] + c["source"] + c["stale"] + c["pinCleared"]
if not dry and total:
    write_atomic(path, data)
print(f"  {path}")
print(f"    model={c['model']} modelOverride={c['override']} provider={c['provider']} "
      f"source={c['source']} staleRemoved={c['stale']} pinCleared={c['pinCleared']} "
      f"autoSkipped={c['autoSkipped']}")
PYEOF
}

rewrite_session_overrides_offline() {
  local sessions_file="$1"
  [[ -f "$sessions_file" ]] || return 0
  [[ "$DRY_RUN" -eq 0 ]] && cp "$sessions_file" "$sessions_file.bak"
  python3 - "$sessions_file" "$THINK_MODE_SET" "$THINK_VALUE" "$FAST_MODE_SET" "$FAST_VALUE" "$DRY_RUN" <<PYEOF
$write_atomic_py
import json, sys
path, think_set, think_value, fast_set, fast_value, dry = sys.argv[1], sys.argv[2] == "1", sys.argv[3], sys.argv[4] == "1", sys.argv[5], sys.argv[6] == "1"
with open(path) as f:
    data = json.load(f)
c = {"thinkSet": 0, "thinkCleared": 0, "fastSet": 0, "fastCleared": 0}
entries = data.values() if isinstance(data, dict) else []
for s in entries:
    if not isinstance(s, dict):
        continue
    if think_set:
        if think_value == "null":
            if "thinkingLevel" in s:
                del s["thinkingLevel"]; c["thinkCleared"] += 1
        elif s.get("thinkingLevel") != think_value:
            s["thinkingLevel"] = think_value; c["thinkSet"] += 1
    if fast_set:
        if fast_value == "null":
            if "fastMode" in s:
                del s["fastMode"]; c["fastCleared"] += 1
        else:
            next_fast = True if fast_value == "true" else False if fast_value == "false" else fast_value
            if s.get("fastMode") != next_fast:
                s["fastMode"] = next_fast; c["fastSet"] += 1
total = sum(c.values())
if not dry and total:
    write_atomic(path, data)
print(f"  {path}")
print(f"    thinkingSet={c['thinkSet']} thinkingCleared={c['thinkCleared']} fastSet={c['fastSet']} fastCleared={c['fastCleared']}")
PYEOF
}

patch_session_overrides_gateway() {
  local failed=0
  local attempted=0
  local ok=0
  local skipped=0
  local failure_log=""

  if [[ "$DRY_RUN" -eq 1 ]]; then
    for store in "${STORES[@]}"; do
      local count
      count="$(python3 - "$store" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
print(len(data) if isinstance(data, dict) else 0)
PYEOF
)"
      skipped=$((skipped + count))
    done
    echo "  dry-run: would patch $skipped session(s) through Gateway sessions.patch"
    return 0
  fi

  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    attempted=$((attempted + 1))
    local params
    params="$(python3 - "$key" "$THINK_MODE_SET" "$THINK_VALUE" "$FAST_MODE_SET" "$FAST_VALUE" <<'PYEOF'
import json, sys
key, think_set, think_value, fast_set, fast_value = sys.argv[1], sys.argv[2] == "1", sys.argv[3], sys.argv[4] == "1", sys.argv[5]
params = {"key": key}
if think_set:
    params["thinkingLevel"] = None if think_value == "null" else think_value
if fast_set:
    if fast_value == "null":
        params["fastMode"] = None
    elif fast_value == "true":
        params["fastMode"] = True
    elif fast_value == "false":
        params["fastMode"] = False
    else:
        params["fastMode"] = fast_value
print(json.dumps(params, separators=(",", ":")))
PYEOF
)"
    local out
    if out="$(openclaw gateway call sessions.patch --params "$params" --json --timeout 10000 2>&1)"; then
      if python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("ok") else 1)' <<<"$out" 2>/dev/null; then
        ok=$((ok + 1))
      else
        failed=$((failed + 1))
        local msg
        msg="$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("error",{}).get("message") or d.get("error") or "unknown error")' <<<"$out" 2>/dev/null || printf '%s' "$out")"
        failure_log="${failure_log}    ${key}: ${msg}"$'\n'
      fi
    else
      failed=$((failed + 1))
      failure_log="${failure_log}    ${key}: ${out}"$'\n'
    fi
  done < <(python3 - "${STORES[@]}" <<'PYEOF'
import json, sys
for path in sys.argv[1:]:
    with open(path) as f:
        data = json.load(f)
    if isinstance(data, dict):
        for key in data.keys():
            print(key)
PYEOF
)

  echo "  sessions.patch attempted=$attempted ok=$ok failed=$failed"
  if [[ "$failed" -gt 0 ]]; then
    printf '%s' "$failure_log" | sed -n '1,25p'
    if [[ "$(printf '%s' "$failure_log" | wc -l | tr -d ' ')" -gt 25 ]]; then
      echo "    ...additional failures omitted"
    fi
    echo "[shell-swap] Some session override patches failed; those sessions were left unchanged." >&2
    return 6
  fi
}

echo ""
echo "=== sessions ==="
if [[ -n "$TARGET" ]]; then
  for store in "${STORES[@]}"; do
    rewrite_sessions "$store"
  done
fi

if [[ "$THINK_MODE_SET" -eq 1 || "$FAST_MODE_SET" -eq 1 ]]; then
  echo ""
  echo "=== session overrides ==="
  if [[ "$SESSION_MODE" == "gateway" ]]; then
    patch_session_overrides_gateway
  else
    for store in "${STORES[@]}"; do
      rewrite_session_overrides_offline "$store"
    done
  fi
fi

# --- 3. cron (opt-in, legacy path; format may have migrated) ---
echo ""
echo "=== cron/jobs.json ==="
if [[ -z "$TARGET" ]]; then
  echo "  skipped (no model target; session overrides only)"
elif [[ "$TOUCH_CRONS" -eq 0 ]]; then
  echo "  skipped (pass --crons to enable)"
elif [[ -f "$CRON" ]]; then
  [[ "$DRY_RUN" -eq 0 ]] && cp "$CRON" "$CRON.bak"
  python3 - "$CRON" "$FULL_ID" "$DRY_RUN" <<PYEOF
$write_atomic_py
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
    write_atomic(path, data)
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
  echo "[shell-swap] Done. Sessions set to $FULL_ID (model=$MODEL_ID provider=$PROVIDER)."
fi
