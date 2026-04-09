# Contract: Peak Generator (C++)

## Module: `emp_peak_generator.h / .cpp`

Peak generation engine — runs in background thread, reads audio via EMP Reader, writes `.peaks` binary files.

## Public Interface

### PeakGenerator (singleton or per-project instance)

```cpp
class PeakGenerator {
public:
    // Request peak generation for a media file.
    // Returns immediately — work happens on background thread.
    // If already generating or complete, no-op.
    void RequestPeaks(const std::string& media_id,
                      const std::string& media_path,
                      const std::string& output_path);

    // Cancel a pending/running generation job.
    void CancelPeaks(const std::string& media_id);

    // Cancel all pending/running jobs (project close).
    void CancelAll();

    // Query generation progress.
    // Returns {state, progress_samples, total_samples}.
    struct JobStatus {
        enum State { None, Queued, Running, Complete, Failed };
        State state;
        int64_t progress_samples;
        int64_t total_samples;
    };
    JobStatus GetStatus(const std::string& media_id) const;
};
```

### Lua Bindings (emp_bindings.cpp)

```
EMP.PEAK_REQUEST(media_id, media_path, output_path) → nil
EMP.PEAK_CANCEL(media_id) → nil
EMP.PEAK_CANCEL_ALL() → nil
EMP.PEAK_STATUS(media_id) → {state, progress_samples, total_samples} | nil
```

## Behavior Contract

- `RequestPeaks` MUST NOT block the calling thread
- Background thread MUST decode audio sequentially (no seeking)
- MUST write peak file atomically (write to `.tmp`, rename on completion)
- MUST handle offline/missing media gracefully (set state=Failed, no assert)
- MUST sum multi-channel audio to mono for peak computation
- MUST generate all 4 mipmap levels in a single pass
- Progress counter MUST update at least every 48000 samples (1 second of audio)
- `CancelPeaks` MUST be safe to call from any thread
- After `CancelAll`, no background work may continue
