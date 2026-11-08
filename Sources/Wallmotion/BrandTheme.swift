import SwiftUI

/// Neutral native surfaces let the library's artwork carry the color.
enum BrandTheme {
    static let cyan = Color(red: 98/255, green: 222/255, blue: 206/255)

    /// Enabled instructional text on native glass must retain 4.5:1 contrast.
    static func secondaryInk(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 180/255, green: 180/255, blue: 180/255)
                        : Color(red: 95/255, green: 99/255, blue: 104/255)
    }

    static func selection(for scheme: ColorScheme) -> Color {
        scheme == .dark ? cyan : Color(red: 0/255, green: 103/255, blue: 92/255)
    }
}

/// One glass controls layer, with deterministic accessibility and older-system fallbacks.
/// Wallpaper cards remain opaque: scrolling the collection never multiplies glass surfaces.
struct ScenarioSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    private let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

    func body(content: Content) -> some View {
        Group {
            if reduceTransparency || contrast == .increased {
                content.background(Color(nsColor: .controlBackgroundColor), in: shape)
            } else if #available(macOS 26.0, *) {
                content.glassEffect(.regular, in: shape)
            } else {
                content.background(.regularMaterial, in: shape)
            }
        }
        .overlay {
            if contrast == .increased {
                shape.strokeBorder(.primary.opacity(0.6), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Shared vector identity for the sidebar and application icon.
struct BrandLogoView: View {
    var size: CGFloat = 28
    var body: some View { WallmotionBrandIcon(size: size) }
}
