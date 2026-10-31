import AppKit
import WallmotionCore

/// One clock/current NSImage per immutable asset. Subscribers never own the clock
/// through their callbacks; renderer callbacks capture only a weak image view.
@MainActor
final class SharedGIFPlayback {
    private final class WeakPlayback { weak var value: SharedGIFPlayback?; init(_ value: SharedGIFPlayback) { self.value = value } }
    private static var shared: [GIFFileIdentity: WeakPlayback] = [:]
    static func playback(for asset: PreparedGIF) throws -> SharedGIFPlayback {
        shared = shared.filter { $0.value.value != nil }
        if let existing = shared[asset.identity]?.value { return existing }
        let value = try SharedGIFPlayback(asset: asset)
        shared[asset.identity] = WeakPlayback(value)
        return value
    }

    let asset: PreparedGIF
    private(set) var currentImage: NSImage
    private(set) var frameIndex = 0
    private var elapsed = 0.0
    private var resumedAt: Double?
    private let now: @MainActor () -> Double
    private var tick: Task<Void, Never>?
    private struct Subscriber { var active: Bool; let url: URL?; let image: (NSImage) -> Void; let changed: () -> Void }
    private var subscribers: [UUID: Subscriber] = [:]
    private var watchers: [URL: GIFSourceWatcher] = [:]
    var hasScheduledTick: Bool { tick != nil }
    var subscriberCount: Int { subscribers.count }

    init(asset: PreparedGIF, now: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime }) throws {
        self.asset = asset; self.now = now
        let image = try asset.animation.image(at: 0, retaining: asset)
        currentImage = NSImage(cgImage: image, size: NSSize(width: asset.animation.width, height: asset.animation.height))
    }
    deinit { tick?.cancel() }

    func subscribe(url: URL? = nil, image: @escaping (NSImage) -> Void, changed: @escaping () -> Void = {}) -> UUID {
        let id = UUID(); subscribers[id] = Subscriber(active: false, url: url, image: image, changed: changed)
        if let url, watchers[url] == nil {
            watchers[url] = GIFSourceWatcher(url: url) { [weak self] in
                Task { @MainActor [weak self] in self?.sourceChanged(url: url) }
            }
        }
        image(currentImage)
        // Events before watcher installation cannot be replayed. Recheck after
        // arming it, and defer callbacks until the renderer has been installed.
        if let url, (try? GIFFileIdentity.read(url: url)) != asset.identity {
            Task { @MainActor [weak self] in self?.sourceChanged(url: url) }
        }
        return id
    }
    func setActive(_ active: Bool, subscriber: UUID) {
        guard var entry = subscribers[subscriber], entry.active != active else { return }
        entry.active = active; subscribers[subscriber] = entry
        updateTransport()
        if active { entry.image(currentImage) }
    }
    func isActive(_ id: UUID) -> Bool { subscribers[id]?.active == true }
    func unsubscribe(_ id: UUID) {
        let url = subscribers.removeValue(forKey: id)?.url
        if let url, !subscribers.values.contains(where: { $0.url == url }) { watchers[url] = nil }
        updateTransport()
    }

    private func updateTransport() {
        let playing = subscribers.values.contains { $0.active }
        if playing, resumedAt == nil { resumedAt = now(); renderFrame(); scheduleTick() }
        else if !playing, let started = resumedAt {
            elapsed = position(at: now(), started: started)
            resumedAt = nil; tick?.cancel(); tick = nil
        }
    }
    private func position(at now: Double, started: Double) -> Double {
        let value = elapsed + max(0, now-started)
        return asset.timeline.duration > 0 ? value.truncatingRemainder(dividingBy: asset.timeline.duration) : 0
    }
    private func scheduleTick() {
        guard let started = resumedAt, asset.animation.frameCount > 1 else { return }
        let delay = asset.timeline.nextWake(after: position(at: now(), started: started))
        tick = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self?.advance()
        }
    }
    func advance() {
        tick?.cancel(); tick = nil
        renderFrame()
        scheduleTick()
    }
    private func renderFrame() {
        guard let started = resumedAt else { return }
        let phase = position(at: now(), started: started)
        let index = asset.timeline.frame(at: phase)
        if index != frameIndex, let image = try? asset.animation.image(at: index, retaining: asset) {
            frameIndex = index
            currentImage = NSImage(cgImage: image, size: NSSize(width: asset.animation.width, height: asset.animation.height))
            for entry in subscribers.values where entry.active { entry.image(currentImage) }
        }
    }
    private func sourceChanged(url: URL) {
        // Parent-directory events also catch a second atomic replacement after a
        // failed reload. Unrelated writes do not trigger media preparation.
        guard (try? GIFFileIdentity.read(url: url)) != asset.identity else { return }
        for callback in subscribers.values.filter({ $0.url == url }).map(\.changed) { callback() }
    }
}

/// Dispatch owns the fd until cancellation completes; immutable wrapper may die
/// on any thread without closing an fd still in use by its dispatch source.
private final class GIFSourceWatcher: @unchecked Sendable {
    private let sources: [any DispatchSourceFileSystemObject]
    init?(url: URL, changed: @escaping @Sendable () -> Void) {
        var sources: [any DispatchSourceFileSystemObject] = []
        // The inode source covers writes and attributes; the directory source
        // follows replacement of the path while a failed reload keeps old pixels.
        for (path, mask): (String, DispatchSource.FileSystemEvent) in [
            (url.path, [.write, .extend, .attrib, .link, .rename, .delete, .revoke]),
            (url.deletingLastPathComponent().path, [.write, .rename, .delete, .revoke])
        ] {
            let descriptor = open(path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: mask, queue: .main)
            source.setEventHandler(handler: changed)
            source.setCancelHandler { close(descriptor) }
            source.resume(); sources.append(source)
        }
        guard !sources.isEmpty else { return nil }
        self.sources = sources
    }
    deinit { sources.forEach { $0.cancel() } }
}
