import AppKit
import AVFoundation
import WebKit
import SwiftUI
import XCTest
import WallmotionCore
@testable import Wallmotion

@MainActor
final class SourceAudioGainTests: XCTestCase {
    private final class Windows {
        var values: [NSWindow] = []
        func visible(_ window: NSWindow) -> Bool {
            if !values.contains(where: { $0 === window }) { values.append(window) }
            return true
        }
    }
    private func directory() throws -> URL {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WallmotionSourceAudio-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }
    private func targets(_ screen: NSScreen) -> [DesktopTarget] {
        [DesktopTarget(id: "left", screen: screen, frame: CGRect(x: -10000,y: -10000,width: 200,height: 100)),
         DesktopTarget(id: "right", screen: screen, frame: CGRect(x: -9800,y: -10000,width: 200,height: 100))]
    }
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }

    func testNativeGainMasterAndOwnerChangesKeepPlayersItemsAndWindows() async throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Sem sessão gráfica") }
        let root = try directory();defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("video.mp4");try await LocalVideoFixture.write(at: url)
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library")), windows = Windows()
        let first = try store.importFile(at: url), second = try store.importFile(at: url)
        var state = LibraryState(wallpapers: [first, second], assignments: ["left": first.id, "right": second.id],
            settings: .init(isManuallyPaused: true, audioDisplayID: "left", audioVolume: 0.8))
        state.setAudioGain(0.25, for: first.id);state.setAudioGain(0.75, for: second.id)
        try store.save(state)
        let engine = DesktopCoordinator(targets: { self.targets(screen) }, isWindowVisible: { windows.visible($0) })
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), purgeThumbnails: {},
            store: store, engine: engine, connectedDisplays: { [Display(id: "left", name: "Left"), Display(id: "right", name: "Right")] })
        defer { model.stop() }
        model.refreshPlayback(force: false);try await waitUntil { windows.values.count == 2 }
        let leftWindow = try XCTUnwrap(windows.values.first { $0.frame.minX == -10000 })
        let rightWindow = try XCTUnwrap(windows.values.first { $0.frame.minX == -9800 })
        let left = try XCTUnwrap((leftWindow.contentView as? VideoSurface)?.playerLayer.player)
        let right = try XCTUnwrap((rightWindow.contentView as? VideoSurface)?.playerLayer.player)
        XCTAssertTrue(left.isMuted);XCTAssertEqual(left.volume, 0)
        XCTAssertTrue(right.isMuted);XCTAssertEqual(right.volume, 0)
        try await waitUntil { left.currentItem != nil && right.currentItem != nil }
        let leftItem = try XCTUnwrap(left.currentItem), rightItem = try XCTUnwrap(right.currentItem)
        model.togglePause();engine.setPaused(model.isPaused)
        XCTAssertEqual(left.volume, 0.2, accuracy: 0.0001);XCTAssertFalse(left.isMuted)
        XCTAssertEqual(right.volume, 0);XCTAssertTrue(right.isMuted)
        model.setAudioGain(0.5, for: first.id)
        XCTAssertEqual(left.volume, 0.4, accuracy: 0.0001)
        model.setAudioVolume(0.5)
        XCTAssertEqual(left.volume, 0.25, accuracy: 0.0001)
        model.setAudioDisplayID("right")
        XCTAssertEqual(left.volume, 0);XCTAssertTrue(left.isMuted)
        XCTAssertEqual(right.volume, 0.375, accuracy: 0.0001);XCTAssertFalse(right.isMuted)
        model.setAudioGain(0, for: second.id)
        XCTAssertEqual(right.volume, 0);XCTAssertTrue(right.isMuted)
        model.togglePause();model.togglePause()
        XCTAssertEqual(right.volume, 0);XCTAssertTrue(right.isMuted)
        model.setAudioGain(1, for: second.id)
        XCTAssertEqual(right.volume, 0.5, accuracy: 0.0001);XCTAssertFalse(right.isMuted)
        var pending = model.state;pending.assignments["right"] = first.id
        engine.setAudioPreferences(state: pending)
        XCTAssertEqual(right.volume, 0, "A retained old renderer must not regain audio during a pending assignment")
        XCTAssertTrue(right.isMuted)
        engine.setAudioPreferences(state: model.state)
        XCTAssertEqual(right.volume, 0.5, accuracy: 0.0001)
        XCTAssertEqual(windows.values.count, 2)
        XCTAssertTrue((leftWindow.contentView as? VideoSurface)?.playerLayer.player === left)
        XCTAssertTrue((rightWindow.contentView as? VideoSurface)?.playerLayer.player === right)
        XCTAssertTrue(left.currentItem === leftItem);XCTAssertTrue(right.currentItem === rightItem)
        XCTAssertEqual(try store.load(), model.state)
        model.stop()
        XCTAssertEqual(left.volume, 0);XCTAssertTrue(left.isMuted)
        XCTAssertEqual(right.volume, 0);XCTAssertTrue(right.isMuted)
    }

    func testComposedLevelsReachBothWebProvidersOfflineAndOwnerTransferSendsZero() async throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Sem sessão gráfica") }
        let root = try directory();defer { try? FileManager.default.removeItem(at: root) }
        let youtube = try Wallpaper.web("https://youtu.be/M7lc1UVf-VE"), vimeo = try Wallpaper.web("https://vimeo.com/76979871")
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library")), windows = Windows()
        var state = LibraryState(wallpapers: [youtube, vimeo], assignments: ["left": youtube.id, "right": vimeo.id], settings: .init(audioDisplayID: "left", audioVolume: 0.8))
        state.setAudioGain(0.5, for: youtube.id);state.setAudioGain(0.25, for: vimeo.id)
        try store.save(state)
        let document = """
        <script>window.volume=-1;window.audio=false;window.setAudioPolicy=function(enabled,level){window.audio=enabled;window.volume=level};
        window.webkit.messageHandlers.playback.postMessage('ready');</script>
        """
        let engine = DesktopCoordinator(targets: { self.targets(screen) }, isWindowVisible: { windows.visible($0) }, webDocument: document)
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), purgeThumbnails: {},
            store: store, engine: engine, connectedDisplays: { [Display(id: "left", name: "Left"), Display(id: "right", name: "Right")] })
        defer { model.stop() }
        model.refreshPlayback(force: false);try await waitUntil { windows.values.count == 2 }
        let leftSurface = try XCTUnwrap(windows.values.first { $0.frame.minX == -10000 }?.contentView)
        let rightSurface = try XCTUnwrap(windows.values.first { $0.frame.minX == -9800 }?.contentView)
        let left = try XCTUnwrap(leftSurface.subviews.first as? WKWebView), right = try XCTUnwrap(rightSurface.subviews.first as? WKWebView)
        func waitFor(_ view: WKWebView, level: Double, audible: Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(3)
            while ContinuousClock.now < deadline {
                let result = try? await view.evaluateJavaScript("({volume:window.volume,audio:window.audio})")
                if let object = result as? [String: Any], let volume = object["volume"] as? Double,
                   abs(volume-level) < 0.0001, object["audio"] as? Bool == audible { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTFail("Composed volume did not reach offline web document")
        }
        try await waitFor(left, level: 0.4, audible: true);try await waitFor(right, level: 0, audible: false)
        model.setAudioGain(0.25, for: youtube.id);try await waitFor(left, level: 0.2, audible: true)
        model.setAudioVolume(0.4);try await waitFor(left, level: 0.1, audible: true)
        model.setAudioDisplayID("right")
        try await waitFor(left, level: 0, audible: false);try await waitFor(right, level: 0.1, audible: true)
        model.setAudioGain(0.5, for: vimeo.id);try await waitFor(right, level: 0.2, audible: true)
        XCTAssertTrue(leftSurface.subviews.first === left);XCTAssertTrue(rightSurface.subviews.first === right)
        XCTAssertEqual(windows.values.count, 2, "Changing levels or ownership never reconstructs a web view/window")
        model.setAudioDisplayID(nil)
        try await waitFor(left, level: 0, audible: false);try await waitFor(right, level: 0, audible: false)
    }

    func testLatePhotoPreparationUsesCurrentOwnerMasterAndSourceLevel() async throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Sem sessão gráfica") }
        let root = try directory();defer { try? FileManager.default.removeItem(at: root) }
        let videoURL = root.appendingPathComponent("video.mp4");try await LocalVideoFixture.write(at: videoURL)
        let context = try XCTUnwrap(CGContext(data: nil, width: 2,height: 2,bitsPerComponent: 8,bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let png = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        let photoURL = root.appendingPathComponent("photo.png")
        try XCTUnwrap(png.representation(using: .png, properties: [:])).write(to: photoURL)
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library")), windows = Windows()
        let photo = try store.importFile(at: photoURL), video = try store.importFile(at: videoURL)
        let state = LibraryState(wallpapers: [photo, video], assignments: ["left": photo.id,"right": video.id], settings: .init(audioDisplayID: "right", audioVolume: 0.8))
        try store.save(state)
        let gate = PhotoTestGate(), entered = expectation(description: "photo decode pending")
        let engine = DesktopCoordinator(targets: { self.targets(screen) }, isWindowVisible: { windows.visible($0) }, photoDecoder: { request in
            let image = try await PhotoDecodeWorker.shared.decode(request)
            entered.fulfill();await gate.wait();return image
        })
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), purgeThumbnails: {},
            store: store, engine: engine, connectedDisplays: { [Display(id: "left", name: "Left"), Display(id: "right", name: "Right")] })
        defer { model.stop() }
        model.refreshPlayback(force: false);await fulfillment(of: [entered], timeout: 2)
        model.setAudioDisplayID(nil);model.setAudioVolume(0.2);model.setAudioGain(0.5, for: video.id)
        await gate.release();try await waitUntil { windows.values.count == 2 }
        let player = try XCTUnwrap((windows.values.first { $0.frame.minX == -9800 }?.contentView as? VideoSurface)?.playerLayer.player)
        XCTAssertTrue(player.isMuted);XCTAssertEqual(player.volume, 0)
        model.setAudioDisplayID("right")
        XCTAssertFalse(player.isMuted);XCTAssertEqual(player.volume, 0.1, accuracy: 0.0001)
        XCTAssertEqual(windows.values.count, 2)
    }

    func testGIFWatcherRescheduleCannotRestoreAnOldAudioOwnerOrLevel() async throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Sem sessão gráfica") }
        let root = try directory();defer { try? FileManager.default.removeItem(at: root) }
        let videoURL = root.appendingPathComponent("video.mp4");try await LocalVideoFixture.write(at: videoURL)
        let gifURL = root.appendingPathComponent("input.gif")
        func gif(_ frames: Int) -> Data {
            var bytes: [UInt8] = [0x47,0x49,0x46,0x38,0x39,0x61,1,0,1,0,0x80,0,0,0,0,0,255,255,255]
            for _ in 0..<frames { bytes += [0x21,0xf9,4,0,10,0,0,0,0x2c,0,0,0,0,1,0,1,0,0,2,2,0x44,1,0] }
            bytes.append(0x3b);return Data(bytes)
        }
        try gif(2).write(to: gifURL)
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library")), windows = Windows()
        let animation = try store.importFile(at: gifURL), video = try store.importFile(at: videoURL)
        let state = LibraryState(wallpapers: [animation, video], assignments: ["left": animation.id,"right": video.id], settings: .init(audioDisplayID: "right", audioVolume: 0.8))
        try store.save(state)
        let engine = DesktopCoordinator(targets: { self.targets(screen) }, isWindowVisible: { windows.visible($0) }, gifWorker: GIFDecodeWorker(admissionWorker: GIFAdmissionWorker()))
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), purgeThumbnails: {},
            store: store, engine: engine, connectedDisplays: { [Display(id: "left", name: "Left"), Display(id: "right", name: "Right")] })
        defer { model.stop() }
        model.refreshPlayback(force: false);try await waitUntil { windows.values.count == 2 }
        let player = try XCTUnwrap((windows.values.first { $0.frame.minX == -9800 }?.contentView as? VideoSurface)?.playerLayer.player)
        model.setAudioDisplayID(nil);model.setAudioVolume(0.2);model.setAudioGain(0.5, for: video.id)
        try gif(3).write(to: store.resolvedURL(for: animation), options: .atomic)
        try await waitUntil { windows.values.count == 3 }
        XCTAssertTrue(player.isMuted);XCTAssertEqual(player.volume, 0)
        model.setAudioDisplayID("right")
        XCTAssertFalse(player.isMuted);XCTAssertEqual(player.volume, 0.1, accuracy: 0.0001)
        XCTAssertEqual(windows.values.count, 3, "Only the changed GIF gets a replacement window")
    }

    func testInvalidAndFailedPreferenceSavesDoNotChangeSourcesAndRemovalCleansOnlyItsGain() async throws {
        let root = try directory();defer { try? FileManager.default.removeItem(at: root) }
        let first = try Wallpaper.remote("https://cdn.example.com/first.mp4"), second = try Wallpaper.remote("https://cdn.example.com/second.mp4")
        let photo = Wallpaper(title: "Photo", kind: .image, source: .local(filename: "photo.png"))
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library"))
        try store.save(LibraryState(wallpapers: [first, second, photo], assignments: ["left": first.id], settings: .init(audioVolume: 0.5)))
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), purgeThumbnails: {},
            store: store, engine: DesktopCoordinator(targets: { [] }), connectedDisplays: { [Display(id: "left", name: "Left")] })
        defer { model.stop() };model.refreshPlayback(force: false)
        model.setAudioGain(0.2, for: first.id);model.setAudioGain(0.7, for: second.id)
        let accepted = model.state
        if let path = ProcessInfo.processInfo.environment["WALLMOTION_SOURCE_AUDIO_SNAPSHOT_PATH"] {
            try await captureSource(model: model, wallpaperID: first.id, path: path)
        }
        for value in [-1.0, 1.01, Double.nan, .infinity, -.infinity] { model.setAudioGain(value, for: first.id) }
        model.setAudioGain(0.1, for: photo.id);model.setAudioGain(0.1, for: UUID())
        XCTAssertEqual(model.state, accepted);XCTAssertEqual(try store.load(), accepted)
        model.remove(first)
        XCTAssertNil(model.state.audioGains[first.id.uuidString]);XCTAssertEqual(model.state.audioGain(for: second.id), 0.7)
        let afterRemoval = model.state
        try FileManager.default.removeItem(at: store.stateURL)
        try FileManager.default.createDirectory(at: store.stateURL, withIntermediateDirectories: false)
        model.setAudioGain(0.4, for: second.id)
        XCTAssertEqual(model.state, afterRemoval);XCTAssertTrue(model.errorMessage?.contains("salvar") == true)
    }
    private func captureSource(model: LibraryModel, wallpaperID: UUID, path: String) async throws {
        let light = ProcessInfo.processInfo.environment["WALLMOTION_SOURCE_AUDIO_LIGHT"] == "1"
        let root = VStack(alignment: .leading, spacing: 16) {
            Text("Volume geral · 50%").font(.headline)
            Divider()
            SourceAudioControls(model: model, wallpaperID: wallpaperID)
        }.padding(20).frame(width: 460).background(Color(nsColor: .controlBackgroundColor))
        let hosting = NSHostingView(rootView: root)
        let bounds = CGRect(x: 0,y: 0,width: 460,height: 200)
        hosting.appearance = NSAppearance(named: light ? .aqua : .darkAqua);hosting.frame = bounds
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false;window.contentView = hosting
        window.setFrameOrigin(CGPoint(x: -10000,y: -10000));window.orderBack(nil)
        defer { window.orderOut(nil);window.close() }
        try await Task.sleep(for: .milliseconds(150))
        let bitmap = try await LibrarySnapshotCapture.capture(hosting)
        let destination = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: destination)
    }

}
