import SwiftUI
import AppKit
import WallmotionCore

struct WallpaperCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    let item: Wallpaper
    let localURL: URL?
    let isApplied: Bool
    var appliesToAll: Bool = false
    var canApply = true
    let onRename: () -> Void
    let onApply: () -> Void
    let onRemove: () -> Void

    private var kindLabel: String {
        switch item.kind {
        case .image: "FOTO"
        case .gif: "GIF"
        case .video: "VÍDEO"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MediaThumbnail(item: item, localURL: localURL)
                .frame(height: 118).clipShape(RoundedRectangle(cornerRadius: 10))
            Text(item.title).font(.headline).lineLimit(1).help(item.title)
            HStack {
                Text(kindLabel).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if case .web(let embed) = item.source { Text(embed.provider == .youtube ? "YouTube" : "Vimeo").font(.caption).foregroundStyle(.secondary) }
                if case .remote = item.source { Label("URL", systemImage: "link").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(action: onRename) {
                    Image(systemName: "pencil").foregroundStyle(.primary)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                    .buttonStyle(.borderless).help("Renomear título da mídia")
                    .accessibilityLabel("Renomear \(item.title)")
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash").frame(width: 24, height: 24).contentShape(Rectangle())
                }
                    .buttonStyle(.borderless).help("Remover da biblioteca")
                    .accessibilityLabel("Remover \(item.title) da biblioteca")
            }
            Button(action: onApply) {
                Label(isApplied ? "Aplicado · reaplicar" : (appliesToAll ? "Aplicar em todos" : "Aplicar neste monitor"), systemImage: isApplied ? "checkmark.circle.fill" : "display")
                    .frame(maxWidth: .infinity)
            }.buttonStyle(.bordered).disabled(!canApply)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(isApplied ? BrandTheme.selection(for: colorScheme) : .primary.opacity(0.07), lineWidth: isApplied ? (contrast == .increased ? 3 : 2) : 1))
        .contextMenu {
            Button("Renomear…", systemImage: "pencil", action: onRename)
            Button("Remover…", systemImage: "trash", role: .destructive, action: onRemove)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.title)
        .accessibilityValue(isApplied ? "Fundo aplicado" : "Não aplicado no monitor selecionado")
        .accessibilityAddTraits(isApplied ? .isSelected : [])
        .accessibilityAction(named: Text("Renomear"), onRename)
    }
}
