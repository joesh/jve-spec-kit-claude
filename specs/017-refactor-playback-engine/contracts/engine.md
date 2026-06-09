# Contract: `core.playback.playback_engine` module (refactored)

**Feature**: 017 | **Phase**: 1 | **File**: `src/lua/core/playback/playback_engine.lua` (MODIFIED)

The engine is no longer view-owned. It's a role-bound singleton constructed once by `transport.init`. Lifecycle methods (`load`/`unload`) replace today's implicit "engine is loaded for its monitor's saved seq_id" assumption.

## Construction

### `PlaybackEngine.new(role) -> PlaybackEngine`
Constructs the singleton. Asserts:
- `role ∈ {"source", "record"}`.
- Audio module initialized (existing precondition, retained).

Sets:
- `self.role = role` (immutable thereafter).
- `self.loaded_sequence_id = nil`.
- `self.state = "stopped"`.
- `self._log_tag = role .. ":unloaded"` (replaced on load).
- Constructs `self._playback_controller` (C++) and sets log tag via `qt_constants.PLAYBACK.SET_LOG_TAG(...)`.

## Public lifecycle API

### `engine:load(sequence_id) -> nil`
Replaces today's overloaded `load_sequence`. Reads playhead from Model, configures TMB and PlaybackController bounds, parks at saved playhead. The audio bus rate is derived internally from the loaded sequence's `audio_sample_rate` (or routed to the silent-output path for video-only masters per FR-013a) — callers do NOT pass a rate. The existing `resolve_output_audio_rate` helper in `SequenceMonitor` (which forwarded the active record's bus rate so a video-only master could "borrow" it across monitors) is DELETED: with role-bound engines + synchronous handover, each engine configures the device for its own sequence on every transport-start.

Asserts:
- `sequence_id` is a non-empty string.
- `Sequence.load(sequence_id)` returns non-nil row (existing assert, retained).
- Sequence kind matches engine role: source-engine ⇒ `kind == "master"`; record-engine ⇒ `kind == "sequence"`. (NEW assert per FR-001 invariant.)
- Not currently playing (`self.state == "stopped"`) — caller must `stop()` first; `load` does NOT silently stop active playback.

Side effects:
- If `self.loaded_sequence_id` is non-nil, writes its playhead back to that sequence's Model row first (FR-007).
- Sets `self.loaded_sequence_id = sequence_id`.
- Reads `seq.playhead_frame` from Model; calls `self:seek(seq.playhead_frame)` to park at it.
- Recomputes `self._log_tag = role .. ":" .. sequence_id:sub(1, LOG_TAG_ID_PREFIX_LEN)` where `LOG_TAG_ID_PREFIX_LEN = 8` is a module-level named constant (rule 1.5 spirit: no magic literal in the formatter) (FR-022).
- Pushes new log tag to C++ via `qt_constants.PLAYBACK.SET_LOG_TAG(self._playback_controller, self._log_tag)`.

### `engine:unload() -> nil`
Releases the loaded sequence. Asserts:
- Not currently playing.
- `loaded_sequence_id` is non-nil (calling `unload` twice asserts).

Side effects:
- Writes current playhead to Model.
- Closes TMB, resets PlaybackController bounds.
- Sets `loaded_sequence_id = nil`, `_log_tag = role .. ":unloaded"`.

## Public transport API (semantics unchanged from today; ownership refactored)

### `engine:play() -> nil`
Asserts:
- `loaded_sequence_id` non-nil (otherwise FR-027 no-op is implemented at the command layer, NOT here — engine `play` on empty asserts).
- `self.state == "stopped"` (idempotent re-play asserts; caller must check).

Side effects:
- Refresh content bounds (existing).
- Take audio device ownership via the two-invariant handover (see `audio_handover.md`: `halt_current` if a prior owner exists, then `acquire_for(self)`).
- Start CVDisplayLink + decode pump.
- Begin emitting `frame_delivered` signals (views observing this engine pick them up).

### `engine:stop() -> nil`
- Asserts `self.state == "playing"` (idempotent stop asserts — caller must check).
- Halts CVDisplayLink, drains audio, releases audio device.
- Writes current playhead to Model (FR-007).
- `self.state = "stopped"`.

### `engine:shuttle(direction) -> nil`, `engine:slow_play(direction) -> nil`
Existing semantics retained. Both must own audio device per FR-011 (use same handover protocol).

### `engine:seek(frame) -> nil`
Park-mode seek. Updates `self._position`, writes to PlaybackController (`PLAYBACK.PARK`), fires single decode. Does NOT trigger audio handover (no audio output during park). Asserts:
- `frame` is non-nil and a number.
- `self.sequence ~= nil` (a sequence must be loaded).
- `self.fps_num` and `self.fps_den` are set (load_sequence completed).
- `frame >= self.start_frame` — mirrors the C++ `PlaybackController::Park` invariant (`frame >= m_start_frame`) one layer up with Lua-side context (role, loaded_sequence_id, attempted frame, required start_frame). Without this Lua-side gate, bad callers (deferred timers that captured a stale playhead, pre-clamp model writes) crash deep in C++ with no actionable context. TSO 2026-05-17 regression — `tests/test_engine_seek_asserts_below_start_frame.lua` pins the assert path.

## Forbidden behaviors

- Engine MUST NOT consult any view widget, focus state, or `displayed_tab_id`. It only knows its `role` and its `loaded_sequence_id`.
- No method may silently fall back. `seq.start_timecode_frame or 0` (current code) is DELETED — column is NOT NULL with DB default 0, so the value is always present.
- `play` on an engine with `loaded_sequence_id == nil` asserts; it does NOT no-op. (The no-op for "Space with nothing loaded" is implemented at the command-dispatch layer in `core.commands.playback`, BEFORE reaching the engine — see `audio_handover.md` and the command layer contract.)

## Deleted methods (from current `playback_engine.lua`)

- `engine:activate_audio()` — replaced by handover protocol.
- `engine:deactivate_audio()` — replaced by handover protocol.
- `self._audio_owner` field — deleted; structural ownership lives in `audio_playback`'s module-private state, accessed by engines only through the public accessors `audio_playback.current_owner()` and `audio_playback.is_owner(engine)`.

## Contract tests (failing initially)

`tests/synthetic/contract/test_engine_contract.lua`:
1. `PlaybackEngine.new("garbage")` asserts.
2. `PlaybackEngine.new("source")` returns object with `role == "source"`, `loaded_sequence_id == nil`, `state == "stopped"`.
3. `engine:play()` before `load` asserts.
4. `engine:load(nil)` asserts; `engine:load("nonexistent-id")` asserts.
5. Source-engine `engine:load(record_seq_id)` asserts (kind mismatch).
6. Record-engine `engine:load(master_seq_id)` asserts (kind mismatch).
7. `engine:load(seq_id)` then `engine:play()` then `engine:load(other_id)` — `engine:load(other_id)` asserts because engine is playing.
8. `engine:load(seq_a)` → `engine:load(seq_b)` (while parked) → seq_a's playhead was written back to Model before seq_b was loaded.
9. `engine:unload()` twice asserts.
10. After `engine:load(seq_id)`, the C++ `PlaybackController` has log tag `"source:" .. seq_id:sub(1,8)` (or `"record:..."`).
