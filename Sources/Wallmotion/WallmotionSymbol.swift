import AppKit
import SwiftUI

/// A monitor filled by motion: a compact monochrome counterpart to the full-color icon.
/// Geometry is shared with resources/branding/wallmotion-menubar-template.svg.
struct WallmotionMark: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let scale = side / 22
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
        }
        var path = Path(roundedRect: CGRect(x: origin.x + 2 * scale, y: origin.y + 3.5 * scale,
                                           width: 18 * scale, height: 13 * scale), cornerRadius: 2.5 * scale)
        path.move(to: point(4.5, 11.5))
        path.addCurve(to: point(17.5, 8.5), control1: point(8, 6.8), control2: point(11.5, 15))
        path.move(to: point(11, 16.5))
        path.addLine(to: point(11, 19))
        path.move(to: point(7.5, 19))
        path.addLine(to: point(14.5, 19))
        return path
    }
}

private enum MonitorArtwork {
    static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 255) / 255,
              green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }

    static func gradient(_ colors: [UInt32], from start: CGPoint, to end: CGPoint) -> GraphicsContext.Shading {
        .linearGradient(Gradient(colors: colors.map(color)), startPoint: start, endPoint: end)
    }

    static var stand: Path {
        var path = Path()
        path.move(to: CGPoint(x: 456, y: 690))
        path.addLine(to: CGPoint(x: 568, y: 690))
        path.addLine(to: CGPoint(x: 582, y: 795))
        path.addLine(to: CGPoint(x: 442, y: 795))
        path.closeSubpath()
        return path
    }

    /// Broad filled shapes survive small sizes; no fine-line aurora or letter monogram.
    static func wave(_ layer: Int) -> Path {
        var path = Path()
        switch layer {
        case 0:
            path.move(to: CGPoint(x: 200, y: 440))
            path.addCurve(to: CGPoint(x: 544, y: 418), control1: CGPoint(x: 324, y: 292), control2: CGPoint(x: 438, y: 352))
            path.addCurve(to: CGPoint(x: 824, y: 310), control1: CGPoint(x: 650, y: 484), control2: CGPoint(x: 742, y: 384))
        case 1:
            path.move(to: CGPoint(x: 200, y: 526))
            path.addCurve(to: CGPoint(x: 536, y: 516), control1: CGPoint(x: 326, y: 372), control2: CGPoint(x: 424, y: 462))
            path.addCurve(to: CGPoint(x: 824, y: 416), control1: CGPoint(x: 654, y: 574), control2: CGPoint(x: 752, y: 458))
        default:
            path.move(to: CGPoint(x: 200, y: 622))
            path.addCurve(to: CGPoint(x: 550, y: 592), control1: CGPoint(x: 334, y: 490), control2: CGPoint(x: 438, y: 562))
            path.addCurve(to: CGPoint(x: 824, y: 520), control1: CGPoint(x: 656, y: 620), control2: CGPoint(x: 744, y: 530))
        }
        path.addLine(to: CGPoint(x: 824, y: 672))
        path.addLine(to: CGPoint(x: 200, y: 672))
        path.closeSubpath()
        return path
    }
}

/// Static native vectors only: no image reads, decoding, animation, timers or SVG runtime.
/// Artwork coordinates match wallmotion-icon.svg, excluding the 100px Dock margin.
struct WallmotionBrandIcon: View {
    var size: CGFloat = 28

    var body: some View {
        Canvas { context, dimensions in
            context.scaleBy(x: dimensions.width / 824, y: dimensions.height / 824)
            context.translateBy(x: -100, y: -100)
            let tile = Path(CGRect(x: 100, y: 100, width: 824, height: 824))
            context.fill(tile, with: MonitorArtwork.gradient([0xF0F7F6, 0xDCEBEA, 0xB9D0D1],
                from: CGPoint(x: 100, y: 100), to: CGPoint(x: 924, y: 924)))
            context.fill(MonitorArtwork.stand, with: MonitorArtwork.gradient([0x60777C, 0x2C454E],
                from: CGPoint(x: 512, y: 690), to: CGPoint(x: 512, y: 795)))
            let bezel = MonitorArtwork.gradient([0x46545A, 0x25363E, 0x16262E],
                from: CGPoint(x: 512, y: 238), to: CGPoint(x: 512, y: 708))
            context.fill(Path(roundedRect: CGRect(x: 350, y: 792, width: 324, height: 32), cornerRadius: 16), with: bezel)
            let monitorRect = size <= 16 ? CGRect(x: 160, y: 222, width: 704, height: 486)
                                         : CGRect(x: 176, y: 238, width: 672, height: 470)
            context.fill(Path(roundedRect: monitorRect, cornerRadius: 54), with: bezel)
            let display = Path(roundedRect: CGRect(x: 200, y: 262, width: 624, height: 410), cornerRadius: 32)
            context.drawLayer { screen in
                screen.clip(to: display)
                screen.fill(display, with: MonitorArtwork.gradient([0x0D5266, 0x102D49],
                    from: CGPoint(x: 200, y: 262), to: CGPoint(x: 824, y: 672)))
                let colors: [[UInt32]] = [[0xFFD2A0, 0xFF8C83, 0xDE527A],
                                         [0x9DFFF0, 0x34E0D6, 0x1397AC], [0x1FB6B9, 0x073C63]]
                for layer in 0..<3 {
                    screen.fill(MonitorArtwork.wave(layer), with: MonitorArtwork.gradient(colors[layer],
                        from: CGPoint(x: 200, y: 262), to: CGPoint(x: 824, y: 672)))
                }
            }
            if size > 16 {
                context.stroke(display, with: .color(.white.opacity(0.22)), lineWidth: 2)
                context.fill(Path(roundedRect: CGRect(x: 500, y: 685, width: 24, height: 4), cornerRadius: 2),
                             with: .color(MonitorArtwork.color(0x8DEADD)))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 185 / 824, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Cached alpha-only monitor and wave. macOS supplies the correct light/dark tint.
@MainActor
enum WallmotionMenuIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 22, height: 22), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(1.5)
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
