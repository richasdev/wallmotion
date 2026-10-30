import SwiftUI
import WallmotionCore

struct LibraryView: View {
    @Bindable var model: LibraryModel
    @State private var selectedDisplay = ""
    @State private var search = ""
    @State private var showingURL = false
    @State private var urlText = ""
    @State private var urlError: String?
    @State private var pendingRemoval: Wallpaper?

    private var filteredItems: [Wallpaper] {
        model.state.wallpapers.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
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
                    Button { model.chooseFiles() } label: { Label("Importar", systemImage: "plus") }
                        .disabled(!model.canEdit || model.isImporting)
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
            if let wallpaperID = model.state.assignments[selectedDisplay] {
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
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 16)], spacing: 16) {
                    ForEach(filteredItems) { item in card(for: item) }
                }.padding(.bottom)
            }
            if filteredItems.isEmpty { Text("Nenhuma mídia encontrada.").foregroundStyle(.secondary) }
        }
    }

    private func card(for item: Wallpaper) -> some View {
        let applied = model.state.assignments[selectedDisplay] == item.id
        return WallpaperCard(item: item, isApplied: applied, onApply: {
            model.apply(item, to: selectedDisplay)
        }, onRemove: {
            pendingRemoval = item
        })
        .disabled(!model.canEdit || selectedDisplay.isEmpty)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Wallmotion", systemImage: "play.rectangle.on.rectangle.fill")
                .font(.title2.weight(.semibold)).padding(.top, 18)
            Text("SEUS MONITORES").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(model.displays) { display in
                Button { selectedDisplay = display.id } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "display").font(.title3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(display.name).lineLimit(1)
                            Text(model.state.assignments[display.id] == nil ? "Wallpaper do sistema" : "Wallpaper aplicado")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(selectedDisplay == display.id ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            Spacer()
            Divider()
            Label(model.playbackDescription, systemImage: model.isPaused ? "pause.circle" : "play.circle")
                .font(.callout)
            Button(model.state.settings.isManuallyPaused ? "Retomar" : "Pausar") { model.togglePause() }
                .disabled(!model.canEdit)
            Toggle("Pausar em baixo consumo", isOn: Binding(get: { model.state.settings.pauseOnLowPower }, set: { model.setPauseOnLowPower($0) }))
                .font(.caption).disabled(!model.canEdit)
            Text("Áudio desativado · arquivos originais preservados")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(18)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sua biblioteca").font(.largeTitle.weight(.bold))
            HStack {
                Text("\(model.state.wallpapers.count) itens · fotos, GIFs e vídeos").foregroundStyle(.secondary)
                Spacer()
                Button("Usar wallpaper do sistema") { model.clear(displayID: selectedDisplay) }
                    .disabled(!model.canEdit || model.state.assignments[selectedDisplay] == nil)
            }
            if let error = model.playbackErrors[selectedDisplay] {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Spacer()
                    Button("Tentar novamente") { model.refreshPlayback() }
                }.font(.callout)
            }
        }
    }

    private var urlSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Adicionar vídeo por URL").font(.title2.weight(.semibold))
            Text("Cole um link HTTPS direto de vídeo ou HLS (.m3u8). Links de páginas como YouTube ainda não são suportados.")
                .foregroundStyle(.secondary)
            TextField("https://exemplo.com/video.mp4", text: $urlText)
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
        if model.addURL(urlText) {
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

private struct WallpaperCard: View {
    let item: Wallpaper
    let isApplied: Bool
    let onApply: () -> Void
    let onRemove: () -> Void

    private var symbol: String {
        switch item.kind {
        case .image: "photo"
        case .gif: "square.stack.3d.up"
        case .video: "play.rectangle"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                LinearGradient(colors: [.accentColor.opacity(0.25), .indigo.opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: symbol).font(.system(size: 38, weight: .light)).foregroundStyle(Color.accentColor)
            }
            .frame(height: 118).clipShape(RoundedRectangle(cornerRadius: 10))
            Text(item.title).font(.headline).lineLimit(1).help(item.title)
            HStack {
                Text(item.kind.rawValue.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if case .remote = item.source { Label("URL", systemImage: "link").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(role: .destructive, action: onRemove) { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Remover da biblioteca")
            }
            Button(action: onApply) {
                Label(isApplied ? "Aplicado · reaplicar" : "Aplicar neste monitor", systemImage: isApplied ? "checkmark.circle.fill" : "display")
                    .frame(maxWidth: .infinity)
            }.buttonStyle(.bordered)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(isApplied ? Color.accentColor : .primary.opacity(0.07), lineWidth: 1))
    }
}
