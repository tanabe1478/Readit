// Readit for pi: connects the Readit MCP server and forwards questions from
// guide bubbles into the session, so the user does not have to announce them.
import path from "node:path";
import os from "node:os";
import { randomBytes } from "node:crypto";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { ReaditWatcher } from "./watcher.ts";

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const python = process.env.READIT_PYTHON || "python3";
// By default this session launches a Readit of its own, so other sessions keep
// their own windows and tours. READIT_SOCKET instead joins an existing Readit.
const shared = process.env.READIT_SOCKET;
const socket = shared ||
  path.join(os.homedir(), ".readit/sessions", `pi-${process.pid}-${randomBytes(2).toString("hex")}.sock`);
const mcpArgs = shared
  ? ["--socket", shared]
  : ["--launch", "--socket", socket, "--label", "pi", "--workspace", process.cwd()];

export default function readit(pi: ExtensionAPI): void {
  // The same MCP server Claude Code uses. An entry named "readit" in mcp.json takes precedence.
  pi.registerMcpServer("readit", {
    command: python,
    args: [path.join(repo, "tools/readit_mcp.py"), ...mcpArgs],
    exposure: "direct",
  });

  let context: ExtensionContext | undefined;
  const watcher = new ReaditWatcher({
    python,
    script: path.join(repo, "tools/readit_wait.py"),
    socket,
    deliver: (prompt) => {
      // A busy agent gets the question after its current work instead of being interrupted.
      pi.sendUserMessage(prompt, context && !context.isIdle() ? { deliverAs: "followUp" } : undefined);
      context?.ui.notify("Readit: 質問をセッションへ送りました", "info");
    },
    notify: (message, type) => context?.ui.notify(message, type),
    onStatus: (text) => context?.ui.setStatus("readit", text),
  });

  pi.on("session_start", async (_event, ctx) => {
    context = ctx;
    if (process.env.READIT_WATCH !== "0") watcher.start();
  });
  pi.on("session_shutdown", async () => {
    watcher.stop();
  });
  pi.registerCommand("readit-watch", {
    description: "Readit のガイドの質問をこのセッションで受け取る (on / off / status)",
    handler: async (arg, ctx) => {
      context = ctx;
      const mode = (arg ?? "").trim();
      if (mode === "off") watcher.stop();
      else if (mode === "on" || mode === "") watcher.start();
      ctx.ui.notify(`Readit: ${watcher.active ? `質問を待機中 (${socket})` : "待機していません"}`, "info");
    },
  });
}
