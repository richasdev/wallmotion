import AppKit
import AVFoundation
import XCTest
import WallmotionCore
@testable import Wallmotion

@MainActor
final class VideoFitContinuityTests: XCTestCase {
    @MainActor private final class Windows {
        var values: [NSWindow] = []
        func visible(_ window: NSWindow) -> Bool {
            if !values.contains(where: { $0 === window }) { values.append(window) }
            return true
        }
    }

    private func fixture() async throws -> (URL, LibraryStore, Wallpaper) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WallmotionVideoFit-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("video.mp4")
        // Long enough that natural AVPlayerLooper item replacement cannot hide a restart.
        try await LocalVideoFixture.write(at: url, frames: 90, fps: 3)
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library"))
        return (root, store, try store.importFile(at: url))
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }

    private func verifyContinuity(mode: DisplayMode) async throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Sem sessão gráfica") }
        let (root, store, item) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let windows = Windows()
        let targets = [
            DesktopTarget(id: "left", screen: screen, frame: CGRect(x: -10000, y: -10000, width: 160, height: 90), backingScale: 1),
            DesktopTarget(id: "right", screen: screen, frame: CGRect(x: -9800, y: -9960, width: 90, height: 160), backingScale: 2)
        ]
        let active = mode.isShared ? targets : Array(targets.prefix(1))
        let engine = DesktopCoordinator(targets: { active }, isWindowVisible: { windows.visible($0) }, sharedVideoLayerReady: { _ in true })
        defer { engine.stop() }
        var state = LibraryState(wallpapers: [item], assignments: ["left": item.id],
            settings: .init(audioDisplayID: "left", audioVolume: 0.7), displayMode: mode, mirroredWallpaperID: item.id)
        engine.scheduleRebuild(state: state, store: store, paused: false) { _, error in XCTFail(error) }
        try await waitUntil { windows.values.count == active.count }
        let surfaces = try windows.values.map { try XCTUnwrap($0.contentView as? VideoSurface) }
        let player = try XCTUnwrap(surfaces.first?.playerLayer.player)
        try await waitUntil { player.timeControlStatus == .playing && player.currentItem?.presentationSize == CGSize(width: 32, height: 16) }
        let current = try XCTUnwrap(player.currentItem)
        await player.seek(to: CMTime(seconds: 2, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        try await waitUntil { player.currentTime().seconds >= 2 }
        let initialWindows = windows.values
        let initialLayers = surfaces.map(\.playerLayer)
        let panorama = mode == .spanned ? PanoramaLayout(frames: active.map(\.frame), backingScales: active.map(\.backingScale)) : nil

        for fit in [MediaFit.fill, .center, .stretch, .fit] {
            let before = player.currentTime().seconds
            state.setMediaFit(fit, for: item.id, on: "left")
            engine.scheduleRebuild(state: state, store: store, paused: false) { _, error in XCTFail(error) }
            let expectedGravity: AVLayerVideoGravity = panorama != nil || fit == .stretch ? .resize : (fit == .fill ? .resizeAspectFill : .resizeAspect)
            try await waitUntil {
                surfaces.allSatisfy { surface in
                    surface.layoutSubtreeIfNeeded()
                    if surface.playerLayer.videoGravity != expectedGravity { return false }
                    if let panorama, let window = surface.window {
                        return surface.playerLayer.frame == panorama.imageFrame(sourcePixels: CGSize(width: 32, height: 16), fit: fit, on: window.frame)
                    }
                    return surface.playerLayer.frame == (fit == .center
                        ? fit.frame(for: CGSize(width: 32, height: 16), in: surface.bounds, backingScale: surface.window?.backingScaleFactor ?? 1)
                        : surface.bounds)
                }
            }
            XCTAssertEqual(windows.values.count, active.count, "Fit must not allocate replacement windows")
            for index in initialWindows.indices {
                XCTAssertTrue(windows.values[index] === initialWindows[index])
                XCTAssertTrue(initialWindows[index].contentView === surfaces[index])
                XCTAssertTrue(surfaces[index].playerLayer === initialLayers[index])
                XCTAssertTrue(surfaces[index].playerLayer.player === player)
                XCTAssertNil(surfaces[index].playerLayer.animationKeys(), "Geometry must not animate through intermediate crop frames")
            }
            XCTAssertTrue(player.currentItem === current)
            XCTAssertEqual(player.rate, 1)
            XCTAssertEqual(player.volume, 0.7, accuracy: 0.0001)
            XCTAssertFalse(player.isMuted)
            XCTAssertGreaterThanOrEqual(player.currentTime().seconds, before)
            try await waitUntil { player.currentTime().seconds > before + 0.05 }
        }

        engine.setPaused(true)
        let pausedAt = player.currentTime()
        state.setMediaFit(.center, for: item.id, on: "left")
        engine.scheduleRebuild(state: state, store: store, paused: true) { _, error in XCTFail(error) }
        try await waitUntil { surfaces.allSatisfy { $0.playerLayer.frame.width < $0.bounds.width } }
        XCTAssertTrue(player.currentItem === current)
        XCTAssertEqual(player.rate, 0)
        // AVFoundation settles its host-clock mapping asynchronously after pause.
        XCTAssertEqual(player.currentTime().seconds, pausedAt.seconds, accuracy: 0.02)
        XCTAssertEqual(player.volume, 0)
        XCTAssertTrue(player.isMuted)
        engine.stop()
        XCTAssertNil(player.currentItem)
        XCTAssertTrue(surfaces.allSatisfy { $0.playerLayer.player == nil && $0.playerLayer.superlayer == nil })
        XCTAssertTrue(initialWindows.allSatisfy { $0.contentView == nil })
    }

    func testIndependentVideoChangesEveryFitWithoutReplacingPlayingOrPausedTransport() async throws {
        try await verifyContinuity(mode: .independent)
    }

    func testMirroredVideoChangesEveryFitWithoutReplacingPlayingOrPausedTransport() async throws {
        try await verifyContinuity(mode: .mirrored)
    }

    func testPanoramaVideoChangesEveryFitAcrossGapsAndMixedScaleWithoutReplacingTransport() async throws {
        try await verifyContinuity(mode: .spanned)
    }

    func testExplicitReloadStillReplacesVideoAndMissingReplacementPreservesOldRenderer() async throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Sem sessão gráfica") }
        let (root, store, item) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let windows = Windows()
        let engine = DesktopCoordinator(targets: {
            [DesktopTarget(id: "left", screen: screen, frame: CGRect(x: -10000, y: -10000, width: 160, height: 90))]
        }, isWindowVisible: { windows.visible($0) })
        defer { engine.stop() }
        var errors: [String] = []
        let state = LibraryState(wallpapers: [item], assignments: ["left": item.id])
        engine.rebuild(state: state, store: store, paused: true) { _, error in errors.append(error) }
        let first = try XCTUnwrap((windows.values.first?.contentView as? VideoSurface)?.playerLayer.player)
        engine.invalidate(displayID: "left")
        engine.rebuild(state: state, store: store, paused: true) { _, error in errors.append(error) }
        XCTAssertEqual(windows.values.count, 2)
        XCTAssertNil(first.currentItem)
        let surface = try XCTUnwrap(windows.values.last?.contentView as? VideoSurface)
        let second = try XCTUnwrap(surface.playerLayer.player)
        XCTAssertFalse(first === second)
        try await waitUntil { second.currentItem?.status == .readyToPlay }
        try FileManager.default.removeItem(at: store.resolvedURL(for: item))
        engine.invalidate(displayID: "left")
        engine.rebuild(state: state, store: store, paused: true) { _, error in errors.append(error) }
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(windows.values.count, 2)
        XCTAssertTrue(surface.playerLayer.player === second)
        XCTAssertNotNil(second.currentItem)
    }

    func testRemoteVideoFitKeepsItemAndHLSPreferenceAndStoppedRendererRejectsUpdates() async throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Sem sessão gráfica") }
        let (root, store, local) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let localURL = try store.resolvedURL(for: local)
        let item = try Wallpaper.remote("https://example.invalid/video.m3u8")
        let renderer = try WallpaperRenderer(wallpaper: item, url: URL(string: "https://example.invalid/video.m3u8")!, screen: screen,
            targetFrame: CGRect(x: -10000, y: -10000, width: 160, height: 90), hlsResolution: .hd720, isWindowVisible: { _ in true },
            makePlayer: { _, _ in AVPlayer(playerItem: AVPlayerItem(url: localURL)) }) { XCTFail($0) }
        defer { renderer.stop() }
        let surface = try XCTUnwrap(renderer.window.contentView as? VideoSurface)
        let player = try XCTUnwrap(surface.playerLayer.player)
        renderer.setPaused(false)
        try await waitUntil { player.timeControlStatus == .playing }
        let current = try XCTUnwrap(player.currentItem)
        for fit in MediaFit.allCases { XCTAssertTrue(renderer.updateVideoFit(fit)) }
        XCTAssertTrue(player.currentItem === current)
        XCTAssertEqual(current.preferredMaximumResolution, CGSize(width: 1280, height: 720))
        XCTAssertEqual(player.rate, 1)
        renderer.stop()
        XCTAssertFalse(renderer.updateVideoFit(.fill))
        XCTAssertNil(player.currentItem)
    }
}
