import AppKit
import SwiftUI

/// The same rounded W geometry as resources/branding/wallmotion-icon.svg.
/// Coordinates are normalized to the icon tile (100...924), excluding its Dock margin.
struct WallmotionMark: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let scale = side / 824
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + (x - 100) * scale, y: origin.y + (y - 100) * scale)
        }
        var path = Path()
        path.move(to: point(244, 356))
        path.addLine(to: point(342, 636))
        path.addCurve(to: point(404, 642), control1: point(354, 671), control2: point(383, 676))
        path.addLine(to: point(492, 489))
        path.addQuadCurve(to: point(532, 489), control: point(512, 455))
        path.addLine(to: point(620, 642))
        path.addCurve(to: point(682, 636), control1: point(641, 676), control2: point(670, 671))
        path.addLine(to: point(780, 356))
        return path
    }
}

private struct WallmotionHorizon: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 824
        let sy = rect.height / 824
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + (x - 100) * sx, y: rect.minY + (y - 100) * sy)
        }
        var path = Path()
        path.move(to: point(100, 707))
        path.addCurve(to: point(566, 756), control1: point(270, 624), control2: point(381, 809))
        path.addCurve(to: point(924, 673), control1: point(717, 713), control2: point(805, 633))
        path.addLine(to: point(924, 924))
        path.addLine(to: point(100, 924))
        path.closeSubpath()
        return path
    }
}

/// Compact in-app icon. No animated effects, image decoding, shadows or runtime asset loading.
struct WallmotionBrandIcon: View {
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 48/255, green: 55/255, blue: 59/255),
                                    Color(red: 16/255, green: 23/255, blue: 25/255)],
                           startPoint: .top, endPoint: .bottom)
            if size > 16 {
                WallmotionHorizon()
                    .fill(LinearGradient(colors: [Color(red: 56/255, green: 214/255, blue: 207/255),
                                                  Color(red: 22/255, green: 68/255, blue: 79/255)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            WallmotionMark()
                .stroke(.white, style: StrokeStyle(lineWidth: size * (size <= 16 ? 96 : 78) / 824,
                                                   lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 185 / 824, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Cached alpha-only menu bar symbol. AppKit supplies the appropriate light/dark tint.
@MainActor
enum WallmotionMenuIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 22, height: 22), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(22 * 78 / 824)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.addPath(WallmotionMark().path(in: rect).cgPath)
            context.strokePath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Wallmotion"
        return image
    }()
}
