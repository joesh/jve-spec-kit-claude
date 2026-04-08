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
#include <vector>

namespace emp {
namespace impl {

class QtrleDecoder {
public:
    // Initialize for given frame dimensions.
    // Only 32bpp (ARGB) depth is supported.
    Result<void> init(int width, int height);

    // Set scaled output dimensions. Call before first decode if
    // downscaling is desired. decode() will produce scaled output into
    // the caller-provided buffer at these dimensions.
    void set_scaled_output(int w, int h);

    // Decode one qtrle packet into the internal reference buffer.
    // If set_scaled_output was called AND scaled_out is non-null,
    // also writes a downscaled copy directly into scaled_out.
    // The caller owns scaled_out — decoder writes there, no internal copy.
    Result<void> decode(const uint8_t* pkt_data, int pkt_size,
                        uint8_t* scaled_out = nullptr, int scaled_stride = 0);

    // Access the decoded reference buffer (full resolution, valid after decode()).
    const uint8_t* ref_data() const { return m_ref_buffer.data(); }
    int ref_stride() const { return m_ref_stride; }

    // Scaled output dimensions (0 if no scaling configured).
    int scaled_width() const { return m_scaled_w; }
    int scaled_height() const { return m_scaled_h; }
    bool has_scaled_output() const { return m_scaled_w > 0; }

    // Clear reference buffer (call after seek).
    // Next frame must be a keyframe to produce correct output.
    void flush();

    int width() const { return m_width; }
    int height() const { return m_height; }

private:
    int m_width = 0;
    int m_height = 0;

    // Reference frame in BGRA format. Persists across frames for delta coding.
    // Stride is 32-byte aligned.
    std::vector<uint8_t> m_ref_buffer;
    int m_ref_stride = 0;

    // Scaled output dimensions (set by set_scaled_output).
    int m_scaled_w = 0;
    int m_scaled_h = 0;

    // Pre-scan result: byte offset into packet data where each scanline begins.
    // Built during the sequential pre-scan pass, consumed by parallel decode.
    std::vector<int> m_line_offsets;

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
