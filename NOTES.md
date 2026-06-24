# Shell Swap Notes

- 2026-05-03: Skill is script-backed (`scripts/switch.sh`), not just instructions. It uses `set -euo pipefail`, creates `.bak` backups, and supports `--dry-run`.
- Dry-run before applying broad swaps. Current script behavior for `sessions.json` only rewrites model values that look like `claude-*`; broad non-Claude fleet swaps need careful verification before trusting results.
- 2026-06-24: **Harness-pin gap** — swap stamps `{model, provider}` but NOT `agentHarnessId`. A session pinned to a dead harness (e.g. `codex` over-quota) stays broken after a "successful" swap. Clearing the pin is out-of-band (session store edit) and needs a gateway restart. Full writeup + future-exploration ideas: `RESEARCH-harness-pin-gap.md`.
