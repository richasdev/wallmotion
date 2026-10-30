import SwiftUI

/// Fixed vector scenery: no timer, media decode, blur pass or offscreen player.
struct LivingArtwork: View {
    var warm = false

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            ZStack {
                LinearGradient(colors: warm
                    ? [Color(red: 0.22, green: 0.12, blue: 0.38), Color(red: 0.72, green: 0.30, blue: 0.42)]
                    : [Color(red: 0.07, green: 0.12, blue: 0.29), Color(red: 0.22, green: 0.18, blue: 0.48)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(LinearGradient(colors: [.init(red: 1, green: 0.80, blue: 0.64), .init(red: 0.99, green: 0.46, blue: 0.51)], startPoint: .top, endPoint: .bottom))
                    .frame(width: height * 0.55, height: height * 0.55)
                    .position(x: width * 0.77, y: height * 0.39)
                ForEach(0..<5) { layer in
                    Path { path in
                        let baseline = height * (0.45 + Double(layer) * 0.11)
                        path.move(to: CGPoint(x: 0, y: baseline + height * 0.15))
                        path.addCurve(to: CGPoint(x: width, y: baseline - height * 0.1),
                            control1: CGPoint(x: width * 0.38, y: baseline - height * 0.65),
                            control2: CGPoint(x: width * 0.65, y: baseline + height * 0.55))
                        path.addLine(to: CGPoint(x: width, y: height))
                        path.addLine(to: CGPoint(x: 0, y: height))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [
                        Color(red: 0.18 + Double(layer) * 0.025, green: 0.65 - Double(layer) * 0.10, blue: 0.73 - Double(layer) * 0.08),
                        Color(red: 0.18, green: 0.12, blue: 0.34 + Double(layer) * 0.035)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing))
                }
            }
        }
        .clipped()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct LibraryHero: View {
    let count: Int

    var body: some View {
        ZStack(alignment: .leading) {
            LivingArtwork()
            LinearGradient(stops: [.init(color: .black.opacity(0.75), location: 0), .init(color: .black.opacity(0.48), location: 0.48), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing)
            VStack(alignment: .leading, spacing: 10) {
                Text("SEU ESPAÇO. OUTRA ATMOSFERA.")
                    .font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2)
                    .foregroundStyle(BrandTheme.cyan)
                Text("Dê vida à sua tela.")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white).accessibilityAddTraits(.isHeader)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Paisagens que inspiram. Movimento que transforma.")
                    .font(.callout).foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up")
                    Text("\(count) \(count == 1 ? "mídia na sua coleção" : "mídias na sua coleção")")
                }
                .font(.caption.weight(.medium)).foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.black.opacity(0.35), in: Capsule())
            }
            .padding(22)
            .frame(maxWidth: 440, alignment: .leading)
        }
        .frame(minHeight: 178)
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }
}
