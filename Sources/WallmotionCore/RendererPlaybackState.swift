import Foundation

/// Combines playback intent with renderer-local visibility and lifetime.
/// Neither a visibility change nor a seek completion can undo a pause or stop.
public struct RendererPlaybackState: Equatable, Sendable {
    public private(set) var isPaused = true
    public private(set) var isVisible = false
    public private(set) var isStopped = false
    public private(set) var pendingRestart: UUID?
    private var restartFailed = false

    public init() {}

    public var shouldPlay: Bool {
        !isPaused && isVisible && !isStopped && pendingRestart == nil && !restartFailed
    }

    public mutating func setPaused(_ value: Bool) {
        guard !isStopped else { return }
        isPaused = value
    }

    public mutating func setVisible(_ value: Bool) {
        guard !isStopped else { return }
        isVisible = value
    }

    public mutating func beginRestart() -> UUID? {
        guard !isStopped, pendingRestart == nil else { return nil }
        let token = UUID()
        pendingRestart = token
        restartFailed = false
        return token
    }

    /// False means this completion is stale, duplicated or arrived after stop.
    @discardableResult
    public mutating func completeRestart(_ token: UUID, finished: Bool) -> Bool {
        guard !isStopped, pendingRestart == token else { return false }
        pendingRestart = nil
        restartFailed = !finished
        return true
    }

    public mutating func stop() {
        isStopped = true
        pendingRestart = nil
    }
}
