import importlib.util
import io
import json
import pathlib
import socket
import tempfile
import threading
import unittest

spec = importlib.util.spec_from_file_location("readit_mcp", pathlib.Path(__file__).resolve().parents[2] / "tools/readit_mcp.py")
mcp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mcp)


class ProtocolTests(unittest.TestCase):
    def exchange(self, messages):
        source = io.BytesIO(b"\n".join(json.dumps(m).encode() for m in messages) + b"\n")
        output = io.StringIO()
        mcp.serve("/missing/readit.sock", source, output)
        return [json.loads(line) for line in output.getvalue().splitlines()]

    def init(self):
        return [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-11-25"}},
                {"jsonrpc": "2.0", "method": "notifications/initialized"}]

    def test_lifecycle_and_tool_discovery(self):
        replies = self.exchange(self.init() + [{"jsonrpc": "2.0", "id": 2, "method": "tools/list"}])
        self.assertEqual(len(replies), 2)  # No reply to initialized notification.
        self.assertEqual(replies[0]["result"]["protocolVersion"], "2025-11-25")
        tools = replies[1]["result"]["tools"]
        self.assertIn("readit_open", [t["name"] for t in tools])
        self.assertFalse(next(t for t in tools if t["name"] == "readit_open")["annotations"]["readOnlyHint"])

    def test_schema_errors_and_disconnected_editor(self):
        replies = self.exchange(self.init() + [
            {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "readit_open", "arguments": {"workspace": "/test", "path": "a.py", "line": True}}},
            {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "readit_state"}},
            {"jsonrpc": "2.0", "id": 4, "method": "unknown"},
        ])
        self.assertEqual(replies[1]["error"]["code"], -32602)
        self.assertTrue(replies[2]["result"]["isError"])
        self.assertEqual(replies[3]["error"]["code"], -32601)

    def test_prepared_tour_rejects_malformed_nested_steps(self):
        schema = next(t for t in mcp.TOOLS if t["name"] == "readit_guide_load")["inputSchema"]
        step = {"id": "a", "title": "a", "body": "説明", "path": "a.py", "line": 1, "column": 1, "expected_text": "a"}
        args = {"workspace": "/test", "id": "tour", "event_sequence": 0, "steps": [step]}
        mcp.validate(args, schema)
        for steps in [[], [None], [{**step, "line": True}], [{**step, "extra": 1}], [step] * 33]:
            with self.assertRaises(mcp.RpcError):
                mcp.validate({**args, "steps": steps}, schema)

    def tour_args(self, steps, overview=None):
        args = {"workspace": "/test", "id": "tour", "event_sequence": 0, "steps": steps}
        if overview is not None:
            args["overview"] = overview
        return args

    def accepts(self, name, args):
        mcp.validate(args, next(t for t in mcp.TOOLS if t["name"] == name)["inputSchema"])
        mcp.validate_tour(args, name == "readit_guide_revise")

    def rejects(self, name, args):
        with self.assertRaises(mcp.RpcError):
            self.accepts(name, args)

    def test_step_kinds(self):
        base = {"title": "t", "body": "説明", "path": "a.py", "line": 1, "column": 1, "expected_text": "a"}
        legacy = {"id": "legacy", **base}
        explanation = {"id": "e", "kind": "explanation", **base}
        hypothesis = {"id": "h", "kind": "hypothesis", **base}
        prediction = {"id": "p", "kind": "prediction", "prompt": "どうなると思う？", **base}
        verification = {"id": "v", "kind": "verification", "verifies": "p", **base}
        self.accepts("readit_guide_load", self.tour_args([legacy]))
        self.accepts("readit_guide_load", self.tour_args([explanation, hypothesis, prediction, verification]))
        bad = [
            [{k: v for k, v in prediction.items() if k != "prompt"}],
            [{**explanation, "prompt": "?"}],
            [prediction, {k: v for k, v in verification.items() if k != "verifies"}],
            [{**hypothesis, "verifies": "p"}],
            [verification, prediction],  # verifies a later step
            [explanation, {**verification, "verifies": "e"}],  # not a prediction
            [prediction, {**verification, "verifies": "missing"}],
            [{**explanation, "kind": "quiz"}],
            [explanation, {**hypothesis, "id": "e"}],
            [{**prediction, "prompt": 1}],
        ]
        for steps in bad:
            self.rejects("readit_guide_load", self.tour_args(steps))
        # A revision may verify a prediction from the retained history; Readit checks it.
        revise = {**self.tour_args([verification]), "question_sequence": 1, "answer": "回答"}
        self.accepts("readit_guide_revise", revise)
        self.rejects("readit_guide_revise", {**revise, "steps": [verification, prediction]})
        # The stdio server applies the same rules before contacting the editor.
        replies = self.exchange(self.init() + [{"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {
            "name": "readit_guide_load", "arguments": self.tour_args([{k: v for k, v in prediction.items() if k != "prompt"}])}}])
        self.assertEqual(replies[1]["error"]["code"], -32602)

    def test_overview_claims_and_reader_context(self):
        step = {"id": "a", "title": "a", "body": "説明", "path": "a.py", "line": 1, "column": 1, "expected_text": "a"}
        legacy = {"title": "t", "summary": "s", "relationships": "r", "chapters": [{"title": "c", "summary": "s", "start_step": "a"}]}
        evidence = {"label": "根拠", "path": "a.py", "line": 1, "column": 1, "expected_text": "a"}
        claim = {"id": "c1", "statement": "主張", "confidence": "source_confirmed", "evidence": [evidence]}
        full = {**legacy, "reader_context": {"known": ["async/await"], "focus": ["所有権"]},
                "claims": [claim, {**claim, "id": "c2", "confidence": "inferred"}]}
        self.accepts("readit_guide_load", self.tour_args([step], legacy))
        self.accepts("readit_guide_load", self.tour_args([step], full))
        self.accepts("readit_guide_load", self.tour_args([step], {**legacy, "reader_context": {}}))
        bad = [
            {**legacy, "claims": [claim, claim]},
            {**legacy, "claims": [{**claim, "id": f"c{i}"} for i in range(9)]},
            {**legacy, "claims": [{**claim, "confidence": "verified"}]},
            {**legacy, "claims": [{**claim, "evidence": []}]},
            {**legacy, "claims": [{**claim, "evidence": [evidence] * 9}]},
            {**legacy, "claims": [{**claim, "evidence": [{**evidence, "line": "1"}]}]},
            {**legacy, "claims": [{**claim, "evidence": [{k: v for k, v in evidence.items() if k != "expected_text"}]}]},
            {**legacy, "claims": [{**claim, "evidence": [{**evidence, "extra": 1}]}]},
            {**legacy, "claims": [{**claim, "extra": 1}]},
            {**legacy, "reader_context": {"known": ["x"] * 17}},
            {**legacy, "reader_context": {"focus": ["x"] * 9}},
            {**legacy, "reader_context": {"known": [1]}},
            {**legacy, "reader_context": {"persona": "x"}},
            {**legacy, "reader_context": ["x"]},
            {**legacy, "extra": 1},
        ]
        for overview in bad:
            self.rejects("readit_guide_load", self.tour_args([step], overview))

    def test_launch_mode_names_the_session_after_the_client(self):
        launcher = mcp.Launcher(None, "/repo", None)
        server = mcp.Server(None, launcher)
        server.handle({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                       "params": {"protocolVersion": "2025-11-25", "clientInfo": {"name": "Claude Code"}}})
        self.assertEqual(launcher.label, "Claude Code")
        path = mcp.Launcher.default_socket(launcher.label)
        self.assertTrue(pathlib.Path(path).name.startswith("claude-code-"))
        self.assertEqual(pathlib.Path(path).parent, pathlib.Path.home() / ".readit/sessions")
        self.assertLess(len(path.encode()), 104)  # Unix socket path limit on macOS.
        # An explicit label wins over the client's name.
        named = mcp.Launcher(None, "/repo", "pi")
        mcp.Server(None, named).handle({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                                         "params": {"protocolVersion": "2025-11-25", "clientInfo": {"name": "other"}}})
        self.assertEqual(named.label, "pi")

    def test_parse_error_and_uninitialized_calls(self):
        output = io.StringIO()
        mcp.serve("/missing", io.BytesIO(b'not-json\n[]\n'), output)
        replies = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual([r["error"]["code"] for r in replies], [-32700, -32600])
        replies = self.exchange([{"jsonrpc": "2.0", "id": 1, "method": "tools/list"}])
        self.assertEqual(replies[0]["error"]["code"], -32600)

    def test_forwards_utf8_and_unsaved_result(self):
        with tempfile.TemporaryDirectory(prefix="rd-mcp-", dir="/tmp") as directory:
            endpoint = str(pathlib.Path(directory) / "s")
            listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            listener.bind(endpoint)
            listener.listen()
            received = []
            def respond():
                connection, _ = listener.accept()
                with connection:
                    received.append(json.loads(connection.makefile("rb").readline()))
                    connection.sendall(json.dumps({"result": {"text": "未保存の本文", "unsaved": True}}, ensure_ascii=False).encode() + b"\n")
            worker = threading.Thread(target=respond)
            worker.start()
            result = mcp.editor_call(endpoint, "readit_read", {"workspace": "/repo", "path": "日本語.py"})
            worker.join(3)
            listener.close()
            self.assertFalse(worker.is_alive())
            self.assertEqual(received[0]["arguments"]["path"], "日本語.py")
            self.assertEqual(result["text"], "未保存の本文")
            self.assertTrue(result["unsaved"])


if __name__ == "__main__":
    unittest.main()
