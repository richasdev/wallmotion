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
            let imageView = try XCTUnwrap(window.contentView as? NSImageView)
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
            let renderer = try WallpaperRenderer(wallpaper: wallpaper, url: url, screen: screen) {
                XCTFail("Um GIF válido não deve gerar erro: \($0)")
            }
            defer { renderer.stop() }
            let view = try XCTUnwrap(renderer.window.contentView as? NSImageView)
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
        let renderer = try WallpaperRenderer(wallpaper: wallpaper, url: url, screen: screen) {
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
            engine.rebuild(state: state, store: store, paused: false, force: false) { _, message in XCTFail(message) }
            let refreshed = NSApplication.shared.windows.compactMap { $0 as? DesktopWindow }
                .filter { !existing.contains(ObjectIdentifier($0)) && $0.isVisible }
            XCTAssertEqual(refreshed.count, 2)
            XCTAssertTrue(refreshed.contains { $0 === unaffected })
            XCTAssertFalse(replaced.isVisible)
            XCTAssertFalse(refreshed.contains { $0 === replaced })
        }
    }
}
