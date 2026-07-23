---
name: shell-swap
description: "Admin tool to safely unpin or mass-switch OpenClaw session models. Config mutation is explicit-only; default/reset uses Gateway model:null so configured fallbacks keep working without a restart."
---

# Shell Swap

Provider/model-**agnostic** model administration. The safe default operation
unpins sessions through Gateway so they inherit the configured primary and its
fallback chain. Exact non-default hard pins remain available, but are explicit
`source=user` selections and therefore disable configured model fallback.

## Usage

```bash
exec scripts/switch.sh <target> [--set-primary|--pin-exact] [--agent NAME] [--all-agents] [--crons] [--dry-run]
exec scripts/switch.sh --think LEVEL [--fast MODE] [--agent NAME] [--dry-run]
exec scripts/switch.sh --fast MODE [--agent NAME] [--dry-run]
```

`<target>` may be:
- **default/reset/unpin** — call Gateway `sessions.patch` with `model:null` so
  sessions inherit config and stale `liveModelSwitchPending` is removed
- **alias** — any alias defined in `agents.defaults.models` (e.g. `opus`, `gpt`, `minimax`, `grok-4.3`, `kimi`)
- **provider/model** — a full config key (e.g. `anthropic/claude-opus-4-8`, `venice/grok-4-20`)
- **raw id** — any `provider/model` not yet in the allowlist (agnostic passthrough)

Bare model names (no `/` and not a known alias) are **rejected** — the same
model can map to multiple providers (e.g. `claude-fable-5` → `claude-work`,
`claude-cli`, or `anthropic`), so the provider can't be guessed safely. Pass the
full `provider/model` id instead.

Session override flags:
- `--think LEVEL` sets or clears direct session `thinkingLevel` overrides.
  Levels: `off|minimal|low|medium|high|xhigh|adaptive|max|default`.
  `default` clears the session override so config/provider defaults win.
- `--fast MODE` sets or clears direct session `fastMode` overrides.
  Modes: `on|off|auto|default`. `default` clears the session override.
- `--set-primary` explicitly changes `agents.defaults.model.primary`. Without
  it, shell-swap does not modify `openclaw.json`.
- `--pin-exact` preserves intentional hard-pin semantics even when the explicit
  target equals the configured primary. It writes `source=user` and therefore
  disables configured fallbacks. It cannot be combined with `--set-primary`.
- `--session-mode gateway|offline` controls how reset / `--think` / `--fast` are
  written. Default is `gateway`, which calls Gateway `sessions.patch` and
  updates warm in-memory sessions without a restart. `offline` edits
  `sessions.json` directly and is for maintenance when Gateway is down.

### What it does

1. Leaves `openclaw.json` unchanged unless `--set-primary` is supplied.
2. For `default`, or a target equal to the configured primary without
   `--pin-exact`, calls Gateway `sessions.patch {model:null}` for every idle
   selected session. This removes model overrides, fallback-origin state, and
   `liveModelSwitchPending` without a restart. Active sessions are deferred;
   rerun once they are idle.
3. For an exact non-default target—or a configured-primary target paired with
   `--pin-exact`—updates every selected session store:
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
4. When `--think` / `--fast` is provided:
   - default `gateway` mode patches every selected session through Gateway
     `sessions.patch` so warm sessions update without restart
   - `offline` mode edits direct session-entry fields in `sessions.json`
   - invalid provider/model combinations are rejected by Gateway in warm-safe
     mode and reported; those sessions are left unchanged
5. Optionally (`--crons`) rewrites `payload.model` in a legacy `cron/jobs.json`
   only for exact pins; reset/unpin does not create cron model pins.
6. Backs up directly modified files (`*.bak`) and reports change counts.

### What it does NOT touch

- `agents.defaults.models` allowlist (left unchanged — never clobbered)
- `agents.defaults.model.fallbacks` (left as-is)
- global/per-agent thinking or fast defaults (`agents.defaults.thinkingDefault`,
  `agents.list[].thinkingDefault`, `agents.list[].fastModeDefault`)
- per-model fast defaults (`agents.defaults.models[*].params.fastMode`)
- Claude Foreman skill (separate billing via Claude CLI)
- Memory files, daily logs, or any workspace content

### Scope

- Default: **every** agent under `agents/` (true fleet-wide switch)
- `--agent NAME`: limit to one agent's session store

### Examples

```bash
# Switch the whole fleet to opus (resolves to claude-cli/claude-opus-4-8)
exec scripts/switch.sh opus

# Safely inherit the configured primary + fallbacks (no restart/config edit)
exec scripts/switch.sh default

# Intentionally pin the configured primary and disable fallbacks
exec scripts/switch.sh sol --pin-exact

# Explicitly change the configured primary, then unpin sessions to inherit it
exec scripts/switch.sh opus --set-primary

# Any provider, by alias
exec scripts/switch.sh minimax            # -> venice/minimax-m25
exec scripts/switch.sh grok-4.3           # -> openrouter/x-ai/grok-4.3

# Full id, agnostic passthrough
exec scripts/switch.sh anthropic/claude-opus-4-8

# Only the <your-agent> agent
exec scripts/switch.sh sonnet --agent <your-agent>

# Preview without writing
exec scripts/switch.sh opus --dry-run

# Set every selected session's thinking override, warm-safe/no restart
exec scripts/switch.sh --think high

# Mode-only run: set fast auto without changing model
exec scripts/switch.sh --fast auto

# Clear direct session overrides so config/provider defaults win
exec scripts/switch.sh --think default --fast default

# Maintenance mode when Gateway is down (direct file edit)
exec scripts/switch.sh --think off --session-mode offline
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
- **Tests:** `/opt/homebrew/bin/bash scripts/test.sh` runs a hermetic regression
  suite covering no-config-by-default behavior, Gateway null-unpin, active-run
  deferral, pending-flag cleanup, same-primary `--pin-exact`, explicit config
  mutation, and offline safety.
- **Thinking compatibility:** Gateway `sessions.patch` validates the selected
  level against the session's effective provider/model profile. For example,
  `--think max` can be rejected on an OpenAI session whose current profile only
  supports `off|minimal|low|medium|high|xhigh`; shell-swap reports that failure
  and leaves that session unchanged. Existing stored unsupported levels may be
  remapped by OpenClaw at runtime, but the warm-safe Gateway path does not force
  invalid values into live sessions.
- **Restart scope (warm vs cold):** Gateway reset via `model:null` updates warm
  state and explicitly deletes pending live-switch state; idle sessions do not
  require a restart. Active sessions are not patched because their later
  snapshot merge could win the race; rerun after they become idle. File-surgery
  edits the on-disk store. A
  **cold** session (a persisted row not currently loaded in the gateway's
  memory) reads the new override when it next hydrates — no restart. A **warm**
  session (held in gateway memory) keeps its in-memory copy and can rewrite the
  file, so a config-primary change or warm-session switch may need a gateway
  restart to take effect. Cold sessions are the easy case; warm sessions are the
  reason a restart is sometimes required.
- **Pending semantics:** a non-null `sessions.patch` can set
  `liveModelSwitchPending` even if the session is idle at patch time, and that
  flag can fire on a later user turn. Shell-swap therefore uses the native
  null-reset path for default-equivalent targets and never manufactures the
  flag online. Offline reset may delete it only while Gateway is stopped.
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
  is down, and using Gateway `sessions.patch` in a loop for warm-safe bulk
  thinking/fast overrides.
- `--crons` targets the legacy `cron/jobs.json`; the cron store format has since
  migrated, so cron mutation may be a no-op until updated separately
