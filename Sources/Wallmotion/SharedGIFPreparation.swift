import Foundation
import WallmotionCore

/// Providers retain this immutable accounting object while pixels remain alive.
final class PreparedGIF: @unchecked Sendable {
    let animation: GIFAnimation
    let identity: GIFFileIdentity
    let timeline: GIFTimeline
    init(animation: GIFAnimation, identity: GIFFileIdentity) throws {
        self.animation = animation; self.identity = identity
        timeline = GIFTimeline(delaysCentiseconds: try (0..<animation.frameCount).map { try animation.delayCentiseconds(at: $0) })
    }
}

private final class WeakPreparedGIF: @unchecked Sendable {
    weak var value: PreparedGIF?
    init(_ value: PreparedGIF) { self.value = value }
}

/// Serial actor: canceled native decodes retain this slot until they actually end.
/// Weak entries count even images retained after the display/factory is gone.
actor GIFDecodeWorker {
    static let shared = GIFDecodeWorker()
    typealias Decode = @Sendable (URL, GIFAnimationLimits) throws -> GIFAnimation
    private let limit: UInt64
    let admissionWorker: GIFAdmissionWorker
    private let decode: Decode
    private var assets: [GIFFileIdentity: WeakPreparedGIF] = [:]
    private(set) var decodeCount = 0

    init(limit: UInt64 = GIFPlaybackBudget.defaultLimit, admissionWorker: GIFAdmissionWorker = .shared,
         decode: @escaping Decode = { try GIFAnimation(url: $0, limits: $1) }) {
        self.limit = limit; self.decode = decode; self.admissionWorker = admissionWorker
    }

    func prepare(url: URL) async throws -> PreparedGIF {
        let admission = try await admissionWorker.inspect(url: url)
        try Task.checkCancellation()
        assets = assets.filter { $0.value.value != nil }
        let identity = admission.identity
        if let asset = assets[identity]?.value { return asset }
        let metadata = admission.metadata
        let used = assets.values.compactMap(\.value).reduce(UInt64(0)) { $0 + $1.animation.decodedBytes }
        guard used <= limit, metadata.decodedBytes <= limit-used else { throw GIFPlaybackBudgetError.exceeded(limit: limit) }
        let limits = GIFAnimationLimits(workingBytes: min(384 * 1024 * 1024, limit-used))
        decodeCount += 1
        let animation = try decode(url, limits)
        try Task.checkCancellation()
        guard animation.sourceIdentity == identity else { throw GIFAnimationError.nativeStatus(9) }
        let asset = try PreparedGIF(animation: animation, identity: identity)
        assets[identity] = WeakPreparedGIF(asset)
        return asset
    }

    var retainedBytes: UInt64 {
        assets.values.compactMap(\.value).reduce(0) { $0 + $1.animation.decodedBytes }
    }
}

@MainActor
final class SharedGIFPreparation {
    typealias Results = [String: Result<PreparedGIF, any Error>]
    struct Outcome {
        let admission: Result<GIFAdmissionBatch, any Error>
        let images: Results
    }
    private let worker: GIFDecodeWorker
    private let limit: UInt64
    private var requests: [String: URL]?
    private var completion: (@MainActor (Outcome) -> Void)?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(worker: GIFDecodeWorker = .shared, limit: UInt64 = GIFPlaybackBudget.defaultLimit) { self.worker = worker; self.limit = limit }
    deinit { task?.cancel() }

    func submit(_ requests: [String: URL], completion: @escaping @MainActor (Outcome) -> Void) {
        self.completion = completion
        if self.requests == requests { return }
        cancelTask()
        self.requests = requests
        if requests.isEmpty { self.requests = nil; self.completion = nil; completion(Outcome(admission: .success(GIFAdmissionBatch(byDisplay: [:], budget: GIFPlaybackBudget(limit: limit))), images: [:])); return }
        let token = generation, worker = worker, limit = limit
        task = Task(priority: .utility) { [weak self] in
            let outcome: Outcome
            do {
                let admission = try await worker.admissionWorker.admit(requests, limit: limit)
                var results: Results = [:]
                var byURL: [URL: Result<PreparedGIF, any Error>] = [:]
                for (display, url) in requests.sorted(by: { $0.key < $1.key }) {
                    guard !Task.isCancelled else { return }
                    let result: Result<PreparedGIF, any Error>
                    if let existing = byURL[url] { result = existing }
                    else {
                        do { result = .success(try await worker.prepare(url: url)) }
                        catch { result = .failure(error) }
                        byURL[url] = result
                    }
                    guard !Task.isCancelled else { return }
                    results[display] = result
                }
                outcome = Outcome(admission: .success(admission), images: results)
            } catch { outcome = Outcome(admission: .failure(error), images: [:]) }
            guard let self, self.generation == token, !Task.isCancelled else { return }
            self.task = nil; self.requests = nil
            let completion = self.completion; self.completion = nil
            completion?(outcome)
        }
    }

    func cancel() { cancelTask(); requests = nil; completion = nil }
    private func cancelTask() { generation = UUID(); task?.cancel(); task = nil }
}
