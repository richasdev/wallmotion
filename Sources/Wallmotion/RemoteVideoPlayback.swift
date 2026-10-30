import AVFoundation
import Network

struct RemotePlaybackFailure: Equatable {
    let transient: Bool
    let message: String

    static func classify(_ error: Error?, httpStatus: Int? = nil) -> Self {
        if let httpStatus, (400...499).contains(httpStatus), httpStatus != 408, httpStatus != 429 {
            return Self(transient: false, message: "O servidor recusou o vídeo (HTTP \(httpStatus)). O link pode ter expirado ou sido removido. Atualize a URL e tente novamente.")
        }
        if let httpStatus, (500...599).contains(httpStatus) || httpStatus == 408 || httpStatus == 429 {
            return Self(transient: true, message: "O servidor está temporariamente indisponível.")
        }
        var current = error as NSError?
        for _ in 0..<8 {
            guard let value = current else { break }
            if value.domain == NSURLErrorDomain {
                let transientCodes = [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
                                      NSURLErrorNotConnectedToInternet, NSURLErrorCannotFindHost,
                                      NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed]
                if transientCodes.contains(value.code) {
                    return Self(transient: true, message: "A conexão com o vídeo foi interrompida.")
                }
            }
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        // Do not expose NSError descriptions: signed URLs can contain credentials.
        return Self(transient: false, message: "Não foi possível reproduzir o vídeo remoto. Verifique se a URL ainda é válida e se o formato é compatível; depois tente novamente.")
    }
}

/// Owns remote-only AVFoundation observations and connectivity. Local looping is
/// deliberately kept in WallpaperRenderer. No periodic time observers or polling.
@MainActor
final class RemoteVideoPlayback {
    private let player: AVPlayer
    private let url: URL
    private let onState: @MainActor (RemotePlaybackState) -> Void
    private var recovery: RemotePlaybackRecovery!
    private var timeObserver: NSKeyValueObservation?
    private var statusObserver: NSKeyValueObservation?
    private var notifications: [NSObjectProtocol] = []
    private var monitor: NWPathMonitor?
    private var monitorGeneration = 0
    private var itemGeneration = 0
    private var transportGeneration = 0
    private var stopped = false

    var state: RemotePlaybackState { recovery.state }

    init(player: AVPlayer, url: URL, scheduler: any RecoveryScheduling = RecoveryScheduler(), onState: @escaping @MainActor (RemotePlaybackState) -> Void) {
        self.player = player
        self.url = url
        self.onState = onState
        recovery = RemotePlaybackRecovery(scheduler: scheduler, retry: { [weak self] in self?.replaceItem() }, onState: { [weak self] state in
            guard let self else { return }
            if case .error = state {
                self.player.pause()
                self.itemGeneration += 1
                self.removeItemObservers()
                self.player.replaceCurrentItem(with: nil)
                self.stopMonitoring()
            }
            self.onState(state)
        })
        timeObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.readTransport() }
        }
        replaceItem()
    }

    func setPaused(_ value: Bool) {
        guard !stopped else { return }
        // Invalidates seek completions even if pause is followed rapidly by resume.
        if value { transportGeneration += 1 }
        recovery.setPaused(value)
        if value {
            player.pause()
            stopMonitoring()
        } else if recovery.canPlay {
            startMonitoring()
            player.play()
            readTransport()
        }
    }

    private func replaceItem() {
        guard !stopped else { return }
        removeItemObservers()
        itemGeneration += 1
        let ticket = itemGeneration
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped, self.itemGeneration == ticket else { return }
                if self.player.currentItem?.status == .failed { self.readFailure() }
                else { self.readTransport() }
            }
        }
        observe(.AVPlayerItemPlaybackStalled, item: item, ticket: ticket) { owner in
            owner.recovery.waiting(ready: true)
        }
        notifications.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
            Task { @MainActor [weak self] in
                guard let self, !self.stopped, self.itemGeneration == ticket else { return }
                self.readFailure(error: error)
            }
        })
        observe(.AVPlayerItemDidPlayToEndTime, item: item, ticket: ticket) { owner in
            let transportTicket = owner.transportGeneration
            owner.player.seek(to: .zero) { [weak owner] finished in
                Task { @MainActor [weak owner] in
                    guard let owner, !owner.stopped, owner.itemGeneration == ticket,
                          owner.transportGeneration == transportTicket, owner.recovery.canPlay else { return }
                    if finished { owner.player.play() }
                    else { owner.recovery.failed(transient: false, message: "Não foi possível reiniciar o vídeo remoto. Tente novamente.") }
                }
            }
        }
        if recovery.canPlay { player.play() }
    }

    private func observe(_ name: Notification.Name, item: AVPlayerItem, ticket: Int,
                         action: @escaping @MainActor (RemoteVideoPlayback) -> Void) {
        notifications.append(NotificationCenter.default.addObserver(forName: name, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped, self.itemGeneration == ticket else { return }
                action(self)
            }
        })
    }

    private func readTransport() {
        guard !stopped, recovery.canPlay else { return }
        if player.currentItem?.status == .failed { readFailure(); return }
        switch player.timeControlStatus {
        case .playing: recovery.playing()
        case .waitingToPlayAtSpecifiedRate:
            recovery.waiting(ready: player.currentItem?.status == .readyToPlay)
        case .paused: break // Policy owns pause; a seek/end is not a manual pause.
        @unknown default: break
        }
    }

    private func readFailure(error: Error? = nil) {
        guard !stopped else { return }
        let item = player.currentItem
        let failure = RemotePlaybackFailure.classify(error ?? item?.error, httpStatus: item?.errorLog()?.events.last?.errorStatusCode)
        recovery.failed(transient: failure.transient, message: failure.message)
    }

    private func startMonitoring() {
        guard monitor == nil else { return }
        let watcher = NWPathMonitor()
        monitor = watcher
        let ticket = monitorGeneration
        watcher.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self, !self.stopped, self.monitorGeneration == ticket else { return }
                self.recovery.connectivityChanged(available: available)
            }
        }
        watcher.start(queue: DispatchQueue(label: "com.wallmotion.remote-connectivity", qos: .utility))
    }

    private func stopMonitoring() {
        monitorGeneration += 1
        monitor?.pathUpdateHandler = nil
        monitor?.cancel()
        monitor = nil
    }

    private func removeItemObservers() {
        statusObserver?.invalidate()
        statusObserver = nil
        notifications.forEach { NotificationCenter.default.removeObserver($0) }
        notifications.removeAll()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        itemGeneration += 1
        recovery.stop()
        stopMonitoring()
        timeObserver?.invalidate()
        timeObserver = nil
        removeItemObservers()
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}
