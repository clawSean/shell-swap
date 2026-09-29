import importlib.util, json, os, tempfile, unittest
from pathlib import Path
HERE = Path(__file__).parent
spec = importlib.util.spec_from_file_location("shell_swap", HERE / "switch.py")
swap = importlib.util.module_from_spec(spec); spec.loader.exec_module(swap)
class Args: think=None; fast=None; runtime=None
class ShellSwapTests(unittest.TestCase):
    def setUp(self):
        self.config={"agents":{"defaults":{"model":{"primary":"openai/gpt-old"},"models":{"openai/gpt-new":{"alias":"new"},"xai/grok":{"alias":"grok"}}}}}
    def test_alias_resolution(self): self.assertEqual(swap.resolve_target(self.config,"new"),"openai/gpt-new")
    def test_full_resolution(self): self.assertEqual(swap.resolve_target(self.config,"venice/foo/bar"),"venice/foo/bar")
    def test_default_resolution(self): self.assertEqual(swap.resolve_target(self.config,"default"),"default")
    def test_bare_unknown_rejected(self):
        with self.assertRaises(swap.SwapError): swap.resolve_target(self.config,"missing")
    def test_chat_filter(self):
        rows=[{"key":"agent:a:telegram:group:1"},{"key":"agent:a:cron:2"},{"key":"agent:a:main"}]
        self.assertEqual(len(swap.select_sessions(rows,False)),2); self.assertEqual(len(swap.select_sessions(rows,True)),3)
    def test_profile_preserves_model(self):
        row={"key":"agent:a:main","modelProvider":"openai","model":"gpt-5.6-sol"}
        self.assertEqual(swap.profile_model_for_row(row,"openai:me"),"openai/gpt-5.6-sol@openai:me")
        self.assertEqual(swap.profile_model_for_row(row,"default"),"openai/gpt-5.6-sol")
    def test_profile_requires_observed_model(self):
        with self.assertRaises(swap.SwapError): swap.profile_model_for_row({"key":"x"},"p")
    def test_profile_provider(self):
        self.assertEqual(swap.profile_provider("openai:me"),"openai")
        self.assertIsNone(swap.profile_provider("default"))
    def test_combined_patch(self):
        a=Args(); a.think="high"; a.fast="auto"; a.runtime="codex"
        self.assertEqual(swap.build_patch(a,"openai/gpt@openai:me"),{"model":"openai/gpt@openai:me","thinkingLevel":"high","fastMode":"auto","agentRuntime":"codex"})
    def test_clear_patch(self):
        a=Args(); a.think="default"; a.fast="default"; a.runtime="default"
        self.assertEqual(swap.build_patch(a,"default"),{"model":None,"thinkingLevel":None,"fastMode":None,"agentRuntime":None})
    def test_chunk_limit(self): self.assertEqual([len(x) for x in swap.chunks(list(range(205)))],[100,100,5])
    def test_target_guard_fields(self):
        row={"key":"k","agentId":"a","sessionId":"s","lifecycleRevision":"r"}
        self.assertEqual(swap.target_ref(row,"fallback"),{"key":"k","agentId":"a","expectedSessionId":"s","expectedLifecycleRevision":"r"})
    def test_set_default_dry_run(self):
        self.assertEqual(swap.set_default("never",self.config,"openai/gpt-new",True),{"before":"openai/gpt-old","after":"openai/gpt-new","changed":True})
    def test_set_default_rejects_inherit(self):
        with self.assertRaises(swap.SwapError): swap.set_default("x",self.config,"default",True)
    def test_current_agent_env(self):
        old=os.environ.get("OPENCLAW_MCP_AGENT_ID"); os.environ["OPENCLAW_MCP_AGENT_ID"]="<your-agent>"
        try: self.assertEqual(swap.normalize_agent("current"),"<your-agent>")
        finally:
            if old is None: os.environ.pop("OPENCLAW_MCP_AGENT_ID",None)
            else: os.environ["OPENCLAW_MCP_AGENT_ID"]=old
    def test_config_load(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/"openclaw.json"; p.write_text(json.dumps(self.config)); self.assertEqual(swap.load_config(p),self.config)
if __name__=="__main__": unittest.main()
