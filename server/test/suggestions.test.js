import { test, before } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

before(() => { process.env.DATA_DIR = mkdtempSync(join(tmpdir(), "pfg-server-")); });

const { submit, status, reply } = await import("../src/suggestions.js");
const push = await import("../src/push.js");

test("suggestions issue opaque receipts and only answer matching receipt+name pairs", () => {
  assert.throws(() => submit({ text: "" }), /1–250/);
  assert.throws(() => submit({ text: "x".repeat(251) }), /1–250/);
  const first = submit({ name: "Pat", title: "Map", text: "Add a north arrow." });
  assert.match(first.receipt, /^[0-9a-f]{48}$/);
  assert.equal(first.status, "received");
  assert.throws(() => submit({ name: "Pat", text: "second device" }), /already in use/);
  const again = submit({ name: "Pat", text: "same device", proof: first.receipt });
  assert.notEqual(again.receipt, first.receipt);
  const { responses } = status({ receipts: [{ receipt: first.receipt, name: "Pat" }, { receipt: first.receipt, name: "Someone" }, { receipt: "unknown", name: null }] });
  assert.equal(responses.length, 1);
  reply(first.receipt, "Added in 0.2.", { close: true });
  const after = status({ receipts: [{ receipt: first.receipt, name: "Pat" }] }).responses[0];
  assert.equal(after.reply, "Added in 0.2.");
  assert.equal(after.closed, true);
});

test("push registration validates tokens and reports readiness honestly", () => {
  assert.throws(() => push.register({ token: "not hex" }), /hex APNs device token/);
  const token = "a".repeat(64);
  const r = push.register({ token, preferences: { weather: { track: true, push: true } } });
  assert.equal(r.accepted, true);
  assert.equal(r.pushReady, false, "no APNs credentials configured in tests");
  assert.equal(push.unregister({ token }).accepted, true);
});
