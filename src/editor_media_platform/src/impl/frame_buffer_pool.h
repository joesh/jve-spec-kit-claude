#pragma once

// Thread-safe pool of pre-allocated raw frame buffers. Uses malloc (no
// zero-init) so page faults happen in the decoder's dispatch_apply instead
// of sequentially during allocation. Frames return their buffer here via
// FrameImpl::RawReleaseCallback when their refcount hits zero.
//
// shared_ptr so the pool outlives the Reader if cached frames still reference it.

#include "frame_impl.h"
#include <cassert>
#include <cstdlib>
#include <mutex>
#include <vector>

namespace emp {

struct FrameBufferPool {
    static constexpr size_t MAX_POOLED = 160;  // > MAX_VIDEO_CACHE (144)
    std::mutex mtx;

    struct Entry { uint8_t* data; size_t size; };
    std::vector<Entry> buffers;

    ~FrameBufferPool() {
        for (auto& e : buffers) free(e.data);
    }

    // Pre-allocate buffers with malloc (no zero-init, no page faults).
    // Pages will fault on first write inside the decoder's dispatch_apply.
    void warm(size_t buf_size, size_t count) {
        assert(buf_size > 0 && "FrameBufferPool::warm: buf_size must be > 0");
        std::lock_guard<std::mutex> lock(mtx);
        for (size_t i = buffers.size(); i < count && i < MAX_POOLED; ++i) {
            auto* p = static_cast<uint8_t*>(malloc(buf_size));
            assert(p && "FrameBufferPool::warm: malloc failed");
            buffers.push_back({p, buf_size});
        }
    }

    // Take a buffer of at least `size` bytes, or malloc fresh.
    Entry acquire(size_t size) {
        assert(size > 0 && "FrameBufferPool::acquire: size must be > 0");
        std::lock_guard<std::mutex> lock(mtx);
        for (auto it = buffers.begin(); it != buffers.end(); ++it) {
            if (it->size >= size) {
                Entry e = *it;
                buffers.erase(it);
                return e;
            }
        }
        // Pool empty — fresh malloc (page faults on first write, parallelized by decoder).
        auto* p = static_cast<uint8_t*>(malloc(size));
        assert(p && "FrameBufferPool::acquire: malloc failed");
        return {p, size};
    }

    // Return a buffer to the pool for reuse.
    void release(uint8_t* data, size_t size) {
        assert(data && "FrameBufferPool::release: data must not be null");
        std::lock_guard<std::mutex> lock(mtx);
        if (buffers.size() < MAX_POOLED) {
            buffers.push_back({data, size});
        } else {
            free(data);
        }
    }

    // Create a release callback for FrameImpl. Uses weak_ptr so the callback
    // safely outlives the pool (falls back to free if pool is gone).
    static FrameImpl::RawReleaseCallback make_release_cb(
            std::shared_ptr<FrameBufferPool> pool) {
        std::weak_ptr<FrameBufferPool> pool_ref = pool;
        return [pool_ref](uint8_t* data, size_t size) {
            if (auto p = pool_ref.lock()) {
                p->release(data, size);
            } else {
                free(data);
            }
        };
    }
};

} // namespace emp
