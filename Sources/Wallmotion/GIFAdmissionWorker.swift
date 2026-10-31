import Foundation
import WallmotionCore

struct GIFAdmission: Sendable {
    let identity: GIFFileIdentity
    let metadata: GIFMetadata
}

struct GIFAssignmentAdmissionRequest: Sendable {
    let urls: [String: URL]
    let connectedIDs: Set<String>
    let limit: UInt64
}

struct GIFAdmissionBatch: Sendable {
    let byDisplay: [String: GIFAdmission]
    let budget: GIFPlaybackBudget
}

/// File-content inspection always runs on this actor, independently of AppKit.
/// A cancelled synchronous scan keeps this slot until it returns; it does not
/// publish or populate the memo after observing cancellation.
actor GIFAdmissionWorker {
    static let shared = GIFAdmissionWorker()
    typealias Inspect = @Sendable (URL) throws -> GIFMetadata
    private let inspectContent: Inspect
    private var metadata: [GIFFileIdentity: GIFMetadata] = [:]

    init(inspect: @escaping Inspect = { try GIFPreflight.inspect(url: $0) }) {
        inspectContent = inspect
    }

    func inspect(url: URL) throws -> GIFAdmission {
        try Task.checkCancellation()
        let identity = try GIFFileIdentity.read(url: url)
        if let cached = metadata[identity] { return GIFAdmission(identity: identity, metadata: cached) }
        let value = try inspectContent(url)
        try Task.checkCancellation()
        guard try GIFFileIdentity.read(url: url) == identity else { throw GIFAnimationError.nativeStatus(9) }
        if metadata.count >= 128 { metadata.removeAll(keepingCapacity: true) }
        metadata[identity] = value
        return GIFAdmission(identity: identity, metadata: value)
    }

    func admit(_ requests: [String: URL], limit: UInt64) throws -> GIFAdmissionBatch {
        var byURL: [URL: GIFAdmission] = [:], byDisplay: [String: GIFAdmission] = [:]
        var budget = GIFPlaybackBudget(limit: limit)
        for (display, url) in requests.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            let value: GIFAdmission
            if let cached = byURL[url] { value = cached }
            else { value = try inspect(url: url);byURL[url] = value }
            budget = try budget.replacing(displayID: display, decodedBytes: value.metadata.decodedBytes, sourceID: value.identity.resourceKey)
            byDisplay[display] = value
        }
        return GIFAdmissionBatch(byDisplay: byDisplay, budget: budget)
    }
}
