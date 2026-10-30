#!/usr/bin/env python3 -I
"""Builds the bundled content and geometry packs for Enve Yosemite.

Inputs (gitignored): research/extracted/*.json (factual records parsed from the public
reference as data) and research/reference/data (public static packs).
Overlays: content/rewrites/*.json — original wording keyed by record id and field.
Outputs: ios/PettyFieldGuide/Resources/{Content,Geo,Documents}.
"""
import hashlib
import json
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EX = ROOT / "research" / "extracted"
REF = ROOT / "research" / "reference"
REWRITES = ROOT / "content" / "rewrites"
OUT = ROOT / "ios" / "PettyFieldGuide" / "Resources"
CONTENT = OUT / "Content"
GEO = OUT / "Geo"
DOCS = OUT / "Documents"


def load(name: str):
    return json.loads((EX / f"{name}.json").read_text())


def load_rewrites(dataset: str) -> dict:
    """Merges every content/rewrites/<dataset>*.json overlay (split files keep edits reviewable)."""
    merged: dict = {}
    for path in sorted(REWRITES.glob(f"{dataset}*.json")):
        for key, patch in json.loads(path.read_text()).items():
            merged.setdefault(key, {}).update(patch)
    return merged


def apply_rewrites(records: list, dataset: str, key: str = "id") -> int:
    overlay = load_rewrites(dataset)
    applied = 0
    for rec in records:
        patch = overlay.get(rec.get(key))
        if patch:
            rec.update(patch)
            applied += 1
    return applied


def write(name: str, payload) -> None:
    CONTENT.mkdir(parents=True, exist_ok=True)
    path = CONTENT / name
    path.write_text(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
    print(f"content/{name}: {path.stat().st_size:,} bytes")


def regex(value):
    if isinstance(value, dict) and "__regex__" in value:
        return {"pattern": value["__regex__"], "caseInsensitive": "i" in value.get("flags", "")}
    return value


# places

PLACE_FIELDS = [
    "id", "name", "campus", "categories", "latitude", "longitude", "mapPriority", "summary", "hours",
    "accessScope", "nearbyStops", "phones", "accessibility", "notice", "sources", "sourceUrl", "sourceNote",
    "tags", "checked", "details", "menus", "glyph", "facility", "bridge", "waterfall", "charging",
    "dumpStation", "waterIce", "campgroundId", "npsBuildingId", "stopNumber", "routes", "trailId",
    "unitNumber", "guestArea", "npsIds", "emails",
]


def norm_place(raw: dict, kind: str, listed: bool) -> dict:
    out = {k: raw[k] for k in PLACE_FIELDS if k in raw and raw[k] is not None}
    out.setdefault("hours", [])
    out.setdefault("nearbyStops", [])
    out.setdefault("phones", [])
    out.setdefault("sources", [])
    out.setdefault("tags", [])
    out.setdefault("details", [])
    out.setdefault("categories", [])
    out.setdefault("mapPriority", 3)
    out["kind"] = kind
    out["listed"] = listed
    if "waterfall" in out:
        out["waterfall"] = out["waterfall"]
    return out


WATERFALL_GUIDE = "https://www.nps.gov/yose/planyourvisit/waterfalls.htm"
POI_SERVICE = "https://mapservices.nps.gov/arcgis/rest/services/NationalDatasets/NPS_Public_POIs_Geographic/FeatureServer/0"
WATERFALL_TAGS = ["waterfall", "waterfalls", "falls", "fall", "cascade", "scenery", "snowmelt"]


def waterfall_place(raw: dict) -> dict:
    """Equivalent of the reference's waterfall record builder, expressed as data."""
    map_source = raw.get("mapSource", "GNIS")
    on_guide = raw.get("onNpsGuide", True) is not False
    object_id = raw["objectId"]
    point_url = f"{POI_SERVICE}/{object_id}?f=pjson"
    sources = []
    if on_guide:
        sources.append({"label": "NPS · Yosemite waterfalls (updated May 12, 2026)", "url": WATERFALL_GUIDE})
    sources.append({"label": f"NPS GIS · waterfall point {object_id}", "url": point_url})
    sources.extend(raw.get("extraSources", []))
    sources.append({"label": "NPS · current conditions (updated Oct 23, checked Oct 25, 2026)", "url": "https://www.nps.gov/yose/planyourvisit/conditions.htm"})
    waterfall = {
        "researchId": raw.get("researchId"), "npsObjectId": object_id, "npsFeatureId": raw.get("featureId"),
        "mapSource": map_source, "flowClass": raw.get("flowClass"), "normalSeason": raw.get("normalSeason"),
        "height": raw.get("height"), "viewing": raw.get("viewing"), "links": raw.get("links", []),
        "riverContext": raw.get("riverContext", False), "onNpsGuide": on_guide,
    }
    if raw.get("closure"):
        waterfall["closure"] = raw["closure"]
        waterfall["closureAsOf"] = raw.get("closureAsOf")
    return {
        "id": raw["id"], "name": raw["name"], "campus": raw["campus"], "categories": ["waterfalls"],
        "latitude": raw["latitude"], "longitude": raw["longitude"], "summary": raw["summary"],
        "hours": [raw["season"]], "mapPriority": raw.get("priority", 7), "checked": "2026-10-05",
        "tags": WATERFALL_TAGS + raw.get("tags", []), "notice": raw.get("notice"), "details": raw.get("details", []),
        "sourceUrl": WATERFALL_GUIDE if on_guide else point_url,
        "sourceNote": ("NPS waterfall guide (updated May 12, 2026), rechecked October 5, 2026. " if on_guide else "Not on the NPS waterfall guide (rechecked October 5, 2026). ")
                      + f"Pin: NPS public GIS point {object_id} (source {map_source}), feature edited January 9, 2026; positional accuracy unknown. Normal season only; no current flow observation.",
        "sources": sources, "waterfall": waterfall,
    }


BRIDGE_SUMMARIES = {
    "pois": "A crossing recorded by name in the NPS public places layer; nothing beyond the name is published.",
    "trails": "A footbridge recorded by name in the NPS trails layer; nothing beyond the name is published.",
    "roads": "A road bridge recorded by name in the NPS roads layer; nothing beyond the name is published.",
}
EV_DETAIL_LABELS = {"Brand / network": "Network", "Before charging": "Before you plug in", "Installation / management": "Who runs it"}


def template_wording(p: dict) -> None:
    """Original phrasing for records whose extracted text is a repeated template."""
    kind = p["kind"]
    if kind == "bridge":
        layer = ((p.get("bridge") or {}).get("sourceIds") or [{}])[0].get("layer", "pois")
        if p.get("summary", "").startswith("Named "):
            p["summary"] = BRIDGE_SUMMARIES.get(layer, BRIDGE_SUMMARIES["pois"])
        if p.get("notice", "").startswith("Current access, bridge condition"):
            p["notice"] = "Mapped position only. The inventory says nothing about today's access, load limits or seasonal closures; check NPS conditions and the signs on site before counting on this crossing."
        note = p.get("sourceNote", "")
        if note.startswith("NPS public GIS inventory; points retrieved"):
            p["sourceNote"] = "NPS public GIS points retrieved October 2, 2026 (feature edited January 9, 2026). Appearing on a public map is not evidence that the crossing is open."
        elif note.startswith("NPS public GIS inventory; Valley corridors"):
            p["sourceNote"] = "NPS public GIS Valley corridors retrieved September 21, 2026; this feature's own edit date was not kept. Appearing on a public map is not evidence that the crossing is open."
    elif kind in ("water", "ice"):
        if p.get("notice", "").startswith("Recorded location, not live availability"):
            p["notice"] = "This marks where a tap or machine was recorded, not whether it works today. Seasonal shut-offs, repairs and access rules change; follow the signs."
        if p.get("summary", "").startswith("At the ") and "campground bathroom station" in p.get("summary", ""):
            campground = p["name"].split(" · ")[0]
            p["summary"] = f"At one of the {campground} campground restroom stations; the potable tap is signed."
    elif kind == "charging":
        if p.get("notice", "").startswith("Pin is an NPS digitized orientation point"):
            p["notice"] = "NPS digitized this point for orientation and its accuracy is unknown. Look for the signed bays; whether the equipment works or a bay is free is not known to this guide."
        note = p.get("sourceNote", "")
        m = re.search(r"feature (\d+)", note)
        if m and "Charging details from the NPS EV guide" in note:
            p["sourceNote"] = f"NPS public GIS feature {m.group(1)}, reviewed October 2, 2026. Port counts and plug types come from the NPS EV guide (updated January 8, 2026); network and rated power were cross-checked against AFDC the same day."
        charging = p.get("charging") or {}
        rewritten = []
        for d in p.get("details", []):
            label, text = d["label"], d["text"]
            if label == "Chargers at this pin":
                text = f"{charging.get('count', '?')} {charging.get('connector', 'J1772')} ports, Level 2 AC. This is the installed count, not how many are free."
            elif label == "Brand / network":
                text = f"{charging.get('network', 'Network not recorded')}, per the AFDC station record."
            elif label == "Rated power" and charging.get("maxKw"):
                text = f"AFDC lists up to {charging['maxKw']:g} kW per port. What your car draws depends on the vehicle and the site."
            elif label == "Installation / management" and "Rivian" in text:
                text = "Installed under the Rivian and Adopt a Charger program for Yosemite and managed by Yosemite Hospitality according to NPS. The electrical contractor is not recorded."
            elif label == "Before charging":
                text = "Carry the J1772 adapter your car needs, read the posted price and idle-fee rules instead of assuming charging is free, and expect no live status: this guide has no occupancy feed."
            elif label == "Season / operation":
                text = "Access depends on Tioga Road, and a published inventory does not prove the chargers are working; check locally before relying on this stop."
            rewritten.append({"label": EV_DETAIL_LABELS.get(label, label), "text": text})
        p["details"] = rewritten
    elif kind == "facility":
        p["summary"] = {
            "toilet": "A restroom point from the NPS places layer.",
            "shower": "A shower facility from the NPS places layer.",
            "accessible-parking": "An accessible parking point from the NPS places layer.",
            "water": "A drinking-water point from the NPS places layer.",
        }.get(p.get("facility"), p.get("summary", ""))


def build_places() -> list:
    places: list[dict] = []
    for rec in load("Zb"):
        places.append(norm_place(rec, "place", True))
    for rec in load("Qb"):
        places.append(norm_place(rec, "bridge", True))
    waterfall_rewrites = load_rewrites("waterfalls")
    for raw in load("Wd"):
        raw.update(waterfall_rewrites.get(raw["id"], {}))
        places.append(norm_place(waterfall_place(raw), "waterfall", True))
    for rec in load("Od"):
        places.append(norm_place(rec, "charging", True))
    for rec in load("rg"):
        places.append(norm_place(rec, "dump-station", True))
    for rec in load("Nh"):
        kind = rec.get("waterIce", {}).get("kind", "water")
        places.append(norm_place(rec, kind, True))

    glyphs = load("C4")
    facility_note = load("j4")
    for rec in load("A4"):
        facility = rec["facility"]
        categories = {"toilet": ["facilities"], "shower": ["facilities"], "accessible-parking": ["parking"], "water": ["water"]}[facility]
        p = {
            "id": rec["id"], "name": rec["name"], "campus": rec["campus"], "categories": categories,
            "latitude": rec["latitude"], "longitude": rec["longitude"], "mapPriority": 2,
            "summary": rec["summary"], "hours": [facility_note],
            "accessScope": "registered-guest" if rec.get("guestArea") else "unknown",
            "tags": rec.get("tags", []), "glyph": glyphs.get(facility), "facility": facility,
            "guestArea": rec.get("guestArea", False), "npsIds": rec.get("npsIds", []),
            "sourceUrl": f"https://mapservices.nps.gov/arcgis/rest/services/NationalDatasets/NPS_Public_POIs_Geographic/FeatureServer/0/{rec['npsIds'][0]}?f=pjson" if rec.get("npsIds") else None,
            "sources": [{"label": f"NPS · points of interest record {i}", "url": f"https://mapservices.nps.gov/arcgis/rest/services/NationalDatasets/NPS_Public_POIs_Geographic/FeatureServer/0/{i}?f=pjson"} for i in rec.get("npsIds", [])],
            "checked": "2026-10-02",
        }
        places.append(norm_place(p, "facility", True))

    # Shuttle stops: NPS timetable points, replaced by NPS GIS stop points where published.
    info = load("Ia")
    east = set(load("f4"))
    gis = load("gd")
    source_url = load("Sy")
    for stop in load("rv"):
        n = stop["n"]
        routes = ["valleywide", "east-valley"] if n in east else ["valleywide"]
        g = gis.get(str(n))
        p = {
            "id": f"shuttle-{n}", "name": f"Stop {n} · {stop['destination']}", "campus": "Yosemite Valley Shuttle",
            "categories": ["shuttle"], "latitude": g["latitude"] if g else stop["latitude"],
            "longitude": g["longitude"] if g else stop["longitude"], "mapPriority": 10,
            "summary": "Served by the Valleywide and East Valley shuttle routes." if len(routes) == 2 else "Served by the Valleywide shuttle route only.",
            "hours": [f"Daily · {info['hours']}", info["fare"]],
            "phones": [{"label": "Park information", "number": "209-372-0200"}],
            "nearbyStops": [n], "accessibility": info["accessibility"],
            "tags": [f"stop {n}", "shuttle", "bus"], "sourceUrl": source_url,
            "sourceNote": ("Pin uses the NPS public GIS stop point (reviewed October 2, 2026), which differs from the timetable-feed point. Digitized location of unknown accuracy; follow the signed boarding area."
                           if g else "Pin uses the NPS timetable-feed location: approximate, not a surveyed boarding point."),
            "sources": ([{"label": "NPS · mapped shuttle point", "url": "https://mapservices.nps.gov/arcgis/rest/services/NationalDatasets/NPS_Public_POIs_Geographic/FeatureServer/0?f=pjson"}] if g else [])
                       + [{"label": "NPS · shuttle service", "url": source_url}],
            "stopNumber": n, "routes": routes,
        }
        places.append(norm_place(p, "shuttle-stop", True))

    # Housekeeping units: approximate building centres from NPS building records.
    pt = load("pt")
    hk = pt["housekeeping-camp"]
    hk_sources = load("is") + load("dn")
    for unit in load("M4"):
        ambiguous = unit["latitude"] is None or unit["longitude"] is None
        p = {
            "id": f"housekeeping-unit-{unit['site']}", "name": f"Housekeeping Camp · unit {unit['site']}",
            "unitNumber": unit["site"], "campus": "Housekeeping Camp", "categories": ["lodging"], "mapPriority": 1,
            "glyph": unit["site"], "latitude": unit["latitude"] if not ambiguous else hk["latitude"],
            "longitude": unit["longitude"] if not ambiguous else hk["longitude"],
            "summary": ("This unit number appears on conflicting NPS building records, so the pin marks the camp front desk. Confirm the unit's location there or on the property map."
                        if ambiguous else f"Approximate centre of the NPS building record labelled {unit['buildingNames'][0]}. Units in the same building share this pin, which is not an entrance."),
            "hours": [load("bl")], "phones": [{"label": "Lodging reservations", "number": "888-413-8869"}, {"label": "Yosemite Hospitality switchboard · ask for Housekeeping Camp", "number": "209-372-1001"}],
            "details": load("Gb"), "sources": hk_sources, "checked": "2026-10-01", "accessScope": "registered-guest",
            "nearbyStops": [12],
            "notice": "Mapped inventory, not booking availability. Current unit use and pin accuracy are not field-verified.",
            "sourceUrl": hk_sources[2]["url"],
            "sourceNote": "NPS building inventory fetched September 21, 2026; operator property map reviewed October 1, 2026. Map and GIS numbering disagree in places: the operator lists 266 units while GIS carries 279 labels.",
            "tags": ["housekeeping", "unit", "site", unit["site"], *unit["buildingNames"]],
        }
        if ambiguous:
            p["tags"].append("ambiguous")
        places.append(norm_place(p, "housekeeping-unit", False))

    # Trail places mirror the twelve hikes on the map and in the directory, with the same reviewed wording,
    # published routes and start points as trails.json.
    hikes = load("Dl")
    apply_rewrites(hikes, "trails")
    for trail in hikes:
        routes_text = " / ".join(
            f"{r['distanceMi']:g} mi {r['kind']}" + (f", {r['gainFt']:,} ft gain" if r.get("gainFt") else "") for r in trail["routes"]
        )
        p = {
            "id": trail["id"], "trailId": trail["id"], "name": trail["name"], "campus": "Valley trails", "categories": ["outdoors"],
            "latitude": trail["latitude"], "longitude": trail["longitude"], "summary": trail["summary"],
            "hours": [f"{trail['difficulty']} · {routes_text}", f"Start: {trail['start']}"],
            "nearbyStops": trail.get("shuttleStops", []), "accessibility": trail.get("accessibility"),
            "notice": trail["notes"][0] if trail.get("notes") else None,
            "tags": ["trail", "hike", "hiking", trail["difficulty"].lower()],
            "sourceUrl": (trail.get("sources") or [{}])[0].get("url", "https://www.nps.gov/yose/planyourvisit/valleyhikes.htm"),
            "sources": trail.get("sources", []), "mapPriority": trail.get("mapPriority", 5),
        }
        places.append(norm_place(p, "trail", True))

    for p in places:
        template_wording(p)
    seen: set[str] = set()
    for p in places:  # two NPS facility points share a generated id; keep both with a stable suffix
        base = p["id"]
        suffix = 2
        while p["id"] in seen:
            p["id"] = f"{base}-{suffix}"
            suffix += 1
        seen.add(p["id"])
    applied = apply_rewrites(places, "places")
    print(f"places: {len(places)} ({sum(1 for p in places if p['listed'])} listed, {applied} rewritten)")
    return places


# other packs

HIKES = ROOT / "content" / "hikes"


def build_trails():
    trails = load("Dl")
    apply_rewrites(trails, "trails")
    # Stable route ids come from the reviewed route manifest, matched by trail and published label.
    manifest = json.loads((HIKES / "hike-routes.json").read_text())
    for trail in trails:
        for route in trail["routes"]:
            match = [r for r in manifest["routes"] if r["trailId"] == trail["id"] and r["label"] == route["label"]]
            if len(match) != 1:
                sys.exit(f"hike-routes.json must define exactly one route for {trail['id']} / {route['label']!r} (found {len(match)})")
            route["id"] = match[0]["id"]
    return {
        "trails": trails,
        "corridorRepairNotice": load("hl"),
        "iceClosureNotice": load("Sh"),
        "mistTrailIds": load("Xb"),
        "johnMuirValleyIds": load("Q6"),
        "preparationTips": load("ov"),
    }


def build_campgrounds():
    campgrounds = load("_i")
    apply_rewrites(campgrounds, "campgrounds")
    return {"campgrounds": campgrounds, "guidance": load("uv"),
            "source": {"label": "NPS · Campgrounds (updated Sep 28, 2026)", "url": "https://www.nps.gov/yose/planyourvisit/campgrounds.htm", "updated": "2026-09-28"},
            "checked": "2026-10-05"}


def build_permits():
    guides = json.loads((EX / "$n.json").read_text())
    apply_rewrites(guides, "permits")
    return {"guides": guides, "requirementLabels": load("yg"), "groups": json.loads((EX / "$r.json").read_text()),
            "sources": load("_4"), "fireNotice": load("Py"), "fireNoticeLink": load("My")}


def build_contacts():
    contacts = load("xg")
    apply_rewrites(contacts, "contacts")
    return {"contacts": contacts, "groups": load("l9"), "emergency": load("xa")}


GROVE_LOCATION = "The Grove House, 4993 5th Street, Mariposa, outside Yosemite, per its homepage and ticket pages. The host's contact page gives 4995; check the entrance and accessibility with the venue."
ART_CLASS_DATES = re.compile(r"only (\d{4}-\d{2}-\d{2}) through (\d{4}-\d{2}-\d{2})")
RETREAT_DATES = re.compile(r"Program dates (\d{4}-\d{2}-\d{2})–(\d{4}-\d{2}-\d{2})")


def template_event(e: dict) -> None:
    """Original phrasing for the two large families of templated listings and shared venue text."""
    summary = e.get("summary", "")
    if summary.startswith("A four-hour beginner-friendly art class"):
        m = ART_CLASS_DATES.search(e.get("schedule", ""))
        setting = "indoors" if "; indoors" in e.get("location", "") else ("partly indoors and outdoors" if "partly indoors" in e.get("location", "") else "outdoors, weather permitting")
        e["summary"] = "A four-hour class with the named artist, open to beginners. Instruction and the class materials are included."
        e["schedule"] = (f"Weekdays 9 am to 1 pm Pacific, {m.group(1)} to {m.group(2)} only. " if m else "Weekdays 9 am to 1 pm Pacific. ") + "Each registration buys one class day. Ask the host about holiday and weather arrangements."
        e["location"] = f"Happy Isles Art and Nature Center at shuttle stop 16 in Yosemite Valley, {setting}. Confirm arrival instructions and the current shuttle service."
        e["cost"] = "$40 per person per class day, including instruction and class materials. Extra days are separate registrations; confirm the final fee with the host."
        e["registration"] = "Register in advance. Ages 12 and over; under-18s must come with an adult. Beginners welcome. Confirm space and whether a companion must also register; no place is guaranteed."
    elif summary.startswith("A three-day outdoor art retreat"):
        level = re.sub(r"^A three-day outdoor art retreat\. ", "", summary).split(" Walking")[0].strip()
        m = RETREAT_DATES.search(e.get("schedule", ""))
        where = "Tuolumne Meadows" if "Tuolumne Meadows" in e.get("location", "") else "Yosemite Valley"
        camp = "Tuolumne Meadows Campground" if where == "Tuolumne Meadows" else "Upper Pines Campground"
        price = re.search(r"\$(\d+) registration", e.get("cost", ""))
        window = re.search(r"camping window: (.+?)\.", e.get("registration", ""))
        independent = re.search(r"Optional independent day ([A-Z][a-z]+ \d+)", e.get("registration", ""))
        e["summary"] = f"Three days of outdoor art instruction. {level} Expect to walk one to three miles a day carrying supplies; daily class times are not on the event page."
        e["schedule"] = (f"Program days {m.group(1)} to {m.group(2)} only; " if m else "") + "daily times are not published. Camping arrival and departure" + (" and the optional independent day are" if independent else " is") + " outside the class dates."
        e["location"] = f"{where}; the exact meeting point comes from the host. Camping included at {camp}. Nothing here implies current road, campground or trail access."
        e["cost"] = (f"${price.group(1)} registration" if price else "Registration") + " includes shared tent camping for participants only, with no discount for skipping it" + (" or the independent day" if independent else "") + ". Lodging upgrades cost extra; bring your own art supplies, camping gear, food and transport. Confirm the final fee."
        e["registration"] = f"Register in advance and confirm space, age rules and meeting details. {level} Camping is for participants only, so friends and family need their own arrangements; tents only, and sleeping in a vehicle needs your own campsite." + (f" Host camping window: {window.group(1)}." if window else "") + (f" The optional independent day on {independent.group(1)} is not a class date." if independent else "") + (" The index says Yosemite Valley while the detailed program says Tuolumne Meadows, which is used here." if where == "Tuolumne Meadows" else "")
    if e.get("location", "").startswith("The Grove House, 4993 5th Street, Mariposa, outside Yosemite, per its homepage"):
        e["location"] = GROVE_LOCATION


def build_events():
    events = load("Gn")
    for e in events:
        template_event(e)
    apply_rewrites(events, "events")
    return {"events": events, "npsMapping": load("zk"), "npsAreaRegions": load("qk")}


def build_regions():
    regions = load("wl")
    apply_rewrites(regions, "regions")
    return {"regions": regions, "approaches": load("d9"), "gatewayTowns": load("Ng"), "tripFacts": load("u9"),
            "schematicBounds": load("gl"), "valleyLandmarks": load("gk")}


def build_webcams():
    webcams = load("io")
    apply_rewrites(webcams, "webcams")
    return {"webcams": webcams, "providerNotes": load("h9"), "groups": load("Mh"), "groupOrder": load("m9")}


DOC_FILES = {
    "yosemite-guide-51-8": "yosemite-guide-51-8-7d377a5835d7.pdf",
    "accessibility-2022": "accessibility-2022-5ed9f1339cb9.pdf",
    "park-campground-map": "park-campground-map-971a4651bc81.pdf",
    "wilderness-trailheads": "wilderness-trailheads-4d2ef021231b.pdf",
    "junior-ranger-adapted-2021": "junior-ranger-adapted-2021-981bd1a40df3.pdf",
}


def build_documents():
    docs = load("Jr")
    DOCS.mkdir(parents=True, exist_ok=True)
    for doc in docs:
        src = REF / "documents" / DOC_FILES[doc["id"]]
        dst = DOCS / f"{doc['id']}.pdf"
        shutil.copyfile(src, dst)
        digest = hashlib.sha256(dst.read_bytes()).hexdigest()
        if digest != doc["sha256"]:
            sys.exit(f"sha256 mismatch for {doc['id']}")
        doc["bundledFile"] = f"{doc['id']}.pdf"
        doc.pop("file", None)
    apply_rewrites(docs, "documents")
    return docs


def build_status():
    risk_checks = load("Pv")
    return {
        "forecastPoints": load("dh"),
        "fireRegions": load("_b"),
        "riskChecks": risk_checks,
        "riskPatterns": {k: regex(v) for k, v in load("Sw").items()},
        "updateTopics": load("Bg"),
        "links": load("Ee"),
        "fireLinks": load("rn"),
        "visitorCenters": load("nu"),
        "shuttleInfo": load("Ia"),
        "guideEdition": load("ls"),
    }


def build_categories():
    return {"categories": load("tu"), "quickFilterNotes": load("w8")}


def build_notice_patterns():
    patterns = []
    for p in load("ev"):
        patterns.append({"id": p["id"], "pattern": regex(p["pattern"]), "area": regex(p.get("area")) if p.get("area") else None, "targets": p["targets"]})
    area_regions = [{"pattern": regex(p["pattern"]), "regions": p["regions"]} for p in load("K6")]
    return {"patterns": patterns, "areaRegions": area_regions, "parkingSources": load("zp"), "parkingWalks": load("mg")}


# geo

GEO_FILES = [
    "buildings.geojson", "parking.geojson", "pois.geojson", "roads.geojson", "trails.geojson",
    "park-roads.geojson", "park-pois.geojson", "park-boundary.geojson", "fire-scars.geojson",
    "campsites.geojson", "campground-context.geojson", "elevation-valley.json", "transit.json",
    "map-manifest.json", "park-manifest.json", "water-ice.json", "dump-stations.json",
]


def append_trail_features():
    """Adds the Little Yosemite Valley John Muir Trail features the Valley envelope query omits, keeping the
    original 610 features and ids intact, and records the addition in the map manifest."""
    trails_path = GEO / "trails.geojson"
    doc = json.loads(trails_path.read_text())
    extra = json.loads((HIKES / "trails-extra-lyv.geojson").read_text())
    existing = {f["id"] for f in doc["features"]}
    added = [f for f in extra["features"] if f["id"] not in existing]
    doc["features"] += added
    trails_path.write_text(json.dumps(doc, separators=(",", ":")))
    manifest_path = GEO / "map-manifest.json"
    manifest = json.loads(manifest_path.read_text())
    for layer in manifest["layers"]:
        if layer["file"] == "trails.geojson":
            layer["count"] = len(doc["features"])
            layer["bytes"] = trails_path.stat().st_size
            layer["sha256"] = hashlib.sha256(trails_path.read_bytes()).hexdigest()
            layer["appended"] = {"features": [f["id"] for f in extra["features"]], "fetchedAt": extra["source"]["fetchedAt"],
                                 "service": extra["source"]["service"], "query": extra["source"]["query"], "reason": extra["description"]}
    manifest_path.write_text(json.dumps(manifest, indent=2))
    print(f"trails.geojson: appended {len(added)} feature(s) → {len(doc['features'])}")


def build_geo():
    GEO.mkdir(parents=True, exist_ok=True)
    manifest = []
    for name in GEO_FILES:
        src = REF / "data" / name
        dst = GEO / name
        shutil.copyfile(src, dst)
    append_trail_features()
    for name in GEO_FILES:
        dst = GEO / name
        manifest.append({"file": name, "bytes": dst.stat().st_size, "sha256": hashlib.sha256(dst.read_bytes()).hexdigest()})
    waterways = load("yk")
    waterways.setdefault("type", "FeatureCollection")
    dst = GEO / "waterways.geojson"
    dst.write_text(json.dumps(waterways, separators=(",", ":")))
    manifest.append({"file": "waterways.geojson", "bytes": dst.stat().st_size, "sha256": hashlib.sha256(dst.read_bytes()).hexdigest()})
    # Relief grids are produced directly into the Geo folder by tools/prepare_basemap_terrain.py (public AWS tiles).
    for name in ("elevation-basemap.json", "elevation-region.json"):
        relief = GEO / name
        if not relief.exists():
            sys.exit(f"missing {name}: run tools/prepare_basemap_terrain.py first")
        manifest.append({"file": name, "bytes": relief.stat().st_size, "sha256": hashlib.sha256(relief.read_bytes()).hexdigest()})
    explorer = json.loads((REF / "data" / "explorer" / "catalog.json").read_text())
    (GEO / "explorer-catalog.json").write_text(json.dumps(explorer, separators=(",", ":")))
    print(f"geo: {len(manifest)} files, {sum(m['bytes'] for m in manifest):,} bytes")
    return manifest


def main():
    places = build_places()
    write("places.json", places)
    write("trails.json", build_trails())
    write("campgrounds.json", build_campgrounds())
    write("permits.json", build_permits())
    write("contacts.json", build_contacts())
    write("events.json", build_events())
    write("regions.json", build_regions())
    write("webcams.json", build_webcams())
    write("documents.json", build_documents())
    write("status.json", build_status())
    write("categories.json", build_categories())
    write("notices.json", build_notice_patterns())
    write("changelog.json", json.loads((ROOT / "content" / "changelog.json").read_text()))
    write("housekeeping.json", {"details": load("Gb"), "sources": load("is") + load("dn"), "season": load("bl"), "frontDeskPlaceId": "housekeeping-camp"})
    manifest = build_geo()
    write("pack-manifest.json", {"built": "2026-10-27", "geo": manifest})
    # Resolved hike routes depend on the final trails.geojson and trails.json written above.
    sys.path.insert(0, str(ROOT / "tools"))
    import build_hike_routes
    build_hike_routes.build()


if __name__ == "__main__":
    main()
