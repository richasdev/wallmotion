import Foundation
import XCTest
@testable import Wallmotion

@MainActor
final class LaunchEventRouterTests: XCTestCase {
    @MainActor private final class Gate {
        private var opened = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            guard !opened else { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func open() { opened = true; continuation?.resume(); continuation = nil }
    }

    @MainActor private final class Values { var fail = true; var primary = false }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { XCTFail("Router did not settle before test deadline"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testPrimaryBuffersEarlyEventsAndImportsLaterEventsWithoutForwarding() {
        let early = URL(fileURLWithPath: "/temporary/early.jpg")
        let late = URL(fileURLWithPath: "/temporary/late.mp4")
        var batches: [[URL]] = []
        var foreignCalls = 0
        let router = LaunchEventRouter(isPrimary: { true }, isBusy: { false }, importURLs: { batches.append($0) }, activateOwner: { foreignCalls += 1 }, forward: { _ in foreignCalls += 1 }, terminate: { foreignCalls += 1 })
        router.receive([early])
        XCTAssertTrue(batches.isEmpty)
        router.finishLaunching(isDefaultLaunch: false)
        router.receive([late])
        XCTAssertEqual(batches, [[early], [late]])
        XCTAssertEqual(foreignCalls, 0)
        XCTAssertTrue(router.pendingURLs.isEmpty)
    }

    func testSecondaryWaitsForLateInitialEventAndDrainsArrivalsBeforeQuitting() async throws {
        let early = URL(fileURLWithPath: "/temporary/early.jpg")
        let late = URL(fileURLWithPath: "/temporary/late.mp4")
        let gate = Gate()
        var forwarded: [[URL]] = []
        var terminated = 0
        var imports = 0
        let router = LaunchEventRouter(isPrimary: { false }, isBusy: { true }, importURLs: { _ in imports += 1 }, activateOwner: {}, forward: { batch in
            forwarded.append(batch)
            if forwarded.count == 1 { await gate.wait() }
        }, terminate: { terminated += 1 })
        router.finishLaunching(isDefaultLaunch: false)
        try await waitUntil { !router.isForwarding }
        XCTAssertTrue(router.waitingForInitialFiles)
        XCTAssertEqual(terminated, 0)
        router.receive([early])
        try await waitUntil { forwarded.count == 1 }
        router.receive([late])
        XCTAssertEqual(terminated, 0)
        gate.open()
        try await waitUntil { terminated == 1 }
        XCTAssertEqual(forwarded, [[early], [late]])
        XCTAssertEqual(imports, 0)
        XCTAssertTrue(router.pendingURLs.isEmpty)
    }

    func testFailedForwardRetainsBatchAndSanitizesErrorUntilExplicitRetry() async throws {
        let url = URL(fileURLWithPath: "/temporary/private.jpg")
        let values = Values()
        var terminated = 0
        var imports = 0
        let router = LaunchEventRouter(isPrimary: { false }, isBusy: { true }, importURLs: { _ in imports += 1 }, activateOwner: {}, forward: { _ in
            if values.fail { throw NSError(domain: "PRIVATE_TOKEN", code: 1, userInfo: [NSLocalizedDescriptionKey: "https://secret.invalid/?token=PRIVATE_TOKEN"]) }
        }, terminate: { terminated += 1 })
        router.receive([url])
        router.finishLaunching(isDefaultLaunch: true)
        try await waitUntil { !router.isForwarding }
        XCTAssertEqual(router.pendingURLs, [url])
        XCTAssertNotNil(router.errorMessage)
        XCTAssertFalse(router.errorMessage?.contains("PRIVATE_TOKEN") == true)
        XCTAssertEqual(terminated, 0)
        values.fail = false
        router.retry()
        try await waitUntil { terminated == 1 }
        XCTAssertTrue(router.pendingURLs.isEmpty)
        XCTAssertEqual(imports, 0)
    }

    func testEventsArrivingDuringDefaultLaunchActivationAreStillForwarded() async throws {
        let gate = Gate()
        let url = URL(fileURLWithPath: "/temporary/late.jpg")
        var forwarded: [URL] = []
        var terminated = 0
        let router = LaunchEventRouter(isPrimary: { false }, isBusy: { true }, importURLs: { _ in XCTFail("Secondary imported") }, activateOwner: { await gate.wait() }, forward: { forwarded += $0 }, terminate: { terminated += 1 })
        router.finishLaunching(isDefaultLaunch: true)
        XCTAssertEqual(terminated, 0)
        router.receive([url])
        gate.open()
        try await waitUntil { terminated == 1 }
        XCTAssertEqual(forwarded, [url])
    }

    func testUnavailableSessionKeepsEventsAndRetryCanBecomePrimary() {
        let values = Values()
        var imported: [URL] = []
        var foreignCalls = 0
        let url = URL(fileURLWithPath: "/temporary/retry.jpg")
        let router = LaunchEventRouter(isPrimary: { values.primary }, isBusy: { false }, importURLs: { imported += $0 }, activateOwner: { foreignCalls += 1 }, forward: { _ in foreignCalls += 1 }, terminate: { foreignCalls += 1 })
        router.receive([url])
        router.finishLaunching(isDefaultLaunch: true)
        XCTAssertEqual(router.pendingURLs, [url])
        XCTAssertEqual(foreignCalls, 0)
        values.primary = true
        router.retry()
        XCTAssertEqual(imported, [url])
        XCTAssertTrue(router.pendingURLs.isEmpty)
    }

    func testActivationFailureKeepsAllEventsWithoutForwardingOrQuitting() async throws {
        let url = URL(fileURLWithPath: "/temporary/queued.jpg")
        var foreignCalls = 0
        let router = LaunchEventRouter(isPrimary: { false }, isBusy: { true }, importURLs: { _ in foreignCalls += 1 }, activateOwner: { throw NSError(domain: "PRIVATE_TOKEN", code: 2) }, forward: { _ in foreignCalls += 1 }, terminate: { foreignCalls += 1 })
        router.receive([url])
        router.finishLaunching(isDefaultLaunch: true)
        try await waitUntil { !router.isForwarding }
        XCTAssertEqual(router.pendingURLs, [url])
        XCTAssertEqual(foreignCalls, 0)
        XCTAssertNotNil(router.errorMessage)
        XCTAssertFalse(router.errorMessage?.contains("PRIVATE_TOKEN") == true)
    }
    func testStartupBoundaryRejectsOnlyNewBatchAndPrimaryReceivesWarningOnce() {
        let values = Values()
        let accepted = Array(repeating: URL(fileURLWithPath: "/temporary/accepted.png"), count: 256)
        let rejected = URL(fileURLWithPath: "/temporary/PRIVATE_TOKEN.png")
        var batches: [[URL]] = []
        var notices: [String] = []
        let router = LaunchEventRouter(isPrimary: { values.primary }, isBusy: { false }, importURLs: { batches.append($0) }, activateOwner: {}, forward: { _ in }, terminate: {}, onRejection: { notices.append($0) })
        XCTAssertTrue(router.receive(accepted))
        XCTAssertFalse(router.receive([rejected]))
        XCTAssertEqual(router.pendingURLs, accepted)
        XCTAssertTrue(router.hasRejectedURLs)
        XCTAssertFalse(router.errorMessage?.contains("PRIVATE_TOKEN") == true)
        values.primary = true
        router.finishLaunching(isDefaultLaunch: false)
        XCTAssertEqual(batches, [accepted])
        XCTAssertEqual(notices.count, 1)
        XCTAssertFalse(router.hasRejectedURLs)
        XCTAssertTrue(router.receive([rejected])) // Space was drained; a valid later event does not repeat the warning.
        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(notices.count, 1)
    }

    func testInFlightReservationAndFailedRequeueStayWithinLimitUntilExplicitAcknowledgement() async throws {
        let gate = Gate()
        let values = Values()
        let active = Array(repeating: URL(fileURLWithPath: "/temporary/active.png"), count: 200)
        let queued = Array(repeating: URL(fileURLWithPath: "/temporary/queued.png"), count: 56)
        var forwards: [[URL]] = []
        var terminated = 0
        let router = LaunchEventRouter(isPrimary: { false }, isBusy: { true }, importURLs: { _ in XCTFail("Secondary imported") }, activateOwner: {}, forward: { batch in
            forwards.append(batch)
            if values.fail { await gate.wait(); throw NSError(domain: "PRIVATE_TOKEN", code: 1) }
        }, terminate: { terminated += 1 })
        router.receive(active)
        router.finishLaunching(isDefaultLaunch: false)
        try await waitUntil { forwards.count == 1 }
        XCTAssertTrue(router.receive(queued))
        XCTAssertFalse(router.receive([URL(fileURLWithPath: "/temporary/excess.png")]))
        XCTAssertEqual(router.pendingURLs, queued)
        gate.open()
        try await waitUntil { !router.isForwarding }
        XCTAssertEqual(router.pendingURLs, active + queued)
        XCTAssertEqual(router.pendingURLs.count, 256)
        XCTAssertEqual(terminated, 0)
        XCTAssertFalse(router.errorMessage?.contains("PRIVATE_TOKEN") == true)
        values.fail = false
        router.retry()
        try await waitUntil { forwards.count == 2 && !router.isForwarding }
        XCTAssertEqual(forwards[1], active + queued)
        XCTAssertTrue(router.pendingURLs.isEmpty)
        XCTAssertTrue(router.hasRejectedURLs)
        XCTAssertNotNil(router.errorMessage)
        XCTAssertEqual(terminated, 0, "A successful dispatch must not hide a rejected-batch notice.")
        router.activateAndClose()
        try await waitUntil { terminated == 1 }
        XCTAssertFalse(router.hasRejectedURLs)
    }

    func testOversizedInitialEventDoesNotMasqueradeAsWaitingForInitialFiles() async throws {
        var terminated = 0
        let router = LaunchEventRouter(isPrimary: { false }, isBusy: { true }, importURLs: { _ in XCTFail("Secondary imported") }, activateOwner: {}, forward: { _ in XCTFail("Rejected batch forwarded") }, terminate: { terminated += 1 })
        XCTAssertFalse(router.receive(Array(repeating: URL(fileURLWithPath: "/temporary/large.png"), count: 257)))
        router.finishLaunching(isDefaultLaunch: false)
        try await waitUntil { !router.isForwarding }
        XCTAssertTrue(router.pendingURLs.isEmpty)
        XCTAssertFalse(router.waitingForInitialFiles)
        XCTAssertTrue(router.hasRejectedURLs)
        XCTAssertNotNil(router.errorMessage)
        XCTAssertEqual(terminated, 0)
    }

    func testSuccessfulForwardReleasesReservationWhileRejectedNoticeKeepsSecondaryOpen() async throws {
        let gate = Gate()
        var forwards: [[URL]] = []
        let batch = Array(repeating: URL(fileURLWithPath: "/temporary/file.png"), count: 256)
        let router = LaunchEventRouter(isPrimary: { false }, isBusy: { true }, importURLs: { _ in }, activateOwner: {}, forward: { urls in
            forwards.append(urls)
            await gate.wait()
        }, terminate: { XCTFail("Rejected notice must keep the secondary open") })
        router.receive(batch)
        router.finishLaunching(isDefaultLaunch: true)
        try await waitUntil { forwards.count == 1 }
        XCTAssertFalse(router.receive([URL(fileURLWithPath: "/temporary/excess.png")]))
        gate.open()
        try await waitUntil { !router.isForwarding }
        XCTAssertTrue(router.receive(batch))
        try await waitUntil { forwards.count == 2 && !router.isForwarding }
        XCTAssertEqual(forwards, [batch, batch])
    }

}
