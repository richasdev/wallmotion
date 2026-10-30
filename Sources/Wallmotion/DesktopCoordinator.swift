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
final class VideoSurface: NSView {
    let playerLayer = AVPlayerLayer()

    init(player: AVPlayer) {
        super.init(frame: .zero)
        wantsLayer = true
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
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
    private var remotePlayback: RemoteVideoPlayback?
    var remotePlaybackState: RemotePlaybackState? { remotePlayback?.state }
    private var failureObserver: NSObjectProtocol?
    private var occlusionObserver: NSObjectProtocol?
    private var paused = true
    private var occluded = false
    private var stopped = false

    init(wallpaper: Wallpaper, url: URL, screen: NSScreen, onState: @escaping @MainActor (RemotePlaybackState) -> Void = { _ in }, onError: @escaping @MainActor (String) -> Void) throws {
        if wallpaper.kind == .image || wallpaper.kind == .gif {
            let image: NSImage
            if wallpaper.kind == .gif {
                _ = try GIFPreflight.inspect(url: url)
                guard let animated = NSImage(contentsOf: url), animated.isValid else { throw RendererError.unreadableImage }
                image = animated
            } else {
                // Decode only enough pixels for this display; never retain the full
                // resolution bitmap of a large imported photo.
                let maxPixels = Int(ceil(max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor))
                guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                        kCGImageSourceShouldCacheImmediately: true
                      ] as CFDictionary) else { throw RendererError.unreadableImage }
                image = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
            }
            let view = NSImageView(image: image)
            view.imageScaling = .scaleProportionallyUpOrDown
            view.animates = false
            view.canDrawSubviewsIntoLayer = true
            imageView = view
            player = nil
            window = DesktopWindow(screen: screen, view: view)
        } else {
            if url.isFileURL, !FileManager.default.isReadableFile(atPath: url.path) { throw RendererError.missingFile }
            let mediaPlayer: AVPlayer
            if url.isFileURL {
                mediaPlayer = AVQueuePlayer()
            } else {
                mediaPlayer = AVPlayer()
            }
            mediaPlayer.isMuted = true
            mediaPlayer.preventsDisplaySleepDuringVideoPlayback = false
            mediaPlayer.automaticallyWaitsToMinimizeStalling = true
            player = mediaPlayer
            imageView = nil
            window = DesktopWindow(screen: screen, view: VideoSurface(player: mediaPlayer))
            if let queue = mediaPlayer as? AVQueuePlayer {
                looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
                loopObserver = looper?.observe(\.status, options: [.initial, .new]) { looper, _ in
                    guard looper.status == .failed else { return }
                    let message = looper.error?.localizedDescription ?? "Não foi possível repetir o vídeo."
                    Task { @MainActor in onError(message) }
                }
                // The looper plays copies of its template; observe its current item.
                currentItemObserver = mediaPlayer.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, _ in
                    Task { @MainActor [weak self] in self?.observeCurrentItem(onError: onError) }
                }
            } else {
                mediaPlayer.actionAtItemEnd = .pause
                remotePlayback = RemoteVideoPlayback(player: mediaPlayer, url: url) { state in
                    onState(state)
                    if case .error(let message) = state { onError(message) }
                }
            }
        }

        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                self.occluded = !self.window.occlusionState.contains(.visible)
                self.applyPlaybackPause()
            }
        }
    }

    private func observeCurrentItem(onError: @escaping @MainActor (String) -> Void) {
        guard !stopped else { return }
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
        guard !stopped else { return }
        paused = value
        applyPlaybackPause()
        window.orderBack(nil)
    }

    private func applyPlaybackPause() {
        let effectivePause = paused || occluded
        imageView?.animates = !effectivePause
        if let remotePlayback { remotePlayback.setPaused(effectivePause) }
        else if effectivePause { player?.pause() } else { player?.play() }
    }

    func stop() {
        stopped = true
        paused = true
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
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        (player as? AVQueuePlayer)?.removeAllItems()
        if let surface = window.contentView as? VideoSurface {
            surface.playerLayer.player = nil
            surface.playerLayer.removeFromSuperlayer()
        }
        imageView?.animates = false
        window.orderOut(nil)
        window.close()
    }
}

enum RendererError: LocalizedError {
    case unreadableImage, missingFile
    var errorDescription: String? {
        switch self {
        case .unreadableImage: "Não foi possível decodificar a imagem ou GIF."
        case .missingFile: "O vídeo importado não está mais disponível. Importe o arquivo novamente."
        }
    }
}

@MainActor
final class DesktopCoordinator {
    private struct Entry {
        let wallpaperID: UUID
        let frame: CGRect
        let token: UUID
        let renderer: WallpaperRenderer
    }
    private var renderers: [String: Entry] = [:]
    private var pendingReloads: Set<String> = []
    private(set) var gifBudget: GIFPlaybackBudget
    private let screens: @MainActor () -> [NSScreen]

    init(gifBudgetLimit: UInt64 = GIFPlaybackBudget.defaultLimit,
         screens: @escaping @MainActor () -> [NSScreen] = { NSScreen.screens }) {
        gifBudget = GIFPlaybackBudget(limit: gifBudgetLimit)
        self.screens = screens
    }

    // Check before persisting a user selection. Rebuild also checks restored and
    // reconnected assignments before opening any AppKit GIF decoder.
    func validateAssignment(_ wallpaper: Wallpaper, to displayID: String, store: LibraryStore) throws {
        let connected = Set(screens().compactMap(Display.identify))
        _ = try proposal(for: wallpaper, displayID: displayID, store: store,
                         budget: gifBudget.retaining(displays: connected))
    }

    private func proposal(for wallpaper: Wallpaper, displayID: String, store: LibraryStore,
                          budget: GIFPlaybackBudget) throws -> GIFPlaybackBudget {
        let bytes = wallpaper.kind == .gif
            ? try GIFPreflight.inspect(url: store.resolvedURL(for: wallpaper)).decodedBytes : nil
        return try budget.replacing(displayID: displayID, decodedBytes: bytes)
    }

    func rebuild(state: LibraryState, store: LibraryStore, paused: Bool, force: Bool = false, onState: @escaping @MainActor (String, RemotePlaybackState) -> Void = { _, _ in }, onError: @escaping @MainActor (String, String) -> Void) {
        let currentScreens = screens()
        let connected = Set(currentScreens.compactMap(Display.identify))
        let available = Set(state.wallpapers.map(\.id))
        let assigned = Set(state.assignments.filter { available.contains($0.value) }.keys)
        pendingReloads.formIntersection(connected.intersection(assigned))
        for id in Array(renderers.keys) where !connected.contains(id) || !assigned.contains(id) {
            renderers.removeValue(forKey: id)?.renderer.stop()
        }
        gifBudget = gifBudget.retaining(displays: Set(renderers.keys))
        for screen in currentScreens {
            guard let displayID = Display.identify(screen),
                  let wallpaperID = state.assignments[displayID],
                  let wallpaper = state.wallpapers.first(where: { $0.id == wallpaperID }) else { continue }
            let reloadRequested = pendingReloads.remove(displayID) != nil
            if !force, !reloadRequested, let entry = renderers[displayID], entry.wallpaperID == wallpaperID, entry.frame == screen.frame {
                entry.renderer.setPaused(paused)
                continue
            }
            let token = UUID()
            do {
                let nextBudget = try proposal(for: wallpaper, displayID: displayID, store: store, budget: gifBudget)
                let renderer = try WallpaperRenderer(wallpaper: wallpaper, url: store.resolvedURL(for: wallpaper), screen: screen, onState: { [weak self] state in
                    guard self?.renderers[displayID]?.token == token else { return }
                    onState(displayID, state)
                }) { [weak self] message in
                    guard self?.renderers[displayID]?.token == token else { return }
                    onError(displayID, message)
                }
                // Keep the previous renderer and charge intact on any failure.
                renderers.removeValue(forKey: displayID)?.renderer.stop()
                gifBudget = nextBudget
                renderers[displayID] = Entry(wallpaperID: wallpaperID, frame: screen.frame, token: token, renderer: renderer)
                renderer.setPaused(paused)
                if let state = renderer.remotePlaybackState { onState(displayID, state) }
            } catch {
                renderers[displayID]?.renderer.setPaused(paused)
                if let state = renderers[displayID]?.renderer.remotePlaybackState { onState(displayID, state) }
                onError(displayID, error.localizedDescription)
            }
        }
    }

    func invalidate(displayID: String) {
        // Rebuild replaces transactionally: preserve the renderer and GIF charge
        // until the new item has passed validation and decoder construction.
        pendingReloads.insert(displayID)
    }

    func setPaused(_ value: Bool) { renderers.values.forEach { $0.renderer.setPaused(value) } }

    func stop() {
        let previous = Array(renderers.values)
        renderers.removeAll()
        gifBudget = GIFPlaybackBudget(limit: gifBudget.limit)
        pendingReloads.removeAll()
        previous.forEach { $0.renderer.stop() }
    }
}
