import AppKit
import Testing
@testable import NetworkCulprit

@Test @MainActor func menuBarIconsActuallyRenderColorWithoutTemplateTinting() throws {
    for status in NetworkMenuBarStatus.allCases {
        let image = status.image
        #expect(!image.isTemplate)
        #expect(image.size == NSSize(width: 20, height: 18))
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        var visiblePixels = 0
        var coloredPixels = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 else { continue }
                visiblePixels += 1
                let components = [color.redComponent, color.greenComponent, color.blueComponent]
                if (components.max() ?? 0) - (components.min() ?? 0) > 0.25 { coloredPixels += 1 }
            }
        }
        #expect(visiblePixels > 12, "\(status) must render a visible symbol")
        if status != .unmeasured { #expect(coloredPixels > 12, "\(status) must retain its status color") }
    }
}
