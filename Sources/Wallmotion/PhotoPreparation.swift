import Foundation

/// Keeps only the latest requested batch. Repeated policy/audio refreshes may
/// update its completion without decoding the same pending pixels again.
@MainActor
final class PhotoPreparation {
    typealias Results = [String: Result<DecodedPhoto, any Error>]
    typealias Decode = @Sendable (PhotoDecodeRequest) async throws -> DecodedPhoto
    private let decode: Decode
    private var task: Task<Void, Never>?
    private var requests: [String: PhotoDecodeRequest]?
    private var token = UUID()
    private var completion: (@MainActor (Results) -> Void)?

    init(decode: @escaping Decode = { try await PhotoDecodeWorker.shared.decode($0) }) {
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
        task = Task(priority: .utility) { [weak self] in
            var results: Results = [:]
            var shared: [PhotoDecodeRequest: Result<DecodedPhoto, any Error>] = [:]
            for (display, request) in requests.sorted(by: { $0.key < $1.key }) {
                guard !Task.isCancelled else { return }
                if let cached = shared[request] { results[display] = cached; continue }
                let result: Result<DecodedPhoto, any Error>
                do { result = .success(try await decode(request)) }
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
