#include "codec_probe_worker.h"
#include <editor_media_platform/emp_media_file.h>
#include <editor_media_platform/emp_errors.h>
#include "assert_handler.h"
#include "jve_log.h"

#include <QCoreApplication>
#include <QMetaObject>

#ifdef __APPLE__
#include <pthread.h>
#endif

CodecProbeWorker::~CodecProbeWorker() {
    cancel();
}

// Global instance (defined in emp_bindings.cpp, extern linkage)
extern CodecProbeWorker g_codec_probe_worker;

void jve_cancel_codec_probe_worker() {
    g_codec_probe_worker.cancel();
}

void CodecProbeWorker::start(std::vector<std::string> paths, BatchCallback callback) {
    cancel();  // stop any previous probe

    m_paths = std::move(paths);
    m_callback = std::move(callback);
    m_shutdown.store(false);
    m_running.store(true);

    m_thread = std::thread(&CodecProbeWorker::worker_loop, this);
}

void CodecProbeWorker::cancel() {
    m_shutdown.store(true);
    if (m_thread.joinable()) {
        m_thread.join();
    }
    m_running.store(false);
}

void CodecProbeWorker::worker_loop() {
    jve_init_thread_lua_state();  // for assert handler

    // Lower thread priority (macOS: QOS_CLASS_UTILITY = low priority I/O)
#ifdef __APPLE__
    pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0);
#endif

    JVE_LOG_EVENT(Media, "codec_probe_worker: starting, %zu paths", m_paths.size());

    std::vector<CodecProbeResult> batch;
    batch.reserve(BATCH_SIZE);

    for (size_t i = 0; i < m_paths.size(); ++i) {
        if (m_shutdown.load()) break;

        const auto& path = m_paths[i];
        CodecProbeResult result;
        result.path = path;

        // Thin probe: avformat_open_input only, header-derived codec_id,
        // avcodec_find_decoder. NO avformat_find_stream_info, NO VT
        // negotiation, NO frame decode. Cuts per-file I/O from ~5 MB
        // (Open() default probesize) to ~64 KB for container-tagged
        // formats — critical when this worker runs concurrently with
        // playback, where the 5 MB pulls were thrashing the page cache
        // and contending for the VT hardware engine.
        auto probe_result = emp::MediaFile::ProbeCodecExistence(path);
        if (probe_result.is_error()) {
            result.offline = true;
            result.error_code = emp::error_code_to_string(probe_result.error().code);
        } else {
            result.offline = false;
        }

        batch.push_back(std::move(result));

        // Send batch when full or at end
        bool is_last = (i + 1 == m_paths.size()) || m_shutdown.load();
        if (batch.size() >= BATCH_SIZE || is_last) {
            auto batch_copy = std::move(batch);
            batch = {};
            batch.reserve(BATCH_SIZE);

            bool is_final = is_last;
            auto cb = m_callback;  // copy for lambda capture

            // Deliver on main thread via invokeMethod (thread-safe cross-thread call)
            auto* app = QCoreApplication::instance();
            if (app) {
                QMetaObject::invokeMethod(app,
                    [cb, batch_copy = std::move(batch_copy), is_final]() {
                        cb(batch_copy, is_final);
                    }, Qt::QueuedConnection);
            }
        }
    }

    m_running.store(false);
    JVE_LOG_EVENT(Media, "codec_probe_worker: done (%s)",
        m_shutdown.load() ? "cancelled" : "complete");
}
