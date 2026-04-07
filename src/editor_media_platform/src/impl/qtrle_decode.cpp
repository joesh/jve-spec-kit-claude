#include "qtrle_decode.h"
#include <cassert>
#include <cstring>
#include <algorithm>
#include <dispatch/dispatch.h>

// Big-endian reads (qtrle header is big-endian)
static inline uint16_t read_be16(const uint8_t* p) {
    return static_cast<uint16_t>((p[0] << 8) | p[1]);
}

static inline uint32_t read_be32(const uint8_t* p) {
    return (static_cast<uint32_t>(p[0]) << 24) |
           (static_cast<uint32_t>(p[1]) << 16) |
           (static_cast<uint32_t>(p[2]) << 8)  |
           static_cast<uint32_t>(p[3]);
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

    // Pre-allocate buffer pool with pre-touched pages.
    // On macOS, fresh vector<uint8_t>(33MB) triggers ~2000 page faults (~130ms).
    // By pre-allocating and writing all bytes once, pages become resident.
    // When returned to the pool after Frame release, the pages stay resident.
    m_pool = std::make_shared<BufferPool>();
    m_pool->buf_size = buf_size;
    for (int i = 0; i < POOL_INITIAL_SIZE; i++) {
        std::vector<uint8_t> buf(buf_size);
        std::memset(buf.data(), 0, buf_size);  // pre-touch all pages
        m_pool->free_list.push_back(std::move(buf));
    }

    return {};
}

std::vector<uint8_t> QtrleDecoder::acquire_buffer() {
    std::lock_guard<std::mutex> lock(m_pool->mutex);
    if (!m_pool->free_list.empty()) {
        auto buf = std::move(m_pool->free_list.back());
        m_pool->free_list.pop_back();
        return buf;
    }
    // Pool exhausted — allocate fresh (slow, but rare)
    return std::vector<uint8_t>(m_pool->buf_size);
}

std::function<void(std::vector<uint8_t>)> QtrleDecoder::release_callback() {
    // Capture shared_ptr to pool — keeps pool alive even if QtrleDecoder
    // is destroyed before all Frames are released (e.g. during shutdown).
    auto pool = m_pool;
    return [pool](std::vector<uint8_t> buf) {
        std::lock_guard<std::mutex> lock(pool->mutex);
        pool->free_list.push_back(std::move(buf));
    };
}

void QtrleDecoder::flush() {
    std::fill(m_ref_buffer.begin(), m_ref_buffer.end(), 0);
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

Result<void> QtrleDecoder::decode(
        const uint8_t* pkt_data, int pkt_size,
        uint8_t* bgra_out, int bgra_stride) {
    assert(pkt_data && "QtrleDecoder::decode: pkt_data is null");
    assert(bgra_out && "QtrleDecoder::decode: bgra_out is null");
    assert(bgra_stride >= m_width * 4 &&
           "QtrleDecoder::decode: bgra_stride too small");

    // Parse header
    PacketHeader hdr = parse_header(pkt_data, pkt_size);

    if (hdr.is_duplicate) {
        // Duplicate frame: copy reference buffer to output
        for (int y = 0; y < m_height; y++) {
            std::memcpy(bgra_out + y * bgra_stride,
                        m_ref_buffer.data() + y * m_ref_stride,
                        m_width * 4);
        }
        return {};
    }

    // Pointer to RLE data (past header)
    const uint8_t* rle_data = pkt_data + hdr.data_offset;
    int rle_size = pkt_size - hdr.data_offset;

    if (rle_size <= 0) {
        return Error::internal("QtrleDecoder: empty RLE data");
    }

    // Pass 1: Pre-scan to find scanline byte offsets (sequential)
    prescan_line_offsets(rle_data, rle_size, hdr.num_lines);

    // Pass 2: Parallel decode into reference buffer.
    // Batch scanlines into chunks to amortize GCD dispatch overhead.
    // With 2160 lines at 4K, per-scanline dispatch is too fine-grained
    // (~5μs work per line, dispatch overhead dominates).
    int start_line = hdr.start_line;
    int num_lines = hdr.num_lines;
    constexpr int NUM_CHUNKS = 16;  // 4K: ~135 lines per chunk
    int lines_per_chunk = (num_lines + NUM_CHUNKS - 1) / NUM_CHUNKS;

    dispatch_apply(static_cast<size_t>(NUM_CHUNKS),
                   dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0),
                   ^(size_t chunk_idx) {
        int chunk_start = static_cast<int>(chunk_idx) * lines_per_chunk;
        int chunk_end = std::min(chunk_start + lines_per_chunk, num_lines);

        for (int i = chunk_start; i < chunk_end; i++) {
            int line = start_line + i;
            if (line >= m_height) break;
            if (m_line_offsets[i] >= rle_size) continue;

            uint8_t* row_ptr = m_ref_buffer.data() + line * m_ref_stride;
            decode_scanline(rle_data, m_line_offsets[i], row_ptr);
        }
    });

    // Copy reference buffer to output
    for (int y = 0; y < m_height; y++) {
        std::memcpy(bgra_out + y * bgra_stride,
                    m_ref_buffer.data() + y * m_ref_stride,
                    m_width * 4);
    }

    return {};
}

} // namespace impl
} // namespace emp
