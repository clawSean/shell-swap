# Baseline Test Audit — shell-swap

## What exists

`scripts/test.sh` — 71 offline assertions covering:

1. **SKILL.md structure** — file exists, has YAML frontmatter with `name` and `description`
2. **Script validity** — `switch.sh` exists and passes `bash -n` syntax check
3. **Model resolution** — configured aliases, full ids, raw provider/model ids, multi-segment providers, and provider/model ambiguity rejection
4. **Session rewrite correctness** — model/provider overrides are stamped together, stale fallback fields are removed, `auto` sessions are preserved, nested report/origin objects are untouched, and codex harness pins are cleared when switching out of codex lanes
5. **Scoping** — `--agent`, `--agent current`, unknown agent rejection, and fleet-primary updates
6. **Cron mutation** — legacy cron updates are opt-in and malformed stores abort before writes
7. **Safety** — backups, atomic writes, malformed-store preflight, dry-run no-write behavior, and missing-config failures
8. **Session override modes** — `--think`, `--fast`, `default` clearing, `gateway` dry-run, `offline` edits, and combined model+override runs

## How to run

```bash
bash scripts/test.sh
```

## Last run

- **Date:** 2026-05-09
- **Result:** 71/71 passed, 0 failed
- **Environment:** Linux, bash, python3

## Remaining gaps

- No live Gateway `sessions.patch` call in the hermetic suite; gateway mode is dry-run tested and offline mode is fully file-tested
- No full end-to-end slash-command test from Telegram/chat command to script execution
- No cron-store migration support beyond the legacy `cron/jobs.json` path
