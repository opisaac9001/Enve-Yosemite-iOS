import { test } from "node:test";
import assert from "node:assert/strict";
import { parseHMSKML } from "../src/feeds/smoke.js";
import { assess, parseFWF } from "../src/feeds/fire.js";
import { parseConditionsPage } from "../src/feeds/conditions.js";
import { pointInRing } from "../src/lib/geo.js";
import { normaliseChainRecord } from "../src/feeds/seasonal.js";

test("HMS KML polygons parse density, times and rings", () => {
  const kml = `<kml><Document><Placemark><name>Medium</name><ExtendedData><SchemaData><SimpleData name="Start">2026300 2000</SimpleData><SimpleData name="End">2026300 2330</SimpleData><SimpleData name="Density">Medium</SimpleData></SchemaData></ExtendedData><Polygon><outerBoundaryIs><LinearRing><coordinates>-119.5,37.5,0 -119.4,37.5,0 -119.4,37.6,0 -119.5,37.6,0</coordinates></LinearRing></outerBoundaryIs></Polygon></Placemark></Document></kml>`;
  const polys = parseHMSKML(kml);
  assert.equal(polys.length, 1);
  assert.equal(polys[0].density, "Medium");
  assert.equal(polys[0].ring.length, 4);
  assert.equal(polys[0].start, "2026-10-27T20:00:00.000Z");
  assert.ok(pointInRing(-119.45, 37.55, polys[0].ring));
  assert.ok(!pointInRing(-119.3, 37.55, polys[0].ring));
});

test("fire assessment is transparent about inputs", () => {
  const dry = assess({ metrics: { state: "ready", minHumidityPct: 18, maxWindMph: 10, maxPrecipChancePct: 1, thunderHours: 0 }, restrictions: { state: "ready", inEffect: false }, noticeMatches: [], alertMatches: [] });
  assert.equal(dry.priority, 3);
  assert.match(dry.reasons[0], /humidity 18%/);
  const missing = assess({ metrics: { state: "unavailable" }, restrictions: { state: "unknown" }, noticeMatches: [], alertMatches: [] });
  assert.equal(missing.priority, 1);
  assert.match(missing.label, /Inputs incomplete/);
  const alert = assess({ metrics: { state: "ready", minHumidityPct: 60, maxWindMph: 3, maxPrecipChancePct: 80, thunderHours: 0 }, restrictions: { state: "ready", inEffect: false }, noticeMatches: [], alertMatches: ["Red Flag Warning"] });
  assert.equal(alert.priority, 5);
});

test("FWF parser extracts discussion and zone periods", () => {
  const text = `FNUS56 KHNX 262040\nFWFHNX\n\n.DISCUSSION...A cooling trend begins Tuesday and lasts through the weekend.\n\nCAZ592-270800-\nCentral Sierra\n\n.TONIGHT...\nSky/weather.........Mostly clear.\nMin temperature.....37-47.\nMax humidity........64-74 percent.\nWind (20 ft)........Downslope 3 to 5 mph.\nRidge winds.........South 3 to 7 mph.\n\n.TUESDAY...\nSky/weather.........Mostly sunny.\nMax temperature.....56-66.\nMin humidity........24-34 percent.\n\n$$\n`;
  const fwf = parseFWF(text);
  assert.match(fwf.discussion, /cooling trend/);
  assert.equal(fwf.periods.length, 2);
  assert.equal(fwf.periods[1].name, "TUESDAY");
  assert.equal(fwf.periods[1].minHumidity, "24-34 percent.");
});

test("conditions page road table rows become road notices", () => {
  const html = `<html><body><p>Last updated: October 23, 2026</p><table><tr><th>Road</th><th>Status</th></tr><tr><td>Wawona Road (continuation of Highway 41 from Fresno)</td><td>Open</td></tr><tr><td>Tioga Road</td><td>Closed for the season</td></tr><tr><td>Glacier Point Road</td><td>Open</td></tr></table><h2>Current Roadwork</h2><h4>El Capitan Bridge Stabilization Project</h4><p>Expect delays.</p><h2>Trail Closures</h2><ul><li>Mist Trail above the footbridge is closed for ice.</li></ul></body></html>`;
  const parsed = parseConditionsPage(html);
  assert.equal(parsed.roadTableFound, true);
  const roads = parsed.items.filter((i) => i.kind === "road");
  assert.equal(roads.length, 3);
  assert.equal(roads[1].status, "closed");
  assert.equal(roads[0].sourceDate, "2026-10-23");
  assert.ok(parsed.items.some((i) => i.kind === "roadwork" && /El Capitan Bridge/.test(i.title)));
  assert.ok(parsed.items.some((i) => i.kind === "trail" && /Mist Trail/.test(i.text)));
});

test("chain-control records normalise route and requirement", () => {
  const rec = normaliseChainRecord({ cc: { route: "SR-120", chainControlStatus: "R-2: Chains required on all vehicles except 4WD", locationDescription: "Crane Flat", recordTimestamp: { recordDate: "2026-12-01", recordTime: "06:30:00" } } }, "10");
  assert.equal(rec.route, "SR-120");
  assert.equal(rec.requirement, "R2");
  assert.equal(rec.recordedAt, "2026-12-01T06:30:00");
});
