import { createServer } from "node:http";
import { createReadStream, statSync, existsSync } from "node:fs";
import { resolve, normalize, join } from "node:path";
import { loadEnv, env, envInt } from "./lib/env.js";
import { cache, builders, refreshAll } from "./cache.js";
import * as suggestions from "./suggestions.js";
import * as push from "./push.js";
import { pointByKey } from "./lib/points.js";

loadEnv();

const PORT = envInt("PORT", 8787);
const HOST = env("HOST", "127.0.0.1");
const VERSION = "0.1.0";
const EXPLORER_DIR = resolve(process.cwd(), env("EXPLORER_DIR", "./public/data/explorer"));

function json(res, status, body) {
  const text = JSON.stringify(body);
  res.writeHead(status, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", "content-length": Buffer.byteLength(text) });
  res.end(text);
}

async function readBody(req) {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > 64 * 1024) throw Object.assign(new Error("body too large"), { status: 413 });
    chunks.push(chunk);
  }
  if (!chunks.length) return {};
  try { return JSON.parse(Buffer.concat(chunks).toString("utf8")); } catch { throw Object.assign(new Error("invalid JSON"), { status: 400 }); }
}

function updates() {
  const channels = cache.channels();
  channels.app = { revision: VERSION, changedAt: null, checkedAt: new Date().toISOString(), available: true };
  for (const name of ["weather", "fire", "smoke", "seasonal", "events"]) if (!channels[name]) channels[name] = { revision: "", changedAt: null, checkedAt: null, available: false };
  return { channels, pushReady: push.pushReady(), checkerMinutes: envInt("REFRESH_MINUTES", 15), serverVersion: VERSION };
}

function serveExplorer(req, res, pathname) {
  const rel = normalize(pathname.replace(/^\/data\/explorer\//, "")).replace(/^(\.\.[/\\])+/, "");
  const file = join(EXPLORER_DIR, rel);
  if (!file.startsWith(EXPLORER_DIR) || !existsSync(file) || !statSync(file).isFile()) { json(res, 404, { error: "not found" }); return; }
  const type = file.endsWith(".json") ? "application/json" : "application/geo+json";
  res.writeHead(200, { "content-type": type, "content-length": statSync(file).size, ...(file.endsWith(".gz") ? { "content-encoding": "identity" } : {}), "cache-control": "public, max-age=3600" });
  createReadStream(file).pipe(res);
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host ?? "localhost"}`);
  const path = url.pathname;
  try {
    if (req.method === "GET" && path.startsWith("/data/explorer/")) return serveExplorer(req, res, path);
    if (req.method === "GET" && path === "/api/updates") return json(res, 200, updates());
    if (req.method === "GET" && path === "/api/weather") {
      const point = url.searchParams.get("point") ?? "valley";
      if (!pointByKey(point)) return json(res, 400, { error: "unknown point" });
      return json(res, 200, await builders.weather(point));
    }
    if (req.method === "GET" && path === "/api/fire-risk") return json(res, 200, await builders.fire());
    if (req.method === "GET" && path === "/api/smoke") return json(res, 200, await builders.smoke());
    if (req.method === "GET" && path === "/api/seasonal-risks") return json(res, 200, await builders.seasonal());
    if (req.method === "GET" && path === "/api/nps-programs") return json(res, 200, await builders.programs());
    if (req.method === "GET" && path === "/api/conditions") return json(res, 200, await builders.conditions());
    if (req.method === "POST" && path === "/api/suggestions") return json(res, 200, suggestions.submit(await readBody(req)));
    if (req.method === "POST" && path === "/api/suggestions/status") return json(res, 200, suggestions.status(await readBody(req)));
    if (req.method === "POST" && path === "/api/push/register") return json(res, 200, push.register(await readBody(req)));
    if (req.method === "POST" && path === "/api/push/unregister") return json(res, 200, push.unregister(await readBody(req)));
    if (req.method === "GET" && path === "/healthz") return json(res, 200, { ok: true, version: VERSION, pushReady: push.pushReady() });
    json(res, 404, { error: "not found" });
  } catch (error) {
    json(res, error.status && error.status >= 400 && error.status < 600 ? error.status : 500, { error: error.message ?? "server error" });
  }
});

server.listen(PORT, HOST, () => {
  console.log(`Enve Yosemite server v${VERSION} listening on http://${HOST}:${PORT} (push ${push.pushReady() ? "ready" : "not configured"})`);
  const minutes = envInt("REFRESH_MINUTES", 15);
  if (minutes > 0) {
    refreshAll(console).catch(() => {});
    setInterval(() => refreshAll(console).catch(() => {}), minutes * 60_000).unref();
  }
});
