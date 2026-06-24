# Research: The Harness-Pin Gap (and the restart requirement)

*Logged 2026-06-24 after a live incident on JPop's Telegram DM. Status: root cause
confirmed; one mechanism (restart requirement) reasoned, not yet source-proven —
flagged below as an open question.*

## TL;DR

Shell-swap stamps `{model, provider}` across config + every session store, and that
works for normal switches. But it does **not** touch a deeper, third field:
`agentHarnessId` (the execution-harness pin). When a session is pinned to a harness
whose provider is dead/over-quota (our case: `codex`), swapping the model leaves the
session still bound to the dead harness — so it keeps failing even though `status`
shows the new model. Neither shell-swap nor an in-chat `/model` command clears that
pin. The only fix was an out-of-band edit to the session store, which then required a
gateway restart to take effect.

## What actually happened

1. JPop's DM (`agent:mainelobster:telegram:direct:6566057320`) was pinned to
   `agentHarnessId: "codex"`.
2. The Codex provider was over usage limit → every turn errored with "codex out of usage".
3. A fleet shell-swap to `claude-cli/claude-sonnet-4-6` updated the model everywhere.
   `status` reported Sonnet. **The DM still threw the Codex error.**
4. Running the per-session model-setter (programmatic equivalent of `/model`) also did
   not fix it. Checked the store afterward: `agentHarnessId: "codex"` was still present.
5. Fix that worked: cleared the codex harness pins directly in the session store, then
   **restarted the gateway**. DM then resolved to `claude-cli/sonnet` cleanly.

## Why the model swap wasn't enough — the three layers

A session's effective runtime is resolved from (at least) three distinct fields:

| Layer | Field(s) | Written by shell-swap? | Written by `/model`? |
|-------|----------|------------------------|----------------------|
| Model | `model`, `modelOverride` | ✅ yes | ✅ yes |
| Provider | `modelProvider`, `providerOverride` | ✅ yes | ✅ yes |
| **Harness pin** | `agentHarnessId` | ❌ **no** | ❌ **no** |

The harness pin sits *underneath* model/provider. If it points at a dead harness, the
session is stuck regardless of what model you select. This is the entire gap.

## Verified evidence (this incident)

- `grep -c agentHarnessId openclaw.json` → **0**. The pin was never in config; it lived
  per-session in the session store (`sessions/openclaw.sqlite`).
- Diffing live `openclaw.json` against its `.bak` showed exactly **one** line changed:
  `agents.defaults.model.primary` `openai/gpt-5.5` → `claude-cli/claude-sonnet-4-6`.
  i.e. the config swap genuinely did not, and could not, address the pin.
- The pin clearing was done in the session store, not config.

## Why the restart was needed — in-band vs out-of-band

This is the conceptual key, and it generalizes:

- **In-band edit (hot, no restart):** an in-chat `/model` command is processed by the
  *live* session while it's awake handling the message. It rewrites its own state in RAM
  and on disk in one step. The owner of the state makes the edit, so nothing is stale.
- **Out-of-band edit (cold, needs restart):** clearing the pin meant reaching into the
  session store on disk *from outside* the live session. The DM was still holding the old
  pin in the gateway's memory and had no idea the backing file changed. Only a restart
  forces a fresh re-read.

The kicker that makes the cold path unavoidable: the hot path (`/model`) only writes
model/provider, never `agentHarnessId`. There is **no in-chat command that clears a
harness pin**. So the out-of-band store edit was the only available route — and that
route is exactly the one that requires a restart.

> **Open question (not yet source-proven):** the "live session holds state in RAM, an
> out-of-band disk edit is invisible until reload" model is the standard pattern and fits
> every observation here, but I have not traced the exact OpenClaw code path that loads
> and caches session harness bindings at boot. Worth confirming in source before treating
> as gospel. The bundled `dist/` is minified; check upstream source.

## Future exploration / potential skill improvements

1. **Harness-pin awareness in shell-swap.** When the resolved target's runtime differs
   from a session's existing `agentHarnessId`, the swap arguably should clear or re-stamp
   the pin (it's the whole reason a "successful" swap can leave a session broken). Options:
   - Auto-detect runtime change and clear/repair `agentHarnessId` as part of the stamp.
   - Add an opt-in `--clear-harness-pin` (or `--repair-harness`) flag for the
     escape-a-dead-harness case, kept off by default to avoid surprising behavior.
2. **Session-store target discrepancy.** SKILL.md step 2 targets
   `agents/*/sessions/sessions.json`, but the live pin this incident touched was in
   `sessions/openclaw.sqlite`. Confirm which store is authoritative on the current
   OpenClaw build and whether the script is even walking the right file for harness data.
   If the store migrated to sqlite, the script's session walk may be stale.
3. **Restart-required signalling.** Because clearing a pin is inherently out-of-band, the
   skill should explicitly tell the operator a restart is mandatory after a harness-pin
   repair (vs. a normal model swap, where sessions pick up the new model on next turn).
4. **Upstream schema fix candidate.** Consider whether OpenClaw should expose an in-band
   way to clear/override a harness pin (a `/harness` command or `/model` clearing a stale
   pin when the runtime changes), which would remove the need for out-of-band edits +
   restarts entirely. Possible contribution lane.

## Related

- Memory note: `shell-swap-codex-harness-pin-gap` (auto-memory index).
- SKILL.md "What it does" step 2 (model/provider stamping) — the place a pin-aware step
  would slot in.
