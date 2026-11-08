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
    private(set) var remotePlaybackStates: [String: RemotePlaybackState] = [:]
    private(set) var photoQualityByDisplay: [String: PhotoQualityInfo] = [:]
    var errorMessage: String?
    @ObservationIgnored private let thermalState: @MainActor () -> ThermalPausePolicy.Pressure
    @ObservationIgnored private let memoryMonitor: any MemoryPressureMonitoring
    @ObservationIgnored private let visibleApplicationMonitor: any VisibleApplicationMonitoring
    private var visibleApplicationMonitorRunning = false
    private(set) var visibleAppPausedDisplays = Set<String>()
    @ObservationIgnored private let purgeThumbnails: @MainActor () -> Void
    private var lastMemoryPressure: MemoryPressurePolicy.Pressure?
    private(set) var resourcesReleasedForMemory = false
    private let store: LibraryStore
    private let engine: DesktopCoordinator
    private let connectedDisplays: @MainActor () -> [Display]
    private var started = false
    @ObservationIgnored private var stateRevision = UUID()
    private enum AssignmentScope: Hashable { case display(String), shared, mode }
    private enum AssignmentIntent {
        case wallpaper(UUID, String)
        case mode(DisplayMode, String)
        var displayID: String {
            switch self { case .wallpaper(_, let id), .mode(_, let id): id }
        }
    }
    private struct PendingAssignment {
        let token: UUID
        let intent: AssignmentIntent
        let task: Task<Void, Never>
    }
    private var pendingAssignments: [AssignmentScope: PendingAssignment] = [:]
    private var policy = PlaybackPolicy()
    private var screenLocked = false
    private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    static let maximumImportURLsPerCycle = 256
    private var acceptedImportCount = 0
    private var rejectedDuringImport = false
    private var pendingImportURLs: [URL] = []
    private var importWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private let beforeRollbackCleanup: (@MainActor () async -> Void)?

    init(
        thermalState: @escaping @MainActor () -> ThermalPausePolicy.Pressure = {
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: .nominal
            case .fair: .fair
            case .serious: .serious
            case .critical: .critical
            @unknown default: .serious
            }
        },
        memoryMonitor: any MemoryPressureMonitoring = SystemMemoryPressureMonitor(),
        visibleApplicationMonitor: any VisibleApplicationMonitoring = VisibleApplicationMonitor(),
        purgeThumbnails: @escaping @MainActor () -> Void = { ThumbnailCache.purge() },
        store: LibraryStore = LibraryStore(),
        engine: DesktopCoordinator = DesktopCoordinator(),
        connectedDisplays: @escaping @MainActor () -> [Display] = {
            NSScreen.screens.compactMap { screen in
                Display.identify(screen).map { Display(id: $0, name: screen.localizedName) }
            }
        },
        beforeRollbackCleanup: (@MainActor () async -> Void)? = nil
    ) {
        self.memoryMonitor = memoryMonitor
        self.visibleApplicationMonitor = visibleApplicationMonitor
        self.purgeThumbnails = purgeThumbnails
        self.thermalState = thermalState
        self.store = store
        self.engine = engine
        self.connectedDisplays = connectedDisplays
        self.beforeRollbackCleanup = beforeRollbackCleanup
        load()
    }

    var queuedImportCount: Int { pendingImportURLs.count }

    private var shouldReleaseForMemory: Bool { state.settings.pauseOnMemoryPressure && policy.memory.isPaused }
    private var shouldDeferNewRenderers: Bool { state.settings.pauseOnMemoryPressure && lastMemoryPressure == .warning }

    var isPaused: Bool { screenLocked || policy.isPaused(settings: state.settings, lowPower: lowPower) }
    private var isAutomaticallyPaused: Bool {
        var settings = state.settings
        settings.isManuallyPaused = false
        return screenLocked || policy.isPaused(settings: settings, lowPower: lowPower)
    }

    var manualPauseActionTitle: String {
        if isAutomaticallyPaused {
            return state.settings.isManuallyPaused ? "Liberar pausa manual" : "Manter pausado"
        }
        return state.settings.isManuallyPaused ? "Retomar" : "Pausar"
    }

    var playbackDescription: String {
        if state.settings.isManuallyPaused { return "Pausado por você" }
        if screenLocked || policy.sleeping || policy.screenAsleep || policy.sessionInactive { return "Pausado pelo sistema" }
        if shouldReleaseForMemory { return "Pausado · pressão de memória" }
        if state.settings.pauseOnThermalPressure && policy.thermal.isPaused { return "Pausado · pressão térmica" }
        if lowPower && state.settings.pauseOnLowPower { return "Pausado · baixo consumo" }
        if shouldDeferNewRenderers { return "Ativo · novas mídias aguardam memória" }
        let assigned = Set(state.effectiveAssignments(for: displays.map(\.id)).keys)
        if state.settings.pauseWhenOtherAppsVisible, !assigned.isEmpty, assigned.isSubset(of: visibleAppPausedDisplays) {
            return "Pausado · outros apps nos monitores"
        }
        return "Reprodução ativa"
    }

    func isPausedForVisibleApp(on displayID: String) -> Bool {
        state.settings.pauseWhenOtherAppsVisible && visibleAppPausedDisplays.contains(displayID) && activeWallpaperID(on: displayID) != nil
    }

    func playbackDescription(on displayID: String) -> String {
        if !isPaused, isPausedForVisibleApp(on: displayID) { return "Pausado · outro app neste monitor" }
        return playbackDescription
    }

    func localMediaURL(for wallpaper: Wallpaper) -> URL? {
        guard case .local = wallpaper.source else { return nil }
        return try? store.resolvedURL(for: wallpaper)
    }

    func start() {
        guard !started else { return }
        started = true
        // This source observes transitions; it has no synchronous initial snapshot.
        lastMemoryPressure = nil
        policy.memory = MemoryPressurePolicy()
        memoryMonitor.start { [weak self] pressure in self?.receiveMemoryPressure(pressure) }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(NSApplication.didChangeScreenParametersNotification, in: .default) {
            $0.refreshPlayback(force: false); $0.visibleApplicationMonitor.refresh()
        }
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
        // Reading thermalState before registering is required by Foundation.
        refreshThermalState()
        observe(ProcessInfo.thermalStateDidChangeNotification, in: .default) { $0.refreshThermalState() }
        // Re-read after registration so a transition during setup cannot be lost.
        refreshThermalState()
        refreshPlayback()
    }

    func refreshThermalState() {
        policy.thermal.update(thermalState(), enabled: state.settings.pauseOnThermalPressure)
        if started { applyPolicy() }
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

    func receiveMemoryPressure(_ pressure: MemoryPressurePolicy.Pressure) {
        guard started, lastMemoryPressure != pressure else { return }
        lastMemoryPressure = pressure
        policy.memory.update(pressure, enabled: state.settings.pauseOnMemoryPressure)
        guard state.settings.pauseOnMemoryPressure else { return }
        if pressure == .warning { purgeThumbnails() }
        if shouldReleaseForMemory { releaseMemoryResources() }
        else { refreshPlayback(force: false) }
    }

    private func releaseMemoryResources() {
        guard !resourcesReleasedForMemory else { return }
        resourcesReleasedForMemory = true
        purgeThumbnails()
        engine.stop() // Cancels pending photo publication and releases owned surfaces.
        syncVisibleApplicationMonitor()
        playbackErrors = [:]
        remotePlaybackStates = [:]
        photoQualityByDisplay = [:]
    }

    private func applyPolicy() {
        if shouldReleaseForMemory { releaseMemoryResources() }
        else {
            engine.setPaused(isPaused)
            syncVisibleApplicationMonitor()
        }
    }

    private func syncVisibleApplicationMonitor() {
        let assigned = Set(state.effectiveAssignments(for: displays.map(\.id)).keys)
        guard started, state.settings.pauseWhenOtherAppsVisible, !isPaused, !resourcesReleasedForMemory, !assigned.isEmpty else {
            if visibleApplicationMonitorRunning { visibleApplicationMonitor.stop() }
            visibleApplicationMonitorRunning = false
            visibleAppPausedDisplays = []
            engine.setVisibleAppPausedDisplays([])
            return
        }
        visibleAppPausedDisplays.formIntersection(assigned)
        engine.setVisibleAppPausedDisplays(visibleAppPausedDisplays)
        if visibleApplicationMonitorRunning {
            visibleApplicationMonitor.update(displayIDs: assigned)
        } else {
            visibleApplicationMonitorRunning = true
            visibleApplicationMonitor.start(displayIDs: assigned) { [weak self] occupied in
                guard let self, self.visibleApplicationMonitorRunning,
                      self.state.settings.pauseWhenOtherAppsVisible, !self.isPaused else { return }
                let assigned = Set(self.state.effectiveAssignments(for: self.displays.map(\.id)).keys)
                self.visibleAppPausedDisplays = occupied.intersection(assigned)
                self.engine.setVisibleAppPausedDisplays(self.visibleAppPausedDisplays)
            }
        }
    }

    func stop() {
        visibleApplicationMonitorRunning = false
        visibleApplicationMonitor.stop()
        visibleAppPausedDisplays = []
        cancelPendingAssignments()
        memoryMonitor.stop()
        lastMemoryPressure = nil
        policy.memory = MemoryPressurePolicy()
        resourcesReleasedForMemory = false
        observers.forEach { $0.0.removeObserver($0.1) }
        observers.removeAll()
        photoQualityByDisplay = [:]
        engine.stop()
        remotePlaybackStates = [:]
        playbackErrors = [:]
        started = false
    }

    func load() {
        cancelPendingAssignments()
        stateRevision = UUID()
        do {
            state = try store.load()
            canEdit = true
        } catch {
            canEdit = false
            errorMessage = "A biblioteca não pôde ser aberta e foi preservada em \(store.stateURL.path). \(error.localizedDescription)"
        }
        policy.memory.update(lastMemoryPressure ?? .normal, enabled: state.settings.pauseOnMemoryPressure)
        refreshThermalState()
        if started { refreshPlayback() }
    }

    @discardableResult private func update(_ next: LibraryState) -> Bool {
        guard canEdit else { return false }
        do {
            try store.save(next)
            state = next
            stateRevision = UUID()
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
        panel.message = "Selecione até 256 arquivos por vez. Para seleções maiores, importe em lotes."
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
        guard urls.count <= Self.maximumImportURLsPerCycle - acceptedImportCount else {
            if isImporting { rejectedDuringImport = true }
            errorMessage = Self.importLimitMessage
            return
        }
        acceptedImportCount += urls.count
        pendingImportURLs.append(contentsOf: urls)
        if isImporting {
            await withCheckedContinuation { importWaiters.append($0) }
            return
        }
        isImporting = true
        defer {
            isImporting = false
            acceptedImportCount = 0
            rejectedDuringImport = false
            let waiters = importWaiters
            importWaiters.removeAll(keepingCapacity: true)
            waiters.forEach { $0.resume() }
        }
        var failures = ImportFailureSummary()
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
        var messages = [failures.message].compactMap { $0 }
        if rejectedDuringImport { messages.append(Self.importLimitMessage) }
        if !messages.isEmpty { errorMessage = messages.joined(separator: "\n") }
    }

    private static let importLimitMessage = "Este lote não foi adicionado. Importe até 256 arquivos por vez; se uma importação já estiver em andamento, aguarde a conclusão e tente novamente."

    @discardableResult func addURL(_ text: String, web: Bool = false) -> Bool {
        do {
            let item = try web ? Wallpaper.web(text) : Wallpaper.remote(text)
            var next = state
            next.wallpapers.append(item)
            return update(next)
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func activeWallpaperID(on displayID: String) -> UUID? {
        state.effectiveAssignments(for: displays.map(\.id))[displayID]
    }

    func photoQuality(on displayID: String) -> PhotoQualityInfo? {
        guard let info = photoQualityByDisplay[displayID],
              activeWallpaperID(on: displayID) == info.wallpaperID,
              state.wallpapers.contains(where: { $0.id == info.wallpaperID && $0.kind == .image }) else { return nil }
        return info
    }

    func mediaFit(on displayID: String) -> MediaFit {
        guard let id = activeWallpaperID(on: displayID) else { return .fit }
        return state.mediaFit(for: id, on: displayID)
    }

    func setDisplayMode(_ mode: DisplayMode, sourceDisplayID: String) {
        guard canEdit else { return }
        if mode == state.displayMode { cancelPendingAssignment(.mode);return }
        cancelPendingAssignments()
        submitAssignment(.mode(mode, sourceDisplayID), scope: .mode)
    }

    /// Explicitly leave a shared scene before editing one display. The selected
    /// display is an action target, not a new source to copy over saved choices.
    /// The existing admission path restores every independent assignment/fit.
    func useIndependentDisplays(on displayID: String) {
        guard canEdit, displays.contains(where: { $0.id == displayID }) else { return }
        setDisplayMode(.independent, sourceDisplayID: displayID)
    }

    func isPreparingWallpaper(on displayID: String) -> Bool {
        pendingAssignments.keys.contains(.display(displayID)) ||
            pendingAssignments.keys.contains(.shared) || pendingAssignments.keys.contains(.mode)
    }

    private func cancelPendingAssignment(_ scope: AssignmentScope) {
        pendingAssignments.removeValue(forKey: scope)?.task.cancel()
    }

    private func cancelPendingAssignments() {
        let tasks = pendingAssignments.values.map(\.task)
        pendingAssignments.removeAll()
        tasks.forEach { $0.cancel() }
    }

    private func proposedAssignment(_ intent: AssignmentIntent) -> LibraryState? {
        guard canEdit, displays.contains(where: { $0.id == intent.displayID }) else { return nil }
        var next = state
        switch intent {
        case .wallpaper(let id, let display):
            guard state.wallpapers.contains(where: { $0.id == id }) else { return nil }
            if next.displayMode.isShared { next.mirroredWallpaperID = id }
            else { next.assignments[display] = id }
        case .mode(let mode, let sourceDisplay):
            if mode.isShared {
                let sourceID = activeWallpaperID(on: sourceDisplay)
                let source = state.wallpapers.first { $0.id == sourceID }
                next.mirroredWallpaperID = mode == .spanned && source?.supportsPanorama != true ? nil : sourceID
                next.mirroredMediaFit = mediaFit(on: sourceDisplay)
            }
            next.displayMode = mode
        }
        return next
    }

    private func commitAssignment(_ next: LibraryState, intent: AssignmentIntent) {
        guard update(next) else { return }
        let affected: [String]
        switch intent {
        case .wallpaper(_, let display): affected = next.displayMode.isShared ? displays.map(\.id) : [display]
        case .mode: affected = displays.map(\.id)
        }
        for id in affected {
            playbackErrors[id] = nil;remotePlaybackStates[id] = nil
            if case .wallpaper = intent { engine.invalidate(displayID: id) }
        }
        refreshPlayback(force: false)
    }

    private func submitAssignment(_ intent: AssignmentIntent, scope: AssignmentScope) {
        cancelPendingAssignment(scope)
        guard let next = proposedAssignment(intent) else { return }
        if !engine.requiresGIFAdmission(state: next) {
            do { try engine.validateLayout(state: next) }
            catch { errorMessage = error.localizedDescription;return }
            commitAssignment(next, intent: intent)
            return
        }
        let token = UUID(), engine = engine, store = store
        let task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard self?.pendingAssignments[scope]?.token == token,
                      let revision = self?.stateRevision else { break }
                let result: Result<Void, any Error>
                do {
                    let request: GIFAssignmentAdmissionRequest
                    do {
                        guard let next = self?.proposedAssignment(intent) else { break }
                        request = try engine.assignmentAdmissionRequest(state: next, store: store)
                    } // Drop the full catalog snapshot before suspending on file I/O.
                    try await engine.validateAssignmentsAsync(request)
                    result = .success(())
                } catch { result = .failure(error) }
                guard let self, self.pendingAssignments[scope]?.token == token, !Task.isCancelled else { break }
                // Rebase intent onto current settings/catalog/other display rather
                // than replacing newer state with an old validation snapshot.
                if self.stateRevision != revision { continue }
                self.pendingAssignments[scope] = nil
                switch result {
                case .success:
                    if let next = self.proposedAssignment(intent) { self.commitAssignment(next, intent: intent) }
                case .failure(let error):
                    if !(error is CancellationError) { self.errorMessage = error.localizedDescription }
                }
                return
            }
            if self?.pendingAssignments[scope]?.token == token { self?.pendingAssignments[scope] = nil }
        }
        pendingAssignments[scope] = PendingAssignment(token: token, intent: intent, task: task)
    }

    /// Shared action for the scenario shelf and menu. Muting always clears the
    /// real owner; enabling requires a connected video and never changes volume.
    func toggleAudioPermission(preferredDisplayID: String? = nil) {
        guard canEdit else { return }
        if state.settings.audioDisplayID != nil {
            setAudioDisplayID(nil)
            return
        }
        guard let target = preferredDisplayID ?? displays.first(where: { audioWallpaper(on: $0.id) != nil })?.id,
              displays.contains(where: { $0.id == target }), audioWallpaper(on: target) != nil else { return }
        setAudioDisplayID(target)
    }

    func setAudioDisplayID(_ id: String?) {
        guard id == nil || displays.contains(where: { $0.id == id }) else { return }
        var next = state
        next.settings.audioDisplayID = id
        if update(next) { engine.setAudioPreferences(state: state) }
    }

    /// A monitor-local sound control. Enabling transfers the single audio owner;
    /// disabling this monitor must never mute another monitor's active source.
    /// The global menu toggle intentionally retains its separate mute-all action.
    @discardableResult func setAudioEnabled(_ enabled: Bool, on displayID: String) -> Bool {
        guard canEdit, displays.contains(where: { $0.id == displayID }) else { return false }
        if enabled {
            guard audioWallpaper(on: displayID) != nil else { return false }
            if state.settings.audioDisplayID == displayID { return true }
        } else if state.settings.audioDisplayID != displayID {
            return true
        }
        var next = state
        next.settings.audioDisplayID = enabled ? displayID : nil
        guard update(next) else { return false }
        engine.setAudioPreferences(state: state)
        return true
    }

    func setHLSResolution(_ value: HLSResolution) {
        guard value != state.settings.hlsResolution else { return }
        var next = state
        next.settings.hlsResolution = value
        if update(next) { refreshPlayback(force: false) }
    }

    func setAudioVolume(_ value: Double) {
        guard value.isFinite, (0...1).contains(value), value != state.settings.audioVolume else { return }
        var next = state
        next.settings.audioVolume = value
        if update(next) { engine.setAudioPreferences(state: state) }
    }

    func audioWallpaper(on displayID: String) -> Wallpaper? {
        guard let id = activeWallpaperID(on: displayID) else { return nil }
        return state.wallpapers.first { $0.id == id && $0.kind == .video }
    }

    func setAudioGain(_ value: Double, for wallpaperID: UUID) {
        guard canEdit, value.isFinite, (0...1).contains(value), value != state.audioGain(for: wallpaperID),
              state.wallpapers.contains(where: { $0.id == wallpaperID && $0.kind == .video }) else { return }
        var next = state
        next.setAudioGain(value, for: wallpaperID)
        if update(next) { engine.setAudioPreferences(state: state) }
    }

    func applicationRestriction(for item: Wallpaper, on displayID: String) -> String? {
        guard canEdit else { return "A biblioteca está indisponível para edição." }
        guard let current = state.wallpapers.first(where: { $0.id == item.id }) else {
            return "Esta mídia não está mais na biblioteca."
        }
        guard displays.contains(where: { $0.id == displayID }) else {
            return "Selecione um monitor conectado para aplicar o fundo."
        }
        if state.displayMode == .spanned, !current.supportsPanorama {
            return "O modo panorâmico aceita fotos, GIFs locais e vídeos nativos. Fontes web não são compatíveis."
        }
        return nil
    }

    func apply(_ item: Wallpaper, to displayID: String) {
        guard canEdit, state.wallpapers.contains(where: { $0.id == item.id }),
              displays.contains(where: { $0.id == displayID }) else { return }
        cancelPendingAssignment(.mode)
        let scope: AssignmentScope = state.displayMode.isShared ? .shared : .display(displayID)
        submitAssignment(.wallpaper(item.id, displayID), scope: scope)
    }

    func setMediaFit(_ fit: MediaFit, on displayID: String) {
        guard displays.contains(where: { $0.id == displayID }),
              let wallpaperID = activeWallpaperID(on: displayID),
              let wallpaper = state.wallpapers.first(where: { $0.id == wallpaperID }) else { return }
        // Official embeds keep the provider's proportional presentation.
        if case .web = wallpaper.source { return }
        var next = state
        next.setMediaFit(fit, for: wallpaperID, on: displayID)
        if update(next) { refreshPlayback(force: false) }
    }

    func clear(displayID: String) {
        guard canEdit, displays.contains(where: { $0.id == displayID }) else { return }
        cancelPendingAssignment(.mode)
        if state.displayMode.isShared { cancelPendingAssignments() }
        else { cancelPendingAssignment(.display(displayID)) }
        var next = state
        if next.displayMode.isShared { next.mirroredWallpaperID = nil }
        else { next.assignments.removeValue(forKey: displayID) }
        if update(next) { refreshPlayback(force: false) }
    }

    @discardableResult func rename(id: UUID, title: String) -> Bool {
        guard canEdit else { return false }
        guard let index = state.wallpapers.firstIndex(where: { $0.id == id }) else {
            errorMessage = "Esta mídia não está mais na biblioteca."
            return false
        }
        do {
            let title = try MediaTitle.normalized(title)
            guard title != state.wallpapers[index].title else { return true }
            var next = state
            next.wallpapers[index].title = title
            // Title-only editing must not rebuild or restart an active renderer.
            return update(next)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func hasOtherLocalReferences(to item: Wallpaper) -> Bool {
        guard case .local = item.source else { return false }
        return state.wallpapers.contains { $0.id != item.id && $0.source == item.source }
    }

    func remove(_ item: Wallpaper) {
        guard canEdit, let current = state.wallpapers.first(where: { $0.id == item.id }) else { return }
        cancelPendingAssignments()
        var next = state
        next.remove(id: current.id)
        guard update(next) else { return }
        refreshPlayback(force: false)
        guard !hasOtherLocalReferences(to: current) else { return }
        do { try store.deleteMedia(for: current) }
        catch { errorMessage = "Item removido da biblioteca, mas a cópia de mídia não pôde ser apagada. \(error.localizedDescription)" }
    }

    func togglePause() {
        let wasPaused = isPaused
        var next = state
        next.settings.isManuallyPaused.toggle()
        if update(next) {
            if !isAutomaticallyPaused, wasPaused != isPaused { engine.setManuallyPaused(isPaused) }
            else { engine.setPaused(isPaused) }
            syncVisibleApplicationMonitor()
        }
    }

    func setPauseOnLowPower(_ value: Bool) {
        var next = state
        next.settings.pauseOnLowPower = value
        if update(next) { engine.setPaused(isPaused); syncVisibleApplicationMonitor() }
    }

    func setPauseWhenOtherAppsVisible(_ value: Bool) {
        guard value != state.settings.pauseWhenOtherAppsVisible else { return }
        var next = state
        next.settings.pauseWhenOtherAppsVisible = value
        if update(next) { syncVisibleApplicationMonitor() }
    }

    func setPauseOnMemoryPressure(_ value: Bool) {
        guard value != state.settings.pauseOnMemoryPressure else { return }
        var next = state
        next.settings.pauseOnMemoryPressure = value
        if update(next) {
            policy.memory.update(lastMemoryPressure ?? .normal, enabled: value)
            refreshPlayback(force: false)
        }
    }

    func setPauseOnThermalPressure(_ value: Bool) {
        guard value != state.settings.pauseOnThermalPressure else { return }
        var next = state
        next.settings.pauseOnThermalPressure = value
        if update(next) { refreshThermalState() }
    }

    func retryPlayback(displayID: String) {
        guard activeWallpaperID(on: displayID) != nil else { return }
        engine.invalidate(displayID: displayID)
        playbackErrors[displayID] = nil
        remotePlaybackStates[displayID] = nil
        refreshPlayback(force: false)
    }

    func refreshPlayback(force: Bool = true) {
        displays = connectedDisplays()
        let disconnected = pendingAssignments.filter { pending in
            !displays.contains(where: { $0.id == pending.value.intent.displayID })
        }.map(\.key)
        disconnected.forEach { cancelPendingAssignment($0) }
        if shouldReleaseForMemory { releaseMemoryResources(); return }
        resourcesReleasedForMemory = false
        syncVisibleApplicationMonitor()
        let effectivePhotos = state.effectiveAssignments(for: displays.map(\.id))
        photoQualityByDisplay = photoQualityByDisplay.filter { effectivePhotos[$0.key] == $0.value.wallpaperID }
        if force {
            playbackErrors = [:]
            remotePlaybackStates = [:]
        } else {
            let effective = state.effectiveAssignments(for: displays.map(\.id))
            let remoteIDs = Set(state.wallpapers.compactMap { item -> UUID? in
                if case .remote = item.source { return item.id }
                return nil
            })
            remotePlaybackStates = remotePlaybackStates.filter {
                effective[$0.key].map(remoteIDs.contains) == true
            }
            playbackErrors = playbackErrors.filter { effective[$0.key] != nil }
        }
        engine.scheduleRebuild(state: state, store: store, paused: isPaused, force: force, deferNewRenderers: shouldDeferNewRenderers, onPhotoQuality: { [weak self] id, info in
            guard let self, !self.resourcesReleasedForMemory else { return }
            if let info, self.activeWallpaperID(on: id) == info.wallpaperID {
                self.photoQualityByDisplay[id] = info
            } else { self.photoQualityByDisplay[id] = nil }
        }, onState: { [weak self] id, state in
            self?.remotePlaybackStates[id] = state
            if case .error(let message) = state { self?.playbackErrors[id] = message }
            else { self?.playbackErrors[id] = nil }
        }) { [weak self] id, message in
            self?.playbackErrors[id] = message
        }
    }
}
