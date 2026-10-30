import Foundation
import Testing
@testable import WallmotionCore

@Suite("Safe web playback diagnostics")
struct WebPlaybackFailureTests {
    @Test func knownProviderErrorsHaveActionableDistinctMessages() {
        #expect(WebPlaybackFailure.message(provider: .youtube, code: "153").contains("153"))
        #expect(WebPlaybackFailure.message(provider: .youtube, code: "101").contains("incorporação"))
        #expect(WebPlaybackFailure.message(provider: .youtube, code: "100").contains("privado"))
        #expect(WebPlaybackFailure.message(provider: .vimeo, code: "PrivacyError").contains("endereço completo"))
        #expect(WebPlaybackFailure.message(provider: .vimeo, code: "PasswordError").contains("senha"))
        #expect(WebPlaybackFailure.message(provider: .vimeo, code: "PlaybackError").contains("não informou a causa"))
    }

    @Test(arguments: ["PlaybackError: https://vimeo.com/video?h=PRIVATE_TOKEN", "https://secret.invalid/?token=PRIVATE_TOKEN", "UNKNOWN_PRIVATE_TOKEN", String(repeating: "a", count: 10000)])
    func untrustedProviderTextNeverLeaksIntoUserDiagnostics(_ raw: String) {
        let message = WebPlaybackFailure.message(provider: .vimeo, code: raw)
        #expect(!message.contains("PRIVATE_TOKEN"))
        #expect(!message.contains("https://"))
        #expect(message.utf8.count < 512)
    }

    @Test func navigationFailuresDoNotEchoNSErrorDescriptionsOrURLs() {
        for code in [NSURLErrorTimedOut, NSURLErrorCannotConnectToHost, NSURLErrorServerCertificateUntrusted] {
            let error = NSError(domain: NSURLErrorDomain, code: code, userInfo: [NSLocalizedDescriptionKey: "https://example.com/?h=PRIVATE_TOKEN", NSURLErrorFailingURLErrorKey: URL(string: "https://example.com/?token=PRIVATE_TOKEN")!])
            let message = WebPlaybackFailure.navigationMessage(provider: .vimeo, error: error)
            #expect(message.contains("Vimeo"))
            #expect(!message.contains("PRIVATE_TOKEN"))
            #expect(!message.contains("https://"))
        }
    }
}
