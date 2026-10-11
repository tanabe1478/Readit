import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import { PassThrough, Readable, Writable } from 'node:stream';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import { fileURLToPath } from 'node:url';
import {
  Server,
  serve,
  editorCall,
  validate,
  validateTour,
  TOOLS,
  MAX_FRAME,
  MAX_RESPONSE,
  parseArgs,
  isMain
} from '../../tools/readit_mcp.mjs';

const root = fileURLToPath(new URL('../../', import.meta.url));
const entry = path.join(root, 'tools/readit_mcp.mjs');

const req = (method, params = {}, id = 1) => {
  return { jsonrpc: '2.0', method, params, id };
};

const init = req('initialize', { protocolVersion: '2025-11-25' });
const initialized = { jsonrpc: '2.0', method: 'notifications/initialized' };

const call = (name, arguments_) => {
  return req('tools/call', { name, arguments: arguments_ });
};

const code = number => {
  return error => {
    return error.code === number;
  };
};

const encodeFrames = messages => {
  return messages.map(JSON.stringify).join('\n') + '\n';
};

async function ready(endpoint, options) {
  const server = new Server(endpoint, options);
  await server.handle(init);
  await server.handle(initialized);
  return server;
}

async function wire(chunks, options) {
  let text = '';
  const output = new Writable({
    write(chunk, _, done) {
      text += chunk.toString();
      done();
    }
  });
  await serve('/unused/socket', Readable.from(chunks), output, options);
  return text.trim() ? text.trim().split('\n').map(JSON.parse) : [];
}

async function mock(t, responder) {
  // Keep sun_path under 108 bytes even in the Android app's long workspace.
  const directory = fs.mkdtempSync(path.join(root, '..', '.mcp-'));
  const endpoint = path.join(directory, 's');
  const sockets = new Set();
  const requests = [];
  const server = net.createServer(client => {
    sockets.add(client);
    client.on('error', () => {
      // A closed test client must not fail the mock listener.
    });
    client.on('close', () => {
      sockets.delete(client);
    });
    let pending = '';
    client.on('data', bytes => {
      pending += bytes.toString();
      const end = pending.indexOf('\n');
      if (end >= 0) {
        const message = JSON.parse(pending.slice(0, end));
        pending = '';
        requests.push(message);
        responder(client, message);
      }
    });
  });
  t.after(async () => {
    for (const client of sockets) {
      client.destroy();
    }
    if (server.listening) {
      await new Promise(resolve => {
        server.close(resolve);
      });
    }
    fs.rmSync(directory, { recursive: true, force: true });
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(endpoint, resolve);
  });
  return { endpoint, requests };
}

const step = (id, extra = {}) => {
  return {
    id,
    title: 'T',
    body: 'B',
    path: 'a',
    line: 1,
    column: 1,
    expected_text: 'x',
    ...extra
  };
};

const tour = steps => {
  return { workspace: '/w', id: 'tour', event_sequence: 0, steps };
};

test('canonical tools/list exactly matches shared JSON', async () => {
  const canonical = JSON.parse(fs.readFileSync(path.join(root, 'tools/readit_mcp_schema.json')));
  assert.equal(TOOLS.length, 17);
  const server = await ready('/unused');
  assert.deepEqual(await server.handle(req('tools/list')), { tools: canonical.tools });
});

test('initialization sequence, version negotiation, ping, duplicate initialize', async () => {
  const server = new Server('/unused');
  assert.deepEqual(await server.handle(req('ping')), {});
  await server.handle(initialized);
  await assert.rejects(server.handle(req('tools/list')), code(-32600));
  await assert.rejects(server.handle(req('initialize', {})), code(-32602));
  const result = await server.handle(req('initialize', { protocolVersion: 'future' }));
  assert.equal(result.protocolVersion, '2025-11-25');
  await assert.rejects(server.handle(req('tools/list')), code(-32600));
  await server.handle(initialized);
  await assert.rejects(server.handle(init), code(-32600));
  await assert.rejects(server.handle(req('unknown')), code(-32601));
});

test('invalid requests, ids and params; notifications never respond', async () => {
  const messages = [
    null,
    [],
    {},
    { ...req('ping'), jsonrpc: '1.0' },
    req('ping', {}, true),
    req('ping', {}, 1.5),
    req('ping', {}, null)
  ];
  for (const message of messages) {
    await assert.rejects(new Server('/unused').handle(message), code(-32600));
  }
  for (const params of [null, [], 'x', 1]) {
    await assert.rejects(new Server('/unused').handle(req('ping', params)), code(-32602));
  }
  const result = await wire([
    Buffer.from(encodeFrames([initialized, { method: 'bad' }, req('ping')]))
  ]);
  assert.equal(result.length, 1);
  assert.deepEqual(result[0].result, {});
});

test('unknown tool and arguments, nested schema types, bounds and enums', async () => {
  const server = await ready('/unused');
  const messages = [
    call('unknown', {}),
    call('readit_state', { typo: true }),
    call('readit_state', null),
    call('readit_read', { workspace: '/w' }),
    call('readit_read', { workspace: '/w', path: 'a', start_line: true }),
    call('readit_read', { workspace: '/w', path: 'a', line_count: 401 }),
    call('readit_files', { workspace: '/w', offset: -1 }),
    call('readit_symbol', { workspace: '/w', kind: 'fake' }),
    call('readit_state', JSON.parse('{"__proto__":1}'))
  ];
  for (const message of messages) {
    await assert.rejects(server.handle(message), code(-32602));
  }
});

test('tour schema and semantics: duplicates, prediction, verification, revisions, claims', () => {
  const schema = TOOLS.find(tool => {
    return tool.name === 'readit_guide_load';
  }).inputSchema;
  const invalidSchema = [
    tour([]),
    tour([step('a', { bad: true })]),
    tour([step('a', { line: 1.5 })]),
    tour(Array.from({ length: 33 }, (_, index) => {
      return step(String(index));
    }))
  ];
  for (const args of invalidSchema) {
    assert.throws(() => {
      validate(args, schema);
    }, code(-32602));
  }
  const invalidTours = [
    tour([step('a'), step('a')]),
    tour([step('p', { kind: 'prediction' })]),
    tour([step('a', { prompt: 'x' })]),
    tour([step('v', { kind: 'verification' })]),
    tour([step('a', { verifies: 'x' })]),
    tour([
      step('v', { kind: 'verification', verifies: 'p' }),
      step('p', { kind: 'prediction', prompt: 'why' })
    ])
  ];
  for (const args of invalidTours) {
    assert.throws(() => {
      validateTour(args, false);
    }, code(-32602));
  }
  const good = tour([
    step('__proto__', { kind: 'prediction', prompt: 'why' }),
    step('v', { kind: 'verification', verifies: '__proto__' })
  ]);
  validate(good, schema);
  validateTour(good, false);
  const revision = tour([step('v', { kind: 'verification', verifies: 'kept' })]);
  validateTour(revision, true);
  assert.throws(() => {
    validateTour(revision, false);
  }, code(-32602));
  assert.throws(() => {
    validateTour({ ...tour([]), overview: { claims: [{ id: 'x' }, { id: 'x' }] } }, true);
  }, code(-32602));
});

test('broken JSON, invalid UTF-8 and scalar/batch requests recover cleanly', async () => {
  const result = await wire([
    Buffer.from('{oops}\n'),
    Buffer.from([0xff, 10]),
    Buffer.from('null\n[]\n'),
    Buffer.from(encodeFrames([req('ping')]))
  ]);
  const codes = result.map(response => {
    return response.error?.code ?? 0;
  });
  assert.deepEqual(codes, [-32700, -32700, -32600, -32600, 0]);
  assert.equal(result[0].id, null);
});

test('oversized frame drains all fragments once and then resumes', async () => {
  const result = await wire([
    Buffer.alloc(MAX_FRAME, 120),
    Buffer.alloc(MAX_FRAME, 120),
    Buffer.from('\n' + encodeFrames([req('ping')]))
  ]);
  assert.equal(result.length, 2);
  assert.equal(result[0].error.code, -32700);
  assert.deepEqual(result[1].result, {});
  const oversized = await wire([Buffer.alloc(MAX_FRAME + 1, 120)]);
  assert.equal(oversized[0].error.message, 'message is too large');
});

test('EOF: empty, final unterminated valid or invalid frame, exact frame boundary', async () => {
  assert.deepEqual(await wire([]), []);
  const valid = await wire([Buffer.from(JSON.stringify(req('ping')))]);
  assert.deepEqual(valid[0].result, {});
  const invalid = await wire([Buffer.from('{')]);
  assert.equal(invalid[0].error.code, -32700);
  const ping = Buffer.from(JSON.stringify(req('ping')));
  const exact = Buffer.concat([
    ping,
    Buffer.alloc(MAX_FRAME - ping.length - 1, 32),
    Buffer.from('\n')
  ]);
  assert.equal((await wire([exact]))[0].error, undefined);
});

test('UTF-8 split framing and newline escape stay intact', async () => {
  const bytes = Buffer.from(encodeFrames([req('ping', { ignored: '日本語\n確認😀' })]));
  const fragments = [...bytes].map(byte => {
    return Buffer.from([byte]);
  });
  assert.deepEqual((await wire(fragments))[0].result, {});
});

test('JSON decimal/exponent literals preserve Python strict integer validation', async () => {
  for (const literal of ['1.0', '1e0']) {
    const response = await wire([
      Buffer.from(`{"jsonrpc":"2.0","id":${literal},"method":"ping"}\n`)
    ]);
    assert.equal(response[0].error.code, -32600);
    const toolCall = '{"jsonrpc":"2.0","id":2,"method":"tools/call",' +
      '"params":{"name":"readit_read","arguments":{"workspace":"/w","path":"a",' +
      `"start_line":${literal}}}}`;
    const input = encodeFrames([init, initialized]) + toolCall + '\n';
    assert.equal((await wire([Buffer.from(input)]))[1].error.message, 'start_line must be integer');
  }
  const invalid = await wire([
    Buffer.from('{"jsonrpc":"2.0","id":1,"method":"ping","params":1.0}\n')
  ]);
  assert.equal(invalid[0].error.code, -32602);
});

test('lone Unicode surrogate is a tool error before any Unix connection', async () => {
  await assert.rejects(
    editorCall('/unused', 'readit_search', { query: '\ud800' }),
    /unpaired Unicode surrogate/
  );
});

test('Unix round-trip forwards workspace/source guards and returns structuredContent', async t => {
  const mockServer = await mock(t, (client, request) => {
    const response = request.arguments.workspace === '/stale'
      ? { error: 'stale workspace' }
      : { result: { text: '日本語😀', received: request } };
    client.end(JSON.stringify(response) + '\n');
  });
  const server = await ready(mockServer.endpoint);
  const args = { workspace: '/w', path: 'a', line: 2, column: 3 };
  const result = await server.handle(call('readit_open', args));
  assert.equal(result.isError, false);
  assert.deepEqual(JSON.parse(result.content[0].text), result.structuredContent);
  assert.deepEqual(mockServer.requests[0], { method: 'readit_open', arguments: args });
  const stale = await server.handle(call('readit_guide_show', {
    workspace: '/stale',
    id: 'x',
    title: 't',
    body: 'b',
    path: 'a',
    line: 1,
    column: 1,
    expected_text: 'old',
    event_sequence: 8
  }));
  assert.equal(stale.isError, true);
  assert.equal(stale.content[0].text, 'stale workspace');
  assert.equal('structuredContent' in stale, false);
  assert.equal(mockServer.requests[1].arguments.expected_text, 'old');
  assert.equal(mockServer.requests[1].arguments.event_sequence, 8);
});

test('state socket metadata and guide result compaction match Python shape', async t => {
  const mockServer = await mock(t, (client, request) => {
    const result = request.method === 'readit_state'
      ? { workspace: '/w', unsaved: true }
      : {
        guide_tour: {
          overview: {
            title: 'Overview',
            chapters: [1, 2],
            claims: [1],
            summary: 'not echoed'
          },
          steps: [{ id: 'a' }, null, { id: 'b' }]
        }
      };
    client.end(JSON.stringify({ result }) + '\n');
  });
  const server = await ready(mockServer.endpoint);
  const state = (await server.handle(call('readit_state', {}))).structuredContent;
  assert.equal(state.control_socket, mockServer.endpoint);
  assert.equal(state.unsaved, true);
  assert.match(state.wait_command, /readit_wait\.py.*--stop-when-idle$/);
  const loaded = await server.handle(call('readit_guide_load', tour([step('a')])));
  const result = loaded.structuredContent;
  assert.deepEqual(result.guide_tour, {
    overview: { title: 'Overview', chapters: 2, claims: 1 },
    steps: ['a', 'b']
  });
});

test('open_folder canonicalizes locally; nonexistent folder has no socket write', async t => {
  const mockServer = await mock(t, (client, request) => {
    client.end(JSON.stringify({ result: request.arguments }) + '\n');
  });
  const server = await ready(mockServer.endpoint);
  const opened = await server.handle(call('readit_open_folder', { path: '.' }));
  assert.equal(opened.structuredContent.path, fs.realpathSync('.'));
  const invalid = await server.handle(call('readit_open_folder', {
    path: path.join(root, 'nonexistent-folder')
  }));
  assert.equal(invalid.isError, true);
  assert.equal(mockServer.requests.length, 1);
});

test('timeout and transport close never resend a mutation; outcome isError', async t => {
  const mockServer = await mock(t, () => {
    // Leave this request pending to exercise the deadline.
  });
  const server = await ready(mockServer.endpoint, { timeout: 25 });
  const result = await server.handle(call('readit_history', {
    workspace: '/w',
    direction: 'forward'
  }));
  assert.equal(result.isError, true);
  assert.match(result.content[0].text, /timed out/);
  assert.equal(mockServer.requests.length, 1);
  const broken = await mock(t, client => {
    client.destroy();
  });
  const brokenServer = await ready(broken.endpoint);
  const failed = await brokenServer.handle(call('readit_history', {
    workspace: '/w',
    direction: 'back'
  }));
  assert.equal(failed.isError, true);
  assert.equal(broken.requests.length, 1);
});

const invalidResponses = [
  ['invalid JSON', '{bad}\n'],
  ['missing result', '{}\n'],
  ['array', '[]\n'],
  ['unsafe integer', '{"result":{"event_sequence":9007199254740993}}\n'],
  ['invalid UTF-8', Buffer.from([0xff, 10])],
  ['unterminated', '{}'],
  ['oversized', Buffer.alloc(MAX_RESPONSE + 1, 120)]
];
for (const [name, response] of invalidResponses) {
  test(`editor response ${name} is a tool error without retry`, async t => {
    const mockServer = await mock(t, client => {
      client.end(response);
    });
    const server = await ready(mockServer.endpoint);
    const result = await server.handle(call('readit_view', { workspace: '/w', wrap: true }));
    assert.equal(result.isError, true);
    assert.equal(mockServer.requests.length, 1);
  });
}

test('editor fragmented UTF-8 response and missing socket errors', async t => {
  const mockServer = await mock(t, client => {
    const bytes = Buffer.from(JSON.stringify({ result: { text: '日本😀' } }) + '\n');
    client.write(bytes.subarray(0, 23));
    client.end(bytes.subarray(23));
  });
  assert.deepEqual(await editorCall(mockServer.endpoint, 'readit_state', {}), { text: '日本😀' });
  const disconnected = await ready(path.join(root, 'absent.sock'));
  assert.equal((await disconnected.handle(call('readit_state', {}))).isError, true);
});

test('oversized editor request is rejected before connection', async () => {
  await assert.rejects(
    editorCall('/unused', 'readit_search', { query: 'x'.repeat(MAX_FRAME) }),
    /request is too large/
  );
});

test('output close aborts in-flight request and destroys only our client', async t => {
  let received;
  const arrived = new Promise(resolve => {
    received = resolve;
  });
  const mockServer = await mock(t, () => {
    received();
  });
  const source = new PassThrough();
  const output = new PassThrough();
  output.resume();
  const serving = serve(mockServer.endpoint, source, output, { timeout: 1000 });
  source.write(encodeFrames([
    init,
    initialized,
    call('readit_history', { workspace: '/w', direction: 'forward' })
  ]));
  await arrived;
  output.destroy();
  await serving;
  assert.equal(mockServer.requests.length, 1);
  assert.equal(source.destroyed, true);
});

test('normal input EOF completes pending response, premature input close cancels it', async t => {
  const mockServer = await mock(t, client => {
    setTimeout(() => {
      if (!client.destroyed) {
        client.end('{"result":{"ok":true}}\n');
      }
    }, 10);
  });
  const frames = encodeFrames([init, initialized, call('readit_state', {})]);
  const source = Readable.from([Buffer.from(frames)]);
  let text = '';
  const output = new Writable({
    write(bytes, _, done) {
      text += bytes;
      done();
    }
  });
  await serve(mockServer.endpoint, source, output);
  assert.equal(text.trim().split('\n').length, 2);
  const hanging = await mock(t, () => {
    // Keep the reply pending until the input closes.
  });
  const input = new PassThrough();
  const out = new PassThrough();
  out.resume();
  const serving = serve(hanging.endpoint, input, out);
  input.write(frames);
  await new Promise(resolve => {
    setTimeout(resolve, 20);
  });
  input.destroy();
  await serving;
});

test('CLI SIGTERM cancels only its connection', { timeout: 3000 }, async t => {
  let arrive;
  const received = new Promise(resolve => {
    arrive = resolve;
  });
  let count = 0;
  const mockServer = await mock(t, client => {
    count += 1;
    if (count === 1) {
      arrive();
    } else {
      client.end('{"result":{"alive":true}}\n');
    }
  });
  const child = spawn(process.execPath, [entry, '--socket', mockServer.endpoint], {
    stdio: ['pipe', 'pipe', 'pipe']
  });
  t.after(() => {
    if (child.exitCode === null) {
      child.kill('SIGKILL');
    }
  });
  let stderr = '';
  child.stderr.on('data', bytes => {
    stderr += bytes;
  });
  child.stdout.resume();
  child.stdin.on('error', () => {
    // The child may close stdin while the parent still holds its pipe.
  });
  child.stdin.write(encodeFrames([
    init,
    initialized,
    call('readit_history', { workspace: '/w', direction: 'forward' })
  ]));
  await received;
  const exited = once(child, 'exit');
  child.kill('SIGTERM');
  assert.deepEqual(await exited, [0, null]);
  assert.equal(stderr, '');
  assert.equal(mockServer.requests.length, 1);
  assert.equal(fs.existsSync(mockServer.endpoint), true);
  assert.deepEqual(await editorCall(mockServer.endpoint, 'readit_state', {}), { alive: true });
});

test('CLI rejects unknown options/launch/duplicate/missing socket without stdout', () => {
  const cases = [
    [],
    ['--launch'],
    ['--socket'],
    ['--socket', 'x', '--launch'],
    ['--socket', 'x', '--socket', 'y'],
    ['--socket', '--bad']
  ];
  for (const args of cases) {
    assert.throws(() => {
      parseArgs(args);
    }, /usage:/);
    const result = spawnSync(process.execPath, [entry, ...args], { encoding: 'utf8' });
    assert.equal(result.status, 1);
    assert.equal(result.stdout, '');
    assert.match(result.stderr, /usage:/);
  }
  assert.equal(parseArgs(['--socket', '/existing.sock']), '/existing.sock');
  const result = spawnSync(process.execPath, [entry, '--socket', '/unused'], {
    input: encodeFrames([req('ping')]),
    encoding: 'utf8'
  });
  assert.equal(result.status, 0);
  assert.equal(result.stderr, '');
  assert.deepEqual(JSON.parse(result.stdout).result, {});
});

// A symlink in an unrelated directory also exercises resource resolution under
// --preserve-symlinks-main: no schema or Python waiter is copied beside the link.
for (const kind of ['physical', 'file symlink', 'directory alias']) {
  for (const preserve of [false, true]) {
    const mode = preserve ? 'preserve-symlinks-main' : 'default resolution';
    test(`CLI initialize via ${kind}, ${mode}`, t => {
      const directory = fs.mkdtempSync(path.join(root, '..', '.mcp-entry-'));
      t.after(() => {
        fs.rmSync(directory, { recursive: true, force: true });
      });
      let invokedEntry = fs.realpathSync(entry);
      if (kind === 'file symlink') {
        invokedEntry = path.join(directory, 'entry.mjs');
        fs.symlinkSync(entry, invokedEntry);
      } else if (kind === 'directory alias') {
        const alias = path.join(directory, 'project');
        fs.symlinkSync(root, alias, 'dir');
        invokedEntry = path.join(alias, 'tools/readit_mcp.mjs');
      }
      const flags = preserve ? ['--preserve-symlinks-main'] : [];
      const input = encodeFrames([
        req('initialize', { protocolVersion: '2025-11-25' }, 'alias-init'),
        initialized,
        req('tools/list', {}, 'alias-tools')
      ]);
      const result = spawnSync(process.execPath, [
        ...flags,
        invokedEntry,
        '--socket',
        '/unused-no-connection'
      ], {
        input,
        encoding: 'utf8',
        timeout: 3000
      });
      assert.equal(result.error, undefined);
      assert.equal(result.status, 0, result.stderr);
      assert.equal(result.stderr, '');
      assert.notEqual(result.stdout.trim(), '', 'CLI must actually reply, not silently exit');
      const replies = result.stdout.trim().split('\n').map(JSON.parse);
      assert.equal(replies.length, 2);
      assert.equal(replies[0].jsonrpc, '2.0');
      assert.equal(replies[0].id, 'alias-init');
      assert.equal(replies[0].error, undefined);
      assert.equal(replies[0].result.protocolVersion, '2025-11-25');
      assert.deepEqual(replies[0].result.serverInfo, { name: 'readit', version: '0.4.0' });
      assert.equal(replies[1].id, 'alias-tools');
      assert.deepEqual(replies[1].result.tools, TOOLS);
    });
  }
}

test('isMain does not treat imports or missing entry paths as CLI launches', () => {
  assert.equal(isMain(entry), true);
  assert.equal(isMain(import.meta.filename), false);
  assert.equal(isMain(''), false);
  assert.equal(isMain(path.join(root, 'missing-entry.mjs')), false);
});
