import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
import WallmotionCore
@testable import Wallmotion

@MainActor
final class WallpaperRendererTests: XCTestCase {
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
}
