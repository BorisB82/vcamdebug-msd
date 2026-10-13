// Shared ABI between the NDI daemon (producer) and the mediaserverd tweak (consumer).
// Both map the same file MAP_SHARED: /var/mobile/Media/DCIM/vcam_ndi_frames.bin
//
// Layout: a fixed 4 KiB header page, then VCAMNDI_RING raw-pixel slots. The daemon decodes
// NDI (UYVY 4:2:2) and converts to NV12 / '420v' (biplanar 4:2:0, video range) before
// publishing, so the mediaserverd consumer hands VideoToolbox a same-family 420->420 scale
// (hardware) instead of a 4:2:2->4:2:0 convert (software, ~10x slower). A seqlock
// (frameSeq even/odd) guards against reading a torn header; triple buffering means the slot
// being read is not the slot being written.
//
// Each slot holds NV12 for width x height: a Y plane (height rows x width bytes, packed,
// rowBytes = width) immediately followed by an interleaved CbCr plane (height/2 rows x
// width bytes, packed). Consumer offsets: Y at slot+0, CbCr at slot + width*height.

#ifndef VCAMNDI_SHARED_H
#define VCAMNDI_SHARED_H

#include <stdint.h>

#define VCAMNDI_PATH        "/var/mobile/Media/DCIM/vcam_ndi_frames.bin"
#define VCAMNDI_MAGIC       0x56434E31u   /* 'VCN1' */
#define VCAMNDI_ABI         1u
#define VCAMNDI_RING        3u
#define VCAMNDI_HEADER_SIZE 4096u

// Capacity cap for this milestone: up to 1920x1088 UYVY per slot. Larger streams are
// rejected by the daemon (it logs and does not publish).
#define VCAMNDI_MAX_W       1920u
#define VCAMNDI_MAX_H       1088u
#define VCAMNDI_SLOT_BYTES  (VCAMNDI_MAX_W * VCAMNDI_MAX_H * 2u)   /* 4,177,920 */
#define VCAMNDI_FILE_SIZE   (VCAMNDI_HEADER_SIZE + (uint64_t)VCAMNDI_RING * VCAMNDI_SLOT_BYTES)

// kCVPixelFormatType_422YpCbCr8 == '2vuy' (NDI's native receive format, pre-conversion)
#define VCAMNDI_FOURCC_2VUY 0x32767579u
// kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange == '420v' (what we publish)
#define VCAMNDI_FOURCC_420V 0x34323076u

// NV12 plane offsets within a slot of the given width/height.
static inline uint64_t vcamndi_y_bytes(uint32_t w, uint32_t h)     { return (uint64_t)w * h; }
static inline uint64_t vcamndi_cbcr_bytes(uint32_t w, uint32_t h)  { return (uint64_t)w * (h / 2u); }

typedef struct {
    volatile uint32_t magic;        // VCAMNDI_MAGIC once initialized
    volatile uint32_t abi;          // VCAMNDI_ABI
    volatile uint32_t width;        // current frame width
    volatile uint32_t height;       // current frame height
    volatile uint32_t fourcc;       // VCAMNDI_FOURCC_2VUY
    volatile uint32_t rowBytes;     // bytes per row in a slot (= width*2, packed)
    volatile uint32_t ringCount;    // VCAMNDI_RING
    volatile uint32_t slotBytes;    // VCAMNDI_SLOT_BYTES
    volatile uint32_t currentIndex; // ring slot holding the most recent complete frame
    volatile uint32_t enabled;      // 1 while the daemon is publishing live frames
    volatile uint64_t configGen;    // bumped on geometry change (consumer re-reads dims)
    volatile uint64_t frameSeq;     // seqlock + frame id: odd = write in progress
} VCamNDIHeader;

static inline uint64_t vcamndi_slot_offset(uint32_t index) {
    return (uint64_t)VCAMNDI_HEADER_SIZE + (uint64_t)index * VCAMNDI_SLOT_BYTES;
}

#endif /* VCAMNDI_SHARED_H */
