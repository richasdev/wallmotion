import SwiftUI

struct PhotoQualityDetails: View {
    @Environment(\.colorScheme) private var scheme
    let quality: PhotoQualityInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Foto original: \(quality.sourceWidth) × \(quality.sourceHeight) pixels")
            Text("\(quality.isPanorama ? "Bitmap do panorama" : "Bitmap preparado"): \(quality.bitmapWidth) × \(quality.bitmapHeight) pixels")
            if quality.isPanorama {
                Text("Dimensões do bitmap inteiro, antes do recorte de cada monitor.")
            }
            if quality.isReduced {
                Text("Resolução reduzida para o enquadramento e o limite de memória.")
            }
        }
        .font(.caption2).foregroundStyle(BrandTheme.secondaryInk(for: scheme))
        .fixedSize(horizontal: false, vertical: true)
    }
}
