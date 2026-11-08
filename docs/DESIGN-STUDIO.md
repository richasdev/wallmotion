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
- Enabled shelf captions use measured adaptive ink (#B4B4B4 dark, #5F6368 light), checked against native compositor surfaces at 4.5:1 minimum. The capture requests sRGB at the own-window filter pixel scale/content rectangle, excludes shadows and uses best native resolution; antialiased glyph edges are not treated as solid text ink.
- Source gain in advanced controls follows the actual audio owner, even when another display is selected.
- Missing remote artwork says “Sem prévia”; no invented preview or additional playback instance.
- Empty collection offers import/link actions. Provider-controlled web framing is explained in place.
- No count, percentage or status is authored independently of the model.

## Direction and references

Applied skills: awesome-design (Notion reference: readable control spacing and native-sized typography), design, design-taste-frontend app-screens and motion-design. The revised taste draw selected **Framed sheet**, seed **1356117065**. Its floating two-panel variant follows the user's supplied reference: graphite navigation, a rounded native glass sheet and coral actions. The earlier true-black direction was rejected by the user. Native system text is deliberate for macOS legibility and settings compatibility.

The face is Wallmotion's monitor filled with coral/cyan/teal waves, with a matching coral action hue. The signature element is the selected monitor's actual cached still preview, directly beside framing and sound. At 880 pt the frame is 24 pt outer padding + 132 pt navigation + 12 pt gap + 712 pt glass sheet; its 36 pt inner padding leaves 676 pt. A 240 pt preview + 18 pt gap + at least 300 pt controls fit without hiding the first collection row. At 820 pt the sheet's inner area is 616 pt; controls can stack at larger accessibility text sizes. Names in navigation wrap; the horizontal monitor selector exposes the full name through help and accessibility.

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

The earlier compact release was functionally reviewed but did not match the user's visual reference. This revision changes the actual frame and hierarchy, not only a caption or accent. Bright coral (#FF735B) uses graphite labels, never white body text; the light selection ink is a darker coral and dark selection ink is light peach. Contrast and native compositor screenshots are validated on the final commit. The icon is a monitor with full-screen waves, not a letter.

Visual QA uses only private synthetic fixture media. Screenshots are evidence of the fixture layout and materials, not certification of HDR, VoiceOver or macOS 14 physical runtime. No web inspector applies to this native SwiftUI screen; the native AppKit/WindowServer capture replaces browser metrics. Performance constraints: no extra AVPlayer, network preview, frame polling, ambient animation or desktop screenshot loop.
