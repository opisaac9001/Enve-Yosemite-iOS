import SwiftUI
import CoreLocation

struct MapScreen: View {
    @EnvironmentObject private var content: ContentStore
    @EnvironmentObject private var saved: SavedStore
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var router: AppRouter
    @StateObject private var model = MapViewModel(restoresPreferences: true)
    @StateObject private var location = LocationService()
    @ObservedObject private var packs = GeoPackStore.shared
    @ObservedObject private var updates = UpdatesStore.shared
    @ObservedObject private var conditions = ConditionsStore.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.bottomBarInset) private var bottomInset
    @State private var showLayers = false
    @State private var showKey = false
    @State private var showCategories = false
    @State private var showSun = false
    @State private var showCar = false
    @State private var placingCar = false
    @State private var proposedCar: CLLocationCoordinate2D?
    @State private var carNote = ""
    @State private var carMessage: String?
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var topChromeHeight: CGFloat = 96
    @State private var bottomChromeHeight: CGFloat = 40
    @State private var safeInsets = EdgeInsets()
    @State private var viewHeight: CGFloat = 0

    private static let quickCategories = ["parking", "shuttle", "food", "facilities", "water"]

    var body: some View {
        layers(of: canvasStack)
    }

    private var canvasStack: some View {
        ZStack(alignment: .top) {
            MapCanvasView(model: model, scaleLimits: model.scaleLimits, clampRect: model.clampRect)
                .overlay { if placingCar { crosshairMark } }
                .ignoresSafeArea()
                .accessibilityLabel("Yosemite Valley map")
            VStack(spacing: 8) {
                topBar
                filterRow
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .background(GeometryReader { p in Color.clear.preference(key: TopChromeHeightKey.self, value: p.size.height) })
            controls
            bottomStack
        }
        .background(GeometryReader { p in
            Color.clear
                .onAppear { safeInsets = p.safeAreaInsets; viewHeight = p.size.height }
                .onChange(of: p.safeAreaInsets) { _, new in safeInsets = new }
                .onChange(of: p.size.height) { _, new in viewHeight = new }
        })
        .onPreferenceChange(TopChromeHeightKey.self) { topChromeHeight = $0 }
        .onPreferenceChange(BottomChromeHeightKey.self) { bottomChromeHeight = $0 }
        .toolbar(.hidden, for: .navigationBar)
    }

    private func layers(of view: some View) -> some View {
        sheets(of: observers(of: view))
    }

    private func observers(of view: some View) -> some View {
        view
            .task { await bootstrap() }
            .onChange(of: content.isReady) { _, _ in configure() }
            .onChange(of: saved.state) { _, new in model.update(saved: new) }
            .onChange(of: conditions.smoke?.retrievedAt) { _, _ in model.update(smoke: conditions.smoke) }
            .onChange(of: theme.mapElementSize) { _, _ in model.update(elementScale: theme.mapElementSize.scale, dark: scheme == .dark) }
            .onChange(of: scheme) { _, new in model.update(elementScale: theme.mapElementSize.scale, dark: new == .dark) }
            .onChange(of: router.mapFocus) { _, focus in
                guard let focus else { return }
                model.focus(on: focus)
                router.mapFocus = nil
            }
            .onChange(of: router.pendingMapTool) { _, _ in openPendingTool() }
            .onChange(of: model.camera.scale) { old, new in
                if (old < 1.2) != (new < 1.2) { model.cameraScaleChanged() }
            }
            .onChange(of: location.lastLocation) { _, loc in handleLocation(loc) }
            .onChange(of: model.pendingCarPlacement) { _, spot in
                guard let spot else { return }
                model.pendingCarPlacement = nil
                openCarSheet(proposed: spot.coordinate)
            }
            .onChange(of: topChromeHeight) { _, _ in updateInsets() }
            .onChange(of: bottomChromeHeight) { _, _ in updateInsets() }
            .onChange(of: safeInsets) { _, _ in updateInsets() }
            .onChange(of: bottomInset) { _, _ in updateInsets() }
    }

    private func sheets(of view: some View) -> some View {
        view
            .sheet(isPresented: $showLayers) { MapLayersSheet(model: model) }
            .sheet(isPresented: $showKey) { MapKeySheet(scene: model.scene) }
            .sheet(isPresented: $showCategories) { if let c = content.content { MapCategoriesSheet(model: model, categories: c.categories.categories) } }
            .sheet(isPresented: $showSun) { SunPreviewSheet(model: model) }
            .sheet(isPresented: $showCar, onDismiss: { proposedCar = nil }) { carSheet }
            .task(id: carMessage) {
                guard carMessage != nil else { return }
                try? await Task.sleep(for: .seconds(6))
                if !Task.isCancelled { carMessage = nil }
            }
    }

    /// Ceiling for the hike card: a third of the view (never under 120 pt) stays map between the chrome.
    private var hikeCardMaxHeight: CGFloat {
        let reserved = safeInsets.top + 4 + topChromeHeight + 8 + max(120, viewHeight * 0.33) + 56 + safeInsets.bottom + bottomInset + 4
        return max(130, viewHeight - reserved)
    }

    private func updateInsets() {
        model.obscuredInsets = UIEdgeInsets(top: safeInsets.top + 4 + topChromeHeight + 8, left: 0,
                                            bottom: safeInsets.bottom + bottomInset + 4 + bottomChromeHeight + 8, right: 64)
    }

    private func handleLocation(_ loc: CLLocation?) {
        guard let loc else { return }
        model.userLocation = loc.coordinate
        if location.pendingAction == .centre {
            model.focus(on: loc.coordinate, scale: max(model.camera.scale, 0.8))
        } else if location.pendingAction == .car {
            pinCar(at: loc.coordinate, basis: .location, accuracy: loc.horizontalAccuracy)
        }
        location.pendingAction = nil
    }

    // MARK: Parked car

    private var carSheet: some View {
        ParkedCarSheet(existing: saved.state.car, proposed: proposedCar, note: $carNote,
                       onUseLocation: { location.request(.car) },
                       onChooseOnMap: { placingCar = true },
                       onSave: { coordinate, basis in pinCar(at: coordinate, basis: basis) },
                       onShowOnMap: showCarOnMap,
                       onClear: { saved.setCar(nil); carNote = ""; carMessage = "Parked-car pin cleared." })
    }

    private func showCarOnMap() {
        guard let car = saved.state.car else { return }
        model.selection = .car
        model.focus(on: car.coordinate, scale: max(model.camera.scale, 1.0))
    }

    private func openCarSheet(proposed: CLLocationCoordinate2D?) {
        if carNote.isEmpty { carNote = saved.state.car?.note ?? "" }
        proposedCar = proposed
        showCar = true
    }

    /// The single write path for the pin, whichever way the spot was chosen.
    private func pinCar(at coordinate: CLLocationCoordinate2D, basis: CarPinBasis, accuracy: CLLocationAccuracy? = nil) {
        let car = ParkedCar.pin(at: coordinate, basis: basis, note: carNote)
        saved.setCar(car)
        placingCar = false
        var text = basis == .location ? "Parked car pinned at your position" : "Parked car pinned"
        if let accuracy, accuracy > 0 { text += String(format: " (±%.0f m)", accuracy) }
        if ParkedCar.isOnValleyMap(coordinate) {
            model.selection = .car
        } else {
            text += ". It lies outside the bundled Valley map, so it is not drawn here; Trip prep keeps the coordinates."
        }
        carMessage = text + "."
    }

    /// Drawn as an overlay of the canvas itself, so its centre is the camera centre that `centerCoordinate` saves.
    private var crosshairMark: some View {
        Image(systemName: "plus.viewfinder")
            .font(.system(size: 44, weight: .light))
            .foregroundStyle(Palette.accent)
            .shadow(radius: 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func bootstrap() async {
        configure()
        updateInsets()
        await packs.loadValley()
        if case .ready(let scene) = packs.valley { model.setScene(scene) }
        if let focus = router.mapFocus {
            model.focus(on: focus)
            router.mapFocus = nil
        }
        openPendingTool()
    }

    private func openPendingTool() {
        guard let tool = router.pendingMapTool else { return }
        router.pendingMapTool = nil
        switch tool {
        case .sunPreview: showSun = true
        case .layers: showLayers = true
        case .parkedCar: openCarSheet(proposed: nil)
        }
    }

    private func configure() {
        guard let c = content.content else { return }
        model.configure(content: c, saved: saved.state, elementScale: theme.mapElementSize.scale, dark: scheme == .dark)
        model.update(smoke: conditions.smoke)
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack(spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find a place, stop or site", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                    .onSubmit { runSearch() }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            Button { router.sheet = .settings } label: {
                Image(systemName: "gearshape.fill").padding(10).background(.regularMaterial, in: Circle())
            }
            .accessibilityLabel("Settings")
            Button { router.sheet = .updates } label: {
                Image(systemName: "bell.fill").padding(10).background(.regularMaterial, in: Circle())
                    .overlay(alignment: .topTrailing) {
                        if updates.unreadCount > 0 {
                            Text("\(updates.unreadCount)").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                .padding(4).background(Palette.accent, in: Circle())
                        }
                    }
            }
            .accessibilityLabel(updates.unreadCount > 0 ? "Updates, \(updates.unreadCount) unread" : "Updates")
        }
        .overlay(alignment: .top) {
            if !query.isEmpty, let c = content.content {
                MapSearchResults(query: query, content: c) { place in
                    query = ""
                    searchFocused = false
                    model.focus(on: .place(place.id))
                }
                .padding(.top, 48)
            }
        }
        .zIndex(2)
    }

    private func runSearch() {
        guard let c = content.content else { return }
        if let hit = SearchIndex.shared(for: c).placeOrSite(matching: query) {
            query = ""
            searchFocused = false
            model.focus(on: hit)
        }
    }

    private var filterRow: some View {
        HStack(spacing: 6) {
            if let c = content.content {
                let total = c.categories.categories.count
                let shown = model.activeCategories.intersection(c.categories.categories.map(\.id)).count
                Button { showCategories = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "line.3.horizontal.decrease.circle.fill")
                        Text("\(shown)/\(total)").font(.fieldCaption.weight(.semibold)).monospacedDigit()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Map filters, \(shown) of \(total) categories shown")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Self.quickCategories, id: \.self) { id in
                            if let category = c.category(id) {
                                ChipButton(title: category.label, symbol: category.symbol, active: model.activeCategories.contains(id), color: Color(UIColor(hex: category.color))) {
                                    if model.activeCategories.contains(id) { model.activeCategories.remove(id) } else { model.activeCategories.insert(id) }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .accessibilityLabel("Quick map filters")
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            controlGroup {
                controlButton("plus", "Zoom in") { model.zoomIn() }
                Divider().frame(width: 24)
                controlButton("minus", "Zoom out") { model.zoomOut() }
            }
            .overlay(alignment: .topTrailing) {
                if model.zoomLocked {
                    Image(systemName: "lock.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .padding(4).background(Palette.accent, in: Circle()).offset(x: 4, y: -4)
                        .accessibilityHidden(true)
                }
            }
            controlGroup { controlButton("location", "Show my position") { location.request(.centre) } }
            controlGroup {
                controlButton("square.3.layers.3d", "Layers") { showLayers = true }
                Divider().frame(width: 24)
                controlButton("arrow.down.left.and.arrow.up.right", "Fit the whole Valley") { model.fitValley() }
            }
            toolsMenu
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.trailing, 10)
        .padding(.top, topChromeHeight + 16)
    }

    private func controlGroup<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.cardStroke(scheme)))
    }

    private func controlButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 44, height: 42)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var toolsMenu: some View {
        Menu {
            Button { model.zoomLocked.toggle() } label: { Label(model.zoomLocked ? "Unlock zoom" : "Lock zoom", systemImage: model.zoomLocked ? "lock.open" : "lock") }
            Divider()
            Button { openCarSheet(proposed: nil) } label: { Label(saved.state.car == nil ? "Mark parked car" : "Parked car", systemImage: "car.fill") }
            Button { router.sheet = .waterIceGuide } label: { Label("Water & ice guide", systemImage: "drop.fill") }
            Button { showSun = true } label: { Label("Sun & terrain preview", systemImage: "sun.max") }
            Button { showKey = true } label: { Label("Map key & sources", systemImage: "list.bullet.rectangle") }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "ellipsis.circle.fill").font(.system(size: 17, weight: .semibold))
                Text("Tools").font(.system(size: 9, weight: .semibold, design: .rounded))
            }
            .frame(width: 44, height: 50)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.cardStroke(scheme)))
        }
        .accessibilityLabel("Map tools")
    }

    private var bottomStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if case .loading = packs.valley { StatusPill(state: .unknown, text: "Loading Valley geometry…") }
                    if case .failed(let message) = packs.valley { StatusPill(state: .unavailable, text: "Detailed layers unavailable: \(message)") }
                    if let message = location.message { StatusPill(state: .unknown, text: message) }
                    if let carMessage { StatusPill(state: .ready, text: carMessage) }
                    Spacer()
                }
                .allowsHitTesting(false)
                HStack(alignment: .bottom) {
                    MapScaleBadge(scale: model.camera.scale) { showKey = true }
                    Spacer()
                }
                if placingCar {
                    ParkedCarPlacementBar(note: carNote, onSet: { pinCar(at: model.centerCoordinate, basis: .manual) }, onCancel: { placingCar = false })
                } else if case .hike(let routeId)? = model.selection, let c = content.content, let route = c.hikeRoute(routeId), let trail = c.trail(route.trailId) {
                    HikeMapCard(trail: trail, route: route, content: c, model: model, maxHeight: hikeCardMaxHeight)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if let selection = model.selection, let c = content.content {
                    MapSelectionCard(selection: selection, content: c, scene: model.scene, model: model) { model.selection = nil }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .background(GeometryReader { p in Color.clear.preference(key: BottomChromeHeightKey.self, value: p.size.height) })
        }
        .padding(.horizontal, 12)
        .padding(.bottom, bottomInset + 4)
    }
}

private struct TopChromeHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 96
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct BottomChromeHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 44
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct MapScaleBadge: View {
    let scale: CGFloat
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let metres = MapRenderer.scaleBarMetres(for: scale, maxWidth: 96)
        let text = MapRenderer.scaleBarText(metres: metres)
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(text).font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
                    ZStack(alignment: .leading) {
                        Rectangle().frame(width: max(24, metres * scale), height: 2)
                        Rectangle().frame(width: 1.5, height: 6)
                        Rectangle().frame(width: 1.5, height: 6).offset(x: max(24, metres * scale) - 1.5)
                    }
                    .frame(height: 6, alignment: .bottom)
                }
                Divider().frame(height: 20)
                HStack(spacing: 2) {
                    Image(systemName: "location.north.fill").font(.system(size: 9, weight: .bold))
                    Text("N").font(.system(size: 10, weight: .bold, design: .rounded))
                }
                Divider().frame(height: 20)
                HStack(spacing: 3) {
                    Image(systemName: "info.circle").font(.system(size: 10, weight: .semibold))
                    Text("Sources").font(.system(size: 10, weight: .semibold, design: .rounded))
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.cardStroke(scheme)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Scale \(text). North is up. Map key and sources")
    }
}

struct MapSearchResults: View {
    let query: String
    let content: Content
    let choose: (Place) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let results = SearchIndex.shared(for: content).places(matching: query, limit: 8, content: content)
        if !results.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(results) { place in
                    Button { choose(place) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(place.name).font(.fieldBody.weight(.semibold))
                            Text(place.campus).font(.fieldCaption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}
