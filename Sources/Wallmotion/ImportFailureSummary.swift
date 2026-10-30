import Foundation

/// Bounded UI diagnostics even if every accepted file fails.
struct ImportFailureSummary {
    static let maximumDetails = 10
    static let maximumDetailBytes = 1024
    private(set) var count = 0
    private(set) var details: [String] = []

    mutating func append(_ message: String) {
        count += 1
        guard details.count < Self.maximumDetails else { return }
        guard message.utf8.prefix(Self.maximumDetailBytes + 1).count > Self.maximumDetailBytes else {
            details.append(message)
            return
        }
        var bytes = Array(message.utf8.prefix(Self.maximumDetailBytes - 3))
        while String(bytes: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        details.append((String(bytes: bytes, encoding: .utf8) ?? "") + "…")
    }

    var message: String? {
        guard count > 0 else { return nil }
        var lines = details
        let remaining = count - details.count
        if remaining > 0 { lines.append("Mais \(remaining) arquivo(s) não puderam ser importados.") }
        return lines.joined(separator: "\n")
    }
}
