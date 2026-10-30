import SwiftUI
import AppKit
import WallmotionCore

struct LibraryView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var model: LibraryModel
    @State private var selectedDisplay = ""
    @State private var searchDraft = LibrarySearchDraft()
    @State private var mediaFilter = LibraryMediaFilter.all
    @State private var sortOrder = LibrarySortOrder.recent
    @State private var catalog = LibraryCatalogProjection()
    @State private var pendingURLDraft: MediaURLDraft?
    @State private var pendingRename: Wallpaper?
    @State private var pendingRemoval: Wallpaper?
    @State private var isDropTargeted = false
    @State private var dropMessage = ""
    @State private var showingSceneControls = false

    init(model: LibraryModel, initialQuery: LibraryQuery = .init(), initialRename: Wallpaper? = nil, initialSceneControls: Bool = false) {
        self.model = model
        _showingSceneControls = State(initialValue: initialSceneControls)
        _pendingRename = State(initialValue: initialRename)
        _searchDraft = State(initialValue: LibrarySearchDraft(text: initialQuery.text))
        _mediaFilter = State(initialValue: initialQuery.filter)
        _sortOrder = State(initialValue: initialQuery.sort)
    }

    private var filteredItems: [Wallpaper] {
        catalog.items(from: model.state.wallpapers, query: LibraryQuery(text: searchDraft.text, filter: mediaFilter, sort: sortOrder))
    }

    private var searchBinding: Binding<String> {
        Binding(get: { searchDraft.text }, set: { value in
            var next = searchDraft
            guard next.replace(with: value) else { return }
            searchDraft = next
        })
    }

    private var renameTargetExists: Bool {
        guard let pendingRename else { return true }
        return model.state.wallpapers.contains { $0.id == pendingRename.id }
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
            .searchable(text: searchBinding, prompt: "Buscar na biblioteca")
        }
        .onAppear { selectAvailableDisplay() }
        .onChange(of: model.displays) { _, _ in selectAvailableDisplay() }
        .onChange(of: renameTargetExists, initial: true) { _, exists in
            if !exists { pendingRename = nil }
        }
        .sheet(item: $pendingURLDraft) { draft in urlSheet(draft: draft) }
        .sheet(item: $pendingRename) { item in
            RenameMediaSheet(title: item.title, canSave: model.canEdit && renameTargetExists) { title in
                guard model.state.wallpapers.contains(where: { $0.id == item.id }) else {
                    pendingRename = nil
                    return nil
                }
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
        } message: { Text(removalMessage) }
    }

    private var removalMessage: String {
        guard let pendingRemoval else { return "" }
        guard let item = model.state.wallpapers.first(where: { $0.id == pendingRemoval.id }) else {
            return "Esta mídia já foi removida da biblioteca."
        }
        switch item.source {
        case .local:
            if model.hasOtherLocalReferences(to: item) {
                return "Esta mídia será removida da biblioteca e dos monitores. A cópia importada continuará disponível para as outras mídias que a usam."
            }
            return "A cópia importada será apagada e removida dos monitores. Seu arquivo original será preservado."
        case .remote, .web:
            return "O link será removido da biblioteca e dos monitores."
        }
    }

    private var detail: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            header
            DisclosureGroup(isExpanded: $showingSceneControls) {
                BackgroundControls(model: model, selectedDisplay: selectedDisplay, supportsMediaFit: supportsMediaFit)
                    .padding(.top, 10)
            } label: {
                Label("Ajustar cenário · monitores, enquadramento e som", systemImage: "slider.horizontal.3")
                    .font(.callout.weight(.medium))
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            if let notice = searchDraft.notice {
                HStack(alignment: .top, spacing: 12) {
                    Label(notice, systemImage: "text.magnifyingglass")
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Limpar busca") { searchDraft.clear() }
                        .buttonStyle(.bordered).controlSize(.small)
                        .accessibilityLabel("Limpar busca e aviso")
                }
                .font(.callout)
                .padding(12)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            if model.canEdit, !model.state.wallpapers.isEmpty { catalogControls }
            libraryContent
            if model.isImporting { ProgressView("Copiando mídia para a biblioteca…").controlSize(.small) }
        }
        .padding(24)
        }
        .background(colorScheme == .dark ? Color(red: 0.055, green: 0.065, blue: 0.095) : Color(red: 0.95, green: 0.95, blue: 0.98))
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
            VStack(spacing: 14) {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: 34, weight: .light)).foregroundStyle(Color.accentColor)
                Text("Sua próxima paisagem começa aqui.").font(.title2.weight(.semibold))
                Text("Solte uma foto, GIF ou vídeo. Transforme um link em atmosfera.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack {
                    Button("Importar mídia…", systemImage: "plus") { model.chooseFiles() }.buttonStyle(.borderedProminent)
                    Button("Adicionar link", systemImage: "link") { pendingURLDraft = MediaURLDraft() }.buttonStyle(.bordered)
                }.disabled(model.isImporting)
            }
            .padding(32).frame(maxWidth: .infinity)
            .background(BrandTheme.cardBackground.opacity(0.35), in: RoundedRectangle(cornerRadius: 20))
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
        VStack(alignment: .leading, spacing: 14) {
        Text("Sua coleção").font(.title2.weight(.bold)).accessibilityAddTraits(.isHeader)
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
                if mediaFilter != .all || !searchDraft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
        searchDraft.clear()
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
        let restriction = model.applicationRestriction(for: item, on: selectedDisplay)
        return WallpaperCard(item: item, localURL: model.localMediaURL(for: item), isApplied: applied, appliesToAll: model.state.displayMode.isShared, canApply: restriction == nil, applyDisabledReason: restriction, onRename: { pendingRename = item }, onApply: {
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
                VStack(alignment: .leading, spacing: 3) {
                    Text("Wallmotion").font(.title2.weight(.bold))
                    Text("DESKTOP STUDIO").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(.secondary)
                }
            }.padding(.top, 18).padding(.bottom, 8)
            Label("SEU CENÁRIO", systemImage: "circle.hexagongrid.fill").font(.caption2.weight(.bold)).foregroundStyle(Color.accentColor)
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
                    .background(selectedDisplay == display.id ? BrandTheme.selection(for: colorScheme).opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 10))
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
            Toggle("Liberar fundos com memória crítica", isOn: Binding(get: { model.state.settings.pauseOnMemoryPressure }, set: { model.setPauseOnMemoryPressure($0) }))
                .font(.caption).disabled(!model.canEdit)
                .help("Sob aviso, novas mídias aguardam. Em pressão crítica, libera os fundos e retoma ao normal, respeitando outras pausas. Vídeos reiniciam.")
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
            LibraryHero(count: model.state.wallpapers.count)
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
