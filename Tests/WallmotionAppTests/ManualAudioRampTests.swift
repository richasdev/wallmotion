import AppKit
import AVFoundation
import XCTest
import WallmotionCore
@testable import Wallmotion

@MainActor
final class ManualAudioRampTests: XCTestCase {
    private final class Clock { var now = 0.0 }
    private final class Visibility { var visible = true }
    private func fixture() async throws -> (URL, Wallpaper) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WallmotionAudioFade-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = root.appendingPathComponent("video.mp4")
        try await LocalVideoFixture.write(at: url)
        return (root, Wallpaper(title: "Fixture", kind: .video, source: .local(filename: "video.mp4")))
    }
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }
    private func renderer(_ item: Wallpaper, root: URL, clock: Clock, visibility: Visibility) throws -> (WallpaperRenderer, AVPlayer) {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Sem sessão gráfica") }
        let renderer = try WallpaperRenderer(wallpaper: item, url: root.appendingPathComponent("video.mp4"), screen: screen,
            targetFrame: CGRect(x: -10000,y: -10000,width: 200,height: 100),
            isWindowVisible: { _ in visibility.visible }, audioClock: { clock.now }) { XCTFail($0) }
        let player = try XCTUnwrap((renderer.window.contentView as? VideoSurface)?.playerLayer.player)
        return (renderer, player)
    }

    func testNativeFadeOutAndFadeInUseEnvelopeAndWaitForActualPlayback() async throws {
        let (root, item) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock(), visibility = Visibility()
        let (renderer, player) = try renderer(item, root: root, clock: clock, visibility: visibility)
        defer { renderer.stop() }
        renderer.setAudioPolicy(enabled: true, volume: 0.8);renderer.setPaused(false)
        try await waitUntil { player.timeControlStatus == .playing }
        renderer.setManuallyPaused(true)
        XCTAssertTrue(renderer.playbackState.isPaused)
        XCTAssertEqual(player.volume, 0.8, accuracy: 0.0001)
        XCTAssertTrue(renderer.hasAudioFadeTick)
        clock.now = 0.1;renderer.refreshAudioTransition()
        XCTAssertEqual(player.volume, 0.4, accuracy: 0.0001)
        clock.now = 0.21;renderer.refreshAudioTransition()
        XCTAssertEqual(player.volume, 0);XCTAssertTrue(player.isMuted)
        XCTAssertFalse(renderer.hasAudioFadeTick);XCTAssertEqual(player.rate, 0)
        renderer.setManuallyPaused(false)
        XCTAssertEqual(player.volume, 0)
        try await waitUntil { !renderer.isWaitingForAudioPlayback && player.timeControlStatus == .playing }
        XCTAssertTrue(renderer.hasAudioFadeTick)
        clock.now = 0.31;renderer.refreshAudioTransition()
        XCTAssertEqual(player.volume, 0.4, accuracy: 0.0001)
        clock.now = 0.42;renderer.refreshAudioTransition()
        XCTAssertEqual(player.volume, 0.8, accuracy: 0.0001)
        XCTAssertFalse(player.isMuted);XCTAssertFalse(renderer.hasAudioFadeTick)
    }

    func testRapidReverseIsContinuousAndLosingOwnerCancelsOldTask() async throws {
        let (root, item) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock(), visibility = Visibility()
        let (renderer, player) = try renderer(item, root: root, clock: clock, visibility: visibility)
        defer { renderer.stop() }
        renderer.setAudioPolicy(enabled: true, volume: 1);renderer.setPaused(false)
        try await waitUntil { player.timeControlStatus == .playing }
        renderer.setManuallyPaused(true);clock.now = 0.05;renderer.refreshAudioTransition()
        let descending = player.volume
        XCTAssertGreaterThan(descending, 0);XCTAssertLessThan(descending, 1)
        renderer.setManuallyPaused(false)
        XCTAssertEqual(player.volume, descending, accuracy: 0.0001)
        clock.now = 0.15;renderer.refreshAudioTransition()
        XCTAssertGreaterThan(player.volume, descending)
        renderer.setAudioEnabled(false)
        XCTAssertEqual(player.volume, 0);XCTAssertTrue(player.isMuted)
        XCTAssertFalse(renderer.hasAudioFadeTick);XCTAssertFalse(renderer.isWaitingForAudioPlayback)
        clock.now = 5;renderer.refreshAudioTransition()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(player.volume, 0);XCTAssertTrue(player.isMuted)
    }

    func testSystemOcclusionStopAndZeroVolumeCutFadeImmediately() async throws {
        let (root, item) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        for action in ["system", "occlusion", "stop", "zero"] {
            let clock = Clock(), visibility = Visibility()
            let (renderer, player) = try renderer(item, root: root, clock: clock, visibility: visibility)
            defer { renderer.stop() }
            renderer.setAudioPolicy(enabled: true, volume: 1);renderer.setPaused(false)
            try await waitUntil { player.timeControlStatus == .playing }
            renderer.setManuallyPaused(true);clock.now = 0.05;renderer.refreshAudioTransition()
            XCTAssertGreaterThan(player.volume, 0)
            switch action {
            case "system": renderer.setPaused(true)
            case "occlusion":
                visibility.visible = false
                NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: renderer.window)
            case "stop": renderer.stop()
            default: renderer.setAudioPolicy(enabled: true, volume: 0)
            }
            XCTAssertEqual(player.volume, 0);XCTAssertTrue(player.isMuted)
            XCTAssertFalse(renderer.hasAudioFadeTick);XCTAssertFalse(renderer.isWaitingForAudioPlayback)
            clock.now = 2;renderer.refreshAudioTransition()
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(player.volume, 0);XCTAssertTrue(player.isMuted)
        }
    }

    func testRealTimerFinishesFadeWithoutBlockingMainActor() async throws {
        let (root, item) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Sem sessão gráfica") }
        let renderer = try WallpaperRenderer(wallpaper: item, url: root.appendingPathComponent("video.mp4"), screen: screen,
            targetFrame: CGRect(x: -10000,y: -10000,width: 200,height: 100), isWindowVisible: { _ in true }) { XCTFail($0) }
        defer { renderer.stop() }
        let player = try XCTUnwrap((renderer.window.contentView as? VideoSurface)?.playerLayer.player)
        renderer.setAudioPolicy(enabled: true, volume: 1);renderer.setPaused(false)
        try await waitUntil { player.timeControlStatus == .playing }
        renderer.setManuallyPaused(true)
        var mainWasResponsive = false
        Task { @MainActor in mainWasResponsive = true }
        try await waitUntil { mainWasResponsive && player.volume > 0 && player.volume < 1 }
        try await waitUntil { !renderer.hasAudioFadeTick }
        XCTAssertEqual(player.volume, 0);XCTAssertTrue(player.isMuted);XCTAssertEqual(player.rate, 0)
    }

    func testBufferWaitDoesNotSpendEnvelopeTimeOrScheduleTicks() async throws {
        let (root, item) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Sem sessão gráfica") }
        let clock = Clock(), ready = Visibility();ready.visible = false
        let renderer = try WallpaperRenderer(wallpaper: item, url: root.appendingPathComponent("video.mp4"), screen: screen,
            targetFrame: CGRect(x: -10000,y: -10000,width: 200,height: 100), isWindowVisible: { _ in true },
            audioClock: { clock.now }, audioIsPlaying: { _ in ready.visible }) { XCTFail($0) }
        defer { renderer.stop() }
        let player = try XCTUnwrap((renderer.window.contentView as? VideoSurface)?.playerLayer.player)
        renderer.setAudioPolicy(enabled: true, volume: 0.8)
        renderer.setManuallyPaused(false)
        XCTAssertTrue(renderer.isWaitingForAudioPlayback);XCTAssertFalse(renderer.hasAudioFadeTick)
        clock.now = 100;renderer.refreshAudioTransition()
        XCTAssertEqual(player.volume, 0);XCTAssertTrue(player.isMuted);XCTAssertFalse(renderer.hasAudioFadeTick)
        ready.visible = true;renderer.refreshAudioTransition()
        XCTAssertFalse(renderer.isWaitingForAudioPlayback);XCTAssertTrue(renderer.hasAudioFadeTick)
        clock.now = 100.1;renderer.refreshAudioTransition()
        XCTAssertEqual(player.volume, 0.4, accuracy: 0.0001)
        ready.visible = false;renderer.refreshAudioTransition()
        XCTAssertTrue(renderer.isWaitingForAudioPlayback);XCTAssertFalse(renderer.hasAudioFadeTick)
        clock.now = 200;renderer.refreshAudioTransition()
        XCTAssertEqual(player.volume, 0)
        ready.visible = true;renderer.refreshAudioTransition()
        clock.now = 200.21;renderer.refreshAudioTransition()
        XCTAssertEqual(player.volume, 0.8, accuracy: 0.0001);XCTAssertFalse(renderer.hasAudioFadeTick)
    }

    func testReverseIntoBufferingResetsNonzeroEnvelopeAndOldTick() async throws {
        let (root, item) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Sem sessão gráfica") }
        let clock = Clock(), ready = Visibility()
        let renderer = try WallpaperRenderer(wallpaper: item, url: root.appendingPathComponent("video.mp4"), screen: screen,
            targetFrame: CGRect(x: -10000,y: -10000,width: 200,height: 100), isWindowVisible: { _ in true },
            audioClock: { clock.now }, audioIsPlaying: { _ in ready.visible }) { XCTFail($0) }
        defer { renderer.stop() }
        let player = try XCTUnwrap((renderer.window.contentView as? VideoSurface)?.playerLayer.player)
        renderer.setAudioPolicy(enabled: true, volume: 1);renderer.setPaused(false)
        renderer.setManuallyPaused(true);clock.now = 0.1;renderer.refreshAudioTransition()
        XCTAssertEqual(player.volume, 0.5, accuracy: 0.0001)
        ready.visible = false;renderer.setManuallyPaused(false)
        XCTAssertEqual(player.volume, 0);XCTAssertTrue(renderer.isWaitingForAudioPlayback)
        XCTAssertFalse(renderer.hasAudioFadeTick)
        clock.now = 100;renderer.refreshAudioTransition()
        XCTAssertEqual(player.volume, 0);XCTAssertFalse(renderer.hasAudioFadeTick)
        ready.visible = true;renderer.refreshAudioTransition()
        clock.now = 100.1;renderer.refreshAudioTransition()
        XCTAssertEqual(player.volume, 0.5, accuracy: 0.0001)
    }

    func testModelManualToggleFadesButWorkspaceSleepCutsImmediatelyAndPreventsResume() async throws {
        let (root, _) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Sem sessão gráfica") }
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library"))
        let item = try store.importFile(at: root.appendingPathComponent("video.mp4"))
        var state = LibraryState(wallpapers: [item], assignments: ["test": item.id])
        state.settings.audioDisplayID = "test";state.settings.audioVolume = 0.8
        state.settings.pauseOnLowPower = false;state.settings.pauseOnThermalPressure = false
        try store.save(state)
        var window: NSWindow?
        let engine = DesktopCoordinator(targets: { [DesktopTarget(id: "test", screen: screen,
            frame: CGRect(x: -10000,y: -10000,width: 200,height: 100))] }, isWindowVisible: { candidate in window = candidate;return true })
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), purgeThumbnails: {},
            store: store, engine: engine, connectedDisplays: { [Display(id: "test", name: "Test")] })
        defer { model.stop() }
        model.start();try await waitUntil { window != nil }
        let player = try XCTUnwrap((window?.contentView as? VideoSurface)?.playerLayer.player)
        try await waitUntil { player.timeControlStatus == .playing }
        model.togglePause()
        XCTAssertTrue(model.isPaused);XCTAssertGreaterThan(player.volume, 0, "Manual pause keeps transport only during its envelope")
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertEqual(player.volume, 0);XCTAssertTrue(player.isMuted);XCTAssertEqual(player.rate, 0)
        model.togglePause()
        XCTAssertFalse(model.state.settings.isManuallyPaused);XCTAssertTrue(model.isPaused)
        XCTAssertEqual(player.volume, 0)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(player.volume, 0);XCTAssertTrue(player.isMuted)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertFalse(model.isPaused)
        try await waitUntil { player.timeControlStatus == .playing }
        XCTAssertEqual(player.volume, 0.8, accuracy: 0.0001)
        model.togglePause();try await waitUntil { player.rate == 0 }
        model.togglePause()
        XCTAssertEqual(player.volume, 0, "Manual resume starts at zero")
        try await waitUntil { player.volume > 0 && player.volume < 0.8 }
        try await waitUntil { abs(player.volume - 0.8) < 0.0001 }
    }

    func testMutedSourcesDoNotCreateFadeTasks() async throws {
        let (root, item) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock(), visibility = Visibility()
        let (renderer, player) = try renderer(item, root: root, clock: clock, visibility: visibility)
        defer { renderer.stop() }
        renderer.setAudioPolicy(enabled: false, volume: 1);renderer.setPaused(false)
        renderer.setManuallyPaused(true);renderer.setManuallyPaused(false)
        XCTAssertFalse(renderer.hasAudioFadeTick);XCTAssertEqual(player.volume, 0)
        renderer.setAudioPolicy(enabled: true, volume: 0)
        renderer.setManuallyPaused(true);renderer.setManuallyPaused(false)
        XCTAssertFalse(renderer.hasAudioFadeTick);XCTAssertEqual(player.volume, 0)
    }
}
