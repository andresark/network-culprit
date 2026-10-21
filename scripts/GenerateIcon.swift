import AppKit
import Foundation

let image = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { bounds in
    let outer = NSBezierPath(roundedRect: bounds.insetBy(dx: 28, dy: 28), xRadius: 205, yRadius: 205)
    NSGradient(colors: [NSColor(red: 0.03, green: 0.17, blue: 0.29, alpha: 1), NSColor(red: 0.02, green: 0.59, blue: 0.64, alpha: 1)])?.draw(in: outer, angle: 45)
    let configuration = NSImage.SymbolConfiguration(pointSize: 560, weight: .medium).applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "network", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
        symbol.draw(in: NSRect(x: 222, y: 222, width: 580, height: 580))
    }
    let dot = NSBezierPath(ovalIn: NSRect(x: 730, y: 155, width: 150, height: 150))
    NSColor(red: 0.43, green: 0.98, blue: 0.72, alpha: 1).setFill(); dot.fill()
    return true
}
guard CommandLine.arguments.count > 1, let tiff = image.tiffRepresentation,
      let representation = NSBitmapImageRep(data: tiff), let png = representation.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
