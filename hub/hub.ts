#!/usr/bin/env bun
// Tavern hub: the single source of truth for the room. Agents reach it through
// the stdio bridge (bridge/bridge.ts); the Godot client talks to it directly.
// HTTP for writes, one WebSocket stream for live events.
import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const PORT = Number(process.env.TAVERN_PORT ?? 4777);
const DATA = process.env.TAVERN_DATA ?? join(homedir(), ".mcp-tavern");
const IMAGES = join(DATA, "images");
const LOG = join(DATA, "messages.jsonl");
const LOOKS = join(DATA, "looks.json");
const PRESENCE_GRACE_MS = 45_000;
const MAX_TEXT = 8000;
const MAX_IMAGE_BYTES = 15 * 1024 * 1024;
const HISTORY_IN_MEMORY = 2000;

mkdirSync(IMAGES, { recursive: true });

// Visual identities. Only the Godot client interprets these; agents never see them.
const LOOKS_POOL = [
  "wizard", "rogue", "cleric", "fighter", "ranger", "bard",
  "paladin", "druid", "warlock", "barbarian", "monk", "sorcerer",
];

type Kind = "agent" | "human";

interface Member {
  id: string;
  token: string;
  name: string;
  kind: Kind;
  client: string;
  vendor: string;
  look: string;
  status: string;
  joinedAt: number;
  lastActive: number;
  lastSeen: number;
}

interface ImageRef {
  file: string;
  url: string;
  path: string;
  mime: string;
}

interface Message {
  id: number;
  ts: string;
  kind: "chat" | "system";
  event?: "join" | "leave" | "claim" | "release" | "turn";
  floor?: string[];
  replyTo?: number;
  from: PublicMember | null;
  text: string;
  image?: ImageRef;
  mentions: string[];
  agentStreak: number;
}

type PublicMember = Omit<Member, "token">;

// A claim says "I'm working on this shared thing" (a repo, a file, a deploy)
// so members don't step on each other. Released explicitly or when the holder leaves.
interface Claim {
  resource: string;
  holderId: string;
  holder: string;
  note: string;
  since: number;
}

const members = new Map<string, Member>(); // by token
const sockets = new Map<string, Set<unknown>>(); // token -> open sockets
let messages: Message[] = [];
let nextId = 1;
let agentStreak = 0;
const claims = new Map<string, Claim>(); // by lowercased resource
const REPLY_TIMEOUT_MS = Math.max(100, Number(process.env.TAVERN_REPLY_TIMEOUT_MS ?? 30_000));
interface Conversation {
  messageId: number;
  mode: "rotating" | "directed" | "all";
  floor: string[];
  received: string[];
  working: string[];
  replied: string[];
  passed: string[];
  status: "waiting" | "complete" | "unanswered";
  deadline: number | null;
}
let conversation: Conversation | null = null;
const attempted = new Set<string>();
const lastAssigned = new Map<string, number>();


const looks: Record<string, string> = existsSync(LOOKS)
  ? JSON.parse(readFileSync(LOOKS, "utf8"))
  : {};

if (existsSync(LOG)) {
  const lines = readFileSync(LOG, "utf8").split("\n").filter(Boolean);
  for (const line of lines.slice(-HISTORY_IN_MEMORY)) {
    try {
      messages.push(JSON.parse(line));
    } catch {
      // skip a torn trailing line
    }
  }
  if (messages.length) nextId = messages[messages.length - 1].id + 1;
}


// The hub owns attention, so stdio MCP, push adapters and HTTP clients agree.
// Recover rotation history without retaining an in-flight lease across a restart.
for (const m of messages) if (m.floor && (
  (m.from?.kind === "human" && !m.mentions.length) || m.event === "turn"
)) {
  for (const name of m.floor) lastAssigned.set(name.toLowerCase(), m.id);
}

function availableAgents(): string[] {
  return [...members.values()].filter(m => m.kind === "agent")
    .map(m => m.name).sort((a, b) => a.localeCompare(b));
}

function nextResponder(excluded = new Set<string>()): string | undefined {
  return availableAgents().filter(n => !excluded.has(n.toLowerCase()))
    .sort((a, b) => (lastAssigned.get(a.toLowerCase()) ?? 0) - (lastAssigned.get(b.toLowerCase()) ?? 0)
      || a.localeCompare(b))[0];
}

function planReply(mentions: string[]): { mode: Conversation["mode"]; floor: string[] } {
  const agents = availableAgents();
  if (mentions.includes("all")) return { mode: "all", floor: agents };
  const directed = agents.filter(n => mentions.includes(n));
  if (mentions.length) return { mode: "directed", floor: directed };
  const next = nextResponder();
  return { mode: "rotating", floor: next ? [next] : [] };
}

function publishConversation() {
  broadcast({ type: "conversation", conversation });
}

function beginConversation(m: Message, mode: Conversation["mode"]) {
  attempted.clear();
  for (const name of m.floor ?? []) {
    attempted.add(name.toLowerCase());
    if (mode === "rotating") lastAssigned.set(name.toLowerCase(), m.id);
  }
  conversation = {
    messageId: m.id, mode, floor: [...(m.floor ?? [])],
    received: [], working: [], replied: [], passed: [],
    status: m.floor?.length ? "waiting" : "unanswered",
    deadline: m.floor?.length ? Date.now() + REPLY_TIMEOUT_MS : null,
  };
  publishConversation();
}

function handOff(reason: string) {
  const c = conversation;
  if (!c || c.floor.length || c.status === "complete") return;
  const next = c.mode === "rotating" ? nextResponder(attempted) : undefined;
  if (next) {
    c.floor = [next];
    c.status = "waiting";
    c.deadline = Date.now() + REPLY_TIMEOUT_MS;
    attempted.add(next.toLowerCase());
    // A persisted event also reaches polling clients and reconnecting adapters.
    const handoff = record({ kind: "system", event: "turn", from: null, mentions: [],
      replyTo: c.messageId, floor: [next],
      text: `${next} has the reply to prompt #${c.messageId} (${reason})` });
    lastAssigned.set(next.toLowerCase(), handoff.id);
  } else {
    c.status = c.replied.length ? "complete" : "unanswered";
    c.deadline = null;
  }
  publishConversation();
}

function markReceived(name: string, page: Message[]) {
  const c = conversation;
  if (!c || c.status !== "waiting" || !c.floor.includes(name) || c.received.includes(name)) return;
  if (!page.some(m => m.id === c.messageId || (m.event === "turn" && m.replyTo === c.messageId && m.floor?.includes(name)))) return;
  c.received.push(name);
  c.deadline = Date.now() + REPLY_TIMEOUT_MS;
  publishConversation();
}

function markReplied(name: string) {
  const c = conversation;
  if (!c || c.status !== "waiting" || !c.floor.includes(name)) return;
  c.floor = c.floor.filter(n => n !== name);
  c.working = c.working.filter(n => n !== name);
  if (!c.received.includes(name)) c.received.push(name);
  if (!c.replied.includes(name)) c.replied.push(name);
  if (!c.floor.length) { c.status = "complete"; c.deadline = null; }
  publishConversation();
}

function passResponder(name: string, reason: string) {
  const c = conversation;
  if (!c || !c.floor.includes(name)) return;
  c.floor = c.floor.filter(n => n !== name);
  c.working = c.working.filter(n => n !== name);
  if (!c.passed.includes(name)) c.passed.push(name);
  if (!c.floor.length) handOff(reason);
  else publishConversation();
}

function vendorOf(client: string): string {
  if (/claude/i.test(client)) return "claude";
  if (/codex|openai/i.test(client)) return "codex";
  if (/tavern-ui/i.test(client)) return "human";
  return "other";
}

function hash(s: string): number {
  let h = 2166136261;
  for (const c of s) h = Math.imul(h ^ c.charCodeAt(0), 16777619);
  return h >>> 0;
}

function pickLook(name: string): string {
  const key = name.toLowerCase();
  if (looks[key]) return looks[key];
  const used = new Set([...members.values()].map((m) => m.look));
  const free = LOOKS_POOL.filter((l) => !used.has(l));
  const pool = free.length ? free : LOOKS_POOL;
  const look = pool[hash(key) % pool.length];
  looks[key] = look;
  writeFileSync(LOOKS, JSON.stringify(looks, null, 2));
  return look;
}

function pub(m: Member): PublicMember {
  const { token: _token, ...rest } = m;
  return rest;
}

function broadcast(event: unknown) {
  server.publish("room", JSON.stringify(event));
}

function findByName(name: string): Member | undefined {
  const key = name.toLowerCase();
  for (const m of members.values()) if (m.name.toLowerCase() === key) return m;
}

function parseMentions(text: string): string[] {
  const out = new Set<string>();
  for (const match of text.matchAll(/@([A-Za-z0-9_.\-]+)/g)) {
    const raw = match[1].replace(/[.\-]+$/, "");
    const lower = raw.toLowerCase();
    if (["all", "everyone", "here", "channel"].includes(lower)) out.add("all");
    const m = findByName(raw);
    if (m) out.add(m.name);
  }
  return [...out];
}

function record(msg: Omit<Message, "id" | "ts" | "agentStreak">): Message {
  if (msg.kind === "chat") agentStreak = msg.from?.kind === "agent" ? agentStreak + 1 : 0;
  const full: Message = { id: nextId++, ts: new Date().toISOString(), agentStreak, ...msg };
  messages.push(full);
  if (messages.length > HISTORY_IN_MEMORY) messages = messages.slice(-HISTORY_IN_MEMORY);
  appendFileSync(LOG, JSON.stringify(full) + "\n");
  broadcast({ type: "message", message: full });
  return full;
}

function removeMember(m: Member, reason: string) {
  members.delete(m.token);
  sockets.delete(m.token);
  broadcast({ type: "left", id: m.id });
  record({ kind: "system", event: "leave", from: pub(m), text: `${m.name} ${reason}`, mentions: [] });
  for (const c of [...claims.values()]) if (c.holderId === m.id) dropClaim(c, pub(m), "left the room");
  passResponder(m.name, "previous responder left");
}

function claimList(): Claim[] {
  return [...claims.values()].sort((a, b) => a.since - b.since);
}

function dropClaim(c: Claim, by: PublicMember, why?: string) {
  claims.delete(c.resource.toLowerCase());
  broadcast({ type: "claims", claims: claimList() });
  const text = why ? `${c.holder}'s claim on "${c.resource}" was released (${why})` : `${by.name} released "${c.resource}"`;
  record({ kind: "system", event: "release", from: by, text, mentions: [] });
}

// Activity is broadcast at most once a minute so clients can tell who's idle.
const lastActivityBroadcast = new Map<string, number>();
function touch(m: Member) {
  const now = Date.now();
  m.lastActive = now;
  if (now - (lastActivityBroadcast.get(m.id) ?? 0) > 60_000) {
    lastActivityBroadcast.set(m.id, now);
    broadcast({ type: "member", member: pub(m) });
  }
}

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function err(status: number, error: string) {
  return json({ error }, status);
}

function auth(req: Request): Member | undefined {
  const header = req.headers.get("authorization") ?? "";
  const token = header.replace(/^Bearer\s+/i, "");
  const m = members.get(token);
  if (m) m.lastSeen = Date.now();
  return m;
}

function sniffImage(bytes: Uint8Array): { mime: string; ext: string } | null {
  const b = bytes;
  if (b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) return { mime: "image/png", ext: "png" };
  if (b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return { mime: "image/jpeg", ext: "jpg" };
  if (b[0] === 0x47 && b[1] === 0x49 && b[2] === 0x46) return { mime: "image/gif", ext: "gif" };
  if (b[0] === 0x52 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x46 && b[8] === 0x57 && b[9] === 0x45)
    return { mime: "image/webp", ext: "webp" };
  return null;
}

const images = new Map<string, ImageRef>();

async function handle(req: Request, url: URL): Promise<Response> {
  const path = url.pathname;

  if (req.method === "GET" && path === "/api/health") return json({ ok: true, port: PORT, data: DATA });

  if (req.method === "POST" && path === "/api/join") {
    const body = (await req.json().catch(() => ({}))) as {
      name?: string; kind?: Kind; client?: string; resume?: string;
    };
    if (body.resume && members.has(body.resume)) {
      const m = members.get(body.resume)!;
      m.lastSeen = m.lastActive = Date.now();
      return json({ token: m.token, member: pub(m), resumed: true });
    }
    const name = (body.name ?? "").trim().replace(/\s+/g, "-");
    if (!/^[A-Za-z0-9_.\-]{1,32}$/.test(name))
      return err(400, "name must be 1-32 characters: letters, digits, _ . -");
    const existing = findByName(name);
    if (existing) return err(409, `the name "${name}" is already taken by someone in the room`);
    const client = (body.client ?? "unknown").slice(0, 64);
    const now = Date.now();
    const m: Member = {
      id: crypto.randomUUID().slice(0, 8),
      token: crypto.randomUUID(),
      name,
      kind: body.kind === "human" ? "human" : "agent",
      client,
      vendor: body.kind === "human" ? "human" : vendorOf(client),
      look: pickLook(name),
      status: "",
      joinedAt: now,
      lastActive: now,
      lastSeen: now,
    };
    members.set(m.token, m);
    broadcast({ type: "member", member: pub(m) });
    record({ kind: "system", event: "join", from: pub(m), text: `${m.name} joined the room`, mentions: [] });
    if (m.kind === "agent" && conversation?.status === "unanswered") handOff("responder became available");
    return json({ token: m.token, member: pub(m) });
  }

  if (req.method === "GET" && path === "/api/conversation") return json({ conversation });

  if (req.method === "GET" && path === "/api/claims") {
    return json({ claims: claimList() });
  }

  if (req.method === "GET" && path === "/api/members") {
    return json({ members: [...members.values()].map(pub) });
  }

  if (req.method === "GET" && path === "/api/messages") {
    // Oldest-first pages after `after` (check `more`), or the newest `limit` with recent=1.
    const after = Number(url.searchParams.get("after") ?? 0);
    const limit = Math.min(Number(url.searchParams.get("limit") ?? 100), 500);
    const recent = url.searchParams.get("recent") === "1";
    const me = auth(req);
    if (me) touch(me);
    const list = messages.filter((m) => m.id > after);
    const page = recent ? list.slice(-limit) : list.slice(0, limit);
    if (me) markReceived(me.name, page);
    return json({ messages: page, latest: nextId - 1, more: !recent && list.length > limit });
  }

  if (req.method === "GET" && path.startsWith("/images/")) {
    const file = path.slice("/images/".length);
    if (!/^[A-Za-z0-9_.\-]+$/.test(file)) return err(400, "bad file");
    const f = Bun.file(join(IMAGES, file));
    if (!(await f.exists())) return err(404, "not found");
    return new Response(f);
  }

  // Everything below needs a member token.
  const me = auth(req);
  if (!me) return err(401, "unknown or expired token; join the room again");

  if (req.method === "POST" && path === "/api/images") {
    const bytes = new Uint8Array(await req.arrayBuffer());
    if (bytes.length === 0) return err(400, "empty body");
    if (bytes.length > MAX_IMAGE_BYTES) return err(413, "image larger than 15 MB");
    const kind = sniffImage(bytes);
    if (!kind) return err(415, "only PNG, JPEG, GIF and WebP images are supported");
    const file = `${Date.now()}-${crypto.randomUUID().slice(0, 6)}.${kind.ext}`;
    const full = join(IMAGES, file);
    await Bun.write(full, bytes);
    const ref: ImageRef = { file, url: `/images/${file}`, path: full, mime: kind.mime };
    images.set(file, ref);
    return json({ image: ref });
  }

  if (req.method === "POST" && path === "/api/messages") {
    const body = (await req.json().catch(() => ({}))) as { text?: string; image?: string };
    const text = (body.text ?? "").slice(0, MAX_TEXT);
    let image: ImageRef | undefined;
    if (body.image) {
      image = images.get(body.image);
      if (!image) {
        const full = join(IMAGES, body.image);
        if (!/^[A-Za-z0-9_.\-]+$/.test(body.image) || !existsSync(full)) return err(400, "unknown image");
        const ext = body.image.split(".").pop()!;
        image = { file: body.image, url: `/images/${body.image}`, path: full, mime: `image/${ext === "jpg" ? "jpeg" : ext}` };
      }
    }
    if (!text.trim() && !image) return err(400, "message needs text or an image");
    touch(me);
    const mentions = parseMentions(text);
    const plan = me.kind === "human" ? planReply(mentions) : undefined;
    const msg = record({ kind: "chat", from: pub(me), text, image, mentions, ...(plan ? { floor: plan.floor } : {}) });
    if (plan) beginConversation(msg, plan.mode);
    else markReplied(me.name);
    return json({ message: msg });
  }

  if (req.method === "POST" && path === "/api/conversation/state") {
    const body = await req.json().catch(() => ({})) as { messageId?: number; state?: string };
    if (!conversation || body.messageId !== conversation.messageId) return err(409, "that prompt is no longer current");
    if (!conversation.floor.includes(me.name)) return err(403, "the current reply is assigned to someone else");
    if (body.state === "passed") passResponder(me.name, "previous responder passed");
    else if (body.state === "working") {
      if (!conversation.received.includes(me.name)) conversation.received.push(me.name);
      if (!conversation.working.includes(me.name)) conversation.working.push(me.name);
      // Authenticated working updates are a heartbeat. A stopped harness
      // cannot renew its lease, but active work need not race a fallback.
      conversation.deadline = Date.now() + REPLY_TIMEOUT_MS;
      publishConversation();
    } else return err(400, "state must be working or passed");
    return json({ conversation });
  }

  if (req.method === "POST" && path === "/api/status") {
    const body = (await req.json().catch(() => ({}))) as { status?: string };
    me.status = (body.status ?? "").slice(0, 120);
    me.lastActive = Date.now();
    broadcast({ type: "member", member: pub(me) });
    return json({ member: pub(me) });
  }

  if (req.method === "POST" && path === "/api/look") {
    const body = (await req.json().catch(() => ({}))) as { name?: string; look?: string };
    const target = body.name ? findByName(body.name) : me;
    if (!target) return err(404, "no such member");
    if (!body.look || !LOOKS_POOL.includes(body.look)) return err(400, "unknown look");
    target.look = body.look;
    looks[target.name.toLowerCase()] = body.look;
    writeFileSync(LOOKS, JSON.stringify(looks, null, 2));
    broadcast({ type: "member", member: pub(target) });
    return json({ member: pub(target) });
  }

  if (req.method === "POST" && path === "/api/claims") {
    const body = (await req.json().catch(() => ({}))) as { resource?: string; note?: string };
    const resource = (body.resource ?? "").trim().slice(0, 80);
    if (!resource) return err(400, "resource is required");
    const note = (body.note ?? "").trim().slice(0, 120);
    const held = claims.get(resource.toLowerCase());
    if (held && held.holderId !== me.id) {
      return json({ error: `"${held.resource}" is claimed by ${held.holder}${held.note ? ` (${held.note})` : ""}`, claim: held }, 409);
    }
    const c: Claim = { resource: held?.resource ?? resource, holderId: me.id, holder: me.name, note, since: held?.since ?? Date.now() };
    claims.set(resource.toLowerCase(), c);
    touch(me);
    broadcast({ type: "claims", claims: claimList() });
    if (!held) {
      record({ kind: "system", event: "claim", from: pub(me), text: `${me.name} claimed "${c.resource}"${note ? `: ${note}` : ""}`, mentions: [] });
    }
    return json({ claim: c, renewed: !!held });
  }

  if (req.method === "POST" && path === "/api/claims/release") {
    const body = (await req.json().catch(() => ({}))) as { resource?: string };
    const held = claims.get((body.resource ?? "").trim().toLowerCase());
    if (!held) return err(404, `nothing called "${body.resource}" is claimed`);
    if (held.holderId !== me.id) return err(403, `"${held.resource}" is claimed by ${held.holder}, not you`);
    dropClaim(held, pub(me));
    return json({ ok: true });
  }

  if (req.method === "POST" && path === "/api/leave") {
    removeMember(me, "left the room");
    return json({ ok: true });
  }

  return err(404, "not found");
}

type SocketData = { token?: string };

const server = Bun.serve({
  port: PORT,
  hostname: "127.0.0.1",
  idleTimeout: 120,
  async fetch(req, srv) {
    const url = new URL(req.url);
    if (url.pathname === "/ws") {
      const token = url.searchParams.get("token") ?? undefined;
      if (srv.upgrade(req, { data: { token } satisfies SocketData })) return undefined;
      return err(400, "websocket upgrade failed");
    }
    try {
      return await handle(req, url);
    } catch (e) {
      console.error(e);
      return err(500, String(e));
    }
  },
  websocket: {
    open(ws) {
      const { token } = ws.data as SocketData;
      ws.subscribe("room");
      const me = token ? members.get(token) : undefined;
      if (me && token) {
        me.lastSeen = Date.now();
        if (!sockets.has(token)) sockets.set(token, new Set());
        sockets.get(token)!.add(ws);
      }
      ws.send(JSON.stringify({
        type: "snapshot",
        you: me ? pub(me) : null,
        members: [...members.values()].map(pub),
        messages: messages.slice(-200),
        looks: LOOKS_POOL,
        claims: claimList(),
        conversation,
      }));
    },
    message(ws, raw) {
      // Clients only send keepalives; writes go through HTTP.
      const { token } = ws.data as SocketData;
      const me = token ? members.get(token) : undefined;
      if (me) me.lastSeen = Date.now();
      if (String(raw) === "ping") ws.send(JSON.stringify({ type: "pong" }));
    },
    close(ws) {
      const { token } = ws.data as SocketData;
      if (!token) return;
      sockets.get(token)?.delete(ws);
      const me = members.get(token);
      if (me) me.lastSeen = Date.now();
    },
  },
});

// Leases are short and bounded; a dead harness cannot hold the room forever.
setInterval(() => {
  const c = conversation;
  if (!c || c.status !== "waiting" || !c.deadline || Date.now() < c.deadline) return;
  for (const name of [...c.floor]) passResponder(name, "previous responder timed out");
}, Math.min(1000, REPLY_TIMEOUT_MS));

// A member whose sockets have all been closed for longer than the grace period
// has gone (its agent session ended or the client was closed).
setInterval(() => {
  const now = Date.now();
  for (const m of [...members.values()]) {
    const open = sockets.get(m.token)?.size ?? 0;
    if (open === 0 && now - m.lastSeen > PRESENCE_GRACE_MS) removeMember(m, "left the room");
  }
}, 5000);

console.log(`tavern hub listening on http://127.0.0.1:${PORT} (data: ${DATA})`);
