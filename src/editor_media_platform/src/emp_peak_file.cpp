#include "editor_media_platform/emp_peak_file.h"
#include <cstring>
#include <cmath>
#include <algorithm>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>

namespace emp {

// ============================================================================
// Content fingerprint — FNV-1a-64 over up to 64KB at start + 64KB at end.
//
// "Did the bytes of this media file change?" The mtime alone false-
// positives on every cp/touch/rsync-without-t. Comparing the actual
// bytes via a fixed-size sample window is the architecturally correct
// signal: invariant under inode rewrites that preserve content, AND
// catches real edits (overwrite-in-place, BWF metadata rewrites).
// ============================================================================
namespace {
constexpr uint64_t FNV1A_OFFSET_BASIS = 0xcbf29ce484222325ULL;
constexpr uint64_t FNV1A_PRIME        = 0x100000001b3ULL;
constexpr size_t   FINGERPRINT_WINDOW = 64 * 1024;  // 64KB head + 64KB tail

inline void FnvAccumulate(uint64_t& h, const uint8_t* buf, size_t n) {
    for (size_t i = 0; i < n; ++i) {
        h ^= buf[i];
        h *= FNV1A_PRIME;
    }
}
}  // namespace

uint64_t ComputeContentHash(const std::string& media_path, int64_t expected_size) {
    if (expected_size <= 0) return 0;

    int fd = ::open(media_path.c_str(), O_RDONLY);
    if (fd < 0) return 0;

    uint64_t h = FNV1A_OFFSET_BASIS;
    // Fold expected_size into the hash so two files of different sizes
    // whose sample windows happen to coincide still get different hashes.
    {
        uint64_t s = static_cast<uint64_t>(expected_size);
        FnvAccumulate(h, reinterpret_cast<const uint8_t*>(&s), sizeof(s));
    }

    uint8_t buf[FINGERPRINT_WINDOW];
    const size_t head_len = (expected_size < static_cast<int64_t>(FINGERPRINT_WINDOW))
        ? static_cast<size_t>(expected_size)
        : FINGERPRINT_WINDOW;

    ssize_t got = ::pread(fd, buf, head_len, 0);
    if (got < 0 || static_cast<size_t>(got) != head_len) {
        ::close(fd);
        return 0;
    }
    FnvAccumulate(h, buf, head_len);

    // Tail window — only if the file is larger than head_len (otherwise
    // we've already hashed everything).
    if (static_cast<int64_t>(head_len) < expected_size) {
        const size_t tail_len = (expected_size - static_cast<int64_t>(head_len)
                                    < static_cast<int64_t>(FINGERPRINT_WINDOW))
            ? static_cast<size_t>(expected_size - head_len)
            : FINGERPRINT_WINDOW;
        const off_t tail_off = static_cast<off_t>(expected_size - tail_len);
        got = ::pread(fd, buf, tail_len, tail_off);
        if (got < 0 || static_cast<size_t>(got) != tail_len) {
            ::close(fd);
            return 0;
        }
        FnvAccumulate(h, buf, tail_len);
    }

    ::close(fd);
    // Avoid the sentinel: if a real fingerprint happens to be 0
    // (statistically negligible), bump it so callers can use 0 ==
    // "no fingerprint available" unambiguously.
    return h == 0 ? 1 : h;
}

bool RefreshHeaderMtime(const std::string& peak_path, int64_t new_mtime) {
    int fd = ::open(peak_path.c_str(), O_WRONLY);
    if (fd < 0) return false;
    ssize_t written = ::pwrite(fd, &new_mtime, sizeof(new_mtime),
                               static_cast<off_t>(PEAK_HEADER_MTIME_OFFSET));
    ::close(fd);
    return written == static_cast<ssize_t>(sizeof(new_mtime));
}

// ============================================================================
// PeakFileWriter
// ============================================================================

bool PeakFileWriter::Write(const std::string& output_path,
                           const PeakFileHeader& header,
                           const float* peak_data,
                           size_t peak_data_floats)
{
    if (peak_data_floats > 0 && !peak_data) return false;

    std::string tmp_path = output_path + ".tmp";

    int fd = ::open(tmp_path.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return false;

    ssize_t hdr_written = ::write(fd, &header, sizeof(PeakFileHeader));
    if (hdr_written != static_cast<ssize_t>(sizeof(PeakFileHeader))) {
        ::close(fd);
        ::unlink(tmp_path.c_str());
        return false;
    }

    size_t data_bytes = peak_data_floats * sizeof(float);
    if (data_bytes > 0) {
        ssize_t data_written = ::write(fd, peak_data, data_bytes);
        if (data_written != static_cast<ssize_t>(data_bytes)) {
            ::close(fd);
            ::unlink(tmp_path.c_str());
            return false;
        }
    }

    ::close(fd);

    if (::rename(tmp_path.c_str(), output_path.c_str()) != 0) {
        ::unlink(tmp_path.c_str());
        return false;
    }

    return true;
}

// ============================================================================
// PeakFileReader
// ============================================================================

PeakFileReader::~PeakFileReader()
{
    if (m_mmap_addr && m_mmap_addr != MAP_FAILED) {
        ::munmap(m_mmap_addr, m_mmap_size);
    }
    if (m_fd >= 0) {
        ::close(m_fd);
    }
}

static bool ValidateAndComputeOffsets(PeakFileReader& reader, size_t file_size)
{
    const auto& hdr = reader.header();

    if (std::memcmp(hdr.magic, PEAK_MAGIC, 4) != 0) return false;
    if (hdr.version != PEAK_VERSION) return false;

    // Verify data fits within file
    size_t expected = PEAK_HEADER_SIZE;
    for (int i = 0; i < MIPMAP_LEVELS; ++i) {
        expected += hdr.bins_per_level[i] * 2 * sizeof(float);
    }
    if (expected > file_size) return false;

    return true;
}

std::unique_ptr<PeakFileReader> PeakFileReader::Open(const std::string& path)
{
    int fd = ::open(path.c_str(), O_RDONLY);
    if (fd < 0) return nullptr;

    struct stat st;
    if (::fstat(fd, &st) != 0 || st.st_size < 0) {
        ::close(fd);
        return nullptr;
    }

    size_t file_size = static_cast<size_t>(st.st_size);
    if (file_size < PEAK_HEADER_SIZE) {
        ::close(fd);
        return nullptr;
    }

    void* addr = ::mmap(nullptr, file_size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (addr == MAP_FAILED) {
        ::close(fd);
        return nullptr;
    }

    auto reader = std::unique_ptr<PeakFileReader>(new PeakFileReader());
    std::memcpy(&reader->m_header, addr, sizeof(PeakFileHeader));
    reader->m_mmap_addr = addr;
    reader->m_mmap_size = file_size;
    reader->m_fd = fd;

    if (!ValidateAndComputeOffsets(*reader, file_size)) {
        ::munmap(addr, file_size);
        ::close(fd);
        return nullptr;
    }

    // Compute level data byte offsets
    size_t offset = PEAK_HEADER_SIZE;
    for (int i = 0; i < MIPMAP_LEVELS; ++i) {
        reader->m_level_offsets[i] = offset;
        offset += reader->m_header.bins_per_level[i] * 2 * sizeof(float);
    }

    return reader;
}

const float* PeakFileReader::LevelData(int level) const
{
    if (level < 0 || level >= MIPMAP_LEVELS) return nullptr;
    auto* base = static_cast<const uint8_t*>(m_mmap_addr);
    return reinterpret_cast<const float*>(base + m_level_offsets[level]);
}

uint64_t PeakFileReader::BinsAtLevel(int level) const
{
    if (level < 0 || level >= MIPMAP_LEVELS) return 0;
    return m_header.bins_per_level[level];
}

// ============================================================================
// Query subfunctions (rule 2.5)
// ============================================================================

int SelectMipmapLevel(double samples_per_pixel)
{
    for (int i = MIPMAP_LEVELS - 1; i >= 0; --i) {
        if (SAMPLES_PER_LEVEL[i] <= samples_per_pixel) {
            return i;
        }
    }
    return 0;
}

void MapSourceRangeToBins(int64_t source_start, int64_t source_end,
                          uint32_t spp, uint64_t total_bins,
                          int64_t& out_start_bin, int64_t& out_end_bin)
{
    out_start_bin = source_start / static_cast<int64_t>(spp);
    out_end_bin = (source_end + spp - 1) / static_cast<int64_t>(spp);

    if (out_start_bin < 0) out_start_bin = 0;
    if (out_end_bin > static_cast<int64_t>(total_bins)) out_end_bin = static_cast<int64_t>(total_bins);
}

void ResampleBinsToPixels(const float* level_data,
                          int64_t start_bin, int64_t bin_count,
                          uint64_t total_bins,
                          int pixel_width,
                          std::vector<float>& out_buf)
{
    out_buf.resize(static_cast<size_t>(pixel_width) * 2);
    double bins_per_pixel = static_cast<double>(bin_count) / pixel_width;

    for (int px = 0; px < pixel_width; ++px) {
        int64_t b0 = start_bin + static_cast<int64_t>(px * bins_per_pixel);
        int64_t b1 = start_bin + static_cast<int64_t>((px + 1) * bins_per_pixel);
        if (b1 <= b0) b1 = b0 + 1;
        if (b0 < 0) b0 = 0;
        if (b0 >= static_cast<int64_t>(total_bins)) b0 = static_cast<int64_t>(total_bins) - 1;
        if (b1 > static_cast<int64_t>(total_bins)) b1 = static_cast<int64_t>(total_bins);

        float mn = 1.0f;
        float mx = -1.0f;
        for (int64_t b = b0; b < b1; ++b) {
            float bin_min = level_data[b * 2];
            float bin_max = level_data[b * 2 + 1];
            if (bin_min < mn) mn = bin_min;
            if (bin_max > mx) mx = bin_max;
        }

        out_buf[static_cast<size_t>(px) * 2]     = mn;
        out_buf[static_cast<size_t>(px) * 2 + 1] = mx;
    }
}

PeakFileReader::QueryResult PeakFileReader::Query(int64_t source_start_sample,
                                                   int64_t source_end_sample,
                                                   int pixel_width) const
{
    QueryResult result;
    if (source_end_sample <= source_start_sample || pixel_width <= 0) return result;

    int64_t total_source = source_end_sample - source_start_sample;
    double samples_per_pixel = static_cast<double>(total_source) / pixel_width;

    int level = SelectMipmapLevel(samples_per_pixel);
    uint32_t spp = SAMPLES_PER_LEVEL[level];
    uint64_t total_bins = m_header.bins_per_level[level];
    const float* level_data = LevelData(level);
    if (!level_data || total_bins == 0) return result;

    int64_t start_bin, end_bin;
    MapSourceRangeToBins(source_start_sample, source_end_sample, spp, total_bins,
                          start_bin, end_bin);
    if (start_bin >= end_bin) return result;

    int64_t bin_count = end_bin - start_bin;
    ResampleBinsToPixels(level_data, start_bin, bin_count, total_bins,
                          pixel_width, m_query_buf);

    result.peaks = m_query_buf.data();
    result.count = pixel_width;
    result.actual_start = start_bin * static_cast<int64_t>(spp);
    result.actual_end = end_bin * static_cast<int64_t>(spp);
    return result;
}

} // namespace emp
