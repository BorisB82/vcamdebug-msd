// Shared ABI between the NDI daemon (producer) and the mediaserverd tweak (consumer).
// Both map the same file MAP_SHARED: /var/mobile/Media/DCIM/vcam_ndi_frames.bin
//
// Layout: a fixed 4 KiB header page, then VCAMNDI_RING raw-pixel slots. The daemon requests
// NDI 'fastest' (UYVY 4:2:2, native) and publishes it unchanged (one packed plane, rowBytes
// = width*2). This is a pure passthrough with no conversion in the NDI process: requesting a
// converted format (NV12/BGRA) made the A11 do that conversion inline and starved NDI's
// network thread, dropping the connection. The tweak-side UYVY->dst transfer cost is handled
// by resolution instead. A seqlock (frameSeq even/odd) guards against a torn header; triple
// buffering means the slot being read is not the slot being written.

#ifndef VCAMNDI_SHARED_H
#define VCAMNDI_SHARED_H

#include <stdint.h>

#define VCAMNDI_PATH        "/var/mobile/Media/DCIM/vcam_ndi_frames.bin"
#define VCAMNDI_MAGIC       0x56434E31u   /* 'VCN1' */
#define VCAMNDI_ABI         1u
#define VCAMNDI_RING        3u
#define VCAMNDI_HEADER_SIZE 4096u

// Capacity cap: up to 1920x1088 UYVY (2 bytes/px) per slot. Larger streams are rejected by
// the daemon (it logs and does not publish).
#define VCAMNDI_MAX_W       1920u
#define VCAMNDI_MAX_H       1088u
#define VCAMNDI_SLOT_BYTES  (VCAMNDI_MAX_W * VCAMNDI_MAX_H * 2u)   /* 4,177,920 */
#define VCAMNDI_FILE_SIZE   (VCAMNDI_HEADER_SIZE + (uint64_t)VCAMNDI_RING * VCAMNDI_SLOT_BYTES)

// kCVPixelFormatType_422YpCbCr8 == '2vuy' (NDI 'fastest' native; pure passthrough)
#define VCAMNDI_FOURCC_2VUY 0x32767579u

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
