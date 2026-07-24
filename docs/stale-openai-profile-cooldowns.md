# Recover stale OpenAI/Codex profile cooldowns

Use this runbook when OpenClaw refuses to try OpenAI/Codex OAuth profiles
because it believes they are rate-limited, but the accounts have already reset
or a direct quota check shows capacity.

This is state recovery, not a quota bypass. Never clear a block that is still
confirmed by the provider.

## Symptom

Typical signs:

- Every OpenAI profile is shown as cooling down.
- OpenClaw skips the provider without making a fresh request.
- The recorded reset time is clearly stale or contradicts a live account
  check.
- A newly reset profile works outside OpenClaw but remains blocked inside it.

OpenClaw persists runtime auth health separately from credentials. In current
database-first releases, the relevant state is the `primary` row in:

```text
~/.openclaw/agents/<agent-id>/agent/openclaw-agent.sqlite
```

The row's `state_json` contains `usageStats`, keyed by auth profile ID.
Fields such as `blockedUntil`, `blockedReason`, and failure counters can prevent
selection before a provider request is attempted.

## Safety rules

1. Confirm the provider reset first. Prefer a live per-profile quota or
   authenticated smoke check over cached status output.
2. Stop if the SQLite schema does not match this runbook.
3. Back up the database before writing.
4. Change only the affected `usageStats` entries.
5. Do not modify credentials, tokens, auth order, or unrelated providers.
6. Do not restart the gateway unless verification shows stale in-memory state.

## 1. Locate and inspect the state

Set the agent explicitly:

```bash
AGENT_ID=main
DB="$HOME/.openclaw/agents/$AGENT_ID/agent/openclaw-agent.sqlite"
sqlite3 "$DB" '.schema auth_profile_state'
```

Expected columns:

```text
state_key
state_json
updated_at
```

List blocked OpenAI entries without printing credentials:

```bash
sqlite3 "$DB" "
SELECT
  entry.key AS profile_id,
  json_extract(entry.value, '$.blockedUntil') AS blocked_until,
  json_extract(entry.value, '$.blockedReason') AS blocked_reason,
  json_extract(entry.value, '$.errorCount') AS error_count
FROM auth_profile_state AS state,
     json_each(json_extract(state.state_json, '$.usageStats')) AS entry
WHERE state.state_key = 'primary'
  AND entry.key LIKE 'openai:%'
  AND (
    json_extract(entry.value, '$.blockedUntil') IS NOT NULL OR
    json_extract(entry.value, '$.disabledUntil') IS NOT NULL OR
    json_extract(entry.value, '$.errorCount') IS NOT NULL
  );
"
```

If the query fails, inspect the installed OpenClaw version and schema instead
of guessing.

## 2. Back up the database

Use SQLite's online backup command so the copy is consistent:

```bash
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="${DB%.sqlite}.pre-openai-unblock-$STAMP.sqlite.bak"
sqlite3 "$DB" ".backup '$BACKUP'"
test -s "$BACKUP"
```

Keep the printed backup path in the handoff or incident record.

## 3. Clear only confirmed-stale markers

The safest approach is to name the exact profile IDs confirmed healthy. Replace
the examples below; do not use a broad provider-wide update unless every
profile was independently checked.

```bash
PROFILE_IDS='[
  "openai:example-one",
  "openai:example-two"
]'

sqlite3 "$DB" "BEGIN IMMEDIATE;
UPDATE auth_profile_state
SET
  state_json = (
    SELECT json_set(
      auth_profile_state.state_json,
      '$.usageStats',
      json_group_object(
        entry.key,
        CASE
          WHEN entry.key IN (
            SELECT value FROM json_each('$PROFILE_IDS')
          )
          THEN json_remove(
            entry.value,
            '$.blockedUntil',
            '$.blockedReason',
            '$.blockedSource',
            '$.disabledUntil',
            '$.disabledReason',
            '$.cooldownReason',
            '$.cooldownModel',
            '$.failureCounts',
            '$.errorCount',
            '$.lastFailureAt'
          )
          ELSE json(entry.value)
        END
      )
    )
    FROM json_each(
      json_extract(auth_profile_state.state_json, '$.usageStats')
    ) AS entry
  ),
  updated_at = CAST(strftime('%s', 'now') AS INTEGER) * 1000
WHERE state_key = 'primary';
COMMIT;"
```

Immediately run:

```bash
sqlite3 "$DB" 'PRAGMA integrity_check;'
```

Expected result: `ok`.

If the write or integrity check fails, stop and restore the backup rather than
trying additional mutations.

## 4. Verify

Run all three checks:

```bash
openclaw models status
openclaw models auth list
```

Then run one minimal model turn through OpenClaw using an affected profile. The
important proof is that OpenClaw attempts the provider again; status text alone
is not sufficient.

Re-run the inspection query from step 1. Confirm:

- stale block fields are absent only on the selected profiles;
- unrelated profiles are unchanged;
- the live request either succeeds or records a new, current provider result.

If a fresh request returns a real usage-limit response, leave the newly written
block intact. The provider is still limited.

## Gateway reload decision

A restart is usually unnecessary because the next turn reloads current auth
state. Consider a gateway reload only when:

- disk inspection is clean;
- the CLI status is clean;
- OpenClaw still skips the provider without a request; and
- logs prove a warm process is retaining the old block.

Follow the deployment's normal restart-approval policy. Never restart a shared
gateway casually during incident recovery.

## Restore

If recovery changed the wrong state, stop the gateway according to local
operating policy, preserve the bad database for diagnosis, and restore the
verified backup:

```bash
cp "$BACKUP" "$DB"
sqlite3 "$DB" 'PRAGMA integrity_check;'
```

Then start the gateway and repeat the read-only checks.

## Handoff checklist

- [ ] Provider reset independently confirmed
- [ ] Exact agent database and schema verified
- [ ] Consistent SQLite backup created
- [ ] Exact affected profile IDs recorded
- [ ] Only stale health markers removed
- [ ] Integrity check returned `ok`
- [ ] OpenClaw attempted a fresh provider request
- [ ] Restart avoided unless evidence required it
