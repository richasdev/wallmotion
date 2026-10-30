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
    private var webRenderer: WebWallpaperRenderer?
    private let player: AVPlayer?
    private let imageView: NSImageView?
    private var looper: AVPlayerLooper?
    private var statusObserver: NSKeyValueObservation?
    private var currentItemObserver: NSKeyValueObservation?
    private var loopObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var paused = true
    private var stopped = false

    init(wallpaper: Wallpaper, url: URL, screen: NSScreen, onError: @escaping @MainActor (String) -> Void) throws {
        if case .web(let embed) = wallpaper.source {
            let renderer = try WebWallpaperRenderer(embed: embed, onError: onError)
            webRenderer = renderer
            player = nil
            imageView = nil
            window = DesktopWindow(screen: screen, view: renderer.surface)
        } else if wallpaper.kind == .image || wallpaper.kind == .gif {
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
            let item = AVPlayerItem(url: url)
            let mediaPlayer: AVPlayer
            if url.isFileURL {
                mediaPlayer = AVQueuePlayer()
            } else {
                mediaPlayer = AVPlayer(playerItem: item)
            }
            mediaPlayer.isMuted = true
            mediaPlayer.preventsDisplaySleepDuringVideoPlayback = false
            mediaPlayer.automaticallyWaitsToMinimizeStalling = true
            player = mediaPlayer
            imageView = nil
            window = DesktopWindow(screen: screen, view: VideoSurface(player: mediaPlayer))
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
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.player?.seek(to: .zero) { [weak self] finished in
                            Task { @MainActor [weak self] in
                                guard let self, !self.stopped else { return }
                                guard finished else { onError("Não foi possível reiniciar o vídeo remoto. Tente recarregar a reprodução."); return }
                                guard !self.paused else { return }
                                self.player?.play()
                            }
                        }
                    }
                }
            }
            // The looper plays copies of its template; observe the current item,
            // rather than the template, to receive errors from the actual decoder.
            currentItemObserver = mediaPlayer.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.observeCurrentItem(onError: onError) }
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
        webRenderer?.setPaused(value)
        imageView?.animates = !value
        if value { player?.pause() } else { player?.play() }
        window.orderBack(nil)
    }

    func stop() {
        stopped = true
        webRenderer?.stop()
        webRenderer = nil
        paused = true
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

    func rebuild(state: LibraryState, store: LibraryStore, paused: Bool, force: Bool = false, onError: @escaping @MainActor (String, String) -> Void) {
        if force { stop() }
        let connected = Set(NSScreen.screens.compactMap(Display.identify))
        for id in Array(renderers.keys) where !connected.contains(id) || state.assignments[id] == nil {
            renderers.removeValue(forKey: id)?.renderer.stop()
        }
        for screen in NSScreen.screens {
            guard let displayID = Display.identify(screen),
                  let wallpaperID = state.assignments[displayID],
                  let wallpaper = state.wallpapers.first(where: { $0.id == wallpaperID }) else { continue }
            if let entry = renderers[displayID], entry.wallpaperID == wallpaperID, entry.frame == screen.frame {
                entry.renderer.setPaused(paused)
                continue
            }
            renderers.removeValue(forKey: displayID)?.renderer.stop()
            let token = UUID()
            do {
                let renderer = try WallpaperRenderer(wallpaper: wallpaper, url: store.resolvedURL(for: wallpaper), screen: screen) { [weak self] message in
                    guard self?.renderers[displayID]?.token == token else { return }
                    onError(displayID, message)
                }
                renderers[displayID] = Entry(wallpaperID: wallpaperID, frame: screen.frame, token: token, renderer: renderer)
                renderer.setPaused(paused)
            } catch { onError(displayID, error.localizedDescription) }
        }
    }

    func setPaused(_ value: Bool) { renderers.values.forEach { $0.renderer.setPaused(value) } }

    func stop() {
        renderers.values.forEach { $0.renderer.stop() }
        renderers.removeAll()
    }
}
