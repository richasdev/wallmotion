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

#endif
