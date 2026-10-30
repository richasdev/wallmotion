import SwiftUI
import WallmotionCore

struct LibraryView: View {
    @Bindable var model: LibraryModel
    @State private var selectedDisplay = ""
    @State private var search = ""
    @State private var showingURL = false
    @State private var isWebSource = false
    @State private var urlText = ""
    @State private var urlError: String?
    @State private var pendingRemoval: Wallpaper?
    @State private var isDropTargeted = false
    @State private var dropMessage = ""

    private var filteredItems: [Wallpaper] {
        model.state.wallpapers.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
    }

    private var targetDisplayName: String {
        model.displays.first(where: { $0.id == selectedDisplay })?.name ?? "Selecione um monitor"
    }

    private var hasAppliedWallpaper: Bool {
        model.displays.contains { model.state.assignments[$0.id] != nil }
    }

    private func appliedWallpaper(on displayID: String) -> Wallpaper? {
        guard let id = model.state.assignments[displayID] else { return nil }
        return model.state.wallpapers.first(where: { $0.id == id })
    }

    private var supportsMediaFit: Bool {
        guard let wallpaper = appliedWallpaper(on: selectedDisplay) else { return false }
        if case .web = wallpaper.source { return false }
        return true
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 290)
        } detail: {
            detail
            .toolbar {
                ToolbarItemGroup {
                    Button { showingURL = true } label: { Label("Adicionar URL", systemImage: "link.badge.plus") }
                        .disabled(!model.canEdit || model.isImporting)
                        .help("Adicionar um link de vídeo à biblioteca")
                    Button { model.chooseFiles() } label: { Label("Importar", systemImage: "plus") }
                        .disabled(!model.canEdit || model.isImporting)
                        .help("Importar fotos, GIFs e vídeos · ⌘O")
                }
            }
            .searchable(text: $search, prompt: "Buscar na biblioteca")
        }
        .onAppear { selectAvailableDisplay() }
        .onChange(of: model.displays) { _, _ in selectAvailableDisplay() }
        .sheet(isPresented: $showingURL) { urlSheet }
        .alert("Wallmotion", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .confirmationDialog("Remover da biblioteca?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }), titleVisibility: .visible) {
            Button("Remover mídia", role: .destructive) {
                if let item = pendingRemoval { model.remove(item) }
                pendingRemoval = nil
            }
        } message: { Text("A cópia importada será apagada e removida dos monitores. Seu arquivo original será preservado.") }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            if let wallpaperID = model.state.assignments[selectedDisplay], supportsMediaFit {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Exibição neste monitor").font(.callout.weight(.semibold))
                    Picker("Exibição neste monitor", selection: Binding(
                        get: { model.state.mediaFit(for: wallpaperID, on: selectedDisplay) },
                        set: { model.setMediaFit($0, on: selectedDisplay) }
                    )) {
                        Text("Ajustar").tag(MediaFit.fit)
                        Text("Preencher").tag(MediaFit.fill)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 320)
                    .disabled(!model.canEdit)
                    Text("Ajustar mostra toda a mídia. Preencher recorta as bordas, sem distorcer. Fotos muito grandes usam resolução reduzida para limitar memória.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            libraryContent
            if model.isImporting { ProgressView("Copiando mídia para a biblioteca…").controlSize(.small) }
        }
        .padding(28)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(isDropTargeted ? Color.accentColor : .clear, lineWidth: 3)
                .padding(6)
                .allowsHitTesting(false)
        }
        .dropDestination(for: URL.self, action: { urls, _ in
            guard !urls.isEmpty, model.canEdit else { return false }
            dropMessage = "Arquivos recebidos. Importando mídia."
            Task { @MainActor in
                await model.importFiles(urls)
                dropMessage = model.errorMessage == nil
                    ? "Importação concluída."
                    : "Importação concluída com arquivos que não puderam ser adicionados."
            }
            return true
        }, isTargeted: { isDropTargeted = $0 })
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Biblioteca de mídia. Solte fotos, GIFs ou vídeos para importar.")
        .overlay(alignment: .bottomLeading) {
            if !dropMessage.isEmpty {
                Text(dropMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
    }

    @ViewBuilder private var libraryContent: some View {
        if !model.canEdit {
            ContentUnavailableView {
                Label("Biblioteca indisponível", systemImage: "externaldrive.badge.exclamationmark")
            } description: {
                Text("O arquivo original foi preservado. Corrija a biblioteca e tente carregá-la novamente.")
            } actions: { Button("Tentar novamente") { model.load() } }
        } else if model.state.wallpapers.isEmpty {
            ContentUnavailableView {
                Label("Seu desktop, em movimento", systemImage: "photo.on.rectangle.angled")
            } description: {
                Text("Importe uma foto, GIF ou vídeo. Ou adicione um link direto de vídeo para começar.")
            } actions: { Button("Importar mídia…") { model.chooseFiles() }.buttonStyle(.borderedProminent) }
        } else if filteredItems.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 16)], spacing: 16) {
                    ForEach(filteredItems) { item in card(for: item) }
                }.padding(.bottom)
            }
        }
    }

    private func card(for item: Wallpaper) -> some View {
        let applied = model.state.assignments[selectedDisplay] == item.id
        return WallpaperCard(item: item, localURL: model.localMediaURL(for: item), isApplied: applied, onApply: {
            model.apply(item, to: selectedDisplay)
        }, onRemove: {
            pendingRemoval = item
        })
        .disabled(!model.canEdit || selectedDisplay.isEmpty)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                BrandLogoView(size: 28)
                Text("Wallmotion").font(.title2.weight(.semibold))
            }.padding(.top, 18).padding(.bottom, 8)
            Text("MONITORES").font(.caption.weight(.semibold)).tracking(1).foregroundStyle(.secondary)
            if model.displays.isEmpty {
                Label("Nenhum monitor disponível", systemImage: "display.trianglebadge.exclamationmark")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.displays) { display in
                Button { selectedDisplay = display.id } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "display").font(.title3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(display.name).font(.callout.weight(.medium)).lineLimit(2)
                            Text(appliedWallpaper(on: display.id)?.title ?? "Fundo do sistema")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if selectedDisplay == display.id {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(12)
                    .background(selectedDisplay == display.id ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(display.name)
                .accessibilityValue(selectedDisplay == display.id ? "Monitor selecionado" : "Monitor disponível")
            }
            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                Label(hasAppliedWallpaper ? model.playbackDescription : "Nenhum fundo aplicado", systemImage: hasAppliedWallpaper ? (model.isPaused ? "pause.circle.fill" : "play.circle.fill") : "display")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(!hasAppliedWallpaper || model.isPaused ? Color.secondary : Color.accentColor)
                Button { model.togglePause() } label: {
                    Label(model.state.settings.isManuallyPaused ? "Retomar" : "Pausar", systemImage: model.state.settings.isManuallyPaused ? "play.fill" : "pause.fill")
                        .frame(maxWidth: .infinity)
                }.disabled(!model.canEdit).help("Controlar a reprodução em todos os monitores")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            Toggle("Pausar em baixo consumo", isOn: Binding(get: { model.state.settings.pauseOnLowPower }, set: { model.setPauseOnLowPower($0) }))
                .font(.caption).disabled(!model.canEdit)
            Text("Áudio desativado · arquivos originais preservados")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(18)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sua biblioteca").font(.largeTitle.weight(.bold))
                Text("\(model.state.wallpapers.count) \(model.state.wallpapers.count == 1 ? "mídia" : "mídias") · fotos, GIFs e vídeos")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    monitorContext
                    Spacer(minLength: 8)
                    restoreSystemButton
                }
                VStack(alignment: .leading, spacing: 12) {
                    monitorContext
                    restoreSystemButton
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            if let error = model.playbackErrors[selectedDisplay] {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Spacer()
                    Button("Tentar novamente") { model.refreshPlayback() }
                }
                .font(.callout).padding(12)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var monitorContext: some View {
        HStack(spacing: 12) {
            Image(systemName: "display").font(.title2).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(targetDisplayName).font(.callout.weight(.semibold)).lineLimit(1)
                Text(appliedWallpaper(on: selectedDisplay).map { "Fundo: \($0.title)" } ?? "Escolha uma mídia para este monitor")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private var restoreSystemButton: some View {
        Button { model.clear(displayID: selectedDisplay) } label: {
            Label("Fundo do sistema", systemImage: "arrow.uturn.backward")
        }
        .disabled(!model.canEdit || model.state.assignments[selectedDisplay] == nil)
        .help("Remover o Wallmotion deste monitor e revelar o fundo do macOS")
    }

    private var urlSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Adicionar vídeo por URL").font(.title2.weight(.semibold))
            Toggle("Fonte web (YouTube ou Vimeo)", isOn: $isWebSource)
                .onChange(of: isWebSource) { _, _ in urlError = nil }
            Text(isWebSource ? "Cole a URL de um vídeo individual público. Autoplay e incorporação dependem do provedor; login e DRM não são suportados." : "Cole um link HTTPS direto de vídeo ou HLS (.m3u8).")
                .foregroundStyle(.secondary)
            TextField(isWebSource ? "https://www.youtube.com/watch?v=…" : "https://exemplo.com/video.mp4", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .onChange(of: urlText) { _, _ in urlError = nil }
                .onSubmit { submitURL() }
            if let urlError { Label(urlError, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red) }
            Text("A conexão com o provedor será feita ao aplicar o wallpaper. Links temporários podem expirar.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancelar") { showingURL = false }.keyboardShortcut(.cancelAction)
                Button("Adicionar") { submitURL() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(28).frame(width: 480)
    }

    private func submitURL() {
        if model.addURL(urlText, web: isWebSource) {
            urlText = ""
            urlError = nil
            showingURL = false
        } else {
            urlError = model.errorMessage
            model.errorMessage = nil
        }
    }

    private func selectAvailableDisplay() {
        if !model.displays.contains(where: { $0.id == selectedDisplay }) { selectedDisplay = model.displays.first?.id ?? "" }
    }
}

struct WallpaperCard: View {
    let item: Wallpaper
    let localURL: URL?
    let isApplied: Bool
    let onApply: () -> Void
    let onRemove: () -> Void

    private var kindLabel: String {
        ["image": "FOTO", "gif": "GIF", "video": "VÍDEO", "web": "WEB"][item.kind.rawValue] ?? item.kind.rawValue.uppercased()
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
                Button(role: .destructive, action: onRemove) { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Remover da biblioteca")
                    .accessibilityLabel("Remover \(item.title) da biblioteca")
            }
            Button(action: onApply) {
                Label(isApplied ? "Aplicado · reaplicar" : "Aplicar neste monitor", systemImage: isApplied ? "checkmark.circle.fill" : "display")
                    .frame(maxWidth: .infinity)
            }.buttonStyle(.bordered)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(isApplied ? BrandTheme.cyan : .primary.opacity(0.07), lineWidth: isApplied ? 1.5 : 1))
    }
}
