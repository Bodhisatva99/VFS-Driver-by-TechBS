#ifndef VFS491_PROTOCOL_H
#define VFS491_PROTOCOL_H

#include <stdint.h>

#define VFS491_FRAME_MAGIC 0x31534656u /* ASCII "VFS1" in little-endian */
#define VFS491_FRAME_VERSION 1u
#define VFS491_IMAGE_WIDTH 200u
#define VFS491_MAX_IMAGE_HEIGHT 1023u
#define VFS491_MAX_IMAGE_BYTES (VFS491_IMAGE_WIDTH * VFS491_MAX_IMAGE_HEIGHT)

/* The bridge writes this header followed by exactly image_len grayscale bytes. */
struct __attribute__((packed)) vfs491_frame_header {
    uint32_t magic_le;
    uint32_t version_le;
    uint32_t width_le;
    uint32_t height_le;
    uint32_t image_len_le;
};

#endif
