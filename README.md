# shell-swap

Provider/model-**agnostic** mass model switch for OpenClaw. It can safely
unpin sessions to the configured default through Gateway (no restart), or
hard-pin an explicit non-default model for maintenance workflows.

## Included

• `SKILL.md` — OpenClaw skill definition
• `scripts/switch.sh` — the switch script
• `scripts/test.sh` — hermetic regression tests

## Usage

```bash
exec scripts/switch.sh <target> [--set-primary] [--agent NAME] [--all-agents] [--crons] [--dry-run]
exec scripts/switch.sh --think LEVEL [--fast MODE] [--agent NAME] [--dry-run]
exec scripts/switch.sh --fast MODE [--agent NAME] [--dry-run]
```

`<target>` is resolved against `agents.defaults.models` in the live config:

• **default/reset/unpin** — clear model overrides so config primary + fallbacks win
• **alias** — any configured alias (`opus`, `gpt`, `minimax`, `grok-4.3`, `kimi`, …)
• **provider/model** — full key (`anthropic/claude-opus-4-8`, `venice/grok-4-20`)
• **raw id** — any `provider/model` not yet in the allowlist (passthrough)

Bare model names (no `/`, not a known alias) are rejected — the same model can
map to multiple providers, so the provider can't be guessed.

```bash
exec scripts/switch.sh opus --dry-run
exec scripts/switch.sh default
exec scripts/switch.sh sol # unpins when sol is already the configured primary
exec scripts/switch.sh opus --set-primary # explicit config change, then unpin
exec scripts/switch.sh anthropic/claude-opus-4-8
exec scripts/switch.sh minimax --agent <your-agent>
exec scripts/switch.sh --think high
exec scripts/switch.sh --fast auto
exec scripts/switch.sh --think default --fast default
```

## What it updates

1. `~/.openclaw/openclaw.json` — only with explicit `--set-primary`; the
   default command never mutates config
2. Default/reset uses Gateway `sessions.patch {model:null}` to remove model
   overrides and stale `liveModelSwitchPending` state. Active sessions are
   deferred and must be retried once idle. No Gateway restart is needed.
3. Exact non-default targets update `model`, `modelOverride`,
   `modelProvider`, `providerOverride`, `modelOverrideSource`; strips stale
   fallback fields. These are `source=user` hard pins and disable configured
   model fallback for those sessions.
4. Session overrides — `--think` / `--fast` patch warm sessions through Gateway
   by default, or edit `sessions.json` directly with `--session-mode offline`
5. (opt-in `--crons`) legacy `~/.openclaw/cron/jobs.json` — `payload.model`

Backups are written before modification (`*.bak`).

Run tests with `/opt/homebrew/bin/bash scripts/test.sh` on macOS.
