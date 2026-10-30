import SwiftUI
import AppKit
import WallmotionCore

struct LibraryView: View {
    @Bindable var model: LibraryModel
    @State private var selectedDisplay = ""
    @State private var search = ""
    @State private var mediaFilter = LibraryMediaFilter.all
    @State private var sortOrder = LibrarySortOrder.recent
    @State private var catalog = LibraryCatalogProjection()
    @State private var pendingURLDraft: MediaURLDraft?
    @State private var pendingRename: Wallpaper?
    @State private var pendingRemoval: Wallpaper?
    @State private var isDropTargeted = false
    @State private var dropMessage = ""

    init(model: LibraryModel, initialQuery: LibraryQuery = .init()) {
        self.model = model
        _search = State(initialValue: initialQuery.text)
        _mediaFilter = State(initialValue: initialQuery.filter)
        _sortOrder = State(initialValue: initialQuery.sort)
    }

    private var filteredItems: [Wallpaper] {
        catalog.items(from: model.state.wallpapers, query: LibraryQuery(text: search, filter: mediaFilter, sort: sortOrder))
    }

    private var targetDisplayName: String {
        model.displays.first(where: { $0.id == selectedDisplay })?.name ?? "Selecione um monitor"
    }

    private var hasAppliedWallpaper: Bool {
        model.displays.contains { model.activeWallpaperID(on: $0.id) != nil }
    }

    private func appliedWallpaper(on displayID: String) -> Wallpaper? {
        guard let id = model.activeWallpaperID(on: displayID) else { return nil }
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
                    Button { pendingURLDraft = MediaURLDraft() } label: { Label("Adicionar URL", systemImage: "link.badge.plus") }
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
        .sheet(item: $pendingURLDraft) { draft in urlSheet(draft: draft) }
        .sheet(item: $pendingRename) { item in
            RenameMediaSheet(title: item.title, canSave: model.canEdit) { title in
                if model.rename(id: item.id, title: title) {
                    pendingRename = nil
                    return nil
                }
                let error = model.errorMessage ?? "Não foi possível salvar o nome."
                model.errorMessage = nil
                return error
            } onCancel: { pendingRename = nil }
        }
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
        ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            header
            BackgroundControls(model: model, selectedDisplay: selectedDisplay, supportsMediaFit: supportsMediaFit)
            if model.canEdit, !model.state.wallpapers.isEmpty { catalogControls }
            libraryContent
            if model.isImporting { ProgressView("Copiando mídia para a biblioteca…").controlSize(.small) }
        }
        .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(isDropTargeted ? Color.accentColor : .clear, lineWidth: 3)
                .padding(6)
                .allowsHitTesting(false)
        }
        .dropDestination(for: URL.self, action: { urls, _ in handleDrop(urls) }, isTargeted: { isDropTargeted = $0 })
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Biblioteca de mídia. Solte fotos, GIFs ou vídeos para importar, ou um link HTTPS para revisar.")
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
        let items = filteredItems
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
        } else if items.isEmpty {
            ContentUnavailableView {
                Label("Nenhuma mídia corresponde", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("Tente outro tipo de mídia ou ajuste a busca.")
            } actions: {
                Button("Limpar filtros", action: clearQuery)
            }
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 16)], spacing: 16) {
                ForEach(items) { item in card(for: item) }
            }.padding(.bottom)
        }
    }

    private var catalogControls: some View {
        VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 12) {
            ViewThatFits(in: .horizontal) {
                mediaFilterPicker.pickerStyle(.segmented).fixedSize(horizontal: true, vertical: false)
                mediaFilterPicker.pickerStyle(.menu)
            }
            Spacer(minLength: 0)
            Picker("Ordenação da biblioteca", selection: $sortOrder) {
                Text("Mais recentes").tag(LibrarySortOrder.recent)
                Text("Título (A–Z)").tag(LibrarySortOrder.title)
                Text("Tipo de mídia").tag(LibrarySortOrder.mediaType)
            }.pickerStyle(.menu).labelsHidden()
                .accessibilityLabel("Ordenação da biblioteca")
                .help("Ordenar as mídias da biblioteca")
        }
            HStack {
                Text("\(filteredItems.count) de \(model.state.wallpapers.count) mídias")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel("\(filteredItems.count) de \(model.state.wallpapers.count) mídias exibidas")
                Spacer()
                if mediaFilter != .all || !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Limpar filtros", systemImage: "xmark.circle", action: clearQuery)
                        .buttonStyle(.borderless).font(.caption)
                        .accessibilityLabel("Limpar busca e filtro de tipo")
                }
            }
        }
        .controlSize(.regular)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filtros da biblioteca")
    }

    private func clearQuery() {
        search = ""
        mediaFilter = .all
    }

    private var mediaFilterPicker: some View {
        Picker("Tipo de mídia", selection: $mediaFilter) {
            Text("Todas").tag(LibraryMediaFilter.all)
            Text("Fotos").tag(LibraryMediaFilter.photos)
            Text("GIFs").tag(LibraryMediaFilter.gifs)
            Text("Vídeos").tag(LibraryMediaFilter.videos)
            Text("Web").tag(LibraryMediaFilter.web)
        }.labelsHidden().accessibilityLabel("Tipo de mídia na biblioteca")
    }

    private func card(for item: Wallpaper) -> some View {
        let applied = model.activeWallpaperID(on: selectedDisplay) == item.id
        return WallpaperCard(item: item, localURL: model.localMediaURL(for: item), isApplied: applied, appliesToAll: model.state.displayMode.isShared, canApply: !selectedDisplay.isEmpty, onRename: { pendingRename = item }, onApply: {
            model.apply(item, to: selectedDisplay)
        }, onRemove: {
            pendingRemoval = item
        })
        .disabled(!model.canEdit)
    }

    private var sidebar: some View {
        GeometryReader { viewport in
            ScrollView {
                sidebarContent
                    .frame(maxWidth: .infinity, minHeight: max(0, viewport.size.height - 36), alignment: .topLeading)
                    .padding(18)
            }
        }
    }

    private var sidebarContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                BrandLogoView(size: 36)
                Text("Wallmotion").font(.title2.weight(.semibold))
            }.padding(.top, 18).padding(.bottom, 8)
            Text("MONITORES").font(.caption.weight(.semibold)).tracking(1).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            if model.displays.isEmpty {
                Label("Nenhum monitor disponível", systemImage: "display.trianglebadge.exclamationmark")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(Array(model.displays.enumerated()), id: \.element.id) { index, display in
                Button { selectedDisplay = display.id } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "display").font(.title3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(display.name).font(.callout.weight(.medium)).lineLimit(2)
                            Text(appliedWallpaper(on: display.id)?.title ?? "Fundo do sistema")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if let state = model.remotePlaybackStates[display.id] {
                                Text(state.description).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }
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
                .accessibilityLabel("Monitor \(index + 1), \(display.name)")
                .accessibilityValue(displayAccessibilityValue(display))
                .accessibilityAddTraits(selectedDisplay == display.id ? .isSelected : [])
            }
            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                Label(hasAppliedWallpaper ? model.playbackDescription : "Nenhum fundo aplicado", systemImage: hasAppliedWallpaper ? (model.isPaused ? "pause.circle.fill" : "play.circle.fill") : "display")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(!hasAppliedWallpaper || model.isPaused ? Color.secondary : Color.accentColor)
                Button { model.togglePause() } label: {
                    Label(model.manualPauseActionTitle, systemImage: model.state.settings.isManuallyPaused ? "play.fill" : "pause.fill")
                        .frame(maxWidth: .infinity)
                }.disabled(!model.canEdit).help("Controlar a reprodução em todos os monitores")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            Toggle("Pausar em baixo consumo", isOn: Binding(get: { model.state.settings.pauseOnLowPower }, set: { model.setPauseOnLowPower($0) }))
                .font(.caption).disabled(!model.canEdit)
            Toggle("Pausar sob pressão térmica", isOn: Binding(get: { model.state.settings.pauseOnThermalPressure }, set: { model.setPauseOnThermalPressure($0) }))
                .font(.caption).disabled(!model.canEdit)
                .help("Pausa quando o macOS indica pressão térmica alta e retoma apenas no estado nominal. Vídeos web reiniciam ao retomar.")
            Label(model.state.settings.audioDisplayID == nil ? "Som desativado" : "Som em um monitor", systemImage: model.state.settings.audioDisplayID == nil ? "speaker.slash" : "speaker.wave.2")
                .font(.caption).foregroundStyle(.secondary)
            Text("Arquivos originais preservados")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func displayAccessibilityValue(_ display: Display) -> String {
        let selection = selectedDisplay == display.id ? "Monitor selecionado" : "Monitor disponível"
        let wallpaper = appliedWallpaper(on: display.id).map { "Fundo aplicado: \($0.title)" } ?? "Fundo do sistema"
        return [selection, wallpaper, model.remotePlaybackStates[display.id]?.description]
            .compactMap { $0 }.joined(separator: ". ")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Sua biblioteca").font(.largeTitle.weight(.bold)).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Text("WALLMOTION").font(.caption2.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
                }
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
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text(error).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                    }.accessibilityElement(children: .combine)
                    ViewThatFits(in: .horizontal) {
                        HStack { playbackErrorActions }
                        VStack(alignment: .leading, spacing: 8) { playbackErrorActions }
                    }
                }
                .font(.callout).padding(12)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    @ViewBuilder private var playbackErrorActions: some View {
        Button("Tentar novamente") { model.retryPlayback(displayID: selectedDisplay) }
        if let item = appliedWallpaper(on: selectedDisplay), case .web(let embed) = item.source {
            Button("Abrir vídeo no navegador") { NSWorkspace.shared.open(embed.pageURL) }
                .help("Conferir disponibilidade no site do provedor")
        }
    }

    private var monitorContext: some View {
        HStack(spacing: 12) {
            Image(systemName: "display").font(.title2).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.state.displayMode.isShared ? (model.state.displayMode == .spanned ? "Foto panorâmica · todas as telas" : "Todos os monitores · mesmo fundo") : targetDisplayName)
                    .font(.callout.weight(.semibold)).lineLimit(2)
                Text(appliedWallpaper(on: selectedDisplay).map { "Fundo: \($0.title)" } ?? "Escolha uma mídia para este monitor")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private var restoreSystemButton: some View {
        Button { model.clear(displayID: selectedDisplay) } label: {
            Label("Fundo do sistema", systemImage: "arrow.uturn.backward")
        }
        .disabled(!model.canEdit || model.activeWallpaperID(on: selectedDisplay) == nil)
        .help(model.state.displayMode.isShared ? "Revelar o fundo do macOS em todos os monitores" : "Revelar o fundo do macOS neste monitor")
    }

    private func handleDrop(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty, model.canEdit else { return false }
        guard pendingURLDraft == nil, pendingRename == nil, pendingRemoval == nil, model.errorMessage == nil else {
            dropMessage = "Conclua a edição ou o aviso aberto antes de soltar outro item."
            return false
        }
        switch MediaDropIntent.classify(urls) {
        case .files(let files):
            dropMessage = "Arquivos recebidos. Importando mídia."
            Task { @MainActor in
                await model.importFiles(files)
                dropMessage = model.errorMessage == nil
                    ? "Importação concluída."
                    : "Importação concluída com arquivos que não puderam ser adicionados."
            }
            return true
        case .link(let draft):
            pendingURLDraft = draft
            dropMessage = "Link recebido. Revise a fonte antes de adicionar."
            return true
        case .rejected(let message):
            dropMessage = message
            model.errorMessage = message
            return false
        }
    }

    private func urlSheet(draft: MediaURLDraft) -> some View {
        AddURLSheet(text: draft.text, web: draft.web, canAdd: model.canEdit && !model.isImporting) { text, web in
            if model.addURL(text, web: web) {
                pendingURLDraft = nil
                return nil
            }
            let error = model.errorMessage ?? "Não foi possível adicionar o link."
            model.errorMessage = nil
            return error
        } onCancel: { pendingURLDraft = nil }
    }

    private func selectAvailableDisplay() {
        if !model.displays.contains(where: { $0.id == selectedDisplay }) { selectedDisplay = model.displays.first?.id ?? "" }
    }
}

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
