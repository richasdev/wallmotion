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
    var applyDisabledReason: String?
    let onRename: () -> Void
    let onApply: () -> Void
    let onRemove: () -> Void

    private var kindLabel: String {
        switch item.kind {
        case .image: "Foto"
        case .gif: "GIF"
        case .video: "Vídeo"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MediaThumbnail(item: item, localURL: localURL)
                .frame(height: 88)
                .overlay(alignment: .topLeading) {
                    Text(kindLabel).font(.caption.weight(.semibold))
                        .foregroundStyle(.white).padding(.horizontal, 9).padding(.vertical, 6)
                        .background(.black.opacity(0.65), in: Capsule()).padding(12)
                }
                .overlay(alignment: .bottomTrailing) {
                    if isApplied {
                        Label("Em cena", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(.white)
                            .padding(8).background(.black.opacity(0.75), in: Capsule()).padding(10)
                    }
                }
            VStack(alignment: .leading, spacing: 8) {
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
                }.buttonStyle(.borderedProminent).tint(BrandTheme.action).foregroundStyle(BrandTheme.graphite).disabled(!canApply)
                    .help(applyDisabledReason ?? "Aplicar este fundo com a organização de monitores selecionada")
                    .accessibilityHint(Text(applyDisabledReason ?? "Aplica o fundo com a organização de monitores selecionada"))
            }
            .padding(10)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(isApplied ? BrandTheme.selection(for: colorScheme) : .primary.opacity(0.07), lineWidth: isApplied ? (contrast == .increased ? 3 : 2) : 1))
        .clipShape(RoundedRectangle(cornerRadius: 18))
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
