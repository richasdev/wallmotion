# Native scenario studio · 2026-11-08

The library answers: **what is applied to this screen, and how can I frame or silence it?**

## Delivery plan

- #166: show fit/fill/center/stretch, separate/mirror/panorama and one-click sound permission on the first screen. Preserve single audio ownership and commit-on-end volume drafts.
- #167: replace the decorative welcome hero with the actual applied item and a single native glass controls surface. Keep the media collection opaque and scrollable.
- #168: central, optically sized Wallmotion mark; reproducible app and menu icons.
- Manual host coverage remains tracked separately in #47 and #101. Infrastructure in #11 is not a product regression.

## Data and jobs

- Objects: imported photos/GIFs/videos and approved HTTPS video links; title, source, media kind and assignment.
- Typical library: zero to hundreds of items; filtering/sorting uses the existing catalog projection.
- Scope: one selected connected display, or the shared mirrored/panorama assignment.
- Routine jobs: apply media, frame it, permit/silence audio, change volume, pause playback.
- The applied library item's thumbnail and title identify the current scenario; they are real state, not decorative sample data.
- Audio ownership is a permission, not a claim that a stream is audible. Disconnected owner, zero gain and paused playback get explicit copy.
- Enabled sheet captions use measured adaptive ink (#C8CACC dark, #505459 light), checked against native compositor surfaces at 4.5:1 minimum. The capture requests sRGB at the own-window filter pixel scale/content rectangle, excludes shadows and uses best native resolution; antialiased glyph edges are not treated as solid text ink.
- Source gain in advanced controls follows the actual audio owner, even when another display is selected.
- Missing remote artwork says “Sem prévia”; no invented preview or additional playback instance.
- Empty collection offers import/link actions. Provider-controlled web framing is explained in place.
- No count, percentage or status is authored independently of the model.

## Direction and references

Applied skills: awesome-design (Notion reference: readable control spacing and native-sized typography), design, design-taste-frontend app-screens and motion-design. The revised taste draw selected **Framed sheet**, seed **1356117065**. Its floating two-panel variant follows the user's supplied reference: graphite navigation, a rounded native glass sheet and coral actions. The earlier true-black direction was rejected by the user. Native system text is deliberate for macOS legibility and settings compatibility.

The face is Wallmotion's monitor filled with coral/cyan/teal waves, with a matching coral action hue. The signature element is the selected monitor's actual cached still preview, directly beside framing and sound. At 880 pt the frame is 24 pt outer padding + 132 pt navigation + 12 pt gap + 712 pt glass sheet; its 36 pt inner padding leaves 676 pt. A 240 pt preview + 18 pt gap + at least 300 pt controls fit with the first collection row and its Apply actions visible at the default height. At 820 pt the sheet's inner area is 616 pt; controls can stack at larger accessibility text sizes. Names in navigation wrap; the horizontal monitor selector exposes the full name through help and accessibility.

The user's explicit reference and native glass request override taste's generic no-glass/no-dark-sidebar rules and restrained color budget. One `.glassEffect(.regular)` sheet is used on macOS 26+, backed by a native `NSVisualEffectView` with `.behindWindow` blending. The library window is transparent; the previous opaque detail background was removed because it hid the material. macOS 14–15 use system material. Reduced transparency/increased contrast select opaque backgrounds for both sheet and gutters, with stronger outlines. There is no glass per media card.

The top-level display-mode control names Separate/Mirror/Panorama. A visible shared-mode message warns that changes affect every display; “Controlar separadamente” explicitly restores independent assignments. Selected-monitor sound offers an atomic handoff, while “Pausar tudo” and “Retomar tudo” explicitly name the global pause scope. Search, import, URL review, rename, removal, errors and advanced quality remain available. Header/preview state comes only from the model; missing URL artwork is never replaced by a fake landscape.

Motion is native interaction feedback only. No ambient animation, refresh timer or live preview player is added. Existing thumbnail scheduling/cache limits and volume debounce remain intact. Native rendering stays in AVFoundation/AppKit; this UI change does not need an additional Rust bridge.

Primary API evidence: Apple's [Liquid Glass guidance](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass) and [custom view API](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views), cross-checked against Xcode 27 SwiftUICore interfaces (`glassEffect` availability macOS 26.0). Older-system runtime behavior requires a physical older macOS host; the deployment target remains 14. For compositor QA, the opt-in fixture captures only its own on-screen test window through `SCShareableContent.currentProcess` and `SCScreenshotManager` on macOS 14.4+. It never enumerates unrestricted windows or requests/changes TCC permissions. The QA window appearance must match its host appearance; native glass uses the window appearance. Offscreen `cacheDisplay` cannot certify backdrop optics.

## Review policy for this batch

The user's 2026-11-08 request explicitly restores multiple Codex agents plus one AGY and one Claude Code, superseding the historical two-agent count. Implementation uses isolated worktrees. Each PR is reviewed on its exact HEAD by at least three non-author agents, with explicit findings, checks, limitations and verdict. AGY is the designated merger and must use `--match-head-commit`; no direct main pushes, admin bypass or self-approval. Same-account agent verdicts are evidence of separate agents, not separate GitHub-account approvals.


## Compact-window refinement · issue #176

The user's supplied reference adds a compact ordinary-window requirement: 880×620 pt by default, retaining the 820×560 accessible minimum. The reference informs the narrow navigation, rounded floating control grouping and calm hierarchy; its health dashboard content is not copied. Monitors and framing sit in adjacent fields when space allows, sound and details share a footer, and the first gallery row exposes title and Apply. Power rules move to a named sidebar disclosure. Native glass and measured caption contrast remain.

A small native AppKit startup adapter disables restoration and normalizes the initial window on every supported macOS version, including a one-time exit from legacy restored fullscreen. It preserves later manual resizing/fullscreen and never changes global preferences. The app remains resizable.

## Reference correction · issues #179 / #180 / #181

The earlier compact release was functionally reviewed but did not match the user's visual reference. This revision changes the actual frame and hierarchy, not only a caption or accent. Bright coral (#FF735B) uses graphite labels, never white body text; the light selection ink is a darker coral and dark selection ink is light peach #FFC4B5. Contrast and native compositor screenshots are validated on the final commit. The icon is a monitor with full-screen waves, not a letter.

Visual QA uses only private synthetic fixture media. Screenshots are evidence of the fixture layout and materials, not certification of HDR, VoiceOver or macOS 14 physical runtime. No web inspector applies to this native SwiftUI screen; the native AppKit/WindowServer capture replaces browser metrics. Performance constraints: no extra AVPlayer, network preview, frame polling, ambient animation or desktop screenshot loop.

Final look round: the native light capture uses caption ink #505459 on #E9E9E9; dark uses #C8CACC on #4A4A4A. Coral action #FF735B with graphite #2F3334 is 4.78:1. The primary action and sidebar face carry the reference's color; no system accent hue leaks into links. The 880×620 capture exposes all three first-row Apply actions. At 820×560 with shared-mode scope messaging the collection scrolls; key monitor, framing, sound and separation controls stay above it. Large text swaps the four framing buttons for an accessible menu. ⌘F explicitly focuses the search, and ⌘O remains the import command. The large image is labelled “Miniatura da mídia”: it identifies the source, while fit/center/stretch are applied to the desktop, avoiding a false promise of a live framing preview.

Native screenshot critique: the reference's two floating panels, dark navigation, light rounded sheet, coral actions and compact hierarchy are present. Readability and visible control scope improved; missing URL artwork remains deliberately neutral. The dark variant follows the system appearance instead of forcing a light workspace. The native scrollbar follows host preferences. There is still a scroll tradeoff at the minimum height/shared mode; HDR and assistive-technology certification remain tracked separately.

Independent review correction: Claude Code measured the selected dark label on its coral-tinted glass surface at 4.17:1 (not the neutral sheet). Selection ink is now #FFC4B5, with a regression test against the measured #604F4C background (5.08:1). The backdrop follows the window's active state; no energy reduction is claimed without measurement. Fit glyphs share a fixed 20 pt icon slot, the thumbnail badge uses scalable caption2, and Find is disabled when no search field exists. GitHub Actions and the macOS checks workflow were explicitly disabled by the user; validation is local only and must not re-enable or dispatch Actions.

## Continuous frosted window · issue #183

The user's actual titlebar crop revealed a gap in the borderless QA fixture: three different silhouettes were visible (a rectangular native backdrop, a rounded sidebar and a separately rounded glass sheet). The studio now uses a single continuous native window contour. The 12 pt outer gap/insets and the two panel radii are removed; native AppKit owns the outer corners. The foreground respects the window safe area, while only the material background extends through the titlebar. Native traffic lights remain untouched.

ScenarioSurface owns one continuous native behind-window material, or one opaque window background for Reduce Transparency/Increase Contrast. Liquid Glass regular is scoped to the actual framing controls on macOS 26+, following Apple’s separation between content and controls; no full-window glass is stacked over the native backdrop. A steady neutral scrim gives the frosted finish and a readable ground; it adds no custom filters, images, timers or extra players. Only increased contrast receives an explicit outer outline. Media cards use a translucent neutral fill over the shell, with a contour only for selection. See [Apple behind-window blending](https://developer.apple.com/documentation/appkit/nsvisualeffectview/blendingmode-swift.enum/behindwindow) and [Build an AppKit app with the new design](https://developer.apple.com/videos/play/wwdc2025/310/).

Native QA opts into a titled/closable/miniaturizable/resizable/fullSizeContentView test window at 880×620 and 820×560, with hidden transparent titlebar and all three actual native buttons asserted visible. Current-process ScreenCaptureKit captures include the real window chrome. This is independent product QA, not capture of the installed app: Orca Computer Use was denied Accessibility permission, so no permission was changed and no attempt was made to access that denied process through another route. Optional active-fixture QA attempts to activate only its own test window and skips unless NSApp.isActive and window.isKeyWindow are both true; it restores the preceding app only if focus has not been changed by the user. This test host could not activate, so compositor evidence covers inactive native windows; active-material and real accessibility-preference certification remain pending.

## Per-monitor automatic resource saving · issue #184

“Pausar com outros apps visíveis” is an opt-in preference in Desempenho and the menu-bar menu. The selected monitor reports its own pause reason, its selector shows a pause symbol, and the sound caption explains when the permitted audio owner is temporarily paused. This feature does not change manual pause or move the sound owner.

Only normal, on-screen, positive-alpha windows from another PID with regular app activation policy intersecting a connected display count. Accessory/menu-bar helpers, prohibited and unknown/terminated owners are excluded: window alpha does not indicate whether its contents are transparent. This prevents invisible helper overlays from pausing a display indefinitely (issue #186). As a deliberate tradeoff, settings windows belonging to menu-bar-only apps do not pause the wallpaper. Each eligible query takes a fresh PID-only snapshot of regular running apps; an empty snapshot skips the WindowServer call. No process names are read. Desktop/Dock/menu layers and Wallmotion itself do not. Window geometry uses CGDisplayBounds and CGWindowBounds in the same upper-left coordinate system, including displays with negative origins; no pixel-scale multiplication is applied. The app requests no capture or Accessibility permission and reads no window titles or owner names. Apple's [window-metadata security guidance](https://developer.apple.com/videos/play/wwdc2019/701/) and [CGWindowListCopyWindowInfo](https://developer.apple.com/documentation/coregraphics/cgwindowlistcopywindowinfo(_:_:)) document the metadata API; no permission is inferred from missing optional keys.

Workspace events are coalesced at 100 ms. A single utility-actor metadata query is allowed at a time; a 2-second timer with 0.5-second tolerance covers minimization and moves that do not emit workspace events. No observation or timer runs when the setting is off, there is no assigned connected screen, the app is asleep, or manual/energy/memory policy already pauses everything. A missing query result clears only this optional reason. All event resources stop with the model, and cancelled queued queries do not touch WindowServer. The timer is a deliberate, low-frequency tradeoff; arbitrary cross-process moves/minimization do not offer a permission-free per-window notification API.

Independent video/GIF retains its frame. When a shared video is still required by an uncovered display, its occupied display window is hidden to avoid composing another animated layer; that display can reveal the macOS background around the other app. The shared transport and HDR path continue for the free display, with no captured/copied freeze frame. Audio permission remains with its original monitor, silent while that monitor is paused and restored when it becomes available. No measured CPU/GPU/energy reduction or every provider's autoplay behavior is claimed; physical HDR and accessibility QA remain tracked separately.
