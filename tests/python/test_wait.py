import importlib.util
import json
import os
import pathlib
import socket
import tempfile
import threading
import unittest

spec = importlib.util.spec_from_file_location("readit_wait", pathlib.Path(__file__).resolve().parents[2] / "tools/readit_wait.py")
waiter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(waiter)


class FakeEditor:
    """A control socket that answers readit_state and readit_guide_events from a script."""

    def __init__(self, states):
        self.states = list(states)
        self.index = -1
        self.calls = []
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "control.sock")
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(self.path)
        self.server.listen()
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        while True:
            try:
                conn, _ = self.server.accept()
            except OSError:
                return
            with conn, conn.makefile("rb") as stream:
                call = json.loads(stream.readline())
                self.calls.append(call)
                # Each poll starts with readit_state, which moves to the next scripted state.
                if call["method"] == "readit_state":
                    self.index = min(self.index + 1, len(self.states) - 1)
                state = self.states[self.index]
                if call["method"] == "readit_state":
                    result = state["state"]
                else:
                    after = call["arguments"]["after"]
                    events = [e for e in state["events"] if e["sequence"] > after]
                    result = {"events": events, "latest_sequence": state["latest"], "truncated": state.get("truncated", False)}
                conn.sendall(json.dumps({"result": result}).encode() + b"\n")

    def close(self):
        self.server.close()


def tour_state(sequence, guide=True):
    return {"workspace": "/w", "guide_event_sequence": sequence,
            "guide": {"id": "one"} if guide else None,
            "guide_tour": {"id": "tour", "index": 1, "visited_through": 1} if guide else None}


class WaitTests(unittest.TestCase):
    def run_wait(self, editor, **options):
        options = {"after": None, "interval": 0, "timeout": 0, "stop_when_idle": False, **options}
        ticks = iter(range(10_000))
        return waiter.wait(editor.path, options["after"], options["interval"], options["timeout"], options["stop_when_idle"],
                           clock=lambda: next(ticks), sleep=lambda _: None, log=lambda _: None)

    def test_returns_the_first_question_after_the_start_sequence(self):
        question = {"sequence": 4, "action": "question", "question": "なぜ？", "id": "one"}
        editor = FakeEditor([
            {"state": tour_state(2), "events": [{"sequence": 1, "action": "question"}], "latest": 2},
            {"state": tour_state(3), "events": [{"sequence": 3, "action": "step"}], "latest": 3},
            {"state": tour_state(4), "events": [{"sequence": 3, "action": "step"}, question], "latest": 4},
        ])
        result = self.run_wait(editor)
        editor.close()
        self.assertEqual(result["status"], "question")
        self.assertEqual(result["event"]["question"], "なぜ？")
        self.assertEqual(result["latest_sequence"], 4)
        self.assertEqual(result["tour_id"], "tour")
        # Started from the latest sequence, so the old question was not replayed.
        afters = [c["arguments"]["after"] for c in editor.calls if c["method"] == "readit_guide_events"]
        self.assertEqual(afters[0], 2)

    def test_predictions_are_local_and_do_not_wake_the_ai(self):
        prediction = {"sequence": 3, "action": "prediction", "id": "guess", "status": "answered", "answer": "消える"}
        question = {"sequence": 4, "action": "question", "question": "なぜ？", "id": "one"}
        editor = FakeEditor([
            {"state": tour_state(3), "events": [prediction], "latest": 3},
            {"state": tour_state(4), "events": [prediction, question], "latest": 4},
        ])
        result = self.run_wait(editor, after=2, stop_when_idle=True)
        editor.close()
        self.assertEqual(result["status"], "question")
        self.assertEqual(result["event"]["sequence"], 4)

    def test_next_on_a_single_guide_is_actionable(self):
        editor = FakeEditor([{"state": tour_state(5), "events": [{"sequence": 6, "action": "next", "id": "one"}], "latest": 6}])
        result = self.run_wait(editor, after=5)
        editor.close()
        self.assertEqual(result["status"], "next")

    def test_stops_when_idle_and_times_out(self):
        idle = FakeEditor([{"state": tour_state(7, guide=False), "events": [], "latest": 7}])
        self.assertEqual(self.run_wait(idle, stop_when_idle=True)["status"], "ended")
        self.assertEqual(self.run_wait(idle, timeout=3)["status"], "timeout")
        idle.close()

    def test_truncation_and_unavailable_editor(self):
        truncated = FakeEditor([{"state": tour_state(200), "events": [], "latest": 200, "truncated": True}])
        self.assertEqual(self.run_wait(truncated, after=1)["status"], "truncated")
        truncated.close()
        ticks = iter(range(100))
        result = waiter.wait("/missing/readit.sock", 0, 0, 5, False, clock=lambda: next(ticks), sleep=lambda _: None, log=lambda _: None)
        self.assertEqual(result["status"], "timeout")


if __name__ == "__main__":
    unittest.main()
