import Foundation

/// Keeps only the latest requested batch. Repeated policy/audio refreshes may
/// update its completion without decoding the same pending pixels again.
@MainActor
final class PhotoPreparation {
    typealias Results = [String: Result<DecodedPhoto, any Error>]
    typealias Decode = @Sendable (PhotoDecodeRequest) async throws -> DecodedPhoto
    static let maximumRetainedBytes = 256 * 1024 * 1024
    private let maximumRetainedBytes: Int
    private let decode: Decode
    private var task: Task<Void, Never>?
    private var requests: [String: PhotoDecodeRequest]?
    private var token = UUID()
    private var completion: (@MainActor (Results) -> Void)?

    init(maximumRetainedBytes: Int = PhotoPreparation.maximumRetainedBytes, decode: @escaping Decode = PhotoDecodeWorker.prepare) {
        self.maximumRetainedBytes = max(0, maximumRetainedBytes)
        self.decode = decode
    }

    func submit(_ requests: [String: PhotoDecodeRequest], completion: @escaping @MainActor (Results) -> Void) {
        self.completion = completion
        if self.requests == requests { return }
        task?.cancel()
        token = UUID()
        self.requests = requests
        if requests.isEmpty {
            task = nil
            self.requests = nil
            self.completion = nil
            completion([:])
            return
        }
        let generation = token
        let decode = decode
        let maximumRetainedBytes = maximumRetainedBytes
        task = Task(priority: .utility) { [weak self] in
            var retainedBytes = 0
            var retainedImages: Set<ObjectIdentifier> = []
            var results: Results = [:]
            var shared: [PhotoDecodeRequest: Result<DecodedPhoto, any Error>] = [:]
            for (display, request) in requests.sorted(by: { $0.key < $1.key }) {
                guard !Task.isCancelled else { return }
                if let cached = shared[request] { results[display] = cached; continue }
                let result: Result<DecodedPhoto, any Error>
                do {
                    let photo = try await decode(request)
                    try Task.checkCancellation()
                    let identity = ObjectIdentifier(photo.image)
                    if !retainedImages.contains(identity) {
                        let height = photo.image.height
                        let rowBytes = photo.image.bytesPerRow
                        let remaining = maximumRetainedBytes - retainedBytes
                        guard height > 0, rowBytes > 0, rowBytes <= remaining / height else {
                            throw PhotoDecodingError.batchOverBudget
                        }
                        retainedBytes += rowBytes * height
                        retainedImages.insert(identity)
                    }
                    result = .success(photo)
                }
                catch { result = .failure(error) }
                guard !Task.isCancelled else { return }
                shared[request] = result
                results[display] = result
            }
            guard let self, self.token == generation, !Task.isCancelled else { return }
            self.task = nil
            self.requests = nil
            let completion = self.completion
            self.completion = nil
            completion?(results)
        }
    }

    func cancel() {
        token = UUID()
        task?.cancel()
        task = nil
        requests = nil
        completion = nil
    }
}
