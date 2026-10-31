import AppKit
import WebKit
import JavaScriptCore
import XCTest
import WallmotionCore
@testable import Wallmotion

@MainActor
final class ManualWebAudioRampTests: XCTestCase {
    private final class Visibility { var value = true }
    private let embed = try! WebEmbed(provider: .youtube, videoID: "M7lc1UVf-VE")
    private var document: String { """
    <script>
    var level=0,muted=true,steps=[],pending=[],mode='ack',serial=0;
    function report(v){window.webkit.messageHandlers.playback.postMessage(v)}
    window.cancelAudioRamp=function(){serial++};
    window.setAudioPolicy=function(enabled,v){level=v;muted=!enabled || v===0};
    function reply(token,v,m){
      if(mode==='drop')return;
      if(mode==='wrong'){report('ramp-ack:'+token+':1:0');return}
      if(mode==='malformed'){report('ramp-ack:'+token+':NaN:0');return}
      if(mode==='stale'){report('ramp-ack:00000000-0000-0000-0000-000000000000:'+v+':0');return}
      if(mode==='hold'){pending.push(token);return}
      report('ramp-ack:'+token+':'+v.toFixed(4)+':'+(m?'1':'0'))
    }
    window.requestAudioRampSnapshot=function(token){reply(token,level,muted)};
    window.requestAudioRampStep=function(token,enabled,v){level=v;muted=!enabled || v===0;steps.push(v);reply(token,level,muted)};
    report('ready');report('playing');
    </script>
    """ }
    private func waitUntil(_ condition: @MainActor () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Web audio fixture did not settle")
    }
    private func create() async throws -> WebWallpaperRenderer {
        _ = NSApplication.shared
        let renderer = try WebWallpaperRenderer(embed: embed, onError: { XCTFail($0) }, document: document)
        renderer.setAudioPolicy(enabled: true, volume: 0.8);renderer.setPaused(false)
        try await waitUntil {
            guard renderer.isPlaying, let view = renderer.webView else { return false }
            return try await view.evaluateJavaScript("level===0.8 && muted===false") as? Bool == true
        }
        return renderer
    }

    func testPauseVerifiesIntermediateStepThenDiscardsAndResumeUsesNewMutedDocument() async throws {
        let renderer = try await create();defer { renderer.stop() }
        let first = try XCTUnwrap(renderer.webView)
        renderer.setManuallyPaused(true, enabled: true, volume: 0.8)
        XCTAssertTrue(renderer.hasManualAudioTransition)
        try await waitUntil { try await first.evaluateJavaScript("steps.length>0") as? Bool == true }
        let middle = try await first.evaluateJavaScript("steps[0]") as? Double
        XCTAssertGreaterThan(try XCTUnwrap(middle), 0);XCTAssertLessThan(try XCTUnwrap(middle), 0.8)
        try await waitUntil { renderer.webView == nil }
        XCTAssertFalse(renderer.hasManualAudioTransition);XCTAssertFalse(renderer.hasAudioTransitionTask)
        renderer.setManuallyPaused(false, enabled: true, volume: 0.8)
        let second = try XCTUnwrap(renderer.webView)
        XCTAssertFalse(first === second)
        try await waitUntil { !renderer.hasManualAudioTransition }
        let state = try await second.evaluateJavaScript("({level:level,muted:muted,steps:steps})") as? [String: Any]
        XCTAssertEqual(state?["level"] as? Double, 0.8);XCTAssertEqual(state?["muted"] as? Bool, false)
        XCTAssertTrue((state?["steps"] as? [Double])?.contains(where: { $0 > 0 && $0 < 0.8 }) == true)
        XCTAssertFalse(renderer.hasAudioTransitionTask)
    }

    func testRapidReverseKeepsDocumentAndUsesObservedCurrentLevel() async throws {
        let renderer = try await create();defer { renderer.stop() }
        let view = try XCTUnwrap(renderer.webView)
        renderer.setManuallyPaused(true, enabled: true, volume: 0.8)
        try await waitUntil { try await view.evaluateJavaScript("steps.length>0") as? Bool == true }
        let descending = try await view.evaluateJavaScript("level") as? Double
        renderer.setManuallyPaused(false, enabled: true, volume: 0.8)
        let reversed = try await view.evaluateJavaScript("level") as? Double
        XCTAssertEqual(reversed, descending);XCTAssertTrue(renderer.webView === view)
        try await waitUntil { !renderer.hasManualAudioTransition }
        let final = try await view.evaluateJavaScript("level") as? Double
        XCTAssertEqual(final, 0.8);XCTAssertFalse(renderer.hasAudioTransitionTask)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(renderer.webView === view, "Obsolete fade-out must not discard resumed document")
    }

    func testMissingMalformedStaleAndMismatchedAcknowledgementsFailClosed() async throws {
        for mode in ["drop", "malformed", "stale", "wrong"] {
            var failure: String?
            let renderer = try WebWallpaperRenderer(embed: embed, onError: { failure = $0 }, document: document)
            defer { renderer.stop() }
            renderer.setAudioPolicy(enabled: true, volume: 0.8);renderer.setPaused(false)
            try await waitUntil { renderer.isPlaying }
            let view = try XCTUnwrap(renderer.webView)
            // Snapshot is valid, then inject failure for the first target step.
            renderer.setManuallyPaused(true, enabled: true, volume: 0.8)
            try await waitUntil {
                try await view.evaluateJavaScript("typeof level==='number'") as? Bool == true && renderer.hasAudioTransitionTask
            }
            try await view.evaluateJavaScript("mode='\(mode)'")
            var responsive = false;Task { @MainActor in responsive = true }
            try await waitUntil { failure != nil }
            XCTAssertTrue(responsive);XCTAssertNil(renderer.webView)
            XCTAssertFalse(renderer.hasAudioTransitionTask);XCTAssertFalse(renderer.hasManualAudioTransition)
            XCTAssertTrue(failure?.contains("confirmar") == true)
            renderer.setPaused(false)
            XCTAssertNil(renderer.webView, "A failed provider must not restart and unmute automatically")
        }
    }

    func testOwnershipSystemPauseStopAndPolicyChangeCancelPendingRequestImmediately() async throws {
        for action in ["owner", "system", "stop", "volume"] {
            let renderer = try await create();defer { renderer.stop() }
            let old = try XCTUnwrap(renderer.webView)
            try await old.evaluateJavaScript("mode='hold'")
            renderer.setManuallyPaused(true, enabled: true, volume: 0.8)
            try await waitUntil { try await old.evaluateJavaScript("pending.length===1") as? Bool == true }
            switch action {
            case "owner": renderer.setAudioPolicy(enabled: false, volume: 0.8)
            case "system": renderer.setPaused(true)
            case "stop": renderer.stop()
            default: renderer.setAudioPolicy(enabled: true, volume: 0)
            }
            XCTAssertNil(renderer.webView);XCTAssertFalse(renderer.hasManualAudioTransition)
            XCTAssertFalse(renderer.hasAudioTransitionTask)
            // An obsolete document cannot resurrect the renderer or time out a new request.
            _ = try? await old.evaluateJavaScript("report('ramp-ack:'+pending[0]+':0.8:0')")
            try await Task.sleep(for: .milliseconds(180))
            XCTAssertNil(renderer.webView);XCTAssertFalse(renderer.hasAudioTransitionTask)
        }
    }

    func testParentLogicalPauseDoesNotDiscardFadeUntilCompletionButOcclusionDoes() async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Sem sessão gráfica") }
        let visible = Visibility()
        let item = Wallpaper(title: "Offline", kind: .video, source: .web(embed: embed))
        let parent = try WallpaperRenderer(wallpaper: item, url: URL(string: "https://youtu.be/M7lc1UVf-VE")!, screen: screen,
            targetFrame: CGRect(x: -10000,y: -10000,width: 200,height: 100), webDocument: document,
            isWindowVisible: { _ in visible.value }) { XCTFail($0) }
        defer { parent.stop() }
        parent.setAudioPolicy(enabled: true, volume: 0.8);parent.setPaused(false)
        let surface = try XCTUnwrap(parent.window.contentView)
        let view = try XCTUnwrap(surface.subviews.first as? WKWebView)
        try await waitUntil {
            guard parent.isWebPlaying else { return false }
            return try await view.evaluateJavaScript("level===0.8 && muted===false") as? Bool == true
        }
        parent.setManuallyPaused(true)
        XCTAssertTrue(parent.playbackState.isPaused)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: parent.window)
        XCTAssertTrue(surface.subviews.first === view)
        try await waitUntil { try await view.evaluateJavaScript("steps.length>0") as? Bool == true }
        visible.value = false
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: parent.window)
        XCTAssertTrue(surface.subviews.isEmpty)
        try await Task.sleep(for: .milliseconds(250))
        visible.value = true
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: parent.window)
        XCTAssertTrue(surface.subviews.isEmpty, "Logical manual pause survives visibility returning")
    }

    private func scripts(provider: WebEmbed.Provider, setup: String) throws -> JSContext {
        let embed = try WebEmbed(provider: provider, videoID: provider == .youtube ? "M7lc1UVf-VE" : "76979871")
        let html = WebWallpaperRenderer.document(embed: embed, origin: "https://dev.richas.wallmotion")
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var window=this,events=[],muted=false,volume=0.8,plays=0;
        var document={getElementById:function(){return {}}};
        window.webkit={messageHandlers:{playback:{postMessage:function(v){events.push(v)}}}};
        var timers=[];function setTimeout(fn){timers.push(fn);return timers.length}function clearTimeout(){}
        \(setup)
        """)
        let regex = try NSRegularExpression(pattern: "<script>([\\s\\S]*?)</script>")
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            context.evaluateScript(String(html[try XCTUnwrap(Range(match.range(at: 1), in: html))]))
            XCTAssertNil(context.exception, context.exception?.toString() ?? "")
        }
        if provider == .youtube { context.evaluateScript("onYouTubeIframeAPIReady()") }
        return context
    }

    func testYouTubeAcknowledgesGetterStateAndBoundsRetryInsteadOfTrustingVoidSetters() throws {
        let context = try scripts(provider: .youtube, setup: """
        var ignore=false;
        var transport={mute:function(){muted=true},unMute:function(){muted=false},playVideo:function(){plays++},
          setVolume:function(v){if(!ignore)volume=v/100},getVolume:function(){return volume*100},isMuted:function(){return muted}};
        var YT={Player:function(id,options){options.events.onReady({target:transport});return transport}};
        """)
        context.evaluateScript("events=[];muted=false;window.requestAudioRampSnapshot('snapshot')")
        XCTAssertEqual(context.evaluateScript("events.join(',')")?.toString(), "ramp-ack:snapshot:0.8000:0")
        context.evaluateScript("events=[];window.requestAudioRampStep('middle',true,0.3333)")
        XCTAssertEqual(context.evaluateScript("events.join(',')")?.toString(), "ramp-ack:middle:0.3300:0")
        context.evaluateScript("events=[];ignore=true;window.requestAudioRampStep('bad',true,0.2);while(timers.length)timers.shift()()")
        XCTAssertEqual(context.evaluateScript("events.join(',')")?.toString(), "ramp-fail:bad")
        context.evaluateScript("events=[];window.requestAudioRampStep('old',true,0.1);window.cancelAudioRamp();while(timers.length)timers.shift()()")
        XCTAssertEqual(context.evaluateScript("events.length")?.toInt32(), 0)
        XCTAssertEqual(context.evaluateScript("plays")?.toInt32(), 1)
        XCTAssertNil(context.exception, context.exception?.toString() ?? "")
    }

    func testVimeoSerializesInFlightSetterAcrossReverseAndInvalidatesStaleUnmute() async throws {
        let context = try scripts(provider: .vimeo, setup: """
        var pending=[],ignore=false;
        var Vimeo={Player:function(){return {
          on:function(){},ready:function(){return Promise.resolve()},play:function(){plays++;return Promise.resolve()},
          setMuted:function(v){muted=v;return Promise.resolve()},getMuted:function(){return Promise.resolve(muted)},
          setVolume:function(v){return new Promise(function(resolve){pending.push(function(){if(!ignore)volume=v;resolve(volume)})})},
          getVolume:function(){return Promise.resolve(volume)}
        }}};
        """)
        func waitJS(_ expression: String) async throws {
            try await waitUntil { context.evaluateScript(expression)?.toBool() == true }
            XCTAssertNil(context.exception, context.exception?.toString() ?? "")
        }
        try await waitJS("plays===1")
        context.evaluateScript("muted=false;events=[];window.requestAudioRampStep('old',true,0.3)")
        try await waitJS("pending.length===1")
        context.evaluateScript("window.requestAudioRampSnapshot('new')")
        XCTAssertEqual(context.evaluateScript("events.length")?.toInt32(), 0, "Snapshot waits behind in-flight setter")
        context.evaluateScript("pending.shift()()")
        try await waitJS("events.length===1")
        XCTAssertEqual(context.evaluateScript("events.join(',')")?.toString(), "ramp-ack:new:0.3000:0")
        context.evaluateScript("events=[];muted=true;window.requestAudioRampStep('cancel',true,0.6)")
        try await waitJS("pending.length===1")
        context.evaluateScript("window.cancelAudioRamp();pending.shift()()")
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertTrue(context.evaluateScript("muted")?.toBool() == true)
        XCTAssertEqual(context.evaluateScript("events.length")?.toInt32(), 0)
        context.evaluateScript("ignore=true;window.requestAudioRampStep('ignored',true,0.2)")
        try await waitJS("pending.length===1")
        context.evaluateScript("pending.shift()()")
        try await waitJS("events.length===1")
        XCTAssertEqual(context.evaluateScript("events.join(',')")?.toString(), "ramp-fail:ignored")
        context.evaluateScript("events=[];ignore=false;window.requestAudioRampStep('final',false,0)")
        try await waitJS("pending.length===1")
        context.evaluateScript("pending.shift()()")
        try await waitJS("events.length===1")
        XCTAssertEqual(context.evaluateScript("events.join(',')")?.toString(), "ramp-ack:final:0.0000:1")
    }
}
