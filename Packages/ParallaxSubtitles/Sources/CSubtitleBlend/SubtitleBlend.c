#include "include/CSubtitleBlend.h"

#include <stdlib.h>
#include <string.h>

/*
 * Colour space note: ASS_Image.color carries plain RGB with no colour space of
 * its own. libass deliberately declines to define an HDR mapping and says all
 * subtitles are to be treated as SDR (see the ASS_YCbCrMatrix comment in
 * ass_types.h), so we hand these bytes on as sRGB / BT.709 primaries and let
 * the compositor deal with the video's own space. This is the same choice mpv
 * and VLC make.
 */

/*
 * v / 255 without a divide. Truncating, and exact against integer division for
 * every value 0...65534 — which covers this file, whose largest product is
 * 255 * 255. Not round-to-nearest: the error is at most 1/255 on antialiased
 * edge pixels only, and it never pushes a channel above its alpha.
 */
static inline uint32_t div255(uint32_t v) {
    return (v + 1 + (v >> 8)) >> 8;
}

static inline uint8_t clamp_byte(uint32_t v) {
    return v > 255u ? 255u : (uint8_t)v;
}

/* An image contributes nothing if it has no area, no bitmap, or is fully see-through. */
static inline bool image_is_visible(const ASS_Image *img) {
    return img->w > 0 && img->h > 0 && img->bitmap != NULL && (img->color & 0xFFu) != 0xFFu;
}

SubtitleBlendResult subtitle_blend_images(const ASS_Image *head) {
    SubtitleBlendResult out;
    memset(&out, 0, sizeof(out));
    out.is_empty = true;

    int32_t min_x = INT32_MAX, min_y = INT32_MAX;
    int32_t max_x = INT32_MIN, max_y = INT32_MIN;

    for (const ASS_Image *img = head; img != NULL; img = img->next) {
        if (!image_is_visible(img)) {
            continue;
        }
        if (img->dst_x < min_x) { min_x = img->dst_x; }
        if (img->dst_y < min_y) { min_y = img->dst_y; }
        if (img->dst_x + img->w > max_x) { max_x = img->dst_x + img->w; }
        if (img->dst_y + img->h > max_y) { max_y = img->dst_y + img->h; }
    }

    if (min_x >= max_x || min_y >= max_y) {
        return out;
    }

    /* Deltas in a wider type: dst_x/dst_y come from libass off untrusted
     * scripts, and a signed int32 subtraction near the limits is undefined
     * before the cast. Anything wider than int32 is not a drawable frame. */
    const int64_t wide_width = (int64_t)max_x - (int64_t)min_x;
    const int64_t wide_height = (int64_t)max_y - (int64_t)min_y;
    if (wide_width > INT32_MAX || wide_height > INT32_MAX) {
        return out;
    }

    const size_t width = (size_t)wide_width;
    const size_t height = (size_t)wide_height;
    const size_t bytes_per_row = width * 4;
    const size_t byte_count = bytes_per_row * height;

    uint8_t *pixels = calloc(byte_count, 1);
    if (pixels == NULL) {
        return out;
    }

    for (const ASS_Image *img = head; img != NULL; img = img->next) {
        if (!image_is_visible(img)) {
            continue;
        }

        /*
         * color is packed RGBA, but the A byte is TRANSPARENCY: 0 means fully
         * opaque. Getting this backwards makes every subtitle invisible.
         */
        const uint32_t opacity = 255u - (img->color & 0xFFu);
        const uint32_t src_r = (img->color >> 24) & 0xFFu;
        const uint32_t src_g = (img->color >> 16) & 0xFFu;
        const uint32_t src_b = (img->color >> 8) & 0xFFu;

        const size_t dst_col = (size_t)(img->dst_x - min_x);
        const size_t dst_row = (size_t)(img->dst_y - min_y);

        for (int32_t y = 0; y < img->h; y++) {
            /* The final row may stop at `w` bytes, so never read past it. */
            const unsigned char *src_line = img->bitmap + (size_t)y * (size_t)img->stride;
            uint8_t *dst_line = pixels + (dst_row + (size_t)y) * bytes_per_row + dst_col * 4;

            for (int32_t x = 0; x < img->w; x++) {
                const uint32_t coverage = src_line[x];
                if (coverage == 0) {
                    continue;
                }
                const uint32_t alpha = div255(coverage * opacity);
                if (alpha == 0) {
                    continue;
                }

                uint8_t *dst = dst_line + (size_t)x * 4;
                const uint32_t inv = 255u - alpha;
                /* Source over destination, both premultiplied, BGRA in memory. */
                dst[0] = clamp_byte(div255(src_b * alpha) + div255(dst[0] * inv));
                dst[1] = clamp_byte(div255(src_g * alpha) + div255(dst[1] * inv));
                dst[2] = clamp_byte(div255(src_r * alpha) + div255(dst[2] * inv));
                dst[3] = clamp_byte(alpha + div255(dst[3] * inv));
            }
        }
    }

    out.pixels = pixels;
    out.bytes_per_row = bytes_per_row;
    out.byte_count = byte_count;
    out.x = min_x;
    out.y = min_y;
    out.width = (int32_t)width;
    out.height = (int32_t)height;
    out.is_empty = false;
    return out;
}
