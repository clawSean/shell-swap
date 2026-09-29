#!/usr/bin/env python3
"""Temporary, Gateway-native OpenClaw session routing changes."""
from __future__ import annotations
import argparse, json, os, re, subprocess, sys
from collections import defaultdict
from pathlib import Path
from typing import Any

CHAT_KEY = re.compile(r"^agent:[^:]+:(?:telegram:|imessage:|sms:|rcs:|bluebubbles:|portal(?:-|:)|voice:|main$)")
THINK_LEVELS = {"off", "minimal", "low", "medium", "high", "xhigh", "adaptive", "max", "ultra", "default"}
FAST_MODES = {"on", "off", "auto", "default"}

class SwapError(RuntimeError): pass

def parser():
    p = argparse.ArgumentParser(description="Patch live OpenClaw sessions without changing defaults or restarting the Gateway.")
    p.add_argument("target", nargs="?", help="configured alias, provider/model, or 'default'")
    p.add_argument("--profile", help="auth profile id, or 'default' to clear the session profile pin")
    p.add_argument("--provider", help="limit profile-only changes to this effective provider")
    p.add_argument("--think", choices=sorted(THINK_LEVELS))
    p.add_argument("--fast", choices=sorted(FAST_MODES))
    p.add_argument("--runtime", help="explicit agent runtime id, or 'default'")
    scope = p.add_mutually_exclusive_group()
    scope.add_argument("--agent", default="current", help="agent id (default: current)")
    scope.add_argument("--all-agents", action="store_true")
    p.add_argument("--include-workloads", action="store_true", help="include cron, subagent, probe, and other non-chat sessions")
    p.add_argument("--set-default", action="store_true", help="also persist agents.defaults.model.primary")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--json", action="store_true")
    return p

def load_config(path: Path):
    try: return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc: raise SwapError(f"cannot read config {path}: {exc}") from exc

def resolve_target(config, raw):
    if raw is None or raw == "default": return raw
    models = config.get("agents", {}).get("defaults", {}).get("models", {}) or {}
    aliases = {v.get("alias"): k for k, v in models.items() if isinstance(v, dict) and isinstance(v.get("alias"), str)}
    full = aliases.get(raw, raw)
    if "/" not in full: raise SwapError(f"'{raw}' is neither a configured alias nor provider/model")
    return full

def normalize_agent(raw):
    if raw != "current": return raw
    value = os.environ.get("OPENCLAW_MCP_AGENT_ID") or os.environ.get("OPENCLAW_AGENT_ID")
    if not value: raise SwapError("cannot resolve --agent current; pass an explicit agent id")
    return value

def run_json(argv, allow_warnings=False):
    proc = subprocess.run(argv, text=True, capture_output=True)
    if proc.returncode: raise SwapError(f"command failed ({proc.returncode}): {' '.join(argv)}\n{(proc.stderr or proc.stdout).strip()}")
    text = proc.stdout.strip()
    try: return json.loads(text)
    except json.JSONDecodeError:
        if allow_warnings:
            starts = [i for i in (text.find("{"), text.find("[")) if i >= 0]
            if starts:
                try: return json.loads(text[min(starts):])
                except json.JSONDecodeError: pass
        raise SwapError(f"command did not return JSON: {' '.join(argv)}")

def configured_agents(openclaw_dir):
    root = openclaw_dir / "agents"
    return sorted(p.name for p in root.iterdir() if p.is_dir()) if root.is_dir() else []

def list_sessions(openclaw_bin, agent):
    payload = run_json([openclaw_bin, "sessions", "--agent", agent, "--limit", "all", "--json"], True)
    rows = payload.get("sessions", []) if isinstance(payload, dict) else []
    return [r for r in rows if isinstance(r, dict) and isinstance(r.get("key"), str)]

def select_sessions(rows, include_workloads):
    return rows if include_workloads else [r for r in rows if CHAT_KEY.search(r["key"])]

def profile_provider(profile):
    if not profile or profile == "default" or ":" not in profile: return None
    return profile.split(":", 1)[0]

def profile_model_for_row(row, profile):
    provider, model = row.get("modelProvider"), row.get("model")
    if not isinstance(provider, str) or not provider or not isinstance(model, str) or not model:
        raise SwapError(f"cannot preserve model while changing profile for {row.get('key')}")
    base = f"{provider}/{model}"
    return base if profile == "default" else f"{base}@{profile}"

def build_patch(args, model_value):
    patch = {}
    if model_value is not None: patch["model"] = None if model_value == "default" else model_value
    if args.think: patch["thinkingLevel"] = None if args.think == "default" else args.think
    if args.fast: patch["fastMode"] = None if args.fast == "default" else {"on": True, "off": False}.get(args.fast, "auto")
    if args.runtime: patch["agentRuntime"] = None if args.runtime == "default" else args.runtime
    return patch

def chunks(rows, size=100):
    for i in range(0, len(rows), size): yield rows[i:i + size]

def target_ref(row, agent):
    ref = {"key": row["key"], "agentId": row.get("agentId") or agent}
    if isinstance(row.get("sessionId"), str) and row["sessionId"]: ref["expectedSessionId"] = row["sessionId"]
    if isinstance(row.get("lifecycleRevision"), str) and row["lifecycleRevision"]: ref["expectedLifecycleRevision"] = row["lifecycleRevision"]
    return ref

def patch_many(openclaw_bin, refs, patch):
    payload = {"targets": refs, "patch": patch}
    result = run_json([openclaw_bin, "gateway", "call", "sessions.patchMany", "--params", json.dumps(payload, separators=(",", ":")), "--json", "--timeout", "30000"])
    outcomes = result.get("outcomes", result.get("result", {}).get("outcomes", []))
    if not isinstance(outcomes, list): raise SwapError("sessions.patchMany returned no outcomes")
    failures = [out for out in outcomes if not out.get("ok")]
    return len(outcomes) - len(failures), failures

def set_default(openclaw_bin, config, full_id, dry_run):
    if full_id == "default": raise SwapError("--set-default requires an explicit model")
    old = config.get("agents", {}).get("defaults", {}).get("model", {}).get("primary")
    result = {"before": old, "after": full_id, "changed": old != full_id}
    if result["changed"] and not dry_run:
        subprocess.run([openclaw_bin, "config", "set", "agents.defaults.model.primary", json.dumps(full_id), "--strict-json", "--expect-current-json", json.dumps(old)], text=True, check=True)
    return result

def main(argv=None):
    args = parser().parse_args(argv)
    if not any((args.target, args.profile, args.think, args.fast, args.runtime)): raise SwapError("provide a model, profile, thinking, fast, or runtime change")
    if args.runtime and not args.target: raise SwapError("--runtime requires an explicit model target")
    if args.provider and args.target: raise SwapError("--provider is for profile-only changes; the model target already selects a provider")
    if args.profile == "default" and not args.target and not args.provider: raise SwapError("profile-only unpin requires --provider so unrelated provider pins stay untouched")
    openclaw_dir = Path(os.environ.get("OPENCLAW_DIR", Path.home() / ".openclaw"))
    config_path = Path(os.environ.get("CONFIG", openclaw_dir / "openclaw.json"))
    openclaw_bin = os.environ.get("OPENCLAW_BIN", "openclaw")
    config = load_config(config_path)
    resolved = resolve_target(config, args.target)
    if resolved == "default" and args.profile and args.profile != "default": raise SwapError("a profile cannot be attached while inheriting the default model")
    agents = configured_agents(openclaw_dir) if args.all_agents else [normalize_agent(args.agent)]
    if not agents: raise SwapError("no agents found")
    provider_filter = args.provider or (profile_provider(args.profile) if not resolved else None)
    rows_by_agent = {}
    for agent in agents:
        rows = select_sessions(list_sessions(openclaw_bin, agent), args.include_workloads)
        if provider_filter: rows = [row for row in rows if row.get("modelProvider") == provider_filter]
        rows_by_agent[agent] = rows
    groups = defaultdict(list)
    for agent, rows in rows_by_agent.items():
        for row in rows:
            if resolved is None and args.profile: model_value = profile_model_for_row(row, args.profile)
            elif resolved and resolved != "default" and args.profile and args.profile != "default": model_value = f"{resolved}@{args.profile}"
            else: model_value = resolved
            patch = build_patch(args, model_value)
            groups[(agent, json.dumps(patch, sort_keys=True, separators=(",", ":")))].append(row)
    intended = sum(len(rows) for rows in groups.values())
    receipt = {"mode": "dry-run" if args.dry_run else "apply", "scope": {"agents": agents, "provider": provider_filter, "includeWorkloads": args.include_workloads}, "requested": {"model": resolved, "profile": args.profile, "thinking": args.think, "fast": args.fast, "runtime": args.runtime}, "sessionCount": intended, "batchCount": sum((len(rows) + 99) // 100 for rows in groups.values()), "succeeded": 0, "failed": [], "configChanged": False, "restartPerformed": False}
    if args.dry_run: receipt["succeeded"] = intended
    else:
        for (agent, patch_json), rows in groups.items():
            for batch in chunks(rows):
                ok, failures = patch_many(openclaw_bin, [target_ref(row, agent) for row in batch], json.loads(patch_json))
                receipt["succeeded"] += ok; receipt["failed"].extend(failures)
    if args.set_default:
        if not resolved: raise SwapError("--set-default requires a model target")
        receipt["default"] = set_default(openclaw_bin, config, resolved, args.dry_run)
        receipt["configChanged"] = bool(receipt["default"]["changed"] and not args.dry_run)
    receipt["ok"] = not receipt["failed"] and receipt["succeeded"] == intended
    if args.json: print(json.dumps(receipt, indent=2, sort_keys=True))
    else:
        print(f"[shell-swap] mode={receipt['mode']} sessions={intended} succeeded={receipt['succeeded']} failed={len(receipt['failed'])}")
        print(f"[shell-swap] configChanged={str(receipt['configChanged']).lower()} restartPerformed=false")
        if receipt["failed"]: print(json.dumps(receipt["failed"][:20], indent=2), file=sys.stderr)
    return 0 if receipt["ok"] else 6

if __name__ == "__main__":
    try: raise SystemExit(main())
    except (SwapError, subprocess.CalledProcessError) as exc:
        print(f"[shell-swap] {exc}", file=sys.stderr); raise SystemExit(2)
