// Draws the Enve Yosemite app icon: a folded cream/amber field map in front of a granite dome and
// an orange sun on a warm ink ground. Original vector art, no external assets.
//
//   xcrun --toolchain default swift -module-cache-path /tmp/enve-yosemite-icon-modules \
//     tools/generate_app_icon.swift ios/PettyFieldGuide/Assets.xcassets/AppIcon.appiconset/AppIcon.png

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let side = 1024
let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "ios/PettyFieldGuide/Assets.xcassets/AppIcon.appiconset/AppIcon.png")

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

let ink = rgb(0x1E1411)
let ground = rgb(0x2A1F1B)
let accent = rgb(0xF5921A)
let sunCore = rgb(0xFFC46B)
let cream = rgb(0xF4E3B8)
let creamShade = rgb(0xE8D09A)
let amber = rgb(0xE9B65C)
let amberShade = rgb(0xD9A043)
let graniteLit = rgb(0xC2A07C)
let graniteShade = rgb(0x8A5E44)
let ridge = rgb(0x5E4033)
let trail = rgb(0xB8582A)
let contour = rgb(0xC9A96B)

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.setAllowsAntialiasing(true)
ctx.setShouldAntialias(true)
ctx.setLineJoin(.round)
ctx.setLineCap(.round)
// Design in a top-left coordinate system.
ctx.translateBy(x: 0, y: CGFloat(side))
ctx.scaleBy(x: 1, y: -1)

func fill(_ path: CGPath, _ color: CGColor) {
    ctx.addPath(path); ctx.setFillColor(color); ctx.fillPath()
}

func stroke(_ path: CGPath, _ color: CGColor, _ width: CGFloat) {
    ctx.addPath(path); ctx.setStrokeColor(color); ctx.setLineWidth(width); ctx.strokePath()
}

func polygon(_ points: [CGPoint]) -> CGPath {
    let p = CGMutablePath()
    p.addLines(between: points)
    p.closeSubpath()
    return p
}

func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

// Ground
ctx.setFillColor(ground)
ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))

// Sun, partly tucked behind the dome's shoulder.
let sunCenter = pt(732, 332)
let sun = CGPath(ellipseIn: CGRect(x: sunCenter.x - 128, y: sunCenter.y - 128, width: 256, height: 256), transform: nil)
fill(sun, accent)
stroke(sun, ink, 16)
fill(CGPath(ellipseIn: CGRect(x: sunCenter.x - 70, y: sunCenter.y - 70, width: 140, height: 140), transform: nil), sunCore)

// Distant ridge on the right, behind everything else.
let ridgeShape = polygon([pt(560, 720), pt(700, 560), pt(790, 600), pt(900, 470), pt(1000, 600), pt(1010, 720)])
fill(ridgeShape, ridge)
stroke(ridgeShape, ink, 16)

// Granite dome: sheer face on the left, rounded crest falling away to the right.
let dome = CGMutablePath()
dome.move(to: pt(150, 720))
dome.addLine(to: pt(262, 360))
dome.addQuadCurve(to: pt(420, 250), control: pt(300, 262))
dome.addCurve(to: pt(780, 540), control1: pt(560, 250), control2: pt(700, 400))
dome.addQuadCurve(to: pt(860, 720), control: pt(830, 620))
dome.closeSubpath()
fill(dome, graniteLit)

// Shadowed face and the crack that separates it from the lit crest.
let face = CGMutablePath()
face.move(to: pt(150, 720))
face.addLine(to: pt(262, 360))
face.addQuadCurve(to: pt(420, 250), control: pt(300, 262))
face.addQuadCurve(to: pt(372, 470), control: pt(360, 330))
face.addQuadCurve(to: pt(330, 720), control: pt(380, 600))
face.closeSubpath()
ctx.saveGState()
ctx.addPath(dome); ctx.clip()
fill(face, graniteShade)
ctx.restoreGState()
stroke(dome, ink, 18)
let seam = CGMutablePath()
seam.move(to: pt(420, 250))
seam.addQuadCurve(to: pt(372, 470), control: pt(360, 330))
seam.addQuadCurve(to: pt(330, 720), control: pt(380, 600))
stroke(seam, ink, 12)
let ledge = CGMutablePath()
ledge.move(to: pt(236, 430))
ledge.addQuadCurve(to: pt(330, 520), control: pt(300, 445))
stroke(ledge, ink, 10)

// Folded field map in the foreground: three panels, the middle one lifted at both folds.
let xs: [CGFloat] = [96, 372, 652, 928]
let top: [CGFloat] = [640, 596, 640, 596]
let bottom: [CGFloat] = [924, 880, 924, 880]
let panelColors: [(CGColor, CGColor)] = [(cream, creamShade), (amber, amberShade), (cream, creamShade)]
for i in 0..<3 {
    let panel = polygon([pt(xs[i], top[i]), pt(xs[i + 1], top[i + 1]), pt(xs[i + 1], bottom[i + 1]), pt(xs[i], bottom[i])])
    fill(panel, panelColors[i].0)
    // A soft shade along the lower edge of each panel keeps the folds readable at small sizes.
    let shade = polygon([pt(xs[i], bottom[i] - 54), pt(xs[i + 1], bottom[i + 1] - 54), pt(xs[i + 1], bottom[i + 1]), pt(xs[i], bottom[i])])
    ctx.saveGState(); ctx.addPath(panel); ctx.clip(); fill(shade, panelColors[i].1); ctx.restoreGState()
}

let mapOutline = polygon([pt(xs[0], top[0]), pt(xs[1], top[1]), pt(xs[2], top[2]), pt(xs[3], top[3]), pt(xs[3], bottom[3]), pt(xs[2], bottom[2]), pt(xs[1], bottom[1]), pt(xs[0], bottom[0])])
ctx.saveGState()
ctx.addPath(mapOutline); ctx.clip()

// Contour hints on the cream panels.
for (cx, cy) in [(190.0, 790.0), (780.0, 760.0)] {
    for r in [46.0, 84.0, 122.0] {
        stroke(CGPath(ellipseIn: CGRect(x: cx - r * 1.25, y: cy - r * 0.75, width: r * 2.5, height: r * 1.5), transform: nil), contour, 7)
    }
}

// Trail winding across all three panels.
let path = CGMutablePath()
path.move(to: pt(96, 884))
path.addCurve(to: pt(372, 760), control1: pt(220, 870), control2: pt(270, 740))
path.addCurve(to: pt(652, 798), control1: pt(470, 780), control2: pt(540, 860))
path.addCurve(to: pt(928, 690), control1: pt(760, 760), control2: pt(820, 690))
ctx.setLineDash(phase: 0, lengths: [30, 24])
stroke(path, trail, 14)
ctx.setLineDash(phase: 0, lengths: [])
ctx.restoreGState()

// Fold lines and the sheet's outline.
for i in 1...2 {
    stroke(polygon([pt(xs[i], top[i]), pt(xs[i], bottom[i])]), ink, 14)
}
stroke(mapOutline, ink, 18)

// Orange location pin on the middle panel.
let pinTip = pt(532, 772)
let pinHead = pt(532, 676)
let pin = CGMutablePath()
pin.move(to: pinTip)
pin.addArc(center: pinHead, radius: 60, startAngle: .pi * 0.78, endAngle: .pi * 0.22, clockwise: false)
pin.closeSubpath()
fill(pin, accent)
stroke(pin, ink, 14)
fill(CGPath(ellipseIn: CGRect(x: pinHead.x - 22, y: pinHead.y - 22, width: 44, height: 44), transform: nil), cream)

let image = ctx.makeImage()!
try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    FileHandle.standardError.write(Data("cannot write \(output.path)\n".utf8)); exit(1)
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { exit(1) }
print("wrote \(output.path) (\(image.width)×\(image.height), alpha: \(image.alphaInfo == .none ? "none" : "\(image.alphaInfo.rawValue)"))")
