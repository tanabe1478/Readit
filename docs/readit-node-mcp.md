# Node attach-only MCP entry point

`tools/readit_mcp.mjs` connects an MCP stdio client to an **already running**
Readit control socket. It requires Node.js **24 or later**, standard library only:
no Python, npm install, additional packages, MoonBit build or browser launch.
The existing Python entry point and desktop `integrations/pi` remain supported.

```sh
node /absolute/path/to/Readit/tools/readit_mcp.mjs \
  --socket /absolute/path/to/existing/control.sock
```

Example stdio registration (adapt the wrapper to the client's MCP configuration):

```json
{
  "mcpServers": {
    "readit": {
      "command": "node",
      "args": ["/absolute/path/to/Readit/tools/readit_mcp.mjs", "--socket", "/absolute/path/to/existing/control.sock"]
    }
  }
}
```

Android Pi should publish this connection's tools through its existing durable
Harness / `@earendil-works/pi-mcp` integration, not start a separate Pi CLI.
This document does not install or modify Android Pi configuration.

## Ownership and lifecycle

- `--socket` is required. `--launch`, unknown/duplicate arguments and extra
  positional arguments are rejected. `--help` prints usage to stderr.
- This entry point never starts/stops Readit, launches a browser, creates/removes
  a control socket or changes socket permissions. It owns only its stdio and
  per-call Unix socket connections. It does not infer server liveness or inspect
  server ownership records.
- Each tool call makes **one connection and one write**, with a 60-second deadline.
  No retry after timeout, disconnection, malformed response or any other failure.
  A mutation may already have happened when a reply is lost. Inspect
  `readit_state` and current guide events before deciding a subsequent action;
  never blindly replay the mutation.
- Normal stdin EOF finishes the received frames and pending reply, then exits.
  Premature input/output close or SIGINT/SIGTERM/SIGHUP cancels this process's
  pending connection. It does not stop the attached Readit or clear its guide.
- Unix socket paths must fit the OS `sun_path` limit (usually 107 bytes). Android
  app-private paths can be long; use the actual existing socket path and let
  transport errors surface rather than truncating or deleting another socket.

## Protocol and guards

The Node and Python entry points consume the same canonical
`tools/readit_mcp_schema.json` for all 17 tool names, descriptions, annotations
and input schemas. The JSON also preserves Python's exported schema constants.
`tools/list` is unchanged. Protocol versions, initialize response and tool-result
shape match Python: validation errors are JSON-RPC errors, editor/transport
errors are tool results with `isError: true`; successful results contain both
text content and `structuredContent` with `isError: false`.

- Send `initialize`, then `notifications/initialized`, before tools. `ping` is
  also allowed before initialization. Notifications do not receive replies.
- MCP framing is newline-delimited JSON-RPC, not Content-Length headers. Input
  is bounded to 262,144 bytes per frame including newline. Oversized frames are
  drained once; their suffix is never processed as another request. A final
  unterminated stdin frame is processed, as in Python. Broken JSON and invalid
  UTF-8 produce `-32700`; malformed requests use `-32600`; invalid arguments
  use `-32602`; unknown methods use `-32601`.
- Unknown tool properties (including nested ones), missing required properties,
  types, integer bounds, enums, array lengths, prediction/verification rules,
  duplicate step ids and duplicate claim ids are validated before socket writes.
  JSON decimal/exponent literals such as `1.0`/`1e0` are not accepted as integers,
  matching Python's strict integer validator. Node rejects integers outside the
  exact JavaScript safe-integer range rather than silently rounding coordinates,
  ids or event sequences. Lone Unicode surrogates are rejected before forwarding;
  valid Japanese text and supplementary characters are preserved.
- Workspace, exact source, event/question sequence and tour ids are forwarded
  unchanged: no cached workspace substitution, no guard weakening. The existing
  Readit server/browser remains authoritative for workspace changes, stale
  source, dialogs, unsaved buffers, native preedit and guide lifecycle decisions.
  `readit_open_folder` resolves `~`, symlinks and relative paths locally, as the
  Python entry point does, but never bypasses Readit's unsaved-change confirmation.
- Editor replies must be UTF-8 JSON with a newline within 4 MiB, containing
  `result` or `error`. Invalid/oversized/truncated replies are tool errors.
  Unsafe integer/non-finite numbers in replies are also rejected, so an event
  sequence is never silently rounded while reporting state to the client.
- Guide load/revise success replies compact the just-sent overview/steps like
  Python. `readit_state` includes `control_socket` and a legacy `wait_command`
  referencing `python3 tools/readit_wait.py`; this is compatibility metadata,
  **not a Node waiter or a process spawned by this entry point**.

## Questions in Android Pi

Android Pi's automatic question receiver is a separate integration. Use the
returned `control_socket` and the existing `readit_guide_events` tool, forwarding
actual `question` events into the **same** durable Harness. Do not execute the
legacy Python `wait_command` in a Python-less installation. Preserve event
sequence/non-consuming semantics and do not fabricate user questions, replay
view mutations or restart a guide when a waiter ends. The desktop Python waiter
and existing pi extension have not been changed by this work.

## Tests and remaining host verification

Local Node tests use in-memory stdio and **temporary mock Unix sockets only**;
no existing Readit server, Preview, fixture text, guide or preedit is accessed.
The mock paths are shortened for Android's Unix path limit and cleaned up.

```sh
node --test tests/node/readit_mcp.test.mjs
```

The one-time migration extracted the existing declarative Python schemas without
installing Python on Android. Host verification must independently compare every
schema against the already-published pre-Node commit `0af16b5`, and run the
existing Python regression suite. The new parity test imports definitions only,
never starts a Launcher/server and additionally compares Node/Python initialize,
`tools/list` and validation results. The published baseline Git object must be
present in the isolated host checkout.

```sh
python3 -m unittest discover -s tests/python -p 'test_mcp*.py'
node --test tests/node/readit_mcp.test.mjs
```

Remaining integration acceptance (separately authorized host/Android pass):

1. Canonical definitions equal the pre-Node Python definitions; all existing
   Python MCP tests and new cross-entry parity tests pass on the host.
2. Node attach against an owned existing Readit socket, initially read-only;
   `readit_state` reports the correct workspace and unchanged unsaved/preedit state.
3. Android Pi publishes all 17 tools through the same durable Harness, loads the
   guide skill, and delivers actual guide questions once without a second waiter.
4. Authorized guide navigation/stale-source/stale-event/unsaved-dialog cases with
   real Readit, plus MCP stdio shutdown that leaves the existing server alive.

This source pass does not claim those live integration checks have run.
