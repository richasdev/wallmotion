import AppKit
import WebKit
import WallmotionCore

/// Owns only the active web view. Pausing releases the document and resumes from
/// the beginning, rather than retaining a hidden WebKit player per display.
@MainActor
final class WebWallpaperRenderer: NSObject, WKNavigationDelegate {
    let surface = NSView()
    private(set) var webView: WKWebView?
    private var stopped = false
    private var failed = false
    private var awaitingDocument = false
    private let embed: WebEmbed
    private let onError: @MainActor (String) -> Void
    private let document: String
    private let baseURL: URL
    private var bridge: WebPlaybackBridge?
    private var startupTimeout: Task<Void, Never>?
    private(set) var isPlaying = false
    private(set) var audioEnabled = false
    private(set) var audioVolume: Double = 1
    private var documentReady = false
    private var appliedAudioPolicy: String?
    private struct AudioStep {
        let token: UUID
        let level: Double?
        let muted: Bool?
        let final: Bool
    }
    private struct ManualFade {
        let paused: Bool
        var start = 0.0
        var beganAt: Double?
        var pending: AudioStep?
    }
    private var manualFade: ManualFade?
    private var fadeGeneration = UUID()
    private var fadeDeadline: Task<Void, Never>?
    private var fadeStepTask: Task<Void, Never>?
    var hasManualAudioTransition: Bool { manualFade != nil }
    var hasAudioTransitionTask: Bool { fadeDeadline != nil || fadeStepTask != nil }

    func setAudioEnabled(_ enabled: Bool) {
        guard !stopped else { return }
        setAudioPolicy(enabled: enabled, volume: audioVolume)
    }

    func setAudioPolicy(enabled: Bool, volume: Double) {
        guard !stopped else { return }
        let level = volume.isFinite ? min(1, max(0, volume)) : 0
        if manualFade != nil, audioEnabled != enabled || audioVolume != level {
            discardView() // A pending provider unmute cannot survive a new policy.
        }
        audioEnabled = enabled;audioVolume = level
        applyAudioPolicy()
    }

    private func audioPolicyScript(enabled: Bool, volume: Double) -> String {
        "window.setAudioPolicy(\(enabled && volume > 0 ? "true" : "false"),\(volume))"
    }

    private func applyAudioPolicy() {
        guard documentReady, let webView else { return }
        // A transition owns provider levels. A new resume document starts muted
        // until playing and a verified SDK observation can start its envelope.
        if let fade = manualFade, fade.pending != nil || fade.beganAt != nil { return }
        let outputVolume = audioEnabled && manualFade == nil ? audioVolume : 0
        let script = audioPolicyScript(enabled: audioEnabled && manualFade == nil, volume: outputVolume)
        guard script != appliedAudioPolicy else { return }
        appliedAudioPolicy = script
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private func clearManualAudioFade() {
        fadeGeneration = UUID();fadeDeadline?.cancel();fadeDeadline = nil
        fadeStepTask?.cancel();fadeStepTask = nil;manualFade = nil
        webView?.evaluateJavaScript("window.cancelAudioRamp && window.cancelAudioRamp()", completionHandler: nil)
    }

    func cancelManualAudioTransition() {
        if manualFade != nil { discardView() }
    }

    func setManuallyPaused(_ paused: Bool, enabled: Bool, volume: Double) {
        guard !stopped, !failed else { return }
        clearManualAudioFade()
        audioEnabled = enabled;audioVolume = volume.isFinite ? min(1, max(0, volume)) : 0
        guard enabled, audioVolume > 0 else {
            setPaused(paused);applyAudioPolicy();return
        }
        if paused, !documentReady || !isPlaying { discardView();return }
        manualFade = ManualFade(paused: paused)
        if !paused { setPaused(false) }
        beginManualAudioIfReady()
    }

    private func beginManualAudioIfReady() {
        guard let fade = manualFade, fade.beganAt == nil, fade.pending == nil,
              documentReady, isPlaying, audioEnabled, audioVolume > 0, webView != nil else { return }
        requestAudioStep(level: nil, final: false)
    }

    private func requestAudioStep(level: Double?, final: Bool) {
        guard var fade = manualFade, let view = webView, documentReady, isPlaying else { return }
        let token = UUID(), generation = fadeGeneration
        let step = AudioStep(token: token, level: level, muted: level.map { $0 <= 0 }, final: final)
        fade.pending = step;manualFade = fade
        fadeDeadline?.cancel()
        fadeDeadline = Task { @MainActor [weak self, weak view] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let self, self.fadeGeneration == generation, self.webView === view,
                  self.manualFade?.pending?.token == token else { return }
            self.manualAudioFailed()
        }
        let script: String
        if let level {
            script = "window.requestAudioRampStep('\(token.uuidString)',\(level > 0 ? "true" : "false"),\(level))"
        } else { script = "window.requestAudioRampSnapshot('\(token.uuidString)')" }
        view.evaluateJavaScript(script) { [weak self, weak view] _, error in
            guard error != nil, let self, self.fadeGeneration == generation, self.webView === view,
                  self.manualFade?.pending?.token == token else { return }
            self.manualAudioFailed()
        }
    }

    private func receiveAudioAcknowledgement(_ value: String) {
        guard value.utf8.count <= 128, var fade = manualFade, let pending = fade.pending else { return }
        let fields = value.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count >= 2, UUID(uuidString: String(fields[1])) == pending.token else { return }
        if fields[0] == "ramp-fail" { manualAudioFailed();return }
        guard fields.count == 4, fields[0] == "ramp-ack", let level = Double(fields[2]),
              level.isFinite, (0...1).contains(level), fields[3] == "0" || fields[3] == "1" else { return }
        let muted = fields[3] == "1"
        if let expected = pending.level {
            // YouTube quantizes to integer percent; Vimeo uses normalized doubles.
            let tolerance = embed.provider == .youtube ? 0.0101 : 0.001
            guard abs(level - expected) <= tolerance, muted == pending.muted else { manualAudioFailed();return }
        }
        fadeDeadline?.cancel();fadeDeadline = nil;fade.pending = nil
        if pending.level == nil {
            fade.start = muted ? 0 : level;fade.beganAt = ProcessInfo.processInfo.systemUptime
            manualFade = fade
            if abs(fade.start - (fade.paused ? 0 : audioVolume)) < 0.00001 { finishManualAudio();return }
        } else { manualFade = fade }
        if pending.final { finishManualAudio() }
        else { scheduleManualAudioStep() }
    }

    private func scheduleManualAudioStep() {
        guard let fade = manualFade, let began = fade.beganAt else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        let due = elapsed < 0.1 ? 0.1 : 0.2
        let generation = fadeGeneration
        fadeStepTask?.cancel()
        fadeStepTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, due - elapsed))) } catch { return }
            guard let self, self.fadeGeneration == generation, let fade = self.manualFade,
                  fade.pending == nil, let began = fade.beganAt, self.documentReady, self.isPlaying else { return }
            self.fadeStepTask = nil
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            let final = elapsed >= 0.195
            let target = fade.paused ? 0 : self.audioVolume
            let level = final ? target : AudioRamp(start: fade.start, target: target).value(at: elapsed)
            self.requestAudioStep(level: level, final: final)
        }
    }

    private func finishManualAudio() {
        guard let fade = manualFade else { return }
        let paused = fade.paused
        clearManualAudioFade()
        if paused { discardView() }
        else { appliedAudioPolicy = audioPolicyScript(enabled: audioEnabled, volume: audioVolume) }
    }

    private func manualAudioFailed() {
        // Native suspension/discard does not depend on a responsive provider SDK.
        fail("Não foi possível confirmar a transição do áudio web. O fundo foi pausado. Tente recarregar este fundo.")
    }
    private(set) var lastEvent = "loading"

    init(embed: WebEmbed, onError: @escaping @MainActor (String) -> Void, document: String? = nil) throws {
        try embed.validate()
        self.embed = embed
        self.onError = onError
        // Same registered identity as resources/Info.plist for swift run/tests.
        baseURL = URL(string: "https://" + (Bundle.main.bundleIdentifier ?? "dev.richas.wallmotion").lowercased())!
        self.document = document ?? Self.document(embed: embed, origin: baseURL.absoluteString)
        super.init()
        surface.wantsLayer = true
        surface.layer?.backgroundColor = NSColor.black.cgColor
    }

    func setPaused(_ paused: Bool) {
        guard !stopped, !failed else { return }
        if paused { discardView(); return }
        guard webView == nil else { return }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.isElementFullscreenEnabled = false
        let bridge = WebPlaybackBridge(owner: self)
        configuration.userContentController.add(bridge, name: "playback")
        self.bridge = bridge
        let view = WKWebView(frame: surface.bounds, configuration: configuration)
        view.autoresizingMask = [.width, .height]
        view.navigationDelegate = self
        webView = view
        surface.addSubview(view)
        lastEvent = "loading"
        awaitingDocument = true
        view.loadHTMLString(document, baseURL: baseURL)
        startupTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self else { return }
            self.fail("O embed não iniciou em 30 segundos (\(self.lastEvent)). Confira a rede ou tente outro vídeo público.")
        }
    }

    func stop() {
        stopped = true
        discardView()
    }

    private func discardView() {
        clearManualAudioFade()
        startupTimeout?.cancel()
        startupTimeout = nil
        isPlaying = false
        documentReady = false
        appliedAudioPolicy = nil
        guard let view = webView else { return }
        // Public WebKit APIs suspend media even if the provider SDK has failed.
        view.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        view.pauseAllMediaPlayback(completionHandler: nil)
        view.stopLoading()
        view.navigationDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "playback")
        bridge = nil
        view.loadHTMLString("", baseURL: nil)
        view.removeFromSuperview()
        webView = nil
    }

    fileprivate func received(_ message: WKScriptMessage) {
        guard message.webView === webView, message.frameInfo.isMainFrame,
              let value = message.body as? String else { return }
        if value.hasPrefix("ramp-ack:") || value.hasPrefix("ramp-fail:") {
            receiveAudioAcknowledgement(value);return
        }
        lastEvent = String(value.prefix(80))
        if value == "ready" {
            documentReady = true
            applyAudioPolicy()
            return
        }
        if value == "playing" {
            startupTimeout?.cancel()
            startupTimeout = nil
            isPlaying = true
            beginManualAudioIfReady()
            return
        }
        guard value.hasPrefix("error:") else { return }
        let code = String(decoding: value.dropFirst(6).utf8.prefix(96), as: UTF8.self)
        lastEvent = "error:" + WebPlaybackFailure.identifier(from: code)
        fail(WebPlaybackFailure.message(provider: embed.provider, code: code))
    }

    private func fail(_ message: String) {
        failed = true
        discardView()
        onError(message)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        guard webView === self.webView, (error as NSError).code != NSURLErrorCancelled else { return }
        fail(WebPlaybackFailure.navigationMessage(provider: embed.provider, error: error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        self.webView(webView, didFail: navigation, withError: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        fail("O processo WebKit foi encerrado. Tente recarregar o wallpaper.")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard webView === self.webView, let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        // No popups, external navigation or login flow. Only the local wrapper
        // may occupy the main frame; provider frames stay on official origins.
        if navigationAction.targetFrame?.isMainFrame == true {
            let isWrapper = url.absoluteString == "about:blank" ||
                (url.scheme == baseURL.scheme && url.host == baseURL.host && ["", "/"].contains(url.path) && url.query == nil)
            let allowed = awaitingDocument && navigationAction.navigationType == .other && isWrapper
            awaitingDocument = false
            decisionHandler(allowed ? .allow : .cancel)
        } else {
            let hosts = embed.provider == .youtube ? ["www.youtube.com", "www.youtube-nocookie.com"] : ["player.vimeo.com"]
            decisionHandler(navigationAction.targetFrame != nil && url.scheme == "https" && hosts.contains(url.host ?? "") ? .allow : .cancel)
        }
    }

    static func document(embed: WebEmbed, origin: String) -> String {
        // Values are validated ASCII identifiers; origin is the registered app ID.
        let common = """
        <!doctype html><html><head><meta name="referrer" content="strict-origin-when-cross-origin">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' https://www.youtube.com https://player.vimeo.com; frame-src https://www.youtube-nocookie.com https://www.youtube.com https://player.vimeo.com; style-src 'unsafe-inline'">
        <style>html,body{margin:0;width:100%;height:100%;background:black;overflow:hidden}iframe,#player{width:100%;height:100%;border:0}</style>
        </head><body><script>
        function report(value){window.webkit.messageHandlers.playback.postMessage(value)}
        var audioRampVersion=0,audioRampTimer=null;
        window.cancelAudioRamp=function(){
          audioRampVersion++;
          if(typeof audioVersion==="number")audioVersion++;
          if(audioRampTimer!==null){clearTimeout(audioRampTimer);audioRampTimer=null}
        };
        function rampAck(token,version,level,muted){
          if(version!==audioRampVersion)return;
          if(typeof level!=="number" || !Number.isFinite(level) || level<0 || level>1 || typeof muted!=="boolean"){
            report("ramp-fail:"+token);return
          }
          report("ramp-ack:"+token+":"+level.toFixed(4)+":"+(muted?"1":"0"))
        }
        function rampFail(token,version){if(version===audioRampVersion)report("ramp-fail:"+token)}
        </script>
        """
        if embed.provider == .youtube {
            let start = embed.startSeconds > 0 ? "&start=\(embed.startSeconds)" : ""
            return common + """
            <iframe id="player" src="https://www.youtube-nocookie.com/embed/\(embed.videoID)?enablejsapi=1&origin=\(origin)&playsinline=1&mute=1&loop=1&playlist=\(embed.videoID)\(start)" allow="autoplay" referrerpolicy="strict-origin-when-cross-origin"></iframe>
            <script>
            window.setAudioEnabled=function(enabled){if(window.player){if(enabled===true)player.unMute();else player.mute()}};
            function applyYouTubeAudio(enabled,volume){
              if(!window.player)return;
              var level=typeof volume==="number" && Number.isFinite(volume)?Math.max(0,Math.min(1,volume)):0;
              player.setVolume(Math.round(level*100));
              window.setAudioEnabled(enabled===true && level>0);
            }
            window.setAudioPolicy=function(enabled,volume){window.cancelAudioRamp();applyYouTubeAudio(enabled,volume)};
            window.requestAudioRampSnapshot=function(token){
              window.cancelAudioRamp();var version=audioRampVersion;
              try{rampAck(token,version,player.getVolume()/100,player.isMuted())}catch(e){rampFail(token,version)}
            };
            window.requestAudioRampStep=function(token,enabled,volume){
              window.cancelAudioRamp();var version=audioRampVersion;
              var level=typeof volume==="number" && Number.isFinite(volume)?Math.max(0,Math.min(1,volume)):0;
              var expected=Math.round(level*100),muted=enabled!==true || level===0;
              try{applyYouTubeAudio(enabled,level)}catch(e){rampFail(token,version);return}
              var attempts=0;
              function verify(){
                if(version!==audioRampVersion)return;
                try{
                  var actual=player.getVolume(),actualMuted=player.isMuted();
                  if(actual===expected && actualMuted===muted){rampAck(token,version,actual/100,actualMuted);return}
                  if(++attempts<7){audioRampTimer=setTimeout(verify,16)}else rampFail(token,version)
                }catch(e){rampFail(token,version)}
              }
              verify()
            };
            function onYouTubeIframeAPIReady(){report("sdk-ready");
              window.player=new YT.Player("player",{events:{
                onReady:function(e){e.target.mute();e.target.playVideo();report("ready")},
                onStateChange:function(e){report("state:"+e.data);if(e.data===1)report("playing")},
                onError:function(e){report("error:"+e.data)},
                onAutoplayBlocked:function(){report("error:autoplay-blocked")}
              }})
            }
            </script><script src="https://www.youtube.com/iframe_api" onerror="report('error:sdk-load')"></script></body></html>
            """
        }
        let hash = embed.privacyHash.map { "h=\($0)&" } ?? ""
        return common + """
        <iframe id="player" src="https://player.vimeo.com/video/\(embed.videoID)?\(hash)autoplay=1&muted=1&loop=1&autopause=0&dnt=1" allow="autoplay" referrerpolicy="strict-origin-when-cross-origin"></iframe>
        <script src="https://player.vimeo.com/api/player.js" onerror="report('error:sdk-load')"></script>
        <script>
        window.player=new Vimeo.Player(document.getElementById("player"));
        window.setAudioEnabled=function(enabled){player.setMuted(enabled!==true).catch(vimeoError)};
        var audioVersion=0,audioChain=Promise.resolve();
        function applyVimeoAudio(enabled,volume){
          var version=++audioVersion;
          var level=typeof volume==="number" && Number.isFinite(volume)?Math.max(0,Math.min(1,volume)):0;
          // Muting must not wait behind an unresolved gain change.
          if(enabled!==true || level===0)player.setMuted(true).catch(function(error){if(version===audioVersion)vimeoError(error)});
          audioChain=audioChain.catch(function(){}).then(function(){
            if(version!==audioVersion)return;
            return player.setMuted(true).then(function(){
              if(version!==audioVersion)return;
              return player.setVolume(level);
            }).then(function(){
              if(version!==audioVersion)return;
              return player.setMuted(enabled!==true || level===0);
            });
          }).catch(function(error){if(version===audioVersion)vimeoError(error)});
        };
        window.setAudioPolicy=function(enabled,volume){window.cancelAudioRamp();applyVimeoAudio(enabled,volume)};
        window.requestAudioRampSnapshot=function(token){
          window.cancelAudioRamp();var version=audioRampVersion;
          // A reversed transition must observe after the previous in-flight
          // setter settles; an old gain cannot overwrite a later confirmed step.
          audioChain=audioChain.catch(function(){}).then(function(){
            if(version!==audioRampVersion)return;
            return Promise.all([player.getVolume(),player.getMuted()])
          }).then(function(values){
            if(version!==audioRampVersion || !values)return;
            rampAck(token,version,values[0],values[1])
          }).catch(function(){rampFail(token,version)})
        };
        window.requestAudioRampStep=function(token,enabled,volume){
          window.cancelAudioRamp();var version=audioRampVersion;
          var level=typeof volume==="number" && Number.isFinite(volume)?Math.max(0,Math.min(1,volume)):0;
          var muted=enabled!==true || level===0;
          audioChain=audioChain.catch(function(){}).then(function(){
            if(version!==audioRampVersion)return;
            return player.setVolume(level)
          }).then(function(){
            if(version!==audioRampVersion)return;
            return player.setMuted(muted)
          }).then(function(){
            if(version!==audioRampVersion)return;
            return Promise.all([player.getVolume(),player.getMuted()])
          }).then(function(values){
            if(version!==audioRampVersion || !values)return;
            if(Math.abs(values[0]-level)>0.001 || values[1]!==muted){rampFail(token,version);return}
            rampAck(token,version,values[0],values[1])
          }).catch(function(){rampFail(token,version)})
        };
        player.on("playing",function(){report("playing")});
        function vimeoError(e){report("error:"+e.name+": "+(e.message||""))}
        player.on("error",vimeoError);
        player.ready().then(function(){return player.setMuted(true)}).then(function(){report("ready");return player.play()}).catch(vimeoError);
        </script></body></html>
        """
    }
}

@MainActor
private final class WebPlaybackBridge: NSObject, WKScriptMessageHandler {
    weak var owner: WebWallpaperRenderer?
    init(owner: WebWallpaperRenderer) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.received(message)
    }
}
