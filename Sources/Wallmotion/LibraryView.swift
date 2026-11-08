import SwiftUI
import AppKit
import WallmotionCore

struct LibraryView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
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
    @State private var showingPerformance = false
    @FocusState private var searchFocused: Bool
    private let initialSceneControls: Bool

    init(model: LibraryModel, initialQuery: LibraryQuery = .init(), initialRename: Wallpaper? = nil, initialSceneControls: Bool = false) {
        self.model = model
        self.initialSceneControls = initialSceneControls
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

    private var findInLibrary: (@MainActor () -> Void)? {
        guard model.canEdit, !model.state.wallpapers.isEmpty else { return nil }
        return { searchFocused = true }
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
        HStack(spacing: 0) {
            sidebar.frame(width: 152)
            detail
        }
        .modifier(ScenarioSurface())
        .tint(BrandTheme.selection(for: colorScheme))
        .focusedSceneValue(\.librarySearchAction, findInLibrary)
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
        VStack(alignment: .leading, spacing: 16) {
            studioTitle
            displayStrip
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    header.frame(width: 240)
                    BackgroundControls(model: model, selectedDisplay: selectedDisplay,
                                       supportsMediaFit: supportsMediaFit, initialDetails: initialSceneControls)
                        .frame(minWidth: 300, maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: 14) {
                    header
                    BackgroundControls(model: model, selectedDisplay: selectedDisplay,
                                       supportsMediaFit: supportsMediaFit, initialDetails: initialSceneControls)
                }
            }
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
        .padding(18)
        }
        .scrollIndicators(.hidden)
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
                    Button("Importar mídia…", systemImage: "plus") { model.chooseFiles() }.buttonStyle(.borderedProminent).tint(BrandTheme.action).foregroundStyle(BrandTheme.graphite)
                    Button("Adicionar link", systemImage: "link") { pendingURLDraft = MediaURLDraft() }.buttonStyle(.bordered)
                }.disabled(model.isImporting)
            }
            .padding(32).frame(maxWidth: .infinity)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
        } else if items.isEmpty {
            ContentUnavailableView {
                Label("Nenhuma mídia corresponde", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("Tente outro tipo de mídia ou ajuste a busca.")
            } actions: {
                Button("Limpar filtros", action: clearQuery)
            }
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                ForEach(items) { item in card(for: item) }
            }.padding(.bottom)
        }
    }

    private var catalogControls: some View {
        VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline) {
            Text("Sua coleção").font(.headline).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            TextField("Buscar", text: searchBinding)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 160)
                .accessibilityLabel("Buscar na biblioteca").focused($searchFocused)
            Text("\(filteredItems.count) de \(model.state.wallpapers.count) mídias")
                .font(.caption).foregroundStyle(BrandTheme.secondaryInk(for: colorScheme))
                .accessibilityLabel("\(filteredItems.count) de \(model.state.wallpapers.count) mídias exibidas")
            if mediaFilter != .all || !searchDraft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Limpar filtros", systemImage: "xmark.circle", action: clearQuery)
                    .buttonStyle(.borderless).font(.caption)
                    .accessibilityLabel("Limpar busca e filtro de tipo")
            }
        }
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
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        BrandLogoView(size: 36)
                        Text("Wallmotion").font(.system(size: 15, weight: .semibold))
                    }.padding(.top, 24).padding(.bottom, 8)
                    Label("Estúdio", systemImage: "square.grid.2x2.fill")
                        .font(.callout.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10).background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 11))
                        .accessibilityAddTraits(.isSelected)
                    ForEach(Array(model.displays.enumerated()), id: \.element.id) { index, display in
                        Button { selectedDisplay = display.id } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 6) {
                                    Image(systemName: "display")
                                    Text("Tela \(index + 1)")
                                    Spacer(minLength: 0)
                                    if selectedDisplay == display.id { Circle().fill(BrandTheme.cyan).frame(width: 6, height: 6) }
                                }.font(.callout.weight(.medium))
                                Text(display.name).font(.caption).lineLimit(2).foregroundStyle(.white.opacity(0.82))
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6).contentShape(Rectangle())
                        }.buttonStyle(.plain).help(display.name)
                            .accessibilityLabel("Monitor \(index + 1), \(display.name)")
                            .accessibilityValue(displayAccessibilityValue(display))
                            .accessibilityAddTraits(selectedDisplay == display.id ? .isSelected : [])
                    }
                    Spacer(minLength: 12)
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: hasAppliedWallpaper ? "waveform.path" : "display").font(.title2).foregroundStyle(BrandTheme.cyan)
                        Text(hasAppliedWallpaper ? model.playbackDescription : "Pronto para ganhar vida.")
                            .font(.caption.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                        Button { model.togglePause() } label: {
                            Label(model.state.settings.isManuallyPaused ? "Retomar tudo" : "Pausar tudo", systemImage: model.state.settings.isManuallyPaused ? "play.fill" : "pause.fill")
                                .font(.caption.weight(.semibold)).foregroundStyle(BrandTheme.graphite).frame(maxWidth: .infinity).padding(.vertical, 7)
                                .background(BrandTheme.action, in: Capsule())
                        }.buttonStyle(.plain).disabled(!model.canEdit).help("Pausar ou retomar todos os monitores")
                    }.padding(10).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
                    Button { showingPerformance.toggle() } label: {
                        Label("Desempenho", systemImage: "leaf").font(.caption)
                    }.buttonStyle(.plain).popover(isPresented: $showingPerformance) {
                        performanceControls.padding(20).frame(width: 300)
                            .foregroundStyle(.primary).environment(\.colorScheme, colorScheme)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: max(0, viewport.size.height - 28), alignment: .topLeading)
                .padding(14)
            }.scrollIndicators(.hidden)
        }
        .foregroundStyle(.white)
        .background(BrandTheme.graphite.opacity(reduceTransparency || contrast == .increased ? 1 : 0.82))
        .environment(\.colorScheme, .dark)
    }

    private var performanceControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Desempenho").font(.headline)
            Toggle("Pausar em baixo consumo", isOn: Binding(get: { model.state.settings.pauseOnLowPower }, set: { model.setPauseOnLowPower($0) }))
            Toggle("Pausar sob pressão térmica", isOn: Binding(get: { model.state.settings.pauseOnThermalPressure }, set: { model.setPauseOnThermalPressure($0) }))
            Toggle("Liberar fundos com memória crítica", isOn: Binding(get: { model.state.settings.pauseOnMemoryPressure }, set: { model.setPauseOnMemoryPressure($0) }))
            Text("As pausas de proteção valem para todos os monitores.").font(.caption).foregroundStyle(BrandTheme.secondaryInk(for: colorScheme))
        }.disabled(!model.canEdit)
    }

    private var studioTitle: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sua tela, mais viva.").font(.system(size: 27, weight: .semibold, design: .rounded)).tracking(-0.7)
                    .accessibilityAddTraits(.isHeader)
                Text("Seu espaço. Seu movimento.").font(.callout).foregroundStyle(BrandTheme.secondaryInk(for: colorScheme))
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Button { model.chooseFiles() } label: {
                    Label("Importar", systemImage: "plus")
                        .labelStyle(.titleAndIcon).font(.callout.weight(.semibold))
                        .foregroundStyle(BrandTheme.graphite)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(BrandTheme.action, in: Capsule())
                }.buttonStyle(.plain).help("Importar fotos, GIFs e vídeos · ⌘O")
                Button { pendingURLDraft = MediaURLDraft() } label: {
                    Image(systemName: "link").font(.callout.weight(.medium))
                        .foregroundStyle(BrandTheme.selection(for: colorScheme))
                        .frame(width: 32, height: 32)
                        .background(BrandTheme.action.opacity(0.14), in: Circle())
                }.buttonStyle(.plain).accessibilityLabel("Adicionar link de vídeo").help("Adicionar URL de vídeo")
            }.disabled(!model.canEdit || model.isImporting)
        }
    }

    private var displayStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Monitores").font(.callout.weight(.semibold))
                Spacer(minLength: 8)
                Picker("Organização dos monitores", selection: Binding(get: { model.state.displayMode }, set: { model.setDisplayMode($0, sourceDisplayID: selectedDisplay) })) {
                    Text("Separados").tag(DisplayMode.independent)
                    Text("Espelhar").tag(DisplayMode.mirrored)
                    Text("Panorama").tag(DisplayMode.spanned)
                }.pickerStyle(.menu).labelsHidden().fixedSize().disabled(!model.canEdit || selectedDisplay.isEmpty)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Array(model.displays.enumerated()), id: \.element.id) { index, display in
                        Button { selectedDisplay = display.id } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "display").font(.title3)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(index + 1) · \(display.name)").font(.caption.weight(.semibold)).lineLimit(1)
                                    Text(appliedWallpaper(on: display.id)?.title ?? "Fundo do sistema")
                                        .font(.caption2).lineLimit(1)
                                }
                                if model.state.settings.audioDisplayID == display.id { Image(systemName: "speaker.wave.2.fill").font(.caption) }
                            }.frame(width: 165, alignment: .leading).padding(10)
                                .foregroundStyle(selectedDisplay == display.id ? BrandTheme.selection(for: colorScheme) : .primary)
                                .background(selectedDisplay == display.id ? BrandTheme.action.opacity(0.12) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selectedDisplay == display.id ? BrandTheme.selection(for: colorScheme) : .clear, lineWidth: 1.5))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).help(display.name)
                            .accessibilityLabel("Monitor \(index + 1), \(display.name)")
                            .accessibilityValue(displayAccessibilityValue(display))
                            .accessibilityAddTraits(selectedDisplay == display.id ? .isSelected : [])
                    }
                }
            }.scrollIndicators(.hidden)
            if model.displays.isEmpty {
                Label("Nenhum monitor disponível", systemImage: "display.trianglebadge.exclamationmark").font(.callout)
            } else if model.state.displayMode.isShared {
                HStack {
                    Text(model.state.displayMode == .spanned ? "Panorama: os ajustes afetam todas as telas." : "Espelhado: os ajustes afetam todas as telas.")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Controlar separadamente") { model.useIndependentDisplays(on: selectedDisplay) }
                        .font(.caption.weight(.semibold)).disabled(!model.canEdit)
                }
            }
        }
    }

    private func displayAccessibilityValue(_ display: Display) -> String {
        let selection = selectedDisplay == display.id ? "Monitor selecionado" : "Monitor disponível"
        let wallpaper = appliedWallpaper(on: display.id).map { "Fundo aplicado: \($0.title)" } ?? "Fundo do sistema"
        return [selection, wallpaper, model.remotePlaybackStates[display.id]?.description]
            .compactMap { $0 }.joined(separator: ". ")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            StudioWallpaperPreview(item: appliedWallpaper(on: selectedDisplay),
                localURL: appliedWallpaper(on: selectedDisplay).flatMap { model.localMediaURL(for: $0) })
                .frame(height: 130)
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(appliedWallpaper(on: selectedDisplay)?.title ?? "Fundo do sistema")
                        .font(.callout.weight(.semibold)).lineLimit(1)
                    Text(model.state.displayMode.isShared ? "Todas as telas" : targetDisplayName)
                        .font(.caption).foregroundStyle(BrandTheme.secondaryInk(for: colorScheme)).lineLimit(1)
                }
                Spacer(minLength: 0)
                scenarioActions
            }
            if model.isPreparingWallpaper(on: selectedDisplay) {
                ProgressView("Verificando fundo…").controlSize(.small)
            }
            if let error = model.playbackErrors[selectedDisplay] {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).fixedSize(horizontal: false, vertical: true)
                playbackErrorActions
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

    private var scenarioActions: some View {
        Menu {
            restoreSystemButton
            Button("Recarregar reprodução", systemImage: "arrow.clockwise") { model.refreshPlayback() }
                .disabled(!model.canEdit)
        } label: {
            Label("Ações do cenário", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .accessibilityLabel("Ações do cenário")
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
