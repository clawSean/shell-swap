---
name: shell-swap
description: "Temporarily switch OpenClaw sessions across models, providers, auth profiles, thinking, fast mode, or runtimes without a restart; persistent defaults require an explicit flag."
---

# Shell Swap

Make **right-now session changes** through the live Gateway. Ordinary runs do
not edit `openclaw.json`, do not touch cron payloads, and do not restart the
Gateway. Persistent default-model mutation is opt-in with `--set-default`.

## Usage

```bash
exec scripts/switch.sh <alias|provider/model|default> [options]
exec scripts/switch.sh --profile <id|default> [options]
exec scripts/switch.sh --think <level|default> --fast <on|off|auto|default> [options]
```

Core options:

- `--profile ID` pins the selected account with the model; `default` clears the
  account pin while preserving each session's observed model.
- `--provider ID` limits a profile-only operation. It is required when
  `--profile default` is used without a model, preventing unrelated pins from
  being cleared. A qualified profile such as `openai:...` infers its provider.
- `--think LEVEL` sets thinking; `default` clears the session override.
- `--fast on|off|auto|default` sets or clears fast mode.
- `--runtime ID|default` selects or clears an explicit runtime and requires a
  model target.
- `--agent NAME` scopes one agent. The default is `current`, resolved from the
  OpenClaw agent environment.
- `--all-agents` explicitly selects every configured agent.
- `--include-workloads` adds cron, subagent, probe, and other non-chat sessions.
  Default scope is human chat surfaces plus the agent main chat.
- `--dry-run --json` produces the exact target and batch receipt without writes.
- `--set-default` additionally changes `agents.defaults.model.primary`. This is
  the only ordinary flag that mutates configuration.

Examples:

```bash
# Current agent's chats only; temporary and restart-free
exec scripts/switch.sh openai/gpt-5.6-sol --profile openai:pearson@example.com --think high --fast off

# Change account only while preserving each chat's current model
exec scripts/switch.sh --profile openai:pearson@example.com --agent <your-agent>

# Unpin accounts so configured provider order wins
exec scripts/switch.sh --profile default --provider openai --agent <your-agent>

# Clear model, thinking, and fast overrides
exec scripts/switch.sh default --think default --fast default

# Preview an explicit persistent default change
exec scripts/switch.sh gpt --set-default --dry-run --json
```

## Operating procedure

1. Run `--dry-run --json`; confirm agents, session count, batch count, and
   `includeWorkloads` before applying.
2. Apply the same command without `--dry-run`. The script inventories sessions
   through `openclaw sessions`, groups profile-only changes by observed model,
   and calls Gateway `sessions.patchMany` in batches of at most 100.
3. Require `failed: []`, `succeeded == sessionCount`, and
   `restartPerformed: false` in the receipt.
4. Verify the current chat plus one representative chat per populated surface.
   A running turn is not changed mid-flight; the new route applies on its next
   model call.

## Contracts

- Gateway derives provider/runtime/model fields from the canonical model
  selector. Do not directly stamp `modelProvider`, `providerOverride`, legacy
  JSON stores, or SQLite rows.
- `provider/model@profile` is the canonical account-qualified selector. Gateway
  validates model availability, profile compatibility, thinking levels,
  runtime ownership, and optimistic session identity guards.
- Profile-only changes preserve each row's effective model. They intentionally
  create an explicit selection for that same model while adding or removing the
  account pin.
- The default run excludes non-chat workloads. Use `--include-workloads` only
  when the request explicitly includes them.
- A partial batch failure is a failed run, not success. The receipt lists exact
  failures; rerun only after reconciling them.
- `--set-default` changes only `agents.defaults.model.primary`; auth order,
  fallbacks, allowlists, agent defaults, and cron payloads remain untouched.

## Verification

Run before publishing:

```bash
bash scripts/test.sh
OPENCLAW_MCP_AGENT_ID=<your-agent> exec scripts/switch.sh openai/gpt-5.6-sol --profile default --dry-run --json
```

The first command is hermetic. The second is a read-only live inventory; it
must report `configChanged: false` and `restartPerformed: false`.
