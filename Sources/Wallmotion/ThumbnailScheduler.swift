import CoreGraphics
import Foundation

/// Bounds active decoders, including a cancelled codec until it actually returns.
/// Identical in-flight requests share output; no additional image cache is kept.
actor ThumbnailScheduler {
    typealias Decode = @Sendable (ThumbnailRequest) async throws -> CGImage
    static let shared = ThumbnailScheduler()

    private struct Job {
        let generation = UUID()
        var waiters: [UUID: CheckedContinuation<CGImage, any Error>] = [:]
    }
    private let maximumConcurrent: Int
    private let decode: Decode
    private var jobs: [ThumbnailRequest: Job] = [:]
    private var pending: [ThumbnailRequest] = []
    private var running: [UUID: Task<Void, Never>] = [:]

    init(maximumConcurrent: Int = 4, decode: @escaping Decode = MediaThumbnailDecoding.generate) {
        self.maximumConcurrent = max(1, min(4, maximumConcurrent))
        self.decode = decode
    }

    struct Load: Sendable {
        let active: Int
        let pending: Int
        let subscribers: Int
    }
    var load: Load { Load(active: running.count, pending: pending.count, subscribers: jobs.values.reduce(0) { $0 + $1.waiters.count }) }

    func image(for request: ThumbnailRequest) async throws -> CGImage {
        let waiter = UUID()
        let image = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CGImage, any Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if var job = jobs[request] {
                    job.waiters[waiter] = continuation
                    jobs[request] = job
                } else {
                    var job = Job()
                    job.waiters[waiter] = continuation
                    jobs[request] = job
                    pending.append(request)
                }
                startPending()
            }
        } onCancel: {
            Task { await self.cancel(waiter: waiter, request: request) }
        }
        try Task.checkCancellation()
        return image
    }

    private func cancel(waiter: UUID, request: ThumbnailRequest) {
        guard var job = jobs[request], let continuation = job.waiters.removeValue(forKey: waiter) else { return }
        if job.waiters.isEmpty {
            jobs.removeValue(forKey: request)
            pending.removeAll { $0 == request }
            // Do not release its slot yet: ImageIO may ignore cancellation while
            // inside a synchronous codec. A fresh same-key request gets a new job.
            running[job.generation]?.cancel()
        } else { jobs[request] = job }
        continuation.resume(throwing: CancellationError())
    }

    private func startPending() {
        while running.count < maximumConcurrent, !pending.isEmpty {
            let request = pending.removeFirst()
            guard let job = jobs[request] else { continue }
            let generation = job.generation
            let decode = decode
            running[generation] = Task.detached(priority: .utility) { [weak self] in
                let result: Result<CGImage, any Error>
                do {
                    try Task.checkCancellation()
                    let image = try await decode(request)
                    try Task.checkCancellation()
                    result = .success(image)
                } catch { result = .failure(error) }
                await self?.finish(request: request, generation: generation, result: result)
            }
        }
    }

    private func finish(request: ThumbnailRequest, generation: UUID, result: Result<CGImage, any Error>) {
        guard running.removeValue(forKey: generation) != nil else { return }
        if let job = jobs[request], job.generation == generation {
            jobs.removeValue(forKey: request)
            for continuation in job.waiters.values { continuation.resume(with: result) }
        }
        startPending()
    }
}
