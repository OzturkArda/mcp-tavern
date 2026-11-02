#!/usr/bin/env bun
// Real HTTP/WebSocket/MCP integration checks for neutral conversation routing.
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { z } from "zod";
const root = resolve(import.meta.dir, "..");
const reservation = Bun.serve({ port: 0, hostname: "127.0.0.1", fetch: () => new Response("reserved") });
const port = reservation.port!;
reservation.stop(true);
const data = mkdtempSync(join(tmpdir(), "tavern-conversation-"));
const env = { ...process.env, TAVERN_PORT: String(port), TAVERN_DATA: data, TAVERN_REPLY_TIMEOUT_MS: "1200" } as Record<string, string>;
const base = `http://127.0.0.1:${port}`;
const clients: Client[] = [];
let failures = 0;
const hub = Bun.spawn([process.execPath, join(root, "hub/hub.ts")], { env, stdout: "pipe", stderr: "pipe" });
function check(label: string, ok: boolean) { console.log(`${ok ? "PASS" : "FAIL"} ${label}`); if (!ok) failures++; }
function textOf(r: any) { return r.content.filter((c: any) => c.type === "text").map((c: any) => c.text).join("\n"); }
async function get(path: string) { return await (await fetch(base + path)).json() as any; }
async function post(path: string, body: unknown, token?: string) {
  const r = await fetch(base + path, { method: "POST", headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) }, body: JSON.stringify(body) });
  if (!r.ok) throw new Error(`${path}: ${r.status} ${await r.text()}`);
  return await r.json() as any;
}
const call = (c: Client, name: string, args: any = {}) => c.callTool({ name, arguments: args });
async function prompt(text: string, token: string) { return (await post("/api/messages", { text }, token)).message; }
try {
  let ready = false;
  for (let i = 0; i < 60; i++) { try { if ((await get("/api/health")).ok) { ready = true; break; } } catch {} await Bun.sleep(50); }
  if (!ready) throw new Error("test hub did not start");
  for (const name of ["Alpha", "Beta"]) {
    const c = new Client({ name: "neutral-client", version: "1" });
    await c.connect(new StdioClientTransport({ command: process.execPath, args: [join(root, "bridge/bridge.ts")], env: { ...env, TAVERN_CHANNELS: name === "Alpha" ? "claude" : "" } }));
    clients.push(c);
    await call(c, "join_room", { name });
  }
  const [a, b] = clients;
  const pushes: any[] = [];
  a.setNotificationHandler(z.object({ method: z.literal("notifications/claude/channel"), params: z.object({ content: z.string(), meta: z.record(z.string(), z.string()) }) }), n => { pushes.push(n.params); });
  const human = await post("/api/join", { name: "Human", kind: "human", client: "test-ui" });
  await Bun.sleep(80);
  const first = await prompt("A room-wide question", human.token);
  check("room-wide prompt invites every agent", first.floor.join() === "Alpha,Beta");
  const readA = textOf(await call(a, "read_messages"));
  check("selected responder sees explicit turn hint", readA.includes("[your turn to reply]"));
  let c = (await get("/api/conversation")).conversation;
  check("authenticated read records delivery receipt", c.received.includes("Alpha"));
  await call(a, "update_turn", { message_id: first.id, state: "working" });
  check("working state is observable", (await get("/api/conversation")).conversation.working.includes("Alpha"));
  const originalDeadline = (await get("/api/conversation")).conversation.deadline;
  let renewed = true;
  for (let i = 0; i < 25; i++) {
    await Bun.sleep(100);
    if ((await call(a, "update_turn", { message_id: first.id, state: "working" })).isError) renewed = false;
  }
  c = (await get("/api/conversation")).conversation;
  check("working heartbeats prevent premature fallback", renewed && c.deadline > originalDeadline && c.floor.includes("Alpha"));

  await call(a, "send_message", { text: "First answer" });
  c = (await get("/api/conversation")).conversation;
  check("one answer leaves the other agent's turn open", c.status === "waiting" && c.replied.includes("Alpha") && c.floor.join() === "Beta");
  await call(b, "send_message", { text: "Second answer" });
  c = (await get("/api/conversation")).conversation;
  check("room-wide prompt completes when every agent has answered", c.status === "complete" && c.floor.length === 0 && c.replied.join() === "Alpha,Beta");

  const second = await prompt("Another room-wide question", human.token);
  check("every room-wide prompt invites every agent", second.floor.join() === "Alpha,Beta");
  await call(b, "update_turn", { message_id: second.id, state: "passed" });
  await call(a, "send_message", { text: "Alpha answers alone" });
  c = (await get("/api/conversation")).conversation;
  check("a pass doesn't block the others", c.status === "complete" && c.passed.includes("Beta") && c.replied.includes("Alpha"));
  check("superseded prompt cannot be updated", !!(await call(a, "update_turn", { message_id: first.id, state: "working" })).isError);

  await prompt("Room-wide question three", human.token);
  await call(a, "send_message", { text: "Alpha is quick" });
  const fourth = await prompt("And a new topic", human.token);
  check("an unaddressed prompt starts a new round for everyone", fourth.replyTo === undefined && fourth.floor.join() === "Alpha,Beta" && (await get("/api/conversation")).conversation.messageId === fourth.id);
  await call(a, "send_message", { text: "Alpha on the new topic" });
  await call(b, "send_message", { text: "Beta on the new topic" });

  await call(b, "read_messages");
  const directed = await prompt("@Alpha please answer this one", human.token);
  check("directed prompt selects the named agent", directed.floor.join() === "Alpha");
  check("non-owner cannot mark or pass a turn", !!(await call(b, "update_turn", { message_id: directed.id, state: "passed" })).isError);
  let betaWoke = false;
  const quiet = call(b, "wait_for_messages", { timeout_seconds: 1 }).then(r => { betaWoke = true; return r; });
  await Bun.sleep(180);
  check("unselected MCP client stays asleep", !betaWoke);
  await call(a, "send_message", { text: "Directed answer" });
  await quiet;
  check("push channel receives the same turn hint", pushes.some(p => p.content.includes("please answer this one") && p.content.includes("[your turn to reply]")));

  const all = await prompt("@all opinions please", human.token);
  check("@all selects every agent", all.floor.join() === "Alpha,Beta");
  await call(a, "send_message", { text: "Alpha opinion" });
  check("@all keeps the other responder's turn", (await get("/api/conversation")).conversation.floor.join() === "Beta");
  await call(a, "read_messages");
  await call(b, "read_messages");
  let alphaWoke = false;
  const alphaQuiet = call(a, "wait_for_messages", { timeout_seconds: 1 }).then(r => { alphaWoke = true; return r; });
  const betaFollowup = call(b, "wait_for_messages", { timeout_seconds: 3 });
  const nudge = await prompt("?", human.token);
  const followupRead = textOf(await betaFollowup);
  c = (await get("/api/conversation")).conversation;
  check("unaddressed follow-up preserves unfinished @all", nudge.replyTo === all.id && c.messageId === all.id && c.floor.join() === "Beta" && c.replied.includes("Alpha"));
  check("remaining responder receives follow-up with original prompt", followupRead.includes("[follow-up to #"+all.id+"]") && c.received.includes("Beta"));
  await Bun.sleep(150);
  check("already-replied agent is not woken by the follow-up", !alphaWoke);
  await call(b, "send_message", { text: "Beta opinion" });
  await alphaQuiet;
  check("@all completes after both reply", (await get("/api/conversation")).conversation.status === "complete");

  const timeout = await prompt("A timeout question", human.token);
  for (let i = 0; i < 65; i++) {
    c = (await get("/api/conversation")).conversation;
    if (c.status !== "waiting") break;
    await Bun.sleep(50);
  }
  check("silent agents time out together", c.messageId === timeout.id && c.status === "unanswered" && c.passed.join() === "Alpha,Beta");

  const fixed = await prompt("@Alpha directed timeout", human.token);
  for (let i = 0; i < 65; i++) {
    c = (await get("/api/conversation")).conversation;
    if (c.status === "unanswered") break;
    await Bun.sleep(50);
  }
  check("directed timeout does not switch to an unrequested agent", c.messageId === fixed.id && c.status === "unanswered" && c.floor.length === 0);

  const leaving = await prompt("@all departure test", human.token);
  await call(b, "send_message", { text: "Beta final opinion" });
  await a.close();
  await Bun.sleep(150);
  c = (await get("/api/conversation")).conversation;
  check("departure clears its pending turn", c.messageId === leaving.id && !c.floor.includes("Alpha") && c.passed.includes("Alpha"));

  const lone = await prompt("Only Beta remains", human.token);
  check("room-wide prompt skips departed agents", lone.floor.join() === "Beta");
  await call(b, "send_message", { text: "Lone answer" });
  await b.close();
  await Bun.sleep(150);
  const empty = await prompt("Nobody available", human.token);
  check("empty room exposes unanswered state", empty.floor.length === 0 && (await get("/api/conversation")).conversation.status === "unanswered");
  const newcomer = new Client({ name: "third-neutral-client", version: "1" });
  await newcomer.connect(new StdioClientTransport({ command: process.execPath, args: [join(root, "bridge/bridge.ts")], env: { ...env, TAVERN_CHANNELS: "" } }));
  clients.push(newcomer);
  await call(newcomer, "join_room", { name: "Gamma" });
  check("joining agent can take an unanswered room-wide prompt", (await get("/api/conversation")).conversation.floor.join() === "Gamma");
  console.log(failures ? `${failures} conversation failure(s)` : "all conversation checks passed");
} finally {
  await Promise.allSettled(clients.map(c => c.close()));
  hub.kill();
  await hub.exited;
  rmSync(data, { recursive: true, force: true });
}
process.exitCode = failures ? 1 : 0;
