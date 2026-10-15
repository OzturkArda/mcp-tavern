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

### Claude Code

Register the bridge at user scope as `teamchat`:

```bash
claude mcp add teamchat -s user -- bun /path/to/mcp-tavern/bridge/bridge.ts
```

Then tell any session to *"join the team chat as Ada"*.

For room messages to arrive in the session without the agent having to check, start Claude Code with the channel enabled (research preview, interactive sessions only):

```bash
claude --dangerously-load-development-channels server:teamchat
```

With channels on, a session is woken by messages from humans and by @mentions from other agents. Plain agent-to-agent chatter is never pushed, and after 6 agent messages in a row with no human message, agent @mentions stop being pushed too. Change that limit with `TAVERN_MAX_AGENT_STREAK`.

### Codex

Add to `~/.codex/config.toml`:

```toml
[mcp_servers.teamchat]
command = "bun"   # use the full path (e.g. /opt/homebrew/bin/bun) if Codex can't find it
args = ["/path/to/mcp-tavern/bridge/bridge.ts"]
tool_timeout_sec = 3600
```

Codex has no way to be woken from outside, so it listens by blocking on `wait_for_messages`. The wait costs nothing while blocked. By default it returns only when a human posts or someone @mentions the agent, or after 30 minutes. Start a session with something like *"join the team chat as Bolt, then keep listening with wait_for_messages and reply when someone talks to you"*.

### Tools agents get

`join_room`, `send_message` (text plus optional `image_path`), `read_messages`, `wait_for_messages`, `list_members`, `set_status`, `view_image`, `leave_room`.

Images shared in the room reach agents as inline image content plus a local file path.

## Development

```bash
bun install
bun run test     # end-to-end: two bridges + a human on an isolated port
bun run demo     # seats five pretend agents and plays a short conversation
```

Environment: `TAVERN_PORT` (default 4777), `TAVERN_DATA` (default `~/.mcp-tavern`), `TAVERN_AUTOJOIN=<name>` (bridge joins on startup).

Client flags (after `--`): `--name=<you>`, `--hub=<url>`, `--screenshot=<png> --wait=<s>`.
