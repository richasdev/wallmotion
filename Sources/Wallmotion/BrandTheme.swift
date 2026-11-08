import SwiftUI
import AppKit

/// One coral action hue, graphite navigation and the wallpaper's own colors.
enum BrandTheme {
    static let cyan = Color(red: 98/255, green: 222/255, blue: 206/255)
    static let graphite = Color(red: 47/255, green: 51/255, blue: 52/255)
    static let action = Color(red: 255/255, green: 115/255, blue: 91/255)

    static func secondaryInk(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 200/255, green: 202/255, blue: 204/255)
                        : Color(red: 80/255, green: 84/255, blue: 89/255)
    }

    static func selection(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 255/255, green: 169/255, blue: 148/255) : Color(red: 166/255, green: 46/255, blue: 26/255)
    }
}

/// A single native glass sheet. Collection cards never add glass render passes.
struct ScenarioSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    private let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)

    func body(content: Content) -> some View {
        Group {
            if reduceTransparency || contrast == .increased {
                content.background(Color(nsColor: .windowBackgroundColor), in: shape)
            } else if #available(macOS 26.0, *) {
                content
                    .background(scheme == .dark ? Color.black.opacity(0.1) : Color.white.opacity(0.3))
                    .glassEffect(.regular, in: shape)
            } else {
                content.background(.regularMaterial, in: shape)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(.primary.opacity(contrast == .increased ? 0.7 : 0.12), lineWidth: 1).allowsHitTesting(false))
    }
}

/// Behind-window native material gives the glass a real desktop backdrop. It
/// never decodes wallpaper frames or samples the desktop in an application loop.
struct StudioWindowBackdrop: NSViewRepresentable {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .underWindowBackground
        view.state = .active
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.isHidden = reduceTransparency || contrast == .increased
    }
}

struct BrandLogoView: View {
    var size: CGFloat = 28
    var body: some View { WallmotionBrandIcon(size: size) }
}
