# Shell Swap Notes

- 2026-05-03: Skill is script-backed (`scripts/switch.sh`), not just instructions. It uses `set -euo pipefail`, creates `.bak` backups, and supports `--dry-run`.
- Dry-run before applying broad swaps. Current script behavior for `sessions.json` only rewrites model values that look like `claude-*`; broad non-Claude fleet swaps need careful verification before trusting results.
