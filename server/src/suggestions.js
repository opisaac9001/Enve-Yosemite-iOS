import { randomBytes } from "node:crypto";
import { readJSON, writeJSON } from "./lib/store.js";

const MAX_TEXT = 250;
const FILE = "suggestions.json";

function load() { return readJSON(FILE, { items: [] }); }

/** Accepts a suggestion; returns an opaque receipt the client stores privately. */
export function submit(body) {
  const text = String(body?.text ?? "").trim();
  if (!text || text.length > MAX_TEXT) throw Object.assign(new Error(`text must be 1–${MAX_TEXT} characters`), { status: 400 });
  const name = body?.name ? String(body.name).trim().slice(0, 60) : null;
  const title = body?.title ? String(body.title).trim().slice(0, 120) : null;
  const layout = body?.layout && typeof body.layout === "object" ? Object.fromEntries(Object.entries(body.layout).filter(([k]) => ["section", "orientation", "sizeClass", "textSize", "appearance", "appVersion"].includes(k)).map(([k, v]) => [k, String(v).slice(0, 40)])) : null;
  const store = load();
  // `proof` lets a returning submitter keep the same name; it is never echoed back.
  if (name && body?.proof && !store.items.some((i) => i.name === name && i.receipt === body.proof)) {
    throw Object.assign(new Error("That name is already in use by another device; choose a different name or leave it blank."), { status: 409 });
  }
  if (name && !body?.proof && store.items.some((i) => i.name === name)) {
    throw Object.assign(new Error("That name is already in use; choose a different name or leave it blank."), { status: 409 });
  }
  const now = new Date().toISOString();
  const item = { receipt: randomBytes(24).toString("hex"), name, title, text, layout, createdAt: now, updatedAt: now, status: "received", reply: null, closed: false };
  store.items.push(item);
  writeJSON(FILE, store);
  return { receipt: item.receipt, name, createdAt: now, updatedAt: now, status: item.status, reply: null, closed: false };
}

/** Status for receipts the client holds; unknown receipts are omitted. */
export function status(body) {
  const refs = Array.isArray(body?.receipts) ? body.receipts.slice(0, 100) : [];
  const store = load();
  const responses = [];
  for (const ref of refs) {
    const item = store.items.find((i) => i.receipt === ref?.receipt && (i.name ?? null) === (ref?.name ?? null));
    if (item) responses.push({ receipt: item.receipt, name: item.name, createdAt: item.createdAt, updatedAt: item.updatedAt, status: item.status, reply: item.reply, closed: item.closed });
  }
  return { responses };
}

/** Operator reply (used by scripts/reply.mjs). */
export function reply(receipt, text, { close = false, status: newStatus = "answered" } = {}) {
  const store = load();
  const item = store.items.find((i) => i.receipt === receipt);
  if (!item) throw new Error("receipt not found");
  item.reply = text;
  item.status = newStatus;
  item.closed = close;
  item.updatedAt = new Date().toISOString();
  writeJSON(FILE, store);
  return item;
}
