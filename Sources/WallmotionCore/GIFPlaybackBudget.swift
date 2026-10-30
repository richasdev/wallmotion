import Foundation

/// Estimated decoded frames retained per display, including paused GIFs.
/// Each view is charged separately, even when its source file is shared.
public struct GIFPlaybackBudget: Equatable, Sendable {
    public static let defaultLimit: UInt64 = 512 * 1024 * 1024
    public let limit: UInt64
    public private(set) var bytesByDisplay: [String: UInt64] = [:]

    public init(limit: UInt64 = defaultLimit) { self.limit = limit }

    public var totalBytes: UInt64 { bytesByDisplay.values.reduce(0, +) }

    /// Returns a proposal; the caller commits it only after rendering succeeds.
    /// nil releases a display's charge (photo, video, removal or disconnect).
    public func replacing(displayID: String, decodedBytes: UInt64?) throws -> Self {
        var next = self
        next.bytesByDisplay[displayID] = nil
        let remaining = limit - next.totalBytes
        if let decodedBytes {
            guard decodedBytes <= remaining else { throw GIFPlaybackBudgetError.exceeded(limit: limit) }
            next.bytesByDisplay[displayID] = decodedBytes
        }
        return next
    }

    public func retaining(displays: Set<String>) -> Self {
        var next = self
        next.bytesByDisplay = bytesByDisplay.filter { displays.contains($0.key) }
        return next
    }
}

public enum GIFPlaybackBudgetError: LocalizedError, Equatable {
    case exceeded(limit: UInt64)

    public var errorDescription: String? {
        switch self {
        case .exceeded(let limit):
            "O limite global de GIFs entre monitores (\(limit / (1024 * 1024)) MiB estimados) seria excedido. O wallpaper atual foi mantido. Remova um GIF de outro monitor ou use MP4."
        }
    }
}
