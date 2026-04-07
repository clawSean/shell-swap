# shell-swap

Mass-switch OpenClaw model settings across config, sessions, and cron jobs in one command.

## Included

• `SKILL.md` — OpenClaw skill definition  
• `scripts/switch.sh` — migration script (`haiku | sonnet | opus | gpt-5.4 | spark | codex`, with `--dry-run`)

## Usage

```bash
exec scripts/switch.sh sonnet --dry-run
exec scripts/switch.sh sonnet
```

## Supported aliases

• `haiku` → `anthropic/claude-haiku-4-5`  
• `sonnet` → `anthropic/claude-sonnet-4-6`  
• `opus` → `anthropic/claude-opus-4-6`  
• `gpt-5.4` → `openai-codex/gpt-5.4`  
• `spark` → `openai-codex/gpt-5.3-codex-spark`  
• `codex` → `openai-codex/gpt-5.3-codex`

## What it updates

1. `~/.openclaw/openclaw.json` default model + allowlist
2. `~/.openclaw/agents/main/sessions/sessions.json` (`model` + `modelOverride`)
3. `~/.openclaw/cron/jobs.json` (`payload.model`)

Backups are written before modification (`*.bak`).
