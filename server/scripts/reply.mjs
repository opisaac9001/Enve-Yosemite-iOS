// Usage: node scripts/reply.mjs <receipt> "<reply text>" [--close]
import { loadEnv } from "../src/lib/env.js";
import { reply } from "../src/suggestions.js";

loadEnv();
const [receipt, text, flag] = process.argv.slice(2);
if (!receipt || !text) {
  console.error("usage: reply.mjs <receipt> <text> [--close]");
  process.exit(1);
}
const item = reply(receipt, text, { close: flag === "--close" });
console.log(`replied to ${item.receipt.slice(0, 8)}… (${item.status}${item.closed ? ", closed" : ""})`);
