import SwiftUI

/// Neutral native surfaces let the library's artwork carry the color.
enum BrandTheme {
    static let black = Color(red: 16/255, green: 17/255, blue: 18/255)
    static let white = Color.white
    static let cyan = Color(red: 98/255, green: 222/255, blue: 206/255)
    static let violet = Color(red: 98/255, green: 222/255, blue: 206/255)

    static func selection(for scheme: ColorScheme) -> Color {
        scheme == .dark ? cyan : Color(red: 0/255, green: 103/255, blue: 92/255)
    }
}

/// One glass controls layer, with deterministic accessibility and older-system fallbacks.
/// Wallpaper cards remain opaque: scrolling the collection never multiplies glass surfaces.
struct ScenarioSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    private let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

    func body(content: Content) -> some View {
        Group {
            if reduceTransparency || contrast == .increased {
                content.background(Color(nsColor: .controlBackgroundColor), in: shape)
            } else if #available(macOS 26.0, *) {
                content.foregroundStyle(scheme == .dark ? Color.white : Color.black)
                    .glassEffect(.regular, in: shape)
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

/// A compact vector rendition of the Wallmotion App Icon mark
/// featuring the 4-tone palette: Black background, White W, and two Aurora lines.
struct BrandLogoView: View {
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(BrandTheme.black)

            // Minimalist W monogram (occupying top-left)
            Path { path in
                let scale = size / 100.0
                path.move(to: CGPoint(x: 22 * scale, y: 24 * scale))
                path.addLine(to: CGPoint(x: 29 * scale, y: 52 * scale))
                path.addLine(to: CGPoint(x: 36 * scale, y: 35 * scale))
                path.addLine(to: CGPoint(x: 43 * scale, y: 52 * scale))
                path.addLine(to: CGPoint(x: 50 * scale, y: 24 * scale))
            }
            .stroke(BrandTheme.white, style: StrokeStyle(lineWidth: size * 0.035, lineCap: .round, lineJoin: .round))

            // Two flowing aurora lines crossing lower half
            // Line 2: Violet
            Path { path in
                let scale = size / 100.0
                path.move(to: CGPoint(x: 8 * scale, y: 66 * scale))
                path.addCurve(
                    to: CGPoint(x: 92 * scale, y: 62 * scale),
                    control1: CGPoint(x: 38 * scale, y: 56 * scale),
                    control2: CGPoint(x: 68 * scale, y: 72 * scale)
                )
            }
            .stroke(BrandTheme.violet, style: StrokeStyle(lineWidth: size * 0.032, lineCap: .round))

            // Line 1: Cyan
            Path { path in
                let scale = size / 100.0
                path.move(to: CGPoint(x: 8 * scale, y: 58 * scale))
                path.addCurve(
                    to: CGPoint(x: 92 * scale, y: 54 * scale),
                    control1: CGPoint(x: 38 * scale, y: 49 * scale),
                    control2: CGPoint(x: 68 * scale, y: 64 * scale)
                )
            }
            .stroke(BrandTheme.cyan, style: StrokeStyle(lineWidth: size * 0.032, lineCap: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
