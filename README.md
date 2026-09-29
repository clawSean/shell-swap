# shell-swap

Restart-free, Gateway-native bulk routing for OpenClaw sessions.

```bash
scripts/switch.sh openai/gpt-5.6-sol \
  --profile openai:pearson@example.com \
  --think high --fast off --agent <your-agent> --dry-run --json
```

The normal path changes live session overrides only. It supports model/provider,
auth profile, thinking, fast mode, runtime, scoped agents, chat-only filtering,
dry-run receipts, and clearing overrides. It calls `sessions.patchMany` in
100-session batches and never requires a Gateway restart.

Persistent default-model mutation exists only behind `--set-default`.
See `SKILL.md` for the full contract and examples.
