# Editing library titles

Use **Renomear…** in a card's context menu, or its named accessibility action. A native field provides Save/Cancel and Return/Escape actions, validates inline and focuses when opened. The card layout stays unchanged. Renaming/removing library entries remains available without a connected display; Apply still requires a selected monitor.

Only the existing entry's title changes. UUID, source path/URL, creation date, assignments, display mode, fit and audio/playback preferences remain unchanged. No physical file is renamed and no remote metadata is updated. The model does not rebuild the desktop when saving a title. Subsequent non-forced coordinator refreshes reuse the wallpaper ID/geometry/fit rather than its title. Search and sort projections observe the updated catalog; an active search can hide an item whose new title no longer matches.

New edits trim outer whitespace, require a nonempty single-line title and allow up to 200 grapheme characters. Control characters, line/paragraph separators and explicit directional embedding/override/isolate controls are rejected. Ordinary international text and emoji ZWJ sequences remain valid. A 4096 UTF-8 byte guard also bounds a single oversized combining grapheme before grapheme counting. Existing imported/legacy titles are not rewritten on load.

Saving uses the existing private atomic library writer. State is updated only after save succeeds; failures stay in the editor and preserve the old model title. Cancel does not call the model. Re-saving the same normalized title is a no-op. Missing entries and read-only/corrupt libraries cannot be edited.

## Verification

Core tests cover trimming, accents/Japanese/family emoji, empty/control/multiline/override rejection, the 200-character boundary and an oversized single combining grapheme. Model tests check that only the title differs after round-trip, search/sort memoization refreshes, invalid/missing edits preserve original JSON, and failed publication preserves the model and previous bytes. The corrupt-library fixture also rejects renaming.

An opt-in dark snapshot (`WALLMOTION_RENAME_SNAPSHOT_PATH`) exports the editor through the existing content-validated capture helper. The standalone editor has an explicit native window background so the QA PNG includes an opaque surface. The compact form was visually inspected. Full interactive VoiceOver and physical monitor playback remain separate QA; the snapshot alone does not certify accessibility.
