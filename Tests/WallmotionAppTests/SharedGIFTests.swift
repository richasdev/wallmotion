import AppKit
import XCTest
import WallmotionCore
@testable import Wallmotion

@MainActor
final class SharedGIFTests: XCTestCase {
    private func fixture(frames: Int = 2) -> Data {
        var bytes: [UInt8] = [0x47,0x49,0x46,0x38,0x39,0x61,1,0,1,0,0x80,0,0,0,0,0,255,255,255]
        for frame in 0..<frames {
            bytes += [0x21,0xf9,4,0,10,0,0,0,0x2c,0,0,0,0,1,0,1,0,0,2,2,frame % 2 == 0 ? 0x44 : 0x4c,1,0]
        }
        bytes.append(0x3b);return Data(bytes)
    }
    private func root() throws -> URL {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WallmotionSharedGIF-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }
    private func pixels(_ image: NSImage) throws -> [UInt8] {
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        return Array(try XCTUnwrap(cg.dataProvider?.data) as Data)
    }

    func testWorkerSharesHardLinksAndProviderRetainsItsBudgetAfterFactoryScopeEnds() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("one.gif"), alias = directory.appendingPathComponent("alias.gif")
        try fixture().write(to: url);try FileManager.default.linkItem(at: url, to: alias)
        let worker = GIFDecodeWorker(limit: 32, decode: { url, limits in
            XCTAssertFalse(Thread.isMainThread)
            return try GIFAnimation(url: url, limits: limits)
        })
        var asset: PreparedGIF? = try await worker.prepare(url: url)
        let weakAsset = WeakAsset(asset)
        var same: PreparedGIF? = try await worker.prepare(url: alias)
        XCTAssertTrue(asset === same)
        let count = await worker.decodeCount;XCTAssertEqual(count, 1)
        var image: CGImage? = try XCTUnwrap(asset).animation.image(at: 1, retaining: try XCTUnwrap(asset))
        asset = nil;same = nil
        XCTAssertNotNil(weakAsset.value)
        let retained = await worker.retainedBytes;XCTAssertEqual(retained, 8)
        let big = directory.appendingPathComponent("big.gif");try fixture(frames: 8).write(to: big)
        do { _ = try await worker.prepare(url: big);XCTFail("The provider's retained allocation must still count") }
        catch { XCTAssertEqual(error as? GIFPlaybackBudgetError, .exceeded(limit: 32)) }
        XCTAssertEqual(Array(try XCTUnwrap(image?.dataProvider?.data) as Data), [255,255,255,255])
        image = nil
        XCTAssertNil(weakAsset.value)
        let released = await worker.retainedBytes;XCTAssertEqual(released, 0)
        let next = try await worker.prepare(url: url)
        XCTAssertEqual(next.animation.frameCount, 2)
        let finalCount = await worker.decodeCount;XCTAssertEqual(finalCount, 2)
    }

    func testFileReplacementInvalidatesCacheAndCancelledNativeDecodeReleasesSerialSlot() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.gif");try fixture().write(to: url)
        let entered = expectation(description: "native worker entered")
        let gate = DispatchSemaphore(value: 0);defer { gate.signal() }
        let worker = GIFDecodeWorker(decode: { url, limits in
            entered.fulfill();gate.wait()
            return try GIFAnimation(url: url, limits: limits)
        })
        let request = Task { try await worker.prepare(url: url) }
        await fulfillment(of: [entered], timeout: 2)
        request.cancel();gate.signal()
        do { _ = try await request.value;XCTFail("Obsolete native decode must not publish") }
        catch { XCTAssertTrue(error is CancellationError) }
        let retained = await worker.retainedBytes;XCTAssertEqual(retained, 0)
        let normal = GIFDecodeWorker()
        let first = try await normal.prepare(url: url)
        try fixture(frames: 3).write(to: url, options: .atomic)
        let second = try await normal.prepare(url: url)
        XCTAssertNotEqual(first.identity, second.identity)
        XCTAssertFalse(first === second)
        XCTAssertEqual(first.animation.frameCount, 2)
        XCTAssertEqual(second.animation.frameCount, 3)
    }

    func testSharedClockPublishesOneImageSkipsFramesAndFreezesUntilAnySubscriberResumes() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.gif");try fixture().write(to: url)
        let asset = try await GIFDecodeWorker().prepare(url: url)
        let clock = Clock()
        var playback: SharedGIFPlayback? = try SharedGIFPlayback(asset: asset, now: { clock.value })
        let weakPlayback = WeakPlayback(playback)
        var left: NSImage?, right: NSImage?
        let one = try XCTUnwrap(playback).subscribe(image: { left = $0 })
        let two = try XCTUnwrap(playback).subscribe(image: { right = $0 })
        XCTAssertTrue(left === right)
        playback?.setActive(true, subscriber: one);playback?.setActive(true, subscriber: two)
        XCTAssertTrue(playback?.hasScheduledTick == true)
        clock.value = 0.15;playback?.advance()
        XCTAssertTrue(left === right)
        XCTAssertEqual(try pixels(XCTUnwrap(left)), [255,255,255,255])
        playback?.setActive(false, subscriber: one)
        clock.value = 0.45;playback?.advance()
        XCTAssertTrue(playback?.hasScheduledTick == true)
        XCTAssertEqual(try pixels(XCTUnwrap(right)), [0,0,0,255])
        XCTAssertEqual(try pixels(XCTUnwrap(left)), [255,255,255,255], "An occluded view is not repainted")
        playback?.setActive(false, subscriber: two)
        XCTAssertFalse(playback?.hasScheduledTick == true)
        clock.value = 100;playback?.advance()
        XCTAssertFalse(playback?.hasScheduledTick == true)
        playback?.setActive(true, subscriber: one)
        XCTAssertEqual(try pixels(XCTUnwrap(left)), [0,0,0,255])
        clock.value += 0.1;playback?.advance()
        XCTAssertEqual(try pixels(XCTUnwrap(left)), [255,255,255,255])
        playback?.unsubscribe(one);playback?.unsubscribe(two)
        XCTAssertFalse(playback?.hasScheduledTick == true)
        playback = nil
        XCTAssertNil(weakPlayback.value, "The suspended Task and weak registry must not retain the clock")
    }

    func testRealTimerSharesFramesAndSingleFrameNeedsNoTimer() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.gif");try fixture().write(to: url)
        let asset = try await GIFDecodeWorker().prepare(url: url)
        let playback = try SharedGIFPlayback.playback(for: asset)
        XCTAssertTrue(try SharedGIFPlayback.playback(for: asset) === playback)
        var left: NSImage?, right: NSImage?
        let one = playback.subscribe(image: { left = $0 }), two = playback.subscribe(image: { right = $0 })
        defer { playback.unsubscribe(one);playback.unsubscribe(two) }
        playback.setActive(true, subscriber: one);playback.setActive(true, subscriber: two)
        try await waitUntil { playback.frameIndex == 1 }
        XCTAssertTrue(left === right)
        XCTAssertEqual(try pixels(XCTUnwrap(left)), [255,255,255,255])
        try await waitUntil { playback.frameIndex == 0 }
        try await waitUntil { playback.frameIndex == 1 }
        XCTAssertTrue(left === right, "The real timer keeps sharing frames across repeated loops")
        playback.setActive(false, subscriber: one);playback.setActive(false, subscriber: two)
        let frozen = left
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertTrue(left === frozen);XCTAssertFalse(playback.hasScheduledTick)
        let stillURL = directory.appendingPathComponent("still.gif");try fixture(frames: 1).write(to: stillURL)
        let stillAsset = try await GIFDecodeWorker().prepare(url: stillURL)
        let still = try SharedGIFPlayback(asset: stillAsset)
        let id = still.subscribe(image: { _ in });still.setActive(true, subscriber: id)
        XCTAssertFalse(still.hasScheduledTick);still.unsubscribe(id)
    }

    func testDirectoryWatcherRetriesAfterBadAtomicReplacementAndUnrelatedWritesStayQuiet() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.gif");try fixture().write(to: url)
        let asset = try await GIFDecodeWorker().prepare(url: url)
        let playback = try SharedGIFPlayback(asset: asset)
        var changes: [GIFFileIdentity?] = []
        let id = playback.subscribe(url: url, image: { _ in }, changed: { changes.append(try? GIFFileIdentity.read(url: url)) })
        defer { playback.unsubscribe(id) }
        try Data([1]).write(to: directory.appendingPathComponent("unrelated"))
        try await Task.sleep(for: .milliseconds(80));XCTAssertTrue(changes.isEmpty)
        try Data("broken".utf8).write(to: url, options: .atomic)
        let broken = try GIFFileIdentity.read(url: url)
        try await waitUntil { changes.contains(broken) }
        try await Task.sleep(for: .milliseconds(100))
        try fixture(frames: 3).write(to: url, options: .atomic)
        let repaired = try GIFFileIdentity.read(url: url)
        XCTAssertNotEqual(broken, repaired)
        try await waitUntil { changes.contains(repaired) }
        XCTAssertEqual(try pixels(playback.currentImage), [0,0,0,255], "Failed reloads never mutate the immutable old frame")
    }
    func testReplacementBeforeWatcherInstallationStillNotifiesSubscriber() async throws {
        let directory = try root();defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.gif");try fixture().write(to: url)
        let asset = try await GIFDecodeWorker().prepare(url: url)
        let playback = try SharedGIFPlayback(asset: asset)
        try fixture(frames: 3).write(to: url, options: .atomic)
        var changed = false
        let id = playback.subscribe(url: url, image: { _ in }, changed: { changed = true })
        defer { playback.unsubscribe(id) }
        XCTAssertFalse(changed, "Callback waits until subscribe and renderer installation can finish")
        try await waitUntil { changed }
    }

    func testPendingPreparationReusesDecodeAndPublishesOnlyLatestCompletion() async throws {
        let directory = try root();defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.gif");try fixture().write(to: url)
        let gate = DispatchSemaphore(value: 0);defer { gate.signal() }
        let entered = expectation(description: "shared pending decode entered")
        let worker = GIFDecodeWorker(decode: { url, limits in
            entered.fulfill();gate.wait();return try GIFAnimation(url: url, limits: limits)
        })
        let preparation = SharedGIFPreparation(worker: worker)
        var obsoleteCalled = false
        preparation.submit(["left": url, "right": url]) { _ in obsoleteCalled = true }
        await fulfillment(of: [entered], timeout: 2)
        let installed = expectation(description: "latest completion receives shared asset")
        preparation.submit(["left": url, "right": url]) { outcome in
            let results = outcome.images
            do {
                let left = try XCTUnwrap(results["left"]).get(), right = try XCTUnwrap(results["right"]).get()
                XCTAssertTrue(left === right)
            } catch { XCTFail("\(error)") }
            installed.fulfill()
        }
        gate.signal()
        await fulfillment(of: [installed], timeout: 2)
        XCTAssertFalse(obsoleteCalled)
        let count = await worker.decodeCount;XCTAssertEqual(count, 1)
        preparation.cancel()
    }

    func testChangedPreparationDiscardsUncooperativeOldDecode() async throws {
        let directory = try root();defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("one.gif"), second = directory.appendingPathComponent("two.gif")
        try fixture().write(to: first);try fixture(frames: 3).write(to: second)
        let gate = DispatchSemaphore(value: 0);defer { gate.signal() }
        let entered = expectation(description: "obsolete native decode entered")
        let worker = GIFDecodeWorker(decode: { url, limits in
            if url == first { entered.fulfill();gate.wait() }
            return try GIFAnimation(url: url, limits: limits)
        })
        let preparation = SharedGIFPreparation(worker: worker)
        var obsoleteCalled = false
        preparation.submit(["left": first]) { _ in obsoleteCalled = true }
        await fulfillment(of: [entered], timeout: 2)
        let installed = expectation(description: "replacement decode published")
        preparation.submit(["right": second]) { outcome in
            let results = outcome.images
            XCTAssertNil(results["left"])
            XCTAssertEqual(try? results["right"]?.get().animation.frameCount, 3)
            installed.fulfill()
        }
        gate.signal();await fulfillment(of: [installed], timeout: 2)
        XCTAssertFalse(obsoleteCalled)
        let count = await worker.decodeCount;XCTAssertEqual(count, 2)
        preparation.cancel()
    }

    private final class WeakAsset {
        weak var value: PreparedGIF?
        init(_ value: PreparedGIF?) { self.value = value }
    }
    private final class WeakPlayback {
        weak var value: SharedGIFPlayback?
        init(_ value: SharedGIFPlayback?) { self.value = value }
    }
    @MainActor private final class Clock { var value = 0.0 }

    private final class Windows {
        var values: [NSWindow] = []
        func visible(_ window: NSWindow) -> Bool {
            if !values.contains(where: { $0 === window }) { values.append(window) }
            return true
        }
    }

    func testCoordinatorMirrorsSameNativeImageWithoutChangingPerMonitorCenterGeometry() async throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Sem sessão gráfica") }
        let directory = try root();defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.gif");try fixture().write(to: url)
        let store = LibraryStore(rootURL: directory.appendingPathComponent("Library"))
        let item = try store.importFile(at: url)
        let worker = GIFDecodeWorker(limit: 128), windows = Windows()
        func installAndStop() async throws {
            let engine = DesktopCoordinator(gifBudgetLimit: 128, targets: {
                [DesktopTarget(id: "left", screen: screen, frame: CGRect(x: 0,y: 0,width: 100,height: 100), backingScale: 1),
                 DesktopTarget(id: "right", screen: screen, frame: CGRect(x: 100,y: 0,width: 100,height: 100), backingScale: 2)]
            }, isWindowVisible: { windows.visible($0) }, gifWorker: worker)
            defer { engine.stop() }
            var state = LibraryState(wallpapers: [item], displayMode: .mirrored, mirroredWallpaperID: item.id, mirroredMediaFit: .center)
            engine.scheduleRebuild(state: state, store: store, paused: true) { _, message in XCTFail(message) }
            try await waitUntil { windows.values.count == 2 }
            let left = try XCTUnwrap(windows.values.first { $0.frame.minX == 0 }?.contentView as? ImageSurface)
            let right = try XCTUnwrap(windows.values.first { $0.frame.minX == 100 }?.contentView as? ImageSurface)
            XCTAssertTrue(left.imageView.image === right.imageView.image)
            left.layoutSubtreeIfNeeded();right.layoutSubtreeIfNeeded()
            XCTAssertEqual(left.imageView.frame.size, CGSize(width: 1,height: 1))
            XCTAssertEqual(right.imageView.frame.size, CGSize(width: 0.5,height: 0.5))
            XCTAssertEqual(left.imageView.image?.size, CGSize(width: 1,height: 1), "Shared image size must never be mutated for a monitor")
            XCTAssertEqual(engine.gifBudget.totalBytes, 8)
            let count = await worker.decodeCount;XCTAssertEqual(count, 1)
            engine.setPaused(false)
            XCTAssertTrue(left.gifIsPlaying);XCTAssertTrue(right.gifIsPlaying)
            try await waitUntil { (try? self.pixels(XCTUnwrap(left.imageView.image))) == [255,255,255,255] }
            XCTAssertTrue(left.imageView.image === right.imageView.image)
            engine.setPaused(true)
            XCTAssertFalse(left.gifIsPlaying);XCTAssertFalse(right.gifIsPlaying)
            state.displayMode = .independent;state.mirroredWallpaperID = nil;state.assignments = ["right": item.id]
            engine.scheduleRebuild(state: state, store: store, paused: true) { _, message in XCTFail(message) }
            try await waitUntil { left.imageView.image == nil }
            XCTAssertEqual(engine.gifBudget.totalBytes, 8)
            engine.stop()
            XCTAssertNil(right.imageView.image)
        }
        try await installAndStop()
        let deadline = ContinuousClock.now + .seconds(3)
        while await worker.retainedBytes != 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let released = await worker.retainedBytes;XCTAssertEqual(released, 0)
    }

    func testCoordinatorPreservesOldPixelsAfterCorruptionAndReloadsRepairedSource() async throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Sem sessão gráfica") }
        let directory = try root();defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.gif");try fixture().write(to: url)
        let store = LibraryStore(rootURL: directory.appendingPathComponent("Library")), windows = Windows()
        let item = try store.importFile(at: url), worker = GIFDecodeWorker(limit: 128)
        let managed = try store.resolvedURL(for: item)
        let engine = DesktopCoordinator(targets: { [DesktopTarget(id: "left", screen: screen)] },
            isWindowVisible: { windows.visible($0) }, gifWorker: worker)
        defer { engine.stop() }
        var errors: [String] = []
        let state = LibraryState(wallpapers: [item], assignments: ["left": item.id])
        engine.scheduleRebuild(state: state, store: store, paused: true) { _, message in errors.append(message) }
        try await waitUntil { windows.values.count == 1 }
        let original = try XCTUnwrap(windows.values.first)
        let surface = try XCTUnwrap(original.contentView as? ImageSurface)
        try Data("corrupt".utf8).write(to: managed, options: .atomic)
        try await waitUntil { !errors.isEmpty }
        XCTAssertTrue(original.isVisible);XCTAssertEqual(windows.values.count, 1)
        XCTAssertEqual(try pixels(XCTUnwrap(surface.imageView.image)), [0,0,0,255])
        var compressedFailure = Array(fixture())
        let code = try XCTUnwrap(compressedFailure.indices.dropLast().first {
            compressedFailure[$0] == 0x44 && compressedFailure[$0+1] == 1
        })
        compressedFailure[code] = 0xff;compressedFailure[code+1] = 0xff
        try Data(compressedFailure).write(to: managed, options: .atomic)
        XCTAssertNoThrow(try GIFPreflight.inspect(url: managed), "Structural admission does not decode compressed pixels")
        let count = errors.count
        try await waitUntil { errors.count > count }
        let attempts = await worker.decodeCount
        XCTAssertGreaterThanOrEqual(attempts, 2, "The structurally admitted corruption reached the native worker")
        XCTAssertTrue(original.isVisible);XCTAssertEqual(windows.values.count, 1)
        try fixture(frames: 3).write(to: managed, options: .atomic)
        try await waitUntil { windows.values.count == 2 }
        XCTAssertFalse(original.isVisible);XCTAssertNil(surface.imageView.image)
        XCTAssertEqual(engine.gifBudget.totalBytes, 12)
    }

    func testSourceWatcherCannotBypassMemoryWarningDeferral() async throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Sem sessão gráfica") }
        let directory = try root();defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.gif");try fixture().write(to: url)
        let store = LibraryStore(rootURL: directory.appendingPathComponent("Library")), windows = Windows()
        let item = try store.importFile(at: url), worker = GIFDecodeWorker(limit: 128)
        let managed = try store.resolvedURL(for: item)
        let engine = DesktopCoordinator(targets: { [DesktopTarget(id: "left", screen: screen)] },
            isWindowVisible: { windows.visible($0) }, gifWorker: worker)
        defer { engine.stop() }
        let state = LibraryState(wallpapers: [item], assignments: ["left": item.id])
        engine.scheduleRebuild(state: state, store: store, paused: true) { _, message in XCTFail(message) }
        try await waitUntil { windows.values.count == 1 }
        engine.scheduleRebuild(state: state, store: store, paused: true, deferNewRenderers: true) { _, message in XCTFail(message) }
        try fixture(frames: 3).write(to: managed, options: .atomic)
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(windows.values.count, 1)
        XCTAssertEqual(engine.gifBudget.totalBytes, 8)
        let deferredCount = await worker.decodeCount;XCTAssertEqual(deferredCount, 1)
        engine.scheduleRebuild(state: state, store: store, paused: true) { _, message in XCTFail(message) }
        try await waitUntil { windows.values.count == 2 }
        XCTAssertEqual(engine.gifBudget.totalBytes, 12)
    }

    func testOldPhotoCannotInstallWhileNewGIFGenerationIsWaiting() async throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Sem sessão gráfica") }
        let directory = try root();defer { try? FileManager.default.removeItem(at: directory) }
        let gifURL = directory.appendingPathComponent("source.gif");try fixture().write(to: gifURL)
        let store = LibraryStore(rootURL: directory.appendingPathComponent("Library"))
        let gif = try store.importFile(at: gifURL)
        let photoURL = directory.appendingPathComponent("photo.png")
        let bitmap = NSBitmapImageRep(cgImage: try GIFAnimation(data: fixture()).image(at: 0))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: photoURL)
        let photo = try store.importFile(at: photoURL)
        let photoGate = PhotoTestGate(), gifGate = DispatchSemaphore(value: 0)
        defer { gifGate.signal() }
        let photoEntered = expectation(description: "old photo prepared")
        let photoReturned = expectation(description: "old photo returned")
        let gifEntered = expectation(description: "new GIF worker entered")
        let worker = GIFDecodeWorker(decode: { url, limits in
            gifEntered.fulfill();gifGate.wait();return try GIFAnimation(url: url, limits: limits)
        })
        let windows = Windows()
        let engine = DesktopCoordinator(targets: { [DesktopTarget(id: "left", screen: screen)] },
            isWindowVisible: { windows.visible($0) }, photoDecoder: { request in
                let result = try await PhotoDecodeWorker.shared.decode(request)
                photoEntered.fulfill();await photoGate.wait();photoReturned.fulfill();return result
            }, gifWorker: worker)
        defer { engine.stop() }
        var state = LibraryState(wallpapers: [photo, gif], assignments: ["left": photo.id])
        engine.scheduleRebuild(state: state, store: store, paused: true) { _, message in XCTFail(message) }
        await fulfillment(of: [photoEntered], timeout: 2)
        state.assignments = ["left": gif.id]
        engine.scheduleRebuild(state: state, store: store, paused: true) { _, message in XCTFail(message) }
        await fulfillment(of: [gifEntered], timeout: 2)
        await photoGate.release()
        await fulfillment(of: [photoReturned], timeout: 2)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(windows.values.isEmpty, "Stale photo completion cannot install while the latest GIF is still decoding")
        gifGate.signal()
        try await waitUntil { windows.values.count == 1 }
        XCTAssertEqual(engine.gifBudget.totalBytes, 8)
    }

}
