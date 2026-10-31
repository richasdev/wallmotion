import AppKit
import AVFoundation
import XCTest
import WallmotionCore
@testable import Wallmotion

@MainActor
final class VideoPanoramaTests: XCTestCase {
    @MainActor private final class Windows {
        var values: [NSWindow] = []
        func visible(_ window: NSWindow) -> Bool {
            if !values.contains(where: { $0 === window }) { values.append(window) }
            return true
        }
        var surfaces: [VideoSurface] { values.compactMap { $0.contentView as? VideoSurface } }
    }
    private final class Targets { var values: [DesktopTarget] = [] }
    private final class Readiness { var ready = false }
    private func fixture(rotated: Bool = false) async throws -> (URL,LibraryStore,Wallpaper) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WallmotionVideoPanorama-\(UUID())")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        let url = root.appendingPathComponent("generated.mp4");try await LocalVideoFixture.write(at: url,rotated: rotated)
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library"))
        return (root,store,try store.importFile(at: url))
    }
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }
    private func targets(_ screen: NSScreen) -> [DesktopTarget] {
        [DesktopTarget(id: "bottom",screen: screen,frame: CGRect(x: -10000,y: -10200,width: 100,height: 80),backingScale: 1),
         DesktopTarget(id: "top",screen: screen,frame: CGRect(x: -9950,y: -10000,width: 80,height: 100),backingScale: 2)]
    }
    func testRotatedNativeVideoUsesOneGlobalFrameForEveryFitAcrossGapsAndMixedScale() async throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Sem sessão gráfica") }
        let (root,store,item) = try await fixture(rotated: true);defer { try? FileManager.default.removeItem(at: root) }
        let targets = targets(screen), layout = try XCTUnwrap(PanoramaLayout(frames: targets.map(\.frame),backingScales: [1,2]))
        for fit in MediaFit.allCases {
            let windows = Windows()
            let engine = DesktopCoordinator(targets: { targets },isWindowVisible: { windows.visible($0) },sharedVideoLayerReady: { _ in true })
            defer { engine.stop() }
            let state = LibraryState(wallpapers: [item],displayMode: .spanned,mirroredWallpaperID: item.id,mirroredMediaFit: fit)
            engine.scheduleRebuild(state: state,store: store,paused: true) { _,error in XCTFail(error) }
            try await waitUntil { windows.surfaces.count == 2 && windows.surfaces.allSatisfy { $0.playerLayer.player?.currentItem?.presentationSize == CGSize(width: 16,height: 32) } }
            try await Task.sleep(for: .milliseconds(20))
            let player = try XCTUnwrap(windows.surfaces[0].playerLayer.player)
            XCTAssertTrue(windows.surfaces[1].playerLayer.player === player)
            for window in windows.values {
                let surface = try XCTUnwrap(window.contentView as? VideoSurface);surface.layoutSubtreeIfNeeded()
                XCTAssertTrue(surface.layer?.masksToBounds == true);XCTAssertEqual(surface.playerLayer.videoGravity,.resize)
                let actual = surface.playerLayer.frame.offsetBy(dx: window.frame.minX,dy: window.frame.minY)
                let expected = layout.imageFrame(sourcePixels: CGSize(width: 16,height: 32),fit: fit,on: .zero)
                XCTAssertEqual(actual,expected)
            }
            XCTAssertEqual(player.rate,0);XCTAssertTrue(player.isMuted)
        }
    }

    func testMirrorToPanoramaAndDisconnectPreserveTheSharedTransportWhileUpdatingGeometry() async throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Sem sessão gráfica") }
        let (root,store,item) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let windows = Windows(), connected = Targets();connected.values = targets(screen)
        let engine = DesktopCoordinator(targets: { connected.values },isWindowVisible: { windows.visible($0) },sharedVideoLayerReady: { _ in true })
        defer { engine.stop() }
        var state = LibraryState(wallpapers: [item],displayMode: .mirrored,mirroredWallpaperID: item.id,mirroredMediaFit: .stretch)
        engine.scheduleRebuild(state: state,store: store,paused: false) { _,error in XCTFail(error) }
        try await waitUntil { windows.surfaces.count == 2 }
        let player = try XCTUnwrap(windows.surfaces.first?.playerLayer.player)
        state.displayMode = .spanned
        engine.scheduleRebuild(state: state,store: store,paused: false) { _,error in XCTFail(error) }
        try await waitUntil { windows.values.count == 4 }
        XCTAssertTrue(windows.surfaces.suffix(2).allSatisfy { $0.playerLayer.player === player })
        connected.values.removeLast()
        engine.scheduleRebuild(state: state,store: store,paused: false) { _,error in XCTFail(error) }
        try await waitUntil { windows.values.count == 5 }
        let remaining = try XCTUnwrap(windows.surfaces.last)
        XCTAssertTrue(remaining.playerLayer.player === player)
        try await waitUntil { player.currentItem?.presentationSize.width == 32 }
        remaining.layoutSubtreeIfNeeded();XCTAssertEqual(remaining.playerLayer.frame,remaining.bounds)
        try await waitUntil { player.timeControlStatus == .playing }
        state.mirroredWallpaperID = nil
        engine.scheduleRebuild(state: state,store: store,paused: false) { _,error in XCTFail(error) }
        try await waitUntil { player.currentItem == nil }
        XCTAssertEqual(player.volume,0);XCTAssertEqual(player.rate,0)
    }

    func testUnavailableSharedPanoramaStopsInsteadOfCreatingUnsynchronizedPlayersAndExplicitReloadRetries() async throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Sem sessão gráfica") }
        let (root,store,item) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let windows = Windows(), readiness = Readiness()
        var errors: [String] = []
        let engine = DesktopCoordinator(targets: { self.targets(screen) },isWindowVisible: { windows.visible($0) },
            sharedVideoLayerReady: { _ in readiness.ready },sharedVideoReadinessDelay: .milliseconds(40))
        defer { engine.stop() }
        // Reuse a pool first created in mirrored mode to exercise mode changes during its lifetime.
        var state = LibraryState(wallpapers: [item],displayMode: .mirrored,mirroredWallpaperID: item.id)
        readiness.ready = true
        engine.scheduleRebuild(state: state,store: store,paused: false) { _,error in errors.append(error) }
        try await waitUntil { windows.surfaces.count == 2 }
        let original = try XCTUnwrap(windows.surfaces.first?.playerLayer.player)
        readiness.ready = false;state.displayMode = .spanned
        engine.scheduleRebuild(state: state,store: store,paused: false) { _,error in errors.append(error) }
        try await waitUntil { errors.count == 2 }
        XCTAssertEqual(windows.values.count,4,"Only the mode-change windows, no independent fallback")
        XCTAssertTrue(windows.surfaces.suffix(2).allSatisfy { $0.playerLayer.player === original })
        XCTAssertEqual(original.rate,0);XCTAssertEqual(original.volume,0);XCTAssertTrue(original.isMuted)
        XCTAssertTrue(errors.allSatisfy { $0.contains("Recarregue") })
        engine.scheduleRebuild(state: state,store: store,paused: false) { _,_ in }
        try await Task.sleep(for: .milliseconds(100));XCTAssertEqual(windows.values.count,4)
        readiness.ready = true;engine.invalidate(displayID: "bottom")
        engine.scheduleRebuild(state: state,store: store,paused: false) { _,error in XCTFail(error) }
        try await waitUntil { windows.values.count == 6 }
        let replacement = try XCTUnwrap(windows.surfaces.last?.playerLayer.player)
        XCTAssertFalse(replacement === original);XCTAssertNil(original.currentItem)
        XCTAssertTrue(windows.surfaces.suffix(2).allSatisfy { $0.playerLayer.player === replacement })
    }

    func testPanoramaToMirrorReusesPoolButKeepsIndependentFallbackForCurrentMode() async throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Sem sessão gráfica") }
        let (root,store,item) = try await fixture();defer { try? FileManager.default.removeItem(at: root) }
        let windows = Windows(),readiness = Readiness();readiness.ready = true
        var errors: [String] = []
        let engine = DesktopCoordinator(targets: { self.targets(screen) },isWindowVisible: { windows.visible($0) },
            sharedVideoLayerReady: { _ in readiness.ready },sharedVideoReadinessDelay: .milliseconds(40))
        defer { engine.stop() }
        var state = LibraryState(wallpapers: [item],displayMode: .spanned,mirroredWallpaperID: item.id)
        engine.scheduleRebuild(state: state,store: store,paused: false) { _,error in errors.append(error) }
        try await waitUntil { windows.surfaces.count == 2 }
        let original = try XCTUnwrap(windows.surfaces.first?.playerLayer.player)
        state.displayMode = .mirrored;readiness.ready = false
        engine.scheduleRebuild(state: state,store: store,paused: false) { _,error in errors.append(error) }
        try await waitUntil { windows.values.count == 6 }
        XCTAssertTrue(errors.isEmpty,"Current mirrored mode must retain its compatibility fallback")
        XCTAssertNil(original.currentItem)
        let current = windows.surfaces
        XCTAssertEqual(current.count,2)
        let first = try XCTUnwrap(current[0].playerLayer.player),second = try XCTUnwrap(current[1].playerLayer.player)
        XCTAssertFalse(first === second);XCTAssertFalse(first === original);XCTAssertFalse(second === original)
        try await waitUntil { first.timeControlStatus == .playing && second.timeControlStatus == .playing }
        try await Task.sleep(for: .milliseconds(100));XCTAssertEqual(windows.values.count,6)
    }
}
