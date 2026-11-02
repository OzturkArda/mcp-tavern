// A fake Codex host for integration tests. Bun resolves this as `bun queue`.
import { appendFileSync } from "node:fs";
appendFileSync(process.env.TAVERN_QUEUE_TEST_LOG!, JSON.stringify({ args: process.argv.slice(2), ts: Date.now() }) + "\n");
await Bun.sleep(Number(process.env.TAVERN_QUEUE_TEST_DELAY_MS || 0));
console.log("queue accepted"); // Must never leak onto the bridge's MCP stdout.
process.exit(Number(process.env.TAVERN_QUEUE_TEST_EXIT || 0));
