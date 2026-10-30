// Regenerates the optional GIS explorer packs from the public NPS Yosemite GIS services.
// Output: <EXPLORER_DIR>/<id>-<sha16>.geojson.gz plus catalog.json in the shape the app expects.
import { createHash } from "node:crypto";
import { gzipSync } from "node:zlib";
import { mkdirSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { loadEnv, env } from "../src/lib/env.js";
import { fetchJSON } from "../src/lib/http.js";

loadEnv();
const out = resolve(process.cwd(), env("EXPLORER_DIR", "./public/data/explorer"));
mkdirSync(out, { recursive: true });

const LAYERS = [
  { id: "trails", title: "Park trails", description: "Trail segments, surfaces, use designations, slope and recorded accessibility attributes.", color: "#a85432", sourceUrl: "https://services1.arcgis.com/fBc8EJBxQRMcHlei/arcgis/rest/services/YOSE_Trails/FeatureServer/0" },
  { id: "roads", title: "Park roads", description: "Detailed road centerlines, names, classifications, recorded directions and seasonal notes.", color: "#45698c", sourceUrl: "https://services1.arcgis.com/fBc8EJBxQRMcHlei/arcgis/rest/services/YOSE_Roads/FeatureServer/0" },
  { id: "buildings", title: "Buildings & names", description: "Footprints with building names, numbers, uses, seasons and record provenance.", color: "#705594", sourceUrl: "https://services1.arcgis.com/fBc8EJBxQRMcHlei/arcgis/rest/services/YOSE_Buildings/FeatureServer/1" },
  { id: "structures", title: "Shelters & other structures", description: "Non-building footprints such as covered facilities, shelters and recreation structures.", color: "#b36616", sourceUrl: "https://services1.arcgis.com/fBc8EJBxQRMcHlei/arcgis/rest/services/YOSE_Structures/FeatureServer/0" },
  { id: "parking", title: "Parking areas", description: "Parking polygons and labels; a mapped area does not establish current access or availability.", color: "#73704a", sourceUrl: "https://services1.arcgis.com/fBc8EJBxQRMcHlei/arcgis/rest/services/YOSE_Parking/FeatureServer/0" },
  { id: "pois", title: "Places & seasonal uses", description: "All published Yosemite POI categories, including ice rinks, bridges, facilities and trailheads.", color: "#197a69", sourceUrl: "https://mapservices.nps.gov/arcgis/rest/services/NationalDatasets/NPS_Public_POIs_Geographic/FeatureServer/0", where: "UNITCODE='YOSE'" },
];

async function fetchAll(layer) {
  const features = [];
  let offset = 0;
  const { data: meta } = await fetchJSON(`${layer.sourceUrl}?f=pjson`);
  const pageSize = Math.min(meta.maxRecordCount ?? 1000, 2000);
  const fields = Object.fromEntries((meta.fields ?? []).map((f) => [f.name, f.alias ?? f.name]));
  for (;;) {
    const url = `${layer.sourceUrl}/query?where=${encodeURIComponent(layer.where ?? "1=1")}&outFields=*&outSR=4326&f=geojson&resultOffset=${offset}&resultRecordCount=${pageSize}`;
    const { data } = await fetchJSON(url, { timeoutMs: 120_000 });
    features.push(...(data.features ?? []));
    if (!data.properties?.exceededTransferLimit && (data.features ?? []).length < pageSize) break;
    offset += pageSize;
  }
  return { features, fields, sourceUpdatedAt: meta.editingInfo?.lastEditDate ? new Date(meta.editingInfo.lastEditDate).toISOString() : new Date().toISOString() };
}

const catalog = { schema: 1, generatedAt: new Date().toISOString(), layers: [] };
for (const layer of LAYERS) {
  console.log(`fetching ${layer.id}…`);
  const { features, fields, sourceUpdatedAt } = await fetchAll(layer);
  const geojson = JSON.stringify({ type: "FeatureCollection", name: layer.id, features });
  const gz = gzipSync(Buffer.from(geojson));
  const sha = createHash("sha256").update(gz).digest("hex");
  const file = `${layer.id}-${sha.slice(0, 16)}.geojson.gz`;
  writeFileSync(resolve(out, file), gz);
  catalog.layers.push({ ...layer, publisher: "National Park Service · Yosemite GIS", scope: "Yosemite park-wide", updatePolicy: "Publisher-maintained; no guaranteed schedule. This dated snapshot changes when a newer pack is published.", fetchedAt: catalog.generatedAt, sourceUpdatedAt, file: `/data/explorer/${file}`, sha256: sha, count: features.length, compressedBytes: gz.length, unpackedBytes: Buffer.byteLength(geojson), fields });
  console.log(`  ${features.length} records → ${file}`);
}
writeFileSync(resolve(out, "catalog.json"), JSON.stringify(catalog, null, 2));
console.log(`catalog written to ${resolve(out, "catalog.json")}`);
