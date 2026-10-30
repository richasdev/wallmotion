import SwiftUI
import WallmotionCore

/// Explicit, persistent controls; no previews that create additional media players.
struct BackgroundControls: View {
    let model: LibraryModel
    let selectedDisplay: String
    let supportsMediaFit: Bool
    @State private var showingDetails = false

    private var audioSelection: String {
        guard let id = model.state.settings.audioDisplayID,
              model.displays.contains(where: { $0.id == id }) else { return "" }
        return id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    Label("Organização dos monitores", systemImage: "display.2")
                        .font(.callout.weight(.semibold))
                    Spacer(minLength: 12)
                    displayModePicker
                }
                VStack(alignment: .leading, spacing: 10) {
                    Label("Organização dos monitores", systemImage: "display.2")
                        .font(.callout.weight(.semibold))
                    displayModePicker
                }
            }
            Text(model.state.displayMode == .mirrored
                 ? "A mídia e o enquadramento valem para todos os monitores, inclusive os conectados depois."
                 : "Selecione um monitor na lateral e escolha seu fundo. Suas escolhas individuais ficam salvas.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Opções do fundo", isExpanded: $showingDetails) {
                VStack(alignment: .leading, spacing: 16) {
                    if supportsMediaFit {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Enquadramento").font(.callout.weight(.medium))
                            ViewThatFits(in: .horizontal) {
                                mediaFitPicker.pickerStyle(.segmented).fixedSize(horizontal: true, vertical: false)
                                mediaFitPicker.pickerStyle(.menu)
                            }
                            Text(fitDescription(model.mediaFit(on: selectedDisplay)))
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Fotos muito grandes usam resolução reduzida para limitar memória.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    } else if let id = model.activeWallpaperID(on: selectedDisplay),
                              model.state.wallpapers.contains(where: { $0.id == id && $0.source.isWebEmbed }) {
                        Label("O provedor controla o enquadramento deste vídeo web.", systemImage: "rectangle.inset.filled")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Picker(selection: Binding(
                            get: { audioSelection },
                            set: { model.setAudioDisplayID($0.isEmpty ? nil : $0) }
                        )) {
                            Text("Desativado").tag("")
                            ForEach(Array(model.displays.enumerated()), id: \.element.id) { index, display in
                                Text("\(index + 1) · \(display.name)").tag(display.id)
                            }
                        } label: {
                            Label("Som do fundo", systemImage: audioSelection.isEmpty ? "speaker.slash" : "speaker.wave.2")
                        }.frame(maxWidth: 420, alignment: .leading)
                        Text(audioHelp)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.top, 12)
            }.font(.callout.weight(.medium))
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .top) {
            RoundedRectangle(cornerRadius: 1).fill(BrandTheme.auroraGradient)
                .frame(height: 2).padding(.horizontal, 16).accessibilityHidden(true)
        }
        .disabled(!model.canEdit || selectedDisplay.isEmpty)
    }

    private var mediaFitPicker: some View {
        Picker("Enquadramento", selection: Binding(
            get: { model.mediaFit(on: selectedDisplay) },
            set: { model.setMediaFit($0, on: selectedDisplay) }
        )) {
            ForEach(MediaFit.allCases, id: \.self) { fit in
                Text(fitTitle(fit)).tag(fit)
            }
        }.labelsHidden().accessibilityLabel("Enquadramento do fundo")
    }

    private var displayModePicker: some View {
        Picker("Organização dos monitores", selection: Binding(
            get: { model.state.displayMode },
            set: { model.setDisplayMode($0, sourceDisplayID: selectedDisplay) }
        )) {
            Text("Separado por monitor").tag(DisplayMode.independent)
            Text("Mesmo fundo em todos").tag(DisplayMode.mirrored)
        }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 380)
            .accessibilityLabel("Organização dos monitores")
    }

    private var audioHelp: String {
        if let id = model.state.settings.audioDisplayID,
           !model.displays.contains(where: { $0.id == id }) {
            return "O monitor escolhido para o som está desconectado. O áudio permanece desativado até ele voltar ou você escolher outro."
        }
        return "Somente o vídeo do monitor escolhido pode emitir som. Fotos e GIFs são silenciosos. Vídeos web podem bloquear som automático."
    }

    private func fitTitle(_ fit: MediaFit) -> String {
        switch fit {
        case .fit: "Ajustar"
        case .fill: "Preencher"
        case .center: "Centralizar"
        case .stretch: "Esticar"
        }
    }

    private func fitDescription(_ fit: MediaFit) -> String {
        switch fit {
        case .fit: "Mostra toda a mídia sem distorcer; pode deixar bordas."
        case .fill: "Preenche a tela sem distorcer, recortando as bordas."
        case .center: "Centraliza em tamanho original; o que exceder a tela será recortado."
        case .stretch: "Estica até as bordas da tela; as proporções podem mudar."
        }
    }
}

private extension MediaSource {
    var isWebEmbed: Bool {
        if case .web = self { return true }
        return false
    }
}
