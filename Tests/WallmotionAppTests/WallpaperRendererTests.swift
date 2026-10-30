import AppKit
import AVFoundation
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import XCTest
import WallmotionCore
@testable import Wallmotion

@MainActor
final class WallpaperRendererTests: XCTestCase {
    @MainActor private final class TestScreens {
        var values: [NSScreen]
        init(_ values: [NSScreen]) { self.values = values }
    }

    @MainActor private final class TestVisibility {
        var visible = false
    }

    @MainActor private final class TestSeeks {
        var completions: [@MainActor @Sendable (Bool) -> Void] = []
    }

    @MainActor private final class TestWindowVisibility {
        var windows: [NSWindow] = []
        var visible: [ObjectIdentifier: Bool] = [:]

        func isVisible(_ window: NSWindow) -> Bool {
            let key = ObjectIdentifier(window)
            if visible[key] == nil {
                windows.append(window)
                visible[key] = true
            }
            return visible[key] == true
        }
    }

    private func eventually(timeout: Duration = .seconds(5), _ predicate: @MainActor () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }

    private func writeShortVideo(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 16, AVVideoHeightKey: 16
        ]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw XCTSkip("O encoder H.264 não está disponível nesta sessão.")
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 16,
            kCVPixelBufferHeightKey as String: 16,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "WallmotionVideoFixture", code: 1)
        }
        defer { if writer.status == .writing { writer.cancelWriting() } }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<3 {
            guard try await eventually({ input.isReadyForMoreMediaData || writer.status == .failed }) else {
                throw NSError(domain: "WallmotionVideoFixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Timeout esperando encoder H.264"])
            }
            if let error = writer.error { throw error }
            var optionalBuffer: CVPixelBuffer?
            let result = CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true
            ] as CFDictionary, &optionalBuffer)
            XCTAssertEqual(result, kCVReturnSuccess)
            let buffer = try XCTUnwrap(optionalBuffer)
            XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
            do {
                defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
                let context = try XCTUnwrap(CGContext(
                    data: CVPixelBufferGetBaseAddress(buffer), width: 16, height: 16,
                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
                ))
                context.setFillColor(CGColor(red: CGFloat(index) / 2, green: 0.5, blue: 1, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            }
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 3)) else {
                throw writer.error ?? NSError(domain: "WallmotionVideoFixture", code: 3)
            }
        }
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "WallmotionVideoFixture", code: 4)
        }
    }
    private func availableScreen() throws -> NSScreen {
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.first else {
            throw XCTSkip("O smoke test AppKit precisa de uma sessão gráfica com um display disponível.")
        }
        return screen
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WallmotionRendererTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func frame(red: CGFloat, blue: CGFloat) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: red, green: 0, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return try XCTUnwrap(context.makeImage())
    }

    private func writeImage(at url: URL, animated: Bool) throws {
        let type = animated ? UTType.gif : UTType.png
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, animated ? 2 : 1, nil
        ))
        if animated {
            CGImageDestinationSetProperties(destination, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
            ] as CFDictionary)
            let properties = [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]
            ] as CFDictionary
            CGImageDestinationAddImage(destination, try frame(red: 1, blue: 0), properties)
            CGImageDestinationAddImage(destination, try frame(red: 0, blue: 1), properties)
        } else {
            CGImageDestinationAddImage(destination, try frame(red: 1, blue: 0), nil)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination), "A fixture precisa ser uma imagem real decodificável.")
    }

    func testBudgetRejectionAndDecoderFailurePreserveRendererThenReleaseQuota() throws {
        let screen = try availableScreen()
        let displayID = try XCTUnwrap(Display.identify(screen))
        try withTemporaryDirectory { directory in
            let store = LibraryStore(rootURL: directory.appendingPathComponent("Library"))
            let url = directory.appendingPathComponent("animation.gif")
            try writeImage(at: url, animated: true)
            let item = try store.importFile(at: url)
            let bytes = try GIFPreflight.inspect(url: url).decodedBytes
            let connectedScreens = TestScreens([screen])
            let engine = DesktopCoordinator(gifBudgetLimit: bytes, targets: {
                connectedScreens.values.compactMap { screen in
                    Display.identify(screen).map { DesktopTarget(id: $0, screen: screen) }
                }
            })
            defer { engine.stop() }
            var state = LibraryState(wallpapers: [item], assignments: [displayID: item.id])
            engine.rebuild(state: state, store: store, paused: false) { _, message in XCTFail(message) }
            var window = try XCTUnwrap(NSApplication.shared.windows.compactMap { $0 as? DesktopWindow }.first { $0.isVisible })
            XCTAssertEqual(engine.gifBudget.totalBytes, bytes)

            // Changing presentation at the exact GIF quota replaces the existing
            // display charge, and must not bypass its budget or double-charge it.
            state.setMediaFit(.fill, for: item.id, on: displayID)
            engine.rebuild(state: state, store: store, paused: true) { _, message in XCTFail(message) }
            XCTAssertFalse(window.isVisible)
            window = try XCTUnwrap(NSApplication.shared.windows.compactMap { $0 as? DesktopWindow }.first { $0.isVisible })
            XCTAssertEqual(try XCTUnwrap(window.contentView as? ImageSurface).mediaFit, .fill)
            XCTAssertEqual(engine.gifBudget.bytesByDisplay, [displayID: bytes])

            // A tiny encoded fixture with a larger canvas; reject before decoding.
            var larger = try Data(contentsOf: url)
            larger.replaceSubrange(6..<10, with: [4, 0, 4, 0])
            let largerURL = directory.appendingPathComponent("larger.gif")
            try larger.write(to: largerURL)
            let other = try store.importFile(at: largerURL)
            state.wallpapers.append(other)
            state.assignments[displayID] = other.id
            var errors: [String] = []
            engine.rebuild(state: state, store: store, paused: true) { _, message in errors.append(message) }
            XCTAssertEqual(errors.count, 1)
            XCTAssertTrue(errors[0].contains("limite global"))
            XCTAssertTrue(window.isVisible)
            XCTAssertFalse(try XCTUnwrap(window.contentView as? ImageSurface).imageView.animates)
            XCTAssertEqual(engine.gifBudget.bytesByDisplay, [displayID: bytes])

            // A decoder failure, including a forced refresh, must not consume quota.
            let invalidURL = directory.appendingPathComponent("invalid.png")
            try Data("invalid".utf8).write(to: invalidURL)
            let invalid = try store.importFile(at: invalidURL)
            state.wallpapers.append(invalid)
            state.assignments[displayID] = invalid.id
            engine.rebuild(state: state, store: store, paused: true, force: true) { _, message in errors.append(message) }
            XCTAssertEqual(errors.count, 2)
            XCTAssertTrue(window.isVisible)
            XCTAssertEqual(engine.gifBudget.totalBytes, bytes)

            connectedScreens.values = []
            engine.rebuild(state: state, store: store, paused: true) { _, message in XCTFail(message) }
            XCTAssertEqual(engine.gifBudget.totalBytes, 0)
            XCTAssertFalse(window.isVisible)
            connectedScreens.values = [screen]
            state.assignments[displayID] = item.id
            engine.rebuild(state: state, store: store, paused: true) { _, message in XCTFail(message) }
            XCTAssertEqual(engine.gifBudget.totalBytes, bytes)
            let photoURL = directory.appendingPathComponent("photo.png")
            try writeImage(at: photoURL, animated: false)
            let photo = try store.importFile(at: photoURL)
            state.wallpapers.append(photo)
            state.assignments[displayID] = photo.id
            engine.rebuild(state: state, store: store, paused: true) { _, message in XCTFail(message) }
            XCTAssertEqual(engine.gifBudget.totalBytes, 0)
            state.assignments[displayID] = item.id
            engine.rebuild(state: state, store: store, paused: true) { _, message in XCTFail(message) }
            XCTAssertEqual(engine.gifBudget.totalBytes, bytes)
            state.remove(id: item.id)
            engine.rebuild(state: state, store: store, paused: true) { _, message in XCTFail(message) }
            XCTAssertEqual(engine.gifBudget.totalBytes, 0)
            state.wallpapers.append(item)
            state.assignments[displayID] = item.id
            engine.rebuild(state: state, store: store, paused: true) { _, message in XCTFail(message) }
            engine.stop()
            XCTAssertEqual(engine.gifBudget.totalBytes, 0)
        }
    }

    func testPhotoCreatesNonInteractiveDesktopWindowAndStops() throws {
        let screen = try availableScreen()
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("photo.png")
            try writeImage(at: url, animated: false)
            let wallpaper = Wallpaper(title: "Photo", kind: .image, source: .local(filename: "photo.png"))
            let renderer = try WallpaperRenderer(wallpaper: wallpaper, url: url, screen: screen) {
                XCTFail("Uma foto válida não deve gerar erro: \($0)")
            }
            defer { renderer.stop() }

            let window = renderer.window
            XCTAssertTrue(window.isOpaque)
            XCTAssertTrue(window.ignoresMouseEvents)
            XCTAssertFalse(window.canBecomeKey)
            XCTAssertFalse(window.canBecomeMain)
            XCTAssertEqual(window.level.rawValue, Int(CGWindowLevelForKey(.desktopWindow)) + 1)
            XCTAssertEqual(window.frame, screen.frame)
            XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces))
            XCTAssertFalse(window.hasShadow)
            let imageView = try XCTUnwrap(window.contentView as? ImageSurface).imageView
            XCTAssertTrue(try XCTUnwrap(imageView.image).isValid)

            renderer.setPaused(false)
            XCTAssertTrue(window.isVisible)
            renderer.setPaused(true)
            XCTAssertTrue(window.isVisible, "Pausar deve manter o wallpaper visível.")
            renderer.stop()
            XCTAssertFalse(window.isVisible)
        }
    }

    func testAnimatedGIFRespondsToPauseResumeAndStop() throws {
        let screen = try availableScreen()
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("animation.gif")
            try writeImage(at: url, animated: true)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetCount(source), 2)
            let wallpaper = Wallpaper(title: "Animation", kind: .gif, source: .local(filename: "animation.gif"))
            let renderer = try WallpaperRenderer(wallpaper: wallpaper, url: url, screen: screen, mediaFit: .fill, isWindowVisible: { _ in true }) {
                XCTFail("Um GIF válido não deve gerar erro: \($0)")
            }
            defer { renderer.stop() }
            let view = try XCTUnwrap(renderer.window.contentView as? ImageSurface).imageView
            XCTAssertFalse(view.animates)
            renderer.setPaused(false)
            XCTAssertTrue(view.animates)
            renderer.setPaused(true)
            XCTAssertFalse(view.animates)
            renderer.setPaused(false)
            XCTAssertTrue(view.animates)
            renderer.stop()
            XCTAssertFalse(view.animates)
            XCTAssertFalse(renderer.window.isVisible)
        }
    }

    func testImageSurfaceUsesProportionalFramesAndClipsFill() throws {
        _ = NSApplication.shared
        for fit in MediaFit.allCases {
            let image = NSImage(size: NSSize(width: 400, height: 200))
            let surface = ImageSurface(image: image, mediaFit: fit)
            surface.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
            surface.layout()
            XCTAssertEqual(surface.imageView.frame, fit.frame(for: image.size, in: surface.bounds))
            XCTAssertEqual(surface.layer?.masksToBounds, true)
            XCTAssertEqual(surface.imageView.frame.width / surface.imageView.frame.height, 2)
        }
    }

    func testVideoSurfaceUsesNativeProportionalGravity() {
        let player = AVPlayer()
        XCTAssertEqual(VideoSurface(player: player, mediaFit: .fit).playerLayer.videoGravity, .resizeAspect)
        XCTAssertEqual(VideoSurface(player: player, mediaFit: .fill).playerLayer.videoGravity, .resizeAspectFill)
    }

    func testInvalidImageThrowsBeforeCreatingWallpaperWindow() throws {
        let screen = try availableScreen()
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("invalid.png")
            try Data("This is not PNG data".utf8).write(to: url)
            let wallpaper = Wallpaper(title: "Invalid", kind: .image, source: .local(filename: "invalid.png"))
            XCTAssertThrowsError(try WallpaperRenderer(wallpaper: wallpaper, url: url, screen: screen, onError: { _ in })) { error in
                guard case RendererError.unreadableImage = error else {
                    return XCTFail("Esperado unreadableImage; recebido \(error)")
                }
            }
        }
    }

    func testMissingLocalVideoThrowsBeforeStartingPlayback() throws {
        let screen = try availableScreen()
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("missing.mp4")
            let wallpaper = Wallpaper(title: "Missing", kind: .video, source: .local(filename: "missing.mp4"))
            XCTAssertThrowsError(try WallpaperRenderer(wallpaper: wallpaper, url: url, screen: screen, onError: { _ in })) { error in
                guard case RendererError.missingFile = error else {
                    return XCTFail("Esperado missingFile; recebido \(error)")
                }
            }
        }
    }

    func testLocalVideoPlaysLoopsPausesAndReleasesItsSurface() async throws {
        let screen = try availableScreen()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WallmotionVideoTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("short.mp4")
        try await writeShortVideo(at: url)
        let wallpaper = Wallpaper(title: "Short video", kind: .video, source: .local(filename: "short.mp4"))
        let renderer = try WallpaperRenderer(wallpaper: wallpaper, url: url, screen: screen, isWindowVisible: { _ in true }) {
            XCTFail("Falha reproduzindo vídeo H.264 gerado pelo teste: \($0)")
        }
        defer { renderer.stop() }
        let surface = try XCTUnwrap(renderer.window.contentView as? VideoSurface)
        let player = try XCTUnwrap(surface.playerLayer.player)
        XCTAssertTrue(player.isMuted)
        XCTAssertFalse(player.preventsDisplaySleepDuringVideoPlayback)
        guard try await eventually({ player.currentItem?.status == .readyToPlay }) else {
            return XCTFail("O vídeo local não ficou pronto em 5 segundos: \(String(describing: player.currentItem?.error))")
        }
        let firstItem = try XCTUnwrap(player.currentItem)
        renderer.setPaused(false)
        guard try await eventually({ player.currentTime().seconds > 0.05 && player.rate > 0 }) else {
            return XCTFail("O tempo do vídeo não avançou após retomar.")
        }
        // A different queued item proves the short movie completed a loop,
        // independently of exact decoder scheduling or playback timestamps.
        guard try await eventually({ player.currentItem != nil && player.currentItem !== firstItem }) else {
            return XCTFail("O AVPlayerLooper não avançou para a próxima cópia do vídeo.")
        }
        renderer.setPaused(true)
        XCTAssertEqual(player.rate, 0)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(player.rate, 0)
        renderer.stop()
        XCTAssertNil(surface.playerLayer.player)
        XCTAssertNil(surface.playerLayer.superlayer)
        XCTAssertNil(player.currentItem)
        XCTAssertFalse(renderer.window.isVisible)
    }

    func testOptInRemoteStreamBecomesReadyAndAdvances() async throws {
        guard let text = ProcessInfo.processInfo.environment["WALLMOTION_REMOTE_TEST_URL"], !text.isEmpty else {
            throw XCTSkip("Defina WALLMOTION_REMOTE_TEST_URL para testar reprodução remota com rede.")
        }
        let screen = try availableScreen()
        let url = try MediaURL.validate(text)
        let wallpaper = try Wallpaper.remote(text)
        let renderer = try WallpaperRenderer(wallpaper: wallpaper, url: url, screen: screen, isWindowVisible: { _ in true }) {
            XCTFail("Falha no stream remoto: \($0)")
        }
        defer { renderer.stop() }
        let surface = try XCTUnwrap(renderer.window.contentView as? VideoSurface)
        let player = try XCTUnwrap(surface.playerLayer.player)
        XCTAssertFalse(player is AVQueuePlayer)
        XCTAssertTrue(player.isMuted)
        XCTAssertFalse(player.preventsDisplaySleepDuringVideoPlayback)
        renderer.setPaused(false)
        guard try await eventually(timeout: .seconds(15), {
            player.currentItem?.status == .readyToPlay || player.currentItem?.status == .failed
        }) else {
            return XCTFail("O stream remoto não ficou pronto em 15 segundos.")
        }
        guard player.currentItem?.status == .readyToPlay else {
            return XCTFail("O decoder remoto falhou: \(String(describing: player.currentItem?.error))")
        }
        let initialTime = player.currentTime().seconds
        guard try await eventually(timeout: .seconds(15), {
            let current = player.currentTime().seconds
            return current.isFinite && current > max(initialTime.isFinite ? initialTime : 0, 0) + 0.05
        }) else {
            return XCTFail("O stream ficou pronto, mas o tempo de reprodução não avançou em 15 segundos.")
        }
        XCTAssertGreaterThan(player.rate, 0)
        renderer.setPaused(true)
        XCTAssertEqual(player.rate, 0)
        renderer.stop()
        XCTAssertNil(surface.playerLayer.player)
        XCTAssertFalse(renderer.window.isVisible)
    }

    func testRebuildWithSameConfigurationPreservesWindowIdentity() throws {
        let screen = try availableScreen()
        let displayID = try XCTUnwrap(Display.identify(screen))
        try withTemporaryDirectory { directory in
            let store = LibraryStore(rootURL: directory.appendingPathComponent("Library"))
            let url = directory.appendingPathComponent("photo.png")
            try writeImage(at: url, animated: false)
            let item = try store.importFile(at: url)
            let state = LibraryState(wallpapers: [item], assignments: [displayID: item.id])
            let engine = DesktopCoordinator()
            defer { engine.stop() }
            let existing = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
            engine.rebuild(state: state, store: store, paused: false, force: false) { _, message in XCTFail(message) }
            let windows = NSApplication.shared.windows.compactMap { $0 as? DesktopWindow }
                .filter { !existing.contains(ObjectIdentifier($0)) && $0.isVisible }
            XCTAssertEqual(windows.count, 1)
            let original = try XCTUnwrap(windows.first)
            engine.rebuild(state: state, store: store, paused: true, force: false) { _, message in XCTFail(message) }
            XCTAssertTrue(original.isVisible)
            let refreshed = NSApplication.shared.windows.compactMap { $0 as? DesktopWindow }
                .filter { !existing.contains(ObjectIdentifier($0)) && $0.isVisible }
            XCTAssertEqual(refreshed.count, 1)
            XCTAssertTrue(refreshed.first === original)
            var changed = state
            changed.setMediaFit(.fill, for: item.id, on: displayID)
            engine.rebuild(state: changed, store: store, paused: true, force: false) { _, message in XCTFail(message) }
            XCTAssertFalse(original.isVisible)
            let replacement = NSApplication.shared.windows.compactMap { $0 as? DesktopWindow }
                .first { !existing.contains(ObjectIdentifier($0)) && $0.isVisible }
            let surface = try XCTUnwrap(replacement?.contentView as? ImageSurface)
            XCTAssertEqual(surface.mediaFit, .fill)
            XCTAssertFalse(surface.imageView.animates)
        }
    }

    func testRefreshingAnotherDisplayPreservesUnaffectedWindow() throws {
        _ = try availableScreen()
        let screens = NSScreen.screens
        guard screens.count >= 2 else { throw XCTSkip("O teste de refresh entre displays requer dois monitores.") }
        let firstScreen = screens[0]
        let secondScreen = screens[1]
        let firstID = try XCTUnwrap(Display.identify(firstScreen))
        let secondID = try XCTUnwrap(Display.identify(secondScreen))
        try withTemporaryDirectory { directory in
            let store = LibraryStore(rootURL: directory.appendingPathComponent("Library"))
            let url = directory.appendingPathComponent("photo.png")
            try writeImage(at: url, animated: false)
            let firstItem = try store.importFile(at: url)
            let secondItem = try store.importFile(at: url)
            var state = LibraryState(wallpapers: [firstItem, secondItem], assignments: [firstID: firstItem.id, secondID: firstItem.id])
            let engine = DesktopCoordinator()
            defer { engine.stop() }
            let existing = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
            engine.rebuild(state: state, store: store, paused: false, force: false) { _, message in XCTFail(message) }
            let initial = NSApplication.shared.windows.compactMap { $0 as? DesktopWindow }
                .filter { !existing.contains(ObjectIdentifier($0)) && $0.isVisible }
            let unaffected = try XCTUnwrap(initial.first { $0.frame == firstScreen.frame })
            let replaced = try XCTUnwrap(initial.first { $0.frame == secondScreen.frame })
            state.assignments[secondID] = secondItem.id
            state.setMediaFit(.fill, for: secondItem.id, on: secondID)
            engine.rebuild(state: state, store: store, paused: false, force: false) { _, message in XCTFail(message) }
            let refreshed = NSApplication.shared.windows.compactMap { $0 as? DesktopWindow }
                .filter { !existing.contains(ObjectIdentifier($0)) && $0.isVisible }
            XCTAssertEqual(refreshed.count, 2)
            XCTAssertTrue(refreshed.contains { $0 === unaffected })
            XCTAssertFalse(replaced.isVisible)
            XCTAssertFalse(refreshed.contains { $0 === replaced })
        }
    }

    func testCoveredGIFStaysPausedAcrossManualPolicyResumeAndStop() throws {
        let screen = try availableScreen()
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("animation.gif")
            try writeImage(at: url, animated: true)
            let item = Wallpaper(title: "Animation", kind: .gif, source: .local(filename: "animation.gif"))
            let visibility = TestVisibility()
            let renderer = try WallpaperRenderer(wallpaper: item, url: url, screen: screen, mediaFit: .fill,
                                                 isWindowVisible: { _ in visibility.visible }) { XCTFail($0) }
            defer { renderer.stop() }
            let view = try XCTUnwrap(renderer.window.contentView as? ImageSurface).imageView
            XCTAssertFalse(renderer.playbackState.isVisible, "Initialization samples injected visibility.")
            XCTAssertFalse(view.animates)
            renderer.setPaused(false)
            XCTAssertFalse(view.animates)
            visibility.visible = true
            NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: renderer.window)
            XCTAssertTrue(view.animates)
            visibility.visible = false
            NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: renderer.window)
            XCTAssertFalse(view.animates)
            renderer.setPaused(true)
            renderer.setPaused(false)
            XCTAssertFalse(view.animates, "Manual resume cannot override unchanged occlusion.")
            var policy = PlaybackPolicy()
            policy.sleeping = true
            renderer.setPaused(policy.isPaused(settings: PlaybackSettings(), lowPower: false))
            policy.sleeping = false
            renderer.setPaused(policy.isPaused(settings: PlaybackSettings(), lowPower: false))
            renderer.setPaused(policy.isPaused(settings: PlaybackSettings(), lowPower: true))
            renderer.setPaused(policy.isPaused(settings: PlaybackSettings(), lowPower: false))
            XCTAssertFalse(view.animates, "Wake and low-power resume cannot override occlusion.")
            // Becoming visible must preserve manual pause until explicitly resumed.
            renderer.setPaused(true)
            visibility.visible = true
            NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: renderer.window)
            XCTAssertFalse(view.animates)
            renderer.setPaused(false)
            XCTAssertTrue(view.animates)
            renderer.stop()
            renderer.setPaused(false)
            NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: renderer.window)
            XCTAssertFalse(view.animates)
            XCTAssertFalse(renderer.window.isVisible)
        }
    }

    func testOtherDisplayAssignmentRefreshCannotResumePreservedCoveredGIF() throws {
        let screen = try availableScreen()
        try withTemporaryDirectory { directory in
            let store = LibraryStore(rootURL: directory.appendingPathComponent("Library"))
            let url = directory.appendingPathComponent("animation.gif")
            try writeImage(at: url, animated: true)
            let first = try store.importFile(at: url)
            let second = try store.importFile(at: url)
            var state = LibraryState(wallpapers: [first, second], assignments: ["left": first.id, "right": first.id])
            let visibility = TestWindowVisibility()
            // Two actual renderers on logical targets backed by the test screen.
            let engine = DesktopCoordinator(targets: {
                [DesktopTarget(id: "left", screen: screen), DesktopTarget(id: "right", screen: screen)]
            }, isWindowVisible: { visibility.isVisible($0) })
            defer { engine.stop() }
            engine.rebuild(state: state, store: store, paused: false) { _, message in XCTFail(message) }
            XCTAssertEqual(visibility.windows.count, 2)
            let left = try XCTUnwrap(visibility.windows.first)
            let right = visibility.windows[1]
            let view = try XCTUnwrap(left.contentView as? ImageSurface).imageView
            XCTAssertTrue(view.animates)
            visibility.visible[ObjectIdentifier(left)] = false
            NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: left)
            XCTAssertFalse(view.animates)
            state.assignments["right"] = second.id
            state.setMediaFit(.fill, for: second.id, on: "right")
            engine.rebuild(state: state, store: store, paused: false, force: false) { _, message in XCTFail(message) }
            XCTAssertEqual(visibility.windows.count, 3, "Only the changed target gets a new renderer.")
            XCTAssertTrue((left.contentView as? ImageSurface)?.imageView === view)
            XCTAssertTrue(left.isVisible)
            XCTAssertFalse(right.isVisible)
            XCTAssertFalse(view.animates, "Refreshing the right display must not resume the covered left display.")
            let changedView = try XCTUnwrap(visibility.windows.last?.contentView as? ImageSurface).imageView
            XCTAssertTrue(changedView.animates, "The changed visible display can play independently.")
            engine.setPaused(true)
            engine.setPaused(false)
            XCTAssertFalse(view.animates)
            XCTAssertTrue(changedView.animates)
            // Re-sample even without an occlusion notification before rebuild.
            visibility.visible[ObjectIdentifier(left)] = true
            engine.rebuild(state: state, store: store, paused: false, force: false) { _, message in XCTFail(message) }
            XCTAssertTrue(view.animates)
            visibility.visible[ObjectIdentifier(left)] = false
            engine.rebuild(state: state, store: store, paused: false, force: false) { _, message in XCTFail(message) }
            XCTAssertFalse(view.animates)
            XCTAssertTrue(changedView.animates)
        }
    }

    func testVideoAndRemoteSeekUseCurrentVisibilityPauseAndTerminalStop() async throws {
        let screen = try availableScreen()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WallmotionSeekTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("short.mp4")
        try await writeShortVideo(at: url)
        let item = Wallpaper(title: "Video", kind: .video, source: .local(filename: "short.mp4"))
        let visibility = TestVisibility()
        let seeks = TestSeeks()
        var errors: [String] = []
        // A plain AVPlayer with a local fixture exercises the remote restart path
        // without a network dependency or real asynchronous seek timing.
        let renderer = try WallpaperRenderer(wallpaper: item, url: url, screen: screen,
            isWindowVisible: { _ in visibility.visible },
            makePlayer: { item, _ in AVPlayer(playerItem: item) },
            seekToStart: { _, completion in seeks.completions.append(completion) },
            onError: { errors.append($0) })
        defer { renderer.stop() }
        let surface = try XCTUnwrap(renderer.window.contentView as? VideoSurface)
        let player = try XCTUnwrap(surface.playerLayer.player)
        let playerItem = try XCTUnwrap(player.currentItem)
        guard try await eventually({ playerItem.status == .readyToPlay }) else {
            return XCTFail("A fixture de vídeo não ficou pronta.")
        }
        XCTAssertFalse(renderer.playbackState.isVisible)
        XCTAssertEqual(player.rate, 0)
        renderer.setPaused(false)
        XCTAssertEqual(player.rate, 0)
        visibility.visible = true
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: renderer.window)
        XCTAssertEqual(player.rate, 1)
        visibility.visible = false
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: renderer.window)
        renderer.setPaused(true)
        renderer.setPaused(false)
        XCTAssertEqual(player.rate, 0, "Manual/policy resume must not play a covered video.")

        for paused in [false, true] {
            for visible in [false, true] {
                NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: playerItem)
                let completion = try XCTUnwrap(seeks.completions.last)
                let count = seeks.completions.count
                NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: playerItem)
                XCTAssertEqual(seeks.completions.count, count, "Coalesce duplicate end notifications while seeking.")
                visibility.visible = !visible
                renderer.setPaused(paused)
                NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: renderer.window)
                XCTAssertEqual(player.rate, 0, "Even visible/unpaused must wait for seek completion.")
                // Visibility changes again without a notification: the seek
                // completion must sample the current value, not a cached one.
                visibility.visible = visible
                completion(true)
                XCTAssertNil(renderer.playbackState.pendingRestart)
                XCTAssertEqual(player.rate, !paused && visible ? 1 : 0)
                completion(true) // Duplicate completions cannot change the decision.
                XCTAssertEqual(player.rate, !paused && visible ? 1 : 0)
            }
        }
        visibility.visible = true
        renderer.setPaused(false)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: playerItem)
        let failed = try XCTUnwrap(seeks.completions.last)
        failed(false)
        XCTAssertEqual(errors.count, 1)
        renderer.setPaused(false)
        XCTAssertEqual(player.rate, 0, "An unsuccessful seek must not restart playback.")
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: playerItem)
        let pending = try XCTUnwrap(seeks.completions.last)
        failed(true) // An old completion cannot finish the newer seek.
        XCTAssertNotNil(renderer.playbackState.pendingRestart)
        XCTAssertEqual(player.rate, 0)
        renderer.stop()
        pending(true)
        pending(false)
        renderer.setPaused(false)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: renderer.window)
        let count = seeks.completions.count
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: playerItem)
        XCTAssertEqual(seeks.completions.count, count)
        XCTAssertEqual(errors.count, 1, "Stopped/stale seeks must not publish a new error.")
        XCTAssertEqual(player.rate, 0)
        XCTAssertNil(player.currentItem)
        XCTAssertNil(surface.playerLayer.player)
        XCTAssertFalse(renderer.window.isVisible)
    }
}
