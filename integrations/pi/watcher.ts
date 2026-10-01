// Runs tools/readit_wait.py in a loop and hands each guide question to the
// session. Independent of pi so it can be tested with plain Node.
import { spawn, type ChildProcess } from "node:child_process";

export type WaitResult = {
  status: "question" | "next" | "ended" | "truncated" | "timeout";
  latest_sequence: number;
  workspace?: string | null;
  tour_id?: string | null;
  guide_id?: string | null;
  event?: Record<string, unknown>;
};

export type WatcherOptions = {
  python: string;
  script: string;
  socket: string;
  /** Deliver a prompt to the agent. */
  deliver: (prompt: string) => void;
  /** Tell the user something without involving the agent. */
  notify: (message: string, type?: "info" | "warning" | "error") => void;
  onStatus?: (text: string | undefined) => void;
  /** Delay before retrying after the waiter fails. */
  retryMs?: number;
};

/** The prompt the agent receives. It names the tools to use; the skill has the details. */
export function formatPrompt(result: WaitResult): string {
  const event = result.event ?? {};
  const where = `${event.path ?? ""}:${event.line ?? "?"}-${event.end_line ?? "?"}`;
  if (result.status === "next") {
    return [
      "Readit: the user pressed Next on a guide bubble (a single readit_guide_show explanation).",
      `Current step: ${event.id ?? ""} at ${where}.`,
      "Continue the walkthrough with the readit-guide skill: read readit_state and readit_guide_events, then show the next explanation with readit_guide_show using the latest event_sequence.",
      "",
      JSON.stringify(result),
    ].join("\n");
  }
  const tour = result.tour_id
    ? `This is prepared tour "${result.tour_id}". Answer with readit_guide_revise (question_sequence ${event.sequence}); keep the unread steps unless the question calls for a different route, and include the full overview if the tour has one.`
    : `This is a single bubble. Answer with readit_guide_answer (id ${event.id}, question_sequence ${event.sequence}).`;
  return [
    "Readit: the user asked a question in a guide bubble.",
    `Question: ${event.question ?? ""}`,
    `Step: ${event.title ?? event.id ?? ""} at ${where}`,
    tour,
    "Use the readit-guide skill: read the relevant source first, then re-read readit_state and readit_guide_events before submitting.",
    "",
    JSON.stringify(result),
  ].join("\n");
}

export class ReaditWatcher {
  private child: ChildProcess | undefined;
  private timer: ReturnType<typeof setTimeout> | undefined;
  private after: number | undefined;
  private running = false;
  private readonly options: WatcherOptions;

  constructor(options: WatcherOptions) {
    this.options = options;
  }

  get active(): boolean {
    return this.running;
  }

  start(): void {
    if (this.running) return;
    this.running = true;
    this.options.onStatus?.("Readit: 質問を待機中");
    this.spawnWaiter();
  }

  stop(): void {
    this.running = false;
    if (this.timer) clearTimeout(this.timer);
    this.timer = undefined;
    this.child?.kill();
    this.child = undefined;
    this.options.onStatus?.(undefined);
  }

  private spawnWaiter(): void {
    if (!this.running) return;
    // Wait forever: the session owns this process and stops it on shutdown.
    const args = [this.options.script, "--socket", this.options.socket, "--timeout", "0"];
    if (this.after !== undefined) args.push("--after", String(this.after));
    const child = spawn(this.options.python, args, { stdio: ["ignore", "pipe", "ignore"] });
    this.child = child;
    let output = "";
    child.stdout!.setEncoding("utf8");
    child.stdout!.on("data", (chunk: string) => { output += chunk; });
    child.on("error", (error) => {
      if (this.child !== child) return;
      this.child = undefined;
      this.options.notify(`Readit: 待機を開始できません: ${error.message}`, "error");
      this.retry();
    });
    child.on("exit", (code) => {
      if (this.child !== child) return;
      this.child = undefined;
      if (!this.running) return;
      const line = output.trim().split("\n").pop() ?? "";
      let result: WaitResult;
      try {
        result = JSON.parse(line);
      } catch {
        this.options.notify(`Readit: 待機が異常終了しました (${code})`, "warning");
        this.retry();
        return;
      }
      this.handle(result);
    });
  }

  private retry(): void {
    if (!this.running) return;
    this.timer = setTimeout(() => this.spawnWaiter(), this.options.retryMs ?? 5000);
  }

  private handle(result: WaitResult): void {
    this.after = result.latest_sequence;
    if (result.status === "question" || result.status === "next") {
      this.options.deliver(formatPrompt(result));
    } else if (result.status === "truncated") {
      this.options.notify("Readit: 取りこぼした操作があります。readit_state で状態を確認してください。", "warning");
    }
    this.spawnWaiter();
  }
}
