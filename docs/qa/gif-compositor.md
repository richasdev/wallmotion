# Transactional GIF composition

Issue #139 is the first rendering-independent step toward #14, shared GIF decoding.
The current AppKit renderer still decodes GIFs separately. This module does not claim
runtime memory savings or change the existing per-view/global GIF admission budgets.

`wallmotion_media::compositor` accepts already decoded, deinterlaced, row-major indices,
a bounded effective RGB palette and an in-canvas rectangle. Opaque colors produce
straight RGBA with alpha 255; transparent indices preserve destination pixels. The
explicit background may be transparent or any other RGBA color. The caller chooses
premultiplication or surface conversion later.

Keep retains the last canvas; Background restores only the last frame rectangle;
Previous saves and restores only that rectangle. Disposal applies before the next valid
frame. Rejected geometry, buffer lengths, palettes, non-transparent palette indices,
overflow, payload budgets and fallible allocations leave visible pixels and pending
disposal intact. A transparent index requires no palette lookup and may be outside it.

The maximum counts requested pixel payload owned by the compositor, including canvas,
old Previous backup and new Previous backup at peak transition. It excludes allocator
metadata/rounding and caller buffers; it is not a process RSS bound. Allocation uses
try_reserve_exact before mutation. Pixels are exposed as an immutable borrowed slice;
Rust borrowing prevents mutation while that slice is live, but does not create a shared
animation cache, FFI lifetime or playback synchronization policy.

## Verification

Golden 2×2 and 3×2 sequences cover partial overlays, transparent pixels, explicit RGBA
background, repeated overlapping Previous, non-square row stride, nonzero offsets,
invalid-frame rollback with pending disposal and exact peak-budget boundaries.
Additional cases reject palette257, zero dimensions, overflowing coordinates and wrong
buffer lengths. No decoder dependency, unsafe code, file I/O, timer, delay normalization,
FFI or Swift integration is introduced here. Run `sh scripts/check.sh`.

The GIF89a disposal definitions are described in the [official specification](https://www.w3.org/Graphics/GIF/spec-gif89a.txt).
