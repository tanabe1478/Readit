#!/usr/bin/env python3
"""Wait until the user asks something in a Readit guide, then print one JSON line.

AI clients run this while a guide is open so a question sent from the bubble
reaches them without the user switching back to the chat. Claude Code runs it
in the background and resumes when it exits; the pi extension runs it as a
child process and forwards the result into the session.

Output (stdout, one line): {"status": ..., "latest_sequence": n, ...}
  question  the user sent a question; "event" holds it with the source range
  next      the user pressed Next on a single guide_show bubble
  ended     no guide or tour remains (only with --stop-when-idle)
  truncated events older than --after were dropped; read readit_state
  timeout   --timeout elapsed; run again with the same --after
Prediction events are the reader's local notes and never end the wait.
Diagnostics go to stderr. Python 3.10+ standard library only.
"""
import argparse
import json
import os
import socket
import sys
import time

MAX_RESPONSE = 4 * 1024 * 1024


def call(endpoint, method, arguments):
    payload = json.dumps({"method": method, "arguments": arguments}, ensure_ascii=False).encode() + b"\n"
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(60)
        client.connect(endpoint)
        client.sendall(payload)
        with client.makefile("rb") as stream:
            response = stream.readline(MAX_RESPONSE + 1)
    if not response.endswith(b"\n"):
        raise ValueError("invalid editor response")
    data = json.loads(response)
    if "error" in data:
        raise ValueError(data["error"])
    return data["result"]


def summary(state):
    tour = state.get("guide_tour")
    return {
        "workspace": state.get("workspace"),
        "tour_id": tour and tour.get("id"),
        "tour_index": tour and tour.get("index"),
        "visited_through": tour and tour.get("visited_through"),
        "guide_id": (state.get("guide") or {}).get("id"),
    }


def wait(endpoint, after, interval, timeout, stop_when_idle, clock=time.monotonic, sleep=time.sleep, log=None):
    """Poll guide events and return the first actionable result as a dict."""
    log = log or (lambda message: print(message, file=sys.stderr, flush=True))
    started = clock()
    unavailable = None
    while True:
        try:
            state = call(endpoint, "readit_state", {})
            if after is None:
                after = state.get("guide_event_sequence", 0)
            reply = call(endpoint, "readit_guide_events", {"workspace": state["workspace"], "after": after})
            if unavailable is not None:
                log("readit-wait: editor is reachable again")
                unavailable = None
        except (OSError, ValueError, KeyError) as error:
            # The window may be reloading or not open yet; keep waiting quietly.
            if unavailable is None:
                log(f"readit-wait: editor unavailable ({error}); retrying")
                unavailable = clock()
            state, reply = None, None
        if reply is not None:
            if reply.get("truncated"):
                return {"status": "truncated", "latest_sequence": reply["latest_sequence"], **summary(state)}
            for event in reply.get("events", []):
                if event.get("action") in ("question", "next"):
                    return {"status": event["action"], "event": event,
                            "latest_sequence": reply["latest_sequence"], **summary(state)}
            after = reply.get("latest_sequence", after)
            if stop_when_idle and not state.get("guide") and not state.get("guide_tour"):
                return {"status": "ended", "latest_sequence": after, **summary(state)}
        if timeout and clock() - started >= timeout:
            return {"status": "timeout", "latest_sequence": after,
                    **(summary(state) if state else {"workspace": None})}
        sleep(interval)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--socket", default=os.environ.get("READIT_SOCKET") or os.path.expanduser("~/.readit/control.sock"),
                        help="Readit's --control-socket path (default: $READIT_SOCKET or ~/.readit/control.sock)")
    parser.add_argument("--after", type=int, help="Last handled guide event sequence (default: the current latest)")
    parser.add_argument("--interval", type=float, default=1.0, help="Seconds between polls")
    parser.add_argument("--timeout", type=float, default=6600,
                        help="Give up after this many seconds (0 waits forever; the default fits a 2-hour background limit)")
    parser.add_argument("--stop-when-idle", action="store_true", help="Exit with status ended when no guide or tour remains")
    options = parser.parse_args(argv)
    result = wait(options.socket, options.after, options.interval, options.timeout, options.stop_when_idle)
    print(json.dumps(result, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
