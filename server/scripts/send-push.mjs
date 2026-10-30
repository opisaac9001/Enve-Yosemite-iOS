// Usage: node scripts/send-push.mjs <channel> "<title>" "<body>" [url]
import { loadEnv } from "../src/lib/env.js";
import { sendChannelAlert } from "../src/push.js";

loadEnv();
const [channel, title, body, url] = process.argv.slice(2);
if (!channel || !title || !body) {
  console.error("usage: send-push.mjs <channel> <title> <body> [url]");
  process.exit(1);
}
const results = await sendChannelAlert(channel, { title, body, url });
for (const r of results) console.log(`${r.token.slice(0, 8)}… ${r.status} ${r.body}`);
console.log(`${results.length} token(s) attempted`);
