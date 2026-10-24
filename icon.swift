import AppKit
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1) }
let orange = rgb(215, 119, 87), amber = rgb(246, 178, 96), ember = rgb(92, 30, 18)
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
func squircle(_ r: NSRect, _ radius: CGFloat) -> NSBezierPath { NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius) }
func glow(_ color: NSColor, _ blur: CGFloat) { let s = NSShadow(); s.shadowColor = color; s.shadowBlurRadius = blur; s.set() }

func spark(_ center: NSPoint, turn: CGFloat = 0) -> NSBezierPath {
    let path = NSBezierPath()
    for i in 0..<6 {
        let petal = squircle(NSRect(x: -32, y: 0, width: 64, height: 190), 32)
        var t = AffineTransform(translationByX: center.x, byY: center.y); t.rotate(byRadians: CGFloat(i) * .pi / 3 + turn); petal.transform(using: t); path.append(petal)
    }
    return path
}

func innerShadow(_ shape: NSBezierPath, _ color: NSColor, blur: CGFloat, dy: CGFloat) {
    NSGraphicsContext.saveGraphicsState(); shape.addClip()
    let s = NSShadow(); s.shadowColor = color; s.shadowBlurRadius = blur; s.shadowOffset = .init(width: 0, height: dy); s.set()
    let ring = NSBezierPath(rect: shape.bounds.insetBy(dx: -300, dy: -300)); ring.append(shape.reversed)
    NSColor.black.setFill(); ring.fill()
    NSGraphicsContext.restoreGraphicsState()
}

func draw() {
    NSGraphicsContext.saveGraphicsState()
    let drop = NSShadow(); drop.shadowColor = .init(white: 0, alpha: 0.35); drop.shadowBlurRadius = 20; drop.shadowOffset = .init(width: 0, height: -10); drop.set()
    NSColor.black.setFill(); squircle(body, 185).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState(); squircle(body, 185).addClip()
    NSGradient(starting: NSColor(white: 0.11, alpha: 1), ending: NSColor(white: 0.05, alpha: 1))!.draw(in: body, angle: -90)
    NSGradient(colors: [rgb(150, 52, 30).withAlphaComponent(0.45), ember.withAlphaComponent(0.45), rgb(20, 8, 6).withAlphaComponent(0.45), .clear], atLocations: [0, 0.3, 0.7, 1], colorSpace: .sRGB)!
        .draw(fromCenter: NSPoint(x: body.midX, y: body.minY - 40), radius: 0, toCenter: NSPoint(x: body.midX, y: body.minY - 40), radius: body.height * 1.05, options: [])
    NSGraphicsContext.restoreGraphicsState()
    let center = NSPoint(x: 400, y: 540), cursor = NSRect(x: 620, y: 340, width: 190, height: 56)
    for (i, alpha) in [(2, 0.18), (1, 0.38)] as [(CGFloat, CGFloat)] {
        orange.withAlphaComponent(alpha).setFill(); spark(center, turn: -i * 0.22).fill()
    }
    let petals = spark(center).cgPath, s = NSBezierPath(cgPath: petals.union(petals))
    NSGraphicsContext.saveGraphicsState(); glow(orange.withAlphaComponent(0.5), 40); orange.setFill(); s.fill(); NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [rgb(255, 214, 150), amber, orange, rgb(190, 84, 56)])!.draw(in: s, angle: -60)
    innerShadow(s, rgb(90, 20, 10).withAlphaComponent(0.35), blur: 18, dy: 8)
    innerShadow(s, NSColor(white: 1, alpha: 0.35), blur: 8, dy: -5)
    NSGraphicsContext.saveGraphicsState(); glow(orange.withAlphaComponent(0.45), 32); amber.setFill(); cursor.fill(); NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [rgb(255, 214, 140), amber, rgb(226, 132, 70)])!.draw(in: cursor, angle: -90)
    NSGradient(starting: amber.withAlphaComponent(0.12), ending: amber.withAlphaComponent(0))!.draw(in: NSRect(x: cursor.minX, y: cursor.minY - 70, width: cursor.width, height: 62), angle: -90)
    NSGraphicsContext.saveGraphicsState(); squircle(body, 185).addClip()
    let ring = NSBezierPath(rect: body.insetBy(dx: -10, dy: -10)); ring.append(squircle(body.insetBy(dx: 4, dy: 4), 181).reversed); ring.addClip()
    NSGradient(starting: NSColor(white: 0.4, alpha: 1), ending: NSColor(white: 0.2, alpha: 1))!.draw(in: body, angle: -90)
    NSGradient(colors: [NSColor(white: 1, alpha: 0), NSColor(white: 1, alpha: 0.7), NSColor(white: 1, alpha: 0)])!.draw(in: NSRect(x: body.minX + 185, y: body.maxY - 5, width: body.width - 370, height: 5), angle: 0)
    NSGraphicsContext.restoreGraphicsState()
    innerShadow(squircle(body.insetBy(dx: 5, dy: 5), 180), NSColor(white: 1, alpha: 0.10), blur: 6, dy: -3)
}

func bitmap(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    return rep
}
let full = bitmap(1024); draw()
let dir = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let rep = bitmap(points * scale)
        NSGraphicsContext.current!.imageInterpolation = .high
        full.draw(in: NSRect(x: 0, y: 0, width: points * scale, height: points * scale), from: .zero, operation: .copy, fraction: 1, respectFlipped: false, hints: nil)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dir)/icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"))
    }
}
