#!/usr/bin/env bash
# Hermetic regression suite for shell-swap/scripts/switch.sh.
#
# Builds a synthetic OpenClaw dir (config + multi-agent session stores) in a
# temp dir, runs switch.sh against it via OPENCLAW_DIR, and asserts behaviour.
# No dependency on the live ~/.openclaw. Run: bash scripts/test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWITCH="$SCRIPT_DIR/switch.sh"
PASS=0
FAIL=0

red() { printf '\033[31m%s\033[0m\n' "$1"; }
grn() { printf '\033[32m%s\033[0m\n' "$1"; }

ok()   { PASS=$((PASS+1)); grn "  ok   - $1"; }
bad()  { FAIL=$((FAIL+1)); red "  FAIL - $1"; [[ -n "${2:-}" ]] && echo "         $2"; }

# assert_eq <desc> <expected> <actual>
assert_eq() { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "expected [$2] got [$3]"; }
# assert_contains <desc> <needle> <haystack>
assert_contains() { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "missing [$2] in output"; }
# assert_exit <desc> <expected_code> <actual_code>
assert_exit() { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "expected exit $2 got $3"; }

# jq-free JSON probe via python
jget() { python3 -c "import json,sys; d=json.load(open(sys.argv[1]))
exec('v=d'+sys.argv[2]); print(v)" "$1" "$2" 2>/dev/null; }

make_fixture() {
  local root="$1"
  mkdir -p "$root/agents/mainelobster/sessions" \
           "$root/agents/clawdia/sessions" \
           "$root/agents/empty/sessions"
  cat > "$root/openclaw.json" <<'JSON'
{
  "agents": {
    "defaults": {
      "model": { "primary": "openai/gpt-5.5", "fallbacks": [] },
      "models": {
        "openai/gpt-5.5": { "alias": "gpt" },
        "claude-cli/claude-opus-4-8": { "alias": "opus", "agentRuntime": { "id": "claude-cli" } },
        "anthropic/claude-opus-4-6": { "alias": "opus-4.6", "agentRuntime": { "id": "claude-cli" } },
        "anthropic/claude-opus-4-8": { "alias": "opus-8", "agentRuntime": { "id": "openclaw" } },
        "venice/minimax-m25": { "alias": "minimax" },
        "nvidia/moonshotai/kimi-k2.5": { "alias": "kimi" },
        "xai/grok-4.3": { "alias": "Grok" },
        "ollama/phi4-mini": {}
      }
    }
  }
}
JSON

  # mainelobster: a mix of states the rewrite must handle correctly.
  cat > "$root/agents/mainelobster/sessions/sessions.json" <<'JSON'
{
  "agent:mainelobster:s1": {
    "model": "gpt-5.5", "modelProvider": "openai", "modelOverrideSource": "auto",
    "systemPromptReport": { "model": "gpt-5.5", "provider": "openai" },
    "contextBudgetStatus": { "model": "gpt-5.5" },
    "origin": { "provider": "telegram" }
  },
  "agent:mainelobster:s2_diverged": {
    "model": "claude-opus-4-8", "modelProvider": "anthropic",
    "modelOverride": "claude-opus-4-8", "providerOverride": "anthropic",
    "modelOverrideSource": "user"
  },
  "agent:mainelobster:s3_auto": {
    "model": "auto", "modelProvider": "nadirclaw"
  },
  "agent:mainelobster:s4_fallback": {
    "model": "grok-4.3", "modelProvider": "xai", "modelOverrideSource": "auto",
    "modelOverrideFallbackOriginProvider": "anthropic",
    "modelOverrideFallbackOriginModel": "claude-opus-4-6",
    "modelOverrideFallbackNotice": "fell back due to billing"
  },
  "agent:mainelobster:s5_ontarget": {
    "model": "claude-opus-4-8", "modelProvider": "claude-cli", "modelOverrideSource": "user"
  }
}
JSON

  cat > "$root/agents/clawdia/sessions/sessions.json" <<'JSON'
{
  "agent:clawdia:s1": { "model": "gpt-5.5", "modelProvider": "openai", "modelOverrideSource": "auto" }
}
JSON

  echo '{}' > "$root/agents/empty/sessions/sessions.json"
}

run() { OPENCLAW_DIR="$ROOT" bash "$SWITCH" "$@" 2>&1; }

# ---------------------------------------------------------------------------
echo "== resolution =="
ROOT="$(mktemp -d)"; make_fixture "$ROOT"

out="$(run opus --dry-run)"
assert_contains "alias opus -> full id"        "Resolved full id  : claude-cli/claude-opus-4-8" "$out"
assert_contains "alias opus -> model"          "Session model     : claude-opus-4-8" "$out"
assert_contains "alias opus -> provider"       "Session provider  : claude-cli" "$out"

out="$(run opus-4.6 --dry-run)"
assert_contains "agentRuntime: opus-4.6 provider is claude-cli not anthropic" "Session provider  : claude-cli" "$out"

out="$(run opus-8 --dry-run)"
assert_contains "agentRuntime: opus-8 provider is openclaw" "Session provider  : openclaw" "$out"

out="$(run xai/grok-4.3 --dry-run)"
assert_contains "full id passthrough provider" "Session provider  : xai" "$out"
assert_contains "full id passthrough model"    "Session model     : grok-4.3" "$out"

out="$(run kimi --dry-run)"
assert_contains "multi-slash provider" "Session provider  : nvidia" "$out"
assert_contains "multi-slash model"    "Session model     : moonshotai/kimi-k2.5" "$out"

out="$(run minimax --dry-run)"
assert_contains "cross-provider alias (venice)" "Session provider  : venice" "$out"

run gpt-5.5 --dry-run >/dev/null 2>&1; assert_exit "bare model rejected" 3 "$?"
run anything/at-all-novel --dry-run >/dev/null 2>&1; assert_exit "novel provider/model passes (exit 0)" 0 "$?"
rm -rf "$ROOT"

# ---------------------------------------------------------------------------
echo "== session rewrite correctness (real run) =="
ROOT="$(mktemp -d)"; make_fixture "$ROOT"
S="$ROOT/agents/mainelobster/sessions/sessions.json"
run opus >/dev/null

assert_eq "s1 model switched"                "claude-opus-4-8" "$(jget "$S" "['agent:mainelobster:s1']['model']")"
assert_eq "s1 provider stamped to runtime"   "claude-cli"      "$(jget "$S" "['agent:mainelobster:s1']['modelProvider']")"
assert_eq "s1 source flipped (model changed)" "user"           "$(jget "$S" "['agent:mainelobster:s1']['modelOverrideSource']")"
assert_eq "nested systemPromptReport.model UNTOUCHED" "gpt-5.5" "$(jget "$S" "['agent:mainelobster:s1']['systemPromptReport']['model']")"
assert_eq "nested contextBudgetStatus.model UNTOUCHED" "gpt-5.5" "$(jget "$S" "['agent:mainelobster:s1']['contextBudgetStatus']['model']")"
assert_eq "nested origin.provider UNTOUCHED"  "telegram"        "$(jget "$S" "['agent:mainelobster:s1']['origin']['provider']")"

assert_eq "s2 diverged provider REPAIRED"     "claude-cli"      "$(jget "$S" "['agent:mainelobster:s2_diverged']['modelProvider']")"
assert_eq "s2 diverged providerOverride REPAIRED" "claude-cli"  "$(jget "$S" "['agent:mainelobster:s2_diverged']['providerOverride']")"

assert_eq "s3 auto model PRESERVED"           "auto"            "$(jget "$S" "['agent:mainelobster:s3_auto']['model']")"
assert_eq "s3 auto provider PRESERVED"        "nadirclaw"       "$(jget "$S" "['agent:mainelobster:s3_auto']['modelProvider']")"

assert_eq "s4 stale fallback origin removed"  "None"            "$(jget "$S" ".get('agent:mainelobster:s4_fallback',{}).get('modelOverrideFallbackOriginProvider','None')" 2>/dev/null || echo None)"

# s5 was already exactly on target -> source must NOT be touched (provenance)
assert_eq "s5 on-target source preserved"     "user"            "$(jget "$S" "['agent:mainelobster:s5_ontarget']['modelOverrideSource']")"
rm -rf "$ROOT"

# verify stale-field removal more directly
ROOT="$(mktemp -d)"; make_fixture "$ROOT"; S="$ROOT/agents/mainelobster/sessions/sessions.json"
run opus >/dev/null
hasstale="$(python3 -c "import json;d=json.load(open('$S'));s=d['agent:mainelobster:s4_fallback'];print(any(k.startswith('modelOverrideFallback') for k in s))")"
assert_eq "s4 all stale fallback fields gone" "False" "$hasstale"
rm -rf "$ROOT"

# ---------------------------------------------------------------------------
echo "== scoping =="
ROOT="$(mktemp -d)"; make_fixture "$ROOT"
run sonnet-nonexistent-alias --agent mainelobster --dry-run >/dev/null 2>&1 || true
run opus --agent mainelobster >/dev/null
assert_eq "scoped run leaves config primary" "openai/gpt-5.5" "$(jget "$ROOT/openclaw.json" "['agents']['defaults']['model']['primary']")"
assert_eq "scoped run switched target agent" "claude-opus-4-8" "$(jget "$ROOT/agents/mainelobster/sessions/sessions.json" "['agent:mainelobster:s1']['model']")"
assert_eq "scoped run left OTHER agent alone" "gpt-5.5" "$(jget "$ROOT/agents/clawdia/sessions/sessions.json" "['agent:clawdia:s1']['model']")"
rm -rf "$ROOT"

ROOT="$(mktemp -d)"; make_fixture "$ROOT"
run opus --agent ghost >/dev/null 2>&1; assert_exit "unknown agent hard-errors" 4 "$?"
assert_eq "unknown agent made NO config change" "openai/gpt-5.5" "$(jget "$ROOT/openclaw.json" "['agents']['defaults']['model']['primary']")"
rm -rf "$ROOT"

ROOT="$(mktemp -d)"; make_fixture "$ROOT"
out="$(OPENCLAW_DIR="$ROOT" OPENCLAW_MCP_AGENT_ID=mainelobster bash "$SWITCH" opus --agent current --dry-run 2>&1)"
assert_contains "--agent current resolves env agent" "Agent scope       : mainelobster" "$out"
rm -rf "$ROOT"

echo "== fleet run updates primary =="
ROOT="$(mktemp -d)"; make_fixture "$ROOT"
run opus >/dev/null
assert_eq "fleet run updates config primary" "claude-cli/claude-opus-4-8" "$(jget "$ROOT/openclaw.json" "['agents']['defaults']['model']['primary']")"
assert_eq "allowlist NOT clobbered (still 8 entries)" "8" "$(jget "$ROOT/openclaw.json" "['agents']['defaults']['models'].__len__()")"
rm -rf "$ROOT"

# ---------------------------------------------------------------------------
echo "== safety: backups, atomicity, pre-validation, dry-run =="
ROOT="$(mktemp -d)"; make_fixture "$ROOT"
run opus >/dev/null
[[ -f "$ROOT/openclaw.json.bak" ]] && ok "config backup created" || bad "config backup created"
[[ -f "$ROOT/agents/mainelobster/sessions/sessions.json.bak" ]] && ok "sessions backup created" || bad "sessions backup created"
leftover="$(find "$ROOT" -name '.shellswap-*' | wc -l | tr -d ' ')"
assert_eq "no leftover tmp files (atomic)" "0" "$leftover"
python3 -c "import json;json.load(open('$ROOT/agents/mainelobster/sessions/sessions.json'))" 2>/dev/null && ok "result is valid JSON" || bad "result is valid JSON"
rm -rf "$ROOT"

# pre-validation: a malformed store aborts before ANY write
ROOT="$(mktemp -d)"; make_fixture "$ROOT"
echo '{ this is not json' > "$ROOT/agents/clawdia/sessions/sessions.json"
run opus >/dev/null 2>&1; assert_exit "malformed store aborts (exit 5)" 5 "$?"
assert_eq "abort left config primary unchanged" "openai/gpt-5.5" "$(jget "$ROOT/openclaw.json" "['agents']['defaults']['model']['primary']")"
assert_eq "abort left good store unchanged" "gpt-5.5" "$(jget "$ROOT/agents/mainelobster/sessions/sessions.json" "['agent:mainelobster:s1']['model']")"
rm -rf "$ROOT"

# dry-run writes nothing
ROOT="$(mktemp -d)"; make_fixture "$ROOT"
before="$(md5sum "$ROOT/openclaw.json" "$ROOT/agents/mainelobster/sessions/sessions.json")"
run opus --dry-run >/dev/null
after="$(md5sum "$ROOT/openclaw.json" "$ROOT/agents/mainelobster/sessions/sessions.json")"
assert_eq "dry-run modifies nothing" "$before" "$after"
[[ -f "$ROOT/openclaw.json.bak" ]] && bad "dry-run must not write backups" || ok "dry-run writes no backups"
rm -rf "$ROOT"

# missing config
ROOT="$(mktemp -d)"
run opus --dry-run >/dev/null 2>&1; assert_exit "missing config clean exit 1" 1 "$?"
rm -rf "$ROOT"

# ---------------------------------------------------------------------------
echo ""
echo "== bash -n syntax =="
bash -n "$SWITCH" && ok "switch.sh parses" || bad "switch.sh parses"

echo ""
echo "================================"
echo "  PASS: $PASS   FAIL: $FAIL"
echo "================================"
[[ "$FAIL" -eq 0 ]]
