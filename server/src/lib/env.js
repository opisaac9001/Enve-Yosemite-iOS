import { readFileSync } from "node:fs";
import { resolve } from "node:path";

// Minimal .env loader: KEY=value lines, no expansion, existing environment wins.
export function loadEnv(path = resolve(process.cwd(), ".env")) {
  let text;
  try { text = readFileSync(path, "utf8"); } catch { return; }
  for (const line of text.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const eq = trimmed.indexOf("=");
    if (eq < 0) continue;
    const key = trimmed.slice(0, eq).trim();
    const value = trimmed.slice(eq + 1).trim().replace(/^"(.*)"$/, "$1");
    if (process.env[key] === undefined) process.env[key] = value;
  }
}

export const env = (key, fallback = "") => (process.env[key] ?? fallback).toString().trim();
export const envInt = (key, fallback) => Number.parseInt(env(key, String(fallback)), 10) || fallback;
