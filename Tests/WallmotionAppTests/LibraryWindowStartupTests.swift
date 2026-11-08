import AppKit
import XCTest
@testable import Wallmotion

private final class StartupNotificationCenter: NotificationCenter, @unchecked Sendable {
    private let lock = NSLock()
    private var active: Set<ObjectIdentifier> = []
    var observerCount: Int { lock.withLock { active.count } }

    override func addObserver(forName name: NSNotification.Name?, object obj: Any?, queue: OperationQueue?,
                              using block: @escaping @Sendable (Notification) -> Void) -> NSObjectProtocol {
        let token = super.addObserver(forName: name, object: obj, queue: queue, using: block)
        _ = lock.withLock { active.insert(ObjectIdentifier(token)) }
        return token
    }

    override func removeObserver(_ observer: Any) {
        _ = lock.withLock { active.remove(ObjectIdentifier(observer as AnyObject)) }
        super.removeObserver(observer)
    }
}

@MainActor
final class LibraryWindowStartupTests: XCTestCase {
    @MainActor private final class Actions {
        var fullscreen = false
        var exits = 0
        var sizes = 0
    }

    private func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 1400, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    func testOrdinaryWindowStartsCompactWithoutEnteringFullscreenOrChangingWindowCapabilities() throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Sem sessão gráfica") }
        let window = window()
        defer { window.close() }
        let mask = window.styleMask, behavior = window.collectionBehavior
        window.isRestorable = true
        CompactLibraryWindow.prepare(window)
        XCTAssertFalse(window.isRestorable)
        XCTAssertFalse(window.isOpaque, "An opaque window hides the desktop glass backdrop")
        XCTAssertEqual(window.backgroundColor, .clear)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertTrue(window.isMovableByWindowBackground)
        XCTAssertEqual(window.styleMask, mask)
        XCTAssertEqual(window.collectionBehavior, behavior)
        XCTAssertFalse(window.styleMask.contains(.fullScreen))
        XCTAssertFalse(window.collectionBehavior.contains(.fullScreenNone))
        let expected = LibraryWindowStartup.compactFrame(for: window, visibleFrame: (window.screen ?? screen).visibleFrame)
        let pixel = 1 / max(window.backingScaleFactor, 1)
        XCTAssertEqual(window.frame.origin.x, expected.origin.x, accuracy: pixel)
        XCTAssertEqual(window.frame.origin.y, expected.origin.y, accuracy: pixel)
        XCTAssertEqual(window.frame.size, expected.size)
        let requested = window.frameRect(forContentRect: CGRect(origin: .zero, size: LibraryWindowStartup.contentSize))
        if screen.visibleFrame.width >= requested.width && screen.visibleFrame.height >= requested.height {
            XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, LibraryWindowStartup.contentSize)
        }
        XCTAssertFalse(window.isVisible, "Preparing a window must not activate or display it")
    }

    func testProbeRecreationAndLaterPreparationNeverUndoManualResize() throws {
        let window = window()
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let first = CompactLibraryWindow.Probe(frame: .zero)
        content.addSubview(first)
        let manualFrame = CGRect(x: 80, y: 90, width: 1000, height: 760)
        window.setFrame(manualFrame, display: false)
        first.removeFromSuperview()
        let second = CompactLibraryWindow.Probe(frame: .zero)
        content.addSubview(second)
        CompactLibraryWindow.prepare(window)
        XCTAssertEqual(window.frame, manualFrame)
        XCTAssertNil(second.hitTest(.zero), "The background probe must not intercept controls")
    }

    func testNativeFrameIncludesTitlebarAndClampsToVisibleDisplayWithNegativeOrigin() {
        let window = window()
        defer { window.close() }
        let large = CGRect(x: -1900, y: 150, width: 1600, height: 1000)
        let frame = LibraryWindowStartup.compactFrame(for: window, visibleFrame: large)
        XCTAssertEqual(window.contentRect(forFrameRect: frame).size, CGSize(width: 880, height: 620))
        XCTAssertEqual(frame.midX, large.midX)
        XCTAssertEqual(frame.midY, large.midY)
        XCTAssertTrue(large.contains(frame))
        let small = CGRect(x: -700, y: -200, width: 700, height: 500)
        XCTAssertEqual(LibraryWindowStartup.compactFrame(for: window, visibleFrame: small), small)
    }

    func testLegacyFullscreenRequestsOneExitAndWaitsForMatchingWindowNotificationBeforeSizing() {
        let window = window(), other = self.window()
        defer { window.close(); other.close() }
        let center = StartupNotificationCenter()
        let actions = Actions(); actions.fullscreen = true
        let startup = LibraryWindowStartup(window: window, notificationCenter: center,
            isFullScreen: { _ in actions.fullscreen }, exitFullScreen: { _ in actions.exits += 1 }, applySize: { _ in actions.sizes += 1 })
        startup.start(); startup.start()
        XCTAssertEqual(actions.exits, 1)
        XCTAssertEqual(actions.sizes, 0)
        XCTAssertTrue(startup.isWaitingForFullScreenExit)
        XCTAssertEqual(center.observerCount, 2)
        center.post(name: NSWindow.didExitFullScreenNotification, object: other)
        XCTAssertEqual(actions.sizes, 0)
        actions.fullscreen = false
        center.post(name: NSWindow.didExitFullScreenNotification, object: window)
        XCTAssertEqual(actions.sizes, 1)
        XCTAssertFalse(startup.isWaitingForFullScreenExit)
        XCTAssertEqual(center.observerCount, 0)
        // Subsequent user fullscreen transitions must have no startup listener.
        actions.fullscreen = true; startup.start()
        center.post(name: NSWindow.didExitFullScreenNotification, object: window)
        XCTAssertEqual(actions.exits, 1)
        XCTAssertEqual(actions.sizes, 1)
    }

    func testNormalStartupNeverRequestsFullscreenAndNeverKeepsObservers() {
        let window = window()
        defer { window.close() }
        let center = StartupNotificationCenter()
        let actions = Actions()
        let startup = LibraryWindowStartup(window: window, notificationCenter: center,
            isFullScreen: { _ in actions.fullscreen }, exitFullScreen: { _ in actions.exits += 1 }, applySize: { _ in actions.sizes += 1 })
        startup.start()
        actions.fullscreen = true
        startup.start()
        center.post(name: NSWindow.didExitFullScreenNotification, object: window)
        XCTAssertEqual(actions.exits, 0)
        XCTAssertEqual(actions.sizes, 1)
        XCTAssertEqual(center.observerCount, 0)
    }

    func testCloseAndDeallocationReleasePendingObserversWithoutResizing() {
        let window = window()
        defer { window.close() }
        let center = StartupNotificationCenter()
        let actions = Actions()
        var startup: LibraryWindowStartup? = LibraryWindowStartup(window: window, notificationCenter: center,
            isFullScreen: { _ in true }, exitFullScreen: { _ in }, applySize: { _ in actions.sizes += 1 })
        startup?.start()
        XCTAssertEqual(center.observerCount, 2)
        center.post(name: NSWindow.willCloseNotification, object: window)
        XCTAssertEqual(center.observerCount, 0)
        XCTAssertFalse(startup?.isWaitingForFullScreenExit ?? true)
        weak var weakStartup = startup
        startup = nil
        XCTAssertNil(weakStartup)
        center.post(name: NSWindow.didExitFullScreenNotification, object: window)
        XCTAssertEqual(actions.sizes, 0)

        startup = LibraryWindowStartup(window: window, notificationCenter: center,
            isFullScreen: { _ in true }, exitFullScreen: { _ in }, applySize: { _ in actions.sizes += 1 })
        startup?.start()
        XCTAssertEqual(center.observerCount, 2)
        weakStartup = startup
        startup = nil
        XCTAssertNil(weakStartup)
        XCTAssertEqual(center.observerCount, 0)
    }

    func testFailedOrIgnoredNativeExitExpiresWithoutRetryOrLaterResize() async throws {
        let window = window()
        defer { window.close() }
        let center = StartupNotificationCenter()
        let actions = Actions(); actions.fullscreen = true
        let startup = LibraryWindowStartup(window: window, notificationCenter: center, maximumExitWait: .milliseconds(20),
            isFullScreen: { _ in actions.fullscreen }, exitFullScreen: { _ in actions.exits += 1 }, applySize: { _ in actions.sizes += 1 })
        startup.start()
        let deadline = ContinuousClock.now + .seconds(2)
        while startup.isWaitingForFullScreenExit, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(startup.isWaitingForFullScreenExit)
        XCTAssertEqual(center.observerCount, 0)
        actions.fullscreen = false
        center.post(name: NSWindow.didExitFullScreenNotification, object: window)
        startup.start()
        XCTAssertEqual(actions.exits, 1)
        XCTAssertEqual(actions.sizes, 0)
    }
}
