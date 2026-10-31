import AppKit
import AVFoundation
import QuartzCore
import WallmotionCore

struct Display: Identifiable, Equatable {
    let id: String
    let name: String

    @MainActor static func identify(_ screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        if let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, uuid) as String
        }
        return "display-\(number.uint32Value)"
    }
}

/// A connected display snapshot. Tests may use separate logical IDs on one
/// physical screen to exercise multi-display reconciliation deterministically.
struct DesktopTarget {
    let id: String
    let screen: NSScreen
    let frame: CGRect
    let backingScale: CGFloat

    @MainActor init(id: String, screen: NSScreen, frame: CGRect? = nil, backingScale: CGFloat? = nil) {
        self.id = id
        self.screen = screen
        self.frame = frame ?? screen.frame
        self.backingScale = backingScale ?? screen.backingScaleFactor
    }

    @MainActor static var connected: [Self] {
        NSScreen.screens.compactMap { screen in
            Display.identify(screen).map { Self(id: $0, screen: screen) }
        }
    }
}

@MainActor
final class DesktopWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(screen: NSScreen, view: NSView, frame: CGRect? = nil) {
        let frame = frame ?? screen.frame
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isReleasedWhenClosed = false
        contentView = view
        setFrame(frame, display: true)
    }
}

@MainActor
final class ImageSurface: NSView {
    let imageView: NSImageView
    let mediaFit: MediaFit
    let panoramaFrame: CGRect?
    let sourcePointSize: CGSize?
    fileprivate weak var gifPlayback: SharedGIFPlayback?
    fileprivate var gifSubscriber: UUID?
    var gifIsPlaying: Bool { gifSubscriber.map { gifPlayback?.isActive($0) == true } ?? false }

    init(image: NSImage, mediaFit: MediaFit, panoramaFrame: CGRect? = nil, sourcePointSize: CGSize? = nil) {
        imageView = NSImageView(image: image)
        self.mediaFit = mediaFit
        self.panoramaFrame = panoramaFrame
        self.sourcePointSize = sourcePointSize
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        imageView.imageScaling = .scaleAxesIndependently
        imageView.animates = false
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("Not supported") }

    override func layout() {
        super.layout()
        imageView.frame = panoramaFrame ?? mediaFit.frame(for: sourcePointSize ?? imageView.image?.size ?? .zero, in: bounds)
    }
}

@MainActor
final class VideoSurface: NSView {
    let playerLayer = AVPlayerLayer()
    private let mediaFit: MediaFit
    private var itemObserver: NSKeyValueObservation?
    private var sizeObserver: NSKeyValueObservation?
    private var presentationSize: CGSize = .zero

    private func observeSize() {
        sizeObserver?.invalidate()
        presentationSize = playerLayer.player?.currentItem?.presentationSize ?? .zero
        sizeObserver = playerLayer.player?.currentItem?.observe(\.presentationSize, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.presentationSize = self.playerLayer.player?.currentItem?.presentationSize ?? .zero
                self.needsLayout = true
            }
        }
        needsLayout = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    init(player: AVPlayer, mediaFit: MediaFit = .fit) {
        self.mediaFit = mediaFit
        super.init(frame: .zero)
        wantsLayer = true
        playerLayer.player = player
        playerLayer.videoGravity = mediaFit == .stretch ? .resize : (mediaFit == .fill ? .resizeAspectFill : .resizeAspect)
        itemObserver = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.observeSize() }
        }
        layer?.masksToBounds = true
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError("Not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = mediaFit == .center
            ? mediaFit.frame(for: presentationSize, in: bounds, backingScale: window?.backingScaleFactor ?? 1)
            : bounds
        CATransaction.commit()
    }
}

@MainActor
final class WallpaperRenderer {
    let window: DesktopWindow
    private(set) var photoQuality: PhotoQualityInfo?
    private var webRenderer: WebWallpaperRenderer?
    var isWebPlaying: Bool { webRenderer?.isPlaying == true }
    private let player: AVPlayer?
    private let imageView: NSImageView?
    private var gifPlayback: SharedGIFPlayback?
    private var gifSubscriber: UUID?
    var gifIdentity: GIFFileIdentity? { gifPlayback?.asset.identity }
    private var looper: AVPlayerLooper?
    private var statusObserver: NSKeyValueObservation?
    private var currentItemObserver: NSKeyValueObservation?
    private var audioTransportObserver: NSKeyValueObservation?
    private let audioClock: @MainActor () -> Double
    private let audioIsPlaying: @MainActor (AVPlayer) -> Bool
    private struct NativeAudioFade {
        var ramp: AudioRamp
        let fadingOut: Bool
        var beganAt: Double?
    }
    private var nativeAudioFade: NativeAudioFade?
    private var audioFadeTask: Task<Void, Never>?
    private var audioFadeGeneration = UUID()
    private var applyingPlaybackState = false
    private var playbackStateNeedsApply = false
    var hasAudioFadeTick: Bool { audioFadeTask != nil }
    var isWaitingForAudioPlayback: Bool { nativeAudioFade != nil && nativeAudioFade?.beganAt == nil }
    private var loopObserver: NSKeyValueObservation?
    private var remotePlayback: RemoteVideoPlayback?
    var remotePlaybackState: RemotePlaybackState? { remotePlayback?.state }
    private var failureObserver: NSObjectProtocol?
    private var occlusionObserver: NSObjectProtocol?
    private(set) var playbackState = RendererPlaybackState()
    private(set) var audioEnabled = false
    private(set) var audioVolume: Double = 1
    private let isWindowVisible: @MainActor (NSWindow) -> Bool
    private let seekToStart: @MainActor (AVPlayer, @escaping @MainActor @Sendable (Bool) -> Void) -> Void

    init(wallpaper: Wallpaper, url: URL, screen: NSScreen, mediaFit: MediaFit = .fit, preparedPhoto: DecodedPhoto? = nil, preparedGIF: SharedGIFPlayback? = nil, onGIFChanged: @escaping @MainActor () -> Void = {}, targetFrame: CGRect? = nil, targetScale: CGFloat? = nil, panorama: PanoramaLayout? = nil, webDocument: String? = nil, hlsResolution: HLSResolution = .automatic,
         isWindowVisible: @escaping @MainActor (NSWindow) -> Bool = { $0.occlusionState.contains(.visible) },
         makePlayer: @MainActor (AVPlayerItem, Bool) -> AVPlayer = { item, local in
             local ? AVQueuePlayer() : AVPlayer(playerItem: item)
         },
         seekToStart: @escaping @MainActor (AVPlayer, @escaping @MainActor @Sendable (Bool) -> Void) -> Void = { player, completion in
             player.seek(to: .zero) { finished in
                 Task { @MainActor in completion(finished) }
             }
         },
         recoveryScheduler: any RecoveryScheduling = RecoveryScheduler(),
         audioClock: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime },
         audioIsPlaying: @escaping @MainActor (AVPlayer) -> Bool = { $0.timeControlStatus == .playing },
         onState: @escaping @MainActor (RemotePlaybackState) -> Void = { _ in },
         onError: @escaping @MainActor (String) -> Void) throws {
        let frame = targetFrame ?? screen.frame
        let scale = targetScale ?? screen.backingScaleFactor
        let photoScale = panorama?.referenceScale ?? scale
        let viewport = panorama?.pixelSize ?? CGSize(width: frame.width * scale, height: frame.height * scale)
        self.isWindowVisible = isWindowVisible
        self.audioClock = audioClock
        self.audioIsPlaying = audioIsPlaying
        self.seekToStart = seekToStart
        if case .web(let embed) = wallpaper.source {
            let renderer = try WebWallpaperRenderer(embed: embed, onError: onError, document: webDocument)
            webRenderer = renderer
            player = nil
            imageView = nil
            window = DesktopWindow(screen: screen, view: renderer.surface, frame: frame)
        } else if wallpaper.kind == .gif {
            let playback: SharedGIFPlayback
            if let preparedGIF { playback = preparedGIF }
            else {
                // Synchronous entry is retained for coordinator unit fixtures.
                // Production scheduleRebuild always supplies a worker-prepared GIF.
                let animation = try GIFAnimation(url: url)
                guard let identity = animation.sourceIdentity else { throw RendererError.unreadableImage }
                playback = try SharedGIFPlayback.playback(for: PreparedGIF(animation: animation, identity: identity))
            }
            let pointSize = CGSize(width: Double(playback.asset.animation.width)/scale, height: Double(playback.asset.animation.height)/scale)
            let view = ImageSurface(image: playback.currentImage, mediaFit: mediaFit, sourcePointSize: pointSize)
            imageView = view.imageView; player = nil; gifPlayback = playback
            window = DesktopWindow(screen: screen, view: view, frame: frame)
            gifSubscriber = playback.subscribe(url: url, image: { [weak view] image in
                view?.imageView.image = image; view?.needsLayout = true
            }, changed: onGIFChanged)
            view.gifPlayback = playback; view.gifSubscriber = gifSubscriber
        } else if wallpaper.kind == .image {
            let decoded: DecodedPhoto
            do {
                decoded = try preparedPhoto ?? PhotoDecodeWorker.decodeImage(PhotoDecodeRequest(
                    url: url, mediaFit: mediaFit,
                    viewportWidth: viewport.width, viewportHeight: viewport.height))
            } catch PhotoDecodingError.unreadable { throw RendererError.unreadableImage }
            catch PhotoDecodingError.overBudget { throw RendererError.photoTooLarge }
            photoQuality = PhotoQualityInfo(wallpaperID: wallpaper.id, sourceSize: decoded.sourceSize,
                bitmapWidth: decoded.image.width, bitmapHeight: decoded.image.height, isPanorama: panorama != nil)
            let image = NSImage(cgImage: decoded.image, size: NSSize(
                width: decoded.sourceSize.width / photoScale,
                height: decoded.sourceSize.height / photoScale))
            let panoramaFrame = panorama.map {
                $0.imageFrame(sourcePixels: CGSize(width: image.size.width * photoScale, height: image.size.height * photoScale), fit: mediaFit, on: frame)
            }
            let view = ImageSurface(image: image, mediaFit: mediaFit, panoramaFrame: panoramaFrame)
            imageView = view.imageView
            player = nil
            window = DesktopWindow(screen: screen, view: view, frame: frame)
        } else {
            if url.isFileURL, !FileManager.default.isReadableFile(atPath: url.path) { throw RendererError.missingFile }
            let item = AVPlayerItem(url: url)
            let mediaPlayer = makePlayer(item, url.isFileURL)
            mediaPlayer.isMuted = true
            mediaPlayer.preventsDisplaySleepDuringVideoPlayback = false
            mediaPlayer.automaticallyWaitsToMinimizeStalling = true
            player = mediaPlayer
            imageView = nil
            window = DesktopWindow(screen: screen, view: VideoSurface(player: mediaPlayer, mediaFit: mediaFit), frame: frame)
            if let queue = mediaPlayer as? AVQueuePlayer {
                looper = AVPlayerLooper(player: queue, templateItem: item)
                loopObserver = looper?.observe(\.status, options: [.initial, .new]) { looper, _ in
                    guard looper.status == .failed else { return }
                    let message = looper.error?.localizedDescription ?? "Não foi possível repetir o vídeo."
                    Task { @MainActor in onError(message) }
                }
                // Looper copies have their own decoder status.
                currentItemObserver = mediaPlayer.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, _ in
                    Task { @MainActor [weak self] in self?.observeCurrentItem(onError: onError) }
                }
            } else {
                mediaPlayer.actionAtItemEnd = .pause
                remotePlayback = RemoteVideoPlayback(player: mediaPlayer, url: url, hlsResolution: hlsResolution, scheduler: recoveryScheduler,
                    onPlaybackRequested: { [weak self] in self?.applyPlaybackState() },
                    onRestart: { [weak self] in self?.restartRemotePlayback(onError: onError) },
                    onState: { state in
                        onState(state)
                        if case .error(let message) = state { onError(message) }
                    })
            }
        }

        if let player {
            audioTransportObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.applyPlaybackState() }
            }
        }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.playbackState.isStopped else { return }
                self.applyPlaybackState()
            }
        }
        // Sample initial visibility even if AppKit has not posted a transition.
        applyPlaybackState()
    }

    private func restartRemotePlayback(onError: @escaping @MainActor (String) -> Void) {
        guard let player, let token = playbackState.beginRestart() else { return }
        applyPlaybackState()
        seekToStart(player) { [weak self] finished in
            guard let self, self.playbackState.completeRestart(token, finished: finished) else { return }
            self.applyPlaybackState()
            if !finished { onError("Não foi possível reiniciar o vídeo remoto. Tente recarregar a reprodução.") }
        }
    }

    /// The only path that starts/stops transport or animation. Resample on every
    /// request, since policy/rebuild/seek may run without a new occlusion event.
    private var audioTransportPlaying: Bool { player.map(audioIsPlaying) ?? false }

    private var nativeAudioFailed: Bool {
        if player?.currentItem?.status == .failed { return true }
        if let state = remotePlayback?.state, case .error = state { return true }
        return false
    }

    private func cancelAudioFade() {
        audioFadeGeneration = UUID()
        audioFadeTask?.cancel();audioFadeTask = nil;nativeAudioFade = nil
    }

    private func audioFadeValue(at now: Double) -> Double {
        guard let fade = nativeAudioFade else { return playbackState.shouldPlay ? 1 : 0 }
        guard let began = fade.beganAt else { return fade.ramp.start }
        return fade.ramp.value(at: max(0, now - began))
    }

    private func scheduleAudioFadeTick() {
        guard audioFadeTask == nil, nativeAudioFade?.beganAt != nil else { return }
        let generation = audioFadeGeneration
        audioFadeTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            guard let self, self.audioFadeGeneration == generation else { return }
            self.audioFadeTask = nil
            self.applyPlaybackState()
        }
    }

    /// Also used by deterministic clock fixtures. No persistent periodic timer.
    func refreshAudioTransition() { applyPlaybackState() }

    private func applyPlaybackState() {
        if applyingPlaybackState { playbackStateNeedsApply = true;return }
        applyingPlaybackState = true
        defer {
            applyingPlaybackState = false
            if playbackStateNeedsApply { playbackStateNeedsApply = false;applyPlaybackState() }
        }
        playbackState.setVisible(isWindowVisible(window))
        if playbackState.isStopped || !playbackState.isVisible || playbackState.pendingRestart != nil ||
            !audioEnabled || audioVolume <= 0 || nativeAudioFailed { cancelAudioFade() }

        var wantsTransport = playbackState.shouldPlay || nativeAudioFade?.fadingOut == true
        remotePlayback?.setPaused(!wantsTransport)
        if nativeAudioFailed {
            cancelAudioFade();wantsTransport = playbackState.shouldPlay
        }
        let canPlay = !nativeAudioFailed && (remotePlayback?.canPlay ?? true)
        let now = audioClock()
        if var fade = nativeAudioFade {
            if fade.fadingOut, !canPlay || !audioTransportPlaying {
                cancelAudioFade();wantsTransport = playbackState.shouldPlay
            } else if !fade.fadingOut {
                if canPlay, audioTransportPlaying {
                    if fade.beganAt == nil { fade.beganAt = now;nativeAudioFade = fade }
                } else if fade.beganAt != nil || fade.ramp.start > 0 {
                    // Freeze without ticks while buffering; resume from zero once
                    // transport really plays, rather than spending the fade in silence.
                    audioFadeTask?.cancel();audioFadeTask = nil
                    fade.ramp = AudioRamp(start: 0, target: 1);fade.beganAt = nil
                    nativeAudioFade = fade
                }
            }
            if let current = nativeAudioFade, let began = current.beganAt,
               current.ramp.isComplete(at: max(0, now - began)) {
                cancelAudioFade();wantsTransport = playbackState.shouldPlay
            }
        }
        let factor = nativeAudioFade == nil ? (playbackState.shouldPlay ? 1.0 : 0) : audioFadeValue(at: now)
        let audible = audioEnabled && audioVolume > 0 && wantsTransport && canPlay
        let outputVolume = audible ? audioVolume * factor : 0
        player?.volume = Float(outputVolume)
        player?.isMuted = !audible || outputVolume <= 0
        if let webRenderer {
            if webRenderer.hasManualAudioTransition, playbackState.isVisible, !playbackState.isStopped,
               audioEnabled, audioVolume > 0 {
                webRenderer.setAudioPolicy(enabled: audioEnabled, volume: audioVolume)
            } else {
                webRenderer.setAudioPolicy(enabled: audible, volume: outputVolume)
                webRenderer.setPaused(!playbackState.shouldPlay)
            }
        }
        if let gifSubscriber { gifPlayback?.setActive(playbackState.shouldPlay, subscriber: gifSubscriber) }
        remotePlayback?.setPaused(!wantsTransport)
        if let player {
            if wantsTransport && canPlay {
                if player.rate == 0 || player.timeControlStatus == .paused { player.play() }
            } else if player.rate != 0 || player.timeControlStatus != .paused { player.pause() }
        }
        scheduleAudioFadeTick()
    }

    func setManuallyPaused(_ value: Bool) {
        guard !playbackState.isStopped else { return }
        playbackState.setVisible(isWindowVisible(window))
        if value == playbackState.isPaused { applyPlaybackState();return }
        let current = audioFadeValue(at: audioClock())
        cancelAudioFade()
        playbackState.setPaused(value)
        window.orderBack(nil)
        if let webRenderer, playbackState.isVisible, audioEnabled, audioVolume > 0 {
            webRenderer.setManuallyPaused(value, enabled: audioEnabled, volume: audioVolume)
            return
        }
        if player != nil, playbackState.isVisible, playbackState.pendingRestart == nil,
           audioEnabled, audioVolume > 0, !nativeAudioFailed {
            if !value || (current > 0 && audioTransportPlaying) {
                nativeAudioFade = NativeAudioFade(ramp: AudioRamp(start: current, target: value ? 0 : 1),
                    fadingOut: value, beganAt: value ? audioClock() : nil)
            }
        }
        applyPlaybackState()
    }

    private func observeCurrentItem(onError: @escaping @MainActor (String) -> Void) {
        guard !playbackState.isStopped else { return }
        statusObserver?.invalidate()
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = nil
        guard let item = player?.currentItem else { return }
        statusObserver = item.observe(\.status, options: [.initial, .new]) { item, _ in
                guard item.status == .failed else { return }
                let message = item.error?.localizedDescription ?? "Não foi possível reproduzir esta mídia."
                Task { @MainActor in onError(message) }
            }
            failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { _ in
                Task { @MainActor in onError("A reprodução falhou. Confira a rede e o formato do vídeo.") }
            }
    }

    func setHLSResolution(_ value: HLSResolution) {
        guard !playbackState.isStopped else { return }
        remotePlayback?.setHLSResolution(value)
    }

    func setAudioEnabled(_ enabled: Bool) {
        setAudioPolicy(enabled: enabled, volume: audioVolume)
    }

    func setAudioPolicy(enabled: Bool, volume: Double) {
        guard !playbackState.isStopped else { return }
        let nextVolume = volume.isFinite ? min(1, max(0, volume)) : 0
        if audioEnabled != enabled || audioVolume != nextVolume {
            cancelAudioFade();webRenderer?.cancelManualAudioTransition()
        }
        audioEnabled = enabled
        audioVolume = nextVolume
        applyPlaybackState()
    }

    func setPaused(_ value: Bool) {
        guard !playbackState.isStopped else { return }
        cancelAudioFade();webRenderer?.cancelManualAudioTransition()
        playbackState.setPaused(value)
        window.orderBack(nil)
        applyPlaybackState()
    }

    func stop() {
        guard !playbackState.isStopped else { return }
        cancelAudioFade()
        playbackState.stop()
        applyPlaybackState()
        webRenderer?.stop()
        webRenderer = nil
        statusObserver?.invalidate()
        statusObserver = nil
        currentItemObserver?.invalidate()
        currentItemObserver = nil
        audioTransportObserver?.invalidate();audioTransportObserver = nil
        loopObserver?.invalidate()
        loopObserver = nil
        remotePlayback?.stop()
        remotePlayback = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = nil
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        looper?.disableLooping()
        looper = nil
        player?.replaceCurrentItem(with: nil)
        (player as? AVQueuePlayer)?.removeAllItems()
        if let surface = window.contentView as? VideoSurface {
            surface.playerLayer.player = nil
            surface.playerLayer.removeFromSuperlayer()
        }
        if let gifSubscriber { gifPlayback?.unsubscribe(gifSubscriber) }
        gifSubscriber = nil
        gifPlayback = nil
        imageView?.image = nil
        window.contentView = nil
        window.orderOut(nil)
        window.close()
    }
}

enum RendererError: LocalizedError {
    case unreadableImage, missingFile, photoTooLarge
    var errorDescription: String? {
        switch self {
        case .unreadableImage: "Não foi possível decodificar a imagem ou GIF."
        case .photoTooLarge: "A foto decodificada excedeu o limite de memória. Use uma cópia com resolução menor."
        case .missingFile: "O vídeo importado não está mais disponível. Importe o arquivo novamente."
        }
    }
}

@MainActor
final class DesktopCoordinator {
    private struct Entry {
        let wallpaperID: UUID
        let frame: CGRect
        let mediaFit: MediaFit
        let backingScale: CGFloat
        let panorama: PanoramaLayout?
        let token: UUID
        let renderer: WallpaperRenderer
    }
    private var renderers: [String: Entry] = [:]
    private var pendingReloads: Set<String> = []
    private let photos: PhotoPreparation
    private let gifs: SharedGIFPreparation
    private let gifAdmissions: GIFAdmissionWorker
    private var gifMetadata: [GIFFileIdentity: GIFMetadata] = [:]
    private var reschedule: (@MainActor () -> Void)?
    private var rebuildGeneration = UUID()
    private var latestPaused = true
    private var latestPauseIsManual = false
    private var audioConfiguration = AudioConfiguration()
    private struct TargetGeometry: Equatable {
        let id: String
        let frame: CGRect
        let scale: CGFloat
    }

    private func geometry(_ targets: [DesktopTarget]) -> [TargetGeometry] {
        targets.map { TargetGeometry(id: $0.id, frame: $0.frame, scale: $0.backingScale) }
    }
    private(set) var gifBudget: GIFPlaybackBudget
    private let targets: @MainActor () -> [DesktopTarget]
    private let isWindowVisible: @MainActor (NSWindow) -> Bool
    private let webDocument: String?

    init(gifBudgetLimit: UInt64 = GIFPlaybackBudget.defaultLimit,
         photoBatchBudgetLimit: Int = PhotoPreparation.maximumRetainedBytes,
         targets: @escaping @MainActor () -> [DesktopTarget] = { DesktopTarget.connected },
         isWindowVisible: @escaping @MainActor (NSWindow) -> Bool = { $0.occlusionState.contains(.visible) },
         webDocument: String? = nil,
         photoDecoder: @escaping PhotoPreparation.Decode = PhotoDecodeWorker.prepare,
         gifWorker: GIFDecodeWorker = .shared) {
        photos = PhotoPreparation(maximumRetainedBytes: photoBatchBudgetLimit, decode: photoDecoder)
        gifs = SharedGIFPreparation(worker: gifWorker, limit: gifBudgetLimit)
        gifAdmissions = gifWorker.admissionWorker
        gifBudget = GIFPlaybackBudget(limit: gifBudgetLimit)
        self.targets = targets
        self.isWindowVisible = isWindowVisible
        self.webDocument = webDocument
    }

    private func withCurrentAudio(_ state: LibraryState) -> LibraryState {
        var next = state
        next.settings.audioDisplayID = audioConfiguration.displayID
        next.settings.audioVolume = audioConfiguration.masterVolume
        next.audioGains = audioConfiguration.gains
        return next
    }

    // Synchronous fixture helper. Production UI builds a small admission request
    // and awaits validateAssignmentsAsync to keep content parsing off MainActor.
    func validateAssignments(state: LibraryState, store: LibraryStore) throws {
        try validatePanorama(state: state, targets: targets())
        _ = try proposedBudget(state: state, store: store, connected: targets().map(\.id))
    }

    func requiresGIFAdmission(state: LibraryState) -> Bool {
        let assigned = Set(state.effectiveAssignments(for: targets().map(\.id)).values)
        return state.wallpapers.contains { assigned.contains($0.id) && $0.kind == .gif }
    }

    func validateLayout(state: LibraryState) throws {
        try validatePanorama(state: state, targets: targets())
    }

    func assignmentAdmissionRequest(state: LibraryState, store: LibraryStore) throws -> GIFAssignmentAdmissionRequest {
        let connected = targets()
        try validatePanorama(state: state, targets: connected)
        let assignments = state.effectiveAssignments(for: connected.map(\.id))
        var requests: [String: URL] = [:]
        for (display, id) in assignments {
            guard let item = state.wallpapers.first(where: { $0.id == id }), item.kind == .gif else { continue }
            requests[display] = try store.resolvedURL(for: item)
        }
        return GIFAssignmentAdmissionRequest(urls: requests, connectedIDs: Set(connected.map(\.id)), limit: gifBudget.limit)
    }

    func validateAssignmentsAsync(_ request: GIFAssignmentAdmissionRequest) async throws {
        let admission = try await gifAdmissions.admit(request.urls, limit: request.limit)
        try Task.checkCancellation()
        // The MainActor may resume later than the background scan. Recheck only
        // identity here; parsing content remains exclusively on the worker.
        for (display, url) in request.urls {
            guard try GIFFileIdentity.read(url: url) == admission.byDisplay[display]?.identity else {
                throw GIFAnimationError.nativeStatus(9)
            }
        }
        guard request.connectedIDs == Set(targets().map(\.id)) else { throw CancellationError() }
    }

    private func validatePanorama(state: LibraryState, targets: [DesktopTarget]) throws {
        guard state.displayMode == .spanned else { return }
        if let id = state.mirroredWallpaperID {
            guard let item = state.wallpapers.first(where: { $0.id == id }),
                  item.supportsPanorama else { throw PanoramaError.photoRequired }
        }
        if !targets.isEmpty, panorama(state: state, targets: targets) == nil { throw PanoramaError.invalidGeometry }
    }

    private func panorama(state: LibraryState, targets: [DesktopTarget]) -> PanoramaLayout? {
        state.displayMode == .spanned
            ? PanoramaLayout(frames: targets.map(\.frame), backingScales: targets.map(\.backingScale)) : nil
    }

    private func proposedBudget(state: LibraryState, store: LibraryStore, connected: [String], admissions: [String: GIFAdmission]? = nil) throws -> GIFPlaybackBudget {
        var budget = GIFPlaybackBudget(limit: gifBudget.limit)
        let assignments = state.effectiveAssignments(for: connected)
        for displayID in connected {
            guard let id = assignments[displayID], let wallpaper = state.wallpapers.first(where: { $0.id == id }) else { continue }
            budget = try proposal(for: wallpaper, displayID: displayID, store: store, budget: budget, admissions: admissions)
        }
        return budget
    }

    private func proposal(for wallpaper: Wallpaper, displayID: String, store: LibraryStore,
                          budget: GIFPlaybackBudget, admissions: [String: GIFAdmission]? = nil) throws -> GIFPlaybackBudget {
        guard wallpaper.kind == .gif else { return try budget.replacing(displayID: displayID, decodedBytes: nil) }
        let url = try store.resolvedURL(for: wallpaper)
        let identity = try GIFFileIdentity.read(url: url)
        let metadata: GIFMetadata
        if let admissions {
            guard let admitted = admissions[displayID], admitted.identity == identity else { throw GIFAnimationError.nativeStatus(9) }
            metadata = admitted.metadata
        } else if let cached = gifMetadata[identity] { metadata = cached }
        else {
            metadata = try GIFPreflight.inspect(url: url)
            guard try GIFFileIdentity.read(url: url) == identity else { throw GIFAnimationError.nativeStatus(9) }
            if gifMetadata.count >= 128 { gifMetadata.removeAll(keepingCapacity: true) }
            gifMetadata[identity] = metadata
        }
        return try budget.replacing(displayID: displayID, decodedBytes: metadata.decodedBytes, sourceID: identity.resourceKey)
    }

    /// Production entry point: Rust GIF frames and ImageIO photos prepare off the
    /// main actor. Existing windows stay until replacement succeeds.
    func scheduleRebuild(state: LibraryState, store: LibraryStore, paused: Bool, force: Bool = false, deferNewRenderers: Bool = false,
                         onPhotoQuality: @escaping @MainActor (String, PhotoQualityInfo?) -> Void = { _, _ in },
                         onState: @escaping @MainActor (String, RemotePlaybackState) -> Void = { _, _ in },
                         onError: @escaping @MainActor (String, String) -> Void) {
        audioConfiguration = state.audioConfiguration
        rebuildGeneration = UUID()
        let generation = rebuildGeneration
        reschedule = { [weak self] in
            guard let self else { return }
            self.scheduleRebuild(state: self.withCurrentAudio(state), store: store, paused: self.latestPaused, deferNewRenderers: deferNewRenderers, onPhotoQuality: onPhotoQuality, onState: onState, onError: onError)
        }
        latestPaused = paused
        let currentTargets = targets()
        let layout = panorama(state: state, targets: currentTargets)
        let connected = Set(currentTargets.map(\.id))
        let assignments = state.effectiveAssignments(for: currentTargets.map(\.id))
        let assigned = Set(assignments.keys)
        for id in Array(renderers.keys) where !connected.contains(id) || !assigned.contains(id) {
            renderers.removeValue(forKey: id)?.renderer.stop()
        }
        gifBudget = gifBudget.retaining(displays: Set(renderers.keys))
        for (id, entry) in renderers where audioConfiguration.displayID != id || assignments[id] != entry.wallpaperID {
            entry.renderer.setAudioEnabled(false)
        }
        for (id, entry) in renderers {
            entry.renderer.setHLSResolution(state.settings.hlsResolution)
            entry.renderer.setPaused(paused)
            entry.renderer.setAudioPolicy(enabled: audioConfiguration.displayID == id && assignments[id] == entry.wallpaperID, volume: audioConfiguration.effectiveVolume(for: entry.wallpaperID))
        }
        if deferNewRenderers {
            photos.cancel(); gifs.cancel()
            return // Existing surfaces keep policy/audio updates; new media waits.
        }
        do { try validatePanorama(state: state, targets: currentTargets) }
        catch {
            photos.cancel(); gifs.cancel()
            for id in assigned { onError(id, error.localizedDescription) }
            return
        }
        var requests: [String: PhotoDecodeRequest] = [:]
        for target in currentTargets {
            guard let id = assignments[target.id],
                  let wallpaper = state.wallpapers.first(where: { $0.id == id }), wallpaper.kind == .image else { continue }
            let fit = state.mediaFit(for: id, on: target.id)
            if !force, !pendingReloads.contains(target.id), let entry = renderers[target.id],
               entry.wallpaperID == id, entry.frame == target.frame,
               entry.backingScale == target.backingScale, entry.mediaFit == fit, entry.panorama == layout { continue }
            do {
                let viewport = layout?.pixelSize ?? CGSize(width: target.frame.width * target.backingScale, height: target.frame.height * target.backingScale)
                requests[target.id] = PhotoDecodeRequest(url: try store.resolvedURL(for: wallpaper), mediaFit: fit,
                    viewportWidth: viewport.width, viewportHeight: viewport.height)
            } catch {
                // Resolve errors use the same non-mutating failure path as decode errors.
                photos.cancel(); gifs.cancel()
                onError(target.id, error.localizedDescription)
                return
            }
        }
        var gifRequests: [String: URL] = [:]
        for target in currentTargets {
            guard let id = assignments[target.id], let item = state.wallpapers.first(where: { $0.id == id }), item.kind == .gif else { continue }
            do { gifRequests[target.id] = try store.resolvedURL(for: item) }
            catch { photos.cancel(); gifs.cancel(); onError(target.id, error.localizedDescription); return }
        }
        let requestedGeometry = geometry(currentTargets)
        gifs.submit(gifRequests) { [weak self] outcome in
            guard let self, self.rebuildGeneration == generation else { return }
            guard self.geometry(self.targets()) == requestedGeometry else {
                self.scheduleRebuild(state: self.withCurrentAudio(state), store: store, paused: self.latestPaused, force: force, onPhotoQuality: onPhotoQuality, onState: onState, onError: onError)
                return
            }
            let admission: GIFAdmissionBatch
            do { admission = try outcome.admission.get() }
            catch {
                self.photos.cancel()
                for id in assigned { onError(id, error.localizedDescription) }
                return
            }
            self.photos.submit(requests) { [weak self] prepared in
                guard let self, self.rebuildGeneration == generation else { return }
                guard self.geometry(self.targets()) == requestedGeometry else {
                    self.scheduleRebuild(state: self.withCurrentAudio(state), store: store, paused: self.latestPaused, force: force, onPhotoQuality: onPhotoQuality, onState: onState, onError: onError)
                    return
                }
                self.rebuild(state: state, store: store, paused: self.latestPaused, force: force,
                    preparedPhotos: prepared, requiresPreparedPhotos: true, preparedGIFs: outcome.images,
                    requiresPreparedGIFs: true, admissions: admission.byDisplay, onPhotoQuality: onPhotoQuality, onState: onState, onError: onError)
            }
        }
    }

    func rebuild(state: LibraryState, store: LibraryStore, paused: Bool, force: Bool = false, preparedPhotos: PhotoPreparation.Results = [:], requiresPreparedPhotos: Bool = false, preparedGIFs: SharedGIFPreparation.Results = [:], requiresPreparedGIFs: Bool = false, admissions: [String: GIFAdmission]? = nil, onPhotoQuality: @escaping @MainActor (String, PhotoQualityInfo?) -> Void = { _, _ in }, onState: @escaping @MainActor (String, RemotePlaybackState) -> Void = { _, _ in }, onError: @escaping @MainActor (String, String) -> Void) {
        if !requiresPreparedPhotos || !requiresPreparedGIFs {
            rebuildGeneration = UUID();audioConfiguration = state.audioConfiguration;latestPauseIsManual = false
        }
        if !requiresPreparedPhotos { photos.cancel() }
        if !requiresPreparedGIFs { gifs.cancel() }
        latestPaused = paused
        let currentTargets = targets()
        let layout = panorama(state: state, targets: currentTargets)
        let connected = Set(currentTargets.map(\.id))
        let available = Set(state.wallpapers.map(\.id))
        let assignments = state.effectiveAssignments(for: currentTargets.map(\.id))
        let assigned = Set(assignments.filter { available.contains($0.value) }.keys)
        // Removed targets must stop even when a newly connected mirror exceeds its budget.
        for id in Array(renderers.keys) where !connected.contains(id) || !assigned.contains(id) {
            renderers.removeValue(forKey: id)?.renderer.stop()
        }
        gifBudget = gifBudget.retaining(displays: Set(renderers.keys))
        // Silence every existing player before any display receives audio ownership.
        for (id, entry) in renderers where audioConfiguration.displayID != id || assignments[id] != entry.wallpaperID {
            entry.renderer.setAudioEnabled(false)
        }
        let proposed: GIFPlaybackBudget
        do {
            try validatePanorama(state: state, targets: currentTargets)
            proposed = try proposedBudget(state: state, store: store, connected: currentTargets.map(\.id), admissions: admissions)
        }
        catch {
            renderers.values.forEach { $0.renderer.setPaused(paused) }
            for id in assigned { onError(id, error.localizedDescription) }
            return
        }
        pendingReloads.formIntersection(connected.intersection(assigned))
        // Release shrinking charges first so a valid whole-state transition is
        // never rejected merely because a growing display was visited first.
        let orderedTargets = currentTargets.sorted {
            let left = Int64(proposed.bytesByDisplay[$0.id] ?? 0) - Int64(gifBudget.bytesByDisplay[$0.id] ?? 0)
            let right = Int64(proposed.bytesByDisplay[$1.id] ?? 0) - Int64(gifBudget.bytesByDisplay[$1.id] ?? 0)
            return left < right
        }
        for target in orderedTargets {
            let screen = target.screen
            let displayID = target.id
            guard let wallpaperID = assignments[displayID],
                  let wallpaper = state.wallpapers.first(where: { $0.id == wallpaperID }) else { continue }
            let reloadRequested = pendingReloads.remove(displayID) != nil
            let mediaFit = state.mediaFit(for: wallpaperID, on: displayID)
            let preparedIdentity = try? preparedGIFs[displayID]?.get().identity
            let sameGIF = wallpaper.kind != .gif || !requiresPreparedGIFs || (preparedIdentity != nil && renderers[displayID]?.renderer.gifIdentity == preparedIdentity)
            if !force, !reloadRequested, sameGIF, let entry = renderers[displayID], entry.wallpaperID == wallpaperID, entry.frame == target.frame,
               entry.mediaFit == mediaFit, entry.backingScale == target.backingScale, entry.panorama == layout {
                entry.renderer.setHLSResolution(state.settings.hlsResolution)
                entry.renderer.setPaused(paused)
                entry.renderer.setAudioPolicy(enabled: audioConfiguration.displayID == displayID, volume: audioConfiguration.effectiveVolume(for: entry.wallpaperID))
                onPhotoQuality(displayID, entry.renderer.photoQuality)
                if let state = entry.renderer.remotePlaybackState { onState(displayID, state) }
                continue
            }
            let token = UUID()
            do {
                let nextBudget = try proposal(for: wallpaper, displayID: displayID, store: store, budget: gifBudget, admissions: admissions)
                let photo: DecodedPhoto?
                if wallpaper.kind == .image, requiresPreparedPhotos {
                    guard let result = preparedPhotos[displayID] else { throw PhotoDecodingError.unreadable }
                    photo = try result.get()
                } else { photo = nil }
                let playback: SharedGIFPlayback?
                if wallpaper.kind == .gif, requiresPreparedGIFs {
                    guard let result = preparedGIFs[displayID] else { throw RendererError.unreadableImage }
                    let asset = try result.get()
                    let url = try store.resolvedURL(for: wallpaper)
                    guard try GIFFileIdentity.read(url: url) == asset.identity else { throw GIFAnimationError.nativeStatus(9) }
                    playback = try SharedGIFPlayback.playback(for: asset)
                } else { playback = nil }
                let renderer = try WallpaperRenderer(wallpaper: wallpaper, url: store.resolvedURL(for: wallpaper), screen: screen, mediaFit: mediaFit, preparedPhoto: photo, preparedGIF: playback, onGIFChanged: { [weak self] in
                    guard let self else { return }
                    self.invalidate(displayID: displayID)
                    self.reschedule?()
                }, targetFrame: target.frame, targetScale: target.backingScale, panorama: layout, webDocument: webDocument, hlsResolution: state.settings.hlsResolution,
                                                     isWindowVisible: isWindowVisible, onState: { [weak self] state in
                    guard self?.renderers[displayID]?.token == token else { return }
                    onState(displayID, state)
                }) { [weak self] message in
                    guard self?.renderers[displayID]?.token == token else { return }
                    onError(displayID, message)
                }
                // Keep the previous renderer and charge intact on any failure.
                renderers.removeValue(forKey: displayID)?.renderer.stop()
                gifBudget = nextBudget
                renderers[displayID] = Entry(wallpaperID: wallpaperID, frame: target.frame, mediaFit: mediaFit, backingScale: target.backingScale, panorama: layout, token: token, renderer: renderer)
                renderer.setAudioPolicy(enabled: audioConfiguration.displayID == displayID, volume: audioConfiguration.effectiveVolume(for: wallpaperID))
                if latestPauseIsManual { renderer.setManuallyPaused(paused) }
                else { renderer.setPaused(paused) }
                onPhotoQuality(displayID, renderer.photoQuality)
                if let state = renderer.remotePlaybackState { onState(displayID, state) }
            } catch {
                renderers[displayID]?.renderer.setPaused(paused)
                if let state = renderers[displayID]?.renderer.remotePlaybackState { onState(displayID, state) }
                onError(displayID, error.localizedDescription)
            }
        }
    }

    func invalidate(displayID: String) {
        // Preserve the previous renderer and GIF charge until replacement succeeds.
        pendingReloads.insert(displayID)
    }

    /// Hot audio changes do not rebuild windows, re-prepare media or seek players.
    func setAudioPreferences(state: LibraryState) {
        audioConfiguration = state.audioConfiguration
        let connected = Set(targets().map(\.id))
        let assignments = state.effectiveAssignments(for: Array(connected))
        for (display, entry) in renderers where !connected.contains(display) || audioConfiguration.displayID != display || assignments[display] != entry.wallpaperID {
            entry.renderer.setAudioEnabled(false)
        }
        for (display, entry) in renderers {
            let ownsAudio = connected.contains(display) && audioConfiguration.displayID == display && assignments[display] == entry.wallpaperID
            entry.renderer.setAudioPolicy(enabled: ownsAudio, volume: audioConfiguration.effectiveVolume(for: entry.wallpaperID))
        }
    }

    func setManuallyPaused(_ value: Bool) {
        latestPaused = value;latestPauseIsManual = true
        renderers.values.forEach { $0.renderer.setManuallyPaused(value) }
    }

    func setPaused(_ value: Bool) {
        latestPaused = value;latestPauseIsManual = false
        renderers.values.forEach { $0.renderer.setPaused(value) }
    }

    func stop() {
        rebuildGeneration = UUID()
        photos.cancel(); gifs.cancel()
        reschedule = nil; gifMetadata.removeAll();latestPauseIsManual = false
        let previous = Array(renderers.values)
        renderers.removeAll()
        gifBudget = GIFPlaybackBudget(limit: gifBudget.limit)
        pendingReloads.removeAll()
        previous.forEach { $0.renderer.stop() }
    }
}

private enum PanoramaError: LocalizedError {
    case photoRequired, invalidGeometry
    var errorDescription: String? {
        switch self {
        case .photoRequired: "Escolha uma foto para usar o modo panorâmico. Vídeos e GIFs ainda não são compatíveis."
        case .invalidGeometry: "Não foi possível calcular a disposição dos monitores para o panorama."
        }
    }
}
