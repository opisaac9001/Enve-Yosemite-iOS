#!/usr/bin/env python3 -I
"""Writes the park-wide day-hike pack (hikes outside Yosemite Valley) from the curated records below.

Facts (distances, gains, published times, starting points, difficulty where NPS states one) come from the
NPS regional day-hike pages cited per record, checked 2026-10-30. Trailhead coordinates are NPS Public GIS
points of interest (NPS_Public_POIs_Geographic, UNITCODE YOSE, fetched 2026-10-30); the id is in each
`trailheadSource`. Wording is original. Route ids that tools/build_hike_routes.py traces are listed in its
manifest; every other route is published-only and the app says no trace is bundled.

Each hike also gets the roads its trailhead is reached by (keys of the road targets in Content/notices.json)
and distinctive route names used to match official notices. Pet rules cite the NPS pets page (updated
2026-06-24); Hetch Hetchy access lines cite the NPS Hetch Hetchy page (2026-06-11); accessibility lines for
Glacier Point and the Tuolumne and Merced groves cite the bundled NPS Accessibility Guide (Summer 2022).

Usage: python3 -I tools/build_park_hikes.py
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "ios" / "PettyFieldGuide" / "Resources" / "Content" / "park-hikes.json"
CHECKED = "2026-10-30"


def src(label, page, updated):
    return {"label": f"NPS · {label}", "url": f"https://www.nps.gov/yose/planyourvisit/{page}.htm", "updated": updated, "checked": CHECKED}


GLACIER = src("Day hikes along the Glacier Point Road", "glacierhikes", "2026-09-22")
WAWONA = src("Day hikes in Wawona and Mariposa Grove", "wawonahikes", "2024-10-15")
GROVE = src("Mariposa Grove of Giant Sequoias", "mg", "2026-06-11")
HETCH = src("Day hikes in Hetch Hetchy", "hetchhetchy", "2023-08-22")
WHITEWOLF = src("Day hikes in Crane Flat and White Wolf", "whitewolf", "2024-10-15")
SEQUOIAS = src("Giant sequoias", "sequoias", "2025-04-07")
TUOLUMNE = src("Day hikes in Tuolumne Meadows", "tmhikes", "2024-10-15")
HIKING = src("Hiking", "hiking", "2024-11-08")

PETS = src("Pets", "pets", "2026-06-24")
HH_VISIT = src("Visiting Hetch Hetchy", "hh", "2026-06-11")
ACCESS_GUIDE = {"label": "NPS · Yosemite Accessibility Guide (Summer 2022, bundled in Documents)", "url": "https://www.nps.gov/yose/planyourvisit/upload/access2022.pdf",
                "updated": "2022-05", "checked": CHECKED}

UNRATED = "Not rated by NPS"


def route(rid, label, miles, kind, gain=None, time=None, difficulty=None, source=None):
    r = {"id": rid, "label": label, "distanceMi": miles, "kind": kind}
    if gain is not None:
        r["gainFt"] = gain
    if time is not None:
        r["time"] = time
    if difficulty is not None:
        r["difficulty"] = difficulty
        r["difficultySource"] = source
    return r


def hike(tid, name, region, routes, summary, start, poi, lonlat, sources, difficulty=UNRATED, notes=(), warnings=None,
         discrepancies=None, accessibility=None, pets=None, priority=5):
    t = {
        "id": tid, "name": name, "regionId": region, "difficulty": difficulty, "routes": routes, "summary": summary,
        "start": start, "trailheadSource": poi, "latitude": lonlat[1], "longitude": lonlat[0], "shuttleStops": [], "gisNames": [],
        "notes": list(notes), "mapPriority": priority, "sources": sources,
    }
    for key, value in (("warnings", warnings), ("discrepancies", discrepancies), ("accessibility", accessibility), ("pets", pets)):
        if value:
            t[key] = value
    return t


DOMES = "Stay off domes and exposed summits when thunderstorms threaten."
TIOGA_SEASON = "Reached by car only while Tioga Road is open, typically from May or June to November."
GP_SEASON = "Reached by car only while Glacier Point Road is open, usually from May to November."

HIKES = [
    # Glacier Point Road
    hike("trail-glacier-point-overlook", "Glacier Point Overlook", "glacier-point",
         [route("glacier-point-overlook-walk", "To the overlook", 0.17, "one way", time="10–15 minutes")],
         "A short paved stroll from the parking area to the railing 3,200 feet above Yosemite Valley, facing Half Dome and the High Sierra.",
         "Glacier Point parking area", "NPS POI 21520 (Glacier Point Trailhead)", (-119.573491, 37.727709), [GLACIER],
         notes=["NPS gives the distance as 300 yards each way on a paved, gently rising path.", GP_SEASON], priority=7),
    hike("trail-mcgurk-meadow", "McGurk Meadow", "glacier-point",
         [route("mcgurk-meadow-rt", "Round trip", 1.6, "round trip", 150, "1–1.5 hours")],
         "A short downhill walk to a meadow and the historic McGurk cabin, best for early-summer wildflowers.",
         "McGurk Meadow Trailhead, Glacier Point Road", "NPS POI 21924 (McGurk Meadow Trailhead)", (-119.628121, 37.670447), [GLACIER],
         notes=["The 150 feet of climbing comes on the way back.", GP_SEASON]),
    hike("trail-sentinel-dome", "Sentinel Dome", "glacier-point",
         [route("sentinel-dome", "Round trip from the trailhead", 2, "round trip", 400, "1–2 hours")],
         "A short hike and a scramble up the side of a granite dome for a 360-degree view across Yosemite.",
         "Sentinel Dome / Taft Point Trailhead, Glacier Point Road", "NPS POI 20333 (Sentinel Dome Trailhead)", (-119.586349, 37.712552), [GLACIER],
         notes=[GP_SEASON], warnings=[DOMES], priority=7),
    hike("trail-taft-point", "Taft Point", "glacier-point",
         [route("taft-point", "Round trip from the trailhead", 2.2, "round trip", 200, "1–2 hours")],
         "Forest and meadow to the Valley rim, with views of El Capitan and Yosemite Falls from a sheer overlook.",
         "Sentinel Dome / Taft Point Trailhead, Glacier Point Road", "NPS POI 20333 (Sentinel Dome Trailhead)", (-119.586349, 37.712552), [GLACIER],
         notes=["The 200 feet of climbing comes on the way back.", GP_SEASON],
         warnings=["The overlook ends at unfenced cliff edges; keep well back from the rim."], priority=7),
    hike("trail-mono-meadow", "Mono Meadow", "glacier-point",
         [route("mono-meadow-rt", "Round trip", 3, "round trip", 900, "2–3 hours")],
         "A steep descent to a meadow that stays wet through summer; another half mile leads to views of the Clark Range, Mount Starr King and Half Dome.",
         "Mono Meadow Trailhead, Glacier Point Road", "NPS POI 22020 (Mono Meadow Trailhead)", (-119.584778, 37.671453), [GLACIER],
         notes=["NPS describes the descent as steep; the 900 feet of climbing comes on the way back.", GP_SEASON]),
    hike("trail-dewey-point", "Dewey Point", "glacier-point",
         [route("dewey-point-rt", "Round trip via McGurk Meadow", 7.6, "round trip", 750, "4–5 hours")],
         "Through McGurk Meadow to the Pohono Trail and along the Valley rim to a sweeping viewpoint.",
         "McGurk Meadow Trailhead, Glacier Point Road", "NPS POI 21924 (McGurk Meadow Trailhead)", (-119.628121, 37.670447), [GLACIER],
         notes=["NPS: a 250-foot descent to the Pohono Trail junction, then about 500 feet of climbing over the last two miles.", GP_SEASON],
         discrepancies=["The NPS page lists 7.6 miles alongside 13.2 km; 7.6 miles is about 12.2 km. The mile figure is shown."]),
    hike("trail-ostrander-lake", "Ostrander Lake", "glacier-point",
         [route("ostrander-lake-rt", "Round trip", 12, "round trip", 1500, "8–10 hours")],
         "A long day through forest and meadow, then a steep climb with views of Mount Starr King and the Clark Range before the lake.",
         "Ostrander Lake Trailhead, Glacier Point Road", "NPS POI 22812 (Ostrander Trailhead)", (-119.603609, 37.666739), [GLACIER],
         notes=[GP_SEASON]),
    hike("trail-panorama", "Panorama Trail", "glacier-point",
         [route("panorama-trail-mist", "One way to Happy Isles via the Mist Trail", 8.2, "one way", time="6–8 hours")],
         "From Glacier Point down to Illilouette Fall, an 800-foot climb, then down past Nevada and Vernal falls to the Valley floor.",
         "Glacier Point", "NPS POI 21520 (Glacier Point Trailhead)", (-119.573491, 37.727709), [GLACIER],
         notes=["One way: no shuttle runs between the Valley and Glacier Point. The seasonal Glacier Point Tour bus needs a reservation; NPS warns not to plan on it for the return.", GP_SEASON],
         warnings=["The Mist Trail above the Vernal Fall footbridge and the John Muir Trail between Clark Point and the Panorama junction can close for ice from November."],
         priority=6),
    hike("trail-pohono", "Pohono Trail", "glacier-point",
         [route("pohono-trail", "One way to Tunnel View", 12.5, "one way", time="8–10 hours")],
         "The full south rim of Yosemite Valley from Glacier Point to Tunnel View, past Sentinel Dome, Taft Point and Dewey Point.",
         "Glacier Point", "NPS POI 21520 (Glacier Point Trailhead)", (-119.573491, 37.727709), [GLACIER],
         notes=["One way: arrange a car or ride at Tunnel View.", GP_SEASON]),
    # Wawona and Mariposa Grove
    hike("trail-wawona-meadow-loop", "Wawona Meadow Loop", "wawona-mariposa-grove",
         [route("wawona-meadow-loop", "Loop around the meadow", 3.5, "loop", time="2–3 hours")],
         "Across the Wawona golf course on a paved road, then an unpaved fire road around the meadow; wildflowers in spring and early summer.",
         "Wawona Hotel", "NPS POI 21368 (Meadow Loop Trailhead)", (-119.657715, 37.535055), [WAWONA],
         notes=["Mostly flat with uneven ground.", "No drinking water on Wawona trails; the nearest fountain is by the restrooms at the Wawona Store parking area."],
         pets="Leashed pets and bicycles are allowed; NPS says this is the only hiking trail in Yosemite where they are.", priority=6),
    hike("trail-wawona-swinging-bridge", "Wawona Swinging Bridge", "wawona-mariposa-grove",
         [route("wawona-swinging-bridge-rt", "Round trip", 0.6, "round trip", time="30 minutes")],
         "A flat 0.3-mile walk to a suspended footbridge and a popular swimming hole on the South Fork Merced River.",
         "Swinging Bridge Trailhead, end of Forest Drive", "NPS POI 22475 (Swinging Bridge Trailhead)", (-119.628391, 37.543336), [WAWONA],
         warnings=["River currents are strongest during snowmelt; NPS does not publish a safe-swimming season for this spot."]),
    hike("trail-chilnualna-falls", "Chilnualna Falls", "wawona-mariposa-grove",
         [route("chilnualna-falls-rt", "Round trip", 8.2, "round trip", 2400, "5–7 hours")],
         "Beside cascading Chilnualna Creek, then switchbacks with views over Wawona toward the falls. NPS calls it very challenging; a first waterfall view comes a quarter mile in.",
         "Chilnualna Falls Trailhead, near the end of Chilnualna Falls Road", "NPS POI 21941 (Chilnualna Falls Trailhead)", (-119.633688, 37.548545), [WAWONA],
         notes=["The falls run fullest in spring and early summer.", "No drinking water on Wawona trails."], priority=6),
    hike("trail-alder-creek", "Alder Creek", "wawona-mariposa-grove",
         [route("alder-creek-rt", "Round trip from Chilnualna Falls Road", 12, "round trip", 2500, "7–9 hours"),
          route("alder-creek-mosquito-creek", "Shorter round trip from Mosquito Creek Trailhead", 7.4, "round trip")],
         "A very challenging climb through open pine forest to a seldom-visited 100-foot cascade.",
         "Alder Creek Trailhead on Chilnualna Falls Road, or Mosquito Creek Trailhead on Wawona Road for the shorter version", "NPS POI 21996 (Alder Creek Trailhead)", (-119.652298, 37.541171), [WAWONA],
         notes=["NPS publishes no gain or time for the shorter Mosquito Creek option.", "No drinking water on Wawona trails."]),
    hike("trail-big-trees-loop", "Big Trees Loop", "wawona-mariposa-grove",
         [route("big-trees-loop", "Loop from the grove arrival area", 0.3, "loop", time="30–45 minutes", difficulty="Easy", source=GROVE)],
         "A flat loop on pavement, packed dirt and boardwalk among giant sequoias, past the Fallen Monarch and interpretive panels.",
         "Mariposa Grove Arrival Area & Trailhead", "NPS POI 20092 (Mariposa Grove Trailhead)", (-119.61087, 37.501595), [GROVE, WAWONA], difficulty="Easy",
         accessibility="NPS describes the loop as wheelchair accessible.",
         pets="Pets are not allowed on any trail or road in the Mariposa Grove, on the Washburn Trail or on the grove shuttle.",
         discrepancies=["The Wawona hikes page calls it 0.3 mile round trip; the Mariposa Grove page calls it a 0.3-mile loop."], priority=7),
    hike("trail-grizzly-giant-loop", "Grizzly Giant Loop", "wawona-mariposa-grove",
         [route("grizzly-giant-loop", "Loop from the grove arrival area", 2, "loop", 300, "1.5–2 hours", difficulty="Moderate", source=GROVE)],
         "Past the Bachelor and Three Graces, the roughly 3,000-year-old Grizzly Giant and the California Tunnel Tree.",
         "Mariposa Grove Arrival Area & Trailhead", "NPS POI 20092 (Mariposa Grove Trailhead)", (-119.61087, 37.501595), [GROVE, WAWONA], difficulty="Moderate",
         accessibility="Holders of a valid disability placard can drive to the Grizzly Giant parking area, where a section of trail is wheelchair accessible.",
         pets="Pets are not allowed anywhere in the Mariposa Grove.", priority=7),
    hike("trail-guardians-loop", "Guardians Loop", "wawona-mariposa-grove",
         [route("guardians-loop-rt", "Round trip from the grove arrival area", 6.5, "round trip", 1000, "4–6 hours", difficulty="Strenuous", source=GROVE)],
         "Beyond the Grizzly Giant to the quiet upper grove, where a 1.5-mile loop passes the fallen Wawona Tunnel Tree, the Telescope Tree and the Mariposa Grove Cabin.",
         "Mariposa Grove Arrival Area & Trailhead", "NPS POI 20092 (Mariposa Grove Trailhead)", (-119.61087, 37.501595), [GROVE, WAWONA], difficulty="Strenuous",
         pets="Pets are not allowed anywhere in the Mariposa Grove."),
    hike("trail-wawona-point", "Mariposa Grove Trail to Wawona Point", "wawona-mariposa-grove",
         [route("wawona-point-rt", "Round trip to Wawona Point", 7, "round trip", 1200, "4–6 hours", difficulty="Strenuous", source=GROVE)],
         "A wide, fairly smooth historic route to the top of the grove past the Faithful Couple and the Clothespin Tree, continuing to the Wawona Point overlook.",
         "Mariposa Grove Arrival Area & Trailhead", "NPS POI 20092 (Mariposa Grove Trailhead)", (-119.61087, 37.501595), [GROVE, WAWONA], difficulty="Strenuous",
         pets="Pets are not allowed anywhere in the Mariposa Grove.",
         discrepancies=["The Mariposa Grove page (updated June 11, 2026) gives 7 miles round trip; the older Wawona hikes page (October 15, 2024) gives 7.75 miles. The newer figure is shown."]),
    # Hetch Hetchy
    hike("trail-lookout-point", "Lookout Point", "hetch-hetchy",
         [route("lookout-point-rt", "Round trip", 2, "round trip", 680)],
         "Moderate climbing to a rocky outcrop overlooking Hetch Hetchy Valley.",
         "Hetch Hetchy Entrance Station", "NPS POI 21339 (Hetch Hetchy Entrance)", (-119.841696, 37.893591), [HETCH],
         notes=["NPS gives 680 feet as the elevation gain and loss."]),
    hike("trail-wapama-falls", "Wapama Falls", "hetch-hetchy",
         [route("wapama-falls-rt", "Round trip", 5, "round trip", 507)],
         "Across O'Shaughnessy Dam and through the tunnel, then along the reservoir shore with views of Tueeulala and Wapama falls.",
         "Hetch Hetchy Trailhead, across the dam", "NPS POI 22178 (Hetch Hetchy Trailhead)", (-119.787515, 37.946497), [HETCH],
         notes=["NPS gives 507 feet as the elevation gain and loss, with moderate ups and downs."],
         warnings=["The footbridges below Wapama Falls can flood during spring runoff; check current conditions before crossing."], priority=6),
    hike("trail-rancheria-falls", "Rancheria Falls", "hetch-hetchy",
         [route("rancheria-falls-rt", "Round trip", 13, "round trip", 1909)],
         "Beyond Wapama Falls along the reservoir to Rancheria Falls; a long day hike or an overnight trip with a wilderness permit.",
         "Hetch Hetchy Trailhead, across the dam", "NPS POI 22178 (Hetch Hetchy Trailhead)", (-119.787515, 37.946497), [HETCH],
         notes=["A wilderness permit is required for any overnight stay."]),
    hike("trail-smith-peak", "Smith Peak", "hetch-hetchy",
         [route("smith-peak-from-road", "Round trip from the trailhead beyond the entrance", 13, "round trip", 3700),
          route("smith-peak-from-entrance", "Round trip from the entrance station", 16, "round trip", 3300)],
         "The highest point in the Hetch Hetchy area at 7,751 feet, with wide views.",
         "Smith Peak Trailhead about 6 miles beyond the entrance station, or the entrance station itself", "NPS POI 22815 (Smith Peak Trailhead)", (-119.795145, 37.926192), [HETCH]),
    hike("trail-poopenaut-valley", "Poopenaut Valley", "hetch-hetchy",
         [route("poopenaut-valley-rt", "Round trip", 2.5, "round trip", 1279)],
         "A steep descent to the Tuolumne River and a strenuous climb back out.",
         "Signed trailhead 4 miles past the entrance station", "NPS POI 20212 (Poopenaut Valley Trailhead)", (-119.814626, 37.910204), [HETCH]),
    # Crane Flat groves
    hike("trail-tuolumne-grove", "Tuolumne Grove", "crane-flat-big-oak-flat",
         [route("tuolumne-grove-rt", "Round trip with the nature trail", 2.5, "round trip", 500, "1–2 hours")],
         "Down a historic wagon road to about two dozen giant sequoias and a half-mile self-guided nature trail; the climb back is steep.",
         "Tuolumne Grove Trailhead, Tioga Road near Crane Flat", "NPS POI 20953 (Tuolumne Grove Trailhead)", (-119.805599, 37.758253), [WHITEWOLF, SEQUOIAS],
         notes=["The 500 feet of climbing comes on the way back.", "No drinking water; parking is limited.", "Open year-round; skis or snowshoes may be needed in winter."], priority=7),
    hike("trail-merced-grove", "Merced Grove", "crane-flat-big-oak-flat",
         [route("merced-grove-rt", "Round trip", 3, "round trip", 520, "1–3 hours")],
         "An old road down to Yosemite's smallest sequoia grove; keep left at the junction about half a mile in.",
         "Merced Grove Trailhead, Big Oak Flat Road", "NPS POI 21394 (Merced Grove Trailhead)", (-119.842272, 37.762993), [WHITEWOLF, SEQUOIAS],
         notes=["The 520 feet of climbing comes on the way back.", "No drinking water; parking is very limited.", "Open year-round; skis or snowshoes may be needed in winter."]),
    # Tioga Road west (White Wolf area)
    hike("trail-may-lake", "May Lake", "tioga-tuolumne",
         [route("may-lake-rt", "Round trip", 2.4, "round trip", 485, "1–2 hours")],
         "Through forest and over granite slabs to a lake below Mount Hoffmann, with Half Dome views on the way.",
         "May Lake parking area, 1.75 miles up May Lake Road", "NPS POI 20954 (May Lake Trailhead)", (-119.491154, 37.832706), [WHITEWOLF],
         notes=[TIOGA_SEASON]),
    hike("trail-lukens-lake-tioga", "Lukens Lake from Tioga Road", "tioga-tuolumne",
         [route("lukens-lake-tioga-rt", "Round trip", 1.6, "round trip", 200, "1–2 hours")],
         "Through forest and over a saddle to a small lake ringed by meadow; wildflowers in early summer.",
         "Lukens Trailhead, Tioga Road", "NPS POI 21984 (Lukens to Lukens Lake Trailhead)", (-119.61521, 37.850521), [WHITEWOLF],
         notes=["NPS says the trail stays wet and muddy until early August.", TIOGA_SEASON]),
    hike("trail-lukens-lake-white-wolf", "Lukens Lake from White Wolf", "tioga-tuolumne",
         [route("lukens-lake-white-wolf-rt", "Round trip", 4.6, "round trip", 400, "2–3 hours")],
         "The longer way to Lukens Lake, crossing the Middle Fork of the Tuolumne River.",
         "White Wolf, across from the lodge", "NPS POI 21102 (White Wolf Trailhead)", (-119.64882, 37.869768), [WHITEWOLF],
         notes=["Can be wet and muddy.", TIOGA_SEASON]),
    hike("trail-harden-lake", "Harden Lake", "tioga-tuolumne",
         [route("harden-lake-rt", "Round trip", 5.8, "round trip", 390, "2–4 hours")],
         "North from White Wolf along the Middle Tuolumne River and an old road to a lake; an optional, very challenging extension drops to the rim of the Grand Canyon of the Tuolumne.",
         "White Wolf, across from the lodge", "NPS POI 21102 (White Wolf Trailhead)", (-119.64882, 37.869768), [WHITEWOLF],
         notes=["The 390 feet of climbing comes on the way back.", "NPS gives no distance for the optional loop past the lake, only about 1,000 feet of extra climbing.", TIOGA_SEASON]),
    hike("trail-north-dome", "North Dome", "tioga-tuolumne",
         [route("north-dome-rt", "Round trip", 10.4, "round trip", 580, "5–7 hours")],
         "A paved start, a Porcupine Creek crossing and forest and meadow to steep steps below North Dome, whose summit faces Half Dome across Yosemite Valley.",
         "Porcupine Creek Trailhead, Tioga Road", "NPS POI 22600 (Porcupine Creek Trailhead)", (-119.545261, 37.806575), [WHITEWOLF],
         notes=["The 580 feet of climbing comes on the way back.", TIOGA_SEASON], warnings=[DOMES]),
    hike("trail-ten-lakes", "Ten Lakes", "tioga-tuolumne",
         [route("ten-lakes-rt", "Round trip", 12.6, "round trip", 2200, "7–9 hours")],
         "Through conifers and over granite to Ten Lakes Pass and down into the lake basin; Grant Lakes lie a mile off the pass on a side trail.",
         "Ten Lakes Trailhead, Tioga Road", "NPS POI 21777 (Ten Lakes Trailhead)", (-119.576523, 37.852193), [WHITEWOLF],
         notes=[TIOGA_SEASON]),
    # Tuolumne Meadows
    hike("trail-pothole-dome", "Pothole Dome", "tioga-tuolumne",
         [route("pothole-dome-rt", "Round trip", 1, "round trip", 200)],
         "A short walk along Tioga Road and a scramble up the dome for views across Tuolumne Meadows.",
         "Pothole Dome parking, Tioga Road", "NPS POI 21473 (Pothole Dome Shuttle Stop); NPS maps no separate parking point", (-119.393421, 37.876432), [TUOLUMNE],
         notes=["NPS lists it among walks taking about an hour or less.", TIOGA_SEASON], warnings=[DOMES]),
    hike("trail-soda-springs", "Parsons Lodge & Soda Springs", "tioga-tuolumne",
         [route("soda-springs-rt", "Round trip", 1.4, "round trip")],
         "A level, unpaved stroll across Tuolumne Meadows to the cold, bubbling Soda Springs and historic Parsons Memorial Lodge.",
         "Lembert Dome parking or Tuolumne Meadows Visitor Center", "NPS POI 21179 (Lembert Dome Trailhead)", (-119.353701, 37.877417), [TUOLUMNE],
         notes=["NPS lists it among walks taking about an hour or less.", TIOGA_SEASON], priority=6),
    hike("trail-twin-bridges", "Twin Bridges (Lyell Fork)", "tioga-tuolumne",
         [route("twin-bridges-rt", "Round trip", 3, "round trip")],
         "The John Muir Trail to a scenic spot on the Lyell Fork of the Tuolumne River; continue up Lyell Canyon and turn back whenever you like.",
         "Dog Lake parking", "NPS POI 21439 (Dog Lake Trailhead)", (-119.338986, 37.878407), [TUOLUMNE],
         notes=["Mostly flat with uneven ground.", TIOGA_SEASON]),
    hike("trail-gaylor-lakes", "Gaylor Lakes", "tioga-tuolumne",
         [route("gaylor-lakes-rt", "Round trip to Middle Gaylor Lake", 2.6, "round trip", 500, "2–3 hours")],
         "A short, steep climb from Tioga Pass to a ridge above Dana Meadows, then 200 feet down to Middle Gaylor Lake.",
         "Tioga Pass Entrance", "NPS POI 21419 (Gaylor Lakes Trailhead)", (-119.258284, 37.910225), [TUOLUMNE],
         notes=["The trailhead is near 10,000 feet; altitude makes the climb harder than the numbers suggest.", TIOGA_SEASON], priority=6),
    hike("trail-dog-lake-lembert-dome", "Dog Lake & Lembert Dome", "tioga-tuolumne",
         [route("dog-lake-lembert-rt", "Out and back with the Lembert Dome side trip", 3.8, "round trip", 850, "3–4 hours"),
          route("dog-lake-lembert-loop", "Loop returning via Lembert Dome parking", 5, "loop")],
         "A steep climb to Dog Lake with a side trip to the top of Lembert Dome.",
         "Dog Lake parking area", "NPS POI 21439 (Dog Lake Trailhead)", (-119.338986, 37.878407), [TUOLUMNE],
         notes=["NPS publishes no gain or time for the 5-mile loop option.", TIOGA_SEASON], warnings=[DOMES], priority=6),
    hike("trail-elizabeth-lake", "Elizabeth Lake", "tioga-tuolumne",
         [route("elizabeth-lake-rt", "Round trip", 6.8, "round trip", 1000, "6–7 hours")],
         "A steady two-mile climb to a glacier-carved lake below Unicorn Peak; a one-mile path circles the lake.",
         "Tuolumne Meadows Visitor Center", "NPS POI 21607 (Tuolumne Meadows Visitor Center)", (-119.374178, 37.871567), [TUOLUMNE],
         notes=[TIOGA_SEASON],
         discrepancies=["The NPS day-hike page names the visitor center as the start; NPS GIS also maps an Elizabeth Lake Trailhead in Tuolumne Meadows Campground. The coordinate here is the visitor center."]),
    hike("trail-cathedral-lakes", "Cathedral Lakes", "tioga-tuolumne",
         [route("cathedral-lakes-rt", "Round trip to Upper Cathedral Lake", 7.6, "round trip", 1000, "6–7 hours")],
         "The area's most popular trail, climbing steadily to Upper Cathedral Lake; a 0.7-mile spur near the top leads to Lower Cathedral Lake.",
         "Tuolumne Meadows Visitor Center", "NPS POI 21607 (Tuolumne Meadows Visitor Center)", (-119.374178, 37.871567), [TUOLUMNE],
         notes=[TIOGA_SEASON],
         discrepancies=["The NPS day-hike page names the visitor center as the start; NPS GIS maps a Cathedral Lakes trailhead on Tioga Road west of it. The coordinate here is the visitor center."],
         priority=6),
    hike("trail-mono-pass", "Mono Pass", "tioga-tuolumne",
         [route("mono-pass-rt", "Round trip", 8, "round trip", 1000, "5–7 hours")],
         "A steady climb to Mono Pass with views of Mono Lake and the eastern Sierra.",
         "Tioga Road at Dana Meadows", "NPS POI 21643 (Mono/Parker Pass Trailhead)", (-119.262696, 37.89091), [TUOLUMNE],
         notes=[TIOGA_SEASON]),
    hike("trail-glen-aulin", "Glen Aulin", "tioga-tuolumne",
         [route("glen-aulin-rt", "Round trip to Glen Aulin", 11, "round trip", 800, "6–8 hours"),
          route("waterwheel-falls-rt", "Round trip to Waterwheel Falls", 19, "round trip")],
         "Downstream with the Tuolumne River as it drops 5.5 miles to Glen Aulin; Waterwheel Falls is 4 miles further.",
         "Lembert Dome parking area", "NPS POI 21179 (Lembert Dome Trailhead)", (-119.353701, 37.877417), [TUOLUMNE],
         notes=["The 800 feet of climbing comes on the way back.", "NPS publishes no gain or time for the Waterwheel Falls extension.", TIOGA_SEASON]),
    hike("trail-young-lakes", "Young Lakes", "tioga-tuolumne",
         [route("young-lakes-rt", "Round trip", 13.6, "round trip", 1300, "8–10 hours")],
         "A long but rewarding day to a chain of lakes, reached by the Glen Aulin or Dog Lake trails; return the same way or make a loop.",
         "Lembert Dome parking area", "NPS POI 21179 (Lembert Dome Trailhead)", (-119.353701, 37.877417), [TUOLUMNE],
         notes=[TIOGA_SEASON]),
]

REGION_NOTES = [
    {"regionId": "glacier-point", "source": GLACIER, "points": [
        "Glacier Point Road is usually open from May to November, depending on conditions.",
        "Expect snowy or wet trails in early spring.",
        "Water is typically available at Glacier Point from late spring to early fall only; carry enough for the whole hike.",
        "No shuttle runs between Yosemite Valley and Glacier Point. The summer Glacier Point Tour bus needs a reservation; do not count on it to return to your car."]},
    {"regionId": "wawona-mariposa-grove", "source": GROVE, "points": [
        "No drinking water on the Wawona trails; a fountain stands by the restrooms at the Wawona Store parking area.",
        "In the Mariposa Grove, water is available only at the Welcome Plaza (all year) and the arrival area (summer).",
        "A free shuttle runs from the Welcome Plaza to the grove from late April to November when conditions allow; NPS lists shorter 2026 hours for November and no service from December 1.",
        "Without the shuttle, the grove is a 2-mile walk each way on the Washburn Trail or Mariposa Grove Road, with about 500 feet of climbing.",
        "Pets are not allowed anywhere in the Mariposa Grove."]},
    {"regionId": "hetch-hetchy", "source": HETCH, "points": [
        "At about 3,900 feet, Hetch Hetchy has one of the longest hiking seasons in the park; summer is hot and dry.",
        "Carry plenty of water and sunscreen, and watch for rattlesnakes and poison oak.",
        "Swimming and boating are prohibited in the reservoir; pets are not allowed on the dam or on hiking trails.",
        "Overnight trips need a wilderness permit."]},
    {"regionId": "crane-flat-big-oak-flat", "source": SEQUOIAS, "points": [
        "The Tuolumne and Merced groves are each about 30 to 45 minutes from Yosemite Valley.",
        "Neither grove trail has drinking water, and trailhead parking is limited.",
        "Both groves stay open all year; skis or snowshoes may be needed in winter.",
        "The sequoias are below the trailheads, so the hard climbing comes on the way back."]},
    {"regionId": "tioga-tuolumne", "source": TUOLUMNE, "points": [
        "Tioga Road and its trailheads are reachable by car only while the road is open, typically from May or June to November.",
        "Trails can still be snowy or wet in spring.",
        "Services are extremely limited; carry all your water and food. The nearest fuel is at Crane Flat or Lee Vining.",
        "Afternoon thunderstorms are common in summer; stay off domes and summits when they build."]},
]

PARK_RULES = {"source": HIKING, "points": [
    "Stay on trails; shortcuts cause erosion and are dangerous and illegal.",
    "Carry and drink plenty of water, and treat any water from rivers, streams, lakes or springs.",
    "Pets and bicycles are allowed only on paved bike paths, apart from the exceptions named on individual hikes.",
    "Horses and mules have the right of way.",
    "Trails are not maintained or regularly patrolled; travel carefully and at your own risk."]}


# Road keys match the notice patterns in Content/notices.json; a notice naming the road the trailhead is on is
# shown with the hike. Terms are distinctive names on the route, matched whole-word in notice text.
GLACIER_ROAD = {"key": "Glacier Point Road", "name": "Glacier Point Road"}
WAWONA_ROAD = {"key": "SR-41", "name": "Wawona Road (Highway 41)"}
GROVE_ROAD = {"key": "Mariposa Grove Road", "name": "Mariposa Grove Road"}
HETCH_ROAD = {"key": "Hetch Hetchy Road", "name": "Hetch Hetchy Road"}
BIG_OAK_ROAD = {"key": "SR-120", "name": "Big Oak Flat Road (Highway 120)"}
TIOGA_ROAD = {"key": "Tioga", "name": "Tioga Road"}
GROVE = ["Mariposa Grove"]
HETCH_DAM = ["O'Shaughnessy Dam"]
ACCESS = {
    "trail-glacier-point-overlook": ([GLACIER_ROAD], []),
    "trail-mcgurk-meadow": ([GLACIER_ROAD], ["McGurk Meadow"]),
    "trail-sentinel-dome": ([GLACIER_ROAD], ["Sentinel Dome"]),
    "trail-taft-point": ([GLACIER_ROAD], ["Taft Point"]),
    "trail-mono-meadow": ([GLACIER_ROAD], ["Mono Meadow"]),
    "trail-dewey-point": ([GLACIER_ROAD], ["Dewey Point", "McGurk Meadow", "Pohono Trail"]),
    "trail-ostrander-lake": ([GLACIER_ROAD], ["Ostrander Lake", "Ostrander Hut"]),
    "trail-panorama": ([GLACIER_ROAD], ["Panorama Trail", "Illilouette", "Nevada Fall", "Vernal Fall", "Mist Trail"]),
    "trail-pohono": ([GLACIER_ROAD], ["Pohono Trail", "Taft Point", "Dewey Point"]),
    "trail-wawona-meadow-loop": ([WAWONA_ROAD], ["Wawona Meadow"]),
    "trail-wawona-swinging-bridge": ([WAWONA_ROAD], ["Wawona Swinging Bridge", "Forest Drive"]),
    "trail-chilnualna-falls": ([WAWONA_ROAD], ["Chilnualna"]),
    "trail-alder-creek": ([WAWONA_ROAD], ["Alder Creek", "Mosquito Creek", "Chilnualna Falls Road"]),
    "trail-big-trees-loop": ([GROVE_ROAD], GROVE + ["Big Trees Loop"]),
    "trail-grizzly-giant-loop": ([GROVE_ROAD], GROVE + ["Grizzly Giant"]),
    "trail-guardians-loop": ([GROVE_ROAD], GROVE + ["Guardians Loop"]),
    "trail-wawona-point": ([GROVE_ROAD], GROVE + ["Wawona Point"]),
    "trail-lookout-point": ([HETCH_ROAD], ["Lookout Point"]),
    "trail-wapama-falls": ([HETCH_ROAD], HETCH_DAM + ["Wapama", "Tueeulala"]),
    "trail-rancheria-falls": ([HETCH_ROAD], HETCH_DAM + ["Wapama", "Tueeulala", "Rancheria"]),
    "trail-smith-peak": ([HETCH_ROAD], ["Smith Peak"]),
    "trail-poopenaut-valley": ([HETCH_ROAD], ["Poopenaut"]),
    "trail-tuolumne-grove": ([TIOGA_ROAD], ["Tuolumne Grove"]),
    "trail-merced-grove": ([BIG_OAK_ROAD], ["Merced Grove"]),
    "trail-may-lake": ([TIOGA_ROAD], ["May Lake"]),
    "trail-lukens-lake-tioga": ([TIOGA_ROAD], ["Lukens Lake"]),
    "trail-lukens-lake-white-wolf": ([TIOGA_ROAD], ["Lukens Lake", "White Wolf"]),
    "trail-harden-lake": ([TIOGA_ROAD], ["Harden Lake", "White Wolf"]),
    "trail-north-dome": ([TIOGA_ROAD], ["North Dome", "Porcupine Creek"]),
    "trail-ten-lakes": ([TIOGA_ROAD], ["Ten Lakes", "Grant Lakes"]),
    "trail-pothole-dome": ([TIOGA_ROAD], ["Pothole Dome"]),
    "trail-soda-springs": ([TIOGA_ROAD], ["Soda Springs", "Parsons"]),
    "trail-twin-bridges": ([TIOGA_ROAD], ["Twin Bridges", "Lyell"]),
    "trail-gaylor-lakes": ([TIOGA_ROAD], ["Gaylor Lake", "Gaylor Lakes"]),
    "trail-dog-lake-lembert-dome": ([TIOGA_ROAD], ["Dog Lake", "Lembert Dome"]),
    "trail-elizabeth-lake": ([TIOGA_ROAD], ["Elizabeth Lake"]),
    "trail-cathedral-lakes": ([TIOGA_ROAD], ["Cathedral Lake", "Cathedral Lakes"]),
    "trail-mono-pass": ([TIOGA_ROAD], ["Mono Pass"]),
    "trail-glen-aulin": ([TIOGA_ROAD], ["Glen Aulin", "Waterwheel Falls"]),
    "trail-young-lakes": ([TIOGA_ROAD], ["Young Lakes"]),
}

# Dated official statements added per hike: (access lines, accessibility, discrepancies, sources).
HETCH_ACCESS = ["NPS Hetch Hetchy page (updated June 11, 2026): the road is open only from sunrise to sunset, vehicles or trailers over 25 feet long or 8 feet wide are not permitted, and there is no public transportation. From November to March it may close or need chains for ice and snow."]
DETAILS = {
    "trail-glacier-point-overlook": ([], "NPS Accessibility Guide (Summer 2022): two paved paths reach the overlook, but both are steeper than an accessible grade in places.", [], [ACCESS_GUIDE]),
    "trail-tuolumne-grove": ([], "NPS Accessibility Guide (Summer 2022): the path is not accessible. It follows the paved former Big Oak Flat Road at about a 7.5% grade for a mile, then packed dirt, and is not plowed in winter. An accessible restroom is near the parking area.",
                             ["The 2022 NPS Accessibility Guide gives about 400 feet of elevation change; the NPS day-hike page gives 500 feet. The day-hike figure is shown."], [ACCESS_GUIDE]),
    "trail-merced-grove": ([], "NPS Accessibility Guide (Summer 2022): a steep, unpaved road of packed dirt with no vehicle access; the trailhead has picnic tables but no restroom.",
                           ["The 2022 NPS Accessibility Guide gives about 600 feet of elevation change; the NPS day-hike page gives 520 feet. The day-hike figure is shown."], [ACCESS_GUIDE]),
    "trail-lookout-point": (HETCH_ACCESS, None, [], [HH_VISIT]),
    "trail-wapama-falls": (HETCH_ACCESS, None, [], [HH_VISIT]),
    "trail-rancheria-falls": (HETCH_ACCESS, None, [], [HH_VISIT]),
    "trail-smith-peak": (HETCH_ACCESS, None, [], [HH_VISIT]),
    "trail-poopenaut-valley": (HETCH_ACCESS, None, [], [HH_VISIT]),
}
TRAIL_PETS = "Pets are not allowed: NPS bars pets from park trails, wilderness and meadows even if carried, and names the Wawona Meadow Loop as the trail exception (NPS pets page, updated June 24, 2026)."
PAVED_PETS = "The NPS pets page (updated June 24, 2026) allows leashed pets on fully paved paths and sidewalks in developed areas unless signs say otherwise, and bars them from trails; it does not name this path, so follow the signs."


def apply_details(hike):
    roads, terms = ACCESS[hike["id"]]
    hike["accessRoads"] = roads
    hike["noticeTerms"] = terms
    access, accessibility, discrepancies, sources = DETAILS.get(hike["id"], ([], None, [], []))
    if access:
        hike["access"] = access
    if accessibility:
        hike["accessibility"] = accessibility
    if discrepancies:
        hike["discrepancies"] = hike.get("discrepancies", []) + discrepancies
    if "pets" not in hike:
        hike["pets"] = PAVED_PETS if hike["id"] == "trail-glacier-point-overlook" else TRAIL_PETS
        sources = sources + [PETS]
    if sources:
        hike["extraSources"] = sources


def main():
    assert set(ACCESS) == {h["id"] for h in HIKES}, "every park hike needs access roads and notice terms"
    for h in HIKES:
        apply_details(h)
    ids = [h["id"] for h in HIKES]
    route_ids = [r["id"] for h in HIKES for r in h["routes"]]
    assert len(ids) == len(set(ids)), "duplicate hike id"
    assert len(route_ids) == len(set(route_ids)), "duplicate route id"
    pack = {"generated": CHECKED, "about": "NPS-published day hikes outside Yosemite Valley. Distances, gains and times are NPS figures; trailhead coordinates are NPS GIS points. Not every park trail is listed.",
            "trails": HIKES, "regionNotes": REGION_NOTES, "parkRules": PARK_RULES}
    OUT.write_text(json.dumps(pack, ensure_ascii=False, indent=1) + "\n")
    print(f"wrote {OUT.relative_to(ROOT)}: {len(HIKES)} hikes, {len(route_ids)} published routes")


if __name__ == "__main__":
    main()
