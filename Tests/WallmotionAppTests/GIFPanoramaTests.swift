import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
import WallmotionCore
@testable import Wallmotion

@MainActor
final class GIFPanoramaTests: XCTestCase {
    private final class Windows {
        var values: [NSWindow] = []
        var hidden: Set<ObjectIdentifier> = []
        func visible(_ window: NSWindow) -> Bool {
            if !values.contains(where: { $0 === window }) { values.append(window) }
            return !hidden.contains(ObjectIdentifier(window))
        }
    }
    private final class Targets { var values: [DesktopTarget] = [] }
    private func root() throws -> URL {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WallmotionGIFPanorama-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }
    private func writeFixture(_ url: URL) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 2, nil))
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for frame in 0..<2 {
            let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 16,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(frame == 0 ? NSColor.red.cgColor : NSColor.green.cgColor)
            context.fill(CGRect(x: 0,y: 0,width: 2,height: 2))
            context.setFillColor(frame == 0 ? NSColor.blue.cgColor : NSColor.yellow.cgColor)
            context.fill(CGRect(x: 2,y: 0,width: 2,height: 2))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()),
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: 0.2, kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(4)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition())
    }
    private func surfaces(_ windows: Windows) -> [ImageSurface] {
        windows.values.compactMap { $0.contentView as? ImageSurface }
    }

    func testProductionPanoramaSharesOneDecodeImageAndClockAndStopsWhenAllHidden() async throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Sem sessão gráfica") }
        let directory = try root();defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.gif");try writeFixture(url)
        let store = LibraryStore(rootURL: directory.appendingPathComponent("Library"))
        let item = try store.importFile(at: url), windows = Windows(), worker = GIFDecodeWorker(limit: 128)
        let frames = [CGRect(x: -10000,y: -10000,width: 100,height: 100), CGRect(x: -9900,y: -10000,width: 100,height: 100)]
        let engine = DesktopCoordinator(targets: { [DesktopTarget(id: "left", screen: screen, frame: frames[0], backingScale: 1),
            DesktopTarget(id: "right", screen: screen, frame: frames[1], backingScale: 2)] },
            isWindowVisible: { windows.visible($0) }, gifWorker: worker)
        defer { engine.stop() }
        let state = LibraryState(wallpapers: [item], displayMode: .spanned, mirroredWallpaperID: item.id, mirroredMediaFit: .stretch)
        engine.scheduleRebuild(state: state, store: store, paused: false) { _, message in XCTFail(message) }
        try await waitUntil { windows.values.count == 2 }
        let ordered = windows.values.sorted { $0.frame.minX < $1.frame.minX }
        let left = try XCTUnwrap(ordered[0].contentView as? ImageSurface), right = try XCTUnwrap(ordered[1].contentView as? ImageSurface)
        left.layoutSubtreeIfNeeded();right.layoutSubtreeIfNeeded()
        XCTAssertEqual(left.panoramaFrame, CGRect(x: 0,y: 0,width: 200,height: 100))
        XCTAssertEqual(right.panoramaFrame, CGRect(x: -100,y: 0,width: 200,height: 100))
        XCTAssertEqual(left.imageView.frame, left.panoramaFrame);XCTAssertEqual(right.imageView.frame, right.panoramaFrame)
        XCTAssertEqual(left.sourcePointSize, CGSize(width: 2,height: 1))
        XCTAssertEqual(right.sourcePointSize, left.sourcePointSize, "Mixed DPI uses the same global reference scale")
        XCTAssertTrue(left.imageView.image === right.imageView.image)
        XCTAssertEqual(engine.gifBudget.totalBytes, 64, "4×2×4×2 is charged once")
        let count = await worker.decodeCount;XCTAssertEqual(count, 1)
        let asset = try await worker.prepare(url: store.resolvedURL(for: item))
        let playback = try SharedGIFPlayback.playback(for: asset)
        XCTAssertEqual(playback.subscriberCount, 2);XCTAssertTrue(playback.hasScheduledTick)
        let initial = left.imageView.image
        try await waitUntil { left.imageView.image !== initial }
        XCTAssertTrue(left.imageView.image === right.imageView.image)
        windows.hidden.insert(ObjectIdentifier(ordered[0]))
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: ordered[0])
        XCTAssertFalse(left.gifIsPlaying);XCTAssertTrue(right.gifIsPlaying)
        XCTAssertTrue(playback.hasScheduledTick)
        windows.hidden.insert(ObjectIdentifier(ordered[1]))
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: ordered[1])
        XCTAssertFalse(playback.hasScheduledTick)
        let frozen = right.imageView.image
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(right.imageView.image === frozen)
        windows.hidden.removeAll()
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: ordered[0])
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: ordered[1])
        XCTAssertTrue(left.imageView.image === right.imageView.image);XCTAssertTrue(playback.hasScheduledTick)
        engine.stop()
        XCTAssertFalse(playback.hasScheduledTick);XCTAssertEqual(playback.subscriberCount, 0)
        XCTAssertEqual(engine.gifBudget.totalBytes, 0)
    }

    func testAllFitsShareGlobalGeometryWithNegativeOriginsGapsVerticalAndMixedScale() async throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Sem sessão gráfica") }
        let directory = try root();defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.gif");try writeFixture(url)
        let store = LibraryStore(rootURL: directory.appendingPathComponent("Library")), worker = GIFDecodeWorker()
        let item = try store.importFile(at: url)
        let frames = [CGRect(x: -10000,y: -10200,width: 100,height: 80), CGRect(x: -9950,y: -10000,width: 80,height: 100)]
        let targets = [DesktopTarget(id: "bottom", screen: screen, frame: frames[0], backingScale: 1),
            DesktopTarget(id: "top", screen: screen, frame: frames[1], backingScale: 2)]
        let layout = try XCTUnwrap(PanoramaLayout(frames: frames, backingScales: [1,2]))
        for fit in MediaFit.allCases {
            let windows = Windows()
            let engine = DesktopCoordinator(targets: { targets }, isWindowVisible: { windows.visible($0) }, gifWorker: worker)
            defer { engine.stop() }
            let state = LibraryState(wallpapers: [item], displayMode: .spanned, mirroredWallpaperID: item.id, mirroredMediaFit: fit)
            engine.scheduleRebuild(state: state, store: store, paused: true) { _, message in XCTFail(message) }
            try await waitUntil { windows.values.count == 2 }
            let global = windows.values.map { window -> CGRect in
                let surface = window.contentView as! ImageSurface
                surface.layoutSubtreeIfNeeded()
                return surface.imageView.frame.offsetBy(dx: window.frame.minX, dy: window.frame.minY)
            }
            XCTAssertEqual(global[0], global[1])
            let expected = layout.imageFrame(sourcePixels: CGSize(width: 4,height: 2), fit: fit, on: frames[0])
                .offsetBy(dx: frames[0].minX, dy: frames[0].minY)
            XCTAssertEqual(global[0], expected)
        }
    }

    func testRenderedSlicesContainDifferentHalvesOfSameFrame() async throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Sem sessão gráfica") }
        let directory = try root();defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.gif");try writeFixture(url)
        let store = LibraryStore(rootURL: directory.appendingPathComponent("Library")), windows = Windows()
        let item = try store.importFile(at: url)
        let engine = DesktopCoordinator(targets: { [DesktopTarget(id: "left", screen: screen,
            frame: CGRect(x: -10000,y: -10000,width: 100,height: 100)), DesktopTarget(id: "right", screen: screen,
            frame: CGRect(x: -9900,y: -10000,width: 100,height: 100))] }, isWindowVisible: { windows.visible($0) })
        defer { engine.stop() }
        let state = LibraryState(wallpapers: [item], displayMode: .spanned, mirroredWallpaperID: item.id, mirroredMediaFit: .stretch)
        engine.scheduleRebuild(state: state, store: store, paused: true) { _, message in XCTFail(message) }
        try await waitUntil { windows.values.count == 2 }
        let ordered = windows.values.sorted { $0.frame.minX < $1.frame.minX }
        for (index, window) in ordered.enumerated() {
            let surface = try XCTUnwrap(window.contentView as? ImageSurface)
            surface.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(surface.bitmapImageRepForCachingDisplay(in: surface.bounds))
            surface.cacheDisplay(in: surface.bounds, to: bitmap)
            let color = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
            if index == 0 {
                XCTAssertGreaterThan(color.redComponent, 0.8);XCTAssertLessThan(color.blueComponent, 0.2)
            } else {
                XCTAssertGreaterThan(color.blueComponent, 0.8);XCTAssertLessThan(color.redComponent, 0.2)
            }
            if let path = ProcessInfo.processInfo.environment["WALLMOTION_GIF_PANORAMA_SNAPSHOT_DIR"] {
                let output = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: output.appendingPathComponent(index == 0 ? "left.png" : "right.png"))
            }
        }
        let views = surfaces(windows)
        XCTAssertTrue(views[0].imageView.image === views[1].imageView.image)
    }

    func testTopologyRebuildReusesAssetAndPreservesCorrectNewSlice() async throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Sem sessão gráfica") }
        let directory = try root();defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.gif");try writeFixture(url)
        let store = LibraryStore(rootURL: directory.appendingPathComponent("Library"))
        let item = try store.importFile(at: url), windows = Windows(), worker = GIFDecodeWorker(), targets = Targets()
        targets.values = [DesktopTarget(id: "left", screen: screen, frame: CGRect(x: -10000,y: -10000,width: 100,height: 100)),
            DesktopTarget(id: "right", screen: screen, frame: CGRect(x: -9900,y: -10000,width: 100,height: 100))]
        let engine = DesktopCoordinator(targets: { targets.values }, isWindowVisible: { windows.visible($0) }, gifWorker: worker)
        defer { engine.stop() }
        let state = LibraryState(wallpapers: [item], displayMode: .spanned, mirroredWallpaperID: item.id, mirroredMediaFit: .stretch)
        engine.scheduleRebuild(state: state, store: store, paused: true) { _, message in XCTFail(message) }
        try await waitUntil { windows.values.count == 2 }
        let initial = surfaces(windows).first?.imageView.image
        let old = windows.values
        targets.values.removeLast()
        engine.scheduleRebuild(state: state, store: store, paused: true) { _, message in XCTFail(message) }
        try await waitUntil { windows.values.count == 3 }
        XCTAssertTrue(old.allSatisfy { !$0.isVisible })
        let current = try XCTUnwrap(windows.values.last?.contentView as? ImageSurface)
        current.layoutSubtreeIfNeeded()
        XCTAssertEqual(current.imageView.frame, CGRect(x: 0,y: 0,width: 100,height: 100))
        XCTAssertTrue(initial === current.imageView.image)
        let count = await worker.decodeCount;XCTAssertEqual(count, 1)
        XCTAssertEqual(engine.gifBudget.totalBytes, 64)
    }

    func testModelSeedsGIFPanoramaAndRestoresIndependentAssignmentsWithoutAcceptingVideo() async throws {
        let directory = try root();defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.gif");try writeFixture(url)
        let store = LibraryStore(rootURL: directory.appendingPathComponent("Library"))
        let gif = try store.importFile(at: url), video = try Wallpaper.remote("https://example.com/video.mp4")
        let initial = LibraryState(wallpapers: [gif,video], assignments: ["one": gif.id,"two": video.id])
        try store.save(initial)
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(),
            store: store, engine: DesktopCoordinator(targets: { [] }),
            connectedDisplays: { [Display(id: "one", name: "One"),Display(id: "two", name: "Two")] })
        defer { model.stop() }
        model.refreshPlayback(force: false);model.setDisplayMode(.spanned, sourceDisplayID: "one")
        try await waitUntil { !model.isPreparingWallpaper(on: "one") }
        XCTAssertEqual(model.state.displayMode, .spanned);XCTAssertEqual(model.state.mirroredWallpaperID, gif.id)
        XCTAssertEqual(model.activeWallpaperID(on: "two"), gif.id);XCTAssertEqual(try store.load(), model.state)
        XCTAssertNil(model.applicationRestriction(for: gif, on: "two"))
        XCTAssertNotNil(model.applicationRestriction(for: video, on: "one"))
        model.setMediaFit(.fill, on: "two")
        XCTAssertEqual(model.mediaFit(on: "one"), .fill)
        model.setDisplayMode(.independent, sourceDisplayID: "one")
        try await waitUntil { !model.isPreparingWallpaper(on: "one") }
        XCTAssertEqual(model.state.assignments, initial.assignments)
        XCTAssertEqual(model.activeWallpaperID(on: "two"), video.id)
        XCTAssertNil(model.errorMessage)
    }
}
