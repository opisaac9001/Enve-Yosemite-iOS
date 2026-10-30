import XCTest
import SwiftUI
import UIKit
@testable import PettyFieldGuide

/// Cross-section pushes: the intended path is kept per section and only handed to the stack instance that is on screen.
@MainActor
final class SectionNavigationTests: XCTestCase {
    private let detail = Route.hikeRoute(trailId: "trail-yosemite-falls", routeId: "yosemite-falls-columbia-rock")
    private let campground = Route.campground("cg-upper-pines")

    private func stack(_ section: AppSection) -> AppRouter.StackIdentity { AppRouter.StackIdentity(section: section, instance: UUID()) }

    func testPathsAreKeptPerSectionButOnlyTheMountedStackReadsThem() {
        let router = AppRouter()
        let map = stack(.map)
        router.stackDidMount(map)
        router.push(detail, in: .trails)
        XCTAssertEqual(router.section, .trails)
        XCTAssertEqual(router.paths[.trails], [detail], "the intended path is recorded at once")
        let trails = stack(.trails)
        XCTAssertEqual(router.pathBinding(for: trails).wrappedValue, [], "an unmounted stack reads an empty path, so it is never created pre-populated")
        XCTAssertEqual(router.pathBinding(for: map).wrappedValue, [])

        router.pathBinding(for: trails).wrappedValue = []
        XCTAssertEqual(router.paths[.trails], [detail], "a stack that is not on screen cannot wipe the intended path")

        router.stackDidMount(trails)
        XCTAssertEqual(router.mountedSection, .trails)
        XCTAssertEqual(router.pathBinding(for: trails).wrappedValue, [detail], "mounting hands the pending push to the live stack")
        XCTAssertEqual(router.pathBinding(for: map).wrappedValue, [], "the superseded stack reads nothing")
        router.pathBinding(for: map).wrappedValue = [campground]
        XCTAssertNil(router.paths[.map], "the superseded stack cannot write either")

        // In-section navigation and back both go through the binding of the mounted stack.
        router.pathBinding(for: trails).wrappedValue = [detail, campground]
        XCTAssertEqual(router.paths[.trails], [detail, campground])
        router.pathBinding(for: trails).wrappedValue = [detail]
        XCTAssertEqual(router.paths[.trails], [detail])

        // Leaving and returning keeps the section's history for its next stack instance.
        router.show(.map)
        router.stackDidMount(stack(.map))
        XCTAssertEqual(router.pathBinding(for: trails).wrappedValue, [], "the old Trails stack is stale once another mounts")
        XCTAssertEqual(router.paths[.trails], [detail])
        let trailsAgain = stack(.trails)
        XCTAssertEqual(router.pathBinding(for: trailsAgain).wrappedValue, [])
        router.stackDidMount(trailsAgain)
        XCTAssertEqual(router.pathBinding(for: trailsAgain).wrappedValue, [detail])

        // A re-created stack for the section already mounted (a re-hosted root) starts empty and is handed the path on mount.
        let rehosted = stack(.trails)
        XCTAssertEqual(router.pathBinding(for: rehosted).wrappedValue, [])
        router.stackDidMount(rehosted)
        XCTAssertEqual(router.pathBinding(for: rehosted).wrappedValue, [detail])
        XCTAssertEqual(router.pathBinding(for: trailsAgain).wrappedValue, [])
    }

    func testDeepLinksBeforeAnyStackExistsLandOnceTheSectionMounts() {
        let router = AppRouter()
        router.open(url: URL(string: "enveyosemite://trail/trail-half-dome/half-dome-john-muir")!)
        XCTAssertEqual(router.section, .trails)
        let trails = stack(.trails)
        XCTAssertEqual(router.pathBinding(for: trails).wrappedValue, [])
        router.stackDidMount(trails)
        XCTAssertEqual(router.pathBinding(for: trails).wrappedValue, [.hikeRoute(trailId: "trail-half-dome", routeId: "half-dome-john-muir")])
    }

    // MARK: Hosted stacks

    private func navigationControllers(in controller: UIViewController) -> [UINavigationController] {
        var found: [UINavigationController] = []
        if let nav = controller as? UINavigationController { found.append(nav) }
        for child in controller.children { found += navigationControllers(in: child) }
        return found
    }

    /// The deepest live navigation controller: the one showing the section stack, whether the split view nests or flattens it.
    private func deepest(in host: UIViewController) throws -> UINavigationController {
        try XCTUnwrap(navigationControllers(in: host).max { $0.viewControllers.count < $1.viewControllers.count })
    }

    private func settle(_ host: UIViewController, seconds: TimeInterval = 0.1) {
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// The production `SectionStack` in a compact root: a push made while another section is showing
    /// must end on the pushed screen once the target section's stack is mounted, not on its root.
    func testHostedStackShowsACrossSectionPushAfterMounting() throws {
        struct Host: View {
            @ObservedObject var router: AppRouter
            var body: some View {
                SectionStack(section: router.section) { Text("root of \(router.section.rawValue)") } destination: { Text("detail \(String(describing: $0))") }
                    .environmentObject(router)
            }
        }
        let router = AppRouter()
        let host = UIHostingController(rootView: Host(router: router))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.isHidden = false
        settle(host)
        XCTAssertEqual(router.mountedSection, .map)
        XCTAssertEqual(try deepest(in: host).viewControllers.count, 1)

        // The Details button on the hike map card: a push into another section.
        router.push(detail, in: .trails)
        settle(host)
        settle(host)
        XCTAssertEqual(router.mountedSection, .trails)
        XCTAssertEqual(router.paths[.trails], [detail], "the push survived the stack swap")
        XCTAssertEqual(try deepest(in: host).viewControllers.count, 2, "the Trails stack shows the pushed detail, not its root")

        // Back pops through the binding; the section keeps its (now empty) history.
        try deepest(in: host).popViewController(animated: false)
        settle(host)
        XCTAssertEqual(router.paths[.trails], [])
        window.isHidden = true
    }

    /// The regular root's split layout: a sidebar switch, an in-section `NavigationLink` push (the stack appends to its
    /// bound path), a cross-section push, Back, and the section's history on return. The in-section push is the iPad
    /// regression: the column fires the stack's `onDisappear` behind the push, which must not pop it.
    func testSplitLayoutKeepsInSectionPushesAndSectionHistory() throws {
        struct Shell: View {
            @ObservedObject var router: AppRouter
            var body: some View {
                NavigationSplitView {
                    List(selection: Binding(get: { Optional(router.section) }, set: { if let s = $0 { router.show(s) } })) {
                        ForEach(AppSection.pillTabs) { Text($0.title).tag($0) }
                    }
                } detail: {
                    ZStack {
                        Color.clear
                        SectionStack(section: router.section) { Text("root of \(router.section.rawValue)") } destination: { Text("detail \(String(describing: $0))") }
                    }
                }
                .environmentObject(router)
            }
        }
        let router = AppRouter()
        let host = UIHostingController(rootView: Shell(router: router))
        host.traitOverrides.horizontalSizeClass = .regular
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1366, height: 1024))
        window.rootViewController = host
        window.isHidden = false
        settle(host)
        XCTAssertEqual(host.traitCollection.horizontalSizeClass, .regular, "the split view must lay out with both columns")
        XCTAssertEqual(router.mountedSection, .map)
        XCTAssertEqual(try deepest(in: host).viewControllers.count, 1)

        // Sidebar: Trails.
        router.show(.trails)
        settle(host)
        XCTAssertEqual(router.mountedSection, .trails)
        let mounted = try XCTUnwrap(router.mountedStack)

        // A hike card is a NavigationLink: the stack appends to the path it is bound to.
        router.pathBinding(for: mounted).wrappedValue.append(detail)
        settle(host, seconds: 0.3)
        settle(host, seconds: 0.3)
        XCTAssertEqual(router.paths[.trails], [detail])
        XCTAssertEqual(router.mountedStack, mounted, "the push covering the stack's root does not unmount it")
        XCTAssertEqual(try deepest(in: host).viewControllers.count, 2, "the pushed detail stays on top")

        // Sidebar: Map keeps the Trails history; Details on the hike card pushes into it from the Map.
        router.show(.map)
        settle(host)
        XCTAssertEqual(router.mountedSection, .map)
        XCTAssertEqual(try deepest(in: host).viewControllers.count, 1)
        XCTAssertEqual(router.paths[.trails], [detail])
        router.push(campground, in: .trails)
        settle(host, seconds: 0.3)
        settle(host, seconds: 0.3)
        XCTAssertEqual(router.mountedSection, .trails)
        XCTAssertEqual(router.paths[.trails], [detail, campground])
        XCTAssertEqual(try deepest(in: host).viewControllers.count, 3, "the cross-section push lands on top of the restored history")

        // Back pops through the binding.
        try deepest(in: host).popViewController(animated: false)
        settle(host)
        XCTAssertEqual(router.paths[.trails], [detail])
        XCTAssertEqual(try deepest(in: host).viewControllers.count, 2)

        // Leaving and returning restores the section where it was left.
        router.show(.map)
        settle(host)
        router.show(.trails)
        settle(host, seconds: 0.3)
        XCTAssertEqual(router.mountedSection, .trails)
        XCTAssertEqual(router.paths[.trails], [detail])
        XCTAssertEqual(try deepest(in: host).viewControllers.count, 2, "the re-created stack shows the kept history")
        window.isHidden = true
    }
}
