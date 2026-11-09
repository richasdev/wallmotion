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
            MediaThumbnail(item: item, localURL: localURL, compact: true)
                .frame(height: 98)
                .overlay(alignment: .topLeading) {
                    Text(kindLabel).font(.caption.weight(.semibold))
                        .foregroundStyle(.white).padding(.horizontal, 9).padding(.vertical, 6)
                        .background(.black.opacity(0.65), in: Capsule()).padding(12)
                }
                .overlay(alignment: .bottomTrailing) {
                    applyButton.padding(9)
                }
            VStack(alignment: .leading, spacing: 8) {
                Text(item.title).font(.headline).lineLimit(1).help(item.title)
                HStack {
                    if case .web(let embed) = item.source { Text(embed.provider == .youtube ? "YouTube" : "Vimeo").font(.caption).foregroundStyle(BrandTheme.secondaryInk(for: colorScheme)) }
                    if case .remote = item.source { Label("URL", systemImage: "link").font(.caption).foregroundStyle(BrandTheme.secondaryInk(for: colorScheme)) }
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

            }
            .padding(10)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(isApplied ? BrandTheme.selection(for: colorScheme) : .clear, lineWidth: contrast == .increased ? 3 : 2))
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
    private var applyButton: some View {
        Button(action: onApply) {
            Label(isApplied ? "Reaplicar" : (appliesToAll ? "Aplicar em todos" : "Aplicar"), systemImage: isApplied ? "checkmark.circle.fill" : "display")
                .font(.caption.weight(.semibold)).foregroundStyle(BrandTheme.graphite)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(BrandTheme.action, in: Capsule())
        }.buttonStyle(.plain).disabled(!canApply)
            .help(applyDisabledReason ?? (appliesToAll ? "Aplicar em todos os monitores" : "Aplicar no monitor selecionado"))
            .accessibilityLabel(isApplied ? "Reaplicar \(item.title)" : "Aplicar \(item.title)")
            .accessibilityHint(Text(applyDisabledReason ?? (appliesToAll ? "Aplica em todos os monitores" : "Aplica apenas no monitor selecionado")))
    }

}
