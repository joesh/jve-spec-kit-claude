#pragma once

#include "emp_peak_file.h"
#include "emp_reader.h"
#include "emp_media_file.h"
#include <string>
#include <memory>
#include <thread>
#include <mutex>
#include <condition_variable>
#include <atomic>
#include <deque>
#include <unordered_map>
#include <vector>

namespace emp {

// ============================================================================
// PeakGenerator — concurrent round-robin peak computation engine
//
// Files are processed in interleaved 1-second chunks so all queued files
// progress simultaneously. Multiple worker threads provide parallelism.
// The main thread can query partially-generated peak data for progressive
// waveform display via QueryInProgress().
//
// FD-admission: only MAX_RUNNING_JOBS jobs hold their media resources
// (avformat context + decoder) simultaneously. Without this bound, a
// project with hundreds of audio media exhausts the OS file-descriptor
// table (default 256 soft on macOS) and cascades into unrelated open()
// failures elsewhere in the process.
// ============================================================================
class PeakGenerator {
public:
    // Max concurrent jobs in the Running state (holding open media
    // resources). Sized to leave ample FD headroom for the rest of the
    // process under the default macOS soft limit of 256.
    static constexpr int MAX_RUNNING_JOBS = 8;

    PeakGenerator();
    ~PeakGenerator();

    // Request peak generation for a media file.
    // Returns immediately — work happens on background threads.
    // Idempotent: if already generating or complete, no-op.
    void RequestPeaks(const std::string& media_id,
                      const std::string& media_path,
                      const std::string& output_path);

    // Cancel a pending/running generation job.
    void CancelPeaks(const std::string& media_id);

    // Cancel all pending/running jobs (project close).
    void CancelAll();

    // Query generation progress.
    struct JobStatus {
        enum State { None, Queued, Running, Complete, Failed };
        State state = None;
        int64_t progress_samples = 0;
        int64_t total_samples = 0;
    };
    JobStatus GetStatus(const std::string& media_id) const;

    // Number of jobs currently in the Running state (holding media
    // resources). Exposed for tests asserting admission-cap behavior.
    int GetRunningCount() const;

    // Query in-progress peak data for progressive waveform display.
    // Returns level-0 data resampled to pixel_width. Only valid while
    // state == Running. Thread-safe: called from main thread while
    // workers write to the buffer (acquire/release fence on progress_samples).
    struct ProgressQueryResult {
        std::vector<float> peaks;  // owned copy — safe after return
        int count = 0;
        int64_t actual_start = 0;
        int64_t actual_end = 0;
    };
    ProgressQueryResult QueryInProgress(const std::string& media_id,
                                         int64_t source_start_sample,
                                         int64_t source_end_sample,
                                         int pixel_width) const;

private:
    // A job that persists across chunks. Opened once, decoded incrementally.
    struct ChunkedJob {
        // Identity
        std::string media_id;
        std::string media_path;
        std::string output_path;

        // State (state written under m_mutex; atomics read lock-free)
        JobStatus::State state = JobStatus::Queued;
        std::atomic<int64_t> progress_samples{0};  // acquire/release fence
        int64_t total_samples = 0;
        std::atomic<bool> cancel_flag{false};

        // Persistent media resources (opened once in InitJob)
        std::shared_ptr<MediaFile> media_file;
        std::shared_ptr<Reader> reader;
        MediaFileInfo info{};
        AudioFormat out_fmt{SampleFormat::F32, 0, 0};
        emp::Rate sample_rate{0, 1};

        // Peak data (level 0 written by workers, read by main thread via fence)
        PeakBuffer peak_buf;
        int64_t decode_position = 0;  // next sample to decode
    };

    // Worker thread entry point
    void WorkerLoop();

    // Job lifecycle subfunctions (rule 2.5: top-level reads like algorithm)
    bool InitJob(ChunkedJob& job);
    bool ProcessOneChunk(ChunkedJob& job);
    void FinalizeJob(ChunkedJob& job);
    // Shared tail for FinalizeJob: flip state under m_mutex, decrement
    // running count, notify admission/work CVs, release media handles.
    // Called from both the normal write-and-exit path and the truncation-
    // reject early exit, so the two paths don't drift apart.
    void MarkJobDone(ChunkedJob& job, bool success);

    // Thread pool
    std::vector<std::thread> m_workers;
    mutable std::mutex m_mutex;
    std::condition_variable m_cv;             // signalled when rotation has work
    std::condition_variable m_admission_cv;   // signalled when a Running slot frees
    std::atomic<bool> m_shutdown{false};

    // Two-queue scheduler: workers prefer jobs that have already been
    // admitted (m_running_queue) and fall through to the pending pool
    // only when admission has capacity. This prevents all workers from
    // blocking on admission while Running jobs sit idle in one queue.
    std::deque<std::shared_ptr<ChunkedJob>> m_running_queue;  // admitted, mid-chunk rotation
    std::deque<std::shared_ptr<ChunkedJob>> m_queued_pool;    // awaiting admission

    // Count of jobs currently in Running state (holding media resources).
    // Bounded by MAX_RUNNING_JOBS via admission control in WorkerLoop.
    int m_running_count = 0;

    // All jobs by media_id (for GetStatus/QueryInProgress/Cancel lookup)
    std::unordered_map<std::string, std::shared_ptr<ChunkedJob>> m_jobs;

    // Scratch buffer for QueryInProgress resampling (main thread only)
    mutable std::vector<float> m_query_scratch;
};

} // namespace emp
