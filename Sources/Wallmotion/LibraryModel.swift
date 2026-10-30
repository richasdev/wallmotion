import AppKit
import Observation
import UniformTypeIdentifiers
import WallmotionCore

@MainActor @Observable
final class LibraryModel {
    private(set) var state = LibraryState()
    private(set) var displays: [Display] = []
    private(set) var canEdit = true
    private(set) var isImporting = false
    private(set) var playbackErrors: [String: String] = [:]
    var errorMessage: String?
    private let store: LibraryStore
    private let engine: DesktopCoordinator
    private var started = false
    private var policy = PlaybackPolicy()
    private var screenLocked = false
    private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var pendingImportURLs: [URL] = []
    private var importWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private let beforeRollbackCleanup: (@MainActor () async -> Void)?

    init(
        store: LibraryStore = LibraryStore(),
        engine: DesktopCoordinator = DesktopCoordinator(),
        beforeRollbackCleanup: (@MainActor () async -> Void)? = nil
    ) {
        self.store = store
        self.engine = engine
        self.beforeRollbackCleanup = beforeRollbackCleanup
        load()
    }

    var queuedImportCount: Int { pendingImportURLs.count }

    var isPaused: Bool { screenLocked || policy.isPaused(settings: state.settings, lowPower: lowPower) }
    var playbackDescription: String {
        if state.settings.isManuallyPaused { return "Pausado por você" }
        if screenLocked || policy.sleeping || policy.screenAsleep || policy.sessionInactive { return "Pausado pelo sistema" }
        if lowPower && state.settings.pauseOnLowPower { return "Pausado · baixo consumo" }
        return "Reprodução ativa"
    }

    func localMediaURL(for wallpaper: Wallpaper) -> URL? {
        guard case .local = wallpaper.source else { return nil }
        return try? store.resolvedURL(for: wallpaper)
    }

    func start() {
        guard !started else { return }
        started = true
        let workspace = NSWorkspace.shared.notificationCenter
        observe(NSApplication.didChangeScreenParametersNotification, in: .default) { $0.refreshPlayback(force: false) }
        observe(NSWorkspace.willSleepNotification, in: workspace) { $0.policy.sleeping = true; $0.applyPolicy() }
        observe(NSWorkspace.didWakeNotification, in: workspace) { $0.policy.sleeping = false; $0.applyPolicy() }
        observe(NSWorkspace.screensDidSleepNotification, in: workspace) { $0.policy.screenAsleep = true; $0.applyPolicy() }
        observe(NSWorkspace.screensDidWakeNotification, in: workspace) { $0.policy.screenAsleep = false; $0.applyPolicy() }
        observe(NSWorkspace.sessionDidResignActiveNotification, in: workspace) { $0.policy.sessionInactive = true; $0.applyPolicy() }
        observe(NSWorkspace.sessionDidBecomeActiveNotification, in: workspace) { $0.policy.sessionInactive = false; $0.applyPolicy() }
        // These distributed notification names are best-effort macOS signals.
        // Public workspace sleep/session events remain the fallback policy.
        observe(Notification.Name("com.apple.screenIsLocked"), in: DistributedNotificationCenter.default()) { $0.screenLocked = true; $0.applyPolicy() }
        observe(Notification.Name("com.apple.screenIsUnlocked"), in: DistributedNotificationCenter.default()) { $0.screenLocked = false; $0.applyPolicy() }
        observe(Notification.Name.NSProcessInfoPowerStateDidChange, in: .default) {
            $0.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            $0.applyPolicy()
        }
        refreshPlayback()
    }

    private func observe(_ name: Notification.Name, in center: NotificationCenter, action: @escaping @MainActor (LibraryModel) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        observers.append((center, token))
    }

    private func applyPolicy() { engine.setPaused(isPaused) }

    func stop() {
        observers.forEach { $0.0.removeObserver($0.1) }
        observers.removeAll()
        engine.stop()
        started = false
    }

    func load() {
        do {
            state = try store.load()
            canEdit = true
        } catch {
            canEdit = false
            errorMessage = "A biblioteca não pôde ser aberta e foi preservada em \(store.stateURL.path). \(error.localizedDescription)"
        }
        if started { refreshPlayback() }
    }

    @discardableResult private func update(_ next: LibraryState) -> Bool {
        guard canEdit else { return false }
        do {
            try store.save(next)
            state = next
            return true
        } catch {
            errorMessage = "Não foi possível salvar a biblioteca. \(error.localizedDescription)"
            return false
        }
    }

    func chooseFiles() {
        guard canEdit, !isImporting else { return }
        let panel = NSOpenPanel()
        panel.title = "Importar fotos, GIFs e vídeos"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp", "gif", "mp4", "mov", "m4v"].compactMap { UTType(filenameExtension: $0) }
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor [weak self] in await self?.importFiles(urls) }
        }
    }

    func importFiles(_ urls: [URL]) async {
        guard canEdit, !urls.isEmpty else { return }
        pendingImportURLs.append(contentsOf: urls)
        if isImporting {
            await withCheckedContinuation { importWaiters.append($0) }
            return
        }
        isImporting = true
        defer {
            isImporting = false
            let waiters = importWaiters
            importWaiters.removeAll(keepingCapacity: true)
            waiters.forEach { $0.resume() }
        }
        var failures: [String] = []
        var imported: [Wallpaper] = []
        while true {
            while !pendingImportURLs.isEmpty {
                let batch = pendingImportURLs
                pendingImportURLs.removeAll(keepingCapacity: true)
                for url in batch {
                    let scoped = url.startAccessingSecurityScopedResource()
                    do {
                        let store = store
                        let item = try await Task.detached(priority: .userInitiated) { try store.importFile(at: url) }.value
                        imported.append(item)
                    } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
                    if scoped { url.stopAccessingSecurityScopedResource() }
                }
            }

            guard !imported.isEmpty else {
                break
            }
            var next = state
            next.wallpapers.append(contentsOf: imported)
            if !update(next) {
                let rollback = imported
                imported.removeAll(keepingCapacity: true)
                await beforeRollbackCleanup?()
                let store = store
                await Task.detached { rollback.forEach { try? store.deleteMedia(for: $0) } }.value
            }
            imported.removeAll(keepingCapacity: true)
            if pendingImportURLs.isEmpty { break }
        }
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
    }

    @discardableResult func addURL(_ text: String) -> Bool {
        do {
            let item = try Wallpaper.remote(text)
            var next = state
            next.wallpapers.append(item)
            return update(next)
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func apply(_ item: Wallpaper, to displayID: String) {
        guard state.wallpapers.contains(where: { $0.id == item.id }), displays.contains(where: { $0.id == displayID }) else { return }
        do {
            try engine.validateAssignment(item, to: displayID, store: store)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        var next = state
        next.assignments[displayID] = item.id
        if update(next) {
            playbackErrors[displayID] = nil
            refreshPlayback(force: false)
        }
    }

    func clear(displayID: String) {
        var next = state
        next.assignments.removeValue(forKey: displayID)
        if update(next) { refreshPlayback(force: false) }
    }

    func remove(_ item: Wallpaper) {
        var next = state
        next.remove(id: item.id)
        guard update(next) else { return }
        refreshPlayback(force: false)
        do { try store.deleteMedia(for: item) }
        catch { errorMessage = "Item removido da biblioteca, mas a cópia de mídia não pôde ser apagada. \(error.localizedDescription)" }
    }

    func togglePause() {
        var next = state
        next.settings.isManuallyPaused.toggle()
        if update(next) { engine.setPaused(isPaused) }
    }

    func setPauseOnLowPower(_ value: Bool) {
        var next = state
        next.settings.pauseOnLowPower = value
        if update(next) { engine.setPaused(isPaused) }
    }

    func refreshPlayback(force: Bool = true) {
        displays = NSScreen.screens.compactMap { screen in
            Display.identify(screen).map { Display(id: $0, name: screen.localizedName) }
        }
        if force {
            playbackErrors = [:]
        } else {
            let connected = Set(displays.map(\.id))
            playbackErrors = playbackErrors.filter { connected.contains($0.key) && state.assignments[$0.key] != nil }
        }
        engine.rebuild(state: state, store: store, paused: isPaused, force: force) { [weak self] id, message in
            self?.playbackErrors[id] = message
        }
    }
}
