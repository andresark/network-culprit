import SwiftUI
import AppKit

/// Native Liquid Glass for controls and status surfaces, with an explicit
/// opaque alternative for macOS's Reduce Transparency accessibility setting.
private struct NetworkGlassSurface<Surface: Shape>: ViewModifier {
    var shape: Surface
    var tint: Color?
    var interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay(shape.stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
        } else {
            content.glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        }
    }
}

extension View {
    func networkGlass<Surface: Shape>(in shape: Surface, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(NetworkGlassSurface(shape: shape, tint: tint, interactive: interactive))
    }
}

struct ConnectionStatusBar: View {
    @Bindable var store: DiagnosticStore

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "network").foregroundStyle(.tint)
                Text(store.pathDescription).lineLimit(1).help(store.pathDescription)
                Spacer(minLength: 16)
                if store.isRunning { ProgressView().controlSize(.mini) }
                Text(store.isRunning ? store.activity : "Read-only diagnostics · saved on this Mac")
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            .font(.caption)
            .padding(.horizontal, 16).padding(.vertical, 11)
            .networkGlass(in: .rect(cornerRadius: 15))
        }
        .padding(.horizontal, 18).padding(.bottom, 12).padding(.top, 6)
    }
}
