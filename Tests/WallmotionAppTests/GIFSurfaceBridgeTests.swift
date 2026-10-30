import AppKit
import XCTest
import WallmotionCore
@testable import Wallmotion

@MainActor
final class GIFSurfaceBridgeTests: XCTestCase {
    func testImageSurfacePaintsNativeFrameAfterAnimationOwnerIsReleased() async throws {
        let bytes: [UInt8] = [0x47,0x49,0x46,0x38,0x39,0x61,1,0,1,0,0x80,0,0,
            0,0,0,255,255,255,0x2c,0,0,0,0,1,0,1,0,0,2,2,0x4c,1,0,0x3b]
        var animation: GIFAnimation? = try GIFAnimation(data: Data(bytes))
        let original = WeakGIFOwner(animation)
        let bitmap = try XCTUnwrap(animation).image(at: 0)
        let surface = ImageSurface(image: NSImage(cgImage: bitmap, size: NSSize(width: 1,height: 1)), mediaFit: .fill)
        animation = nil
        XCTAssertNil(original.value)
        let bounds = NSRect(x: 0,y: 0,width: 64,height: 64)
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        surface.frame = bounds;window.contentView = surface
        window.setFrameOrigin(NSPoint(x: -10000,y: -10000));window.orderBack(nil)
        defer { window.orderOut(nil);window.close() }
        surface.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let capture = try XCTUnwrap(surface.bitmapImageRepForCachingDisplay(in: bounds))
        surface.cacheDisplay(in: bounds, to: capture)
        let center = try XCTUnwrap(capture.colorAt(x: capture.pixelsWide/2,y: capture.pixelsHigh/2)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(center.redComponent, 0.95)
        XCTAssertGreaterThan(center.greenComponent, 0.95)
        XCTAssertGreaterThan(center.blueComponent, 0.95)
        XCTAssertGreaterThan(center.alphaComponent, 0.95)
    }
}

private final class WeakGIFOwner {
    weak var value: GIFAnimation?
    init(_ value: GIFAnimation?) { self.value = value }
}
