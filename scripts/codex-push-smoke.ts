#!/usr/bin/env bun
// Real hub + stdio MCP bridges, with a fake Codex queue command. No model calls,
// session changes, real-room traffic, or Codex credential/database access.
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { mkdtempSync, mkdirSync, copyFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { z } from "zod";
import { CodexPush, codexOptions } from "../bridge/codex.js";

const root = resolve(import.meta.dir, "..");
const reservation = Bun.serve({ port: 0, hostname: "127.0.0.1", fetch: () => new Response() });
const port = reservation.port!;
reservation.stop(true);
const data = mkdtempSync(join(tmpdir(), "tavern-codex-"));
const cwd = join(data, "fake-host");
mkdirSync(cwd);
copyFileSync(join(root, "scripts/fixtures/codex-queue.ts"), join(cwd, "queue"));
const log = join(data, "queue.jsonl");
const env = { ...process.env, TAVERN_PORT: String(port), TAVERN_DATA: data, TAVERN_REPLY_TIMEOUT_MS: "5000", TAVERN_AUTOJOIN: "", TAVERN_QUEUE_TEST_LOG: log, TAVERN_CODEX_BIN: process.execPath, TAVERN_CODEX_THREAD_ID: "test-chat-123", CODEX_THREAD_ID: "", TAVERN_CODEX_REMOTE: "", TAVERN_CODEX_REMOTE_AUTH_TOKEN_ENV: "" } as Record<string, string>;
const base = `http://127.0.0.1:${port}`;
const hub = Bun.spawn([process.execPath, join(root, "hub/hub.ts")], { env, stdout: "pipe", stderr: "pipe" });
const clients: Client[] = [];
let failures = 0;
function check(label: string, ok: boolean) { console.log(`${ok ? "PASS" : "FAIL"} ${label}`); if (!ok) failures++; }
function records(): { args: string[]; ts: number }[] { try { return readFileSync(log, "utf8").trim().split("\n").filter(Boolean).map(s => JSON.parse(s)); } catch { return []; } }
async function until(test: () => boolean | Promise<boolean>, label: string) {
  const end = Date.now() + 5000;
  while (Date.now() < end) { if (await test()) return; await Bun.sleep(25); }
  throw new Error(`timed out: ${label}`);
}
async function get(path: string) { return (await (await fetch(base + path)).json()) as any; }
async function post(path: string, body: unknown, token?: string) {
  const r = await fetch(base + path, { method: "POST", headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) }, body: JSON.stringify(body) });
  if (!r.ok) throw new Error(`${path}: ${r.status}: ${await r.text()}`);
  return await r.json() as any;
}
const call = (c: Client, name: string, args: any = {}) => c.callTool({ name, arguments: args });
const textOf = (r: any) => r.content.filter((c: any) => c.type === "text").map((c: any) => c.text).join("\n");
async function agent(clientName: string, extra: Record<string, string>) {
  const c = new Client({ name: clientName, version: "1" });
  await c.connect(new StdioClientTransport({ command: process.execPath, args: [join(root, "bridge/bridge.ts")], env: { ...env, ...extra }, cwd }));
  clients.push(c);
  return c;
}

try {
  await until(async () => { try { return (await get("/api/health")).ok; } catch { return false; } }, "test hub");
  const a = await agent("claude-code", { TAVERN_CHANNELS: "claude,codex" });
  const pushes: any[] = [];
  a.setNotificationHandler(z.object({ method: z.literal("notifications/claude/channel"), params: z.object({ content: z.string(), meta: z.record(z.string(), z.string()) }) }), n => { pushes.push(n.params); });
  await call(a, "join_room", { name: "Ada" });
  const b = await agent("codex-mcp-client", { TAVERN_CHANNELS: "codex" });
  const joined = textOf(await call(b, "join_room", { name: "Bolt", thread_id: "explicit-chat-456" }));
  check("Codex push is explicitly configured on join", joined.includes("Codex push configured"));
  check("Codex does not advertise Claude channels", !(b.getServerCapabilities()?.experimental as any)?.["claude/channel"]);
  const start = Date.now();
  check("push mode avoids a competing wait loop", textOf(await call(b, "wait_for_messages", { timeout_seconds: 10 })).includes("do not also wait") && Date.now() - start < 1000);
  const human = await post("/api/join", { name: "Human", kind: "human", client: "test-ui" });
  const prompt = (text: string) => post("/api/messages", { text }, human.token);
  const awkward = '@Bolt quotes "hello", `backticks`, $(not-a-command), and a newline\nsecond line';
  await prompt(awkward);
  await until(() => records().length === 1, "first push");
  const first = records()[0].args;
  check("explicit thread binding overrides inherited setting", first[0] === "--thread" && first[1] === "explicit-chat-456");
  check("room text is one literal command argument", first[2] === "--message" && first[3].includes(awkward) && first.length === 6);
  check("queue connects to an existing host instead of starting another", first[4] === "--remote" && first[5] === "unix://");
  await Bun.sleep(100);
  check("already pushed messages are not redelivered by read_messages", !textOf(await call(b, "read_messages")).includes(awkward));
  await call(b, "send_message", { text: "First answer" });
  await call(b, "list_members");
  await prompt("@Bolt still listening after a roster lookup?");
  await until(() => records().length === 2, "second push");
  check("ordinary tools leave push delivery running", records().length === 2);
  await call(b, "send_message", { text: "Still here" });
  await prompt("@Ada Claude path check");
  await until(() => pushes.some(p => p.content.includes("Claude path check")), "Claude push");
  await Bun.sleep(100);
  check("Claude channel works with Codex support installed", records().length === 2);
  await call(a, "send_message", { text: "Claude answer" });
  await call(a, "send_message", { text: "unaddressed agent chatter" });
  await Bun.sleep(100);
  check("unaddressed agent chatter is not queued", records().length === 2);
  await call(a, "send_message", { text: "@Bolt an agent mention" });
  await until(() => records().length === 3, "agent mention push");
  for (let i = 0; i < 8; i++) await call(a, "send_message", { text: `@Bolt streak ${i}` });
  await Bun.sleep(500);
  check("agent streak limit also applies to Codex push", records().length < 11);
  const beforeRoom = records().length;
  const room = (await prompt("A question for the whole table")).message;
  check("room-wide prompt invites both agents", room.floor.join() === "Ada,Bolt");
  await until(() => records().slice(beforeRoom).some(r => r.args[3].includes("question for the whole table")) && pushes.some(p => p.content.includes("question for the whole table")), "room-wide delivery");
  check("both delivery paths receive a room-wide prompt at once", records().slice(beforeRoom).some(r => r.args[3].includes("[your turn to reply]: A question for the whole table")) && pushes.some(p => p.content.includes("A question for the whole table")));
  await call(a, "send_message", { text: "Ada room reply" });
  await call(b, "send_message", { text: "Bolt room reply" });
  const beforeAll = records().length;
  await prompt("@all one reply each");
  await until(() => records().length === beforeAll + 1 && pushes.some(p => p.content.includes("one reply each")), "all delivery");
  await call(a, "send_message", { text: "Ada all reply" });
  await call(b, "send_message", { text: "Bolt all reply" });
  check("both delivery paths complete their assigned replies", (await get("/api/conversation")).conversation.status === "complete");
  const beforeLeave = records().length;
  await call(b, "leave_room");
  await prompt("@Bolt nobody should queue this");
  await Bun.sleep(150);
  check("leaving stops Codex delivery", records().length === beforeLeave);

  const missing = await agent("codex-mcp-client", { TAVERN_CHANNELS: "codex", TAVERN_CODEX_THREAD_ID: "", CODEX_THREAD_ID: "" });
  check("missing binding is explained and leaves polling available", textOf(await call(missing, "join_room", { name: "Missing" })).includes("Codex push unavailable"));
  await call(missing, "read_messages");
  const wait = call(missing, "wait_for_messages", { timeout_seconds: 3 });
  await prompt("@Missing polling fallback works");
  check("missing binding really falls back to normal waiting", textOf(await wait).includes("polling fallback works"));
  await call(missing, "leave_room");

  const failing = await agent("codex-mcp-client", { TAVERN_CHANNELS: "codex", TAVERN_QUEUE_TEST_DELAY_MS: "600", TAVERN_QUEUE_TEST_EXIT: "2" });
  await call(failing, "join_room", { name: "Failing" });
  const beforeFailure = records().length;
  await prompt("@Failing retain this failed delivery");
  await until(() => records().length > beforeFailure, "failed command started");
  await call(failing, "read_messages"); // Advance the normal cursor while push is pending.
  await until(async () => (await get("/api/members")).members.some((m: any) => m.name === "Failing" && m.status.includes("push failed")), "visible failure");
  const fallback = textOf(await call(failing, "read_messages"));
  check("queue failure is visible in tool results", fallback.includes("Codex push unavailable") && fallback.includes("exit 2"));
  check("failed pending messages survive a read cursor advance", fallback.includes("retain this failed delivery"));
  const countAfterFailure = records().length;
  await prompt("@Failing use polling after failure");
  check("failed adapter permits ordinary wait_for_messages", textOf(await call(failing, "wait_for_messages", { timeout_seconds: 2 })).includes("use polling after failure"));
  await Bun.sleep(100);
  check("failed delivery is not blindly retried into duplicate turns", records().length === countAfterFailure);
  await call(a, "leave_room");
  await call(failing, "leave_room");
  const beforeLate = records().length;
  await prompt("Recover the original question when a Codex agent joins late");
  const late = await agent("codex-mcp-client", { TAVERN_CHANNELS: "codex" });
  const lateJoin = textOf(await call(late, "join_room", { name: "Late" }));
  await until(() => records().length === beforeLate + 1, "connection catch-up");
  await Bun.sleep(150);
  check("connection catch-up delivers one current prompt", records().length === beforeLate + 1 && records().at(-1)!.args[3].includes("Recover the original question"));
  check("join history does not duplicate a prompt queued by catch-up", !lateJoin.includes(": Recover the original question"));
  await call(late, "send_message", { text: "Late answer" });
  await call(late, "leave_room");
  const slow = await agent("codex-mcp-client", { TAVERN_CHANNELS: "codex", TAVERN_QUEUE_TEST_DELAY_MS: "600" });
  await call(slow, "join_room", { name: "Slow" });
  const beforeSlow = records().length;
  await prompt("@Slow first command in flight");
  await until(() => records().length === beforeSlow + 1, "slow first command");
  await prompt("@Slow superseded intermediate prompt");
  await call(slow, "read_messages");
  await prompt("@Slow latest prompt should be delivered");
  await until(() => records().some(r => r.args[3].includes("latest prompt should be delivered")), "latest prompt");
  await Bun.sleep(700);
  check("superseded queued prompts are checked again before delivery", !records().some(r => r.args[3].includes("superseded intermediate prompt")));
  check("cancelled pending prompts remain readable as history", textOf(await call(slow, "read_messages")).includes("superseded intermediate prompt"));
  await call(slow, "leave_room");

  const opts = codexOptions({ TAVERN_CODEX_THREAD_ID: "bound-chat", TAVERN_CODEX_REMOTE: "wss://codex.example/socket", TAVERN_CODEX_REMOTE_AUTH_TOKEN_ENV: "TEST_TOKEN" });
  check("remote auth uses an environment variable reference", opts.authTokenEnv === "TEST_TOKEN");
  let refused = false;
  try { codexOptions({ CODEX_THREAD_ID: "bound-chat", TAVERN_CODEX_REMOTE: "ws://public.example" }); } catch { refused = true; }
  check("unencrypted non-local Codex endpoints are rejected", refused);
  let missingError = "";
  const missingBinary = new CodexPush({ threadId: "test-chat", binary: join(data, "missing-codex-executable"), remote: "unix://" }, e => { missingError = e; });
  missingBinary.enqueue(1, "test");
  await until(() => !!missingError, "missing executable");
  check("missing executable gives a useful fallback error", missingError.includes("ENOENT") && !missingBinary.active);
  missingBinary.close();

  const previousCwd = process.cwd();
  const previousLog = process.env.TAVERN_QUEUE_TEST_LOG;
  const previousDelay = process.env.TAVERN_QUEUE_TEST_DELAY_MS;
  let timeoutError = "";
  const timeoutAdapter = new CodexPush({ threadId: "test-chat", binary: process.execPath, remote: "unix://" }, e => { timeoutError = e; }, 50);
  try {
    process.chdir(cwd);
    process.env.TAVERN_QUEUE_TEST_LOG = log;
    process.env.TAVERN_QUEUE_TEST_DELAY_MS = "5000";
    timeoutAdapter.enqueue(1, "timeout test");
    await until(() => !!timeoutError, "command timeout");
    check("an unresponsive Codex host cannot hang delivery forever", timeoutError.includes("timed out") && !timeoutAdapter.active);
  } finally {
    timeoutAdapter.close();
    process.chdir(previousCwd);
    if (previousLog === undefined) delete process.env.TAVERN_QUEUE_TEST_LOG; else process.env.TAVERN_QUEUE_TEST_LOG = previousLog;
    if (previousDelay === undefined) delete process.env.TAVERN_QUEUE_TEST_DELAY_MS; else process.env.TAVERN_QUEUE_TEST_DELAY_MS = previousDelay;
  }
  console.log(failures ? `${failures} Codex delivery failure(s)` : "all Codex push checks passed");
} finally {
  await Promise.allSettled(clients.map(c => c.close()));
  hub.kill();
  await hub.exited;
  const resolved = resolve(data);
  if (!resolved.startsWith(resolve(tmpdir()) + (process.platform === "win32" ? "\\" : "/")) || !resolved.includes("tavern-codex-")) throw new Error("unsafe test cleanup target");
  rmSync(resolved, { recursive: true, force: true });
}
process.exitCode = failures ? 1 : 0;
