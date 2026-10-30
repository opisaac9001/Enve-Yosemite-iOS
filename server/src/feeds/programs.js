import { nowISO } from "../lib/http.js";
import { npsEvents, npsVisitorCenters } from "./nps.js";

const WINDOW_DAYS = 45;

function pacificDay(date) {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "America/Los_Angeles", year: "numeric", month: "2-digit", day: "2-digit" }).format(date);
}

export async function buildPrograms() {
  const start = pacificDay(new Date());
  const end = pacificDay(new Date(Date.now() + WINDOW_DAYS * 86_400_000));
  const events = await npsEvents(start, end);
  const centers = await npsVisitorCenters();
  return {
    kind: "nps", version: 1, fetchedAt: nowISO(),
    window: { start, end, days: WINDOW_DAYS },
    visitorCenters: { state: centers.status.state, checkedAt: centers.status.checkedAt, items: centers.value ?? [], ...(centers.status.detail ? { detail: centers.status.detail } : {}) },
    events: { state: events.status.state, checkedAt: events.status.checkedAt, items: events.value?.items ?? [], total: events.value?.total ?? null, url: events.status.url, ...(events.status.detail ? { detail: events.status.detail } : {}) },
    statuses: [events.status, centers.status],
  };
}
