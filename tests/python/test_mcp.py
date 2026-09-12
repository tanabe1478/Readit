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
