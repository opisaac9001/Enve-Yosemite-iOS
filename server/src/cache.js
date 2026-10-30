import { createHash } from "node:crypto";
import { readJSON, writeJSON } from "./lib/store.js";
import { buildWeather } from "./feeds/weather.js";
import { buildFire } from "./feeds/fire.js";
import { buildSmoke } from "./feeds/smoke.js";
import { buildSeasonal } from "./feeds/seasonal.js";
import { buildPrograms } from "./feeds/programs.js";
import { buildConditions } from "./feeds/conditions.js";
import { FORECAST_POINTS } from "./lib/points.js";
import * as push from "./push.js";

const TTL_MS = 10 * 60_000;

/** Update channels the app can track, with the section a push alert opens. */
export const CHANNELS = {
  weather: { label: "Weather", view: "status" },
  fire: { label: "Fire assessment", view: "fire" },
  smoke: { label: "Smoke & incidents", view: "fire" },
  seasonal: { label: "Roads, river & seasonal notices", view: "risks" },
  events: { label: "NPS calendar & hours", view: "events" },
};

export function channelFor(feedName) {
  if (feedName.startsWith("weather-")) return feedName === "weather-valley" ? "weather" : null;
  return { fire: "fire", smoke: "smoke", seasonal: "seasonal", conditions: "seasonal", programs: "events" }[feedName] ?? null;
}

const sha = (text) => createHash("sha256").update(text).digest("hex");

/**
 * In-memory + on-disk cache of the latest payload per feed, with change revisions for update
 * channels. When a rebuild fails the previous payload is served again with its original
 * `fetchedAt`, so clients can see how old the data really is.
 */
export class FeedCache {
  constructor({ onChannelChanged = null } = {}) {
    this.entries = new Map(Object.entries(readJSON("cache.json", {})));
    this.inflight = new Map();
    this.feedRevisions = readJSON("feed-revisions.json", {});
    this.revisions = readJSON("revisions.json", {});
    this.onChannelChanged = onChannelChanged;
  }

  async get(name, builder, { force = false } = {}) {
    const existing = this.entries.get(name);
    if (!force && existing && Date.now() - Date.parse(existing.fetchedAt) < TTL_MS) return existing.payload;
    if (this.inflight.has(name)) return this.inflight.get(name);
    const task = (async () => {
      try {
        const payload = await builder();
        this.entries.set(name, { fetchedAt: payload.fetchedAt, payload });
        this.noteRevision(name, payload);
        this.persist();
        return payload;
      } catch (error) {
        if (existing) return existing.payload;
        throw error;
      } finally {
        this.inflight.delete(name);
      }
    })();
    this.inflight.set(name, task);
    return task;
  }

  /**
   * Each feed keeps its own content hash (volatile fields removed); a channel's revision combines
   * the hashes of every feed that reports into it, so refreshing feeds in any order with unchanged
   * content never moves the channel. Returns whether the channel's content really changed.
   */
  noteRevision(name, payload) {
    const channel = channelFor(name);
    if (!channel) return false;
    this.feedRevisions[name] = sha(JSON.stringify(stable(payload)));
    writeJSON("feed-revisions.json", this.feedRevisions);
    const members = Object.keys(this.feedRevisions).filter((feed) => channelFor(feed) === channel).sort();
    const revision = sha(members.map((feed) => `${feed}:${this.feedRevisions[feed]}`).join("|"));
    const now = new Date().toISOString();
    const previous = this.revisions[channel];
    const sameMembers = Boolean(previous) && JSON.stringify(previous.members ?? []) === JSON.stringify(members);
    const changed = sameMembers && previous.revision !== revision;
    this.revisions[channel] = { revision, changedAt: previous && previous.revision === revision ? previous.changedAt : now, checkedAt: now, available: true, members };
    writeJSON("revisions.json", this.revisions);
    if (changed) this.onChannelChanged?.(channel, this.revisions[channel]);
    return changed;
  }

  /** Channel states as the app sees them (member bookkeeping stays internal). */
  channels() {
    return Object.fromEntries(Object.entries(this.revisions).map(([channel, { revision, changedAt, checkedAt, available }]) => [channel, { revision, changedAt, checkedAt, available }]));
  }

  persist() {
    writeJSON("cache.json", Object.fromEntries(this.entries));
  }

  snapshot(name) { return this.entries.get(name)?.payload ?? null; }
}

/** Drops volatile fields so revisions only move on real changes. */
function stable(value) {
  if (Array.isArray(value)) return value.map(stable);
  if (value && typeof value === "object") {
    const out = {};
    for (const [k, v] of Object.entries(value)) {
      if (["checkedAt", "fetchedAt", "statuses", "tracking"].includes(k)) continue;
      out[k] = stable(v);
    }
    return out;
  }
  return value;
}

/** Alert payload for a changed channel; the URL opens the matching section in the app. */
export function channelAlert(channel, info) {
  const meta = CHANNELS[channel];
  const when = new Date(info.changedAt).toLocaleString("en-US", { timeZone: "America/Los_Angeles", dateStyle: "medium", timeStyle: "short" });
  return { title: `${meta.label} updated`, body: `New information as of ${when} Pacific. Open the app to read it.`, url: `enveyosemite://section/${meta.view}` };
}

/** Sends the alert to subscribers; a no-op until APNs is configured. */
export async function alertSubscribers(channel, info, log = console) {
  if (!push.pushReady()) return [];
  const results = await push.sendChannelAlert(channel, channelAlert(channel, info));
  log.log(`push ${channel}: ${results.filter((r) => r.status === 200).length}/${results.length} accepted`);
  return results;
}

export const cache = new FeedCache({
  onChannelChanged: (channel, info) => { alertSubscribers(channel, info).catch((error) => console.error(`push ${channel} failed: ${error.message}`)); },
});

export const builders = {
  fire: () => cache.get("fire", buildFire),
  smoke: () => cache.get("smoke", buildSmoke),
  seasonal: () => cache.get("seasonal", buildSeasonal),
  programs: () => cache.get("programs", buildPrograms),
  conditions: () => cache.get("conditions", buildConditions),
  weather: (point) => cache.get(`weather-${point}`, () => buildWeather(point)),
};

export async function refreshAll(log = console) {
  const tasks = [
    ["fire", () => cache.get("fire", buildFire, { force: true })],
    ["smoke", () => cache.get("smoke", buildSmoke, { force: true })],
    ["seasonal", () => cache.get("seasonal", buildSeasonal, { force: true })],
    ["programs", () => cache.get("programs", buildPrograms, { force: true })],
    ["conditions", () => cache.get("conditions", buildConditions, { force: true })],
    ...FORECAST_POINTS.map((p) => [`weather-${p.key}`, () => cache.get(`weather-${p.key}`, () => buildWeather(p.key), { force: true })]),
  ];
  for (const [name, run] of tasks) {
    try { await run(); log.info?.(`refreshed ${name}`) ?? log.log(`refreshed ${name}`); }
    catch (error) { log.error(`refresh ${name} failed: ${error.message}`); }
  }
}
