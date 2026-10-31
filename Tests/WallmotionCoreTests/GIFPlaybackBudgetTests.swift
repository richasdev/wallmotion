import Testing
@testable import WallmotionCore

@Suite("Global GIF playback budget")
struct GIFPlaybackBudgetTests {
    @Test func exactGlobalLimitCountsEachDisplayAndRejectsOneByteMore() throws {
        let perFile = GIFPreflight.defaultBudget
        var budget = GIFPlaybackBudget()
        budget = try budget.replacing(displayID: "left", decodedBytes: perFile)
        budget = try budget.replacing(displayID: "right", decodedBytes: perFile)
        #expect(budget.totalBytes == GIFPlaybackBudget.defaultLimit)
        #expect(throws: GIFPlaybackBudgetError.exceeded(limit: budget.limit)) {
            try budget.replacing(displayID: "third", decodedBytes: 1)
        }
        #expect(budget.bytesByDisplay == ["left": perFile, "right": perFile])
    }

    @Test func replacementOnlyCreditsSelectedMonitorAndFailureRollsBack() throws {
        var budget = GIFPlaybackBudget(limit: 100)
        budget = try budget.replacing(displayID: "left", decodedBytes: 40)
        budget = try budget.replacing(displayID: "right", decodedBytes: 60)
        let original = budget
        #expect(throws: GIFPlaybackBudgetError.exceeded(limit: 100)) {
            try budget.replacing(displayID: "left", decodedBytes: 41)
        }
        #expect(budget == original)
        let proposal = try budget.replacing(displayID: "left", decodedBytes: 30)
        // A renderer/save failure can discard this proposal without a reservation.
        #expect(budget == original)
        #expect(proposal.bytesByDisplay == ["left": 30, "right": 60])
        #expect(try budget.replacing(displayID: "right", decodedBytes: 60) == budget)
    }

    @Test func clearPhotoVideoDisconnectAndStopReleaseCharges() throws {
        var budget = GIFPlaybackBudget(limit: 100)
        budget = try budget.replacing(displayID: "left", decodedBytes: 50)
        budget = try budget.replacing(displayID: "right", decodedBytes: 50)
        budget = budget.retaining(displays: ["right"])
        #expect(budget.totalBytes == 50)
        budget = try budget.replacing(displayID: "left", decodedBytes: 50)
        budget = try budget.replacing(displayID: "right", decodedBytes: nil)
        #expect(budget.bytesByDisplay == ["left": 50])
        budget = try budget.replacing(displayID: "right", decodedBytes: nil)
        budget = budget.retaining(displays: [])
        #expect(budget.totalBytes == 0)
        #expect(try budget.replacing(displayID: "reconnected", decodedBytes: 100).totalBytes == 100)
    }

    @Test func arithmeticCannotOverflow() throws {
        var budget = GIFPlaybackBudget(limit: .max)
        budget = try budget.replacing(displayID: "left", decodedBytes: .max)
        #expect(throws: GIFPlaybackBudgetError.exceeded(limit: .max)) {
            try budget.replacing(displayID: "right", decodedBytes: 1)
        }
        #expect(try budget.replacing(displayID: "left", decodedBytes: 1).totalBytes == 1)
        #expect(throws: GIFPlaybackBudgetError.exceeded(limit: 0)) {
            try GIFPlaybackBudget(limit: 0).replacing(displayID: "left", decodedBytes: 1)
        }
    }
    @Test func sharedIdentityChargesOnceUntilLastDisplayReleasesIt() throws {
        var budget = GIFPlaybackBudget(limit: 100)
        budget = try budget.replacing(displayID: "left", decodedBytes: 80, sourceID: "file-a")
        budget = try budget.replacing(displayID: "right", decodedBytes: 80, sourceID: "file-a")
        #expect(budget.totalBytes == 80)
        #expect(budget.retaining(displays: ["right"]).totalBytes == 80)
        #expect(try budget.replacing(displayID: "left", decodedBytes: nil).totalBytes == 80)
        #expect(throws: GIFPlaybackBudgetError.exceeded(limit: 100)) {
            try budget.replacing(displayID: "third", decodedBytes: 21, sourceID: "file-b")
        }
        budget = try budget.replacing(displayID: "left", decodedBytes: nil)
        budget = try budget.replacing(displayID: "right", decodedBytes: nil)
        #expect(budget.totalBytes == 0)
    }

    @Test func conflictingCostsUseMaximumAndLegacyNamesCannotCollide() throws {
        var budget = GIFPlaybackBudget(limit: 100)
        budget = try budget.replacing(displayID: "one", decodedBytes: 30, sourceID: "same")
        budget = try budget.replacing(displayID: "two", decodedBytes: 60, sourceID: "same")
        #expect(budget.totalBytes == 60)
        budget = try budget.replacing(displayID: "source:same", decodedBytes: 40)
        #expect(budget.totalBytes == 100)
    }

}
