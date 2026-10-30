import Foundation
import Testing
@testable import WallmotionCore

@Suite("Renderer playback state")
struct RendererPlaybackStateTests {
    @Test func startsPausedAndNotVisible() {
        let state = RendererPlaybackState()
        #expect(!state.shouldPlay)
        #expect(state.isPaused)
        #expect(!state.isVisible)
    }

    @Test(arguments: 0..<8)
    func playbackRequiresUnpausedVisibleAndNotStopped(_ flags: Int) {
        let paused = flags & 1 != 0
        let visible = flags & 2 != 0
        let stopped = flags & 4 != 0
        var state = RendererPlaybackState()
        state.setPaused(paused)
        state.setVisible(visible)
        if stopped { state.stop() }
        #expect(state.shouldPlay == (!paused && visible && !stopped))
    }

    @Test func resumingWhileStillCoveredAndRepeatedRefreshCannotPlay() {
        var state = RendererPlaybackState()
        state.setPaused(false)
        state.setVisible(true)
        #expect(state.shouldPlay)
        state.setVisible(false)
        for _ in 0..<3 {
            state.setPaused(true)
            state.setPaused(false)
            state.setPaused(false) // Preserved-renderer rebuild, no visibility transition.
            #expect(!state.shouldPlay)
        }
        state.setPaused(true)
        state.setVisible(true)
        #expect(!state.shouldPlay)
        state.setPaused(false)
        #expect(state.shouldPlay)
    }

    @Test(arguments: [false, true], [false, true])
    func seekCompletionRechecksCurrentPauseAndVisibility(paused: Bool, visible: Bool) throws {
        var state = RendererPlaybackState()
        state.setPaused(false)
        state.setVisible(true)
        let tokenProposal = state.beginRestart()
        let token = try #require(tokenProposal)
        #expect(!state.shouldPlay)
        let duplicateRestartRejected = state.beginRestart() == nil
        #expect(duplicateRestartRejected)
        state.setPaused(paused)
        state.setVisible(visible)
        #expect(!state.shouldPlay)
        let completionAccepted = state.completeRestart(token, finished: true)
        #expect(completionAccepted)
        #expect(state.shouldPlay == (!paused && visible))
    }

    @Test func staleFailedAndDuplicateCompletionsCannotStartPlayback() throws {
        var state = RendererPlaybackState()
        state.setPaused(false)
        state.setVisible(true)
        let firstProposal = state.beginRestart()
        let first = try #require(firstProposal)
        let unknownTokenRejected = !state.completeRestart(UUID(), finished: true)
        #expect(unknownTokenRejected)
        #expect(!state.shouldPlay)
        let failureAccepted = state.completeRestart(first, finished: false)
        #expect(failureAccepted)
        #expect(!state.shouldPlay)
        let duplicateCompletionRejected = !state.completeRestart(first, finished: true)
        #expect(duplicateCompletionRejected)
        state.setPaused(false)
        state.setVisible(true)
        #expect(!state.shouldPlay)
        let secondProposal = state.beginRestart()
        let second = try #require(secondProposal)
        let oldCompletionRejected = !state.completeRestart(first, finished: true)
        #expect(oldCompletionRejected)
        #expect(!state.shouldPlay)
        let currentCompletionAccepted = state.completeRestart(second, finished: true)
        #expect(currentCompletionAccepted)
        #expect(state.shouldPlay)
    }

    @Test func stopIsTerminalEvenWithPendingSeekAndResumeRequests() throws {
        var state = RendererPlaybackState()
        state.setPaused(false)
        state.setVisible(true)
        let tokenProposal = state.beginRestart()
        let token = try #require(tokenProposal)
        state.stop()
        let completionAfterStopRejected = !state.completeRestart(token, finished: true)
        #expect(completionAfterStopRejected)
        state.setPaused(false)
        state.setVisible(true)
        let restartAfterStopRejected = state.beginRestart() == nil
        #expect(restartAfterStopRejected)
        state.stop()
        #expect(state.isStopped)
        #expect(!state.shouldPlay)
    }
}
