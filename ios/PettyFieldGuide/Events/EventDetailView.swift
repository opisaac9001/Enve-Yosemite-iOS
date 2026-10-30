import SwiftUI

struct EventDetailView: View {
    let eventId: String
    @EnvironmentObject private var content: ContentStore
    @EnvironmentObject private var router: AppRouter
    @ObservedObject private var conditions = ConditionsStore.shared

    var body: some View {
        if eventId.hasPrefix("nps:") {
            npsBody(String(eventId.dropFirst(4)))
        } else if let c = content.content, let event = c.event(eventId) {
            curatedBody(event, c)
        } else {
            EmptyStateView(symbol: "calendar", title: "Event not found", message: "This link points to a listing that is not in the guide.")
        }
    }

    private func curatedBody(_ event: CuratedEvent, _ c: Content) -> some View {
        let occurrences = EventCalendar.occurrences(of: event)
        let ended = DateText.parse(event.end).map { $0 < Date() } ?? false
        return FieldScroll {
            FieldCard {
                Text("\(event.category) · \(event.area)").font(.fieldEyebrow).foregroundStyle(.secondary)
                Text(event.dateLabel).font(.fieldHeading).foregroundStyle(ended ? .secondary : Palette.accent)
                if ended { Text("Ended \(DateText.long(event.end))").font(.fieldCaption).foregroundStyle(Palette.ember) }
                Text(event.summary).font(.fieldBody)
                HStack {
                    if let pid = event.placeId, c.place(pid) != nil { Button { router.showOnMap(.place(pid)) } label: { Label("Map", systemImage: "map") } }
                    if let url = AppRouter.url(for: .event(event.id)) { ShareLink(item: url, subject: Text(event.title)) { Label("Share", systemImage: "square.and.arrow.up") } }
                }
                .buttonStyle(.bordered).font(.fieldCaption)
            }
            FieldCard(eyebrow: "Schedule") {
                Text(event.schedule).font(.fieldBody)
                if occurrences.count > 1 {
                    Text("\(occurrences.count) dates: \(occurrences.prefix(12).map { DateText.long($0.day) }.joined(separator: " · "))\(occurrences.count > 12 ? " …" : "")").font(.fieldCaption).foregroundStyle(.secondary)
                }
                Text("Ends \(DateText.long(event.end)) · Pacific time").font(.caption2).foregroundStyle(.tertiary)
            }
            FieldCard(eyebrow: "Location") { Text(event.location).font(.fieldBody) }
            FieldCard(eyebrow: "Cost · \(event.admissionLabel ?? event.admission)") { Text(event.cost).font(.fieldBody) }
            FieldCard(eyebrow: "Booking & access") {
                Text(event.registration).font(.fieldBody)
                if let u = event.registrationUrl, let url = URL(string: u) { ExternalLinkRow(label: "Booking page", url: url) }
                if let prep = event.preparation {
                    Text(prep).font(.fieldCaption)
                    if let u = event.preparationUrl, let url = URL(string: u) { ExternalLinkRow(label: "Preparation list", url: url) }
                }
            }
            FieldCard(eyebrow: "Host & source") {
                LabeledContent("Host", value: event.host).font(.fieldCaption)
                if let url = URL(string: event.sourceUrl) { ExternalLinkRow(label: "Provider listing", url: url) }
                Text("Checked \(DateText.long(event.checked))\(event.sourceDate.map { " · source dated \(DateText.long($0))" } ?? ""). Availability is never inferred; confirm with the host.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .fieldNavigationTitle(event.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func npsBody(_ id: String) -> some View {
        if let snap = conditions.programs, let item = snap.payload.events.items.first(where: { $0.id == id }) {
            FieldScroll {
                FieldCard {
                    Text("NPS calendar · \(item.types.joined(separator: ", "))").font(.fieldEyebrow).foregroundStyle(.secondary)
                    Text(item.description ?? "").font(.fieldBody)
                    if let loc = item.location { Text(loc).font(.fieldCaption) }
                }
                FieldCard(eyebrow: "Dates & times") {
                    Text(item.dates.prefix(20).map { DateText.long($0) }.joined(separator: " · ") + (item.dates.count > 20 ? " …" : "")).font(.fieldCaption)
                    ForEach(Array(item.times.enumerated()), id: \.offset) { _, t in
                        Text([t.start, t.end].compactMap { $0 }.joined(separator: "–")).font(.fieldBody)
                    }
                    if let cancelled = item.cancelledDates, !cancelled.isEmpty { Text("Cancelled: \(cancelled.joined(separator: ", "))").font(.fieldCaption).foregroundStyle(Palette.ember) }
                    if let rule = item.recurrenceRule { Text(rule).font(.caption2).foregroundStyle(.tertiary) }
                }
                FieldCard(eyebrow: "Cost & registration") {
                    Text(item.feeInfo ?? (item.isFree == true ? "Free" : "Fee not stated")).font(.fieldBody)
                    if let r = item.registrationInfo { Text(r).font(.fieldCaption) }
                    if let u = item.registrationUrl ?? item.infoUrl, let url = URL(string: u) { ExternalLinkRow(label: "Registration / information", url: url) }
                }
                FieldCard(eyebrow: "Source") {
                    if let u = item.url, let url = URL(string: u) { ExternalLinkRow(label: "NPS event page", url: url) }
                    if let up = item.updated { Text("NPS record updated \(DateText.long(up))").font(.caption2).foregroundStyle(.secondary) }
                    SnapshotFooter(snapshot: snap, staleAfter: 12 * 3600)
                }
            }
            .fieldNavigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            EmptyStateView(symbol: "calendar", title: "NPS listing unavailable", message: "The saved NPS calendar snapshot no longer contains this listing.")
        }
    }
}
