import SwiftUI

struct TrailDetailView: View {
    let trailId: String
    var routeId: String?
    @EnvironmentObject private var content: ContentStore
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var saved: SavedStore
    @ObservedObject private var conditions = ConditionsStore.shared
    @ObservedObject private var packs = GeoPackStore.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selectedRouteId = ""
    @State private var inspection: HikeInspectorLoad = .loading
    @State private var inspectionAttempt = 0
    /// Distance along the travelled line shared by the mini-map cursor and the chart; transient, never stored.
    @State private var inspectedMetres: Double?

    var body: some View {
        if let c = content.content, let trail = c.trail(trailId) {
            let routes = c.hikeRoutes(for: trail.id)
            let route = routes.first { $0.id == selectedRouteId } ?? routes.first { $0.id == routeId } ?? c.defaultHikeRoute(for: trail.id)
            FieldScroll {
                header(trail, route, routes, c)
                if routes.count < trail.routes.count { publishedRoutesCard(trail, traced: routes) }
                if let route {
                    routeCards(trail, route)
                    HikeSequenceCard(route: route)
                } else if let regionId = trail.regionId {
                    regionalMapCard(trail, regionId: regionId)
                }
                if let guide = trail.guide { HikeGuideCards(guide: guide) }
                if let regionId = trail.regionId, let advice = c.hikeAdvice(forRegion: regionId) {
                    HikeAdviceCard(title: "Know before you go · \(c.region(regionId)?.name ?? "")", advice: advice)
                }
                trailheadCard(trail, c)
                TrailheadDaylightCard(coordinate: trail.coordinate)
                noticesCard(trail, c)
                if !trail.notes.isEmpty || trail.warnings != nil {
                    FieldCard(eyebrow: "Seasonal warnings & notes") {
                        ForEach((trail.warnings ?? []) + trail.notes, id: \.self) { Label($0, systemImage: "exclamationmark.circle").font(.fieldCaption) }
                    }
                }
                if let d = trail.discrepancies, !d.isEmpty {
                    FieldCard(eyebrow: "Source discrepancies") { ForEach(d, id: \.self) { Text($0).font(.fieldCaption) } }
                }
                FieldCard(eyebrow: "Accessibility & pets") {
                    Text(trail.accessibility ?? "No accessibility statement is published for this trail.").font(.fieldBody)
                    Text(trail.pets ?? "Pets are not allowed on unpaved trails; the published pages for this hike do not list an exception.").font(.fieldCaption).foregroundStyle(.secondary)
                }
                permitsCard(trail, c)
                linksCard(trail)
                FieldCard(eyebrow: "Sources") {
                    SourceList(sources: trail.sources + (trail.extraSources ?? []) + (route.flatMap { trail.route($0.id)?.difficultySource }.map { [$0] } ?? []))
                }
            }
            .fieldNavigationTitle(trail.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { saved.toggleSaved(trail.id) } label: { Image(systemName: saved.isSaved(trail.id) ? "star.fill" : "star") }
                        .accessibilityLabel(saved.isSaved(trail.id) ? "Remove from saved hikes" : "Save hike")
                }
            }
            .onAppear { if selectedRouteId.isEmpty { selectedRouteId = route?.id ?? "" } }
            .task(id: "\(route?.id ?? "")#\(inspectionAttempt)") {
                inspection = .loading
                inspectedMetres = nil
                guard let route else { inspection = .unavailable; return }
                let result = await packs.hikeInspector(for: route)
                // A variant switch cancels this task; its late result must not land under the new route.
                guard !Task.isCancelled else { return }
                inspection = result.map { .ready($0) } ?? .unavailable
            }
        } else {
            EmptyStateView(symbol: "figure.hiking", title: "Trail not found", message: "This link points to a hike that is not in the guide.")
        }
    }

    private func header(_ trail: Trail, _ route: HikeRoute?, _ routes: [HikeRoute], _ c: Content) -> some View {
        FieldCard {
            Text(route.flatMap { trail.route($0.id) }.map { trail.difficulty(for: $0) } ?? trail.difficulty).font(.fieldEyebrow).foregroundStyle(Palette.accent)
            Text(trail.summary).font(.fieldBody)
            Text(c.areaName(of: trail)).font(.fieldCaption).foregroundStyle(.secondary)
            HikeRoutePicker(trail: trail, routes: routes, selection: $selectedRouteId)
            if let route, let published = trail.route(route.id) {
                HikeStatsRow(difficulty: trail.difficulty(for: published), published: published, route: route)
            }
            HStack {
                if let route {
                    Button { router.showOnMap(.hikeRoute(route.id)) } label: { Label("Show route on map", systemImage: "map").frame(minHeight: 32) }
                } else if let regionId = trail.regionId {
                    Button { router.push(.region(regionId), in: .park) } label: { Label("Region guide", systemImage: "mountain.2").frame(minHeight: 32) }
                }
                if let url = AppRouter.url(for: route.map { Route.hikeRoute(trailId: trail.id, routeId: $0.id) } ?? .trail(trail.id)) {
                    ShareLink(item: url, subject: Text(trail.name)) { Label("Share", systemImage: "square.and.arrow.up").frame(minHeight: 32) }
                }
            }
            .buttonStyle(.borderedProminent).font(.fieldCaption)
        }
    }

    private func routeCards(_ trail: Trail, _ route: HikeRoute) -> some View {
        FieldCard(eyebrow: "Route map & terrain · offline, north up, approximate") {
            let inspector: HikeInspector? = { if case .ready(let i) = inspection, i.routeId == route.id { return i } else { return nil } }()
            let cursor = inspector.flatMap { i in inspectedMetres.map { i.chainage.point(at: $0) } }
            if sizeClass == .regular {
                HStack(alignment: .top, spacing: 14) {
                    miniMap(route, cursor: cursor).frame(maxWidth: .infinity)
                    terrain(route, inspector: inspector).frame(maxWidth: .infinity)
                }
            } else {
                miniMap(route, cursor: cursor)
                terrain(route, inspector: inspector)
            }
            if let inspector {
                Text("Elevations sampled every \(Int(inspector.profile.stepMetres)) m from the bundled \(Int(inspector.profile.gridMetres.rounded())) m relief grid (\(route.pack == .park ? "USGS 3DEP" : "Mapzen/Tilezen Terrarium, from USGS 3DEP")); grade is averaged over \(Int(HikeInspector.gradeHalfWindowMetres * 2)) m of those samples. Terrain-sampled climb about \(HikeFormat.feet(metres: inspector.profile.approxGainMetres)); the NPS figure above is the published gain. Distances follow the mapped NPS trail features, not the published mileage.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func miniMap(_ route: HikeRoute, cursor: CGPoint?) -> some View {
        let height: CGFloat = sizeClass == .regular ? 280 : 210
        if case .ready(let scene) = packs.map {
            if let trace = scene.hikeRoutes[route.id] {
                HikeMiniMap(scene: scene, route: route, trace: trace, dark: scheme == .dark, cursor: cursor)
                    .frame(height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Map of the route, north up, from \(route.start.name)\(route.kind == .loop ? " and back" : " to \(route.destination.name)")\(cursor == nil ? "" : ", with the inspected point marked").")
            } else {
                Text("This route could not be resolved onto the bundled trail geometry, so it is not drawn.").font(.fieldCaption).foregroundStyle(Palette.ember)
            }
        } else if case .failed(let message) = packs.map {
            Text("Route geometry unavailable: \(message)").font(.fieldCaption).foregroundStyle(Palette.ember)
        } else {
            ProgressView().frame(maxWidth: .infinity).frame(height: height).task { await packs.loadMap() }
        }
    }

    @ViewBuilder private func terrain(_ route: HikeRoute, inspector: HikeInspector?) -> some View {
        if let inspector {
            HikeTerrainInspector(inspector: inspector, metres: $inspectedMetres)
        } else if case .unavailable = inspection {
            Text("No terrain profile: the route leaves the bundled relief grid, or the route or grid could not be loaded.").font(.fieldCaption).foregroundStyle(Palette.ember)
            Button { inspectionAttempt += 1 } label: { Label("Try again", systemImage: "arrow.clockwise").frame(minHeight: 44) }.buttonStyle(.bordered).font(.fieldCaption)
        } else {
            ProgressView().frame(maxWidth: .infinity).frame(height: 150)
        }
    }

    /// Every published variant, including those without a bundled trace, with the NPS figures only.
    private func publishedRoutesCard(_ trail: Trail, traced: [HikeRoute]) -> some View {
        FieldCard(eyebrow: "Published routes · NPS figures") {
            ForEach(trail.routes, id: \.id) { r in
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.label).font(.fieldBody.weight(.semibold))
                    Text([HikeFormat.miles(r.distanceMi) + " " + r.kind, r.gainFt.map { "\(HikeFormat.feet($0)) gain" } ?? "gain not published",
                          r.timeHours.map { "about \($0)" } ?? "no published time", r.difficulty ?? trail.difficulty].joined(separator: " · "))
                        .font(.fieldCaption).foregroundStyle(.secondary)
                    if !traced.contains(where: { $0.id == r.id }) {
                        Text("No route trace bundled").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// Untraced hikes get the region's map and trailhead pins, never a highlighted route.
    private func regionalMapCard(_ trail: Trail, regionId: String) -> some View {
        FieldCard(eyebrow: "Regional orientation map · no route trace") {
            ParkMapView(mode: .region(regionId), onSelect: { _ in }, focusTrailId: trail.id, height: sizeClass == .regular ? 300 : 230,
                        canvasAccessibilityLabel: "Regional map with park roads, trail lines and trailheads; this hike's route is not highlighted")
            Text("No verified route trace is bundled for this hike, so none is highlighted. Zoomed in, the map shows every NPS trail line, but which lines make up this hike has not been checked. Orientation only; carry a topographic map and follow trail signs.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func trailheadCard(_ trail: Trail, _ c: Content) -> some View {
        FieldCard(eyebrow: trail.isValley ? "Trailhead & shuttle" : "Trailhead & access") {
            Text(trail.start).font(.fieldBody)
            if let source = trail.trailheadSource {
                Text("Map point: \(source).").font(.caption2).foregroundStyle(.secondary)
            }
            if let roads = trail.accessRoads, !roads.isEmpty {
                Label("Reached by \(roads.map(\.name).joined(separator: ", "))", systemImage: "road.lanes").font(.fieldCaption)
            }
            ForEach(trail.access ?? [], id: \.self) { Text($0).font(.fieldCaption) }
            ForEach(trail.shuttleStops, id: \.self) { n in
                if let stop = c.place("shuttle-\(n)") {
                    Button { router.push(.place(stop.id), in: .directory) } label: { Label(stop.name, systemImage: "bus").frame(minHeight: 44) }.font(.fieldCaption)
                }
            }
        }
    }

    @ViewBuilder private func noticesCard(_ trail: Trail, _ c: Content) -> some View {
        let notices = NoticeMatcher.hikeNotices(trail, content: c, snapshot: conditions.conditions)
        FieldCard(eyebrow: trail.isValley ? "Official notices for this hike" : "Official notices for this hike, its road or region") {
            if notices.isEmpty {
                Text(emptyNoticesText(trail)).font(.fieldCaption).foregroundStyle(.secondary)
            } else {
                noticeGroup("Naming this hike", notices.hike)
                ForEach(notices.roads, id: \.road) { noticeGroup("Naming \($0.road.name)", $0.items) }
                noticeGroup("Naming the wider region", notices.region)
                Text("Matched by place and road names in the notice text; read each notice for what it covers.").font(.caption2).foregroundStyle(.secondary)
            }
            if c.trails.mistTrailIds.contains(trail.id) || c.trails.johnMuirValleyIds.contains(trail.id) {
                Text(c.trails.corridorRepairNotice).font(.fieldCaption)
                Text(c.trails.iceClosureNotice).font(.fieldCaption)
            }
            SnapshotFooter(snapshot: conditions.conditions, staleAfter: 6 * 3600)
        }
    }

    @ViewBuilder private func noticeGroup(_ title: String, _ items: [NoticeItem]) -> some View {
        if !items.isEmpty {
            Text(title).font(.fieldEyebrow).foregroundStyle(.secondary)
            ForEach(items.sorted { $0.title < $1.title }) { NoticeRow(item: $0) }
        }
    }

    private func emptyNoticesText(_ trail: Trail) -> String {
        let scope = trail.accessRoads?.isEmpty == false ? "this hike, its access road or its region" : "this hike"
        guard let snapshot = conditions.conditions else { return "No saved NPS conditions snapshot. A missing notice is not an open trail or road." }
        if snapshot.isExpired { return "The saved conditions are over 48 hours old, so their notices are not shown. That is not confirmation the trail or road is open." }
        return "No saved notice names \(scope). That is not confirmation it is open."
    }

    @ViewBuilder private func permitsCard(_ trail: Trail, _ c: Content) -> some View {
        let permits = c.permits.guides.filter { ($0.places ?? []).contains(trail.id) }
        if !permits.isEmpty {
            FieldCard(eyebrow: "Permits") {
                ForEach(permits) { g in Button { router.push(.permit(g.id), in: .permits) } label: { Label(g.title, systemImage: "checkmark.seal").frame(minHeight: 44) }.font(.fieldBody) }
            }
        }
    }

    @ViewBuilder private func linksCard(_ trail: Trail) -> some View {
        if let links = trail.links, !links.isEmpty {
            FieldCard(eyebrow: "Related") {
                ForEach(links, id: \.label) { link in
                    if let rid = link.regionId { Button { router.push(.region(rid), in: .park) } label: { Label(link.label, systemImage: "mountain.2").frame(minHeight: 44) }.font(.fieldBody) }
                    else if let u = link.url, let url = URL(string: u) { ExternalLinkRow(label: link.label, url: url) }
                    if let note = link.note { Text(note).font(.caption2).foregroundStyle(.secondary) }
                }
            }
        }
    }
}
