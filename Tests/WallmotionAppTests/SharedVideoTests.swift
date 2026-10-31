import AppKit
import AVFoundation
import CoreImage
import XCTest
import WallmotionCore
@testable import Wallmotion

@MainActor
final class SharedVideoTests: XCTestCase {
    private final class Targets { var values: [DesktopTarget] = [] }
    @MainActor private final class Windows {
        var values: [NSWindow] = []
        var hidden: Set<ObjectIdentifier> = []
        var players: [AVPlayer] = []
        func visible(_ window: NSWindow) -> Bool {
            if !values.contains(where: { $0 === window }) {
                values.append(window)
                if let player = (window.contentView as? VideoSurface)?.playerLayer.player { players.append(player) }
            }
            return !hidden.contains(ObjectIdentifier(window))
        }
    }
    private func fixture() async throws -> (URL, LibraryStore, Wallpaper) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WallmotionSharedVideo-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = root.appendingPathComponent("video.mp4");try await LocalVideoFixture.write(at: url)
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library"))
        return (root,store,try store.importFile(at: url))
    }
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }
    private func targets(_ screen: NSScreen) -> [DesktopTarget] {
        [DesktopTarget(id: "left", screen: screen, frame: CGRect(x: -10000,y: -10000,width: 160,height: 90)),
         DesktopTarget(id: "right", screen: screen, frame: CGRect(x: -9840,y: -10000,width: 160,height: 90))]
    }
    func testMirroredNativePlayersShareTransportAndOwnerOcclusionDoesNotPauseOtherScreen() async throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Sem sessão gráfica") }
        let (root,store,item) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let windows = Windows(), targets = Targets();targets.values = self.targets(screen)
        let engine = DesktopCoordinator(targets: { targets.values }, isWindowVisible: { windows.visible($0) }, sharedVideoLayerReady: { _ in true })
        defer { engine.stop() }
        var state = LibraryState(wallpapers: [item], settings: .init(audioDisplayID: "left",audioVolume: 0.8),
            displayMode: .mirrored, mirroredWallpaperID: item.id)
        state.setAudioGain(0.5, for: item.id)
        engine.scheduleRebuild(state: state, store: store, paused: false) { _, error in XCTFail(error) }
        try await waitUntil { windows.players.count == 2 }
        let player = windows.players[0]
        XCTAssertTrue(player === windows.players[1]);XCTAssertFalse(player.preventsDisplaySleepDuringVideoPlayback)
        try await waitUntil { player.timeControlStatus == .playing }
        XCTAssertEqual(player.volume, 0.4, accuracy: 0.0001)
        let left = try XCTUnwrap(windows.values.first { $0.frame.minX == -10000 })
        windows.hidden.insert(ObjectIdentifier(left))
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: left)
        XCTAssertEqual(player.volume, 0);XCTAssertTrue(player.isMuted)
        XCTAssertEqual(player.rate, 1, "Visible secondary still owns transport demand")
        state.settings.audioDisplayID = "right";engine.setAudioPreferences(state: state)
        XCTAssertEqual(player.volume, 0.4, accuracy: 0.0001)
        state.settings.audioVolume = 0.5;engine.setAudioPreferences(state: state)
        XCTAssertEqual(player.volume, 0.25, accuracy: 0.0001)
        engine.setManuallyPaused(true)
        try await waitUntil { player.rate == 0 }
        XCTAssertTrue(player.isMuted);XCTAssertEqual(player.volume, 0)
        engine.setManuallyPaused(false)
        try await waitUntil { player.timeControlStatus == .playing && abs(player.volume - 0.25) < 0.0001 }
        targets.values.removeLast()
        engine.scheduleRebuild(state: state, store: store, paused: false) { _, error in XCTFail(error) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(windows.values.count, 2, "Disconnect preserves the remaining transport/window")
        XCTAssertTrue(player.isMuted);XCTAssertEqual(player.volume, 0)
        windows.hidden.removeAll()
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: left)
        try await waitUntil { player.timeControlStatus == .playing }
        engine.stop();XCTAssertNil(player.currentItem);XCTAssertEqual(player.rate, 0)
    }

    func testStoppingOneRendererCannotPauseOrMuteTheRemainingSharedRendererFromQueuedKVO() async throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Sem sessão gráfica") }
        let (root,store,item) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let url = try store.resolvedURL(for: item)
        let playback = try SharedVideoPlayback(wallpaperID: item.id, url: url, layerReady: { _ in true }) { XCTFail("Unexpected readiness failure") }
        let a = try WallpaperRenderer(wallpaper: item, url: url, screen: screen, targetFrame: targets(screen)[0].frame,
            sharedVideo: playback, isWindowVisible: { _ in true }) { XCTFail($0) }
        let b = try WallpaperRenderer(wallpaper: item, url: url, screen: screen, targetFrame: targets(screen)[1].frame,
            sharedVideo: playback, isWindowVisible: { _ in true }) { XCTFail($0) }
        defer { a.stop();b.stop() }
        a.setAudioPolicy(enabled: true,volume: 0.6);a.setPaused(false);b.setPaused(false)
        try await waitUntil { playback.player.timeControlStatus == .playing }
        b.stop()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(playback.subscriberCount, 1);XCTAssertEqual(playback.player.rate, 1)
        XCTAssertEqual(playback.player.volume, 0.6, accuracy: 0.0001);XCTAssertFalse(playback.player.isMuted)
        a.stop();XCTAssertEqual(playback.subscriberCount, 0);XCTAssertNil(playback.player.currentItem)
    }

    func testMissingSharedLayersFallBackOnceToIndependentNativePlayers() async throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Sem sessão gráfica") }
        let (root,store,item) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let windows = Windows()
        let engine = DesktopCoordinator(targets: { self.targets(screen) }, isWindowVisible: { windows.visible($0) },
            sharedVideoLayerReady: { _ in false }, sharedVideoReadinessDelay: .milliseconds(40))
        defer { engine.stop() }
        let state = LibraryState(wallpapers: [item], displayMode: .mirrored, mirroredWallpaperID: item.id)
        engine.scheduleRebuild(state: state, store: store, paused: false) { _, error in XCTFail(error) }
        try await waitUntil { windows.players.count == 4 }
        XCTAssertTrue(windows.players[0] === windows.players[1])
        XCTAssertFalse(windows.players[2] === windows.players[3])
        XCTAssertNil(windows.players[0].currentItem)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(windows.values.count, 4, "A rejected pipeline must not retry forever")
    }

    func testReadinessDeadlineCancelsWhilePausedAndDuplicateAudioOwnersFailClosed() async throws {
        let (root,store,item) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        var rejected = false
        let playback = try SharedVideoPlayback(wallpaperID: item.id, url: store.resolvedURL(for: item),
            layerReady: { _ in false }, readinessDelay: .milliseconds(80)) { rejected = true }
        defer { playback.stop() }
        let a = AVPlayerLayer(player: playback.player), b = AVPlayerLayer(player: playback.player)
        let one = playback.subscribe(layer: a, refresh: {}, state: { _ in },error: { XCTFail($0) })
        let two = playback.subscribe(layer: b, refresh: {}, state: { _ in },error: { XCTFail($0) })
        playback.update(one, playing: true,visible: true,volume: 0.5)
        playback.update(two, playing: true,visible: true,volume: 0.7)
        XCTAssertEqual(playback.player.volume, 0);XCTAssertTrue(playback.player.isMuted)
        try await waitUntil { playback.hasReadinessTask }
        playback.update(one, playing: false,visible: true,volume: 0)
        playback.update(two, playing: false,visible: true,volume: 0)
        XCTAssertFalse(playback.hasReadinessTask)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(rejected);XCTAssertEqual(playback.player.rate, 0)
    }

    func testSharedRemoteAdapterKeepsHLSPreferenceAndPausesWithoutReplacingItsItem() async throws {
        let (root,store,item) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let local = try store.resolvedURL(for: item)
        let playback = try SharedVideoPlayback(wallpaperID: item.id,url: URL(string: "https://example.invalid/test.m3u8")!,
            hlsResolution: .hd720, makePlayer: { _, _ in AVPlayer(playerItem: AVPlayerItem(url: local)) }, layerReady: { _ in true }) {}
        defer { playback.stop() }
        let layer = AVPlayerLayer(player: playback.player)
        let token = playback.subscribe(layer: layer,refresh: {},state: { _ in },error: { XCTFail($0) })
        let current = try XCTUnwrap(playback.player.currentItem)
        XCTAssertEqual(current.preferredMaximumResolution, CGSize(width: 1280,height: 720))
        playback.update(token,playing: true,visible: true,volume: 0)
        try await waitUntil { playback.player.timeControlStatus == .playing }
        playback.setHLSResolution(.fullHD1080)
        XCTAssertEqual(current.preferredMaximumResolution, CGSize(width: 1920,height: 1080))
        playback.update(token,playing: false,visible: true,volume: 0)
        XCTAssertEqual(playback.player.rate, 0);XCTAssertTrue(playback.player.currentItem === current)
        XCTAssertFalse(playback.player.preventsDisplaySleepDuringVideoPlayback)
    }

    func testDestroyedLayerDoesNotRejectSharedPlaybackOrRetainAudioDemand() async throws {
        let (root,store,item) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        var rejected = false
        let playback = try SharedVideoPlayback(wallpaperID: item.id,url: store.resolvedURL(for: item),
            layerReady: { _ in false },readinessDelay: .milliseconds(60)) { rejected = true }
        defer { playback.stop() }
        let kept = AVPlayerLayer(player: playback.player)
        var orphan: AVPlayerLayer? = AVPlayerLayer(player: playback.player)
        let one = playback.subscribe(layer: kept,refresh: {},state: { _ in },error: { XCTFail($0) })
        let two = playback.subscribe(layer: try XCTUnwrap(orphan),refresh: {},state: { _ in },error: { XCTFail($0) })
        playback.update(one,playing: true,visible: true,volume: 0)
        playback.update(two,playing: true,visible: true,volume: 0.8)
        try await waitUntil { playback.hasReadinessTask }
        weak let weakLayer = orphan;orphan = nil
        XCTAssertNil(weakLayer)
        // The bounded readiness callback also prunes a layer destroyed without an update.
        try await waitUntil { playback.subscriberCount == 1 }
        XCTAssertTrue(playback.player.isMuted);XCTAssertEqual(playback.player.volume,0)
        XCTAssertEqual(playback.player.rate,1)
        playback.update(one,playing: true,visible: true,volume: 0.4)
        XCTAssertFalse(rejected);XCTAssertEqual(playback.player.volume,0.4,accuracy: 0.0001)
        XCTAssertFalse(playback.hasReadinessTask)
    }

    func testDeallocatedRendererReleasesItsSharedSubscription() async throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Sem sessão gráfica") }
        let (root,store,item) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let url = try store.resolvedURL(for: item)
        let playback = try SharedVideoPlayback(wallpaperID: item.id,url: url,layerReady: { _ in true }) {}
        var renderer: WallpaperRenderer? = try WallpaperRenderer(wallpaper: item,url: url,screen: screen,
            targetFrame: targets(screen)[0].frame,sharedVideo: playback,isWindowVisible: { _ in true }) { XCTFail($0) }
        let window = try XCTUnwrap(renderer?.window)
        defer { window.orderOut(nil);window.close();playback.stop() }
        XCTAssertEqual(playback.subscriberCount,1)
        weak let weakRenderer = renderer;renderer = nil
        XCTAssertNil(weakRenderer)
        try await waitUntil { playback.subscriberCount == 0 }
        XCTAssertNil(playback.player.currentItem);XCTAssertEqual(playback.player.rate,0)
    }
}
