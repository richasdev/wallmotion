# Display controls manual acceptance

Use this checklist with at least two connected displays. Record the macOS version, display arrangement, and whether each scenario was exercised on physical hardware or in a virtual display setup. Do not describe simulator-only checks as physical display QA.

## Assignment modes

- [ ] Choose one wallpaper and select **Same background on every display**. Confirm the same wallpaper appears on each connected display.
- [ ] Disconnect one display while mirrored mode is active. Confirm the remaining display continues showing the wallpaper; reconnect the display and confirm it joins the mirrored presentation.
- [ ] Switch to **Separate backgrounds**. Confirm each display returns to its prior wallpaper choice instead of inheriting the mirrored choice.
- [ ] Choose different wallpapers per display, switch to mirrored mode, then return to separate mode again. Confirm the independent choices remain intact.
- [ ] Clear a wallpaper from one display in separate mode. Confirm only that display is cleared. In mirrored mode, verify the clear action and resulting selection are consistent across all connected displays.

## Media fit and display quality

For each mode, use both landscape and portrait media and inspect on a Retina display at its native resolution:

- [ ] **Fit** shows the full image with letterboxing where needed.
- [ ] **Fill** covers the display and crops the excess without distorting the image.
- [ ] **Center** shows the media at its natural pixel size centered in the display.
- [ ] **Stretch** fills the display dimensions, including aspect-ratio distortion where applicable.
- [ ] Change a display's scaling/resolution and confirm the image remains stable, sharp, and correctly placed.

## Audio and playback

- [ ] New/default settings have audio off. Verify no display begins playing audible media until an audio display is chosen.
- [ ] Choose one monitor for audio. Confirm sound is heard from that display's wallpaper only, and other displays remain muted.
- [ ] Cover or obscure the chosen display using the supported covered-display behavior. Confirm playback/audio follows the product's pause policy and resumes appropriately when uncovered.
- [ ] Disconnect the selected audio display. Confirm no other display unexpectedly becomes audible; reconnect it and confirm the selected-monitor behavior recovers as designed.
- [ ] With multiple wallpapers playing, pause and resume playback and verify the selected audio output and mute state remain correct.

## Web media provider limits

- [ ] Test a supported web wallpaper and confirm the UI communicates provider autoplay or audio restrictions when playback is blocked.
- [ ] Verify autoplay behavior with audio disabled and with a user-selected audio display. Confirm browser/provider policies are respected and controls do not imply guaranteed autoplay with sound.
- [ ] Test a provider page that requires user interaction and record the observed limitation; do not treat a blocked autoplay as a display assignment failure.

## Results

For each unchecked or failed item, record the display IDs/order, wallpaper type, reproduction steps, expected behavior, and observed behavior. Attach screenshots or a short recording when useful, while noting whether the capture came from physical monitors or virtual displays.
