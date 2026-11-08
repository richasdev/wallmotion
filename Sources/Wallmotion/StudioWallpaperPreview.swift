import SwiftUI
import WallmotionCore

/// A cached still image, never an additional playback surface.
struct StudioWallpaperPreview: View {
    let item: Wallpaper?
    let localURL: URL?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 15).fill(BrandTheme.graphite)
            if let item {
                MediaThumbnail(item: item, localURL: localURL)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(5)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "display").font(.system(size: 32, weight: .light)).foregroundStyle(BrandTheme.cyan)
                    Text("Escolha seu próximo fundo").font(.caption).foregroundStyle(.white)
                }.padding(16)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if item != nil {
                Text("Miniatura da mídia").font(.caption2.weight(.medium))
                    .foregroundStyle(.white).padding(.horizontal, 7).padding(.vertical, 4)
                    .background(.black.opacity(0.7), in: Capsule()).padding(10)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.map { "Miniatura de \($0.title). O enquadramento é aplicado no desktop." } ?? "Nenhum fundo aplicado")
    }
}
