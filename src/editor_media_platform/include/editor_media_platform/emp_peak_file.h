#pragma once

#include <cstdint>
#include <cstddef>
#include <string>
#include <memory>
#include <vector>

namespace emp {

// Peak file binary format constants
static constexpr char     PEAK_MAGIC[4] = {'J','V','P','K'};
// v2 (2026-06-03): header carries source_size + content_hash so the
// load-time verifier can answer "did the bytes change?" instead of
// "did the inode get rewritten?" (mtime alone false-positives on cp,
// touch, rsync-without-t, fixture refreshes, fs migrations). See
// peak_cache.try_load_existing for the hybrid policy. v1 files are
// rejected at PeakFileReader::Open and regenerated.
static constexpr uint32_t PEAK_VERSION  = 2;
static constexpr uint32_t BASE_SAMPLES_PER_PEAK = 256;
static constexpr uint16_t MIPMAP_LEVELS = 4;
static constexpr uint32_t SAMPLES_PER_LEVEL[4] = {256, 512, 1024, 2048};
static constexpr size_t   PEAK_HEADER_SIZE = 80;

// Byte offset of source_mtime — exposed because the verifier pwrites
// just this field when bytes are unchanged but mtime drifted.
static constexpr size_t   PEAK_HEADER_MTIME_OFFSET = 8;

// 80-byte fixed header (packed to avoid padding)
#pragma pack(push, 1)
struct PeakFileHeader {
    char     magic[4];             //  4 bytes  (offset  0)
    uint32_t version;              //  4 bytes  (offset  4)
    int64_t  source_mtime;         //  8 bytes  (offset  8)
    uint32_t sample_rate;          //  4 bytes  (offset 16)
    uint16_t channels;             //  2 bytes  (offset 20)
    uint32_t base_spp;             //  4 bytes  (offset 22)
    uint16_t num_levels;           //  2 bytes  (offset 26)
    uint64_t bins_per_level[4];    // 32 bytes  (offset 28)
    int64_t  source_size;          //  8 bytes  (offset 60) — v2
    uint64_t content_hash;         //  8 bytes  (offset 68) — v2: FNV-1a-64
                                   //   of fingerprint windows (see
                                   //   ComputeContentHash). Identity of
                                   //   bytes, not cryptographic.
    uint8_t  reserved[4];          //  4 bytes  (offset 76) = 80 total
};
#pragma pack(pop)
static_assert(sizeof(PeakFileHeader) == PEAK_HEADER_SIZE,
    "PeakFileHeader must be exactly 80 bytes");
static_assert(offsetof(PeakFileHeader, source_mtime) == PEAK_HEADER_MTIME_OFFSET,
    "PEAK_HEADER_MTIME_OFFSET must match source_mtime field offset");

// FNV-1a-64 content fingerprint of a media file. Reads up to 64KB
// from the start and 64KB from the end (or the whole file if smaller
// than 128KB). Cheap to compute, collision-resistant enough for
// "did the bytes change" identity — not cryptographic.
//
// expected_size is the file size at the time of generation, used as
// the read budget so a partial-write race during fixture setup cannot
// trick the verifier into accepting a truncated file. On I/O failure
// returns 0 — callers MUST treat 0 as "no fingerprint available" and
// regenerate (do not silently equate two zero hashes).
uint64_t ComputeContentHash(const std::string& media_path, int64_t expected_size);

// Rewrite source_mtime in an existing peak file's header (pwrite at
// PEAK_HEADER_MTIME_OFFSET). Used by the load-time verifier when the
// content hash matches but stored mtime drifted — accept the cached
// peaks and re-sync the mtime so the fast path takes effect on next
// open. Returns true on success. Does not validate magic/version;
// caller is expected to have opened the file via PeakFileReader first.
bool RefreshHeaderMtime(const std::string& peak_path, int64_t new_mtime);

// ============================================================================
// PeakFileWriter — writes peak data atomically (write to .tmp, rename)
// ============================================================================
class PeakFileWriter {
public:
    // Write a complete peak file.
    // peak_data layout: level 0 first, then level 1, etc.
    // Within each level: interleaved [min, max] per bin, mono (channels already summed).
    // Returns true on success.
    static bool Write(const std::string& output_path,
                      const PeakFileHeader& header,
                      const float* peak_data,
                      size_t peak_data_floats);
};

// ============================================================================
// PeakFileReader — mmap-based reader with mipmap query
// ============================================================================
class PeakFileReader {
public:
    ~PeakFileReader();

    // Open and mmap a peak file. Returns nullptr on failure (bad magic, version, etc.)
    static std::unique_ptr<PeakFileReader> Open(const std::string& path);

    // Get the header (parsed on open).
    const PeakFileHeader& header() const { return m_header; }

    // Query result: peak data + the actual sample range it covers.
    struct QueryResult {
        const float* peaks = nullptr;  // [min0,max0,min1,max1,...] — owned by PeakFileReader
        int count = 0;                 // number of min/max pairs
        int64_t actual_start = 0;      // actual file-relative sample start (bin-aligned)
        int64_t actual_end = 0;        // actual file-relative sample end (bin-aligned)
    };

    // Query visible peaks for a source sample range at a given pixel width.
    // Returns peak data tagged with the actual sample range it covers.
    // actual_start/end may differ from requested range due to bin alignment.
    QueryResult Query(int64_t source_start_sample,
                      int64_t source_end_sample,
                      int pixel_width) const;

    // Get raw peak data pointer at a specific mipmap level.
    // Returns pointer to first float in that level's data.
    // Level is 0-based (0 = finest = 256 spp).
    const float* LevelData(int level) const;

    // Number of bins at a given level (0-based).
    uint64_t BinsAtLevel(int level) const;

    // Source mtime stored in header.
    int64_t source_mtime() const { return m_header.source_mtime; }

private:
    PeakFileReader() = default;
    PeakFileHeader m_header{};
    void*  m_mmap_addr = nullptr;
    size_t m_mmap_size = 0;
    int    m_fd = -1;

    // Computed offsets for each level's data (byte offset from start of file)
    size_t m_level_offsets[MIPMAP_LEVELS] = {};

    // Scratch buffer for Query results (resampled to pixel_width)
    mutable std::vector<float> m_query_buf;
};

// ============================================================================
// PeakBuffer — in-memory peak data (level 0 + mipmaps)
// ============================================================================
struct PeakBuffer {
    uint64_t bins_per_level[MIPMAP_LEVELS] = {};
    size_t level_offsets[MIPMAP_LEVELS] = {};
    uint64_t total_data_floats = 0;
    std::vector<float> data;
};

// ============================================================================
// Shared query utilities — used by both PeakFileReader and PeakGenerator
// ============================================================================

// Select the coarsest mipmap level whose samples-per-bin <= samples_per_pixel.
int SelectMipmapLevel(double samples_per_pixel);

// Map a source sample range to bin indices at a given level.
void MapSourceRangeToBins(int64_t source_start, int64_t source_end,
                          uint32_t spp, uint64_t total_bins,
                          int64_t& out_start_bin, int64_t& out_end_bin);

// Resample bins to pixel columns. Writes pixel_width min/max pairs to out_buf.
void ResampleBinsToPixels(const float* level_data,
                          int64_t start_bin, int64_t bin_count,
                          uint64_t total_bins,
                          int pixel_width,
                          std::vector<float>& out_buf);

} // namespace emp
