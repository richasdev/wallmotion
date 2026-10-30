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

// 0 = structural GIF metadata parsed, 1 = invalid input. Does not decode LZW.
// Caller owns the readable byte buffer and writable, aligned output for this call.
int32_t wm_gif_probe(const uint8_t *bytes, size_t len, WMGifInfo *out);
// Same ownership contract. 2 = decoded budget exceeded, possibly before the
// remaining container has been validated. Output remains unchanged on failure.
int32_t wm_gif_probe_bounded(const uint8_t *bytes, size_t len, uint64_t max_decoded_bytes, WMGifInfo *out);
#endif
