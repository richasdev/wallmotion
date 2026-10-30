import AppKit
import WebKit
import JavaScriptCore
import XCTest
import WallmotionCore
@testable import Wallmotion

@MainActor
final class WebWallpaperRendererTests: XCTestCase {
    @MainActor private final class TestVisibility {
        var visible = false
        var windows: [NSWindow] = []
        func read(_ window: NSWindow) -> Bool {
            if !windows.contains(where: { $0 === window }) { windows.append(window) }
            return visible
        }
    }

    func testCoveredWebStaysDiscardedAcrossResumeAndVisibility() throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Sem display") }
        let wallpaper = try Wallpaper.web("https://youtu.be/M7lc1UVf-VE")
        let visibility = TestVisibility()
        let renderer = try WallpaperRenderer(
            wallpaper: wallpaper, url: LibraryStore().resolvedURL(for: wallpaper), screen: screen,
            webDocument: "<html><body>Offline occlusion fixture</body></html>",
            isWindowVisible: { visibility.read($0) }
        ) { XCTFail($0) }
        defer { renderer.stop() }
        let surface = try XCTUnwrap(renderer.window.contentView)
        XCTAssertTrue(surface.subviews.isEmpty, "Inicialização coberta não deve criar WKWebView")
        renderer.setPaused(false)
        XCTAssertTrue(surface.subviews.isEmpty)
        visibility.visible = true
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: renderer.window)
        let first = try XCTUnwrap(surface.subviews.first as? WKWebView)
        renderer.setPaused(false)
        XCTAssertTrue(surface.subviews.first === first, "Retomada repetida não deve recarregar embed visível")
        visibility.visible = false
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: renderer.window)
        XCTAssertTrue(surface.subviews.isEmpty)
        XCTAssertNil(first.superview)
        // No new visibility event follows manual/policy resume while covered.
        renderer.setPaused(false)
        renderer.setPaused(true)
        renderer.setPaused(false)
        var policy = PlaybackPolicy()
        policy.sleeping = true
        renderer.setPaused(policy.isPaused(settings: PlaybackSettings(), lowPower: false))
        policy.sleeping = false
        renderer.setPaused(policy.isPaused(settings: PlaybackSettings(), lowPower: false))
        renderer.setPaused(policy.isPaused(settings: PlaybackSettings(), lowPower: true))
        renderer.setPaused(policy.isPaused(settings: PlaybackSettings(), lowPower: false))
        XCTAssertTrue(surface.subviews.isEmpty, "Resume, wake e baixo consumo não desfazem oclusão")
        renderer.setPaused(true)
        visibility.visible = true
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: renderer.window)
        XCTAssertTrue(surface.subviews.isEmpty, "Visibilidade não desfaz pausa manual")
        renderer.setPaused(false)
        let resumed = try XCTUnwrap(surface.subviews.first as? WKWebView)
        XCTAssertFalse(resumed === first)
        renderer.stop()
        renderer.setPaused(false)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: renderer.window)
        XCTAssertTrue(surface.subviews.isEmpty, "Stop é terminal")
    }

    func testCoveredWebStaysDiscardedAcrossPreservedAndForcedRebuild() throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Sem display") }
        for text in ["https://youtu.be/M7lc1UVf-VE", "https://vimeo.com/76979871"] {
            let wallpaper = try Wallpaper.web(text)
            let state = LibraryState(wallpapers: [wallpaper], assignments: ["test": wallpaper.id])
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let store = LibraryStore(rootURL: root)
            let visibility = TestVisibility()
            let engine = DesktopCoordinator(
                targets: { [DesktopTarget(id: "test", screen: screen)] },
                isWindowVisible: { visibility.read($0) },
                webDocument: "<html><body>Offline rebuild fixture</body></html>"
            )
            defer { engine.stop(); try? FileManager.default.removeItem(at: root) }
            engine.rebuild(state: state, store: store, paused: false) { _, error in XCTFail(error) }
            let original = try XCTUnwrap(visibility.windows.first)
            let surface = try XCTUnwrap(original.contentView)
            XCTAssertTrue(surface.subviews.isEmpty, "Restauração coberta não cria WKWebView")
            visibility.visible = true
            NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: original)
            XCTAssertNotNil(surface.subviews.first as? WKWebView)
            visibility.visible = false
            NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: original)
            XCTAssertTrue(surface.subviews.isEmpty)
            engine.setPaused(false)
            engine.rebuild(state: state, store: store, paused: false, force: false) { _, error in XCTFail(error) }
            XCTAssertEqual(visibility.windows.count, 1, "Rebuild deve preservar o renderer")
            XCTAssertTrue(surface.subviews.isEmpty, "Rebuild preservado não recria view coberta")
            engine.rebuild(state: state, store: store, paused: false, force: true) { _, error in XCTFail(error) }
            XCTAssertEqual(visibility.windows.count, 2)
            let replacement = try XCTUnwrap(visibility.windows.last)
            let newSurface = try XCTUnwrap(replacement.contentView)
            XCTAssertTrue(newSurface.subviews.isEmpty, "Rebuild forçado coberto também não cria view")
            XCTAssertFalse(original.isVisible)
            visibility.visible = true
            // Rebuild must resample visibility even without an occlusion event.
            engine.rebuild(state: state, store: store, paused: false, force: false) { _, error in XCTFail(error) }
            XCTAssertNotNil(newSurface.subviews.first as? WKWebView)
            visibility.visible = false
            engine.rebuild(state: state, store: store, paused: false, force: false) { _, error in XCTFail(error) }
            XCTAssertTrue(newSurface.subviews.isEmpty)
            engine.setPaused(true)
            visibility.visible = true
            NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: replacement)
            XCTAssertTrue(newSurface.subviews.isEmpty)
            engine.setPaused(false)
            XCTAssertNotNil(newSurface.subviews.first as? WKWebView)
            engine.stop()
            engine.setPaused(false)
            NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: replacement)
            XCTAssertTrue(newSurface.subviews.isEmpty)
        }
    }

    func testTargetedRetryKeepsCoveredWebDiscardedAndPreservesOtherDisplay() throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Sem display") }
        let youtube = try Wallpaper.web("https://youtu.be/M7lc1UVf-VE")
        let vimeo = try Wallpaper.web("https://vimeo.com/76979871")
        let state = LibraryState(wallpapers: [youtube, vimeo], assignments: ["left": youtube.id, "right": vimeo.id])
        var windows: [NSWindow] = []
        var leftCovered = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LibraryStore(rootURL: root)
        let engine = DesktopCoordinator(targets: {
            [DesktopTarget(id: "left", screen: screen), DesktopTarget(id: "right", screen: screen)]
        }, isWindowVisible: { window in
            if !windows.contains(where: { $0 === window }) { windows.append(window) }
            return (windows.count >= 2 && window === windows[1]) || !leftCovered
        }, webDocument: "<html><body>Offline targeted retry fixture</body></html>")
        defer { engine.stop(); try? FileManager.default.removeItem(at: root) }
        func rebuild() {
            engine.rebuild(state: state, store: store, paused: false, onState: { _, _ in
                XCTFail("Fonte web não deve criar estado/recuperação de vídeo direto")
            }) { _, error in XCTFail(error) }
        }
        rebuild()
        XCTAssertEqual(windows.count, 2)
        let left = try XCTUnwrap(windows.first)
        let right = windows[1]
        let rightSurface = try XCTUnwrap(right.contentView)
        let rightView = try XCTUnwrap(rightSurface.subviews.first as? WKWebView)
        leftCovered = true
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: left)
        XCTAssertTrue(try XCTUnwrap(left.contentView).subviews.isEmpty)
        engine.invalidate(displayID: "left")
        rebuild()
        XCTAssertEqual(windows.count, 3)
        XCTAssertFalse(left.isVisible)
        XCTAssertTrue(rightSurface.subviews.first === rightView, "Retry do outro monitor preserva player web")
        let replacement = try XCTUnwrap(windows.last)
        let replacementSurface = try XCTUnwrap(replacement.contentView)
        XCTAssertTrue(replacementSurface.subviews.isEmpty, "Retry ainda coberto não cria WKWebView")
        leftCovered = false
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: replacement)
        XCTAssertNotNil(replacementSurface.subviews.first as? WKWebView)
        XCTAssertTrue(rightSurface.subviews.first === rightView)
        engine.stop()
        XCTAssertTrue(rightSurface.subviews.isEmpty)
    }

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

    func testProviderAudioCommandsUseBooleanPolicyWithoutRestartOffline() throws {
        for provider in [WebEmbed.Provider.youtube, .vimeo] {
            let embed = try WebEmbed(provider: provider, videoID: provider == .youtube ? "M7lc1UVf-VE" : "76979871")
            let html = WebWallpaperRenderer.document(embed: embed, origin: "https://dev.richas.wallmotion")
            let context = try XCTUnwrap(JSContext())
            context.evaluateScript("""
            var window=this, muted=true, plays=0;
            var document={getElementById:function(){return {}}};
            window.webkit={messageHandlers:{playback:{postMessage:function(){}}}};
            var transport={mute:function(){muted=true},unMute:function(){muted=false},playVideo:function(){plays++}};
            var YT={Player:function(id,options){options.events.onReady({target:transport});return transport}};
            var promise={then:function(fn){fn();return promise},catch:function(){return promise}};
            var Vimeo={Player:function(){return {on:function(){},ready:function(){return promise},setMuted:function(value){muted=value;return promise},play:function(){plays++;return promise}}}};
            """)
            let regex = try NSRegularExpression(pattern: "<script>([\\s\\S]*?)</script>")
            for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                let range = try XCTUnwrap(Range(match.range(at: 1), in: html))
                context.evaluateScript(String(html[range]))
                XCTAssertNil(context.exception, context.exception?.toString() ?? "")
            }
            if provider == .youtube { context.evaluateScript("onYouTubeIframeAPIReady()") }
            XCTAssertNil(context.exception, context.exception?.toString() ?? "")
            XCTAssertEqual(context.objectForKeyedSubscript("muted")?.toBool(), true)
            let plays = context.objectForKeyedSubscript("plays")?.toInt32()
            context.evaluateScript("window.setAudioEnabled(true)")
            XCTAssertEqual(context.objectForKeyedSubscript("muted")?.toBool(), false)
            context.evaluateScript("window.setAudioEnabled(false)")
            XCTAssertEqual(context.objectForKeyedSubscript("muted")?.toBool(), true)
            context.evaluateScript("window.setAudioEnabled('true')")
            XCTAssertEqual(context.objectForKeyedSubscript("muted")?.toBool(), true)
            XCTAssertEqual(context.objectForKeyedSubscript("plays")?.toInt32(), plays)
            XCTAssertNil(context.exception, context.exception?.toString() ?? "")
        }
    }

    func testVimeoVolumePoliciesSerializeAndDiscardStaleUnmute() async throws {
        let html = WebWallpaperRenderer.document(embed: try WebEmbed.parse("https://vimeo.com/76979871"), origin: "https://dev.richas.wallmotion")
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var window=this, muted=true, volume=1, plays=0, events=[], errors=[], pendingVolumes=[];
        var document={getElementById:function(){return {}}};
        window.webkit={messageHandlers:{playback:{postMessage:function(value){if(String(value).indexOf('error:')===0)errors.push(value)}}}};
        var Vimeo={Player:function(){return {
          on:function(){},ready:function(){return Promise.resolve()},play:function(){plays++;return Promise.resolve()},
          setMuted:function(value){muted=value;events.push('mute:'+value);return Promise.resolve()},
          setVolume:function(value){events.push('volume:'+value);return new Promise(function(resolve,reject){pendingVolumes.push(function(fail){if(fail)reject(new Error('injected failure'));else{volume=value;resolve()}})})}
        }}};
        """)
        let regex = try NSRegularExpression(pattern: "<script>([\\s\\S]*?)</script>")
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            let range = try XCTUnwrap(Range(match.range(at: 1), in: html))
            context.evaluateScript(String(html[range]))
            XCTAssertNil(context.exception, context.exception?.toString() ?? "")
        }
        func waitUntil(_ expression: String) async throws {
            let deadline = ContinuousClock.now + .seconds(2)
            while ContinuousClock.now < deadline {
                if context.evaluateScript(expression)?.toBool() == true { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTFail("JS policy did not settle: \(expression)")
        }
        try await waitUntil("plays===1")
        context.evaluateScript("events=[];window.setAudioPolicy(true,0.8)")
        try await waitUntil("pendingVolumes.length===1")
        context.evaluateScript("window.setAudioPolicy(false,0.2);window.setAudioPolicy(true,0.3)")
        XCTAssertTrue(context.objectForKeyedSubscript("muted")?.toBool() == true)
        context.evaluateScript("pendingVolumes.shift()()")
        try await waitUntil("pendingVolumes.length===1 && events.indexOf('volume:0.3')>=0")
        XCTAssertFalse(context.evaluateScript("events.indexOf('mute:false')>=0")?.toBool() == true)
        XCTAssertFalse(context.evaluateScript("events.indexOf('volume:0.2')>=0")?.toBool() == true)
        context.evaluateScript("pendingVolumes.shift()()")
        try await waitUntil("muted===false && volume===0.3")
        XCTAssertEqual(context.objectForKeyedSubscript("plays")?.toInt32(), 1, "Changing gain must not restart transport")
        context.evaluateScript("window.setAudioPolicy(true,0.7)")
        try await waitUntil("pendingVolumes.length===1")
        context.evaluateScript("window.setAudioPolicy(false,0.2)")
        XCTAssertTrue(context.objectForKeyedSubscript("muted")?.toBool() == true, "Urgent mute cannot wait for a stalled gain promise")
        context.evaluateScript("pendingVolumes.shift()()")
        try await waitUntil("pendingVolumes.length===1")
        context.evaluateScript("pendingVolumes.shift()()")
        try await waitUntil("muted===true && volume===0.2")
        context.evaluateScript("window.setAudioPolicy(true,0.9)")
        try await waitUntil("pendingVolumes.length===1")
        context.evaluateScript("window.setAudioPolicy(false,0.1);pendingVolumes.shift()(true)")
        try await waitUntil("pendingVolumes.length===1")
        XCTAssertEqual(context.evaluateScript("errors.length")?.toInt32(), 0, "Obsolete gain failures must not tear down the current player")
        context.evaluateScript("pendingVolumes.shift()()")
        try await waitUntil("muted===true && volume===0.1")
        context.evaluateScript("window.setAudioPolicy(true,NaN)")
        try await waitUntil("pendingVolumes.length===1")
        context.evaluateScript("pendingVolumes.shift()()")
        try await waitUntil("muted===true && volume===0")
        context.evaluateScript("window.setAudioPolicy(true,0.9)")
        try await waitUntil("pendingVolumes.length===1")
        context.evaluateScript("pendingVolumes.shift()(true)")
        try await waitUntil("errors.length===1")
        XCTAssertNil(context.exception, context.exception?.toString() ?? "")
    }

    func testYouTubeVolumeIsBoundedBeforeUnmuteWithoutRestart() throws {
        let html = WebWallpaperRenderer.document(embed: try WebEmbed.parse("https://youtu.be/M7lc1UVf-VE"), origin: "https://dev.richas.wallmotion")
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var window=this,muted=true,volume=100,plays=0,events=[];
        window.webkit={messageHandlers:{playback:{postMessage:function(){}}}};
        var transport={mute:function(){muted=true;events.push('mute')},unMute:function(){muted=false;events.push('unmute')},setVolume:function(v){volume=v;events.push('volume:'+v)},playVideo:function(){plays++}};
        var YT={Player:function(id,options){options.events.onReady({target:transport});return transport}};
        """)
        let regex = try NSRegularExpression(pattern: "<script>([\\s\\S]*?)</script>")
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            let range = try XCTUnwrap(Range(match.range(at: 1), in: html))
            context.evaluateScript(String(html[range]))
        }
        context.evaluateScript("onYouTubeIframeAPIReady();events=[];window.setAudioPolicy(true,0.25)")
        XCTAssertEqual(context.evaluateScript("events.join(',')")?.toString(), "volume:25,unmute")
        context.evaluateScript("window.setAudioPolicy(true,0.3333333333)")
        XCTAssertEqual(context.objectForKeyedSubscript("volume")?.toInt32(), 33)
        context.evaluateScript("window.setAudioPolicy(true,Infinity)")
        XCTAssertEqual(context.objectForKeyedSubscript("volume")?.toInt32(), 0)
        XCTAssertTrue(context.objectForKeyedSubscript("muted")?.toBool() == true)
        context.evaluateScript("window.setAudioPolicy(true,2)")
        XCTAssertEqual(context.objectForKeyedSubscript("volume")?.toInt32(), 100)
        XCTAssertEqual(context.objectForKeyedSubscript("plays")?.toInt32(), 1)
        XCTAssertNil(context.exception, context.exception?.toString() ?? "")
    }

    func testReadyAudioPolicySurvivesViewReplacementWithoutNetwork() async throws {
        let document = """
        <script>window.audio=false;window.setAudioPolicy=function(value,volume){window.audio=value===true && volume>0;window.volume=volume;window.applies=(window.applies||0)+1};
        window.webkit.messageHandlers.playback.postMessage('ready');</script>
        """
        let renderer = try WebWallpaperRenderer(embed: WebEmbed(provider: .youtube, videoID: "M7lc1UVf-VE"), onError: { XCTFail($0) }, document: document)
        defer { renderer.stop() }
        renderer.setAudioPolicy(enabled: true, volume: 0.25)
        renderer.setPaused(false)
        let first = try XCTUnwrap(renderer.webView)
        func waitForAudio(_ expected: Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while ContinuousClock.now < deadline {
                if let actual = try? await renderer.webView?.evaluateJavaScript("window.audio"), actual as? Bool == expected { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTFail("Audio policy did not reach ready document")
        }
        try await waitForAudio(true)
        let firstVolume = try await renderer.webView?.evaluateJavaScript("window.volume")
        XCTAssertEqual(firstVolume as? Double, 0.25)
        renderer.setAudioPolicy(enabled: true, volume: 0.25)
        renderer.setPaused(false)
        let applies = try await renderer.webView?.evaluateJavaScript("window.applies")
        XCTAssertEqual(applies as? Int, 1, "Unchanged policy must not enqueue more SDK commands")
        renderer.setAudioPolicy(enabled: true, volume: 0)
        try await waitForAudio(false)
        renderer.setAudioPolicy(enabled: true, volume: 0.4)
        try await waitForAudio(true)
        renderer.setAudioEnabled(false)
        try await waitForAudio(false)
        XCTAssertTrue(renderer.webView === first)
        renderer.setAudioEnabled(true)
        renderer.setPaused(true)
        renderer.setPaused(false)
        XCTAssertFalse(renderer.webView === first)
        try await waitForAudio(true)
        let restoredVolume = try await renderer.webView?.evaluateJavaScript("window.volume")
        XCTAssertEqual(restoredVolume as? Double, 0.4)
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
        renderer.setAudioPolicy(enabled: false, volume: 0.25)
        let volumeDeadline = ContinuousClock.now + .seconds(5)
        var observedVolume: Double?
        while ContinuousClock.now < volumeDeadline {
            let result: Any?
            if embed.provider == .youtube { result = try await renderer.webView?.evaluateJavaScript("player.getVolume()") }
            else { result = try await renderer.webView?.callAsyncJavaScript("return await player.getVolume()", in: nil, contentWorld: .page) }
            observedVolume = (result as? NSNumber)?.doubleValue
            if let observedVolume, abs(observedVolume - (embed.provider == .youtube ? 25 : 0.25)) < 0.001 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(try XCTUnwrap(observedVolume), embed.provider == .youtube ? 25 : 0.25, accuracy: 0.001)
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
