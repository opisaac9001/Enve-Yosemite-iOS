import { env } from "./env.js";

const DEFAULT_TIMEOUT_MS = 20_000;

/** Fetch with timeout and a descriptive error; never throws on non-2xx silently. */
export async function fetchText(url, { headers = {}, timeoutMs = DEFAULT_TIMEOUT_MS, accept = "*/*" } = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, {
      headers: { "user-agent": env("NWS_USER_AGENT", "enve-yosemite"), accept, ...headers },
      signal: controller.signal,
      redirect: "follow",
    });
    const text = await response.text();
    if (!response.ok) {
      const error = new Error(`HTTP ${response.status}`);
      error.status = response.status;
      error.body = text.slice(0, 200);
      throw error;
    }
    return { text, lastModified: response.headers.get("last-modified"), contentType: response.headers.get("content-type") };
  } finally {
    clearTimeout(timer);
  }
}

export async function fetchJSON(url, options = {}) {
  const { text, lastModified } = await fetchText(url, { accept: "application/json", ...options });
  return { data: JSON.parse(text), lastModified };
}

export async function fetchBuffer(url, { headers = {}, timeoutMs = DEFAULT_TIMEOUT_MS } = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, { headers: { "user-agent": env("NWS_USER_AGENT", "enve-yosemite"), ...headers }, signal: controller.signal });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return Buffer.from(await response.arrayBuffer());
  } finally {
    clearTimeout(timer);
  }
}

export const nowISO = () => new Date().toISOString();

/** Runs a source fetch, returning a status record plus the value or an unavailable status. */
export async function sourced(key, label, url, fn) {
  const checkedAt = nowISO();
  try {
    const result = await fn();
    const status = { key, label, state: result?.state ?? "ready", checkedAt, url };
    if (result?.detail) status.detail = result.detail;
    if (result?.sourceTime) status.sourceTime = result.sourceTime;
    return { status, value: result?.value, ok: true };
  } catch (error) {
    return { status: { key, label, state: "unavailable", checkedAt, url, detail: describe(error) }, value: undefined, ok: false };
  }
}

export function describe(error) {
  if (!error) return "unknown error";
  if (error.name === "AbortError") return "timed out";
  return error.status ? `HTTP ${error.status}` : (error.message || String(error));
}
