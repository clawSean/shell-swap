#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWITCH="$ROOT/scripts/switch.sh"
BASH5="${BASH5:-/opt/homebrew/bin/bash}"
[[ -x "$BASH5" ]] || BASH5="$(command -v bash)"

pass=0
fail() { echo "not ok - $*" >&2; exit 1; }
ok() { pass=$((pass + 1)); echo "ok $pass - $*"; }

FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/shell-swap-test.XXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/bin" "$FIXTURE/oc/agents/main/sessions" "$FIXTURE/oc/cron"

cat >"$FIXTURE/oc/openclaw.json" <<'JSON'
{
  "agents": {
    "defaults": {
      "model": {
        "primary": "openai/gpt-5.6-sol",
        "fallbacks": ["claude-cli/claude-opus-4-6"]
      },
      "models": {
        "openai/gpt-5.6-sol": {"alias": "sol", "agentRuntime": {"id": "codex"}},
        "claude-cli/claude-opus-4-8": {"alias": "opus", "agentRuntime": {"id": "claude-cli"}}
      }
    }
  }
}
JSON

write_sessions() {
  cat >"$FIXTURE/oc/agents/main/sessions/sessions.json" <<'JSON'
{
  "agent:main:telegram:group:1": {
    "sessionId": "parent",
    "model": "gpt-5.5",
    "modelProvider": "openai",
    "modelOverride": "gpt-5.5",
    "providerOverride": "openai",
    "modelOverrideSource": "user",
    "modelOverrideFallbackOriginProvider": "openai",
    "modelOverrideFallbackOriginModel": "gpt-5.6-sol",
    "liveModelSwitchPending": true
  },
  "agent:main:telegram:group:1:topic:2": {
    "sessionId": "topic",
    "model": "claude-opus-4-8",
    "modelProvider": "claude-cli",
    "modelOverride": "claude-opus-4-8",
    "providerOverride": "claude-cli",
    "modelOverrideSource": "user",
    "liveModelSwitchPending": true
  },
  "agent:main:slack:channel:active": {
    "sessionId": "active",
    "model": "gpt-5.5",
    "modelProvider": "openai",
    "modelOverride": "gpt-5.5",
    "providerOverride": "openai",
    "modelOverrideSource": "user",
    "liveModelSwitchPending": true
  }
}
JSON
}
write_sessions

cat >"$FIXTURE/bin/openclaw" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
STORE="${FAKE_STORE:?}"
if [[ "$*" == *"gateway call health"* ]]; then
  [[ "${FAKE_GATEWAY_RUNNING:-1}" == "1" ]]
  exit
fi
if [[ "$*" == *"gateway call sessions.list"* ]]; then
  python3 - "$STORE" "${FAKE_ACTIVE_KEY:-}" <<'PY'
import json, sys
with open(sys.argv[1]) as f: data = json.load(f)
active = sys.argv[2]
print(json.dumps({"sessions": [{"key": k, "hasActiveRun": k == active} for k in data], "ok": True}))
PY
  exit
fi
if [[ "$*" == *"gateway call sessions.patch"* ]]; then
  params=""
  while [[ $# -gt 0 ]]; do
    [[ "$1" == "--params" ]] && { params="$2"; break; }
    shift
  done
  python3 - "$STORE" "$params" <<'PY'
import json, os, sys, tempfile
path, raw = sys.argv[1], sys.argv[2]
p = json.loads(raw)
with open(path) as f: data = json.load(f)
entry = data[p["key"]]
if "model" in p and p["model"] is None:
    for field in (
        "providerOverride", "modelOverride", "modelOverrideSource",
        "modelOverrideFallbackOriginProvider", "modelOverrideFallbackOriginModel",
        "fallbackNoticeSelectedModel", "fallbackNoticeActiveModel",
        "fallbackNoticeReason", "liveModelSwitchPending", "model", "modelProvider",
        "contextTokens", "contextBudgetStatus",
    ):
        entry.pop(field, None)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".test-")
with os.fdopen(fd, "w") as f: json.dump(data, f, indent=2)
os.replace(tmp, path)
print(json.dumps({"ok": True}))
PY
  exit
fi
echo "unexpected fake openclaw call: $*" >&2
exit 1
SH
chmod +x "$FIXTURE/bin/openclaw"

run_swap() {
  PATH="$FIXTURE/bin:$PATH" \
  OPENCLAW_DIR="$FIXTURE/oc" \
  CONFIG="$FIXTURE/oc/openclaw.json" \
  AGENTS_DIR="$FIXTURE/oc/agents" \
  CRON="$FIXTURE/oc/cron/jobs.json" \
  FAKE_STORE="$FIXTURE/oc/agents/main/sessions/sessions.json" \
  "$BASH5" "$SWITCH" "$@"
}

config_hash_before="$(shasum -a 256 "$FIXTURE/oc/openclaw.json" | awk '{print $1}')"
set +e
FAKE_ACTIVE_KEY="agent:main:slack:channel:active" run_swap default >"$FIXTURE/active.out" 2>&1
rc=$?
set -e
[[ "$rc" -eq 7 ]] || fail "active session reset should exit 7, got $rc"
python3 - "$FIXTURE/oc/agents/main/sessions/sessions.json" <<'PY' || fail "idle sessions were not unpinned"
import json, sys
with open(sys.argv[1]) as f: d=json.load(f)
bad=("providerOverride","modelOverride","modelOverrideSource","liveModelSwitchPending")
assert all(not any(k in d[s] for k in bad) for s in ("agent:main:telegram:group:1","agent:main:telegram:group:1:topic:2"))
assert d["agent:main:slack:channel:active"]["liveModelSwitchPending"] is True
PY
ok "gateway reset unpins idle parent/topic and defers active sessions"

run_swap default >"$FIXTURE/reset.out"
python3 - "$FIXTURE/oc/agents/main/sessions/sessions.json" <<'PY' || fail "reset postcondition"
import json, sys
with open(sys.argv[1]) as f: d=json.load(f)
bad=("providerOverride","modelOverride","modelOverrideSource","modelOverrideFallbackOriginProvider","modelOverrideFallbackOriginModel","liveModelSwitchPending")
assert all(not any(k in e for k in bad) for e in d.values())
PY
[[ "$(shasum -a 256 "$FIXTURE/oc/openclaw.json" | awk '{print $1}')" == "$config_hash_before" ]] || fail "default reset changed config"
ok "model:null reset clears pending/override state without changing config"

write_sessions
run_swap sol >"$FIXTURE/default-equivalent.out"
python3 - "$FIXTURE/oc/agents/main/sessions/sessions.json" <<'PY' || fail "default-equivalent target did not unpin"
import json, sys
with open(sys.argv[1]) as f: d=json.load(f)
assert all("modelOverride" not in e and "liveModelSwitchPending" not in e for e in d.values())
PY
ok "configured-primary alias normalizes to null unpin"

write_sessions
run_swap opus >"$FIXTURE/pin.out"
[[ "$(shasum -a 256 "$FIXTURE/oc/openclaw.json" | awk '{print $1}')" == "$config_hash_before" ]] || fail "exact pin changed config without --set-primary"
grep -q 'exact source=user pins disable configured model fallbacks' "$FIXTURE/pin.out" || fail "exact pin warning missing"
python3 - "$FIXTURE/oc/agents/main/sessions/sessions.json" <<'PY' || fail "exact pin fields"
import json, sys
with open(sys.argv[1]) as f: d=json.load(f)
assert all(e.get("model") == "claude-opus-4-8" and e.get("modelOverride") == "claude-opus-4-8" for e in d.values())
assert all(e.get("modelProvider") == "claude-cli" and e.get("providerOverride") == "claude-cli" for e in d.values())
assert all(e.get("modelOverrideSource") == "user" for e in d.values())
PY
ok "non-default exact pin leaves config untouched and warns about fallbacks"

write_sessions
run_swap opus --set-primary >"$FIXTURE/set-primary.out"
python3 - "$FIXTURE/oc/openclaw.json" "$FIXTURE/oc/agents/main/sessions/sessions.json" <<'PY' || fail "explicit primary switch"
import json, sys
with open(sys.argv[1]) as f: c=json.load(f)
with open(sys.argv[2]) as f: d=json.load(f)
assert c["agents"]["defaults"]["model"]["primary"] == "claude-cli/claude-opus-4-8"
assert all("modelOverride" not in e and "liveModelSwitchPending" not in e for e in d.values())
PY
ok "--set-primary changes config explicitly then unpins sessions"

write_sessions
set +e
FAKE_GATEWAY_RUNNING=1 run_swap default --session-mode offline >"$FIXTURE/offline-running.out" 2>&1
rc=$?
set -e
[[ "$rc" -eq 8 ]] || fail "offline reset should refuse running Gateway, got $rc"
FAKE_GATEWAY_RUNNING=0 run_swap default --session-mode offline >"$FIXTURE/offline-stopped.out"
python3 - "$FIXTURE/oc/agents/main/sessions/sessions.json" <<'PY' || fail "offline cleanup"
import json, sys
with open(sys.argv[1]) as f: d=json.load(f)
assert all("liveModelSwitchPending" not in e and "modelOverride" not in e for e in d.values())
PY
ok "offline reset requires stopped Gateway and clears stale pending flags"

echo "1..$pass"
