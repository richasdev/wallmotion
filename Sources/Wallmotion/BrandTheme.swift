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
        scheme == .dark ? Color(red: 255/255, green: 196/255, blue: 181/255) : Color(red: 166/255, green: 46/255, blue: 26/255)
    }
}

/// One continuous frosted window, including the native titlebar region. All
/// backgrounds share the system window's contour; no separately rounded panels
/// create another silhouette. Cards never add glass render passes.
struct ScenarioSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content.background {
            Group {
                if reduceTransparency || contrast == .increased {
                    Color(nsColor: .windowBackgroundColor)
                } else if #available(macOS 26.0, *) {
                    Rectangle()
                        .fill(scheme == .dark ? Color.black.opacity(0.28) : Color.white.opacity(0.5))
                        .glassEffect(.regular, in: Rectangle())
                } else {
                    StudioWindowBackdrop()
                        .overlay(scheme == .dark ? Color.black.opacity(0.28) : Color.white.opacity(0.5))
                }
            }
            .overlay {
                if contrast == .increased {
                    Rectangle().strokeBorder(.primary.opacity(0.7), lineWidth: 1).allowsHitTesting(false)
                }
            }
            .ignoresSafeArea()
        }
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
        view.state = .followsWindowActiveState
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
