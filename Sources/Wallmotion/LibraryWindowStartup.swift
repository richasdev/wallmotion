import AppKit
import SwiftUI
import ObjectiveC

/// Applies the library's initial size once per native window. SwiftUI may create
/// or attach the background probe repeatedly without resetting a user's window.
struct CompactLibraryWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe {
        let probe = Probe(frame: .zero)
        probe.setAccessibilityElement(false)
        return probe
    }

    func updateNSView(_ view: Probe, context: Context) {}

    @MainActor final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { CompactLibraryWindow.prepare(window) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor private enum Association {
        static var key: UInt8 = 0
    }

    @MainActor static func prepare(_ window: NSWindow) {
        guard objc_getAssociatedObject(window, &Association.key) == nil else { return }
        let startup = LibraryWindowStartup(window: window)
        // Retained by this window, with a weak reference back. This marker lives
        // across probe recreation, without a global registry retaining windows.
        objc_setAssociatedObject(window, &Association.key, startup, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        startup.start()
    }
}

/// One-shot startup policy. Injected actions exercise the legacy fullscreen path
/// without entering or changing the user's macOS Spaces in tests.
@MainActor
final class LibraryWindowStartup {
    static let contentSize = CGSize(width: 880, height: 620)
    private weak var window: NSWindow?
    private var started = false
    private var waitingForExit = false
    private var exitDeadline: Task<Void, Never>?
    private let maximumExitWait: Duration
    private let observations: WindowStartupObservations
    private let isFullScreen: @MainActor (NSWindow) -> Bool
    private let exitFullScreen: @MainActor (NSWindow) -> Void
    private let applySize: @MainActor (NSWindow) -> Void

    var isWaitingForFullScreenExit: Bool { waitingForExit }

    init(window: NSWindow, notificationCenter: NotificationCenter = .default,
         maximumExitWait: Duration = .seconds(8),
         isFullScreen: @escaping @MainActor (NSWindow) -> Bool = { $0.styleMask.contains(.fullScreen) },
         exitFullScreen: @escaping @MainActor (NSWindow) -> Void = { $0.toggleFullScreen(nil) },
         applySize: @escaping @MainActor (NSWindow) -> Void = LibraryWindowStartup.applyCompactFrame) {
        self.window = window
        self.maximumExitWait = maximumExitWait
        observations = WindowStartupObservations(center: notificationCenter)
        self.isFullScreen = isFullScreen
        self.exitFullScreen = exitFullScreen
        self.applySize = applySize
    }

    deinit { exitDeadline?.cancel() }

    func start() {
        guard !started, let window else { return }
        started = true
        window.isRestorable = false
        guard isFullScreen(window) else {
            applySize(window)
            return
        }
        waitingForExit = true
        observations.observe(NSWindow.didExitFullScreenNotification, window: window) { [weak self] in self?.didExitFullScreen() }
        observations.observe(NSWindow.willCloseNotification, window: window) { [weak self] in self?.cancel() }
        // AppKit exposes failed exit only through the existing window delegate,
        // which SwiftUI owns. Bound this one startup attempt instead of replacing
        // that delegate or reacting to a later manual fullscreen transition.
        let maximumExitWait = maximumExitWait
        exitDeadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: maximumExitWait) } catch { return }
            self?.cancel()
        }
        exitFullScreen(window)
    }

    private func didExitFullScreen() {
        guard waitingForExit else { return }
        cancel()
        guard let window, !isFullScreen(window) else { return }
        applySize(window)
    }

    private func cancel() {
        waitingForExit = false
        exitDeadline?.cancel()
        exitDeadline = nil
        observations.cancel()
    }

    static func compactFrame(for window: NSWindow, visibleFrame: CGRect) -> CGRect {
        let requested = window.frameRect(forContentRect: CGRect(origin: .zero, size: contentSize)).size
        let size = CGSize(width: min(requested.width, visibleFrame.width), height: min(requested.height, visibleFrame.height))
        return CGRect(x: visibleFrame.midX - size.width / 2, y: visibleFrame.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    static func applyCompactFrame(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else {
            window.setContentSize(contentSize)
            return
        }
        window.setFrame(compactFrame(for: window, visibleFrame: screen.visibleFrame), display: false, animate: false)
    }
}

/// NotificationCenter removal is thread-safe, including destruction after the
/// owning window is released. Callbacks capture startup state weakly.
private final class WindowStartupObservations {
    private let center: NotificationCenter
    private var tokens: [NSObjectProtocol] = []

    init(center: NotificationCenter) { self.center = center }

    @MainActor func observe(_ name: Notification.Name, window: NSWindow, action: @escaping @MainActor () -> Void) {
        tokens.append(center.addObserver(forName: name, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        })
    }

    func cancel() {
        tokens.forEach(center.removeObserver)
        tokens.removeAll()
    }

    deinit { cancel() }
}
