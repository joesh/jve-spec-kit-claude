#pragma once

// Custom parallel QuickTime Animation (qtrle) decoder.
// Replaces FFmpeg's single-threaded implementation for 32bpp ARGB.
// Uses GCD dispatch_apply for row-level parallelism.
//
// qtrle format: per-scanline RLE with skip/run/literal opcodes.
// Delta coding: unchanged pixels persist from previous frame via
// internal reference buffer. flush() clears it (call after seek).

#include <editor_media_platform/emp_errors.h>
#include <cstdint>
#include <functional>
#include <mutex>
#include <vector>

namespace emp {
namespace impl {

class QtrleDecoder {
public:
    // Initialize for given frame dimensions.
    // Only 32bpp (ARGB) depth is supported.
    Result<void> init(int width, int height);

    // Decode one qtrle packet into BGRA output buffer.
    // Handles delta frames via internal reference buffer.
    // bgra_out must be at least bgra_stride * height bytes.
    Result<void> decode(const uint8_t* pkt_data, int pkt_size,
                        uint8_t* bgra_out, int bgra_stride);

    // Clear reference buffer (call after seek).
    // Next frame must be a keyframe to produce correct output.
    void flush();

    // Acquire a pre-touched output buffer from the pool (avoids page faults).
    // Returns a buffer of size ref_stride * height, with all pages resident.
    std::vector<uint8_t> acquire_buffer();

    // Release callback for FrameImpl — returns buffer to pool on Frame destruction.
    std::function<void(std::vector<uint8_t>)> release_callback();

    int width() const { return m_width; }
    int height() const { return m_height; }
    int ref_stride() const { return m_ref_stride; }

private:
    int m_width = 0;
    int m_height = 0;

    // Reference frame in BGRA format. Persists across frames for delta coding.
    // Stride is 32-byte aligned.
    std::vector<uint8_t> m_ref_buffer;
    int m_ref_stride = 0;

    // Pre-scan result: byte offset into packet data where each scanline begins.
    // Built during the sequential pre-scan pass, consumed by parallel decode.
    std::vector<int> m_line_offsets;

    // Buffer pool: pre-allocated, pre-touched BGRA buffers.
    // Avoids ~130ms page fault overhead on macOS for 4K (33MB) allocations.
    // Buffers are returned via FrameImpl's release callback when Frame is freed.
    // Shared ownership via shared_ptr: Frames may outlive the Reader/QtrleDecoder
    // (e.g. in TMB cache during shutdown). The shared_ptr ensures the pool stays
    // alive as long as any Frame holds a release callback referencing it.
    struct BufferPool {
        std::vector<std::vector<uint8_t>> free_list;
        std::mutex mutex;
        size_t buf_size = 0;
    };
    std::shared_ptr<BufferPool> m_pool;
    static constexpr int POOL_INITIAL_SIZE = 8;

    // Parse packet header. Returns offset to RLE data start.
    struct PacketHeader {
        int start_line;
        int num_lines;
        int data_offset;  // byte offset from pkt_data to first scanline
        bool is_duplicate; // packet < 8 bytes = duplicate frame
    };
    PacketHeader parse_header(const uint8_t* pkt_data, int pkt_size);

    // Pre-scan: walk opcodes to find byte offset of each scanline start.
    void prescan_line_offsets(const uint8_t* data, int data_size, int num_lines);

    // Decode a single scanline from opcode stream into reference buffer.
    // row_ptr points to start of this row in m_ref_buffer.
    void decode_scanline(const uint8_t* data, int offset, uint8_t* row_ptr);
};

} // namespace impl
} // namespace emp
