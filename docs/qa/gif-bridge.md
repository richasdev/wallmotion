# Immutable GIF bridge and image ownership

Issue #145, part of #14. This connects the bounded Rust decoder to Swift/CoreGraphics.
It does not switch the running wallpaper renderer, read files, create a shared cache,
choose playback timing, or claim measured CPU/RSS savings. Those are #146 and #147.

## ABI ownership

`WMGifAnimation` is opaque and immutable. A successful decode publishes one reference;
`retain` adds one and `release` consumes exactly one. Null retain/release are allowed.
A caller must already own a live reference throughout each getter/retain and every
borrowed-byte use. Final release must not race an unprotected getter or retain. Raw
pointers cannot validate arbitrary C use-after-free, double release or misalignment;
these remain explicit unsafe caller contracts in the header and Rust safety comments.
Output storage must be aligned, writable and disjoint from immutable input/handles.

Decode takes a borrowed immutable byte slice plus explicit encoded, decoded, working
and frame-count limits. Failure leaves the output unchanged. Read-only metadata,
frame and ICC getters have the same failure-storage guarantee. Pixels are contiguous
straight RGBA with width*4 stride; profile absence is null/zero. Status codes 0...8
are documented in the header. Existing probe symbols and statuses remain unchanged.

Native references use [Rust Arc raw APIs](https://doc.rust-lang.org/std/sync/struct.Arc.html).
The shared object contains no mutable codec or playback state. Small owner/reference
allocations, codec internals and CoreGraphics allocations are outside the decoder's
pixel-payload budget; this is not a global OOM/RSS guarantee.

## Swift images

GIFAnimation synchronously decodes Data and owns one native reference. Preparation
must later schedule this work off the main actor. Its unchecked Sendable conformance
relies on immutable Swift fields, immutable native storage and atomic ownership.
Methods hold self alive through native borrows. Each CGDataProvider gets an additional
native reference and releases it from its releaseData callback, independently of the
Swift factory object. A CGImage may therefore outlive that factory. The provider is
built directly over the frame pointer; the wrapper does not copy RGBA pixels.
CoreGraphics may internally copy/cache/convert pixels when rendering.

The [provider contract](https://developer.apple.com/documentation/coregraphics/cgdataprovider/init(datainfo:data:size:releasedata:))
requires stable data until provider release. Failed provider creation releases the
reference that was not transferred; failed image creation lets its local provider
release normally. Out-of-range indices fail before native access. Native errors are
reported explicitly. No display, timer, media player or user-library mutation occurs.

A bounded ICC profile is copied as metadata into a CoreGraphics RGB color space; invalid
or non-RGB profiles fail instead of silently substituting another space. No profile
uses sRGB. The image carries that source space and straight-alpha RGBA ordering, so a
consumer can render it into its desired destination space.

## Verification

Rust tests use Weak to verify pixels survive the first release and the object is gone
after the final balanced release. Four threads repeatedly retain/read/release the
same pixel addresses. Nulls, invalid indices and decode-budget rejection preserve
output sentinels. Swift tests retain two distinct frame images after the original
factory deinitializes, verify raw provider bytes and a real CGContext draw, validate
ICC/index/budget paths, and create 320 images concurrently from one immutable animation.
An offscreen AppKit ImageSurface test paints a native frame after its factory is gone;
it does not install a desktop window or touch a real library. This verifies the image
path, not physical multi-monitor playback or a general leak certification.

Run `sh scripts/check.sh` and `sh scripts/build-app.sh`.
