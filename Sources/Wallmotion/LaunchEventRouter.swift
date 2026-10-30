import Foundation
import Observation

/// Queues startup events independently of AppKit callback ordering. Secondary
/// instances never import locally and keep unconfirmed batches for explicit retry.
@MainActor @Observable
final class LaunchEventRouter {
    private(set) var isForwarding = false
    private(set) var errorMessage: String?
    private(set) var waitingForInitialFiles = false
    private(set) var pendingURLs: [URL] = []
    @ObservationIgnored private var finishedLaunching = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let isPrimary: @MainActor () -> Bool
    @ObservationIgnored private let isBusy: @MainActor () -> Bool
    @ObservationIgnored private let importURLs: @MainActor ([URL]) -> Void
    @ObservationIgnored private let activateOwner: @MainActor () async throws -> Void
    @ObservationIgnored private let forward: @MainActor ([URL]) async throws -> Void
    @ObservationIgnored private let terminate: @MainActor () -> Void

    init(isPrimary: @escaping @MainActor () -> Bool, isBusy: @escaping @MainActor () -> Bool,
         importURLs: @escaping @MainActor ([URL]) -> Void,
         activateOwner: @escaping @MainActor () async throws -> Void,
         forward: @escaping @MainActor ([URL]) async throws -> Void,
         terminate: @escaping @MainActor () -> Void) {
        self.isPrimary = isPrimary
        self.isBusy = isBusy
        self.importURLs = importURLs
        self.activateOwner = activateOwner
        self.forward = forward
        self.terminate = terminate
    }

    func receive(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        pendingURLs.append(contentsOf: urls)
        waitingForInitialFiles = false
        route()
    }

    func finishLaunching(isDefaultLaunch: Bool) {
        guard !finishedLaunching else { return }
        finishedLaunching = true
        // Unlike the documented single-file callback, general open-URL batches
        // are not assumed to have arrived before didFinishLaunching.
        waitingForInitialFiles = !isDefaultLaunch && pendingURLs.isEmpty
        route()
    }

    func retry() { errorMessage = nil; route() }

    func activateAndClose() {
        waitingForInitialFiles = false
        retry()
    }

    private func route() {
        guard finishedLaunching, task == nil else { return }
        if isPrimary() {
            let batch = pendingURLs
            pendingURLs.removeAll()
            waitingForInitialFiles = false
            if !batch.isEmpty { importURLs(batch) }
            return
        }
        guard isBusy() else { return }
        isForwarding = true
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.task = nil
                self.isForwarding = false
                if self.isPrimary(), !self.pendingURLs.isEmpty { self.route() }
            }
            do {
                try await self.activateOwner()
                while !self.pendingURLs.isEmpty {
                    let batch = self.pendingURLs
                    self.pendingURLs.removeAll()
                    do { try await self.forward(batch) }
                    catch {
                        self.pendingURLs.insert(contentsOf: batch, at: 0)
                        throw error
                    }
                }
                if !self.waitingForInitialFiles { self.terminate() }
            } catch {
                // Do not expose OS errors containing file URLs or provider tokens.
                self.errorMessage = "Não foi possível confirmar o envio à outra instância. Confira a biblioteca aberta antes de tentar novamente."
            }
        }
    }
}
