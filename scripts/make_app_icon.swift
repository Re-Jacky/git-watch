import AppKit

let size = CGFloat(1024)
let image = NSImage(size: NSSize(width: size, height: size))

image.lockFocus()

let rect = NSRect(x: 0, y: 0, width: size, height: size)
let radius = size * 0.225
let background = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
background.addClip()

let gradient = NSGradient(
    starting: NSColor(srgbRed: 0.45, green: 0.72, blue: 1.00, alpha: 1),
    ending: NSColor(srgbRed: 0.10, green: 0.40, blue: 0.88, alpha: 1)
)!
gradient.draw(in: background, angle: -90)

let ring = NSBezierPath()
ring.appendArc(withCenter: CGPoint(x: size * 0.5, y: size * 0.52), radius: size * 0.295, startAngle: 0, endAngle: 360)
ring.lineWidth = size * 0.052
NSColor.white.withAlphaComponent(0.95).setStroke()
ring.stroke()

if let symbol = NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: nil) {
    let sized = NSImage.SymbolConfiguration(pointSize: size * 0.30, weight: .bold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let tinted = symbol.withSymbolConfiguration(sized) {
        let side = size * 0.60
        tinted.draw(
            in: NSRect(x: (size - side) / 2, y: (size - side) / 2 + size * 0.01, width: side, height: side)
        )
    }
}

NSGraphicsContext.current?.restoreGraphicsState()
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("Failed to render app icon")
}

let output = URL(fileURLWithPath: "Resources/AppIcon-1024.png")
try! FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try! png.write(to: output)
print("Wrote \(output.path)")
