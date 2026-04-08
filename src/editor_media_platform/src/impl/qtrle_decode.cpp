#include "qtrle_decode.h"
#include <cassert>
#include <cstring>
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <dispatch/dispatch.h>

// EMP log level for qtrle decode timing (EMP_LOG_LEVEL >= 2)
static int qtrle_log_level() {
    static int level = [] {
        const char* env = getenv("EMP_LOG_LEVEL");
        return env ? atoi(env) : 0;
    }();
    return level;
}
#define QTRLE_LOG_DEBUG(...) do { if (qtrle_log_level() >= 2) { fprintf(stderr, "[QTRLE] "); fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); } } while(0)

// Big-endian reads (qtrle header is big-endian)
static inline uint16_t read_be16(const uint8_t* p) {
    return static_cast<uint16_t>((p[0] << 8) | p[1]);
}

// Convert one ARGB pixel to BGRA.
// ARGB byte order: [A, R, G, B]
// BGRA byte order: [B, G, R, A]
static inline uint32_t argb_to_bgra(const uint8_t* src) {
    return static_cast<uint32_t>(src[3])        // B
         | (static_cast<uint32_t>(src[2]) << 8) // G
         | (static_cast<uint32_t>(src[1]) << 16)// R
         | (static_cast<uint32_t>(src[0]) << 24);// A
}

namespace emp {
namespace impl {

Result<void> QtrleDecoder::init(int width, int height) {
    assert(width > 0 && "QtrleDecoder::init: width must be > 0");
    assert(height > 0 && "QtrleDecoder::init: height must be > 0");

    m_width = width;
    m_height = height;
    m_ref_stride = ((width * 4) + 31) & ~31;  // 32-byte aligned
    size_t buf_size = static_cast<size_t>(m_ref_stride) * height;
    m_ref_buffer.resize(buf_size, 0);
    m_line_offsets.resize(height);

    return {};
}

void QtrleDecoder::flush() {
    std::fill(m_ref_buffer.begin(), m_ref_buffer.end(), 0);
}

void QtrleDecoder::set_scaled_output(int w, int h) {
    assert(w > 0 && "QtrleDecoder::set_scaled_output: width must be > 0");
    assert(h > 0 && "QtrleDecoder::set_scaled_output: height must be > 0");
    assert(m_width > 0 && "QtrleDecoder::set_scaled_output: call init() first");

    m_scaled_w = w;
    m_scaled_h = h;
}

QtrleDecoder::PacketHeader QtrleDecoder::parse_header(
        const uint8_t* pkt_data, int pkt_size) {
    PacketHeader hdr = {};

    // Duplicate frame: packet too small for header
    if (pkt_size < 8) {
        hdr.is_duplicate = true;
        return hdr;
    }

    // Bytes 0-3: chunk size (masked)
    // Bytes 4-5: header flags
    uint16_t flags = read_be16(pkt_data + 4);

    if (flags & 0x0008) {
        // Partial update: start_line and height present
        assert(pkt_size >= 14 && "QtrleDecoder: partial update header too short");
        hdr.start_line = read_be16(pkt_data + 6);
        // Bytes 8-9: reserved
        hdr.num_lines = read_be16(pkt_data + 10);
        // Bytes 12-13: reserved
        hdr.data_offset = 14;
    } else {
        // Full frame update
        hdr.start_line = 0;
        hdr.num_lines = m_height;
        hdr.data_offset = 6;
    }

    // Clamp to frame bounds
    if (hdr.start_line + hdr.num_lines > m_height) {
        hdr.num_lines = m_height - hdr.start_line;
    }

    return hdr;
}

void QtrleDecoder::prescan_line_offsets(
        const uint8_t* data, int data_size, int num_lines) {
    int pos = 0;
    int line = 0;

    while (line < num_lines && pos < data_size) {
        m_line_offsets[line] = pos;

        // Skip the initial skip_byte for this scanline
        if (pos >= data_size) break;
        pos++;  // skip_byte

        // Walk opcodes until end-of-line sentinel (0xFF = -1 signed)
        while (pos < data_size) {
            int8_t code = static_cast<int8_t>(data[pos]);
            pos++;

            if (code == -1) {
                // End of scanline
                break;
            } else if (code == 0) {
                // Mid-line skip: 1 extra byte
                pos++;
            } else if (code < 0) {
                // RLE run: 1 pixel (4 bytes)
                pos += 4;
            } else {
                // Literal copy: code pixels (code * 4 bytes)
                pos += code * 4;
            }
        }

        line++;
    }

    // Fill remaining lines (if fewer lines in packet than expected)
    for (int i = line; i < num_lines; i++) {
        m_line_offsets[i] = data_size;  // sentinel: no data
    }
}

void QtrleDecoder::decode_scanline(
        const uint8_t* data, int offset, uint8_t* row_ptr) {
    int pos = offset;

    // Initial skip byte: 1-based column offset
    uint8_t skip = data[pos++];
    int col = (skip - 1);  // 0-based pixel index
    if (col < 0) col = 0;

    uint32_t* row32 = reinterpret_cast<uint32_t*>(row_ptr);

    while (true) {
        int8_t code = static_cast<int8_t>(data[pos++]);

        if (code == -1) {
            // End of scanline
            return;
        }

        if (code == 0) {
            // Mid-line skip
            uint8_t skip_val = data[pos++];
            col += (skip_val - 1);
            continue;
        }

        if (code < 0) {
            // RLE run: repeat one ARGB pixel
            int count = -code;
            uint32_t pixel = argb_to_bgra(data + pos);
            pos += 4;

            int end = std::min(col + count, m_width);
            for (int i = col; i < end; i++) {
                row32[i] = pixel;
            }
            col = end;
        } else {
            // Literal copy: code ARGB pixels
            int count = code;
            int end = std::min(col + count, m_width);
            for (int i = col; i < end; i++) {
                row32[i] = argb_to_bgra(data + pos);
                pos += 4;
            }
            // Skip any remaining pixels that went past width
            if (col + count > m_width) {
                pos += (col + count - m_width) * 4;
            }
            col = end;
        }
    }
}

Result<void> QtrleDecoder::decode(const uint8_t* pkt_data, int pkt_size,
                                  uint8_t* scaled_out, int scaled_stride) {
    assert(pkt_data && "QtrleDecoder::decode: pkt_data is null");

    PacketHeader hdr = parse_header(pkt_data, pkt_size);
    if (hdr.is_duplicate) return {};

    const uint8_t* rle_data = pkt_data + hdr.data_offset;
    int rle_size = pkt_size - hdr.data_offset;
    if (rle_size <= 0) return Error::internal("QtrleDecoder: empty RLE data");

    auto t0 = std::chrono::steady_clock::now();
    prescan_line_offsets(rle_data, rle_size, hdr.num_lines);
    auto t1 = std::chrono::steady_clock::now();

    int start_line = hdr.start_line;
    int num_lines = hdr.num_lines;
    constexpr int NUM_CHUNKS = 16;
    int lines_per_chunk = (num_lines + NUM_CHUNKS - 1) / NUM_CHUNKS;

    bool do_scale = scaled_out && m_scaled_w > 0 && m_scaled_h > 0;
    if (do_scale) {
        assert(scaled_stride >= m_scaled_w * 4 &&
            "QtrleDecoder::decode: scaled_stride too small for scaled width");
    }
    float scale_x = do_scale ? static_cast<float>(m_width) / m_scaled_w : 0;
    float scale_y = do_scale ? static_cast<float>(m_height) / m_scaled_h : 0;

    // Phase A: Parallel RLE decode into reference buffer
    dispatch_apply(static_cast<size_t>(NUM_CHUNKS),
                   dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0),
                   ^(size_t chunk_idx) {
        int chunk_start = static_cast<int>(chunk_idx) * lines_per_chunk;
        int chunk_end = std::min(chunk_start + lines_per_chunk, num_lines);
        for (int i = chunk_start; i < chunk_end; i++) {
            int line = start_line + i;
            if (line >= m_height) break;
            if (m_line_offsets[i] >= rle_size) continue;
            decode_scanline(rle_data, m_line_offsets[i],
                            m_ref_buffer.data() + line * m_ref_stride);
        }
    });
    auto t2 = std::chrono::steady_clock::now();

    // Phase B: Parallel box downscale — writes directly into caller's buffer
    if (do_scale) {
        int block_x = std::max(1, static_cast<int>(scale_x));
        int block_y = std::max(1, static_cast<int>(scale_y));
        int scaled_w = m_scaled_w;
        int scaled_h = m_scaled_h;

        dispatch_apply(static_cast<size_t>(16),
                       dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0),
                       ^(size_t ci) {
            int oy0 = static_cast<int>(ci) * ((scaled_h + 15) / 16);
            int oy1 = std::min(oy0 + ((scaled_h + 15) / 16), scaled_h);
            for (int oy = oy0; oy < oy1; oy++) {
                int sy = static_cast<int>(oy * scale_y);
                uint8_t* dst_row = scaled_out + oy * scaled_stride;
                for (int ox = 0; ox < scaled_w; ox++) {
                    int sx = static_cast<int>(ox * scale_x);
                    uint32_t r = 0, g = 0, b = 0, a = 0;
                    int count = 0;
                    for (int by = 0; by < block_y && (sy + by) < m_height; by++) {
                        const uint8_t* sr = m_ref_buffer.data() + (sy + by) * m_ref_stride;
                        for (int bx = 0; bx < block_x && (sx + bx) < m_width; bx++) {
                            const uint8_t* p = sr + (sx + bx) * 4;
                            b += p[0]; g += p[1]; r += p[2]; a += p[3];
                            count++;
                        }
                    }
                    uint8_t* dp = dst_row + ox * 4;
                    dp[0] = b / count; dp[1] = g / count;
                    dp[2] = r / count; dp[3] = a / count;
                }
            }
        });
    }
    auto t3 = std::chrono::steady_clock::now();

    auto us = [](auto a, auto b) {
        return std::chrono::duration_cast<std::chrono::microseconds>(b - a).count();
    };
    QTRLE_LOG_DEBUG("prescan=%.1fms rle=%.1fms scale=%.1fms total=%.1fms out=%dx%d",
            us(t0, t1)/1000.0, us(t1, t2)/1000.0, us(t2, t3)/1000.0,
            us(t0, t3)/1000.0,
            do_scale ? m_scaled_w : m_width, do_scale ? m_scaled_h : m_height);

    return {};
}

} // namespace impl
} // namespace emp
