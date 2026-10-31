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
    private let decode: Decode
    private var assets: [GIFFileIdentity: WeakPreparedGIF] = [:]
    private(set) var decodeCount = 0

    init(limit: UInt64 = GIFPlaybackBudget.defaultLimit,
         decode: @escaping Decode = { try GIFAnimation(url: $0, limits: $1) }) {
        self.limit = limit; self.decode = decode
    }

    func prepare(url: URL) throws -> PreparedGIF {
        try Task.checkCancellation()
        assets = assets.filter { $0.value.value != nil }
        let identity = try GIFFileIdentity.read(url: url)
        if let asset = assets[identity]?.value { return asset }
        let metadata = try GIFPreflight.inspect(url: url)
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
    private let worker: GIFDecodeWorker
    private var requests: [String: URL]?
    private var completion: (@MainActor (Results) -> Void)?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(worker: GIFDecodeWorker = .shared) { self.worker = worker }
    deinit { task?.cancel() }

    func submit(_ requests: [String: URL], completion: @escaping @MainActor (Results) -> Void) {
        self.completion = completion
        if self.requests == requests { return }
        cancelTask()
        self.requests = requests
        if requests.isEmpty { self.requests = nil; self.completion = nil; completion([:]); return }
        let token = generation, worker = worker
        task = Task(priority: .utility) { [weak self] in
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
            guard let self, self.generation == token, !Task.isCancelled else { return }
            self.task = nil; self.requests = nil
            let completion = self.completion; self.completion = nil
            completion?(results)
        }
    }

    func cancel() { cancelTask(); requests = nil; completion = nil }
    private func cancelTask() { generation = UUID(); task?.cancel(); task = nil }
}
