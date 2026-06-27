---
name: shell-swap
description: >
  Admin tool to mass-switch every OpenClaw session and the default model to ANY
  provider/model. Provider- and model-agnostic. Use when asked to change model,
  switch lanes, set the default model, do a fleet-wide model change, or
  "shell swap".
---

# Shell Swap

Provider/model-**agnostic** mass model switch. Resolves the target against the
**live config alias map** (`agents.defaults.models`) — the single source of
truth — then stamps a consistent `{model, provider}` pair across config + every
agent session store. No hardcoded alias table; works for any model the config
knows about (Anthropic, OpenAI, Venice, xAI, OpenRouter, NVIDIA, Ollama, …).

## Usage

```bash
exec scripts/switch.sh <target> [--agent NAME] [--all-agents] [--crons] [--dry-run]
```

`<target>` may be:
- **alias** — any alias defined in `agents.defaults.models` (e.g. `opus`, `gpt`, `minimax`, `grok-4.3`, `kimi`)
- **provider/model** — a full config key (e.g. `anthropic/claude-opus-4-8`, `venice/grok-4-20`)
- **raw id** — any `provider/model` not yet in the allowlist (agnostic passthrough)

Bare model names (no `/` and not a known alias) are **rejected** — the same
model can map to multiple providers (e.g. `claude-fable-5` → `claude-work`,
`claude-cli`, or `anthropic`), so the provider can't be guessed safely. Pass the
full `provider/model` id instead.

### What it does

1. Updates `agents.defaults.model.primary` in `openclaw.json` to the full id
2. For every agent session store (`agents/*/sessions/sessions.json`):
   - sets `model` and `modelOverride` → the resolved model id
   - sets `modelProvider` and `providerOverride` → the resolved provider
   - sets `modelOverrideSource` → `user`
   - removes stale fallback origin/notice fields
   - clears stale runtime/harness pins (`agentHarnessId`,
     `agentRuntimeOverride`, `liveModelSwitchPending`) on any session whose model
     it switches **out of** a codex lane — otherwise a session pinned to
     `agentHarnessId: "codex"` keeps routing to the dead codex harness and
     deadlocks (the pin only clears on a successful turn that never comes). Pins
     are preserved when switching **into** a codex lane (provider resolves to
     `agentRuntime.id == "codex"`).
   - model and provider are stamped **together**, so they can never diverge
3. Optionally (`--crons`) rewrites `payload.model` in a legacy `cron/jobs.json`
4. Backs up each modified file (`*.bak`) and reports per-store change counts

### What it does NOT touch

- `agents.defaults.models` allowlist (left unchanged — never clobbered)
- `agents.defaults.model.fallbacks` (left as-is)
- Claude Foreman skill (separate billing via Claude CLI)
- Memory files, daily logs, or any workspace content

### Scope

- Default: **every** agent under `agents/` (true fleet-wide switch)
- `--agent NAME`: limit to one agent's session store

### Examples

```bash
# Switch the whole fleet to opus (resolves to claude-cli/claude-opus-4-8)
exec scripts/switch.sh opus

# Any provider, by alias
exec scripts/switch.sh minimax            # -> venice/minimax-m25
exec scripts/switch.sh grok-4.3           # -> openrouter/x-ai/grok-4.3

# Full id, agnostic passthrough
exec scripts/switch.sh anthropic/claude-opus-4-8

# Only the mainelobster agent
exec scripts/switch.sh sonnet --agent mainelobster

# Preview without writing
exec scripts/switch.sh opus --dry-run
```

## Notes

- **Runtime-aware provider:** the stamped provider is the resolved model entry's
  `agentRuntime.id` when set, otherwise the config key's first path segment. So
  `anthropic/claude-opus-4-6` (which runs on the `claude-cli` runtime) correctly
  stamps provider `claude-cli`, not `anthropic`. Model and provider are written
  together, so they cannot diverge.
- **Safety:** all target files are JSON-validated up front (abort-before-write
  if any is malformed), writes are atomic (tmp + rename), and `openclaw.json`
  and every session store are backed up (`*.bak`) before modification.
- **Scope rules:** only direct session-entry fields are rewritten — nested
  `systemPromptReport` / `contextBudgetStatus` / `origin` blocks are left intact.
  Sessions pinned to `auto` are skipped. `modelOverrideSource` is set to `user`
  only on sessions whose model was actually switched (provenance preserved).
- `--agent NAME` is a scoped switch: it touches only that agent's sessions and
  leaves the global config primary unchanged; an unknown agent name aborts with
  no changes. `--agent current` (or `--current-agent`) targets the active agent
  via `OPENCLAW_MCP_AGENT_ID`.
- **Tests:** `bash scripts/test.sh` runs a hermetic regression suite (44 checks)
  covering resolution, agentRuntime provider, the schema-scoped walk, `auto`
  preservation, divergence repair, provenance, scoping, atomicity, backups,
  pre-validation, and dry-run. Run it before changing the script.
- **Restart scope (warm vs cold):** file-surgery edits the on-disk store. A
  **cold** session (a persisted row not currently loaded in the gateway's
  memory) reads the new override when it next hydrates — no restart. A **warm**
  session (held in gateway memory) keeps its in-memory copy and can rewrite the
  file, so a config-primary change or warm-session switch may need a gateway
  restart to take effect. Cold sessions are the easy case; warm sessions are the
  reason a restart is sometimes required.
- **When to prefer the native path instead:** for a single session or a live
  switch with **no restart**, use the gateway-native surfaces — `/model`, the
  model picker, `session_status(model=…)`, or `sessions.patch`. They write the
  same `modelOverrideSource: "user"` override through the gateway, update warm
  in-memory state correctly, and let the gateway resolve/clear the effective
  `agentRuntime` itself (so they don't hit the codex-pin deadlock at all). The
  only thing they **don't** do is set `agents.defaults.model.primary` (the
  default for brand-new sessions) — that's `openclaw models set <provider/model>`
  or a config patch. Live switches apply at the next clean retry / next turn,
  never mid-run. shell-swap's niche is the **bulk** case: rewriting many sessions
  (300+) + the config default in one shot from bash, including when the gateway
  is down — `sessions.patch` has no bash CLI, so this script stays the fleet
  tool.
- `--crons` targets the legacy `cron/jobs.json`; the cron store format has since
  migrated, so cron mutation may be a no-op until updated separately
