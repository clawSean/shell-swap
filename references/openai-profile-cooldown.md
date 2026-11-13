# Bench one OpenAI auth profile

Use this procedure to make one OpenAI auth profile unavailable until a known
deadline without changing credentials, fallback order, or conversation
history. This is an account-availability operation, not a Shell Swap session
selection operation.

The schema below is verified for OpenClaw 2026.11.x shared auth state. Inspect
the live schema before applying it to another version. Stop if the target is not
an exact object under `authProfiles.state.value_json.usageStats`.

## Safety contract

1. Identify the exact target profile, a healthy fallback, the current model,
   and an absolute reset time with an explicit UTC offset.
2. If the current turn uses the target profile, switch this conversation to the
   healthy profile first, finish the turn, and verify the new profile on the
   next inbound turn. Otherwise the target-backed turn can overwrite the new
   cooldown with its final usage update.
3. Back up the live database with SQLite's `.backup` before writing.
4. Edit only `config_machine_state/state_key='authProfiles.state'`. Never read
   or edit `authProfiles.store`; it contains credentials.
5. Preserve auth order, tokens, session history, and every other profile.
6. Perform one foreground transaction. Do not use a daemon, retry loop,
   post-turn helper, or Gateway restart.

## 1. Move the active conversation off the target

Use the direct session control:

```text
session_status(model="openai/<current-model>@openai:<healthy-account>")
```

The equivalent user command is:

```text
/model openai/<current-model>@openai:<healthy-account> -s
```

Finish that turn. On the next inbound turn, require `/status` or
`session_status` to show the healthy profile before continuing.

## 2. Set exact inputs

Use the real profile ID and an ISO-8601 reset timestamp with an explicit `Z` or
numeric UTC offset:

```bash
state_db="$HOME/.openclaw/state/openclaw.sqlite"
profile_id="openai:target@example.com"
reset_at="2026-11-14T00:00:00-08:00"

case "$profile_id" in
  *[!A-Za-z0-9._@:+-]*|'') echo "unsafe profile id" >&2; exit 2 ;;
esac

reset_ms="$(node -e '
  const value = process.argv[1];
  if (!/(?:Z|[+-][0-9]{2}:[0-9]{2})$/.test(value)) process.exit(2);
  const millis = Date.parse(value);
  if (!Number.isFinite(millis)) process.exit(2);
  process.stdout.write(String(millis));
' "$reset_at")"
```

Do not reuse the example profile or timestamp.

## 3. Inspect only the target state

```bash
sqlite3 -readonly -json "$state_db" \
  "SELECT json_extract(
     value_json,
     '$.usageStats.' || json_quote('$profile_id')
   ) AS target
   FROM config_machine_state
   WHERE state_key='authProfiles.state';"
```

Stop if the result is missing, null, duplicated, or not the expected profile.

## 4. Back up the live database

```bash
backup_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_dir="$HOME/.openclaw/backups"
backup_path="$backup_dir/openai-auth-state-$backup_stamp.sqlite"
mkdir -p "$backup_dir"
sqlite3 "$state_db" ".backup '$backup_path'"
sqlite3 "$backup_path" "PRAGMA integrity_check;"

if command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "$backup_path"
else
  sha256sum "$backup_path"
fi
```

Require `ok` from the integrity check before continuing.

## 5. Apply one guarded transaction

This sets a profile-wide cooldown. Removing `cooldownModel` prevents a stale
model scope from narrowing the intended account-wide bench.

```bash
sqlite3 "$state_db" <<SQL
.bail on
.parameter init
.parameter set @profile '$profile_id'
.parameter set @deadline $reset_ms

BEGIN IMMEDIATE;
CREATE TEMP TABLE target_guard(n INTEGER CHECK(n = 1));
INSERT INTO target_guard
SELECT count(*)
FROM config_machine_state
WHERE state_key = 'authProfiles.state'
  AND json_valid(value_json)
  AND json_type(
    value_json,
    '$.usageStats.' || json_quote(@profile)
  ) = 'object';

UPDATE config_machine_state
SET value_json = json_remove(
      json_set(
        value_json,
        '$.usageStats.' || json_quote(@profile) || '.cooldownUntil',
        @deadline,
        '$.usageStats.' || json_quote(@profile) || '.cooldownReason',
        'rate_limit'
      ),
      '$.usageStats.' || json_quote(@profile) || '.cooldownModel',
      '$.usageStats.' || json_quote(@profile) || '.cooldownClassification'
    ),
    updated_at_ms = CAST(unixepoch('subsec') * 1000 AS INTEGER)
WHERE state_key = 'authProfiles.state';
COMMIT;
SQL
```

If the guard fails, SQLite exits without committing the transaction. Diagnose
the profile or schema mismatch; do not weaken the guard.

## 6. Refresh and verify

1. Refresh the Gateway's `models.authStatus` snapshot once with
   `refresh: true`. Do not loop or restart the Gateway.
2. Read back only the target profile's `cooldownUntil` and `cooldownReason`:

   ```bash
   sqlite3 -readonly -json "$state_db" \
     "SELECT
        json_extract(
          value_json,
          '$.usageStats.' || json_quote('$profile_id') || '.cooldownUntil'
        ) AS cooldownUntil,
        json_extract(
          value_json,
          '$.usageStats.' || json_quote('$profile_id') || '.cooldownReason'
        ) AS cooldownReason
      FROM config_machine_state
      WHERE state_key='authProfiles.state';"
   ```

   Require the exact `reset_ms` value and `rate_limit` reason.
3. Run `sqlite3 "$state_db" "PRAGMA integrity_check;"` and require `ok`.
4. Verify that no helper process or scheduled job was created.
5. On a fresh turn, require `/status` or `session_status` to select another
   healthy profile.

A detached `openclaw models status --json` result is supporting evidence only;
the shared-state readback and a fresh routed turn are authoritative.

## Rollback

If no newer legitimate auth-state writes would be lost, restore the SQLite
backup. Otherwise, use the same exact-profile guard and a foreground
transaction to remove only the target profile's cooldown fields. Then repeat
the integrity, auth-status refresh, and fresh-turn routing checks.
