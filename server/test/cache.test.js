import { test, before } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

before(() => { process.env.DATA_DIR = mkdtempSync(join(tmpdir(), "pfg-cache-")); });

const { FeedCache, channelFor, channelAlert } = await import("../src/cache.js");

test("channel revisions move only on content changes and notify exactly once per change", () => {
  const notified = [];
  const cache = new FeedCache({ onChannelChanged: (channel, info) => notified.push({ channel, revision: info.revision }) });
  assert.equal(cache.noteRevision("fire", { fetchedAt: "a", assessment: { priority: 2 } }), false, "first sighting is not a change");
  assert.equal(cache.noteRevision("fire", { fetchedAt: "b", statuses: [1], assessment: { priority: 2 } }), false, "volatile fields do not count");
  assert.equal(cache.noteRevision("fire", { fetchedAt: "c", assessment: { priority: 4 } }), true);
  assert.equal(cache.noteRevision("fire", { fetchedAt: "d", assessment: { priority: 4 } }), false);
  assert.equal(notified.length, 1);
  assert.equal(notified[0].channel, "fire");
  assert.equal(notified[0].revision, cache.revisions.fire.revision);
  assert.equal(cache.noteRevision("weather-tuolumne", { hourly: [] }), false, "only the Valley point feeds the weather channel");
  assert.equal(channelFor("conditions"), "seasonal");
  assert.equal(channelFor("programs"), "events");
  assert.deepEqual(Object.keys(cache.channels().fire).sort(), ["available", "changedAt", "checkedAt", "revision"], "member bookkeeping stays off the API");
});

test("two feeds sharing a channel can be refreshed alternately without false alerts", () => {
  const notified = [];
  const cache = new FeedCache({ onChannelChanged: (channel) => notified.push(channel) });
  const seasonal = { fetchedAt: "s1", river: { dischargeCfs: 120 }, chains: { activeControls: [] } };
  const conditions = { fetchedAt: "c1", page: { items: [{ id: "road:1", title: "Tioga Road", status: "open" }] } };
  cache.noteRevision("seasonal", seasonal);
  cache.noteRevision("conditions", conditions);
  const settled = cache.revisions.seasonal.revision;
  for (let round = 0; round < 3; round += 1) {
    assert.equal(cache.noteRevision("seasonal", { ...seasonal, fetchedAt: `s${round + 2}` }), false);
    assert.equal(cache.noteRevision("conditions", { ...conditions, fetchedAt: `c${round + 2}` }), false);
  }
  assert.deepEqual(notified, [], "unchanged content refreshed in alternation must never alert");
  assert.equal(cache.revisions.seasonal.revision, settled, "the combined revision is stable across alternating refreshes");
  assert.equal(cache.noteRevision("conditions", { ...conditions, page: { items: [{ id: "road:1", title: "Tioga Road", status: "closed" }] } }), true);
  assert.deepEqual(notified, ["seasonal"]);
  assert.notEqual(cache.revisions.seasonal.revision, settled);
});

test("a failed rebuild re-serves the previous payload with its original acquisition time", async () => {
  const cache = new FeedCache();
  const first = await cache.get("probe", async () => ({ fetchedAt: "2026-01-01T00:00:00.000Z", v: 1 }));
  assert.equal(first.v, 1);
  const again = await cache.get("probe", async () => { throw new Error("upstream down"); }, { force: true });
  assert.equal(again.fetchedAt, "2026-01-01T00:00:00.000Z", "the stale payload keeps its real fetchedAt for the client to judge");
  await assert.rejects(cache.get("never", async () => { throw new Error("nothing cached"); }), /nothing cached/);
});

test("channel alerts deep-link to the matching app section", () => {
  const alert = channelAlert("seasonal", { changedAt: "2026-10-27T03:31:06.868Z" });
  assert.equal(alert.url, "enveyosemite://section/risks");
  assert.match(alert.title, /seasonal notices updated/);
  assert.match(alert.body, /Pacific/);
});
