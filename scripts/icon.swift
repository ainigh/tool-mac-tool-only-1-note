// Draws the app's icon at every size an .iconset needs: swift scripts/icon.swift <folder>.iconset
import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments[1])

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    // The tile: a warm gradient, Big Sur's rounded square.
    let tile = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let path = NSBezierPath(roundedRect: tile, xRadius: s * 0.18, yRadius: s * 0.18)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = s * 0.03
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.set()
    NSGradient(starting: NSColor(srgbRed: 1.0, green: 0.84, blue: 0.42, alpha: 1),
               ending: NSColor(srgbRed: 0.96, green: 0.56, blue: 0.20, alpha: 1))!.draw(in: path, angle: -90)
    NSShadow().set()
    // The sheet.
    let sheet = NSRect(x: s * 0.27, y: s * 0.22, width: s * 0.46, height: s * 0.56)
    let corner = s * 0.11
    let page = NSBezierPath()
    page.move(to: NSPoint(x: sheet.minX, y: sheet.minY))
    page.line(to: NSPoint(x: sheet.maxX, y: sheet.minY))
    page.line(to: NSPoint(x: sheet.maxX, y: sheet.maxY - corner))
    page.line(to: NSPoint(x: sheet.maxX - corner, y: sheet.maxY))
    page.line(to: NSPoint(x: sheet.minX, y: sheet.maxY))
    page.close()
    NSColor(srgbRed: 1, green: 0.99, blue: 0.96, alpha: 1).setFill()
    page.fill()
    let fold = NSBezierPath()
    fold.move(to: NSPoint(x: sheet.maxX, y: sheet.maxY - corner))
    fold.line(to: NSPoint(x: sheet.maxX - corner, y: sheet.maxY - corner))
    fold.line(to: NSPoint(x: sheet.maxX - corner, y: sheet.maxY))
    fold.close()
    NSColor(srgbRed: 0.93, green: 0.86, blue: 0.74, alpha: 1).setFill()
    fold.fill()
    // A title and three lines, the last short.
    let ink = NSColor(srgbRed: 0.36, green: 0.27, blue: 0.18, alpha: 1)
    let x = sheet.minX + s * 0.06
    let widths: [CGFloat] = [0.22, 0.32, 0.32, 0.2]
    for (i, w) in widths.enumerated() {
        let h = i == 0 ? s * 0.04 : s * 0.022
        let y = sheet.maxY - s * 0.13 - CGFloat(i) * s * 0.085 - (i == 0 ? 0 : s * 0.02)
        (i == 0 ? ink : ink.withAlphaComponent(0.45)).setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: s * w, height: h), xRadius: h / 2, yRadius: h / 2).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! draw(size).write(to: folder.appendingPathComponent("icon_\(size)x\(size).png"))
    try! draw(size * 2).write(to: folder.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
