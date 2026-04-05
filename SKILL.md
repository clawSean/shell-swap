---
name: shell-swap
description: >
  Admin tool to mass-switch all OpenClaw sessions and cron jobs to a different
  model. Use when asked to change model, switch to haiku/sonnet/opus, set the
  default model, do a fleet-wide model change, or "shell swap".
---

# Shell Swap

Mass-update the model across all OpenClaw sessions, cron jobs, and config
in one shot.

## Usage

```bash
exec scripts/switch.sh <model_alias>
```

Where `<model_alias>` is one of: `haiku`, `sonnet`, `opus`

### What it does

1. Updates `agents.defaults.model.primary` in `openclaw.json`
2. Updates `agents.defaults.models` allowlist (adds the target model if missing)
3. Rewrites all `model` and `modelOverride` fields in `agents/main/sessions/sessions.json`
4. Rewrites all `payload.model` fields in `cron/jobs.json`
5. Creates a backup of each file before modifying
6. Reports counts of what changed

### What it does NOT touch

- Claude Foreman skill (separate billing via Claude CLI)
- Fallback config (leaves `agents.defaults.model.fallbacks` as-is)
- Historical error messages in cron job state
- Memory files, daily logs, or any workspace content

### Examples

```bash
# Switch everything to haiku (cheapest)
exec scripts/switch.sh haiku

# Switch everything to sonnet
exec scripts/switch.sh sonnet

# Switch everything to opus (expensive — confirm with user first)
exec scripts/switch.sh opus
```

### Dry run

Add `--dry-run` to preview changes without writing:

```bash
exec scripts/switch.sh sonnet --dry-run
```

## Notes

- A gateway restart may be needed for config changes to take effect
- Existing active sessions will pick up the new model on their next turn
- The models allowlist is updated to include only the target model
