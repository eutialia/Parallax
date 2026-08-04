/*
 * Flattens the linked list of coverage bitmaps libass hands back for one frame
 * into a single premultiplied BGRA buffer, so the Swift side can wrap it in one
 * CGImage instead of hundreds.
 */

#ifndef C_SUBTITLE_BLEND_H
#define C_SUBTITLE_BLEND_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <Libass/ass/ass.h>

/*
 * The blended frame.
 *
 * `pixels` is premultiplied BGRA in memory order (B first), which pairs with
 * CGImage's kCGImageAlphaPremultipliedFirst + byteOrder32Little. Ownership
 * transfers to the caller: release it with free(). When `is_empty` is true the
 * frame drew nothing and `pixels` is NULL.
 *
 * `x`/`y` are the top-left corner of the blended rect inside the render frame
 * libass was configured with (ass_set_frame_size), in pixels, y growing down.
 */
typedef struct {
    uint8_t *pixels;
    size_t bytes_per_row;
    size_t byte_count;
    int32_t x;
    int32_t y;
    int32_t width;
    int32_t height;
    bool is_empty;
} SubtitleBlendResult;

/*
 * Composites every image in the list, in order, into one buffer sized to their
 * union bounding box. Passing NULL yields the empty result.
 */
SubtitleBlendResult subtitle_blend_images(const ASS_Image *head);

#endif /* C_SUBTITLE_BLEND_H */
