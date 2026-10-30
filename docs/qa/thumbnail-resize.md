# Thumbnail stability while resizing

Library cards are still laid out at their actual size. Only the target bitmap dimensions used by task identity, scheduler and cache are rounded **up** to multiples of 32 physical pixels, after the existing finite-value and 4096-pixel checks. This avoids a new task identity for each physical pixel of width change and never requests fewer pixels than the bounded geometry. It adds at most 31 target pixels on each axis. Image/video aspect-fill preparation and orientation handling remain unchanged; the existing 8 MiB bitmap budget can still limit source detail. No unconstrained Retina quality guarantee is made.

When a card changes size, it keeps its prepared image while waiting for the new one or if that resize fails. Changing URL, media kind, or switching to a remote card clears the old image immediately. A completion must match the latest request before publication, and cancelled tasks cannot start a new presentation or publish late decoder output. Cache identity includes media kind as well as path and bucket dimensions.

There is no debounce timer. Resizing across a bucket boundary can still start work, and crossing a grid-column boundary can change many cards. The shared scheduler still limits actual in-progress operations to four and retains slots for cancelled operations until they return. The 32 MiB NSCache limit is advisory; retaining the previous image while preparing a replacement temporarily adds another reference/bitmap and is not a total-RSS limit.

## Verification

A controlled geometry sweep from 200 through 520 points in 0.5-point increments at 2× scale and the current 118-point card height produces **641 distinct raw sizes versus 21 bucketed sizes**. This is a deterministic key-count comparison, not a measured reduction in CPU, decode latency, energy, GPU work or WindowServer composition.

Tests cover upward rounding, dimension caps, idempotence, nonfinite geometry and scales 1/1.5/2/3. Presentation tests cover keeping the old image during a resize, publishing its replacement, rejecting obsolete completion, and clearing a reused card on source/kind/remote changes. Physical live-resize cadence, visual sharpness, cache residency, large libraries and energy still require interactive measurement under #63/#77.
