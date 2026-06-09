# Contract: Synchronous Audio Device Handover

**Feature**: 017 | **Phase**: 1 | **Files**: `src/lua/core/playback/playback_engine.lua` + `src/lua/core/media/audio_playback.lua` (MODIFIED) | **Spec**: FR-011 / FR-012 / FR-013 / FR-013a

The synchronous, blocking transition that swaps audio device ownership between source-engine and record-engine. Initiated by `engine:play()` (or any transport-start) when the calling engine is NOT currently the value returned by `audio_playback.current_owner()`.

## The contract (two observable invariants — FR-012)

A handover is correct iff both invariants hold for the entire duration of the transport-start call:

### Invariant I1: No-overlap
At every sample-instant during the handover, the audio output stream is sourced from **at most one engine** — never two. The previously-owning engine MUST fully halt its audio output before the new engine begins producing samples (or silence, per FR-013a).

### Invariant I2: Audio-before-video
The new engine MUST NOT deliver any video frame until its audio output has started (or its `configure_silent` path has completed for video-only masters). Video does not outrun audio at the swap boundary.

### Blocking
The transport-start call (`engine:play()` and friends) blocks the calling Lua thread until both invariants hold at the call's return. Asynchronous handover is forbidden.

## Implementation freedom

Within the invariants, the implementation MAY:
- Pipeline preparation of the new engine (decoder pre-warm, TMB ready, surface binding refresh) concurrently with the previous engine's halt — as long as no audio samples flow from the new engine before the previous has stopped (I1).
- Pre-acquire the device handle if the underlying audio API supports parallel handles, as long as only one is producing samples at any sample-instant (I1).
- Skip drain entirely if the previous engine had no audio output (e.g., it was playing a video-only master) — the previous engine's halt is a no-op.

The implementation MUST NOT:
- Skip the previous-engine halt for "performance" if it WAS producing audio — I1 would break.
- Deliver video frames during the audio-acquire window — I2 would break.
- Silently absorb errors. If acquire fails, drain times out at 100 ms, or any internal step asserts, the editor crashes per existing fail-fast policy.

## Module-level audio API (`audio_playback.lua`)

The handover surface is split per rule 2.18 (FFI vs business logic separation): FFI helpers are pure C++ bindings with parameter validation only; business-logic helpers read engine state and call the FFI.

Module-private state (`_owning_engine`) is accessed **only** via public accessors — engine code never reads the field directly (rule 1.9: respect existing abstractions).

### Public accessors (read-only, no side effects)

#### `audio_playback.current_owner() -> PlaybackEngine | nil`
Returns the engine currently owning the audio device, or `nil` if idle. Pure read; no assertion (returning `nil` is a valid state, not an error).

#### `audio_playback.is_owner(engine) -> boolean`
Sugar: `current_owner() == engine`. Used by engine code to ask "do I already own audio?" without reaching into module-private state.

### Business-logic functions (public, called by `engine:play()`)

#### `audio_playback.halt_current() -> nil`
Synchronously halt the currently-owning engine's audio output. Internally: reads the module-private `_owning_engine`, calls the underlying FFI drain/stop primitive bounded by a module-internal timeout (`AUDIO_HALT_TIMEOUT_MS = 100` — named constant at the top of `audio_playback.lua`; never inlined), clears `_owning_engine` on completion. Asserts:
- `current_owner() ~= nil` (caller misuse if no current owner — engine code should ask via the public accessor before calling halt).
- Drain completes within `AUDIO_HALT_TIMEOUT_MS` (otherwise assert with elapsed time + role of the hung engine + its loaded_sequence_id).

Timeout policy is an audio-module concern (rule 1.4 single responsibility); callers do not pass or know the value. If the current owner was in silent-output mode, the underlying drain is a no-op but the function still completes deterministically and asserts on success.

Post-condition: `current_owner() == nil`; audio device is idle; no further samples produced by the previous owner.

#### `audio_playback.acquire_for(engine) -> nil`
Acquire the audio device for the given engine. Reads `engine.loaded_sequence_id`, derives the engine's bus rate/channels from `engine.sequence` (a master sequence with no audio media_refs → silent-output path per FR-013a). Calls the FFI acquire+configure. Sets `_owning_engine = engine`. Asserts:
- `_owning_engine == nil` (caller must `halt_current` first).
- `engine.loaded_sequence_id ~= nil`.
- FFI acquire returns success.

Post-condition: `_owning_engine == engine`; audio output (real or silent) is producing samples.

### FFI helpers (private, used internally by the two functions above)

#### `audio_playback._ffi_drain(timeout_ms) -> ok, err`
One-to-one wrapper around the C++ AOP drain primitive. Parameter validation only — no business logic. Returns `true` on drain complete; `false, err_string` on timeout or device error.

#### `audio_playback._ffi_acquire(rate_hz, channels) -> ok, err`
One-to-one wrapper around the C++ device acquire+configure. Parameter validation only — `rate_hz` and `channels` must be positive integers. Returns `true` on success; `false, err_string` on acquire failure.

#### `audio_playback._ffi_configure_silent() -> ok, err`
One-to-one wrapper around the C++ silent-output device acquire. No parameters. Used when the loaded sequence has no audio media (FR-013a).

The business-logic functions (`halt_current` / `acquire_for`) read engine state, decide which FFI helper(s) to call, and convert FFI failures into asserts with role/sequence context. The FFI helpers contain no application logic — they exist solely to bridge Lua to the C++ device API.

After `acquire_for` returns: `_owning_engine == engine`, audio output (real or silent) is producing samples.

## Engine play body

```lua
function engine:play()
    assert(self.state == "stopped", string.format(
        "PlaybackEngine[%s]:play: state must be 'stopped', got '%s' "
        .. "(loaded_sequence_id=%s)",
        self.role, tostring(self.state), tostring(self.loaded_sequence_id)))
    assert(self.loaded_sequence_id ~= nil, string.format(
        "PlaybackEngine[%s]:play: no sequence loaded; the command layer "
        .. "must filter Space-with-empty-target per FR-027 before reaching here",
        self.role))

    self:_ensure_audio_ownership()        -- satisfies FR-012 I1 and I2
    self.state = "playing"
    self:_start_transport_loop()          -- existing PLAYBACK.PLAY FFI path
end

function engine:_ensure_audio_ownership()
    if audio_playback.is_owner(self) then return end
    if audio_playback.current_owner() ~= nil then
        audio_playback.halt_current()     -- I1: prior owner fully halts
    end
    audio_playback.acquire_for(self)      -- I2: this engine starts audio
end
```

`engine:play()` reads as a pure 5-line algorithm (rule 2.5): assert preconditions → ensure audio ownership → mark playing → start transport. The audio-handover branching is one named helper that hides the I1/I2 sequencing. Every assert names the function, engine role, and offending value (rule 1.14). Audio-module state is touched only through public accessors (rule 1.9). The handover timeout is an audio-module concern — `halt_current` takes no parameter (rule 1.4: single responsibility); the audio module owns the timeout policy as an internal named constant.

## Coalescing of rapid tab clicks (FR-009a)

There is nothing to coalesce. Under the derived-target model (revised 2026-05-16; see contracts/transport.md), `transport.get_target()` is a pure projection of `focus_manager.get_focused_panel()` and `timeline_state.get_displayed_tab_kind()` — recomputed on every query. Tab clicks update UI state (focus, displayed pointer); they do NOT call into transport. The next `get_target()` after a burst of clicks sees the final UI state and returns the corresponding role.

Audio handover happens only when the user invokes a transport command (Space / J / K / L), at which point `get_target()` resolves to whatever side the UI currently reflects. No `_pending_target` slot, no `_handover_in_flight` flag, no `set_user_transport` setter, no cancellation primitive — the four-pointer coordination problem these would have served is structurally absent.

## Black-box contract tests (failing initially)

`tests/synthetic/contract/test_audio_handover_contract.lua` — runs under `--test` mode (real AOP/SSE). Tests tap the audio output stream (a new `--test`-only inspector returning a small ring of recently-produced samples + their source-engine tag) and verify invariants directly, not internal steps.

1. **I1 holds across a full handover**: source playing → trigger record `engine:play()` → tap audio stream → verify no sample-instant has samples from BOTH engines.
2. **I2 holds across a full handover**: same scenario → verify the timestamp of the first video frame delivered by record-engine is >= the timestamp of the first audio sample produced by record-engine.
3. **Video-only master (FR-013a)**: source-engine plays a video-only master → tap → audio stream samples are all zero/silent BUT `audio_playback.current_owner() == source_engine` throughout playback; if record was previously playing, no record samples in the stream after handover.
4. **Drain timeout asserts at 100 ms**: stub `halt_current` to hang → editor crashes at 100 ms with role + timeout context.
5. **Acquire failure asserts**: stub `acquire_for` to fail → editor crashes with role + failure cause.
6. **Idle → play (no previous owner)**: first `engine:play()` of a session → handover skips halt step, only acquires. Invariants hold trivially (no previous engine to overlap with).
7. **Same-engine re-play is idempotent**: `engine:play()` when `audio_playback.is_owner(engine)` already returns `true` → no handover work; engine plays directly. Both invariants hold (no boundary to cross).
8. **Rapid swap**: source-playing → record-play → source-play in rapid succession → tap → at most 2 handover boundaries observable in the stream, each preserving I1/I2 individually.

These tests are black-box: they observe the audio output stream and the video frame delivery timestamps. They do NOT inspect internal state like `_device_state` or step counters.
