import CoreGraphics

enum LabelKind { case landform, water, road, place, building, custom }

/// A measured label with its preferred positions; geometry only, so placement needs no fonts.
struct LabelCandidate {
    let id: String
    let text: String
    let kind: LabelKind
    let point: CGPoint             // screen anchor
    let size: CGSize               // measured text size
    let priority: Int
    let angle: CGFloat             // radians, for text drawn along a line; 0 for horizontal labels
    /// Offsets of the label rect's centre from `point`, tried in order.
    let offsets: [CGPoint]

    init(id: String, text: String, kind: LabelKind, point: CGPoint, size: CGSize, priority: Int, angle: CGFloat = 0, offsets: [CGPoint] = [.zero]) {
        self.id = id; self.text = text; self.kind = kind; self.point = point; self.size = size
        self.priority = priority; self.angle = angle; self.offsets = offsets
    }

    /// Axis-aligned footprint of the (possibly rotated) label centred at `centre`.
    func footprint(centredAt centre: CGPoint) -> CGRect {
        let c = abs(cos(angle)), s = abs(sin(angle))
        let w = size.width * c + size.height * s
        let h = size.width * s + size.height * c
        return CGRect(x: centre.x - w / 2, y: centre.y - h / 2, width: w, height: h)
    }
}

struct PlacedLabel {
    let candidate: LabelCandidate
    let center: CGPoint
    let footprint: CGRect
}

enum LabelPlacer {
    /// Greedy by priority (ties by id): first offset whose footprint is inside `bounds` and clear of
    /// reserved rects and earlier labels wins.
    static func place(_ candidates: [LabelCandidate], reserved: [CGRect], bounds: CGRect, padding: CGFloat = 2) -> [PlacedLabel] {
        var taken = reserved
        var result: [PlacedLabel] = []
        let ordered = candidates.sorted { $0.priority != $1.priority ? $0.priority > $1.priority : $0.id < $1.id }
        for candidate in ordered {
            for offset in candidate.offsets {
                let centre = CGPoint(x: candidate.point.x + offset.x, y: candidate.point.y + offset.y)
                let footprint = candidate.footprint(centredAt: centre)
                let padded = footprint.insetBy(dx: -padding, dy: -padding)
                guard bounds.contains(footprint), !taken.contains(where: { $0.intersects(padded) }) else { continue }
                taken.append(padded)
                result.append(PlacedLabel(candidate: candidate, center: centre, footprint: footprint))
                break
            }
        }
        return result
    }

    /// Right, left, below, above a marker footprint.
    static func besideOffsets(frame: CGRect, anchor: CGPoint, size: CGSize, gap: CGFloat = 4) -> [CGPoint] {
        let cy = frame.midY - anchor.y
        return [CGPoint(x: frame.maxX - anchor.x + gap + size.width / 2, y: cy),
                CGPoint(x: frame.minX - anchor.x - gap - size.width / 2, y: cy),
                CGPoint(x: 0, y: frame.maxY - anchor.y + gap + size.height / 2),
                CGPoint(x: 0, y: frame.minY - anchor.y - gap - size.height / 2)]
    }
}
