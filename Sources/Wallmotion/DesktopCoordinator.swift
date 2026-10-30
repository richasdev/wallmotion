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

    init(screen: NSScreen, view: NSView) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isReleasedWhenClosed = false
        contentView = view
        setFrame(screen.frame, display: true)
    }
}

@MainActor
final class ImageSurface: NSView {
    let imageView: NSImageView
    let mediaFit: MediaFit

    init(image: NSImage, mediaFit: MediaFit) {
        imageView = NSImageView(image: image)
        self.mediaFit = mediaFit
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = false
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("Not supported") }

    override func layout() {
        super.layout()
        imageView.frame = mediaFit.frame(for: imageView.image?.size ?? .zero, in: bounds)
    }
}

@MainActor
final class VideoSurface: NSView {
    let playerLayer = AVPlayerLayer()

    init(player: AVPlayer, mediaFit: MediaFit = .fit) {
        super.init(frame: .zero)
        wantsLayer = true
        playerLayer.player = player
        playerLayer.videoGravity = mediaFit == .fill ? .resizeAspectFill : .resizeAspect
        layer?.masksToBounds = true
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError("Not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

@MainActor
final class WallpaperRenderer {
    let window: DesktopWindow
    private let player: AVPlayer?
    private let imageView: NSImageView?
    private var looper: AVPlayerLooper?
    private var statusObserver: NSKeyValueObservation?
    private var currentItemObserver: NSKeyValueObservation?
    private var loopObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var occlusionObserver: NSObjectProtocol?
    private(set) var playbackState = RendererPlaybackState()
    private let isWindowVisible: @MainActor (NSWindow) -> Bool
    private let seekToStart: @MainActor (AVPlayer, @escaping @MainActor @Sendable (Bool) -> Void) -> Void

    init(wallpaper: Wallpaper, url: URL, screen: NSScreen, mediaFit: MediaFit = .fit,
         isWindowVisible: @escaping @MainActor (NSWindow) -> Bool = { $0.occlusionState.contains(.visible) },
         makePlayer: @MainActor (AVPlayerItem, Bool) -> AVPlayer = { item, local in
             local ? AVQueuePlayer() : AVPlayer(playerItem: item)
         },
         seekToStart: @escaping @MainActor (AVPlayer, @escaping @MainActor @Sendable (Bool) -> Void) -> Void = { player, completion in
             player.seek(to: .zero) { finished in
                 Task { @MainActor in completion(finished) }
             }
         },
         onError: @escaping @MainActor (String) -> Void) throws {
        self.isWindowVisible = isWindowVisible
        self.seekToStart = seekToStart
        if wallpaper.kind == .image || wallpaper.kind == .gif {
            let image: NSImage
            if wallpaper.kind == .gif {
                _ = try GIFPreflight.inspect(url: url)
                guard let animated = NSImage(contentsOf: url), animated.isValid else { throw RendererError.unreadableImage }
                image = animated
            } else {
                // Decode only the pixels required by this display and crop mode,
                // accounting for orientation and Retina backing scale.
                guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                      let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { throw RendererError.unreadableImage }
                let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
                let rotated = (5...8).contains(orientation)
                let size = CGSize(width: rotated ? height.doubleValue : width.doubleValue,
                                  height: rotated ? width.doubleValue : height.doubleValue)
                let viewport = CGSize(width: screen.frame.width * screen.backingScaleFactor,
                                      height: screen.frame.height * screen.backingScaleFactor)
                let maxPixels = mediaFit.decodePixelLimit(for: size, viewport: viewport)
                guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                        kCGImageSourceShouldAllowFloat: false,
                        kCGImageSourceShouldCacheImmediately: true
                      ] as CFDictionary) else { throw RendererError.unreadableImage }
                // Defense in depth if a codec returns an unexpected layout. Use division
                // to avoid overflow, and check before retaining or handing it to AppKit.
                guard thumbnail.width <= maxPixels, thumbnail.height <= maxPixels,
                      thumbnail.height > 0,
                      thumbnail.bytesPerRow <= PhotoDecodeBudget.maximumBytes / thumbnail.height else {
                    throw RendererError.photoTooLarge
                }
                image = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
            }
            let view = ImageSurface(image: image, mediaFit: mediaFit)
            imageView = view.imageView
            player = nil
            window = DesktopWindow(screen: screen, view: view)
        } else {
            if url.isFileURL, !FileManager.default.isReadableFile(atPath: url.path) { throw RendererError.missingFile }
            let item = AVPlayerItem(url: url)
            let mediaPlayer = makePlayer(item, url.isFileURL)
            mediaPlayer.isMuted = true
            mediaPlayer.preventsDisplaySleepDuringVideoPlayback = false
            mediaPlayer.automaticallyWaitsToMinimizeStalling = true
            player = mediaPlayer
            imageView = nil
            window = DesktopWindow(screen: screen, view: VideoSurface(player: mediaPlayer, mediaFit: mediaFit))
            if let queue = mediaPlayer as? AVQueuePlayer {
                looper = AVPlayerLooper(player: queue, templateItem: item)
                loopObserver = looper?.observe(\.status, options: [.initial, .new]) { looper, _ in
                    guard looper.status == .failed else { return }
                    let message = looper.error?.localizedDescription ?? "Não foi possível repetir o vídeo."
                    Task { @MainActor in onError(message) }
                }
            } else {
                mediaPlayer.actionAtItemEnd = .pause
                endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.restartRemotePlayback(onError: onError)
                    }
                }
            }
            // The looper plays copies of its template; observe the current item,
            // rather than the template, to receive errors from the actual decoder.
            currentItemObserver = mediaPlayer.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.observeCurrentItem(onError: onError) }
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
        imageView?.animates = playbackState.shouldPlay
        if playbackState.shouldPlay { player?.play() } else { player?.pause() }
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
        statusObserver?.invalidate()
        statusObserver = nil
        currentItemObserver?.invalidate()
        currentItemObserver = nil
        loopObserver?.invalidate()
        loopObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
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
        let token: UUID
        let renderer: WallpaperRenderer
    }
    private var renderers: [String: Entry] = [:]
    private(set) var gifBudget: GIFPlaybackBudget
    private let targets: @MainActor () -> [DesktopTarget]
    private let isWindowVisible: @MainActor (NSWindow) -> Bool

    init(gifBudgetLimit: UInt64 = GIFPlaybackBudget.defaultLimit,
         targets: @escaping @MainActor () -> [DesktopTarget] = { DesktopTarget.connected },
         isWindowVisible: @escaping @MainActor (NSWindow) -> Bool = { $0.occlusionState.contains(.visible) }) {
        gifBudget = GIFPlaybackBudget(limit: gifBudgetLimit)
        self.targets = targets
        self.isWindowVisible = isWindowVisible
    }

    // Check before persisting a user selection. Rebuild also checks restored and
    // reconnected assignments before opening any AppKit GIF decoder.
    func validateAssignment(_ wallpaper: Wallpaper, to displayID: String, store: LibraryStore) throws {
        let connected = Set(targets().map(\.id))
        _ = try proposal(for: wallpaper, displayID: displayID, store: store,
                         budget: gifBudget.retaining(displays: connected))
    }

    private func proposal(for wallpaper: Wallpaper, displayID: String, store: LibraryStore,
                          budget: GIFPlaybackBudget) throws -> GIFPlaybackBudget {
        let bytes = wallpaper.kind == .gif
            ? try GIFPreflight.inspect(url: store.resolvedURL(for: wallpaper)).decodedBytes : nil
        return try budget.replacing(displayID: displayID, decodedBytes: bytes)
    }

    func rebuild(state: LibraryState, store: LibraryStore, paused: Bool, force: Bool = false, onError: @escaping @MainActor (String, String) -> Void) {
        let currentTargets = targets()
        let connected = Set(currentTargets.map(\.id))
        let available = Set(state.wallpapers.map(\.id))
        let assigned = Set(state.assignments.filter { available.contains($0.value) }.keys)
        for id in Array(renderers.keys) where !connected.contains(id) || !assigned.contains(id) {
            renderers.removeValue(forKey: id)?.renderer.stop()
        }
        gifBudget = gifBudget.retaining(displays: Set(renderers.keys))
        for target in currentTargets {
            let screen = target.screen
            let displayID = target.id
            guard let wallpaperID = state.assignments[displayID],
                  let wallpaper = state.wallpapers.first(where: { $0.id == wallpaperID }) else { continue }
            let mediaFit = state.mediaFit(for: wallpaperID, on: displayID)
            if !force, let entry = renderers[displayID], entry.wallpaperID == wallpaperID, entry.frame == screen.frame,
               entry.mediaFit == mediaFit, entry.backingScale == screen.backingScaleFactor {
                entry.renderer.setPaused(paused)
                continue
            }
            let token = UUID()
            do {
                let nextBudget = try proposal(for: wallpaper, displayID: displayID, store: store, budget: gifBudget)
                let renderer = try WallpaperRenderer(wallpaper: wallpaper, url: store.resolvedURL(for: wallpaper), screen: screen, mediaFit: mediaFit,
                                                     isWindowVisible: isWindowVisible) { [weak self] message in
                    guard self?.renderers[displayID]?.token == token else { return }
                    onError(displayID, message)
                }
                // Keep the previous renderer and charge intact on any failure.
                renderers.removeValue(forKey: displayID)?.renderer.stop()
                gifBudget = nextBudget
                renderers[displayID] = Entry(wallpaperID: wallpaperID, frame: screen.frame, mediaFit: mediaFit, backingScale: screen.backingScaleFactor, token: token, renderer: renderer)
                renderer.setPaused(paused)
            } catch {
                renderers[displayID]?.renderer.setPaused(paused)
                onError(displayID, error.localizedDescription)
            }
        }
    }

    func setPaused(_ value: Bool) { renderers.values.forEach { $0.renderer.setPaused(value) } }

    func stop() {
        renderers.values.forEach { $0.renderer.stop() }
        renderers.removeAll()
        gifBudget = GIFPlaybackBudget(limit: gifBudget.limit)
    }
}
