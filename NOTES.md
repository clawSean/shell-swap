# Shell Swap Notes

- 2026-05-03: Skill is script-backed (`scripts/switch.sh`), not just instructions. It uses `set -euo pipefail`, creates `.bak` backups, and supports `--dry-run`.
- Dry-run before applying broad swaps. Current script behavior for `sessions.json` only rewrites model values that look like `claude-*`; broad non-Claude fleet swaps need careful verification before trusting results.
- 2026-06-24: **Harness-pin gap** — swap stamps `{model, provider}` but NOT `agentHarnessId`. A session pinned to a dead harness (e.g. `codex` over-quota) stays broken after a "successful" swap. Clearing the pin is out-of-band (session store edit) and needs a gateway restart. Full writeup + future-exploration ideas: `RESEARCH-harness-pin-gap.md`.
- 2026-09-29: Replaced direct config/session-store rewriting with Gateway-native
  `sessions.patchMany`. Default scope is the current agent's human chats;
  profile-only runs preserve observed models; persistent default mutation is
  explicit through `--set-default`. The POSIX wrapper + Python engine fixes the
  macOS Bash 3.2 parse failure. Native model selection now owns stale harness
  cleanup and validation, so ordinary runs require no restart.
