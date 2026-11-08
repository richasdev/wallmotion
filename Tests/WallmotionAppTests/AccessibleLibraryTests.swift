import AppKit
import SwiftUI
import XCTest
import WallmotionCore
@testable import Wallmotion

@MainActor
final class AccessibleLibraryTests: XCTestCase {
    private func luminance(_ color: NSColor) throws -> Double {
        let rgb = try XCTUnwrap(color.usingColorSpace(.sRGB))
        let values = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { component -> Double in
            let value = Double(component)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * values[0] + 0.7152 * values[1] + 0.0722 * values[2]
    }
    func testSelectionContourContrastAgainstResolvedNativeCardSurfaces() throws {
        for (scheme, name) in [(ColorScheme.light, NSAppearance.Name.aqua), (.dark, .darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var foreground: Double = 0, background: Double = 0
            appearance.performAsCurrentDrawingAppearance {
                foreground = (try? luminance(NSColor(BrandTheme.selection(for: scheme)))) ?? -1
                background = (try? luminance(.controlBackgroundColor)) ?? -1
            }
            XCTAssertGreaterThanOrEqual(foreground, 0);XCTAssertGreaterThanOrEqual(background, 0)
            let ratio = (max(foreground, background) + 0.05) / (min(foreground, background) + 0.05)
            print("selection_contour scheme=\(scheme) resolved_native_card_ratio=\(ratio)")
            XCTAssertGreaterThanOrEqual(ratio, 3)
        }
    }

    func testEnabledScenarioCaptionInkHasContrastOnNativeGlassAndOpaqueFallback() throws {
        for (scheme, backgrounds) in [(ColorScheme.light, [0xF3F3F3, 0xE9E9E9, 0xE1E1E1, 0xFFFFFF]), (.dark, [0x262525, 0x4A4A4A, 0x505050, 0x1E1E1E])] {
            let foreground = try luminance(NSColor(BrandTheme.secondaryInk(for: scheme)))
            for hex in backgrounds {
                let surface = NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                                      green: CGFloat((hex >> 8) & 255) / 255,
                                      blue: CGFloat(hex & 255) / 255, alpha: 1)
                let background = try luminance(surface)
                let ratio = (max(foreground, background) + 0.05) / (min(foreground, background) + 0.05)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "Enabled captions must remain legible on the compositor-measured shelf and opaque fallback")
            }
        }
    }

    func testSelectedTextContrastOnCompositorMeasuredTintedGlass() throws {
        for (scheme, hex) in [(ColorScheme.light, 0xEBD9D6), (.light, 0xF4E4E1), (.dark, 0x54413D), (.dark, 0x402E2B)] {
            let foreground = try luminance(NSColor(BrandTheme.selection(for: scheme)))
            let surface = NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                                  green: CGFloat((hex >> 8) & 255) / 255,
                                  blue: CGFloat(hex & 255) / 255, alpha: 1)
            let background = try luminance(surface)
            let ratio = (max(foreground, background) + 0.05) / (min(foreground, background) + 0.05)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "Selected monitor and framing labels must remain readable on tinted glass")
        }
    }

    private func nodes(_ root: AnyObject) -> [any NSAccessibilityProtocol] {
        var result: [any NSAccessibilityProtocol] = [], seen = Set<ObjectIdentifier>()
        func visit(_ value: AnyObject, depth: Int) {
            guard depth < 30, seen.insert(ObjectIdentifier(value)).inserted,
                  let accessible = value as? any NSAccessibilityProtocol else { return }
            result.append(accessible)
            for child in accessible.accessibilityChildren() ?? [] { visit(child as AnyObject, depth: depth + 1) }
        }
        visit(root, depth: 0)
        return result
    }
    private func host<V: View>(_ content: V, size: CGSize) -> (NSHostingView<V>, NSWindow) {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: content)
        let frame = CGRect(origin: .zero, size: size);host.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false;window.contentView = host
        window.setFrameOrigin(CGPoint(x: -10000,y: -10000));window.orderBack(nil)
        return (host, window)
    }
    func testOptInCardPublishesSelectionAndNamedActionsThroughNativeAX() async throws {
        guard ProcessInfo.processInfo.environment["WALLMOTION_NATIVE_AX_QA"] == "1" else {
            throw XCTSkip("Native AX opt-in: requires a host exposing SwiftUI accessibility nodes; no OS permissions are changed.")
        }
        let item = Wallpaper(title: "Aurora de teste", kind: .video, source: .remote(url: URL(string: "https://example.com/aurora.mp4")!))
        var applied = false, renamed = false, removed = false
        let card = WallpaperCard(item: item, localURL: nil, isApplied: true,
            onRename: { renamed = true }, onApply: { applied = true }, onRemove: { removed = true })
        let (host, window) = host(card, size: CGSize(width: 340,height: 350))
        defer { window.orderOut(nil);window.close() }
        _ = try await LibrarySnapshotCapture.capture(host)
        let elements = nodes(host)
        guard elements.count > 1 else { throw XCTSkip("The QA host did not expose SwiftUI AX children; VoiceOver/native AX certification remains pending.") }
        XCTAssertTrue(elements.contains { $0.accessibilityValue() as? String == "Fundo aplicado" })
        let rename = try XCTUnwrap(elements.first { $0.accessibilityLabel() == "Renomear Aurora de teste" })
        let remove = try XCTUnwrap(elements.first { $0.accessibilityLabel() == "Remover Aurora de teste da biblioteca" })
        let apply = try XCTUnwrap(elements.first { ($0.accessibilityLabel() ?? "").contains("Reaplicar") && $0.accessibilityRole() == .button })
        XCTAssertTrue(rename.accessibilityPerformPress());XCTAssertTrue(renamed)
        XCTAssertTrue(remove.accessibilityPerformPress());XCTAssertTrue(removed)
        XCTAssertTrue(apply.accessibilityPerformPress());XCTAssertTrue(applied)
    }

    func testLargeTextLibraryRendersAtMinimumWindowInNativeHighContrastAppearances() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WallmotionAccessibility-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(rootURL: root)
        let item = try Wallpaper.remote("https://example.com/fixture.mp4")
        try store.save(LibraryState(wallpapers: [item], assignments: ["test": item.id], settings: .init(isManuallyPaused: true)))
        let model = LibraryModel(thermalState: { .nominal }, memoryMonitor: TestMemoryPressureMonitor(), purgeThumbnails: {},
            store: store, engine: DesktopCoordinator(targets: { [] }), connectedDisplays: { [Display(id: "test", name: "Monitor de teste")] })
        defer { model.stop() }
        model.refreshPlayback(force: false)
        for scheme in [ColorScheme.light, .dark] {
            let view = LibraryView(model: model, initialSceneControls: true)
                .environment(\.dynamicTypeSize, .accessibility3)
                .environment(\.colorScheme, scheme)
            let (host, window) = host(view, size: CGSize(width: 820,height: 560))
            defer { window.orderOut(nil);window.close() }
            host.appearance = NSAppearance(named: scheme == .light ? .accessibilityHighContrastAqua : .accessibilityHighContrastDarkAqua)
            window.appearance = host.appearance
            let bitmap = try await LibrarySnapshotCapture.capture(host)
            XCTAssertEqual(host.bounds.size, CGSize(width: 820,height: 560))
            XCTAssertTrue(LibrarySnapshotCapture.hasContent(bitmap))
            func scrollViews(_ view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
            }
            let scroll = try XCTUnwrap(scrollViews(host).first {
                $0.bounds.width > 400 && ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height + 1
            })
            let document = try XCTUnwrap(scroll.documentView)
            let before = scroll.contentView.bounds.origin
            let bottom = document.isFlipped ? document.bounds.maxY - scroll.contentView.bounds.height : document.bounds.minY
            scroll.contentView.scroll(to: CGPoint(x: before.x,y: bottom))
            scroll.reflectScrolledClipView(scroll.contentView)
            XCTAssertNotEqual(scroll.contentView.bounds.origin, before)
            let lower = try await LibrarySnapshotCapture.capture(host)
            if let path = ProcessInfo.processInfo.environment["WALLMOTION_ACCESSIBILITY_SNAPSHOT_DIR"] {
                let output = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                let name = scheme == .light ? "light" : "dark"
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: output.appendingPathComponent(name + "-large.png"))
                try XCTUnwrap(lower.representation(using: .png, properties: [:]))
                    .write(to: output.appendingPathComponent(name + "-bottom.png"))
            }
        }
    }
}
