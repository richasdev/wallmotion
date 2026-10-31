import SwiftUI
import WallmotionCore

/// Explicit, persistent controls; no previews that create additional media players.
@MainActor
struct BackgroundControls: View {
    let model: LibraryModel
    let selectedDisplay: String
    let supportsMediaFit: Bool
    @State private var showingDetails = false
    @State private var draftVolume: Double
    @State private var isEditingVolume = false
    @State private var volumeDirty = false

    private struct VolumeEdit: Hashable {
        let value: Double
        let editing: Bool
        let dirty: Bool
    }

    init(model: LibraryModel, selectedDisplay: String, supportsMediaFit: Bool) {
        self.model = model
        self.selectedDisplay = selectedDisplay
        self.supportsMediaFit = supportsMediaFit
        _draftVolume = State(initialValue: model.state.settings.audioVolume)
    }

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
            Text(model.state.displayMode == .spanned
                 ? (model.state.mirroredWallpaperID == nil
                    ? "Escolha uma foto ou GIF local na biblioteca para preencher o panorama. Espaços entre monitores também fazem parte dele."
                    : "A foto ou animação atravessa a disposição das telas. Espaços entre monitores também fazem parte do panorama.")
                 : model.state.displayMode == .mirrored
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
                            if let quality = model.photoQuality(on: selectedDisplay) {
                                PhotoQualityDetails(quality: quality)
                            } else {
                                Text("Fotos muito grandes usam resolução reduzida para limitar memória.")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    } else if let id = model.activeWallpaperID(on: selectedDisplay),
                              model.state.wallpapers.contains(where: { $0.id == id && $0.source.isWebEmbed }) {
                        Label("O provedor controla o enquadramento deste vídeo web.", systemImage: "rectangle.inset.filled")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Qualidade de links HLS", selection: Binding(
                            get: { model.state.settings.hlsResolution },
                            set: { model.setHLSResolution($0) }
                        )) {
                            Text("Automática · sem limite preferido").tag(HLSResolution.automatic)
                            Text("HD · 1280 × 720").tag(HLSResolution.hd720)
                            Text("Full HD · 1920 × 1080").tag(HLSResolution.fullHD1080)
                            Text("4K · 3840 × 2160").tag(HLSResolution.uhd2160)
                        }.frame(maxWidth: 420, alignment: .leading)
                        Text("Preferência para transmissões HLS no player nativo; o servidor e o macOS definem a resolução disponível. YouTube, Vimeo e arquivos locais mantêm suas próprias regras de qualidade.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
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
                        HStack(spacing: 12) {
                            Slider(value: Binding(get: { draftVolume }, set: {
                                draftVolume = $0
                                volumeDirty = true
                            }), in: 0...1, step: 0.01, onEditingChanged: { isEditingVolume = $0 }) {
                                Text("Volume geral")
                            }
                            .accessibilityValue("\(Int((draftVolume * 100).rounded())) por cento")
                            Text("\(Int((draftVolume * 100).rounded()))%")
                                .font(.caption.monospacedDigit()).frame(minWidth: 34, alignment: .trailing)
                        }
                        .frame(maxWidth: 420)
                        .disabled(audioSelection.isEmpty)
                        Text(audioHelp)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let item = model.audioWallpaper(on: selectedDisplay) {
                            SourceAudioControls(model: model, wallpaperID: item.id)
                                .id(item.id)
                        }
                    }
                }.padding(.top, 12)
            }.font(.callout.weight(.medium))
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.1), lineWidth: 1))
        .overlay(alignment: .top) {
            RoundedRectangle(cornerRadius: 1).fill(BrandTheme.auroraGradient)
                .frame(height: 2).padding(.horizontal, 16).accessibilityHidden(true)
        }
        .disabled(!model.canEdit || selectedDisplay.isEmpty)
        .onChange(of: model.state.settings.audioVolume) { _, value in
            // A newer menu/external preference takes precedence over an older slider draft.
            isEditingVolume = false
            volumeDirty = false
            draftVolume = value
        }
        .onChange(of: audioSelection) { _, _ in
            isEditingVolume = false
            saveVolume()
        }
        .onChange(of: model.canEdit) { _, editable in
            if !editable {
                isEditingVolume = false
                volumeDirty = false
                draftVolume = model.state.settings.audioVolume
            }
        }
        .task(id: VolumeEdit(value: draftVolume, editing: isEditingVolume, dirty: volumeDirty)) {
            guard volumeDirty, !isEditingVolume else { return }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard !Task.isCancelled else { return }
            saveVolume()
        }
        .onDisappear { saveVolume() }
    }

    private func saveVolume() {
        guard volumeDirty else { return }
        volumeDirty = false
        model.setAudioVolume(draftVolume)
        draftVolume = model.state.settings.audioVolume
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
            .accessibilityValue(fitTitle(model.mediaFit(on: selectedDisplay)))
            .accessibilityHint(Text(fitDescription(model.mediaFit(on: selectedDisplay))))
    }

    private var displayModePicker: some View {
        ViewThatFits(in: .horizontal) {
            displayModeOptions.pickerStyle(.segmented).fixedSize(horizontal: true, vertical: false)
            displayModeOptions.pickerStyle(.menu)
        }.frame(maxWidth: 380)
    }

    private var displayModeOptions: some View {
        Picker("Organização dos monitores", selection: Binding(
            get: { model.state.displayMode },
            set: { model.setDisplayMode($0, sourceDisplayID: selectedDisplay) }
        )) {
            Text("Separado por monitor").tag(DisplayMode.independent)
            Text("Mesmo fundo em todos").tag(DisplayMode.mirrored)
            Text("Panorâmico").tag(DisplayMode.spanned)
        }.labelsHidden().accessibilityLabel("Organização dos monitores")
            .accessibilityHint("No modo separado, cada monitor mantém sua escolha de fundo.")
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
        if model.state.displayMode == .spanned {
            return switch fit {
            case .fit: "Mostra a foto inteira no conjunto das telas, com bordas quando necessário."
            case .fill: "Preenche o conjunto das telas sem distorcer, recortando as bordas da foto."
            case .center: "Centraliza no conjunto das telas usando a maior escala de pixels conectada como referência."
            case .stretch: "Estica a foto até as bordas do conjunto das telas; as proporções podem mudar."
            }
        }
        return switch fit {
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


/// Identity is the library item, so a disappearing slider can only commit its
/// own source's draft even if the selected monitor has already changed media.
@MainActor
struct SourceAudioControls: View {
    let model: LibraryModel
    let wallpaperID: UUID
    @State private var draft: Double
    @State private var editing = false
    @State private var dirty = false
    private struct Edit: Hashable { let value: Double; let editing: Bool; let dirty: Bool }

    init(model: LibraryModel, wallpaperID: UUID) {
        self.model = model;self.wallpaperID = wallpaperID
        _draft = State(initialValue: model.state.audioGain(for: wallpaperID))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Volume deste fundo").font(.callout.weight(.medium))
                Spacer()
                Button("Restaurar 100%") { dirty = false;editing = false;model.setAudioGain(1, for: wallpaperID);draft = model.state.audioGain(for: wallpaperID) }
                    .font(.caption).disabled(draft == 1)
            }
            HStack(spacing: 12) {
                Slider(value: Binding(get: { draft }, set: { draft = $0;dirty = true }), in: 0...1, step: 0.01,
                    onEditingChanged: { editing = $0 }) { Text("Volume deste fundo") }
                    .labelsHidden()
                    .accessibilityValue("\(Int((draft * 100).rounded())) por cento")
                    .accessibilityHint("Este ajuste é salvo para o fundo e combina com o volume geral.")
                Text("\(Int((draft * 100).rounded()))%")
                    .font(.caption.monospacedDigit()).frame(minWidth: 34, alignment: .trailing)
            }
            Text("Ajuste salvo para este item em qualquer monitor. Saída com o volume geral: \(Int((draft * model.state.settings.audioVolume * 100).rounded()))%.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 420)
        .disabled(!model.canEdit)
        .onChange(of: model.state.audioGain(for: wallpaperID)) { _, value in
            editing = false;dirty = false;draft = value
        }
        .onChange(of: model.canEdit) { _, editable in
            if !editable { editing = false;dirty = false;draft = model.state.audioGain(for: wallpaperID) }
        }
        .task(id: Edit(value: draft, editing: editing, dirty: dirty)) {
            guard dirty, !editing else { return }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard !Task.isCancelled else { return }
            save()
        }
        .onDisappear { save() }
    }

    private func save() {
        guard dirty else { return }
        dirty = false
        model.setAudioGain(draft, for: wallpaperID)
        draft = model.state.audioGain(for: wallpaperID)
    }
}
