import SwiftUI
import WallmotionCore

/// Explicit, persistent controls; no previews that create additional media players.
@MainActor
struct BackgroundControls: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize
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

    init(model: LibraryModel, selectedDisplay: String, supportsMediaFit: Bool, initialDetails: Bool = false) {
        self.model = model
        self.selectedDisplay = selectedDisplay
        self.supportsMediaFit = supportsMediaFit
        _showingDetails = State(initialValue: initialDetails)
        _draftVolume = State(initialValue: model.state.settings.audioVolume)
    }

    private var audioSelection: String {
        guard let id = model.state.settings.audioDisplayID,
              model.displays.contains(where: { $0.id == id }) else { return "" }
        return id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            framingSettings
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { soundButton; volumeSlider.frame(minWidth: 80, maxWidth: .infinity) }
                VStack(alignment: .leading, spacing: 8) { soundButton; volumeSlider }
            }
            Text(audioSummary).font(.caption).foregroundStyle(BrandTheme.secondaryInk(for: scheme))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                audioMonitorMenu
                Spacer(minLength: 8)
                detailsButton
            }
            if showingDetails { advancedSettings }
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

    private var framingSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Enquadramento").font(.callout.weight(.semibold))
                Spacer(minLength: 8)
                if model.state.displayMode.isShared { Text("Todas as telas").font(.caption) }
            }
            if supportsMediaFit {
                if typeSize.isAccessibilitySize {
                    Picker("Enquadramento", selection: Binding(get: { model.mediaFit(on: selectedDisplay) }, set: { model.setMediaFit($0, on: selectedDisplay) })) {
                        ForEach(MediaFit.allCases, id: \.self) { fit in Text(fitTitle(fit)).tag(fit) }
                    }.pickerStyle(.menu)
                } else {
                HStack(spacing: 6) {
                    ForEach(MediaFit.allCases, id: \.self) { fit in
                        Button { model.setMediaFit(fit, on: selectedDisplay) } label: {
                            VStack(spacing: 4) {
                                Image(systemName: fitSymbol(fit)).font(.system(size: 17, weight: .regular)).frame(height: 20)
                                Text(fitTitle(fit)).font(.caption2.weight(.medium)).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 7)
                            .foregroundStyle(model.mediaFit(on: selectedDisplay) == fit ? BrandTheme.selection(for: scheme) : .primary)
                            .background(model.mediaFit(on: selectedDisplay) == fit ? BrandTheme.action.opacity(0.13) : Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
                            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(model.mediaFit(on: selectedDisplay) == fit ? BrandTheme.selection(for: scheme) : .clear, lineWidth: 1.5))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain).help(fitDescription(fit))
                            .accessibilityLabel("Enquadramento: \(fitTitle(fit))")
                            .accessibilityHint(fitDescription(fit))
                            .accessibilityAddTraits(model.mediaFit(on: selectedDisplay) == fit ? .isSelected : [])
                    }
                }
                }
                Text(compactFitDescription).font(.caption).foregroundStyle(BrandTheme.secondaryInk(for: scheme))
            } else {
                Text(model.activeWallpaperID(on: selectedDisplay) == nil ? "Aplique uma mídia da coleção abaixo." : "O provedor controla o enquadramento.")
                    .font(.caption).foregroundStyle(BrandTheme.secondaryInk(for: scheme)).frame(minHeight: 56, alignment: .leading)
            }
        }
    }

    private func fitSymbol(_ fit: MediaFit) -> String {
        switch fit {
        case .fit: "arrow.down.right.and.arrow.up.left"
        case .fill: "arrow.up.left.and.arrow.down.right"
        case .center: "scope"
        case .stretch: "arrow.left.and.right"
        }
    }

    private var audioMonitorMenu: some View {
        Menu {
            Button("Silenciar todos os fundos", systemImage: "speaker.slash") { model.setAudioDisplayID(nil) }
            ForEach(Array(model.displays.enumerated()), id: \.element.id) { index, display in
                Button {
                    model.setAudioEnabled(true, on: display.id)
                } label: {
                    Label("\(index + 1) · \(display.name)", systemImage: model.state.settings.audioDisplayID == display.id ? "checkmark" : "display")
                }.disabled(model.audioWallpaper(on: display.id) == nil)
            }
        } label: {
            Label("Saída de som", systemImage: "display.speaker").font(.caption)
        }.menuStyle(.borderlessButton).fixedSize().tint(BrandTheme.selection(for: scheme)).foregroundStyle(BrandTheme.selection(for: scheme)).help("Escolher o único monitor que pode emitir som")
    }

    private var compactFitDescription: String {
        if model.state.displayMode == .spanned { return "Ajuste aplicado ao conjunto das telas." }
        return switch model.mediaFit(on: selectedDisplay) {
        case .fit: "Mídia inteira, sem distorção."
        case .fill: "Preenche sem distorcer."
        case .center: "Tamanho original, ao centro."
        case .stretch: "Ocupa a tela; pode distorcer."
        }
    }

    private var detailsButton: some View {
        Button("Detalhes", systemImage: "slider.horizontal.3") { showingDetails.toggle() }
            .labelStyle(.titleAndIcon).buttonStyle(.borderless).font(.caption).foregroundStyle(BrandTheme.selection(for: scheme))
            .accessibilityLabel("Detalhes: qualidade e opções de som")
            .accessibilityValue(showingDetails ? "Expandido" : "Recolhido")
            .help("Escolher monitor do som, qualidade HLS e volume por fundo")
    }

    private var advancedSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Somente este monitor emite som", selection: Binding(
                get: { audioSelection },
                set: { model.setAudioDisplayID($0.isEmpty ? nil : $0) }
            )) {
                Text("Desativado").tag("")
                ForEach(Array(model.displays.enumerated()), id: \.element.id) { index, display in
                    Text("\(index + 1) · \(display.name)").tag(display.id)
                }
            }
            Text(audioHelp).font(.caption).foregroundStyle(BrandTheme.secondaryInk(for: scheme))
                .fixedSize(horizontal: false, vertical: true)
            if let owner = model.state.settings.audioDisplayID,
               model.displays.contains(where: { $0.id == owner }),
               let item = model.audioWallpaper(on: owner) {
                SourceAudioControls(model: model, wallpaperID: item.id).id(item.id)
            }
            Picker("Qualidade de links HLS", selection: Binding(
                get: { model.state.settings.hlsResolution },
                set: { model.setHLSResolution($0) }
            )) {
                Text("Automática").tag(HLSResolution.automatic)
                Text("HD · 1280 × 720").tag(HLSResolution.hd720)
                Text("Full HD · 1920 × 1080").tag(HLSResolution.fullHD1080)
                Text("4K · 3840 × 2160").tag(HLSResolution.uhd2160)
            }
            Text("Preferência para links HLS. O servidor e o macOS definem a resolução disponível; arquivos locais e vídeos web mantêm suas próprias regras.")
                .font(.caption).foregroundStyle(BrandTheme.secondaryInk(for: scheme))
                .fixedSize(horizontal: false, vertical: true)
            if let quality = model.photoQuality(on: selectedDisplay) {
                PhotoQualityDetails(quality: quality)
            }
        }.padding(.top, 12)
    }

    private var soundButton: some View {
        let enabled = model.state.settings.audioDisplayID == selectedDisplay
        return Button {
            model.setAudioEnabled(!enabled, on: selectedDisplay)
        } label: {
            Label(enabled ? "Silenciar" : "Ativar som aqui", systemImage: enabled ? "speaker.wave.2.fill" : "speaker.slash")
                .font(.caption.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 7)
                .foregroundStyle(enabled ? BrandTheme.graphite : Color.primary)
                .background(enabled ? BrandTheme.action : Color.primary.opacity(0.06), in: Capsule())
                .contentShape(Capsule())
        }.buttonStyle(.plain)
            .disabled(!enabled && model.audioWallpaper(on: selectedDisplay) == nil)
            .accessibilityHint("O som é exclusivo de um monitor. Ativar aqui transfere o som para a tela selecionada e preserva o volume.")
            .help(enabled ? "Silenciar o monitor selecionado" : "Transferir a saída de som para o monitor selecionado")
    }

    private var volumeSlider: some View {
        HStack(spacing: 10) {
            Slider(value: Binding(get: { draftVolume }, set: {
                draftVolume = $0
                volumeDirty = true
            }), in: 0...1, step: 0.01, onEditingChanged: { isEditingVolume = $0 }) {
                Text("Volume geral")
            }
            .labelsHidden()
            .accessibilityValue("\(Int((draftVolume * 100).rounded())) por cento")
            Text("\(Int((draftVolume * 100).rounded()))%")
                .font(.caption.monospacedDigit()).frame(minWidth: 36, alignment: .trailing)
        }.disabled(audioSelection.isEmpty)
    }

    private var audioSummary: String {
        guard let owner = model.state.settings.audioDisplayID else {
            return model.audioWallpaper(on: selectedDisplay) == nil
                ? "Fotos e GIFs são silenciosos."
                : "Som desativado em todos os monitores."
        }
        guard let display = model.displays.first(where: { $0.id == owner }) else {
            return "Monitor de som desconectado. Nenhum fundo emite som."
        }
        guard let item = model.audioWallpaper(on: owner) else {
            return "Som permitido em \(display.name). Fotos e GIFs são silenciosos."
        }
        if model.state.settings.audioVolume == 0 || model.state.audioGain(for: item.id) == 0 {
            return "Volume em zero · \(display.name)."
        }
        if model.isPaused { return "Reprodução pausada · som permitido em \(display.name)." }
        return "Som permitido em \(display.name). Vídeos web podem exigir interação."
    }

    private func saveVolume() {
        guard volumeDirty else { return }
        volumeDirty = false
        model.setAudioVolume(draftVolume)
        draftVolume = model.state.settings.audioVolume
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
            case .fit: "Mostra a mídia inteira no conjunto das telas, com bordas quando necessário."
            case .fill: "Preenche o conjunto das telas sem distorcer, recortando as bordas da mídia."
            case .center: "Centraliza no conjunto das telas usando a maior escala de pixels conectada como referência."
            case .stretch: "Estica a mídia até as bordas do conjunto das telas; as proporções podem mudar."
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
    @Environment(\.colorScheme) private var scheme
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
                .font(.caption).foregroundStyle(BrandTheme.secondaryInk(for: scheme)).fixedSize(horizontal: false, vertical: true)
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
