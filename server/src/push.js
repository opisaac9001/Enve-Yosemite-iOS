import { createSign, createPrivateKey } from "node:crypto";
import { readFileSync } from "node:fs";
import http2 from "node:http2";
import { env } from "./lib/env.js";
import { readJSON, writeJSON } from "./lib/store.js";

const FILE = "push-tokens.json";

export function apnsConfig() {
  const keyId = env("APNS_KEY_ID"), teamId = env("APNS_TEAM_ID"), keyPath = env("APNS_KEY_P8_PATH"), bundleId = env("APNS_BUNDLE_ID", "dev.petty.fieldguide");
  if (!keyId || !teamId || !keyPath) return null;
  let key;
  try { key = createPrivateKey(readFileSync(keyPath, "utf8")); } catch { return null; }
  return { keyId, teamId, key, bundleId, host: env("APNS_USE_SANDBOX", "true") === "true" ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com" };
}

export const pushReady = () => apnsConfig() !== null;

export function register(body) {
  const token = String(body?.token ?? "").trim();
  if (!/^[0-9a-f]{32,200}$/i.test(token)) throw Object.assign(new Error("token must be a hex APNs device token"), { status: 400 });
  const preferences = body?.preferences && typeof body.preferences === "object" ? Object.fromEntries(Object.entries(body.preferences).map(([k, v]) => [String(k).slice(0, 30), { track: !!v?.track, push: !!v?.push }])) : {};
  const store = readJSON(FILE, { tokens: [] });
  const existing = store.tokens.find((t) => t.token === token);
  const now = new Date().toISOString();
  if (existing) { existing.preferences = preferences; existing.updatedAt = now; } else store.tokens.push({ token, platform: "apns", preferences, createdAt: now, updatedAt: now });
  writeJSON(FILE, store);
  return { accepted: true, pushReady: pushReady() };
}

export function unregister(body) {
  const token = String(body?.token ?? "").trim();
  const store = readJSON(FILE, { tokens: [] });
  store.tokens = store.tokens.filter((t) => t.token !== token);
  writeJSON(FILE, store);
  return { accepted: true, pushReady: pushReady() };
}

/** ES256 JWT for token-based APNs authentication. */
export function providerToken(config) {
  const b64 = (obj) => Buffer.from(JSON.stringify(obj)).toString("base64url");
  const unsigned = `${b64({ alg: "ES256", kid: config.keyId })}.${b64({ iss: config.teamId, iat: Math.floor(Date.now() / 1000) })}`;
  const signer = createSign("SHA256");
  signer.update(unsigned);
  const signature = signer.sign({ key: config.key, dsaEncoding: "ieee-p1363" }).toString("base64url");
  return `${unsigned}.${signature}`;
}

/** Sends one alert to every registered token subscribed to `channel`. Returns per-token results. */
export async function sendChannelAlert(channel, { title, body, url }) {
  const config = apnsConfig();
  if (!config) throw new Error("APNs is not configured (APNS_KEY_ID, APNS_TEAM_ID, APNS_KEY_P8_PATH)");
  const store = readJSON(FILE, { tokens: [] });
  const targets = store.tokens.filter((t) => t.preferences?.[channel]?.push);
  if (!targets.length) return [];
  const jwt = providerToken(config);
  const client = http2.connect(config.host);
  const payload = JSON.stringify({ aps: { alert: { title, body }, sound: "default", "thread-id": channel }, channel, url });
  const results = [];
  try {
    for (const target of targets) {
      results.push(await new Promise((resolve) => {
        const req = client.request({ ":method": "POST", ":path": `/3/device/${target.token}`, authorization: `bearer ${jwt}`, "apns-topic": config.bundleId, "apns-push-type": "alert", "apns-priority": "10", "content-type": "application/json" });
        let status = 0, text = "";
        req.on("response", (headers) => { status = headers[":status"]; });
        req.on("data", (chunk) => { text += chunk; });
        req.on("end", () => resolve({ token: target.token, status, body: text }));
        req.on("error", (error) => resolve({ token: target.token, status: 0, body: error.message }));
        req.end(payload);
      }));
    }
  } finally {
    client.close();
  }
  const gone = results.filter((r) => r.status === 410 || (r.status === 400 && /BadDeviceToken/.test(r.body))).map((r) => r.token);
  if (gone.length) { store.tokens = store.tokens.filter((t) => !gone.includes(t.token)); writeJSON(FILE, store); }
  return results;
}
