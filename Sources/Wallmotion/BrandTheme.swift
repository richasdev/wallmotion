import SwiftUI

/// Wallmotion 4-tone visual identity palette:
/// 1. Obsidian Black (deep space background)
/// 2. Pure White (geometric typography and monogram)
/// 3. Electric Cyan (kinetic aurora wave)
/// 4. Electric Violet (deep kinetic aurora wave)
enum BrandTheme {
    static let black = Color(red: 10/255, green: 11/255, blue: 16/255)
    static let white = Color.white
    static let cyan = Color(red: 0/255, green: 242/255, blue: 254/255)
    static let violet = Color(red: 127/255, green: 0/255, blue: 255/255)

    /// Dynamic Aurora Linear Gradient (Cyan to Violet)
    static let auroraGradient = LinearGradient(
        colors: [cyan, violet],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Subtle Aurora card accent background
    static let cardBackground = LinearGradient(
        colors: [cyan.opacity(0.18), violet.opacity(0.12)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
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
    }
}
