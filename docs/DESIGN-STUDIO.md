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
- Source gain in advanced controls follows the actual audio owner, even when another display is selected.
- Missing remote artwork says “Sem prévia”; no invented preview or additional playback instance.
- Empty collection offers import/link actions. Provider-controlled web framing is explained in place.
- No count, percentage or status is authored independently of the model.

## Direction and references

Applied skills: awesome-design (Notion reference: readable control spacing and native-sized typography), design, design-taste-frontend app-screens and motion-design. The taste draw selected **True-black flat**, seed **2028286329**; its neutral media-first hierarchy is adapted to semantic macOS light/dark surfaces. Native system text is deliberate for macOS legibility and settings compatibility.

The face is Wallmotion's central W/horizon mark and teal selection. The signature element is the applied scenario with persistent framing and sound controls. At 1120 pt: sidebar ~240 + gutters 48 + canvas ~832; collection uses three adaptive columns (~266 each) and two 16 pt gaps. At minimum 820 pt it reduces to two columns and uses the existing scroll containers. Controls wrap rather than clip.

The user's explicit native glass request overrides taste's generic no-glass rule. One `.glassEffect(.regular)` surface is limited to the control shelf on macOS 26+. macOS 14–15 uses system material. Reduced transparency or increased contrast chooses an opaque system surface; high contrast adds an outline. The collection and thumbnails have no glass effects. Standard sidebar and toolbar keep their system behavior.

Motion is native interaction feedback only. No ambient animation, refresh timer or live preview player is added. Existing thumbnail scheduling/cache limits and volume debounce remain intact. Native rendering stays in AVFoundation/AppKit; this UI change does not need an additional Rust bridge.

Primary API evidence: Apple's [Liquid Glass guidance](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass) and [custom view API](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views), cross-checked against Xcode 27 SwiftUICore interfaces (`glassEffect` availability macOS 26.0). Older-system runtime behavior requires a physical older macOS host; the deployment target remains 14. For compositor QA, the opt-in fixture captures only its own on-screen test window through `SCShareableContent.currentProcess` and `SCScreenshotManager` on macOS 14.4+. It never enumerates unrestricted windows or requests/changes TCC permissions. The QA window appearance must match its host appearance; native glass uses the window appearance. Offscreen `cacheDisplay` cannot certify backdrop optics.

## Review policy for this batch

The user's 2026-11-08 request explicitly restores multiple Codex agents plus one AGY and one Claude Code, superseding the historical two-agent count. Implementation uses isolated worktrees. Each PR is reviewed on its exact HEAD by at least three non-author agents, with explicit findings, checks, limitations and verdict. AGY is the designated merger and must use `--match-head-commit`; no direct main pushes, admin bypass or self-approval. Same-account agent verdicts are evidence of separate agents, not separate GitHub-account approvals.
