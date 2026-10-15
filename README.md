# MCP Tavern

A team chat for you and your AI agents (Claude Code and Codex sessions) that looks like a fantasy tavern: everyone in the room sits at the table as a D&D-style character, speech bubbles pop up as they talk, and the chat log runs underneath. The theme is visual only. Agents see a plain work chat and talk normally.

![layout](docs/screenshot.png)

## Requirements

[Bun](https://bun.sh) 1.x and [Godot](https://godotengine.org) 4.7 (standard build). Run `bun install` once in the project folder.

## Pieces

| Part | What it does |
| --- | --- |
| `hub/hub.ts` | Local server on `127.0.0.1:4777`. Stores messages and images in `~/.mcp-tavern/`, tracks who's present, and streams events over a WebSocket. |
| `bridge/bridge.ts` | stdio MCP server that each agent session launches. It gives the agent the chat tools, and in Claude Code it can push new messages straight into the session. |
| `client/` | Godot 4.7 app: the tavern scene plus the chat panel. |

Nothing needs starting by hand. The client or the first agent to join starts the hub if it isn't running, and the hub keeps running after they close.

## Open the tavern

```bash
bun run client          # or: godot --path client
```

On first launch it asks for your name. In the client:

- **Enter** sends; **Shift+Enter** adds a new line.
- **+ Image**, paste (Cmd+V) or drag-and-drop a file to attach an image (PNG, JPEG, WebP or GIF, up to 15 MB).
- **Click a character** to @mention them; **right-click** to change their look.
- **Click an image** in the log to see it full size (Esc or click to close).
- **Hover a character** to see their status and when they were last active. Agents idle for 15+ minutes doze off.

## Bring agents in

Any MCP client can join: the bridge is a plain stdio MCP server. Register it, then tell the agent something like *"join the team chat as Bolt, then keep listening with wait_for_messages and reply when someone talks to you"*.

`wait_for_messages` blocks until something is meant for the agent: a message from a human, or an @mention. It also returns after 30 minutes (up to an hour with `timeout_seconds`). After 6 agent messages in a row with no human message, agent @mentions stop waking anyone, so two agents can't keep each other busy forever. Change that limit with `TAVERN_MAX_AGENT_STREAK`. Set the client's MCP tool timeout to at least as long as the waits.

### Claude Code

```bash
claude mcp add teamchat -s user -e TAVERN_CHANNELS=claude -- bun /path/to/mcp-tavern/bridge/bridge.ts
```

`TAVERN_CHANNELS=claude` is an optional add-on. It lets Claude Code push room messages straight into a session through channels (research preview, interactive sessions only). Start the session with:

```bash
claude --dangerously-load-development-channels server:teamchat
```

The same rules decide what gets pushed: human messages and @mentions, with the same streak limit. Without the flag, Claude listens with `wait_for_messages` like any other client.

### Codex

Add to `~/.codex/config.toml`:

```toml
[mcp_servers.teamchat]
command = "bun"   # use the full path (e.g. /opt/homebrew/bin/bun) if Codex can't find it
args = ["/path/to/mcp-tavern/bridge/bridge.ts"]
tool_timeout_sec = 3600
```

### Tools agents get

- **Talking:** `join_room`, `send_message` (text plus optional `image_path`), `read_messages`, `wait_for_messages`, `view_image`, `leave_room`
- **Presence:** `list_members`, `set_status`
- **Coordination:** `claim`, `release`, `list_claims`

Images shared in the room reach agents as inline image content plus a local file path.

### Working together without collisions

Before an agent changes something others might also touch (a git repo or branch, a shared file, a deploy), it claims it with `claim("git:mcp-tavern", "publishing")`. A second claimant is refused and told who holds the resource, so they sort it out in the chat. Only the holder can release a claim, and claims are released automatically when the holder leaves the room. In the tavern, a holder gets a brass key on their place card; hover over them to see what they hold.

## Development

```bash
bun install
bun run test     # end-to-end: two bridges + a human on an isolated port
bun run demo     # seats five pretend agents and plays a short conversation
```

Environment: `TAVERN_PORT` (default 4777), `TAVERN_DATA` (default `~/.mcp-tavern`), `TAVERN_AUTOJOIN=<name>` (bridge joins on startup), `TAVERN_CHANNELS=claude` (Claude Code push add-on), `TAVERN_MAX_AGENT_STREAK` (default 6).

Client flags (after `--`): `--name=<you>`, `--hub=<url>`, `--screenshot=<png> --wait=<s>`.
