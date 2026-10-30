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

    func setAudioEnabled(_ enabled: Bool) {
        guard !stopped else { return }
        setAudioPolicy(enabled: enabled, volume: audioVolume)
    }

    func setAudioPolicy(enabled: Bool, volume: Double) {
        guard !stopped else { return }
        audioEnabled = enabled
        audioVolume = volume.isFinite ? min(1, max(0, volume)) : 0
        applyAudioPolicy()
    }

    private func applyAudioPolicy() {
        guard documentReady, let webView else { return }
        // Only bounded numbers and a Swift Bool enter JavaScript.
        let script = "window.setAudioPolicy(\(audioEnabled && audioVolume > 0 ? "true" : "false"),\(audioVolume))"
        guard script != appliedAudioPolicy else { return }
        appliedAudioPolicy = script
        webView.evaluateJavaScript(script, completionHandler: nil)
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
        </script>
        """
        if embed.provider == .youtube {
            let start = embed.startSeconds > 0 ? "&start=\(embed.startSeconds)" : ""
            return common + """
            <iframe id="player" src="https://www.youtube-nocookie.com/embed/\(embed.videoID)?enablejsapi=1&origin=\(origin)&playsinline=1&mute=1&loop=1&playlist=\(embed.videoID)\(start)" allow="autoplay" referrerpolicy="strict-origin-when-cross-origin"></iframe>
            <script>
            window.setAudioEnabled=function(enabled){if(window.player){if(enabled===true)player.unMute();else player.mute()}};
            window.setAudioPolicy=function(enabled,volume){
              if(!window.player)return;
              var level=typeof volume==="number" && Number.isFinite(volume)?Math.max(0,Math.min(1,volume)):0;
              player.setVolume(Math.round(level*100));
              window.setAudioEnabled(enabled===true && level>0);
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
        window.setAudioPolicy=function(enabled,volume){
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
