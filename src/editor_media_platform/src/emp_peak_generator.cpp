#include "editor_media_platform/emp_peak_generator.h"
#include <cmath>
#include <cstring>
#include <algorithm>
#include <vector>
#include <cassert>
#include <sys/stat.h>
#include "../../jve_log.h"

namespace emp {

// ============================================================================
// Thread count policy
// ============================================================================

static int ComputeWorkerCount()
{
    int hw = static_cast<int>(std::thread::hardware_concurrency());
    if (hw <= 0) hw = 2;  // fallback for platforms that return 0
    int count = std::max(1, hw / 2);
    return std::min(count, 4);
}

// ============================================================================
// Constructor / Destructor
// ============================================================================

PeakGenerator::PeakGenerator()
{
    int count = ComputeWorkerCount();
    JVE_LOG_EVENT(Media, "PeakGenerator: starting %d worker threads (hw=%d)",
        count, static_cast<int>(std::thread::hardware_concurrency()));
    for (int i = 0; i < count; ++i) {
        m_workers.emplace_back(&PeakGenerator::WorkerLoop, this);
    }
}

PeakGenerator::~PeakGenerator()
{
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        m_shutdown = true;
        for (auto& [id, job] : m_jobs) {
            job->cancel_flag = true;
        }
        m_running_queue.clear();
        m_queued_pool.clear();
    }
    m_cv.notify_all();
    m_admission_cv.notify_all();
    for (auto& w : m_workers) {
        if (w.joinable()) w.join();
    }
}

// ============================================================================
// Public API
// ============================================================================

void PeakGenerator::RequestPeaks(const std::string& media_id,
                                  const std::string& media_path,
                                  const std::string& output_path)
{
    assert(!media_id.empty() && "PeakGenerator::RequestPeaks: media_id must not be empty");
    assert(!media_path.empty() && "PeakGenerator::RequestPeaks: media_path must not be empty");
    assert(!output_path.empty() && "PeakGenerator::RequestPeaks: output_path must not be empty");

    std::lock_guard<std::mutex> lock(m_mutex);

    // Idempotent: skip if job exists in any non-None state
    auto it = m_jobs.find(media_id);
    if (it != m_jobs.end() && it->second->state != JobStatus::None) {
        return;
    }

    auto job = std::make_shared<ChunkedJob>();
    job->media_id = media_id;
    job->media_path = media_path;
    job->output_path = output_path;
    job->state = JobStatus::Queued;

    m_jobs[media_id] = job;
    m_queued_pool.push_back(job);
    m_cv.notify_one();
}

void PeakGenerator::CancelPeaks(const std::string& media_id)
{
    std::lock_guard<std::mutex> lock(m_mutex);
    auto it = m_jobs.find(media_id);
    if (it != m_jobs.end()) {
        // Signal the worker (if any) to bail out, then drop the map entry
        // so a subsequent RequestPeaks for the same media_id starts a
        // fresh job. RequestPeaks is idempotent on the {media_id : state !=
        // None} pair, so leaving the entry in Complete/Failed state would
        // make later relink-driven re-requests silent no-ops. Workers
        // holding a shared_ptr to the cancelled job keep it valid until
        // they finish — no use-after-free.
        it->second->cancel_flag = true;
        m_jobs.erase(it);
    }
}

void PeakGenerator::CancelAll()
{
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        for (auto& [id, job] : m_jobs) {
            job->cancel_flag = true;
        }
        m_running_queue.clear();
        m_queued_pool.clear();
    }
    m_admission_cv.notify_all();
    m_cv.notify_all();
}

PeakGenerator::JobStatus PeakGenerator::GetStatus(const std::string& media_id) const
{
    std::lock_guard<std::mutex> lock(m_mutex);
    auto it = m_jobs.find(media_id);
    if (it == m_jobs.end()) {
        return JobStatus{JobStatus::None, 0, 0};
    }
    auto& job = it->second;
    return JobStatus{job->state, job->progress_samples.load(), job->total_samples};
}

int PeakGenerator::GetRunningCount() const
{
    std::lock_guard<std::mutex> lock(m_mutex);
    return m_running_count;
}

// ============================================================================
// WorkerLoop — round-robin chunk scheduler (rule 2.5)
// ============================================================================

void PeakGenerator::WorkerLoop()
{
    while (true) {
        std::shared_ptr<ChunkedJob> job;
        bool just_admitted = false;
        {
            std::unique_lock<std::mutex> lock(m_mutex);

            // Wake when something is runnable: shutdown, an already-
            // admitted job, or a pool job plus admission capacity.
            m_cv.wait(lock, [this]() {
                if (m_shutdown.load()) return true;
                if (!m_running_queue.empty()) return true;
                return !m_queued_pool.empty()
                    && m_running_count < MAX_RUNNING_JOBS;
            });
            if (m_shutdown.load()) return;

            // Prefer Running jobs — they hold media resources and their
            // chunks should keep moving to release the admission slot.
            if (!m_running_queue.empty()) {
                job = m_running_queue.front();
                m_running_queue.pop_front();
            } else if (!m_queued_pool.empty()
                   && m_running_count < MAX_RUNNING_JOBS) {
                job = m_queued_pool.front();
                m_queued_pool.pop_front();
                if (!job->cancel_flag.load()) {
                    ++m_running_count;
                    just_admitted = true;
                }
            } else {
                continue;  // spurious wake
            }
        }

        // Cancel observed before any processing. If we just took an
        // admission slot, release it before marking the job Failed.
        if (job->cancel_flag.load()) {
            std::lock_guard<std::mutex> lock(m_mutex);
            if (just_admitted || job->state == JobStatus::Running) {
                --m_running_count;
                m_admission_cv.notify_one();
                m_cv.notify_one();
            }
            job->state = JobStatus::Failed;
            continue;
        }

        // First touch: open media + decoder. InitJob transitions state
        // to Running on success.
        if (just_admitted) {
            if (!InitJob(*job)) {
                std::lock_guard<std::mutex> lock(m_mutex);
                --m_running_count;
                m_admission_cv.notify_one();
                m_cv.notify_one();
                job->state = JobStatus::Failed;
                continue;
            }
        }

        bool more = ProcessOneChunk(*job);

        if (job->cancel_flag.load()) {
            std::lock_guard<std::mutex> lock(m_mutex);
            --m_running_count;
            m_admission_cv.notify_one();
            m_cv.notify_one();
            job->state = JobStatus::Failed;
            continue;
        }

        if (more) {
            std::lock_guard<std::mutex> lock(m_mutex);
            m_running_queue.push_back(job);
            m_cv.notify_one();
        } else {
            // FinalizeJob releases media resources and decrements
            // m_running_count, notifying admission + runnable waiters.
            FinalizeJob(*job);
        }
    }
}

// ============================================================================
// Job lifecycle subfunctions (rule 2.5)
// ============================================================================

static bool OpenMediaAndReader(std::shared_ptr<MediaFile>& out_media,
                                std::shared_ptr<Reader>& out_reader,
                                MediaFileInfo& out_info,
                                const std::string& media_path)
{
    // Check file exists before attempting open (avoids blocking on offline volumes)
    struct stat file_check;
    if (::stat(media_path.c_str(), &file_check) != 0) {
        JVE_LOG_WARN(Media, "PeakGenerator: file not accessible: %s", media_path.c_str());
        return false;
    }

    auto mf_result = MediaFile::Open(media_path);
    if (mf_result.is_error()) {
        JVE_LOG_WARN(Media, "PeakGenerator: failed to open %s: %s",
            media_path.c_str(), mf_result.error().message.c_str());
        return false;
    }
    out_media = mf_result.value();
    out_info = out_media->info();

    if (!out_info.has_audio || out_info.audio_sample_rate <= 0 || out_info.audio_channels <= 0) {
        JVE_LOG_WARN(Media, "PeakGenerator: no audio in %s (rate=%d ch=%d)",
            media_path.c_str(), out_info.audio_sample_rate, out_info.audio_channels);
        return false;
    }

    // Audio-only Reader: skip video codec init for files that have a
    // video stream (typical of .mov/.mp4 with both A+V). This keeps
    // PeakGenerator off the VideoToolbox init path entirely.
    auto reader_result = Reader::CreateAudioOnly(out_media);
    if (reader_result.is_error()) {
        JVE_LOG_WARN(Media, "PeakGenerator: failed to create reader for %s: %s",
            media_path.c_str(), reader_result.error().message.c_str());
        return false;
    }
    out_reader = reader_result.value();
    return true;
}

static int64_t ComputeTotalSamples(const MediaFileInfo& info)
{
    assert(info.duration_us > 0 && "PeakGenerator: duration_us must be positive");
    return static_cast<int64_t>(
        static_cast<double>(info.duration_us) / 1000000.0 * info.audio_sample_rate);
}

static PeakBuffer AllocatePeakBuffer(int64_t total_samples)
{
    PeakBuffer buf;

    for (int lvl = 0; lvl < MIPMAP_LEVELS; ++lvl) {
        buf.bins_per_level[lvl] = static_cast<uint64_t>(
            std::ceil(static_cast<double>(total_samples) / SAMPLES_PER_LEVEL[lvl]));
        buf.total_data_floats += buf.bins_per_level[lvl] * 2;
    }

    size_t offset = 0;
    for (int lvl = 0; lvl < MIPMAP_LEVELS; ++lvl) {
        buf.level_offsets[lvl] = offset;
        offset += buf.bins_per_level[lvl] * 2;
    }

    buf.data.resize(buf.total_data_floats);
    for (size_t i = 0; i < buf.total_data_floats; i += 2) {
        buf.data[i]     =  1.0f;  // min starts high
        buf.data[i + 1] = -1.0f;  // max starts low
    }

    return buf;
}

// Shrink an already-populated peak buffer so its level-0 span matches the
// actual decoded sample count (rather than the duration_us * rate estimate
// used to allocate the original buffer). Higher mipmap levels are left
// unpopulated — BuildMipmaps will rebuild them from the copied level-0 data.
//
// Rationale: PeakGenerator sizes peak_buf up front from a container duration
// estimate. For codecs/containers where duration_us overshoots the decoder's
// real output (e.g. AAC/M4A priming with non-zero start_pts), the tail bins
// are never written and would otherwise remain at their AllocatePeakBuffer
// sentinel values (min=1, max=-1), polluting both the mipmap chain and the
// written peak file.
static void TrimPeakBufferToActualSamples(PeakBuffer& buf, int64_t actual_samples)
{
    PeakBuffer trimmed = AllocatePeakBuffer(actual_samples);
    assert(trimmed.level_offsets[0] == 0 &&
        "PeakGenerator: trimmed level 0 must start at offset 0");
    assert(buf.level_offsets[0] == 0 &&
        "PeakGenerator: source level 0 must start at offset 0");
    assert(trimmed.bins_per_level[0] <= buf.bins_per_level[0] &&
        "PeakGenerator: trim target must not exceed original bin count");

    size_t copy_floats = trimmed.bins_per_level[0] * 2;
    std::memcpy(trimmed.data.data(), buf.data.data(), copy_floats * sizeof(float));
    buf = std::move(trimmed);
}

static void AccumulateSamplesToLevel0(PeakBuffer& buf,
                                       const float* audio,
                                       int64_t decoded_frames,
                                       int channels,
                                       int64_t samples_processed)
{
    assert(audio && "PeakGenerator: audio data pointer is null");
    assert(channels > 0 && "PeakGenerator: channels must be > 0");

    for (int64_t s = 0; s < decoded_frames; ++s) {
        float sample_min = audio[s * channels];
        float sample_max = audio[s * channels];
        for (int ch = 1; ch < channels; ++ch) {
            float v = audio[s * channels + ch];
            if (v < sample_min) sample_min = v;
            if (v > sample_max) sample_max = v;
        }

        int64_t bin = (samples_processed + s) / static_cast<int64_t>(BASE_SAMPLES_PER_PEAK);
        if (bin >= static_cast<int64_t>(buf.bins_per_level[0])) continue;

        size_t idx = buf.level_offsets[0] + static_cast<size_t>(bin) * 2;
        if (sample_min < buf.data[idx])     buf.data[idx]     = sample_min;
        if (sample_max > buf.data[idx + 1]) buf.data[idx + 1] = sample_max;
    }
}

static void BuildMipmaps(PeakBuffer& buf)
{
    for (int lvl = 1; lvl < MIPMAP_LEVELS; ++lvl) {
        uint64_t prev_bins = buf.bins_per_level[lvl - 1];
        uint64_t curr_bins = buf.bins_per_level[lvl];
        if (prev_bins == 0) break;

        for (uint64_t b = 0; b < curr_bins; ++b) {
            uint64_t src0 = b * 2;
            uint64_t src1 = src0 + 1;
            float mn =  1.0f;
            float mx = -1.0f;

            if (src0 < prev_bins) {
                size_t si = buf.level_offsets[lvl - 1] + static_cast<size_t>(src0) * 2;
                mn = std::min(mn, buf.data[si]);
                mx = std::max(mx, buf.data[si + 1]);
            }
            if (src1 < prev_bins) {
                size_t si = buf.level_offsets[lvl - 1] + static_cast<size_t>(src1) * 2;
                mn = std::min(mn, buf.data[si]);
                mx = std::max(mx, buf.data[si + 1]);
            }

            size_t di = buf.level_offsets[lvl] + static_cast<size_t>(b) * 2;
            buf.data[di]     = mn;
            buf.data[di + 1] = mx;
        }
    }
}

static bool WriteOutputFile(const PeakBuffer& buf, const MediaFileInfo& info,
                             const std::string& media_path,
                             const std::string& output_path)
{
    PeakFileHeader header{};
    std::memcpy(header.magic, PEAK_MAGIC, 4);
    header.version = PEAK_VERSION;

    struct stat st;
    if (::stat(media_path.c_str(), &st) == 0) {
        header.source_mtime = st.st_mtime;
    } else {
        JVE_LOG_WARN(Media, "PeakGenerator: stat failed for %s — mtime will be 0",
            media_path.c_str());
    }

    header.sample_rate = static_cast<uint32_t>(info.audio_sample_rate);
    header.channels = static_cast<uint16_t>(info.audio_channels);
    header.base_spp = BASE_SAMPLES_PER_PEAK;
    header.num_levels = MIPMAP_LEVELS;
    for (int i = 0; i < MIPMAP_LEVELS; ++i) {
        header.bins_per_level[i] = buf.bins_per_level[i];
    }

    bool ok = PeakFileWriter::Write(output_path, header,
                                     buf.data.data(), buf.total_data_floats);
    if (!ok) {
        JVE_LOG_WARN(Media, "PeakGenerator: failed to write %s", output_path.c_str());
    }
    return ok;
}

// ============================================================================
// InitJob — open media, allocate peak buffer (called once per job)
// ============================================================================

bool PeakGenerator::InitJob(ChunkedJob& job)
{
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        job.state = JobStatus::Running;
    }

    if (!OpenMediaAndReader(job.media_file, job.reader, job.info, job.media_path)) {
        return false;
    }

    job.total_samples = ComputeTotalSamples(job.info);
    assert(job.total_samples > 0 &&
        "PeakGenerator::InitJob: total_samples must be positive");

    job.peak_buf = AllocatePeakBuffer(job.total_samples);
    job.decode_position = 0;
    job.out_fmt = AudioFormat{SampleFormat::F32, job.info.audio_sample_rate, job.info.audio_channels};
    job.sample_rate = emp::Rate{job.info.audio_sample_rate, 1};

    JVE_LOG_EVENT(Media, "PeakGenerator: init %s — %lld samples (%.1fs)",
        job.media_id.c_str(), (long long)job.total_samples,
        static_cast<double>(job.total_samples) / job.info.audio_sample_rate);

    return true;
}

// ============================================================================
// ProcessOneChunk — decode 1 second, accumulate into level 0
// Returns true if more chunks remain.
// ============================================================================

bool PeakGenerator::ProcessOneChunk(ChunkedJob& job)
{
    int64_t chunk_frames = job.info.audio_sample_rate;  // 1-second chunks
    int64_t remaining = job.total_samples - job.decode_position;
    if (remaining <= 0) return false;

    int64_t this_chunk = std::min(chunk_frames, remaining);

    FrameTime t0 = FrameTime::from_frame(job.decode_position, job.sample_rate);
    FrameTime t1 = FrameTime::from_frame(job.decode_position + this_chunk, job.sample_rate);

    auto pcm_result = job.reader->DecodeAudioRange(t0, t1, job.out_fmt);
    if (pcm_result.is_error()) {
        JVE_LOG_WARN(Media, "PeakGenerator: decode failed at sample %lld for %s",
            (long long)job.decode_position, job.media_id.c_str());
        job.decode_position += this_chunk;
        job.progress_samples.store(
            std::min(job.decode_position, job.total_samples),
            std::memory_order_release);
        return job.decode_position < job.total_samples;
    }

    auto pcm = pcm_result.value();

    int64_t decoded_frames = static_cast<int64_t>(pcm->frames());

    // Reader contract (emp_reader.h): frames()==0 on a successful Result
    // means EOF, not an error. Container duration_us routinely overshoots
    // the decoder's real output (AAC priming, BWF padding, codec rounding),
    // so this is reachable for normal files. Treat as clean end-of-stream:
    // leave decode_position and progress_samples at their last-successful
    // values so FinalizeJob sees the true actual-decoded count and can
    // trim the peak buffer accordingly.
    if (decoded_frames == 0) {
        JVE_LOG_EVENT(Media,
            "PeakGenerator: early EOF at %lld/%lld for %s",
            (long long)job.decode_position,
            (long long)job.total_samples,
            job.media_id.c_str());
        return false;
    }

    assert(pcm->data_f32() && "PeakGenerator::ProcessOneChunk: decoded PCM has null data");

    int64_t frames_to_use = std::min(decoded_frames, job.total_samples - job.decode_position);
    assert(frames_to_use > 0 &&
        "PeakGenerator::ProcessOneChunk: no usable frames");

    AccumulateSamplesToLevel0(job.peak_buf, pcm->data_f32(), frames_to_use,
                              pcm->channels(), job.decode_position);

    job.decode_position += decoded_frames;
    job.progress_samples.store(
        std::min(job.decode_position, job.total_samples),
        std::memory_order_release);

    return job.decode_position < job.total_samples;
}

// ============================================================================
// FinalizeJob — build mipmaps, write file, release resources
// ============================================================================

void PeakGenerator::FinalizeJob(ChunkedJob& job)
{
    // Authoritative actual-decoded count. decode_position may transiently
    // exceed total_samples when a chunk over-delivers (clamped via min).
    // It may also fall short of total_samples when the decoder hits EOF
    // before the duration estimate predicted (AAC priming etc.).
    int64_t actual_samples = std::min(job.decode_position, job.total_samples);
    assert(actual_samples > 0 &&
        "PeakGenerator::FinalizeJob: no samples were decoded");

    // Refuse to persist a peak file whose decoded coverage falls far
    // short of the expected total. ProcessOneChunk accepts a zero-frame
    // read as clean EOF; we have observed this firing mid-stream at
    // ~50% of expected samples on otherwise-healthy Resolve Media-Manage
    // MOVs (TSO 2026-04-24, anamnesis-gold-timeline). Root cause is not
    // understood — the regen on the next project open produced a
    // complete peak file against the same media. A truncated peak file
    // whose mtime matches the media's mtime is served as authoritative
    // by peak_cache across sessions, so dropping the file is the only
    // way to force a retry. The stricter coverage check in
    // peak_cache.try_load_existing catches pre-existing truncated
    // files; this prevents newly-generated ones from joining them.
    constexpr double TRUNCATION_THRESHOLD = 0.95;
    const double coverage = static_cast<double>(actual_samples)
        / static_cast<double>(job.total_samples);
    if (coverage < TRUNCATION_THRESHOLD) {
        JVE_LOG_WARN(Media,
            "PeakGenerator: decoded %lld / %lld samples (%.1f%%) for %s — "
            "refusing to write truncated peak file; next open will retry",
            (long long)actual_samples, (long long)job.total_samples,
            coverage * 100.0, job.media_id.c_str());
        MarkJobDone(job, /*success=*/false);
        return;
    }

    // If the decoder delivered fewer samples than the duration-based
    // estimate, shrink the peak buffer so mipmaps and the written file
    // contain no sentinel-init tail bins. See TrimPeakBufferToActualSamples.
    if (actual_samples < job.total_samples) {
        TrimPeakBufferToActualSamples(job.peak_buf, actual_samples);
        job.total_samples = actual_samples;
    }

    BuildMipmaps(job.peak_buf);

    bool ok = WriteOutputFile(job.peak_buf, job.info, job.media_path, job.output_path);
    MarkJobDone(job, ok);

    JVE_LOG_EVENT(Media, "PeakGenerator: %s %s (%lld samples)",
        ok ? "complete" : "FAILED", job.media_id.c_str(),
        (long long)job.total_samples);
}

// Shared FinalizeJob tail: flip state under m_mutex, free a running
// slot, notify waiters, release media resources. peak_buf intentionally
// kept alive — late in-progress queries may still reference it via
// m_jobs until the job is removed.
void PeakGenerator::MarkJobDone(ChunkedJob& job, bool success)
{
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        job.state = success ? JobStatus::Complete : JobStatus::Failed;
        --m_running_count;
    }
    m_admission_cv.notify_one();
    m_cv.notify_one();
    job.reader.reset();
    job.media_file.reset();
}

// ============================================================================
// QueryInProgress — main-thread query of partially-generated peak data
// ============================================================================

PeakGenerator::ProgressQueryResult PeakGenerator::QueryInProgress(
    const std::string& media_id,
    int64_t source_start_sample,
    int64_t source_end_sample,
    int pixel_width) const
{
    ProgressQueryResult result;
    if (source_end_sample <= source_start_sample || pixel_width <= 0) return result;

    // Find the job (lock briefly to copy shared_ptr)
    std::shared_ptr<ChunkedJob> job;
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        auto it = m_jobs.find(media_id);
        if (it == m_jobs.end()) return result;
        if (it->second->state != JobStatus::Running) return result;
        job = it->second;
    }

    // Read progress with acquire to synchronize with worker's release store.
    // All level-0 bins up to progress_samples are guaranteed visible.
    int64_t progress = job->progress_samples.load(std::memory_order_acquire);
    if (progress <= 0) return result;

    // Only level 0 available during generation (mipmaps built at end)
    uint32_t spp = BASE_SAMPLES_PER_PEAK;
    int64_t bins_available = progress / static_cast<int64_t>(spp);
    if (bins_available <= 0) return result;

    // Map source range to bins, clamped to what's been computed
    int64_t start_bin, end_bin;
    MapSourceRangeToBins(source_start_sample, source_end_sample,
                          spp, static_cast<uint64_t>(bins_available),
                          start_bin, end_bin);
    if (start_bin >= end_bin) return result;

    int64_t bin_count = end_bin - start_bin;

    // Resample to pixel width (main thread only, m_query_scratch is safe)
    const float* level0 = job->peak_buf.data.data() + job->peak_buf.level_offsets[0];
    ResampleBinsToPixels(level0, start_bin, bin_count,
                          static_cast<uint64_t>(bins_available),
                          pixel_width, m_query_scratch);

    // Copy to owned result (scratch may be reused on next call)
    result.peaks = m_query_scratch;
    result.count = pixel_width;
    result.actual_start = start_bin * static_cast<int64_t>(spp);
    result.actual_end = end_bin * static_cast<int64_t>(spp);
    return result;
}

} // namespace emp
