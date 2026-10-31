import Foundation

/// Estimated payload per unique source, including paused GIFs. Legacy callers
/// without a source identity continue to charge every display separately.
public struct GIFPlaybackBudget: Equatable, Sendable {
    public static let defaultLimit: UInt64 = 512 * 1024 * 1024
    public let limit: UInt64
    public private(set) var bytesByDisplay: [String: UInt64] = [:]
    private var sourceByDisplay: [String: String] = [:]

    public init(limit: UInt64 = defaultLimit) { self.limit = limit }

    private var checkedTotal: UInt64? {
        var bySource: [String: UInt64] = [:]
        for (display, bytes) in bytesByDisplay {
            let source = sourceByDisplay[display] ?? "display:\(display)"
            bySource[source] = max(bySource[source] ?? 0, bytes)
        }
        var total: UInt64 = 0
        for bytes in bySource.values {
            let (sum, overflow) = total.addingReportingOverflow(bytes)
            if overflow { return nil }
            total = sum
        }
        return total
    }

    public var totalBytes: UInt64 { checkedTotal ?? UInt64.max }

    /// Returns a proposal; the caller commits it only after rendering succeeds.
    /// nil releases a display's charge (photo, video, removal or disconnect).
    public func replacing(displayID: String, decodedBytes: UInt64?, sourceID: String? = nil) throws -> Self {
        var next = self
        next.bytesByDisplay[displayID] = decodedBytes
        next.sourceByDisplay[displayID] = decodedBytes == nil ? nil : (sourceID.map { "source:\($0)" } ?? "display:\(displayID)")
        guard let total = next.checkedTotal, total <= limit else { throw GIFPlaybackBudgetError.exceeded(limit: limit) }
        return next
    }

    public func retaining(displays: Set<String>) -> Self {
        var next = self
        next.bytesByDisplay = bytesByDisplay.filter { displays.contains($0.key) }
        next.sourceByDisplay = sourceByDisplay.filter { displays.contains($0.key) }
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
