import XCTest
@testable import Wallmotion

@MainActor
final class ManualRecoveryScheduler: RecoveryScheduling {
    final class Entry: RecoveryCancellation {
        let delay: Duration
        let action: @MainActor () -> Void
        var cancelled = false
        init(delay: Duration, action: @escaping @MainActor () -> Void) {
            self.delay = delay
            self.action = action
        }
        func cancel() { cancelled = true }
    }
    var entries: [Entry] = []
    var active: [Entry] { entries.filter { !$0.cancelled } }
    func schedule(after delay: Duration, action: @escaping @MainActor () -> Void) -> any RecoveryCancellation {
        let entry = Entry(delay: delay, action: action)
        entries.append(entry)
        return entry
    }
    func fireNext() {
        guard let entry = active.first else { XCTFail("Esperava um backoff pendente"); return }
        entry.cancelled = true
        entry.action()
    }
}

@MainActor
final class RemotePlaybackRecoveryTests: XCTestCase {
    func testStartupPlayingBufferingAndPauseAreObservableWithoutPolling() {
        let clock = ManualRecoveryScheduler()
        var states: [RemotePlaybackState] = []
        let recovery = RemotePlaybackRecovery(scheduler: clock, retry: { XCTFail("Não deveria repetir") }, onState: { states.append($0) })
        recovery.setPaused(false)
        XCTAssertEqual(recovery.state, .loading)
        XCTAssertEqual(clock.active.first?.delay, .seconds(15))
        recovery.playing()
        XCTAssertTrue(clock.active.isEmpty)
        recovery.waiting(ready: true)
        recovery.waiting(ready: true)
        XCTAssertEqual(clock.active.count, 1)
        XCTAssertEqual(clock.active.first?.delay, .seconds(2))
        recovery.setPaused(true)
        recovery.playing() // Late KVO must not resume after policy/manual pause.
        recovery.waiting(ready: true)
        XCTAssertEqual(states, [.loading, .playing, .buffering, .paused])
        XCTAssertTrue(clock.active.isEmpty)
    }

    func testThreeAttemptsAndFinalDeadlineRequireManualRetry() {
        let clock = ManualRecoveryScheduler()
        var retries = 0
        let recovery = RemotePlaybackRecovery(scheduler: clock, retry: { retries += 1 }, onState: { _ in })
        recovery.setPaused(false)
        recovery.playing()
        recovery.waiting(ready: true)
        for expected in 1...3 {
            clock.fireNext()
            XCTAssertEqual(retries, expected)
            XCTAssertEqual(clock.active.first?.delay, expected == 1 ? .seconds(4) : expected == 2 ? .seconds(8) : .seconds(15))
            // AVFoundation reports the replacement is still buffering.
            recovery.waiting(ready: true)
        }
        clock.fireNext()
        guard case .error(let message) = recovery.state else { return XCTFail("Esperava erro terminal") }
        XCTAssertTrue(message.contains("3 tentativas"))
        recovery.connectivityChanged(available: false)
        recovery.connectivityChanged(available: true)
        recovery.playing()
        recovery.setPaused(true)
        recovery.setPaused(false)
        XCTAssertFalse(recovery.canPlay)
        XCTAssertTrue(clock.active.isEmpty)
        XCTAssertEqual(retries, 3)
    }

    func testSuccessfulPlaybackDoesNotReplenishRetryBudget() {
        let clock = ManualRecoveryScheduler()
        var retries = 0
        let recovery = RemotePlaybackRecovery(scheduler: clock, retry: { retries += 1 }, onState: { _ in })
        recovery.setPaused(false)
        for _ in 0..<3 {
            recovery.playing()
            recovery.waiting(ready: true)
            clock.fireNext()
        }
        recovery.playing()
        recovery.waiting(ready: true)
        clock.fireNext()
        XCTAssertEqual(retries, 3)
        if case .error = recovery.state {} else { XCTFail("Servidor oscilante deve esgotar o teto") }
    }

    func testOfflineWaitsForConnectivityAndIgnoresDuplicateEvents() {
        let clock = ManualRecoveryScheduler()
        var retries = 0
        let recovery = RemotePlaybackRecovery(scheduler: clock, retry: { retries += 1 }, onState: { _ in })
        recovery.setPaused(false)
        recovery.connectivityChanged(available: false)
        XCTAssertTrue(clock.active.isEmpty)
        recovery.connectivityChanged(available: true)
        recovery.connectivityChanged(available: true)
        XCTAssertEqual(clock.active.count, 1)
        XCTAssertEqual(clock.active.first?.delay, .seconds(2))
        clock.fireNext()
        XCTAssertEqual(retries, 1)
    }

    func testCancelledCallbackCannotActAfterPauseResumeOrStop() {
        let clock = ManualRecoveryScheduler()
        var retries = 0
        let recovery = RemotePlaybackRecovery(scheduler: clock, retry: { retries += 1 }, onState: { _ in })
        recovery.setPaused(false)
        let stale = clock.entries[0]
        recovery.setPaused(true)
        recovery.connectivityChanged(available: false)
        recovery.connectivityChanged(available: true)
        stale.action() // Deliberately invoke even a cancelled scheduler callback.
        XCTAssertEqual(recovery.state, .paused)
        XCTAssertEqual(retries, 0)
        recovery.setPaused(false)
        stale.action()
        XCTAssertEqual(retries, 0)
        let outstanding = clock.entries.last!
        recovery.stop()
        outstanding.action()
        recovery.setPaused(false)
        recovery.playing()
        recovery.failed(transient: false, message: "atrasado")
        XCTAssertEqual(recovery.state, .stopped)
        XCTAssertTrue(clock.active.isEmpty)
        XCTAssertEqual(retries, 0)
    }

    func testTerminalFailureCancelsBackoffAndSurvivesPolicyChanges() {
        let clock = ManualRecoveryScheduler()
        let recovery = RemotePlaybackRecovery(scheduler: clock, retry: { XCTFail("Falha terminal não pode repetir") }, onState: { _ in })
        recovery.setPaused(false)
        recovery.failed(transient: false, message: "URL expirada")
        XCTAssertEqual(recovery.state, .error("URL expirada"))
        XCTAssertTrue(clock.active.isEmpty)
        recovery.setPaused(true)
        recovery.setPaused(false)
        recovery.waiting(ready: true)
        XCTAssertEqual(recovery.state, .error("URL expirada"))
        XCTAssertFalse(recovery.canPlay)
    }

    func testTransientFailureWhilePausedWaitsForExplicitResume() {
        let clock = ManualRecoveryScheduler()
        let recovery = RemotePlaybackRecovery(scheduler: clock, retry: {}, onState: { _ in })
        recovery.failed(transient: true, message: "sem rede")
        XCTAssertEqual(recovery.state, .paused)
        XCTAssertTrue(clock.active.isEmpty)
        recovery.setPaused(false)
        XCTAssertEqual(clock.active.count, 1)
    }

    func testFailureClassificationIsConservativeAndDoesNotExposeSignedURL() {
        let secret = "https://example.com/video?token=private-secret"
        let expired = NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse,
                              userInfo: [NSLocalizedDescriptionKey: secret])
        for status in [401, 403, 404, 410] {
            let failure = RemotePlaybackFailure.classify(expired, httpStatus: status)
            XCTAssertFalse(failure.transient)
            XCTAssertTrue(failure.message.contains("HTTP \(status)"))
            XCTAssertFalse(failure.message.contains("private-secret"))
        }
        for code in [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet] {
            let underlying = NSError(domain: NSURLErrorDomain, code: code)
            let wrapped = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [NSUnderlyingErrorKey: underlying])
            XCTAssertTrue(RemotePlaybackFailure.classify(wrapped).transient)
        }
        for status in [408, 429, 500, 503] {
            XCTAssertTrue(RemotePlaybackFailure.classify(nil, httpStatus: status).transient)
        }
        XCTAssertFalse(RemotePlaybackFailure.classify(expired).transient)
        XCTAssertFalse(RemotePlaybackFailure.classify(nil).transient)
        XCTAssertFalse(RemotePlaybackFailure.classify(NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted)).transient)
    }
}
