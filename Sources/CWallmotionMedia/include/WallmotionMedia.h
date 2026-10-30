#ifndef WALLMOTION_MEDIA_H
#define WALLMOTION_MEDIA_H
#include <stdint.h>
#include <stddef.h>

typedef struct {
    uint32_t width;
    uint32_t height;
    uint32_t frames;
    uint64_t decoded_bytes;
} WMGifInfo;

// 0 = parsed, 1 = invalid, 3 = structural work budget exceeded. No LZW decode.
// Caller owns the readable byte buffer and writable, aligned output for this call.
int32_t wm_gif_probe(const uint8_t *bytes, size_t len, WMGifInfo *out);
// All probes allow at most 1000000 main-block + subblock iterations (not a deadline).
// Same ownership contract. 2 = decoded budget exceeded, possibly before the
// remaining container has been validated. Output remains unchanged on failure.
int32_t wm_gif_probe_bounded(const uint8_t *bytes, size_t len, uint64_t max_decoded_bytes, WMGifInfo *out);
// descriptor must remain open during the call. The scanner duplicates it and
// leaves seek position unchanged. 0=success, 1=invalid/read, 2=decoded, 3=work.
int32_t wm_gif_probe_fd_bounded(int32_t descriptor, uint64_t max_decoded_bytes, WMGifInfo *out);

// Additive limits API: 4 = complete encoded input exceeds max_encoded_bytes.
// Existing symbols retain their previous signatures and no encoded-size limit.
// Same ownership/output contracts; all failures preserve output storage.
int32_t wm_gif_probe_limited(const uint8_t *bytes, size_t len, uint64_t max_decoded_bytes, uint64_t max_encoded_bytes, WMGifInfo *out);
int32_t wm_gif_probe_fd_limited(int32_t descriptor, uint64_t max_decoded_bytes, uint64_t max_encoded_bytes, WMGifInfo *out);
// Metadata-only regular-file check: 0=size allowed, 1=invalid/read, 4=encoded size.
// Does not validate GIF structure, read content, change offset or retain descriptor.
int32_t wm_gif_check_input_fd(int32_t descriptor, uint64_t max_encoded_bytes);

// Immutable animation ABI. The caller keeps bytes immutable/readable for decode.
// out must be aligned writable storage disjoint from input and handle storage.
// All status failures preserve output. 0=success, 1=invalid, 2=pixel budget,
// 3=structure work, 4=encoded budget, 5=frame count, 6=allocation/overflow,
// 7=ICC retention limit, 8=frame index. Limits do not promise process RSS/CPU.
typedef struct WMGifAnimation WMGifAnimation;
typedef struct {
    uint32_t width, height, frames;
    uint64_t decoded_bytes;
    uint16_t repeat_count;
    uint8_t repeat_infinite;
} WMGifAnimationInfo;
typedef struct {
    const uint8_t *pixels; // Borrowed row-major straight RGBA, width*4 stride.
    size_t length;
    uint16_t delay_centiseconds;
} WMGifFrameView;
typedef struct { const uint8_t *bytes; size_t length; } WMGifByteView;
int32_t wm_gif_animation_decode(const uint8_t *bytes, size_t len,
    uint64_t max_encoded, uint64_t max_decoded, uint64_t max_working,
    uint32_t max_frames, const WMGifAnimation **out);
// A successful decode yields one owned reference. retain adds one, release
// consumes one; null retain/release is allowed. Never release a borrowed pointer.
// Getters and retain require an already owned reference throughout the call;
// callers may read concurrently, but must not race their last release with use.
const WMGifAnimation *wm_gif_animation_retain(const WMGifAnimation *handle);
void wm_gif_animation_release(const WMGifAnimation *handle);
int32_t wm_gif_animation_info(const WMGifAnimation *handle, WMGifAnimationInfo *out);
// Borrowed views stay immutable/valid while any owned handle reference is alive.
int32_t wm_gif_animation_frame(const WMGifAnimation *handle, uint32_t index, WMGifFrameView *out);
int32_t wm_gif_animation_icc(const WMGifAnimation *handle, WMGifByteView *out);

#endif
