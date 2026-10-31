import SwiftUI

struct RootView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var content: ContentStore
    @EnvironmentObject private var theme: ThemeManager
    @EnvironmentObject private var saved: SavedStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch content.state {
            case .loading, .idle:
                LoadingView()
            case .failed(let message):
                LoadFailureView(message: message)
            case .ready:
                if sizeClass == .regular {
                    RegularRootView()
                } else {
                    CompactRootView()
                }
            }
        }
        .dynamicTypeSize(theme.dynamicTypeOverride.map { DynamicTypeSize.xSmall...$0 } ?? DynamicTypeSize.xSmall...DynamicTypeSize.accessibility5)
        .fontWeight(theme.boldText ? .semibold : nil)
        .task { await content.loadIfNeeded() }
        .onChange(of: content.isReady) { _, ready in
            if ready && !saved.state.introGuideSeen { router.sheet = .introGuide }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, content.isReady else { return }
            Task {
                await UpdatesStore.shared.check(background: true)
                await ConditionsStore.shared.refreshStale()
            }
        }
    }
}

/// iPhone: one section at a time behind a floating pill bar; the rest live in More.
private struct CompactRootView: View {
    @EnvironmentObject private var router: AppRouter
    @State private var showMore = false
    private let barHeight: CGFloat = 64

    var body: some View {
        ZStack(alignment: .bottom) {
            DynamicBackground()
            SectionHost(section: router.section)
                .environment(\.bottomBarInset, barHeight + 12)
            PillTabBar(selection: $router.section, showMore: $showMore)
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
        }
        .sheet(isPresented: $showMore) {
            MoreSheet { section in
                showMore = false
                router.show(section)
            }
            .nightVision()
        }
        .sheet(item: $router.sheet) { sheet in SheetHost(sheet: sheet) }
    }
}

/// iPad and wide layouts: grouped sidebar with the same sections.
private struct RegularRootView: View {
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { Optional(router.section) }, set: { if let s = $0 { router.show(s) } })) {
                ForEach(AppSection.groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.sections) { section in
                            Label(section.title, systemImage: section.symbol).tag(section)
                        }
                    }
                }
            }
            .navigationTitle("Enve Yosemite")
            .listStyle(.sidebar)
        } detail: {
            ZStack {
                DynamicBackground()
                SectionHost(section: router.section)
            }
        }
        .sheet(item: $router.sheet) { sheet in SheetHost(sheet: sheet) }
    }
}

/// Each section keeps its own navigation stack so returning preserves state.
struct SectionHost: View {
    let section: AppSection

    var body: some View {
        SectionStack(section: section) { sectionRoot } destination: { RouteHost(route: $0) }
    }

    @ViewBuilder private var sectionRoot: some View {
        switch section {
        case .map: MapTabScreen()
        case .directory: DirectoryScreen()
        case .search: SearchScreen()
        case .status: FieldStatusScreen()
        case .trails: TrailsScreen()
        case .park: ParkScreen()
        case .navigation: TransitScreen()
        case .events: EventsScreen()
        case .permits: PermitsScreen()
        case .contacts: ContactsScreen()
        case .documents: DocumentsScreen()
        case .fire: FireScreen()
        case .risks: RisksScreen()
        case .trip: TripScreen()
        }
    }
}

/// One section's `NavigationStack`, re-created per section and handed its path only once it is on screen.
struct SectionStack<Root: View, Destination: View>: View {
    let section: AppSection
    @ViewBuilder let root: () -> Root
    @ViewBuilder let destination: (Route) -> Destination

    var body: some View {
        MountedSectionStack(section: section, root: root, destination: destination).id(section)
    }
}

private struct MountedSectionStack<Root: View, Destination: View>: View {
    @EnvironmentObject private var router: AppRouter
    let section: AppSection
    let root: () -> Root
    let destination: (Route) -> Destination
    @State private var instance = UUID()

    private var identity: AppRouter.StackIdentity { AppRouter.StackIdentity(section: section, instance: instance) }

    var body: some View {
        NavigationStack(path: router.pathBinding(for: identity)) {
            root().navigationDestination(for: Route.self, destination: destination)
        }
        // Reported by the stack itself, inside the `.id` boundary; never onDisappear, which a split-view column fires behind pushes.
        .onAppear { router.stackDidMount(identity) }
    }
}
