import Foundation
import Observation

/// Queues startup events independently of AppKit callback ordering. Secondary
/// instances never import locally and keep unconfirmed batches for explicit retry.
@MainActor @Observable
final class LaunchEventRouter {
    static let maximumTrackedURLs = 256
    private static let limitMessage = "Este lote não foi enviado: há espaço para até 256 arquivos pendentes ou em envio. Aguarde a conclusão e selecione um lote menor."
    private(set) var hasRejectedURLs = false
    @ObservationIgnored private var inFlightURLCount = 0
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
    @ObservationIgnored private let onRejection: @MainActor (String) -> Void

    init(isPrimary: @escaping @MainActor () -> Bool, isBusy: @escaping @MainActor () -> Bool,
         importURLs: @escaping @MainActor ([URL]) -> Void,
         activateOwner: @escaping @MainActor () async throws -> Void,
         forward: @escaping @MainActor ([URL]) async throws -> Void,
         terminate: @escaping @MainActor () -> Void,
         onRejection: @escaping @MainActor (String) -> Void = { _ in }) {
        self.isPrimary = isPrimary
        self.isBusy = isBusy
        self.importURLs = importURLs
        self.activateOwner = activateOwner
        self.forward = forward
        self.terminate = terminate
        self.onRejection = onRejection
    }

    @discardableResult func receive(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return true }
        waitingForInitialFiles = false
        guard urls.count <= Self.maximumTrackedURLs - pendingURLs.count - inFlightURLCount else {
            hasRejectedURLs = true
            errorMessage = Self.limitMessage
            InstanceDiagnostics.log.warning("Launch URL batch rejected; count=\(urls.count, privacy: .public)")
            reportPrimaryRejection()
            return false
        }
        pendingURLs.append(contentsOf: urls)
        route()
        return true
    }

    func finishLaunching(isDefaultLaunch: Bool) {
        guard !finishedLaunching else { return }
        finishedLaunching = true
        // Unlike the documented single-file callback, general open-URL batches
        // are not assumed to have arrived before didFinishLaunching.
        waitingForInitialFiles = !isDefaultLaunch && pendingURLs.isEmpty && !hasRejectedURLs
        InstanceDiagnostics.log.info("Launch routing default=\(isDefaultLaunch, privacy: .public) pending=\(self.pendingURLs.count, privacy: .public)")
        route()
    }

    func retry() {
        errorMessage = hasRejectedURLs ? Self.limitMessage : nil
        route()
    }

    func activateAndClose() {
        // Explicit acknowledgement of rejected (unretained) URLs. Accepted
        // unconfirmed batches are still forwarded/retried before closing.
        hasRejectedURLs = false
        waitingForInitialFiles = false
        retry()
    }

    private func reportPrimaryRejection() {
        guard hasRejectedURLs, isPrimary() else { return }
        // The model owns its alert after this callback. Do not re-present an
        // acknowledged primary warning on every subsequent valid file event.
        hasRejectedURLs = false
        onRejection(Self.limitMessage)
    }

    private func route() {
        guard finishedLaunching, task == nil else { return }
        if isPrimary() {
            reportPrimaryRejection()
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
                self.inFlightURLCount = 0
                self.isForwarding = false
                if self.isPrimary(), (!self.pendingURLs.isEmpty || self.hasRejectedURLs) { self.route() }
            }
            do {
                try await self.activateOwner()
                while !self.pendingURLs.isEmpty {
                    let batch = self.pendingURLs
                    self.inFlightURLCount = batch.count
                    self.pendingURLs.removeAll()
                    do {
                        try await self.forward(batch)
                        self.inFlightURLCount = 0
                    } catch {
                        self.inFlightURLCount = 0
                        self.pendingURLs.insert(contentsOf: batch, at: 0)
                        throw error
                    }
                }
                if !self.waitingForInitialFiles && !self.hasRejectedURLs {
                    InstanceDiagnostics.log.info("Secondary dispatch acknowledged; requesting exit")
                    self.terminate()
                } else if self.hasRejectedURLs {
                    InstanceDiagnostics.log.info("Secondary retaining rejected-batch notice")
                } else {
                    InstanceDiagnostics.log.info("Secondary awaiting initial file event")
                }
            } catch {
                InstanceDiagnostics.log.info("Secondary dispatch unconfirmed; keeping queued events")
                // Do not expose OS errors containing file URLs or provider tokens.
                let deliveryError = "Não foi possível confirmar o envio à outra instância. Confira a biblioteca aberta antes de tentar novamente."
                self.errorMessage = self.hasRejectedURLs ? deliveryError + "\n\n" + Self.limitMessage : deliveryError
            }
        }
    }
}
