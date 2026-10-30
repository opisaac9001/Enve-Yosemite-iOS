import { mkdirSync, readFileSync, writeFileSync, renameSync, existsSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { env } from "./env.js";

export const dataDir = () => resolve(process.cwd(), env("DATA_DIR", "./data"));

export function readJSON(name, fallback) {
  const path = resolve(dataDir(), name);
  if (!existsSync(path)) return fallback;
  try { return JSON.parse(readFileSync(path, "utf8")); } catch { return fallback; }
}

/** Atomic write: temp file then rename. */
export function writeJSON(name, value) {
  const path = resolve(dataDir(), name);
  mkdirSync(dirname(path), { recursive: true });
  const tmp = `${path}.${process.pid}.tmp`;
  writeFileSync(tmp, JSON.stringify(value));
  renameSync(tmp, path);
}
