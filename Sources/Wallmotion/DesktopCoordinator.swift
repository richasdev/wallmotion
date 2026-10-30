import AppKit
import AVFoundation
import QuartzCore
import WallmotionCore
import ImageIO

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

    init(image: NSImage, mediaFit: MediaFit, panoramaFrame: CGRect? = nil) {
        imageView = NSImageView(image: image)
        self.mediaFit = mediaFit
        self.panoramaFrame = panoramaFrame
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
        imageView.frame = panoramaFrame ?? mediaFit.frame(for: imageView.image?.size ?? .zero, in: bounds)
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
    private let player: AVPlayer?
    private let imageView: NSImageView?
    private var looper: AVPlayerLooper?
    private var statusObserver: NSKeyValueObservation?
    private var currentItemObserver: NSKeyValueObservation?
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

    init(wallpaper: Wallpaper, url: URL, screen: NSScreen, mediaFit: MediaFit = .fit, preparedPhoto: DecodedPhoto? = nil, targetFrame: CGRect? = nil, targetScale: CGFloat? = nil, panorama: PanoramaLayout? = nil, webDocument: String? = nil, hlsResolution: HLSResolution = .automatic,
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
         onState: @escaping @MainActor (RemotePlaybackState) -> Void = { _ in },
         onError: @escaping @MainActor (String) -> Void) throws {
        let frame = targetFrame ?? screen.frame
        let scale = targetScale ?? screen.backingScaleFactor
        let photoScale = panorama?.referenceScale ?? scale
        let viewport = panorama?.pixelSize ?? CGSize(width: frame.width * scale, height: frame.height * scale)
        self.isWindowVisible = isWindowVisible
        self.seekToStart = seekToStart
        if case .web(let embed) = wallpaper.source {
            let renderer = try WebWallpaperRenderer(embed: embed, onError: onError, document: webDocument)
            webRenderer = renderer
            player = nil
            imageView = nil
            window = DesktopWindow(screen: screen, view: renderer.surface, frame: frame)
        } else if wallpaper.kind == .image || wallpaper.kind == .gif {
            let image: NSImage
            if wallpaper.kind == .gif {
                _ = try GIFPreflight.inspect(url: url)
                guard let animated = NSImage(contentsOf: url), animated.isValid else { throw RendererError.unreadableImage }
                image = animated
                if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                   let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                   let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                   let height = properties[kCGImagePropertyPixelHeight] as? NSNumber {
                    image.size = NSSize(width: width.doubleValue / scale,
                                        height: height.doubleValue / scale)
                }
            } else {
                let decoded: DecodedPhoto
                do {
                    decoded = try preparedPhoto ?? PhotoDecodeWorker.decodeImage(PhotoDecodeRequest(
                    url: url, mediaFit: mediaFit,
                    viewportWidth: viewport.width, viewportHeight: viewport.height))
                } catch PhotoDecodingError.unreadable { throw RendererError.unreadableImage }
                catch PhotoDecodingError.overBudget { throw RendererError.photoTooLarge }
                photoQuality = PhotoQualityInfo(wallpaperID: wallpaper.id, sourceSize: decoded.sourceSize,
                    bitmapWidth: decoded.image.width, bitmapHeight: decoded.image.height, isPanorama: panorama != nil)
                image = NSImage(cgImage: decoded.image, size: NSSize(
                    width: decoded.sourceSize.width / photoScale,
                    height: decoded.sourceSize.height / photoScale))
            }
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
    private func applyPlaybackState() {
        playbackState.setVisible(isWindowVisible(window))
        player?.volume = Float(audioVolume)
        player?.isMuted = !(audioEnabled && audioVolume > 0 && playbackState.shouldPlay)
        webRenderer?.setAudioPolicy(enabled: audioEnabled && playbackState.shouldPlay, volume: audioVolume)
        webRenderer?.setPaused(!playbackState.shouldPlay)
        imageView?.animates = playbackState.shouldPlay
        remotePlayback?.setPaused(!playbackState.shouldPlay)
        if playbackState.shouldPlay && (remotePlayback?.canPlay ?? true) { player?.play() }
        else { player?.pause() }
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
        audioEnabled = enabled
        audioVolume = volume.isFinite ? min(1, max(0, volume)) : 0
        applyPlaybackState()
    }

    func setPaused(_ value: Bool) {
        guard !playbackState.isStopped else { return }
        playbackState.setPaused(value)
        window.orderBack(nil)
        applyPlaybackState()
    }

    func stop() {
        guard !playbackState.isStopped else { return }
        playbackState.stop()
        applyPlaybackState()
        webRenderer?.stop()
        webRenderer = nil
        statusObserver?.invalidate()
        statusObserver = nil
        currentItemObserver?.invalidate()
        currentItemObserver = nil
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
    private var latestPaused = true
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
         photoDecoder: @escaping PhotoPreparation.Decode = PhotoDecodeWorker.prepare) {
        photos = PhotoPreparation(maximumRetainedBytes: photoBatchBudgetLimit, decode: photoDecoder)
        gifBudget = GIFPlaybackBudget(limit: gifBudgetLimit)
        self.targets = targets
        self.isWindowVisible = isWindowVisible
        self.webDocument = webDocument
    }

    // Check before persisting a user selection. Rebuild also checks restored and
    // reconnected assignments before opening any AppKit GIF decoder.
    func validateAssignment(_ wallpaper: Wallpaper, to displayID: String, store: LibraryStore) throws {
        let connected = Set(targets().map(\.id))
        _ = try proposal(for: wallpaper, displayID: displayID, store: store,
                         budget: gifBudget.retaining(displays: connected))
    }

    func validateAssignments(state: LibraryState, store: LibraryStore) throws {
        try validatePanorama(state: state, targets: targets())
        _ = try proposedBudget(state: state, store: store, connected: targets().map(\.id))
    }

    private func validatePanorama(state: LibraryState, targets: [DesktopTarget]) throws {
        guard state.displayMode == .spanned else { return }
        if let id = state.mirroredWallpaperID {
            guard let item = state.wallpapers.first(where: { $0.id == id }), item.kind == .image,
                  case .local = item.source else { throw PanoramaError.photoRequired }
        }
        if !targets.isEmpty, panorama(state: state, targets: targets) == nil { throw PanoramaError.invalidGeometry }
    }

    private func panorama(state: LibraryState, targets: [DesktopTarget]) -> PanoramaLayout? {
        state.displayMode == .spanned
            ? PanoramaLayout(frames: targets.map(\.frame), backingScales: targets.map(\.backingScale)) : nil
    }

    private func proposedBudget(state: LibraryState, store: LibraryStore, connected: [String]) throws -> GIFPlaybackBudget {
        var budget = GIFPlaybackBudget(limit: gifBudget.limit)
        let assignments = state.effectiveAssignments(for: connected)
        for displayID in connected {
            guard let id = assignments[displayID], let wallpaper = state.wallpapers.first(where: { $0.id == id }) else { continue }
            budget = try proposal(for: wallpaper, displayID: displayID, store: store, budget: budget)
        }
        return budget
    }

    private func proposal(for wallpaper: Wallpaper, displayID: String, store: LibraryStore,
                          budget: GIFPlaybackBudget) throws -> GIFPlaybackBudget {
        let bytes = wallpaper.kind == .gif
            ? try GIFPreflight.inspect(url: store.resolvedURL(for: wallpaper)).decodedBytes : nil
        return try budget.replacing(displayID: displayID, decodedBytes: bytes)
    }

    /// Production entry point: AppKit remains responsive while bounded ImageIO
    /// output is prepared serially. Existing windows stay until replacement succeeds.
    func scheduleRebuild(state: LibraryState, store: LibraryStore, paused: Bool, force: Bool = false, deferNewRenderers: Bool = false,
                         onPhotoQuality: @escaping @MainActor (String, PhotoQualityInfo?) -> Void = { _, _ in },
                         onState: @escaping @MainActor (String, RemotePlaybackState) -> Void = { _, _ in },
                         onError: @escaping @MainActor (String, String) -> Void) {
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
        for (id, entry) in renderers where state.settings.audioDisplayID != id || assignments[id] != entry.wallpaperID {
            entry.renderer.setAudioEnabled(false)
        }
        for (id, entry) in renderers {
            entry.renderer.setHLSResolution(state.settings.hlsResolution)
            entry.renderer.setPaused(paused)
            entry.renderer.setAudioPolicy(enabled: state.settings.audioDisplayID == id && assignments[id] == entry.wallpaperID, volume: state.settings.audioVolume)
        }
        if deferNewRenderers {
            photos.cancel()
            return // Existing surfaces keep policy/audio updates; new media waits.
        }
        do { try validateAssignments(state: state, store: store) }
        catch {
            photos.cancel()
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
                photos.cancel()
                onError(target.id, error.localizedDescription)
                return
            }
        }
        let requestedGeometry = geometry(currentTargets)
        photos.submit(requests) { [weak self] prepared in
            guard let self else { return }
            guard self.geometry(self.targets()) == requestedGeometry else {
                self.scheduleRebuild(state: state, store: store, paused: self.latestPaused, force: force, onPhotoQuality: onPhotoQuality, onState: onState, onError: onError)
                return
            }
            self.rebuild(state: state, store: store, paused: self.latestPaused, force: force,
                         preparedPhotos: prepared, requiresPreparedPhotos: true, onPhotoQuality: onPhotoQuality, onState: onState, onError: onError)
        }
    }

    func rebuild(state: LibraryState, store: LibraryStore, paused: Bool, force: Bool = false, preparedPhotos: PhotoPreparation.Results = [:], requiresPreparedPhotos: Bool = false, onPhotoQuality: @escaping @MainActor (String, PhotoQualityInfo?) -> Void = { _, _ in }, onState: @escaping @MainActor (String, RemotePlaybackState) -> Void = { _, _ in }, onError: @escaping @MainActor (String, String) -> Void) {
        if !requiresPreparedPhotos { photos.cancel() }
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
        for (id, entry) in renderers where state.settings.audioDisplayID != id || assignments[id] != entry.wallpaperID {
            entry.renderer.setAudioEnabled(false)
        }
        let proposed: GIFPlaybackBudget
        do {
            try validatePanorama(state: state, targets: currentTargets)
            proposed = try proposedBudget(state: state, store: store, connected: currentTargets.map(\.id))
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
            if !force, !reloadRequested, let entry = renderers[displayID], entry.wallpaperID == wallpaperID, entry.frame == target.frame,
               entry.mediaFit == mediaFit, entry.backingScale == target.backingScale, entry.panorama == layout {
                entry.renderer.setHLSResolution(state.settings.hlsResolution)
                entry.renderer.setPaused(paused)
                entry.renderer.setAudioPolicy(enabled: state.settings.audioDisplayID == displayID, volume: state.settings.audioVolume)
                onPhotoQuality(displayID, entry.renderer.photoQuality)
                continue
            }
            let token = UUID()
            do {
                let nextBudget = try proposal(for: wallpaper, displayID: displayID, store: store, budget: gifBudget)
                let photo: DecodedPhoto?
                if wallpaper.kind == .image, requiresPreparedPhotos {
                    guard let result = preparedPhotos[displayID] else { throw PhotoDecodingError.unreadable }
                    photo = try result.get()
                } else { photo = nil }
                let renderer = try WallpaperRenderer(wallpaper: wallpaper, url: store.resolvedURL(for: wallpaper), screen: screen, mediaFit: mediaFit, preparedPhoto: photo, targetFrame: target.frame, targetScale: target.backingScale, panorama: layout, webDocument: webDocument, hlsResolution: state.settings.hlsResolution,
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
                renderer.setPaused(paused)
                renderer.setAudioPolicy(enabled: state.settings.audioDisplayID == displayID, volume: state.settings.audioVolume)
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

    func setPaused(_ value: Bool) {
        latestPaused = value
        renderers.values.forEach { $0.renderer.setPaused(value) }
    }

    func stop() {
        photos.cancel()
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
