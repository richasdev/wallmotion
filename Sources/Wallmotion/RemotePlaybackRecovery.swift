import Foundation

/// Runtime-only state; never persisted with library settings or media URLs.
enum RemotePlaybackState: Equatable {
    case loading, playing, paused, buffering, error(String), stopped

    var description: String {
        switch self {
        case .loading: "Carregando vídeo remoto…"
        case .playing: "Reproduzindo vídeo remoto"
        case .paused: "Vídeo remoto pausado"
        case .buffering: "Aguardando dados ou conexão…"
        case .error: "Erro no vídeo remoto"
        case .stopped: "Reprodução encerrada"
        }
    }
}

@MainActor
protocol RecoveryCancellation: AnyObject {
    func cancel()
}

@MainActor
protocol RecoveryScheduling {
    func schedule(after delay: Duration, action: @escaping @MainActor () -> Void) -> any RecoveryCancellation
}

@MainActor
private final class RecoveryTask: RecoveryCancellation {
    private var task: Task<Void, Never>?

    init(delay: Duration, action: @escaping @MainActor () -> Void) {
        task = Task { @MainActor in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            action()
        }
    }

    func cancel() { task?.cancel(); task = nil }
    deinit { task?.cancel() }
}

struct RecoveryScheduler: RecoveryScheduling {
    func schedule(after delay: Duration, action: @escaping @MainActor () -> Void) -> any RecoveryCancellation {
        RecoveryTask(delay: delay, action: action)
    }
}

/// Event driven policy with a session-wide retry budget. Successful playback does
/// not replenish it: a flapping server cannot cause endless background reloads.
@MainActor
final class RemotePlaybackRecovery {
    private(set) var state: RemotePlaybackState = .paused
    private(set) var attempts = 0
    private let scheduler: any RecoveryScheduling
    private let retry: @MainActor () -> Void
    private let onState: @MainActor (RemotePlaybackState) -> Void
    private let delays: [Duration] = [.seconds(2), .seconds(4), .seconds(8)]
    private var pending: (any RecoveryCancellation)?
    private var generation = 0
    private var paused = true
    private var stopped = false
    private var connected = true
    private var needsRecovery = true
    private var terminalMessage: String?

    init(scheduler: any RecoveryScheduling = RecoveryScheduler(),
         retry: @escaping @MainActor () -> Void,
         onState: @escaping @MainActor (RemotePlaybackState) -> Void) {
        self.scheduler = scheduler
        self.retry = retry
        self.onState = onState
    }

    var canPlay: Bool { !paused && !stopped && terminalMessage == nil }

    func setPaused(_ value: Bool) {
        guard !stopped, paused != value else { return }
        paused = value
        cancelPending()
        if let terminalMessage { publish(.error(terminalMessage)); return }
        if value { publish(.paused) }
        else {
            publish(.loading)
            if needsRecovery { scheduleRecovery() }
        }
    }

    func waiting(ready: Bool) {
        guard canPlay else { return }
        needsRecovery = true
        publish(ready ? .buffering : .loading)
        scheduleRecovery()
    }

    func playing() {
        guard canPlay else { return }
        needsRecovery = false
        cancelPending()
        publish(.playing)
    }

    func failed(transient: Bool, message: String) {
        guard !stopped, terminalMessage == nil else { return }
        needsRecovery = true
        if transient {
            guard !paused else { return }
            publish(.buffering)
            scheduleRecovery()
        } else {
            terminalMessage = message
            cancelPending()
            publish(.error(message))
        }
    }

    func connectivityChanged(available: Bool) {
        guard !stopped, connected != available else { return }
        connected = available
        guard canPlay, needsRecovery else { return }
        if !available { cancelPending(); publish(.buffering) }
        else { scheduleRecovery() }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        cancelPending()
        publish(.stopped)
    }

    private func scheduleRecovery() {
        guard canPlay, connected, pending == nil else { return }
        let ticket = generation
        // After the last reload give AVFoundation a final bounded opportunity
        // to start, rather than declaring failure at the instant of replacement.
        let delay: Duration = attempts == delays.count || (attempts == 0 && state == .loading)
            ? .seconds(15) : delays[attempts]
        pending = scheduler.schedule(after: delay) { [weak self] in
            guard let self, self.generation == ticket, self.canPlay, self.connected else { return }
            self.pending = nil
            guard self.attempts < self.delays.count else {
                self.failed(transient: false, message: "O vídeo remoto não respondeu após 3 tentativas. Confira a conexão e tente novamente.")
                return
            }
            self.attempts += 1
            self.publish(.loading)
            self.retry()
            if self.needsRecovery { self.scheduleRecovery() }
        }
    }

    private func cancelPending() {
        generation += 1
        pending?.cancel()
        pending = nil
    }

    private func publish(_ next: RemotePlaybackState) {
        guard state != next else { return }
        state = next
        onState(next)
    }
}
