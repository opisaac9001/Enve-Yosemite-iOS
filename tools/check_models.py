#!/usr/bin/env python3 -I
"""Checks bundled JSON packs (and reference feed snapshots) against the Swift Codable models.

Parses `struct`/`enum` declarations straight from the Swift sources, then validates each JSON
file the way synthesized Decodable would: every non-optional stored property must be present
with a compatible JSON type, raw-value enums must match a declared case, arrays/dictionaries
recurse. Unknown keys are ignored (as JSONDecoder does). Prints the first mismatches per pack
with their coding paths. Exit code 1 on any mismatch.

Usage: python3 -I tools/check_models.py [--api research/reference/api]
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
IOS = ROOT / "ios" / "PettyFieldGuide"

MODEL_FILES = [
    "Content/Place.swift", "Content/EventModels.swift", "Content/PlanningModels.swift", "Content/StatusModels.swift",
    "Content/TrailModels.swift", "Content/ContentStore.swift", "Transit/TransitModels.swift", "Conditions/FeedModels.swift",
    "Geo/YosemiteGeo.swift", "Explorer/ExplorerStore.swift", "Trip/TripScreen.swift", "Sun/TerrainGrid.swift",
    "Map/Engine/ParkSceneBuilder.swift", "Hiking/HikeRouteModels.swift",
]

# (json path relative to repo, Swift type expression)
CONTENT_TARGETS = [
    ("Content/places.json", "[Place]"), ("Content/trails.json", "TrailsPack"), ("Content/campgrounds.json", "CampgroundsPack"),
    ("Content/permits.json", "PermitsPack"), ("Content/contacts.json", "ContactsPack"), ("Content/events.json", "EventsPack"),
    ("Content/regions.json", "RegionsPack"), ("Content/webcams.json", "WebcamsPack"), ("Content/documents.json", "[DocumentItem]"),
    ("Content/status.json", "StatusPack"), ("Content/categories.json", "CategoriesPack"), ("Content/notices.json", "NoticesPack"),
    ("Content/changelog.json", "[ChangelogEntry]"), ("Content/housekeeping.json", "HousekeepingPack"),
    ("Content/pack-manifest.json", "OfflinePackStatus.Manifest"), ("Content/hike-routes.json", "HikeRoutesPack"),
    ("Geo/transit.json", "TransitFeedPack"), ("Geo/campsites.geojson", "CampsiteLoader.Collection"),
    ("Geo/explorer-catalog.json", "ExplorerCatalog"), ("Geo/elevation-valley.json", "TerrainGrid.Raw"),
    ("Geo/campground-context.geojson", "CampgroundSceneBuilder.Doc"),
]
API_TARGETS = [
    ("weather-valley.json", "WeatherFeed"), ("fire-risk.json", "FireFeed"), ("smoke.json", "SmokeFeed"),
    ("seasonal-risks.json", "SeasonalFeed"), ("nps-programs.json", "ProgramsFeed"), ("conditions.json", "ConditionsFeed"),
    ("updates.json", "UpdatesFeed"),
]

PRIMITIVES = {"String", "Int", "Double", "Bool", "Float", "CGFloat"}
STRING_RE = re.compile(r'"(?:[^"\\]|\\.)*"')
TYPE_DECL_RE = re.compile(r"^\s*(?:(?:public|private|fileprivate|internal|final|indirect|nonisolated)\s+)*(struct|enum|class)\s+(\w+)(?:<[^>]*>)?\s*(?::\s*([^{]*))?\{")
FIELD_RE = re.compile(r"^\s*(?:(?:public|private|fileprivate|internal|nonisolated|static)\s+)*(var|let)\s+(\w+)\s*:\s*([^={]+?)\s*(?:=.*)?$")
CASE_RE = re.compile(r"^\s*case\s+(.+)$")


class SwiftType:
    def __init__(self, kind, name, qualified):
        self.kind = kind            # struct | enum | class
        self.name = name
        self.qualified = qualified
        self.fields = []            # (name, type expression)
        self.raw_values = set()     # enum raw values
        self.raw_type = None
        self.codable = False


def parse_swift(path: Path, types: dict):
    stack = []                      # entries: SwiftType or None for anonymous scopes
    pending = None
    for raw in path.read_text().splitlines():
        line = raw.split("//")[0]
        stripped = STRING_RE.sub('""', line)
        decl = TYPE_DECL_RE.match(stripped)
        if decl:
            kind, name, inherit = decl.groups()
            qualified = ".".join([t.name for t in stack if t] + [name])
            t = SwiftType(kind, name, qualified)
            inherits = [x.strip() for x in (inherit or "").split(",") if x.strip()]
            t.codable = any(x in ("Codable", "Decodable") for x in inherits)
            if kind == "enum" and inherits and inherits[0] in PRIMITIVES:
                t.raw_type = inherits[0]
            types.setdefault(name, []).append(t)
            types[qualified] = [t]
            stack.append(t)
            pending = t
            depth_after = stripped.count("{") - stripped.count("}")
            if depth_after <= 0:
                stack.pop()
            continue
        opens, closes = stripped.count("{"), stripped.count("}")
        current = next((t for t in reversed(stack) if t), None)
        body_depth_line = opens == closes
        if current and stack and stack[-1] is current and body_depth_line:
            field = FIELD_RE.match(stripped)
            if field and "{" not in stripped:
                _, fname, ftype = field.groups()
                current.fields.append((fname, ftype.strip()))
            elif current.kind == "enum":
                case = CASE_RE.match(line)
                if case and "(" not in case.group(1) and ":" not in case.group(1):
                    for part in case.group(1).split(","):
                        part = part.strip()
                        if not part:
                            continue
                        if "=" in part:
                            cname, rawv = [x.strip() for x in part.split("=", 1)]
                            current.raw_values.add(json.loads(rawv) if rawv.startswith('"') else rawv)
                        else:
                            current.raw_values.add(part)
        # Scope bookkeeping for braces that are not type declarations.
        net = opens - closes
        if net > 0:
            for _ in range(net):
                stack.append(None)
        elif net < 0:
            for _ in range(-net):
                if stack:
                    stack.pop()


def resolve(name: str, scope: SwiftType, types: dict):
    if name in types and len(types[name]) == 1:
        return types[name][0]
    if scope:
        parts = scope.qualified.split(".")
        for i in range(len(parts), 0, -1):
            q = ".".join(parts[:i] + [name])
            if q in types:
                return types[q][0]
    cands = types.get(name, [])
    return cands[0] if cands else None


def check(value, texpr: str, scope, types, path, errors):
    texpr = texpr.strip()
    if len(errors) > 25:
        return
    if texpr.endswith("?"):
        if value is None:
            return
        return check(value, texpr[:-1], scope, types, path, errors)
    if value is None:
        errors.append(f"{path}: expected {texpr}, found null")
        return
    if texpr.startswith("[") and texpr.endswith("]"):
        inner = texpr[1:-1]
        depth, split = 0, None
        for i, ch in enumerate(inner):
            if ch in "[<":
                depth += 1
            elif ch in "]>":
                depth -= 1
            elif ch == ":" and depth == 0:
                split = i
                break
        if split is not None:
            if not isinstance(value, dict):
                errors.append(f"{path}: expected dictionary {texpr}, found {type(value).__name__}")
                return
            for k, v in value.items():
                check(v, inner[split + 1:], scope, types, f"{path}.{k}", errors)
            return
        if not isinstance(value, list):
            errors.append(f"{path}: expected array {texpr}, found {type(value).__name__}")
            return
        for i, v in enumerate(value):
            check(v, inner, scope, types, f"{path}[{i}]", errors)
        return
    if texpr == "String":
        if not isinstance(value, str):
            errors.append(f"{path}: expected String, found {type(value).__name__}")
        return
    if texpr == "Bool":
        if not isinstance(value, bool):
            errors.append(f"{path}: expected Bool, found {type(value).__name__}")
        return
    if texpr == "Int":
        if isinstance(value, bool) or not isinstance(value, (int, float)) or (isinstance(value, float) and not value.is_integer()):
            errors.append(f"{path}: expected Int, found {json.dumps(value)}")
        return
    if texpr in ("Double", "Float", "CGFloat"):
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            errors.append(f"{path}: expected {texpr}, found {type(value).__name__}")
        return
    t = resolve(texpr, scope, types)
    if t is None:
        errors.append(f"{path}: no Swift declaration found for type {texpr}")
        return
    if t.kind == "enum":
        if t.raw_type and value not in t.raw_values:
            errors.append(f"{path}: {json.dumps(value)} is not a case of {t.qualified} ({sorted(t.raw_values)})")
        return
    if not isinstance(value, dict):
        errors.append(f"{path}: expected object {t.qualified}, found {type(value).__name__}")
        return
    for fname, ftype in t.fields:
        if fname not in value:
            if not ftype.strip().endswith("?"):
                errors.append(f"{path}.{fname}: key missing for non-optional {ftype} in {t.qualified}")
            continue
        check(value[fname], ftype, t, types, f"{path}.{fname}", errors)


def run(targets, base: Path, types) -> int:
    failures = 0
    for rel, texpr in targets:
        file = base / rel
        if not file.exists():
            print(f"SKIP  {rel}: file not present")
            continue
        data = json.loads(file.read_text())
        errors = []
        check(data, texpr, None, types, "$", errors)
        if errors:
            failures += 1
            print(f"FAIL  {rel} as {texpr}")
            for e in errors[:12]:
                print(f"      {e}")
            if len(errors) > 12:
                print(f"      … {len(errors) - 12} more")
        else:
            print(f"ok    {rel} as {texpr}")
    return failures


def main():
    types = {}
    for rel in MODEL_FILES:
        parse_swift(IOS / rel, types)
    failures = run(CONTENT_TARGETS, IOS / "Resources", types)
    if "--api" in sys.argv:
        api_dir = Path(sys.argv[sys.argv.index("--api") + 1])
        failures += run(API_TARGETS, api_dir, types)
    print(f"{failures} pack(s) with mismatches")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
