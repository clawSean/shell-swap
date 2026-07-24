# shell-swap

Provider/model-**agnostic** mass model switch for OpenClaw. Resolves the target
against the live config alias map and stamps a consistent `{model, provider}`
pair across config + every agent session store in one command.

## Included

• `SKILL.md` — OpenClaw skill definition
• `scripts/switch.sh` — the switch script
• `docs/stale-openai-profile-cooldowns.md` — recovery runbook for stale
  OpenAI/Codex profile blocks

## Usage

```bash
exec scripts/switch.sh <target> [--agent NAME] [--all-agents] [--crons] [--dry-run]
exec scripts/switch.sh --think LEVEL [--fast MODE] [--agent NAME] [--dry-run]
exec scripts/switch.sh --fast MODE [--agent NAME] [--dry-run]
```

`<target>` is resolved against `agents.defaults.models` in the live config:

• **alias** — any configured alias (`opus`, `gpt`, `minimax`, `grok-4.3`, `kimi`, …)
• **provider/model** — full key (`anthropic/claude-opus-4-8`, `venice/grok-4-20`)
• **raw id** — any `provider/model` not yet in the allowlist (passthrough)

Bare model names (no `/`, not a known alias) are rejected — the same model can
map to multiple providers, so the provider can't be guessed.

```bash
exec scripts/switch.sh opus --dry-run
exec scripts/switch.sh anthropic/claude-opus-4-8
exec scripts/switch.sh minimax --agent <your-agent>
exec scripts/switch.sh --think high
exec scripts/switch.sh --fast auto
exec scripts/switch.sh --think default --fast default
```

## What it updates

1. `~/.openclaw/openclaw.json` — `agents.defaults.model.primary` when a model
   target is provided and the run is not scoped to one agent (allowlist +
   fallbacks left untouched)
2. `~/.openclaw/agents/*/sessions/sessions.json` — `model`, `modelOverride`,
   `modelProvider`, `providerOverride`, `modelOverrideSource`; strips stale
   fallback fields. Model + provider are set together so they never diverge.
3. Session overrides — `--think` / `--fast` patch warm sessions through Gateway
   by default, or edit `sessions.json` directly with `--session-mode offline`
4. (opt-in `--crons`) legacy `~/.openclaw/cron/jobs.json` — `payload.model`

Backups are written before modification (`*.bak`).
