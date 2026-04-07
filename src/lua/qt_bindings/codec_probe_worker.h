#pragma once

#include <string>
#include <vector>
#include <thread>
#include <atomic>
#include <functional>

// Background codec probe worker.
// Probes media files via emp::MediaFile::Open + ProbeCodec on a low-priority thread.
// Batches results and delivers them to the main thread via QMetaObject::invokeMethod.

struct CodecProbeResult {
    std::string path;
    bool offline;
    std::string error_code;  // "Unsupported", "DecodeFailed", or "" if OK
};

class CodecProbeWorker {
public:
    // Callback type: receives a batch of results (called on main thread)
    using BatchCallback = std::function<void(const std::vector<CodecProbeResult>& batch, bool is_final)>;

    CodecProbeWorker() = default;
    ~CodecProbeWorker();

    // Start probing paths on a background thread.
    // callback is invoked on the main thread (via QTimer) with batches of results.
    // Any previous probe is cancelled first.
    void start(std::vector<std::string> paths, BatchCallback callback);

    // Cancel the current probe (if any). Blocks until the worker thread exits.
    void cancel();

    // Is a probe currently running?
    bool is_running() const { return m_running.load(); }

private:
    void worker_loop();

    std::thread m_thread;
    std::atomic<bool> m_shutdown{false};
    std::atomic<bool> m_running{false};

    // Inputs (set before thread start, read-only by worker)
    std::vector<std::string> m_paths;
    BatchCallback m_callback;

    static constexpr int BATCH_SIZE = 10;
};

// Called from main.cpp aboutToQuit — cancels worker before static destruction
void jve_cancel_codec_probe_worker();
