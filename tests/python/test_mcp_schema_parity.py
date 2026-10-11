"""Host-only parity checks. No Readit instance, socket, browser or dependencies.

The published pre-Node commit is the oracle for the one-time schema migration.
Requires that Git object locally (0af16b5) and Python 3.10+; Node comparison uses
only the standard library. Run alongside the existing test_mcp.py regression.
"""
import importlib.util
import json
import pathlib
import shutil
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
BASELINE = "0af16b509b306e96bfd99b056ed4eb5fea37f32a"
spec = importlib.util.spec_from_file_location("readit_mcp_canonical", ROOT / "tools/readit_mcp.py")
mcp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mcp)


class SchemaParity(unittest.TestCase):
    def test_canonical_matches_published_python_definitions(self):
        source = subprocess.run(
            ["git", "show", f"{BASELINE}:tools/readit_mcp.py"], cwd=ROOT,
            check=True, capture_output=True, text=True).stdout
        namespace = {"__name__": "readit_mcp_baseline", "__file__": str(ROOT / "tools/readit_mcp.py")}
        # __name__ is not __main__: import definitions only; never start serve/Launcher.
        exec(compile(source, "published-readit_mcp.py", "exec"), namespace)
        canonical = json.loads((ROOT / "tools/readit_mcp_schema.json").read_text(encoding="utf-8"))
        self.assertEqual(canonical["tools"], namespace["TOOLS"])
        self.assertEqual(mcp.TOOLS, namespace["TOOLS"])
        for name, value in canonical["definitions"].items():
            self.assertEqual(value, namespace[name], name)
            self.assertEqual(getattr(mcp, name), value, name)

    @unittest.skipUnless(shutil.which("node"), "Node required for cross-entry parity")
    def test_node_tools_and_initialize_match_python(self):
        source = """
import {Server} from './tools/readit_mcp.mjs';
const s = new Server('/unused-no-connection');
const initialized = await s.handle({jsonrpc:'2.0',id:1,method:'initialize',params:{protocolVersion:'future'}});
await s.handle({jsonrpc:'2.0',method:'notifications/initialized'});
console.log(JSON.stringify({initialized, list:await s.handle({jsonrpc:'2.0',id:2,method:'tools/list'})}));
"""
        node = json.loads(subprocess.run(["node", "--input-type=module", "-e", source],
                                        cwd=ROOT, check=True, capture_output=True, text=True).stdout)
        server = mcp.Server("/unused-no-connection")
        initialized = server.handle({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "future"}})
        server.handle({"jsonrpc": "2.0", "method": "notifications/initialized"})
        self.assertEqual(node["initialized"], initialized)
        self.assertEqual(node["list"], server.handle({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}))

    @unittest.skipUnless(shutil.which("node"), "Node required for cross-entry parity")
    def test_validation_messages_match_python(self):
        def step(id="s", **extra):
            return {"id": id, "title": "t", "body": "b", "path": "a", "line": 1,
                    "column": 1, "expected_text": "日本😀", **extra}

        def tour(steps):
            return {"workspace": "/w", "id": "tour", "event_sequence": 0, "steps": steps}

        cases = [
            ["readit_state", {}], ["readit_state", None], ["readit_state", {"typo": 1}],
            ["readit_read", {"workspace": "/w"}],
            ["readit_read", {"workspace": "/w", "path": "a", "start_line": True}],
            ["readit_files", {"workspace": "/w", "offset": -1}],
            ["readit_read", {"workspace": "/w", "path": "a", "line_count": 401}],
            ["readit_symbol", {"workspace": "/w", "kind": "fake"}],
            ["readit_guide_load", tour([])],
            ["readit_guide_load", tour([step(typo=1)])],
            ["readit_guide_load", tour([step(), step()])],
            ["readit_guide_load", tour([step(kind="prediction")])],
            ["readit_guide_load", tour([step(prompt="why")])],
            ["readit_guide_load", tour([step(kind="verification", verifies="kept")])],
            ["readit_guide_load", tour([step("p", kind="prediction", prompt="why"), step("v", kind="verification", verifies="p")])],
            ["readit_guide_revise", {**tour([step(kind="verification", verifies="kept")]), "question_sequence": 1, "answer": "answer"}],
        ]
        expected = []
        for name, args in cases:
            try:
                schema = next(t["inputSchema"] for t in mcp.TOOLS if t["name"] == name)
                mcp.validate(args, schema)
                if name in ("readit_guide_load", "readit_guide_revise"):
                    mcp.validate_tour(args, name == "readit_guide_revise")
                expected.append(None)
            except mcp.RpcError as error:
                expected.append({"code": error.code, "message": str(error)})
        source = """
import fs from 'node:fs';
import {TOOLS,validate,validateTour} from './tools/readit_mcp.mjs';
const cases=JSON.parse(fs.readFileSync(0,'utf8'));
console.log(JSON.stringify(cases.map(([name,args])=>{try {
 validate(args,TOOLS.find(t=>t.name===name).inputSchema);
 if(['readit_guide_load','readit_guide_revise'].includes(name))validateTour(args,name==='readit_guide_revise');
 return null;
} catch(e){return {code:e.code,message:e.message};}})));
"""
        actual = json.loads(subprocess.run(["node", "--input-type=module", "-e", source],
                                          input=json.dumps(cases), cwd=ROOT, check=True,
                                          capture_output=True, text=True).stdout)
        self.assertEqual(actual, expected)


if __name__ == "__main__":
    unittest.main()
