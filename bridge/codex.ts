// Codex has no Claude-style MCP channel. Deliver through its supported queue
// command into one explicitly bound chat, preserving the host's permissions.
import { spawn, type ChildProcess } from "node:child_process";

export interface CodexOptions {
  threadId: string;
  binary: string;
  remote: string;
  authTokenEnv?: string;
}

export function codexOptions(env: NodeJS.ProcessEnv, threadId?: string): CodexOptions {
  const id = threadId || env.TAVERN_CODEX_THREAD_ID || env.CODEX_THREAD_ID;
  if (!id || !/^[a-zA-Z0-9_-]{1,128}$/.test(id)) {
    throw new Error("Codex push needs a thread UUID: pass thread_id to join_room or set TAVERN_CODEX_THREAD_ID / CODEX_THREAD_ID.");
  }
  // An explicit endpoint is essential: never let queue create a separate local
  // daemon and resume a transcript that is already running in another host.
  const remote = env.TAVERN_CODEX_REMOTE || "unix://";
  if (!remote.startsWith("unix://")) {
    const url = new URL(remote);
    const local = ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
    if ((url.protocol !== "ws:" && url.protocol !== "wss:") || (url.protocol === "ws:" && !local) || url.username || url.password) {
      throw new Error("TAVERN_CODEX_REMOTE must be a local ws://, unix://, or secure wss:// endpoint without embedded credentials.");
    }
  }
  const authTokenEnv = env.TAVERN_CODEX_REMOTE_AUTH_TOKEN_ENV;
  if (authTokenEnv && (!remote || !/^[a-zA-Z_][a-zA-Z0-9_]*$/.test(authTokenEnv))) {
    throw new Error("TAVERN_CODEX_REMOTE_AUTH_TOKEN_ENV needs a remote endpoint and an environment variable name.");
  }
  return { threadId: id, binary: env.TAVERN_CODEX_BIN || "codex", remote, authTokenEnv };
}

export class CodexPush {
  private pending: { id: number; content: string; isCurrent?: () => Promise<boolean> }[] = [];
  private seen = new Set<number>();
  private accepted = new Set<number>();
  private child: ChildProcess | null = null;
  private busy = false;
  private closed = false;
  error = "";

  constructor(readonly options: CodexOptions, private onError: (message: string) => void, private timeoutMs = 15_000) {}

  get active() { return !this.closed && !this.error; }

  // Suppress a second delivery through read_messages while a push is pending
  // or accepted. Failed deliveries remain in the ordinary unread history.
  owns(id: number) { return this.active && this.seen.has(id); }
  confirmed(id: number) { return this.accepted.has(id); }

  enqueue(id: number, content: string, isCurrent?: () => Promise<boolean>) {
    if (!this.active || this.seen.has(id)) return;
    this.seen.add(id);
    this.pending.push({ id, content, isCurrent });
    void this.drain();
  }

  private async drain() {
    if (this.busy) return;
    this.busy = true;
    try {
      while (this.active && this.pending.length) {
        const next = this.pending.shift()!;
        if (next.isCurrent && !(await next.isCurrent())) {
          this.seen.delete(next.id);
          continue;
        }
        if (!this.active) break;
        await this.deliver(next.content);
        this.accepted.add(next.id);
        // Bounded duplicate tracking for a long-lived chat.
        if (this.accepted.size > 2000) {
          const oldest = this.accepted.values().next().value!;
          this.accepted.delete(oldest);
          this.seen.delete(oldest);
        }
      }
    } catch (e) {
      if (!this.closed) {
        this.error = e instanceof Error ? e.message : String(e);
        this.pending.length = 0;
        this.onError(this.error);
      }
    } finally { this.busy = false; }
  }

  private deliver(content: string): Promise<void> {
    const args = ["queue", "--thread", this.options.threadId, "--message", content];
    args.push("--remote", this.options.remote);
    if (this.options.authTokenEnv) args.push("--remote-auth-token-env", this.options.authTokenEnv);
    return new Promise((resolve, reject) => {
      // No shell, interpolated commands, model overrides, or permission overrides.
      const child = spawn(this.options.binary, args, { stdio: "ignore", windowsHide: true });
      this.child = child;
      let timedOut = false;
      let settled = false;
      const timer = setTimeout(() => { timedOut = true; child.kill(); }, this.timeoutMs);
      const finish = (error?: Error) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        if (this.child === child) this.child = null;
        error ? reject(error) : resolve();
      };
      child.once("error", (e: NodeJS.ErrnoException) => finish(new Error(`Codex queue could not start (${e.code || "unknown error"}). Check TAVERN_CODEX_BIN.`)));
      child.once("exit", (code, signal) => {
        if (timedOut) finish(new Error("Codex queue timed out; delivery was not confirmed. Check the Codex host connection."));
        else if (code !== 0) finish(new Error(`Codex queue failed (${signal || "exit " + code}). Check the target chat and Codex host connection.`));
        else finish();
      });
    });
  }

  close() {
    this.closed = true;
    this.pending.length = 0;
    this.child?.kill();
  }
}
