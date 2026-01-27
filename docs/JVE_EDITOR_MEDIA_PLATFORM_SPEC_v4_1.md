# JVE Editor Media Platform (FFmpeg-Backed) v4 — Claude Implementation Spec

## Goal
Create a self-contained, editor-focused media platform module (EMP) that:
- Displays decoded video frames in Source Viewer now.
- Hides all FFmpeg implementation details inside EMP.
- Can later be split out of JVE as a standalone OSS library.
- Specifies deterministic, low-stutter VFR→CFR playback mapping (no interpolation) to avoid later redesign.

## Feature scope
- Video-only decode for Source Viewer (no audio in this phase).
- Worker-thread decode with UI-thread presentation.
- BGRA32 frames suitable for Qt.

## Architectural constraints
- Lua owns policy: transport, scrub/play semantics, caching policy.
- C++ owns mechanisms: decode, conversions, worker threading, buffer lifetimes, Qt painting.
- FFmpeg headers/types appear only in `src/editor_media_platform/src/impl/`.

---

## Module layout (suggested)
```
src/editor_media_platform/
  include/editor_media_platform/
    emp_time.h
    emp_rate.h
    emp_asset.h
    emp_reader.h
    emp_frame.h
    emp_errors.h
  src/
    emp_asset.cpp
    emp_reader.cpp
    emp_frame.cpp
    impl/
      ffmpeg_context.h/.cpp
      ffmpeg_decode.cpp
      ffmpeg_seek.cpp
      ffmpeg_convert.cpp
```

Rules:
- Only `impl/` includes FFmpeg headers.
- Everything outside EMP includes only `include/editor_media_platform/*`.

---

## Public C++ API (frame-first for editor clients)

### Types
- `using emp_time_us = int64_t;` (internal canonical time; not primary for clients)
- `struct Rate { int32_t num; int32_t den; };`  // fps = num/den
- `struct FrameTime { int64_t frame; Rate rate; };`

Tick time conversion (EMP-internal):
- `T(n) = floor(n * 1_000_000 * rate.den / rate.num)`

### Errors (EMP-owned)
- `enum class ErrorCode { Ok, FileNotFound, Unsupported, DecodeFailed, SeekFailed, EOFReached, InvalidArg, Internal };`
- `struct Error { ErrorCode code; std::string message; };`
- `template<typename T> using Result = /* Result<T, Error> */;`

No FFmpeg error codes escape.

### Asset
- `static Result<std::shared_ptr<Asset>> Asset::Open(std::string path);`
- `const AssetInfo& Asset::info() const;`

`AssetInfo` (minimal):
- duration_us
- has_video, video_width, video_height
- video_nominal_fps_num, video_nominal_fps_den (best-effort, may be approximate)
- is_vfr (best-effort; conservative OK)

### Reader (video-only in feature scope)
- `static Result<std::shared_ptr<Reader>> Reader::Create(std::shared_ptr<Asset> asset);`

Primary API:
- `Result<void> Seek(FrameTime t);`
- `Result<std::shared_ptr<Frame>> DecodeAt(FrameTime t);`

Optional (debug/tooling only; not used by editor clients):
- `Result<void> SeekUS(emp_time_us t_us);`
- `Result<std::shared_ptr<Frame>> DecodeAtUS(emp_time_us t_us);`

### Frame (BGRA32 required)
- `int width() const;`
- `int height() const;`
- `int stride_bytes() const;`
- `emp_time_us source_pts_us() const;`  // debug/telemetry only
- `const uint8_t* data() const;`        // BGRA32, alpha=255 OK

---

## Source Viewer CFR grid selection (required)
EMP (or the JVE Lua client) must pick a CFR grid rate for Source Viewer frame indexing.

Rule:
- Default to the clip’s **nominal rate** from `AssetInfo`.
- If a **sequence rate** is provided and it is “close” to nominal, use the sequence rate instead.

Definition of “close”:
- `abs(nominal_fps - seq_fps) / seq_fps <= 0.002` (0.2%)
- This deliberately treats 23.976↔24 and 29.97↔30 as “close”.

Represent rates as rationals (num/den). For common rates, keep exact canonical rationals (e.g., 24000/1001, 30000/1001) rather than floats.

---

## Decode semantic for “show frame at editor time” (required)
`Reader::DecodeAt(FrameTime t)` must implement floor-on-grid behavior:

- Let `T = T(t.frame)` in microseconds.
- Return the decoded source frame `F` with the largest `pts_us(F) <= T`.
- If `T` is earlier than the first decodable frame: snap to the first decodable frame.
- If `T` is beyond EOF: return the last decodable frame.
- Deterministic for equal PTS: pick the last decoded with that PTS.

Seek/backoff requirement (pin down to avoid FFmpeg edge cases):
- When seeking for `DecodeAt`, seek to a keyframe at/before T, but apply a conservative backoff window:
  - `seek_target = max(stream_start, T - 2_000_000)` (2 seconds)
  - Then decode forward to find the floor frame at T.

---

## VFR→CFR playback mapping policy (specified now; implemented later)
Playback is tick-driven (clock-driven), not frame-driven.

### Policy: Strategy B (guarded-nearest, monotonic, small early tolerance)
At each output tick time `T = T(n)`:
- Maintain candidates:
  - `cur`: latest decoded source frame with `pts <= T`
  - `next`: first decoded source frame with `pts > T` (if available)

Decision:
1) Default output is `cur` (hold-last / floor).
2) Switch to `next` early only if:
   - `abs(pts(next) - T) < abs(T - pts(cur))`
   - `pts(next) - T <= early_tol_us`
   - monotonicity preserved

Pinned defaults:
- `early_tol_us = 3000` (3 ms)
- Hysteresis: once `next` is chosen for tick n, do not reconsider until tick n+1.
- If `next` is not available: output `cur`.

Drop/dupe smoothing (pinned to avoid clustering behavior):
- If multiple source frames fall in the window, select the candidate with the largest `pts <= T + early_tol_us` subject to monotonicity.
- Never output more than one source frame per tick.

---

## Threading and cancellation (required)
- Decode runs on a worker thread.
- Requests are coalesced: only the latest request/generation matters.
- Closing a reader:
  - increments generation (invalidates in-flight work),
  - cancels/drains worker queue,
  - prevents late callbacks from updating UI.

UI-thread contract:
- `SURFACE_SET_FRAME` must run on the UI thread.
- Worker thread only produces frames and posts them to UI.

---

## Qt presentation (JVE-side; EMP must not depend on Qt)
### VideoSurfaceWidget
- Stores the current image for painting.
- For v1 safety: **copy** frame pixels into a QImage-owned buffer on the UI thread.
  - Use `QImage::Format_ARGB32` (little-endian memory layout matches BGRA byte order).
- Later optimization can wrap EMP buffers (requires strict lifetime pinning).

---

## JVE Lua bindings (frame-first)
Bindings call EMP public headers only.

### Lua table
- `qt_constants.EMP`

### Runtime error convention (required)
- Type/programmer errors: `luaL_error`
- Runtime failures: return `nil, { code=string, msg=string }`

Pinned `code` strings:
- `FileNotFound`, `Unsupported`, `DecodeFailed`, `SeekFailed`, `EOFReached`, `InvalidArg`, `Internal`

`msg` must always be present.

### Binding surface (feature scope)
Asset/Reader:
- `EMP.ASSET_OPEN(path) -> asset | nil, err`
- `EMP.READER_CREATE(asset) -> reader | nil, err`
- `EMP.READER_CLOSE(reader)`
- `EMP.ASSET_CLOSE(asset)`

Frame-first seek/decode:
- `EMP.READER_SEEK_FRAME(reader, frame_idx, rate_num, rate_den) -> true | nil, err`
- `EMP.READER_DECODE_FRAME(reader, frame_idx, rate_num, rate_den) -> frame | nil, err`

Frame info:
- `EMP.FRAME_INFO(frame) -> { width, height, stride, source_pts_us }`

Lifetime:
- `EMP.FRAME_RELEASE(frame)` (refcount; safe after surface holds a ref)

Qt surface:
- `qt_constants.WIDGET.CREATE_VIDEO_SURFACE() -> widget`
- `EMP.SURFACE_SET_FRAME(surface_widget, frame|nil)`

---

## Acceptance criteria
1. Source Viewer displays a decoded frame for a valid file path.
2. Repeated load/clear cycles do not leak or crash; no late-frame UI updates after close.
3. FFmpeg headers/types appear only under EMP `impl/`.
4. Editor-facing API is frame-first; Lua mainline uses frame indices, not timestamps.

---

## Extraction readiness checklist
- EMP public headers contain no JVE includes, no Qt includes, no FFmpeg includes.
- EMP can be built as a separable target.
- Errors are EMP-owned and stable.
- Bindings depend only on EMP public headers.


---

## Pinned nominal-rate canonicalization and “lying metadata” handling (required)

### Canonical rate snapping
Before comparing nominal rate to sequence rate for “close”, EMP must canonicalize the nominal rate:

- Define a set of canonical CFR rates (rationals):
  - 24000/1001, 24/1
  - 30000/1001, 30/1
  - 25/1
  - 50/1
  - 60000/1001, 60/1

Rule:
- If the nominal rate is within the “close” tolerance (0.2% as defined) of any canonical rate, snap nominal to that canonical rational before further decisions.

This prevents container/stream metadata quirks from defeating the “close” logic.

### Nominal rate selection when stream metadata lies
EMP must choose nominal rate using FFmpeg-provided stream rates with a stable heuristic:

- Prefer `avg_frame_rate` when valid and non-zero.
- Otherwise use `r_frame_rate` when valid and non-zero.
- If both are valid and disagree by more than the “close” tolerance:
  - mark `is_vfr = true`
  - choose the nominal rate as the nearest canonical rate (after canonical snapping above)
  - if neither is close to a canonical rate, choose `avg_frame_rate` as-is and still mark `is_vfr = true`

Rationale:
- Editors need a deterministic CFR grid even when metadata is inconsistent; VFR is signaled explicitly via `is_vfr`.
