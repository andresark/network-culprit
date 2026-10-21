import AppKit

/// An icon-only menu item. Original (non-template) images preserve status color
/// in the macOS menu bar; distinct symbols also identify states without color.
enum NetworkMenuBarStatus: CaseIterable {
    case healthy, warning, failed, checking, unmeasured

    init(health: Health?, isRunning: Bool) {
        if isRunning { self = .checking; return }
        switch health {
        case .good: self = .healthy
        case .warning: self = .warning
        case .failed: self = .failed
        case .unavailable, nil: self = .unmeasured
        }
    }

    var description: String {
        switch self {
        case .healthy: "Healthy"
        case .warning: "Warning — inspect the latest assessment"
        case .failed: "Network failure detected"
        case .checking: "Checking the network"
        case .unmeasured: "No assessment available"
        }
    }

    @MainActor var color: NSColor {
        switch self {
        case .healthy: .systemGreen
        case .warning: .systemOrange
        case .failed: .systemRed
        case .checking: .systemBlue
        case .unmeasured: .systemGray
        }
    }

    var symbol: String {
        switch self {
        case .healthy: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        case .checking: "arrow.trianglehead.2.clockwise.rotate.90"
        case .unmeasured: "network"
        }
    }

    @MainActor var image: NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
            .applying(.init(paletteColors: [color]))
        let symbolImage = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
            .withSymbolConfiguration(configuration)
        // Use a constant canvas so changing health never shifts other menu items.
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { rect in
            guard let symbolImage else { return false }
            let size = symbolImage.size
            let scale = min(18 / size.width, 16 / size.height)
            let fitted = NSSize(width: size.width * scale, height: size.height * scale)
            symbolImage.draw(in: NSRect(x: (rect.width - fitted.width) / 2,
                                       y: (rect.height - fitted.height) / 2,
                                       width: fitted.width, height: fitted.height))
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Network Culprit: \(description)"
        return image
    }
}
