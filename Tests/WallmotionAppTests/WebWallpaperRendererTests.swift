import AppKit
import WebKit
import JavaScriptCore
import XCTest
import WallmotionCore
@testable import Wallmotion

@MainActor
final class WebWallpaperRendererTests: XCTestCase {
    func testPauseDiscardsViewResumeRecreatesAndStopIsTerminalWithoutNetwork() throws {
        let renderer = try WebWallpaperRenderer(embed: WebEmbed(provider: .youtube, videoID: "M7lc1UVf-VE"), onError: { XCTFail($0) }, document: "<html><body>Offline lifecycle fixture</body></html>")
        XCTAssertNil(renderer.webView)
        renderer.setPaused(true)
        XCTAssertNil(renderer.webView)
        renderer.setPaused(false)
        let first = try XCTUnwrap(renderer.webView)
        XCTAssertFalse(first.configuration.websiteDataStore.isPersistent)
        XCTAssertTrue(first.configuration.mediaTypesRequiringUserActionForPlayback.isEmpty)
        renderer.setPaused(false)
        XCTAssertTrue(renderer.webView === first)
        renderer.setPaused(true)
        XCTAssertNil(renderer.webView)
        XCTAssertTrue(renderer.surface.subviews.isEmpty)
        XCTAssertFalse(renderer.isPlaying)
        renderer.setPaused(false)
        XCTAssertNotNil(renderer.webView)
        XCTAssertFalse(renderer.webView === first)
        XCTAssertNil(first.navigationDelegate)
        XCTAssertNil(first.superview)
        renderer.stop()
        renderer.stop()
        renderer.setPaused(false)
        XCTAssertNil(renderer.webView)
        XCTAssertTrue(renderer.surface.subviews.isEmpty)
    }

    func testOfflineBridgeReportsFailureAndDiscardsDocument() async throws {
        var failure: String?
        let document = "<script>window.webkit.messageHandlers.playback.postMessage('error:153')</script>"
        let renderer = try WebWallpaperRenderer(embed: WebEmbed(provider: .youtube, videoID: "M7lc1UVf-VE"), onError: { failure = $0 }, document: document)
        defer { renderer.stop() }
        renderer.setPaused(false)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while failure == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(try XCTUnwrap(failure).contains("153"))
        XCTAssertNil(renderer.webView)
        XCTAssertTrue(renderer.surface.subviews.isEmpty)
        renderer.setPaused(false)
        XCTAssertNil(renderer.webView, "Falhas exigem recarga explícita, sem retry em eventos de monitores/energia")
    }

    func testProviderDocumentsUseOfficialAPIsAndIdentity() throws {
        let youtube = WebWallpaperRenderer.document(embed: try WebEmbed.parse("https://youtu.be/M7lc1UVf-VE"), origin: "https://dev.richas.wallmotion")
        XCTAssertTrue(youtube.contains("origin=https://dev.richas.wallmotion"))
        XCTAssertTrue(youtube.contains("strict-origin-when-cross-origin"))
        XCTAssertTrue(youtube.contains("e.target.mute();e.target.playVideo()"))
        XCTAssertTrue(youtube.contains("onAutoplayBlocked"))
        XCTAssertTrue(youtube.contains("onError"))
        let vimeo = WebWallpaperRenderer.document(embed: try WebEmbed.parse("https://vimeo.com/76979871/8272103f6e"), origin: "https://dev.richas.wallmotion")
        XCTAssertTrue(vimeo.contains("h=8272103f6e&autoplay=1&muted=1"))
        XCTAssertTrue(vimeo.contains("https://player.vimeo.com/api/player.js"))
    }

    func testInlineProviderScriptsParseAndYouTubeMutesBeforePlayOffline() throws {
        for url in ["https://youtu.be/M7lc1UVf-VE", "https://vimeo.com/76979871"] {
            let embed = try WebEmbed.parse(url)
            let html = WebWallpaperRenderer.document(embed: embed, origin: "https://dev.richas.wallmotion")
            let context = try XCTUnwrap(JSContext())
            context.evaluateScript("""
            var window=this, muted=false;
            var document={getElementById:function(id){if(id!=="player")throw Error("bad element");return {}}};
            window.webkit={messageHandlers:{playback:{postMessage:function(value){}}}};
            var YT={Player:function(id,options){
              if(id!=="player")throw Error("bad player ID");
              options.events.onReady({target:{mute:function(){muted=true},playVideo:function(){if(!muted)throw Error("unmuted playback")}}});
              options.events.onStateChange({data:1});
              options.events.onError({data:153});
              options.events.onAutoplayBlocked();
            }};
            var Vimeo={Player:function(){return {on:function(){},ready:function(){return Promise.resolve()},setMuted:function(){return Promise.resolve()},play:function(){return Promise.resolve()}}}};
            """)
            XCTAssertNil(context.exception, context.exception?.toString() ?? "")
            let regex = try NSRegularExpression(pattern: "<script>([\\s\\S]*?)</script>")
            for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                let range = try XCTUnwrap(Range(match.range(at: 1), in: html))
                context.evaluateScript(String(html[range]))
                XCTAssertNil(context.exception, context.exception?.toString() ?? "")
            }
            if embed.provider == .youtube {
                context.evaluateScript("onYouTubeIframeAPIReady()")
                XCTAssertNil(context.exception, context.exception?.toString() ?? "")
                XCTAssertEqual(context.objectForKeyedSubscript("muted")?.toBool(), true)
            }
        }
    }

    func testOptInOfficialEmbedPlaysMutedAndStops() async throws {
        guard let text = ProcessInfo.processInfo.environment["WALLMOTION_WEB_TEST_URL"] else { throw XCTSkip("Rede opt-in: defina WALLMOTION_WEB_TEST_URL com um vídeo público YouTube/Vimeo.") }
        let embed = try WebEmbed.parse(text)
        var failure: String?
        let renderer = try WebWallpaperRenderer(embed: embed, onError: { failure = $0 })
        defer { renderer.stop() }
        renderer.surface.frame = CGRect(x: 0, y: 0, width: 640, height: 360)
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Sem display") }
        let window = DesktopWindow(screen: screen, view: renderer.surface)
        defer { window.close() }
        window.orderBack(nil)
        renderer.setPaused(false)
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !renderer.isPlaying && failure == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertNil(failure)
        guard renderer.isPlaying else { XCTFail("O player oficial não confirmou reprodução: \(renderer.lastEvent)"); return }
        let script = embed.provider == .youtube ? "player.isMuted()" : "player.getMuted()"
        let muted: Any?
        if embed.provider == .youtube { muted = try await renderer.webView?.evaluateJavaScript(script) }
        else { muted = try await renderer.webView?.callAsyncJavaScript("return await player.getMuted()", in: nil, contentWorld: .page) }
        XCTAssertEqual(muted as? Bool, true)
        if let path = ProcessInfo.processInfo.environment["WALLMOTION_WEB_SNAPSHOT_PATH"] {
            let snapshot = try await renderer.webView?.takeSnapshot(configuration: nil)
            let image = try XCTUnwrap(snapshot)
            let tiff = try XCTUnwrap(image.tiffRepresentation)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: path))
        }
        renderer.setPaused(true)
        XCTAssertNil(renderer.webView)
        renderer.stop()
        XCTAssertTrue(renderer.surface.subviews.isEmpty)
    }
}
