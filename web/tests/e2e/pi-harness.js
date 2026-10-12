// A pi SDK session with the Readit extension and a scripted model, the way pi's
// own suite tests sessions: the faux provider plays a model that connects to
// nothing and answers from a script. Shared by pi.spec.js and pi-random.spec.js.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { fauxProvider, fauxAssistantMessage, fauxToolCall } from '@earendil-works/pi-ai';
import { createAgentSession, createMcpExtension, DefaultResourceLoader, ModelRuntime, SessionManager, SettingsManager } from '@earendil-works/pi-coding-agent';
import { expect, ok, repo, python } from './fixture.js';

export const tool = (name) => `mcp__readit__readit_${name}`;
export const call = (name, args) => fauxAssistantMessage(fauxToolCall(tool(name), args), { stopReason: 'toolUse' });
export const text = (message) => (typeof message.content === 'string' ? message.content : message.content.filter((c) => c.type === 'text').map((c) => c.text).join('\n'));
/** The newest tool result the model can see: its parsed JSON, or { error } when the tool failed. */
export function lastResult(context) {
  const message = context.messages.filter((m) => m.role === 'toolResult').at(-1);
  const body = text(message);
  if (message.isError) return { error: body };
  try { return JSON.parse(body); } catch { return { error: body }; }
}
/** The JSON line readit_wait.py printed, which the watcher appends to the prompt it delivers. */
export const delivered = (context) => JSON.parse(text(context.messages.filter((m) => m.role === 'user').at(-1)).trim().split('\n').at(-1));
export const step = (id, line, expected, extra = {}) => ({ id, title: id, body: `${id} の解説`, path: 'sample.py', line, column: 1, expected_text: expected, ...extra });
export const state = (readit) => ok(readit.socketPath, 'readit_state');

/** Start a session joined to the test's Readit (READIT_SOCKET) instead of launching one. */
export async function startPi(readit) {
  process.env.READIT_SOCKET = readit.socketPath;
  process.env.READIT_PYTHON = python;
  // The extension reads READIT_SOCKET when it loads, so each test gets a fresh module instance.
  const extension = (await import(`${pathToFileURL(path.join(repo, 'integrations/pi/index.ts')).href}?socket=${Date.now()}`)).default;
  const faux = fauxProvider();
  const agentDir = fs.mkdtempSync(path.join(os.tmpdir(), 'readit-pi-agent-'));
  const modelRuntime = await ModelRuntime.create({ authPath: path.join(agentDir, 'auth.json'), modelsPath: null, refreshOnCreate: false });
  modelRuntime.registerNativeProvider(faux.provider);
  await modelRuntime.setRuntimeApiKey(faux.provider.id, 'faux-key');
  const resourceLoader = new DefaultResourceLoader({
    cwd: readit.project, agentDir, extensionFactories: [createMcpExtension(), extension],
    noSkills: true, noThemes: true, noPromptTemplates: true, noContextFiles: true,
  });
  await resourceLoader.reload();
  const { session } = await createAgentSession({
    cwd: readit.project, agentDir, modelRuntime, model: faux.getModel(), resourceLoader,
    sessionManager: SessionManager.inMemory(), settingsManager: SettingsManager.inMemory(), noTools: 'builtin',
  });
  await session.bindExtensions({});
  return {
    session, faux,
    userTexts: () => session.messages.filter((m) => m.role === 'user').map(text),
    toolCalls: () => session.messages.filter((m) => m.role === 'assistant').flatMap((m) => m.content.filter((c) => c.type === 'toolCall').map((c) => c.name)),
    /** Run one scripted turn and check that the model used up its script. */
    async turn(prompt, responses) {
      faux.setResponses(responses);
      await session.prompt(prompt);
      expect(faux.getPendingResponseCount()).toBe(0);
    },
    /** Wait until the watcher has delivered `count` prompts and the model has finished reacting. */
    async settled(count, timeout = 20_000) {
      await expect.poll(() => session.messages.filter((m) => m.role === 'user').length, { timeout }).toBe(count);
      await expect.poll(() => session.isIdle && faux.getPendingResponseCount() === 0, { timeout }).toBe(true);
    },
    async stop() {
      // The CLI emits session_shutdown on quit; it stops the watcher and the MCP server.
      await session.extensionRunner.emit({ type: 'session_shutdown', reason: 'quit' });
      session.dispose();
      fs.rmSync(agentDir, { recursive: true, force: true });
    },
  };
}
