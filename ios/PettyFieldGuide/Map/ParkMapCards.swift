import SwiftUI

/// What a tap on one of the map's park markers selected: a trailhead, region point, campground beyond the Valley,
/// gateway town or a point a link asked to show.
struct ParkMarkerCard: View {
    let id: String
    let content: Content
    @ObservedObject var model: MapViewModel
    let maxHeight: CGFloat
    @EnvironmentObject private var router: AppRouter
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Whether a selected marker id belongs to this card rather than the directory place card.
    static func handles(_ id: String) -> Bool {
        id == ShownPin.markerId || id.hasPrefix(ParkMapView.trailheadPrefix) || id.hasPrefix("region-") || id.hasPrefix("campground-") || id.hasPrefix("town-")
    }

    var body: some View {
        if id == ShownPin.markerId, let pin = model.shownPin {
            ParkCardShell(title: pin.title, subtitle: String(format: "%.5f, %.5f · the point the link gave, not a checked location", pin.latitude, pin.longitude),
                          maxHeight: maxHeight, close: { model.clearShownPin() }) { EmptyView() }
        } else if id.hasPrefix(ParkMapView.trailheadPrefix) {
            trailheadCard
        } else if let regionId = ParkMapView.regionId(ofMarker: id), let region = content.region(regionId) {
            ParkCardShell(title: region.name, subtitle: "\(region.tagline) · \(region.elevationFt) ft · \(region.driveFromValley)", maxHeight: maxHeight, close: close) {
                typeSize.actionLayout {
                    Button { model.focus(on: .region(region.id)) } label: { Label("Frame region", systemImage: "arrow.down.left.and.arrow.up.right").frame(minHeight: 44) }
                    Button { router.push(.region(region.id), in: .park) } label: { Label("Region guide", systemImage: "mountain.2").frame(minHeight: 44) }
                }
                .buttonStyle(.bordered).font(.fieldCaption)
            }
        } else if id.hasPrefix("campground-"), let cg = content.campground(String(id.dropFirst(11))) {
            ParkCardShell(title: cg.name, subtitle: "\(cg.area) · \(cg.sites) sites · \(cg.season). A mapped campground is not an open one or a free site; site numbers appear when zoomed in.", maxHeight: maxHeight, close: close) {
                Button { router.push(.campground(cg.id), in: .trails) } label: { Label("Campground guide", systemImage: "tent").frame(minHeight: 44) }
                    .buttonStyle(.bordered).font(.fieldCaption)
            }
        } else if id.hasPrefix("town-"), let town = content.regions.gatewayTowns.first(where: { "town-\($0.name)" == id }) {
            ParkCardShell(title: town.name, subtitle: town.note ?? "Gateway town outside the park", maxHeight: maxHeight, close: close) { EmptyView() }
        }
    }

    private func close() { model.selection = nil }

    @ViewBuilder private var trailheadCard: some View {
        let hikes = ParkMapView.hikes(atMarker: id, content: content)
        if let first = hikes.first {
            ParkCardShell(title: hikes.count == 1 ? "\(first.name) trailhead" : "Trailhead · \(hikes.count) hikes",
                          subtitle: "\(content.areaName(of: first)) · NPS trailhead point", maxHeight: maxHeight, close: close) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(hikes) { trail in hikeRow(trail) }
                }
            }
        }
    }

    private func hikeRow(_ trail: Trail) -> some View {
        let route = content.defaultHikeRoute(for: trail.id)
        return VStack(alignment: .leading, spacing: 4) {
            Text(trail.name).font(.fieldBody.weight(.semibold))
            Text((trail.routes.first.map { "\(HikeFormat.miles($0.distanceMi)) \($0.kind) · " } ?? "") + ParkMapFinderSheet.coverage(route))
                .font(.fieldCaption).foregroundStyle(.secondary)
            typeSize.actionLayout {
                if let route {
                    Button { model.selectHike(route.id) } label: {
                        Label("Show route", systemImage: "point.topleft.down.to.point.bottomright.curvepath").frame(minHeight: 44)
                    }
                }
                Button { router.push(.trail(trail.id), in: .trails) } label: { Label("Details", systemImage: "info.circle").frame(minHeight: 44) }
            }
            .buttonStyle(.bordered).font(.fieldCaption)
        }
        .accessibilityElement(children: .contain)
    }
}

/// Card chrome for the park marker cards; scrolls once the content is taller than the room left above the map.
private struct ParkCardShell<Actions: View>: View {
    let title: String
    let subtitle: String
    let maxHeight: CGFloat
    let close: () -> Void
    @ViewBuilder let actions: () -> Actions
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ViewThatFits(in: .vertical) {
            stack
            ScrollView { stack }.scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxHeight: maxHeight)
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.cardStroke(scheme)))
    }

    private var stack: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.fieldHeading)
                    Text(subtitle).font(.fieldCaption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: close) { Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary).frame(width: 44, height: 44) }
                    .accessibilityLabel("Close")
            }
            actions()
        }
    }
}

private extension DynamicTypeSize {
    /// Card buttons sit in a row, and stack at accessibility sizes so their labels stay whole.
    var actionLayout: AnyLayout {
        isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 8))
    }
}
