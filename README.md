# shell-swap

Mass-switch OpenClaw model settings across config, sessions, and cron jobs in one command.

## Included

• `SKILL.md` — OpenClaw skill definition  
• `scripts/switch.sh` — migration script (`haiku | sonnet | opus`, with `--dry-run`)

## Usage

```bash
exec scripts/switch.sh sonnet --dry-run
exec scripts/switch.sh sonnet
```

## What it updates

1. `~/.openclaw/openclaw.json` default model + allowlist
2. `~/.openclaw/agents/main/sessions/sessions.json` (`model` + `modelOverride`)
3. `~/.openclaw/cron/jobs.json` (`payload.model`)

Backups are written before modification (`*.bak`).
