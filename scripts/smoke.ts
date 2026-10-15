#!/usr/bin/env bun
// End-to-end check: spawns two bridges as MCP clients would, plus a human via
// the hub HTTP API, on an isolated port and data dir.
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { z } from "zod";

const PORT = 4799;
const DATA = mkdtempSync(join(tmpdir(), "tavern-smoke-"));
const env = { ...process.env, TAVERN_PORT: String(PORT), TAVERN_DATA: DATA } as Record<string, string>;
const BRIDGE = resolve(import.meta.dir, "../bridge/bridge.ts");
const HUB = `http://127.0.0.1:${PORT}`;

let failures = 0;
function check(label: string, ok: boolean, detail = "") {
  console.log(`${ok ? "PASS" : "FAIL"} ${label}${ok ? "" : `  ${detail}`}`);
  if (!ok) failures++;
}

const pushed: { content: string; meta: Record<string, string> }[] = [];
const ChannelSchema = z.object({
  method: z.literal("notifications/claude/channel"),
  params: z.object({ content: z.string(), meta: z.record(z.string(), z.string()) }),
});

async function agent(clientName: string, extraEnv: Record<string, string> = {}) {
  const client = new Client({ name: clientName, version: "1.0" });
  await client.connect(new StdioClientTransport({ command: process.execPath, args: [BRIDGE], env: { ...env, ...extraEnv } }));
  return client;
}

function textOf(r: any): string {
  return r.content.filter((c: any) => c.type === "text").map((c: any) => c.text).join("\n");
}

const a = await agent("claude-code", { TAVERN_CHANNELS: "claude" });
a.setNotificationHandler(ChannelSchema, (n) => {
  pushed.push(n.params);
});
const b = await agent("codex-mcp-client");

const tools = await a.listTools();
check("tools listed", tools.tools.length === 13, tools.tools.map((t) => t.name).join(","));
const caps = a.getServerCapabilities();
check("channel capability declared when opted in", !!(caps?.experimental as any)?.["claude/channel"]);
check("plain MCP by default (no channel capability)", !(b.getServerCapabilities()?.experimental as any)?.["claude/channel"]);

const j1 = await a.callTool({ name: "join_room", arguments: { name: "Ada" } });
check("Ada joins (hub autostarted)", textOf(j1).startsWith("Joined as Ada"), textOf(j1));
const j2 = await b.callTool({ name: "join_room", arguments: { name: "Bolt" } });
check("Bolt sees Ada", textOf(j2).includes("Ada (claude)"), textOf(j2));
const dup = await b.callTool({ name: "join_room", arguments: { name: "Ada" } });
check("second join is a no-op", textOf(dup).includes("Already in the room as Bolt"), textOf(dup));

// Human joins straight through the hub, as the Godot client does.
const hj = await (await fetch(`${HUB}/api/join`, {
  method: "POST", headers: { "content-type": "application/json" },
  body: JSON.stringify({ name: "Arda", kind: "human", client: "tavern-ui" }),
})).json() as any;
const human = { authorization: `Bearer ${hj.token}`, "content-type": "application/json" };
check("human joined", !!hj.token);

const waitP = b.callTool({ name: "wait_for_messages", arguments: { timeout_seconds: 10 } });
await Bun.sleep(300);
await a.callTool({ name: "send_message", arguments: { text: "hey @Bolt, tests are green on my side" } });
const waited = textOf(await waitP);
check("wait_for_messages wakes on new message", waited.includes("Ada (claude) [mentions you]: hey @Bolt"), waited);

await fetch(`${HUB}/api/messages`, { method: "POST", headers: human, body: JSON.stringify({ text: "nice, @Ada can you look at the login page?" }) });
await Bun.sleep(300);
check("human message pushed to Ada as channel event", pushed.some((p) => p.meta.from === "Arda" && p.meta.mentions_you === "true"), JSON.stringify(pushed));

// Agent-to-agent mention gets pushed; an unaddressed agent message does not.
await b.callTool({ name: "send_message", arguments: { text: "@Ada I'll take the API side" } });
await b.callTool({ name: "send_message", arguments: { text: "general musing, not for anyone" } });
await Bun.sleep(300);
check("agent mention pushed", pushed.some((p) => p.content.includes("I'll take the API side")));
check("unaddressed agent chatter not pushed", !pushed.some((p) => p.content.includes("general musing")));

// An addressed wait ignores agent chatter but wakes for a human.
await b.callTool({ name: "read_messages", arguments: {} });
const quietP = b.callTool({ name: "wait_for_messages", arguments: { timeout_seconds: 8 } });
let settled = false;
quietP.then(() => (settled = true));
await Bun.sleep(300);
await a.callTool({ name: "send_message", arguments: { text: "just thinking out loud" } });
await Bun.sleep(800);
check("agent chatter doesn't wake an addressed wait", !settled);
await fetch(`${HUB}/api/messages`, { method: "POST", headers: human, body: JSON.stringify({ text: "@Bolt lunch anyone?" }) });
const woke = textOf(await quietP);
check("human message wakes it, with the skipped chatter included", woke.includes("lunch anyone?") && woke.includes("thinking out loud"), woke);

const read = textOf(await a.callTool({ name: "read_messages", arguments: {} }));
check("read_messages returns unread from others", read.includes("Arda (human)") && read.includes("Bolt (codex)") && !read.includes("tests are green"), read);
const again = textOf(await a.callTool({ name: "read_messages", arguments: {} }));
check("cursor advances", again.includes("No new messages"), again);

// Image round trip: a 1x1 PNG.
const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==", "base64");
const imgPath = join(DATA, "dot.png");
await Bun.write(imgPath, png);
const sent = textOf(await b.callTool({ name: "send_message", arguments: { text: "screenshot attached", image_path: imgPath } }));
check("send image", sent.startsWith("Sent"), sent);
const withImg = await a.callTool({ name: "read_messages", arguments: {} });
check("image delivered inline", (withImg.content as any[]).some((c) => c.type === "image" && c.mimeType === "image/png"), JSON.stringify(withImg.content).slice(0, 300));
const id = Number(textOf(withImg).match(/#(\d+) \[[^\]]+\] Bolt/)?.[1]);
const viewed = await a.callTool({ name: "view_image", arguments: { message_id: id } });
check("view_image", (viewed.content as any[]).some((c) => c.type === "image"));

await a.callTool({ name: "set_status", arguments: { status: "fixing login redirect" } });
const roster = textOf(await b.callTool({ name: "list_members", arguments: {} }));
check("status visible to others", roster.includes("Ada [claude] - fixing login redirect"), roster);
check("agents never see looks", !/wizard|rogue|cleric|fighter|ranger|bard|paladin|druid|warlock|barbarian|monk|sorcerer/.test(roster + read + waited));

// Loop guard: after a long agent-only streak, mentions stop being pushed.
const before = pushed.length;
for (let i = 0; i < 8; i++) await b.callTool({ name: "send_message", arguments: { text: `@Ada ping ${i}` } });
await Bun.sleep(300);
const got = pushed.length - before;
check("agent streak caps pushes", got > 0 && got < 8, `pushed ${got} of 8`);

// Claims: one holder at a time; only the holder releases; leaving releases.
const c1 = textOf(await a.callTool({ name: "claim", arguments: { resource: "git", note: "pushing" } }));
check("claim succeeds", c1.includes('You hold "git"'), c1);
const c2 = await b.callTool({ name: "claim", arguments: { resource: "GIT" } });
check("second claimant refused, told who holds it", c2.isError === true && textOf(c2).includes("claimed by Ada (pushing)"), textOf(c2));
const r2 = await b.callTool({ name: "release", arguments: { resource: "git" } });
check("only the holder can release", r2.isError === true, textOf(r2));
const lc = textOf(await b.callTool({ name: "list_claims", arguments: {} }));
check("list_claims shows the holder", lc.includes('"git" - Ada: pushing'), lc);
await a.callTool({ name: "release", arguments: { resource: "git" } });
const c3 = textOf(await b.callTool({ name: "claim", arguments: { resource: "git", note: "tagging" } }));
check("released resource can be claimed by someone else", c3.includes('You hold "git"'), c3);
const seen = textOf(await a.callTool({ name: "read_messages", arguments: {} }));
check("claims are announced in the room", seen.includes('Bolt claimed "git": tagging'), seen);

// The wait obeys the same loop guard as pushes: a long agent-only streak of
// @mentions doesn't wake it, a human does.
await b.callTool({ name: "read_messages", arguments: {} });
for (let i = 0; i < 7; i++) await a.callTool({ name: "send_message", arguments: { text: `@Bolt warm-up ${i}` } });
await b.callTool({ name: "read_messages", arguments: {} });
const guardP = b.callTool({ name: "wait_for_messages", arguments: { timeout_seconds: 8 } });
let guardDone = false;
guardP.then(() => (guardDone = true));
await Bun.sleep(200);
await a.callTool({ name: "send_message", arguments: { text: "@Bolt are you there?" } });
await Bun.sleep(800);
check("agent @mention past the streak limit doesn't wake a wait", !guardDone);
await fetch(`${HUB}/api/messages`, { method: "POST", headers: human, body: JSON.stringify({ text: "@Bolt ok, back to work" }) });
check("a human message still wakes it", textOf(await guardP).includes("back to work"));

// A backlog larger than one page is delivered in full, oldest first.
for (let i = 0; i < 230; i++) {
  await fetch(`${HUB}/api/messages`, { method: "POST", headers: human, body: JSON.stringify({ text: `bulk ${i}` }) });
}
const bulk = textOf(await b.callTool({ name: "read_messages", arguments: {} }));
check("backlog over 200 messages isn't skipped", bulk.includes(": bulk 0\n") && bulk.includes(": bulk 229"), bulk.slice(0, 200));

// Presence: closing a bridge removes its member.
await b.close();
await Bun.sleep(1500);
const members = (await (await fetch(`${HUB}/api/members`)).json()) as any;
check("closed session leaves the room", !members.members.some((m: any) => m.name === "Bolt"), JSON.stringify(members.members.map((m: any) => m.name)));
const left = (await (await fetch(`${HUB}/api/claims`)).json()) as any;
check("leaving releases the member's claims", left.claims.length === 0, JSON.stringify(left.claims));

await a.close();
// Stop the hub this test started.
Bun.spawnSync(["pkill", "-f", `${DATA}`]);
const pid = Bun.spawnSync(["lsof", "-ti", `tcp:${PORT}`, "-sTCP:LISTEN"]).stdout.toString().trim();
if (pid) Bun.spawnSync(["kill", ...pid.split("\n")]);
rmSync(DATA, { recursive: true, force: true });
console.log(failures ? `\n${failures} failure(s)` : "\nall passed");
process.exit(failures ? 1 : 0);
