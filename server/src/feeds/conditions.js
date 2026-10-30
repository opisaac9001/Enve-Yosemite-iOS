import { fetchText, sourced, nowISO } from "../lib/http.js";
import { npsAlerts, npsRoadEvents, stripHtml } from "./nps.js";

export const CONDITIONS_URL = "https://www.nps.gov/yose/planyourvisit/conditions.htm";
export const WILDERNESS_URL = "https://www.nps.gov/yose/planyourvisit/wildcond.htm";

const slug = (s) => s.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 60);

function pageDate(html) {
  const m = /Last updated:?\s*<\/[^>]+>\s*([A-Z][a-z]+ \d{1,2}, \d{4})/i.exec(html) || /Last updated:?\s*([A-Z][a-z]+ \d{1,2}, \d{4})/i.exec(html);
  if (!m) return null;
  const d = new Date(`${m[1]} UTC`);
  return Number.isNaN(d.getTime()) ? null : d.toISOString().slice(0, 10);
}

/** Parses the road status table, roadwork and trail sections of the NPS conditions page. */
export function parseConditionsPage(html) {
  const items = [];
  const sourceDate = pageDate(html);
  let roadTableFound = false;
  let roadTableNote = null;
  const tableMatch = /<table[^>]*>([\s\S]*?)<\/table>/gi;
  let table;
  while ((table = tableMatch.exec(html))) {
    const rows = [...table[1].matchAll(/<tr[^>]*>([\s\S]*?)<\/tr>/gi)].filter((r) => !/<th[\s>]/i.test(r[1])).map((r) => [...r[1].matchAll(/<td[^>]*>([\s\S]*?)<\/td>/gi)].map((c) => stripHtml(c[1]).replace(/\s+/g, " ").trim()));
    const roadRows = rows.filter((cells) => cells.length >= 2 && /road|drive|highway/i.test(cells[0]));
    if (roadRows.length < 3) continue;
    roadTableFound = true;
    for (const cells of roadRows) {
      const titleMatch = /^([^(]+?)\s*(\(.*\))?$/.exec(cells[0]);
      const title = (titleMatch?.[1] ?? cells[0]).trim();
      const statusText = cells[1];
      const status = /^open/i.test(statusText) ? "open" : /^closed/i.test(statusText) ? "closed" : /chain/i.test(statusText) ? "restricted" : null;
      items.push({ url: CONDITIONS_URL, sourceDate, id: `road:${slug(title)}`, kind: "road", title, statusText, status, text: [titleMatch?.[2], cells[2]].filter(Boolean).join(" "), area: "Road Status", subjects: [title] });
    }
    const note = /Call 209\/?372-0200[^<]*/i.exec(html);
    roadTableNote = note ? stripHtml(note[0]).trim() : null;
  }
  const sections = [...html.matchAll(/<h[23][^>]*>([\s\S]*?)<\/h[23]>([\s\S]*?)(?=<h[23]|$)/gi)].map((m) => [stripHtml(m[1]).trim(), m[2]]);
  let roadworkFound = false;
  let trailsFound = false;
  for (const [heading, body] of sections) {
    if (/roadwork|road work|construction/i.test(heading)) {
      roadworkFound = true;
      for (const h of body.matchAll(/<(?:h4|strong|b)[^>]*>([\s\S]*?)<\/(?:h4|strong|b)>([\s\S]*?)(?=<(?:h4|strong|b)|$)/gi)) {
        const title = stripHtml(h[1]).trim();
        if (!title) continue;
        items.push({ url: CONDITIONS_URL, sourceDate, id: `roadwork:${slug(title)}`, kind: "roadwork", title, statusText: null, status: null, text: stripHtml(h[2]).slice(0, 1200).trim(), area: "Current Roadwork", subjects: [title] });
      }
    } else if (/trail|closure|area/i.test(heading) && !/road status/i.test(heading)) {
      const paragraphs = [...body.matchAll(/<(?:li|p)[^>]*>([\s\S]*?)<\/(?:li|p)>/gi)].map((p) => stripHtml(p[1]).replace(/\s+/g, " ").trim()).filter((t) => t.length > 8);
      if (!paragraphs.length) continue;
      trailsFound = true;
      for (const text of paragraphs) {
        const title = text.length > 90 ? `${text.slice(0, 88)}…` : text;
        items.push({ url: CONDITIONS_URL, sourceDate, id: `trail:${slug(heading)}:${slug(text)}`, kind: "trail", title, statusText: null, status: null, text, area: heading, subjects: [] });
      }
    }
  }
  return { items, pageUpdated: sourceDate, roadTableFound, roadTableNote, trailsFound, roadworkFound };
}

export function parseWildernessPage(html) {
  const sourceDate = pageDate(html);
  const report = /(?:report(?:ed)?|updated|as of)[^<]{0,40}?([A-Z][a-z]+ \d{1,2}, \d{4})/i.exec(stripHtml(html));
  const reportDate = report ? new Date(`${report[1]} UTC`).toISOString().slice(0, 10) : null;
  const items = [];
  for (const m of html.matchAll(/<h[34][^>]*>([\s\S]*?)<\/h[34]>([\s\S]*?)(?=<h[234]|$)/gi)) {
    const area = stripHtml(m[1]).trim();
    const paragraphs = [...m[2].matchAll(/<(?:li|p)[^>]*>([\s\S]*?)<\/(?:li|p)>/gi)].map((p) => stripHtml(p[1]).replace(/\s+/g, " ").trim()).filter((t) => t.length > 20);
    for (const text of paragraphs) {
      items.push({ url: WILDERNESS_URL, sourceDate, reportDate, statusText: null, status: null, id: `wilderness:${slug(area)}:${slug(text)}`, kind: "wilderness", title: text.length > 90 ? `${text.slice(0, 88)}…` : text, text, area, subjects: [] });
    }
  }
  return { items, pageUpdated: sourceDate, reportDate };
}

export async function buildConditions() {
  const statuses = [];
  const page = await sourced("nps-conditions", "NPS current conditions (road table, roadwork, trail closures)", CONDITIONS_URL, async () => {
    const { text } = await fetchText(CONDITIONS_URL, { accept: "text/html" });
    const parsed = parseConditionsPage(text);
    return { value: parsed, state: parsed.roadTableFound ? "ready" : "unknown", detail: parsed.roadTableFound ? undefined : "Road table not recognised on the page" };
  });
  statuses.push(page.status);
  const roadEvents = await npsRoadEvents();
  statuses.push(roadEvents.status);
  const alerts = await npsAlerts();
  statuses.push(alerts.status);
  const wilderness = await sourced("nps-wilderness", "NPS wilderness conditions (dated reports)", WILDERNESS_URL, async () => {
    const { text } = await fetchText(WILDERNESS_URL, { accept: "text/html" });
    return { value: parseWildernessPage(text) };
  });
  statuses.push(wilderness.status);

  const alertItems = (alerts.value ?? []).map((a) => ({ id: `alert:${a.id.toLowerCase()}`, kind: "alert", title: a.title, statusText: null, status: null, text: a.description, area: a.category, subjects: [a.title], url: a.url ?? CONDITIONS_URL, sourceDate: a.lastModified, start: null, end: null }));
  return {
    kind: "conditions", version: 1, fetchedAt: nowISO(),
    page: { state: page.status.state, checkedAt: page.status.checkedAt, url: CONDITIONS_URL, items: page.value?.items ?? [], pageUpdated: page.value?.pageUpdated ?? null, roadTableFound: page.value?.roadTableFound ?? false, roadTableNote: page.value?.roadTableNote ?? null, trailsFound: page.value?.trailsFound ?? false, roadworkFound: page.value?.roadworkFound ?? false },
    roadEvents: { state: roadEvents.status.state, checkedAt: roadEvents.status.checkedAt, url: roadEvents.status.url, items: roadEvents.value?.items ?? [], keyed: true, feedUpdated: roadEvents.value?.feedUpdated ?? null },
    alerts: { state: alerts.status.state, checkedAt: alerts.status.checkedAt, url: alerts.status.url, label: alerts.status.label, items: alertItems },
    wilderness: { state: wilderness.status.state, checkedAt: wilderness.status.checkedAt, url: WILDERNESS_URL, items: wilderness.value?.items ?? [], pageUpdated: wilderness.value?.pageUpdated ?? null, reportDate: wilderness.value?.reportDate ?? null },
    statuses,
  };
}
