import AppKit
import AVFoundation
import WallmotionCore

/// One native transport for a shared selection. Each display retains its own
/// AVPlayerLayer and native color handling; no CPU frame copies or custom shader.
@MainActor
final class SharedVideoPlayback {
    let wallpaperID: UUID
    let url: URL
    let player: AVPlayer
    private var looper: AVPlayerLooper?
    private var remote: RemoteVideoPlayback?
    private var transportObserver: NSKeyValueObservation?
    private var itemObserver: NSKeyValueObservation?
    private var statusObserver: NSKeyValueObservation?
    private var loopObserver: NSKeyValueObservation?
    private var readinessTask: Task<Void, Never>?
    private var readinessGeneration = UUID()
    private var restartToken: UUID?
    private var failed = false
    private var stopped = false
    private var applying = false
    private var needsApply = false
    private let layerReady: @MainActor (AVPlayerLayer) -> Bool
    private let readinessDelay: Duration
    private let onIncompatible: @MainActor () -> Void
    private var latestRemoteState: RemotePlaybackState?

    private struct Request: Equatable {
        var playing = false
        var visible = false
        var volume = 0.0
    }
    private final class Subscriber {
        weak var layer: AVPlayerLayer?
        var request = Request()
        let refresh: @MainActor () -> Void
        let state: @MainActor (RemotePlaybackState) -> Void
        let error: @MainActor (String) -> Void
        var readinessObserver: NSKeyValueObservation?
        init(layer: AVPlayerLayer, refresh: @escaping @MainActor () -> Void,
             state: @escaping @MainActor (RemotePlaybackState) -> Void, error: @escaping @MainActor (String) -> Void) {
            self.layer = layer;self.refresh = refresh;self.state = state;self.error = error
        }
    }
    private var subscribers: [UUID: Subscriber] = [:]
    var subscriberCount: Int { subscribers.count }
    var remoteState: RemotePlaybackState? { latestRemoteState }
    var hasReadinessTask: Bool { readinessTask != nil }
    var hasFailed: Bool {
        if failed || stopped || player.currentItem?.status == .failed { return true }
        if let state = latestRemoteState, case .error = state { return true }
        return false
    }
    var canReuse: Bool { !hasFailed }
    var canPlay: Bool { !hasFailed && restartToken == nil && (remote?.canPlay ?? true) }

    init(wallpaperID: UUID, url: URL, hlsResolution: HLSResolution = .automatic,
         scheduler: any RecoveryScheduling = RecoveryScheduler(),
         makePlayer: @MainActor (AVPlayerItem, Bool) -> AVPlayer = { item, local in
             local ? AVQueuePlayer() : AVPlayer(playerItem: item)
         },
         layerReady: @escaping @MainActor (AVPlayerLayer) -> Bool = { $0.isReadyForDisplay },
         readinessDelay: Duration = .seconds(2), onIncompatible: @escaping @MainActor () -> Void) throws {
        if url.isFileURL, !FileManager.default.isReadableFile(atPath: url.path) { throw RendererError.missingFile }
        self.wallpaperID = wallpaperID;self.url = url;self.layerReady = layerReady
        self.readinessDelay = readinessDelay;self.onIncompatible = onIncompatible
        let item = AVPlayerItem(url: url)
        player = makePlayer(item, url.isFileURL)
        player.volume = 0;player.isMuted = true;player.preventsDisplaySleepDuringVideoPlayback = false
        player.automaticallyWaitsToMinimizeStalling = true
        if let queue = player as? AVQueuePlayer {
            looper = AVPlayerLooper(player: queue, templateItem: item)
            loopObserver = looper?.observe(\.status, options: [.new]) { [weak self] looper, _ in
                guard looper.status == .failed else { return }
                Task { @MainActor [weak self] in self?.reportFailure() }
            }
            itemObserver = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.observeItem() }
            }
        } else {
            player.actionAtItemEnd = .pause
            remote = RemoteVideoPlayback(player: player, url: url, hlsResolution: hlsResolution, scheduler: scheduler,
                onPlaybackRequested: { [weak self] in self?.apply();self?.refreshSubscribers() },
                onRestart: { [weak self] in self?.restart() }, onState: { [weak self] state in
                    guard let self else { return }
                    self.latestRemoteState = state
                    for entry in Array(self.subscribers.values) { entry.state(state) }
                    if case .error(let message) = state {
                        for entry in Array(self.subscribers.values) { entry.error(message) }
                    }
                })
        }
        transportObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.scheduleReadinessCheck();self?.refreshSubscribers() }
        }
    }

    func subscribe(layer: AVPlayerLayer, refresh: @escaping @MainActor () -> Void,
                   state: @escaping @MainActor (RemotePlaybackState) -> Void,
                   error: @escaping @MainActor (String) -> Void) -> UUID {
        let id = UUID(), entry = Subscriber(layer: layer, refresh: refresh, state: state, error: error)
        subscribers[id] = entry
        entry.readinessObserver = layer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.scheduleReadinessCheck() }
        }
        if let latestRemoteState { state(latestRemoteState) }
        return id
    }
    func update(_ id: UUID, playing: Bool, visible: Bool, volume: Double) {
        guard !stopped, let entry = subscribers[id] else { return }
        let request = Request(playing: playing, visible: visible, volume: volume.isFinite ? min(1, max(0, volume)) : 0)
        guard request != entry.request else { return }
        entry.request = request
        entry.layer?.isHidden = !visible
        apply()
    }
    func unsubscribe(_ id: UUID) {
        subscribers.removeValue(forKey: id)?.readinessObserver?.invalidate()
        if subscribers.isEmpty { stop() }
        else { apply() }
    }
    func setHLSResolution(_ value: HLSResolution) { remote?.setHLSResolution(value) }

    private func apply() {
        guard !stopped else { return }
        if applying { needsApply = true;return }
        applying = true
        defer { applying = false;if needsApply { needsApply = false;apply() } }
        let playing = subscribers.values.contains { $0.request.playing && $0.request.visible }
        remote?.setPaused(!playing)
        let outputs = subscribers.values.filter { $0.request.playing && $0.request.visible && $0.request.volume > 0 }
        // Multiple simultaneous owners fail closed; normal transfers silence the
        // old owner before enabling another. Never mix duplicate source audio.
        let volume = canPlay && playing && outputs.count == 1 ? outputs[0].request.volume : 0
        player.volume = Float(volume);player.isMuted = volume <= 0
        if playing && canPlay {
            if player.rate == 0 || player.timeControlStatus == .paused { player.play() }
        } else if player.rate != 0 || player.timeControlStatus != .paused { player.pause() }
        scheduleReadinessCheck()
    }
    private func refreshSubscribers() {
        for callback in subscribers.values.map(\.refresh) { callback() }
    }
    private func cancelReadinessCheck() {
        readinessGeneration = UUID();readinessTask?.cancel();readinessTask = nil
    }
    private func scheduleReadinessCheck() {
        guard !hasFailed, player.timeControlStatus == .playing else {
            cancelReadinessCheck();return
        }
        let active = subscribers.values.filter { $0.request.playing && $0.request.visible }
        guard active.count > 1, active.contains(where: { $0.layer.map { !layerReady($0) } ?? true }) else {
            cancelReadinessCheck();return
        }
        guard readinessTask == nil else { return }
        let generation = readinessGeneration
        readinessTask = Task { @MainActor [weak self] in
            guard let delay = self?.readinessDelay else { return }
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, !Task.isCancelled, self.readinessGeneration == generation else { return }
            self.readinessTask = nil
            guard !self.hasFailed, self.player.timeControlStatus == .playing else { return }
            let active = self.subscribers.values.filter { $0.request.playing && $0.request.visible }
            guard active.count > 1, active.contains(where: { $0.layer.map { !self.layerReady($0) } ?? true }) else { return }
            self.failed = true
            self.apply();self.refreshSubscribers();self.onIncompatible()
        }
    }
    private func observeItem() {
        guard !stopped else { return }
        statusObserver?.invalidate()
        statusObserver = player.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor [weak self] in self?.reportFailure() }
        }
    }
    private func reportFailure() {
        guard !failed, !stopped else { return }
        failed = true;restartToken = nil;apply();refreshSubscribers()
        for entry in Array(subscribers.values) { entry.error("Não foi possível reproduzir este vídeo. Tente recarregar o fundo.") }
    }
    private func restart() {
        guard !hasFailed, restartToken == nil, let item = player.currentItem else { return }
        let token = UUID();restartToken = token;apply();refreshSubscribers()
        player.seek(to: .zero) { [weak self, weak item] finished in
            Task { @MainActor [weak self, weak item] in
                guard let self, self.restartToken == token, !self.stopped else { return }
                self.restartToken = nil
                guard self.player.currentItem === item else { self.apply();self.refreshSubscribers();return }
                if !finished { self.reportFailure();return }
                self.apply();self.refreshSubscribers()
            }
        }
    }
    func stop() {
        guard !stopped else { return }
        stopped = true;restartToken = nil
        cancelReadinessCheck()
        player.isMuted = true;player.volume = 0;player.pause()
        remote?.stop();remote = nil
        looper?.disableLooping();looper = nil
        for observer in [transportObserver,itemObserver,statusObserver,loopObserver] { observer?.invalidate() }
        transportObserver = nil;itemObserver = nil;statusObserver = nil;loopObserver = nil
        for entry in subscribers.values { entry.readinessObserver?.invalidate() }
        subscribers.removeAll()
        player.replaceCurrentItem(with: nil);(player as? AVQueuePlayer)?.removeAllItems()
    }
}
