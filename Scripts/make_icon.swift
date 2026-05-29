import AppKit

// GameNest app icon generator — Linear.app aesthetic for gaming.
// Dark glossy squircle, indigo → deep-violet diagonal gradient,
// glassy top reflection, subtle glass edge, and a centered controller glyph.

let canvas: CGFloat = 1024
let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else {
    fatalError("no context")
}

// Geometry: macOS app-icon content square (824pt) centered in the 1024 canvas.
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
let radius: CGFloat = rect.width * 0.2235 // Big Sur squircle-ish

func roundedPath(_ r: CGRect, _ rad: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
}

let bgPath = roundedPath(rect, radius)

// Drop shadow behind the tile.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 46,
              color: NSColor.black.withAlphaComponent(0.45).cgColor)
ctx.addPath(bgPath)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.restoreGState()

// Clip to the tile for everything that follows.
ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()

// Base diagonal gradient: lighter indigo (top-left) → deep violet/near-black (bottom-right).
let space = CGColorSpaceCreateDeviceRGB()
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}
let baseColors = [
    rgb(0.45, 0.47, 0.92),   // #737AEB indigo
    rgb(0.31, 0.30, 0.62),   // #4F4D9E
    rgb(0.11, 0.10, 0.18)    // #1B1A2E deep violet
] as CFArray
let baseGradient = CGGradient(colorsSpace: space, colors: baseColors,
                              locations: [0.0, 0.5, 1.0])!
ctx.drawLinearGradient(baseGradient,
                       start: CGPoint(x: rect.minX, y: rect.maxY),
                       end: CGPoint(x: rect.maxX, y: rect.minY),
                       options: [])

// Glassy top reflection: bright sheen fading downward, clipped to the upper half.
ctx.saveGState()
let sheenRect = CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
let sheen = CGPath(ellipseIn: sheenRect.insetBy(dx: -rect.width * 0.12, dy: -rect.height * 0.18), transform: nil)
ctx.addPath(sheen)
ctx.clip()
let sheenColors = [
    rgb(1, 1, 1, 0.30),
    rgb(1, 1, 1, 0.0)
] as CFArray
let sheenGradient = CGGradient(colorsSpace: space, colors: sheenColors, locations: [0.0, 1.0])!
ctx.drawLinearGradient(sheenGradient,
                       start: CGPoint(x: rect.midX, y: rect.maxY),
                       end: CGPoint(x: rect.midX, y: rect.midY),
                       options: [])
ctx.restoreGState()

// Subtle inner glass edge (1px lighter stroke just inside the border).
ctx.restoreGState()
ctx.saveGState()
let edgePath = roundedPath(rect.insetBy(dx: 2, dy: 2), radius - 2)
ctx.addPath(edgePath)
ctx.setStrokeColor(rgb(1, 1, 1, 0.18))
ctx.setLineWidth(3)
ctx.strokePath()
ctx.restoreGState()

// Controller glyph (SF Symbol), tinted with a white→lavender gradient, centered.
let symbolPoint: CGFloat = 400
let config = NSImage.SymbolConfiguration(pointSize: symbolPoint, weight: .medium)
if let symbol = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let s = symbol.size

    // Build a tinted copy: composite a white→lavender vertical gradient onto the glyph shape.
    let tinted = NSImage(size: s)
    tinted.lockFocus()
    if let tctx = NSGraphicsContext.current?.cgContext {
        symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        tctx.setBlendMode(.sourceAtop)
        let glyphColors = [
            rgb(1, 1, 1, 1),
            rgb(0.86, 0.87, 0.99, 1)
        ] as CFArray
        let glyphGradient = CGGradient(colorsSpace: space, colors: glyphColors, locations: [0, 1])!
        tctx.drawLinearGradient(glyphGradient,
                                start: CGPoint(x: 0, y: s.height),
                                end: CGPoint(x: 0, y: 0),
                                options: [])
    }
    tinted.unlockFocus()

    let glyphRect = CGRect(x: rect.midX - s.width / 2,
                           y: rect.midY - s.height / 2,
                           width: s.width, height: s.height)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 30,
                  color: rgb(0.04, 0.03, 0.10, 0.55))
    tinted.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 1.0)
    ctx.restoreGState()
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("encode failed")
}
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
