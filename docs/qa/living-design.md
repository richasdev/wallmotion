# Living library visual direction

Issue: #140

The library now uses an original static vector landscape, a deep blue/teal/coral hero,
larger edge-to-edge thumbnails, explicit applied badges, and a more expressive empty
state. Light mode keeps native text and control surfaces. The decorative hero uses its
own dark surface in both appearances. The sidebar keeps native controls and accessible
monitor selection. Monitor organization, framing, HLS and audio remain available in
“Ajustar cenário”; they start collapsed to give the collection more room.

Missing thumbnails use decorative scenery with an explicit “Sem prévia” label. This is
not a representation of the source video. No network artwork or user media is needed.

## Cost and behavior

LivingArtwork draws five fixed filled paths, a circle and gradients. It has no timer,
TimelineView, repeating animation, blur or media player. Resize uses the existing bounded
thumbnail scheduler and pixel buckets. This change does not change wallpaper decoding,
playback, persistence or image quality. It adds no dependencies. There is no new motion
to suppress for Reduce Motion. Physical CPU/GPU, VoiceOver and display contrast checks
remain part of issues #8 and #47; source inspection is not an energy measurement or an
accessibility certification.

## Validation

Run `sh scripts/check.sh` for the existing Rust, Python and Swift checks. Native component
captures can be generated with the existing temporary-library fixture:

```sh
WALLMOTION_SNAPSHOT_PATH=/tmp/wallmotion-design-dark.png swift test -j 2 --filter testOptionalLibraryViewSnapshotUsesOnlyTemporaryFixtures
WALLMOTION_SNAPSHOT_LIGHT=1 WALLMOTION_SNAPSHOT_PATH=/tmp/wallmotion-design-light.png swift test -j 2 --filter testOptionalLibraryViewSnapshotUsesOnlyTemporaryFixtures
WALLMOTION_SNAPSHOT_COMPACT=1 WALLMOTION_SNAPSHOT_PATH=/tmp/wallmotion-design-compact.png swift test -j 2 --filter testOptionalLibraryViewSnapshotUsesOnlyTemporaryFixtures
WALLMOTION_SNAPSHOT_SCENE_CONTROLS=1 WALLMOTION_SNAPSHOT_PATH=/tmp/wallmotion-design-controls.png swift test -j 2 --filter testOptionalLibraryViewSnapshotUsesOnlyTemporaryFixtures
WALLMOTION_SEARCH_SNAPSHOT_DIR=/tmp/wallmotion-design-states swift test -j 2 --filter testOptionalNoticeSnapshotsIncludeEmptyLibraryAndNoMatchingItems
```

Fixtures use private temporary libraries and synthetic displays with no playback targets.
Captures are offscreen NSHostingView renderings, not proof of physical screen or mouse
interaction. Inspect normal, compact, expanded-controls, empty and no-results states.
