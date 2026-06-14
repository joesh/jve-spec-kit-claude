--- models/sequence/resolver.lua — pick_in_range and its helpers (013/018).
---
--- Extracted from models/sequence.lua (~750 LOC) to keep that file
--- focused on the model surface (2.6). Public entry point is
--- M.pick_in_range; helpers are file-private.
---
--- Cross-module dependency: emit_audio_channel_entries calls
--- Sequence.count_master_audio_channels for the channel_index < master
--- channel count check inside pick_nested. We lazy-require Sequence inside that
--- helper to avoid the models.sequence ↔ models.sequence.resolver
--- top-level cycle.
---
--- Callers (Sequence:pick_in_range delegate) inject the open SQLite
--- connection; this module never opens one itself.

local subframe_math = require("core.subframe_math")

local M = {}

local function fetch_kind(db, seq_id)
    local stmt = db:prepare("SELECT kind FROM sequences WHERE id = ?")
    assert(stmt, "Sequence.resolve: kind prepare failed")
    stmt:bind_value(1, seq_id)
    assert(stmt:exec(), "Sequence.resolve: kind exec failed")
    assert(stmt:next(), string.format(
        "Sequence.resolve: sequence %s not found", tostring(seq_id)))
    local kind = stmt:value(0)
    stmt:finalize()
    return kind
end

-- Fetch a sequence's default_video_layer_track_id (may be nil).
local function fetch_default_video_layer(db, seq_id)
    local stmt = db:prepare(
        "SELECT default_video_layer_track_id FROM sequences WHERE id = ?")
    assert(stmt, "Sequence.resolve: default-layer prepare failed")
    stmt:bind_value(1, seq_id)
    assert(stmt:exec(), "Sequence.resolve: default-layer exec failed")
    local v
    if stmt:next() then v = stmt:value(0) end
    stmt:finalize()
    return v
end

-- Assert a track_id exists on the given sequence. Loud message with clip_id
-- and the dangling track (G-R5). Returns the track_type.
-- Validate a clip's track-selector reference. `selector_label` is
-- "master_layer_track_id" or "master_audio_track_id" — the column name
-- whose value is being asserted. Both selectors share the same shape
-- (FK to tracks(id) with ON DELETE SET NULL); the only difference is
-- the assert-message label per rule 1.14.
local function assert_track_ref_valid(db, clip_id, seq_id, track_id,
                                       selector_label)
    if track_id == nil then return nil end
    local stmt = db:prepare(
        "SELECT track_type, sequence_id FROM tracks WHERE id = ?")
    assert(stmt, "Sequence.resolve: track-ref prepare failed")
    stmt:bind_value(1, track_id)
    assert(stmt:exec(), "Sequence.resolve: track-ref exec failed")
    local found, ttype, tseq
    if stmt:next() then
        found = true
        ttype = stmt:value(0)
        tseq = stmt:value(1)
    end
    stmt:finalize()
    assert(found, string.format(
        "Sequence.resolve G-R5: clip %s has %s=%s that does not exist "
        .. "(dangling — FK ON DELETE SET NULL should have NULLed this; "
        .. "DB corruption?)",
        tostring(clip_id), selector_label, tostring(track_id)))
    assert(tseq == seq_id, string.format(
        "Sequence.resolve G-R5: clip %s %s=%s belongs to sequence %s, "
        .. "not the referenced sequence %s",
        tostring(clip_id), selector_label, tostring(track_id),
        tostring(tseq), tostring(seq_id)))
    return ttype
end


-- Fetch the effective channel state for a master's channel. Absent row →
-- resolver default (enabled=true, gain=0). Returns {enabled, gain_db}.
local function fetch_master_channel_state(db, master_seq_id, channel_index)
    local stmt = db:prepare([[
        SELECT enabled, default_gain_db FROM media_refs_channel_state
        WHERE owner_sequence_id = ? AND channel_index = ?
    ]])
    assert(stmt, "Sequence.resolve: master-chan-state prepare failed")
    stmt:bind_value(1, master_seq_id)
    stmt:bind_value(2, channel_index)
    assert(stmt:exec(), "Sequence.resolve: master-chan-state exec failed")
    local enabled, gain_db = true, 0.0  -- resolver default
    if stmt:next() then
        enabled = stmt:value(0) == 1
        gain_db = stmt:value(1)
    end
    stmt:finalize()
    return enabled, gain_db
end

-- Fetch per-clip channel override if present. Returns (found, enabled, gain_db).
local function fetch_clip_channel_override(db, clip_id, channel_index)
    local stmt = db:prepare([[
        SELECT enabled, gain_db FROM clip_channel_override
        WHERE clip_id = ? AND channel_index = ?
    ]])
    assert(stmt, "Sequence.resolve: clip-override prepare failed")
    stmt:bind_value(1, clip_id)
    stmt:bind_value(2, channel_index)
    assert(stmt:exec(), "Sequence.resolve: clip-override exec failed")
    local found, enabled, gain_db
    if stmt:next() then
        found = true
        enabled = stmt:value(0) == 1
        gain_db = stmt:value(1)
    end
    stmt:finalize()
    return found, enabled, gain_db
end

-- Multiply dB gains into a linear volume multiplier.
local function db_to_linear(db_gain)
    if db_gain == 0 then return 1.0 end
    return 10 ^ (db_gain / 20)
end

-- Enumerate media_refs on a master sequence, optionally filtered to a single
-- track. Each row comes back as a table.
local function list_media_refs(db, master_seq_id, only_track_id)
    -- 018 V11 / FR-004: mr.audio_sample_rate is denormalized from
    -- media.audio_sample_rate at media_ref insert. AUDIO media_refs must
    -- carry a non-NULL value (enforced at MediaRef.create — rule 2.13, no
    -- silent default). The resolver consumes it to compute file-natural
    -- sample offsets for audio entries — without it the clip-to-media-ref
    -- seam can't bridge from master.fps frames to file samples.
    local sql = [[
        SELECT mr.id, mr.track_id, mr.media_id, mr.source_in_frame, mr.source_out_frame,
               mr.sequence_start_frame, mr.duration_frames,
               mr.enabled, mr.volume,
               t.track_type, t.track_index,
               m.file_path, m.audio_channels,
               mr.audio_sample_rate
        FROM media_refs mr
        JOIN tracks t ON mr.track_id = t.id
        JOIN media m ON mr.media_id = m.id
        WHERE mr.owner_sequence_id = ?
    ]]
    if only_track_id then sql = sql .. " AND mr.track_id = ?" end
    sql = sql .. " ORDER BY t.track_type DESC, t.track_index ASC, mr.sequence_start_frame ASC"
    local stmt = db:prepare(sql)
    assert(stmt, "Sequence.resolve: list_media_refs prepare failed")
    stmt:bind_value(1, master_seq_id)
    if only_track_id then stmt:bind_value(2, only_track_id) end
    assert(stmt:exec(), "Sequence.resolve: list_media_refs exec failed")
    local rows = {}
    while stmt:next() do
        rows[#rows + 1] = {
            id = stmt:value(0),
            track_id = stmt:value(1),
            media_id = stmt:value(2),
            source_in = stmt:value(3),
            source_out = stmt:value(4),
            sequence_start = stmt:value(5),
            duration = stmt:value(6),
            enabled = stmt:value(7) == 1,
            volume = stmt:value(8),
            track_type = stmt:value(9),
            track_index = stmt:value(10),
            file_path = stmt:value(11),
            audio_channels = stmt:value(12) or 0,
            audio_sample_rate = stmt:value(13),
        }
    end
    stmt:finalize()
    return rows
end

-- Enumerate clips on a nested sequence that overlap [start, end) in this
-- sequence's timebase. Sorted by track_type (VIDEO before AUDIO) then track
-- index ascending, then sequence_start ascending — so the output of a sequence
-- with many clips is deterministic (G-R11).
local function list_clips_overlapping(db, seq_id, start_frame, end_frame)
    -- 018: source_in_subframe / source_out_subframe carry the residual
    -- master-clock ticks within the (frame, subframe) source position.
    -- The subframe columns are non-NULL on AUDIO clips, NULL on VIDEO (FR-013). The
    -- recursion seam in pick_nested threads these into the next-level
    -- pick_seq_range call so the leaf can compute file-natural samples
    -- without losing sub-frame precision.
    local stmt = db:prepare([[
        SELECT c.id, c.track_id, c.sequence_id,
               c.sequence_start_frame, c.duration_frames,
               c.source_in_frame, c.source_out_frame,
               c.source_in_subframe, c.source_out_subframe,
               c.master_layer_track_id, c.master_audio_track_id,
               c.fps_mismatch_policy,
               c.enabled, c.volume,
               t.track_type, t.track_index
        FROM clips c
        JOIN tracks t ON c.track_id = t.id
        WHERE c.owner_sequence_id = ?
          AND c.enabled = 1
          AND (c.sequence_start_frame + c.duration_frames) > ?
          AND c.sequence_start_frame < ?
        ORDER BY t.track_type DESC, t.track_index ASC,
                 c.sequence_start_frame ASC, c.id ASC
    ]])
    assert(stmt, "Sequence.resolve: list_clips prepare failed")
    stmt:bind_value(1, seq_id)
    stmt:bind_value(2, start_frame)
    stmt:bind_value(3, end_frame)
    assert(stmt:exec(), "Sequence.resolve: list_clips exec failed")
    local rows = {}
    while stmt:next() do
        rows[#rows + 1] = {
            id = stmt:value(0),
            track_id = stmt:value(1),
            sequence_id = stmt:value(2),
            sequence_start = stmt:value(3),
            duration = stmt:value(4),
            source_in = stmt:value(5),
            source_out = stmt:value(6),
            source_in_subframe = stmt:value(7),
            source_out_subframe = stmt:value(8),
            master_layer_track_id = stmt:value(9),
            master_audio_track_id = stmt:value(10),
            fps_mismatch_policy = stmt:value(11),
            enabled = stmt:value(12) == 1,
            volume = stmt:value(13),
            track_type = stmt:value(14),
            track_index = stmt:value(15),
        }
    end
    stmt:finalize()
    return rows
end

-- Build an ordered provenance array from an outer chain + a leaf id. Pure.
local function build_provenance(outer_chain, leaf_id)
    local p = {}
    for i, v in ipairs(outer_chain) do p[i] = v end
    p[#p + 1] = leaf_id
    return p
end

-- Round-nearest-integer for fractional results from owner/source ratio math.
-- Matches Insert-time rounding (data-model.md "Decisions settled here").
local function round_int(x)
    if x >= 0 then return math.floor(x + 0.5) end
    return -math.floor(-x + 0.5)
end

-- 018: read the project's master_clock_hz (FR-028) once per master leaf and
-- cache on the resolver context. Asserts non-NULL; the bg project-open path
-- guarantees the settings JSON carries it (T007).
local function fetch_master_clock_hz(db, project_id, context)
    if context.master_clock_hz then return context.master_clock_hz end
    assert(project_id and project_id ~= "",
        "Sequence.resolve: project_id required to read master_clock_hz")
    local stmt = db:prepare(
        "SELECT json_extract(settings, '$.master_clock_hz') FROM projects WHERE id = ?")
    assert(stmt, "Sequence.resolve: master_clock_hz prepare failed")
    stmt:bind_value(1, project_id)
    assert(stmt:exec(), "Sequence.resolve: master_clock_hz exec failed")
    local mch
    if stmt:next() then mch = stmt:value(0) end
    stmt:finalize()
    assert(mch and mch > 0, string.format(
        "Sequence.resolve: project %s has no master_clock_hz in settings "
        .. "(018 T007 must run at project open)", tostring(project_id)))
    context.master_clock_hz = mch
    return mch
end

-- 018: master sequence's fps. Cached on context per seq_id to avoid repeat
-- SQL inside the per-media_ref loop.
local function fetch_master_fps(db, seq_id, context)
    context.master_fps_cache = context.master_fps_cache or {}
    local cached = context.master_fps_cache[seq_id]
    if cached then return cached.num, cached.den, cached.project_id end
    local stmt = db:prepare(
        "SELECT fps_numerator, fps_denominator, project_id FROM sequences WHERE id = ?")
    assert(stmt, "Sequence.resolve: master fps prepare failed")
    stmt:bind_value(1, seq_id)
    assert(stmt:exec(), "Sequence.resolve: master fps exec failed")
    assert(stmt:next(), string.format(
        "Sequence.resolve: sequence %s not found", tostring(seq_id)))
    local num, den, proj = stmt:value(0), stmt:value(1), stmt:value(2)
    stmt:finalize()
    assert(num and num > 0 and den and den > 0, string.format(
        "Sequence.resolve: sequence %s has invalid fps %s/%s",
        tostring(seq_id), tostring(num), tostring(den)))
    context.master_fps_cache[seq_id] = { num = num, den = den, project_id = proj }
    return num, den, proj
end

-- Total master-clock ticks for a (frame, subframe) pair at a given tpf.
-- Used both for overlap comparison and as the input to ticks_to_samples.
local function pack_pos_ticks(frame, subframe, tpf)
    return frame * tpf + subframe
end

-- Whether the [mr.start, mr.end) frame extent (treated as subframe=0 at both
-- endpoints) overlaps the request's (frame, subframe) range. Comparison is in
-- packed master-clock-tick space so sub-frame range endpoints are honored.
local function mref_overlaps_request(r, lo_f, lo_s, hi_f, hi_s, tpf)
    local r_lo_ticks = pack_pos_ticks(r.sequence_start, 0, tpf)
    local r_hi_ticks = pack_pos_ticks(r.sequence_start + r.duration, 0, tpf)
    local req_lo_ticks = pack_pos_ticks(lo_f, lo_s, tpf)
    local req_hi_ticks = pack_pos_ticks(hi_f, hi_s, tpf)
    return r_hi_ticks > req_lo_ticks and r_lo_ticks < req_hi_ticks
end

-- Apply the layer / audio-track-selector filter at this level (FR-005, FR-023).
-- Returns true if this mr passes; false if a filter excludes it.
local function mref_passes_filter(r, layer_track_id, audio_track_id)
    if r.track_type == "VIDEO" and layer_track_id ~= nil then
        return r.track_id == layer_track_id
    end
    if r.track_type == "AUDIO" and audio_track_id ~= nil then
        return r.track_id == audio_track_id
    end
    return true
end

-- Clip the request range to the media_ref's [start, end) extent. When the
-- mref boundary takes over, the corresponding subframe is 0 (the request
-- entered the mref at a whole-frame boundary on the mref side).
local function clip_to_mref_extent(r, lo_f, lo_s, hi_f, hi_s)
    local r_lo, r_hi = r.sequence_start, r.sequence_start + r.duration
    local out_lo_f, out_lo_s, out_hi_f, out_hi_s
    if lo_f < r_lo then
        out_lo_f, out_lo_s = r_lo, 0
    else
        out_lo_f, out_lo_s = lo_f, lo_s
    end
    if hi_f > r_hi or (hi_f == r_hi and hi_s > 0) then
        out_hi_f, out_hi_s = r_hi, 0
    else
        out_hi_f, out_hi_s = hi_f, hi_s
    end
    return out_lo_f, out_lo_s, out_hi_f, out_hi_s
end

-- Compute the file-natural source position for a VIDEO media_ref. Video files
-- share the master.fps frame timebase for source positions (FR-003) — subframe
-- is irrelevant on video (video is frame-quantized).
local function compute_video_source_range(r, lo_f, hi_f)
    local file_in  = r.source_in + (lo_f - r.sequence_start)
    local file_out = r.source_in + (hi_f - r.sequence_start)
    return file_in, file_out
end

-- Compute the file-natural sample position for an AUDIO media_ref. Per
-- data-model.md "Resolution to file-natural sample":
--     file_sample = mr.source_in (file-natural samples)
--                 + ticks_to_samples(frame_delta * tpf + subframe,
--                                    mr.audio_sample_rate, master_clock_hz)
-- Composes the whole-frame contribution and the sub-frame residual into a
-- single round in the math primitive (FR-008 single-rounding-rule).
local function compute_audio_source_sample(r, master_frame, master_subframe,
                                            tpf, master_clock_hz)
    local frame_delta = master_frame - r.sequence_start
    assert(frame_delta >= 0, string.format(
        "Sequence.resolve compute_audio_source_sample: frame_delta < 0 "
        .. "(master_frame=%d, mr.sequence_start=%d, mr=%s)",
        master_frame, r.sequence_start, tostring(r.id)))
    assert(r.audio_sample_rate and r.audio_sample_rate > 0, string.format(
        "Sequence.resolve: media_ref %s on AUDIO track lacks audio_sample_rate (FR-004)",
        tostring(r.id)))
    local total_ticks = subframe_math.pack(frame_delta, master_subframe, tpf)
    return r.source_in + subframe_math.ticks_to_samples(
        total_ticks, r.audio_sample_rate, master_clock_hz)
end

-- Build the entry base shared by every emission from one media_ref. The base
-- carries master-coord sequence_start/duration (pick_nested translates to
-- outer-coord) and file-natural source_in/source_out.
--
-- Pass media_path AND user-set enabled state through unchanged regardless of
-- online/offline. Offline routing is the responsibility of downstream
-- consumers: playback_engine._build_tmb_clip queries media_status.get and
-- sets ClipInfo.offline=true on the TMB clip; timeline_view_renderer +
-- offline_frame_cache key on media_path to render the OFFLINE overlay.
local function build_mref_entry_base(r, lo_f, hi_f, file_in, file_out, outer_chain)
    return {
        media_path     = r.file_path,
        media_id       = r.media_id,
        source_in      = file_in,
        source_out     = file_out,
        sequence_start = lo_f,        -- master coords; outer translates
        duration       = hi_f - lo_f, -- master coords (integer frames)
        volume         = r.volume,
        enabled        = r.enabled,
        effects        = {},
        provenance     = build_provenance(outer_chain, r.id),
        -- Default owner-track tagging for the case where this master is the
        -- outermost sequence (e.g. source viewer playing the master directly).
        -- pick_nested overwrites these when recursion bubbles outwards.
        owner_track_index = r.track_index,
        owner_track_type  = r.track_type,
        owner_clip_id     = r.id,
    }
end

local function emit_video_entry(entries, r, base)
    base.media_kind    = "video"
    base.track_role    = "video"
    base.channel_index = nil
    entries[#entries + 1] = base
end

-- One audio entry per channel. Channel-state stays separate from volume
-- until the final composition pass — any clip in the chain may replace it
-- via clip_channel_override without needing to divide out a stale factor.
local function emit_audio_channel_entries(entries, r, base, db, master_seq_id, outer_chain)
    -- Resolver invariant: AUDIO mrefs MUST carry audio_sample_rate (FR-004 /
    -- schema trigger). Surface at the resolver — downstream consumers (TMB
    -- feeder, audio_playback) need it and shouldn't have to re-assert.
    assert(type(r.audio_sample_rate) == "number" and r.audio_sample_rate > 0,
        string.format("emit_audio_channel_entries: mref %s missing audio_sample_rate "
            .. "(track=%s; AUDIO media_refs require it per FR-004)",
            tostring(r.id), tostring(r.track_id)))
    -- Audio media_refs MUST carry channel count (FR-004 / schema trigger).
    -- A 0 / nil here means the importer didn't populate it — fail loud.
    assert(type(r.audio_channels) == "number" and r.audio_channels > 0,
        string.format("emit_audio_channel_entries: mref %s has audio_channels=%s "
            .. "(track=%s; AUDIO media_refs require a positive channel count per FR-004)",
            tostring(r.id), tostring(r.audio_channels), tostring(r.track_id)))
    local n_ch = r.audio_channels
    for ch = 0, n_ch - 1 do
        local ms_enabled, ms_gain_db =
            fetch_master_channel_state(db, master_seq_id, ch)
        entries[#entries + 1] = {
            media_path     = base.media_path,
            media_id       = base.media_id,
            media_kind     = "audio",
            source_in      = base.source_in,
            source_out     = base.source_out,
            sequence_start = base.sequence_start,
            duration       = base.duration,
            track_role     = "audio",
            channel_index  = ch,
            volume         = base.volume,
            enabled        = base.enabled,
            effects        = {},
            provenance     = build_provenance(outer_chain, r.id),
            owner_track_index = r.track_index,
            owner_track_type  = r.track_type,
            owner_clip_id     = r.id,
            channel_state  = { enabled = ms_enabled, gain_db = ms_gain_db },
            -- 018 FR-004 / FR-008: AUDIO entries carry the mref's denormalized
            -- audio_sample_rate so the playback engine's TMB feeder can match
            -- it against source_in (file-natural samples). Without this the
            -- decoder seeks using video fps and lands far past EOF — F10 silent.
            audio_sample_rate = r.audio_sample_rate,
        }
    end
end

-- Compute one media_ref's file-natural source range AND its master-frame
-- extent for a request sub-range already clipped to the mref. Single place
-- that knows playback DIRECTION, because reverse needs sample-accurate math
-- (the +1 native unit below) and the audio sample rate — both of which live
-- here at the leaf, not up at pick_nested (018 single-rounding-rule; the
-- inter-layer currency stays (frame, subframe)).
--
-- Forward: source ascends with the request; extent is the request's frames.
-- Reverse (request HIGH > LOW in tick space): the request's HIGH end is the
-- inclusive entry source position and the LOW end is the exclusive lower
-- bound, so source descends (source_in > source_out) and the played extent is
-- each exclusive bound shifted up by ONE native unit — one frame for video,
-- one sample for audio — recovering the inclusive-high / exclusive-low played
-- region the importer's reverse convention encodes. (+1 sample is why this
-- can't live at pick_nested: it needs the rate, and +1 frame is wrong for
-- sub-frame audio source positions.)
local function resolve_mref_source_and_extent(r, reversed,
        m_lo_f, m_lo_s, m_hi_f, m_hi_s, tpf, master_clock_hz)
    local is_video = (r.track_type == "VIDEO")
    if reversed then
        local file_in, file_out
        if is_video then
            file_in, file_out = compute_video_source_range(r, m_hi_f, m_lo_f)
        else
            file_in  = compute_audio_source_sample(r, m_hi_f, m_hi_s, tpf, master_clock_hz)
            file_out = compute_audio_source_sample(r, m_lo_f, m_lo_s, tpf, master_clock_hz)
        end
        local one_unit = is_video and tpf
            or subframe_math.samples_to_ticks(1, r.audio_sample_rate, master_clock_hz)
        local lo_played = math.floor(
            (pack_pos_ticks(m_lo_f, m_lo_s, tpf) + one_unit) / tpf)
        local hi_played = math.floor(
            (pack_pos_ticks(m_hi_f, m_hi_s, tpf) + one_unit) / tpf)
        return file_in, file_out, lo_played, hi_played
    end
    local file_in, file_out
    if is_video then
        file_in, file_out = compute_video_source_range(r, m_lo_f, m_hi_f)
    else
        file_in  = compute_audio_source_sample(r, m_lo_f, m_lo_s, tpf, master_clock_hz)
        file_out = compute_audio_source_sample(r, m_hi_f, m_hi_s, tpf, master_clock_hz)
    end
    return file_in, file_out, m_lo_f, m_hi_f
end

-- Resolve a master sequence over a request range expressed as (frame, subframe)
-- endpoints in the master's own fps timebase + project master-clock ticks.
-- Iterate media_refs that overlap; emit one ResolvedEntry per row (V) or per
-- channel (A). Video entries' file-source range stays in master.fps frames
-- (FR-003); audio entries are sample-precise via subframe_math (FR-008).
-- Direction-aware: a reverse request (HIGH > LOW) yields descending source.
--
-- Track selectors (symmetric per FR-005 / FR-023):
--   layer_track_id    — non-nil restricts V media_refs to that track.
--   audio_track_id    — non-nil restricts A media_refs to that track
--                       (Expand/Collapse audio path). nil = composite.
local function pick_master_leaf(db, seq_id, lo_f, lo_s, hi_f, hi_s,
                                   layer_track_id, audio_track_id,
                                   outer_chain, context)
    assert(type(context) == "table",
        "Sequence.pick_master_leaf: context table required (018 master_clock_hz)")
    local fps_num, fps_den, project_id = fetch_master_fps(db, seq_id, context)
    local master_clock_hz = fetch_master_clock_hz(db, project_id, context)
    local tpf = subframe_math.ticks_per_frame(master_clock_hz, fps_num, fps_den)

    -- Direction is a property of the request: a reverse clip hands down its
    -- natural window (source_in > source_out) so HIGH > LOW in tick space.
    -- Overlap + clipping work on ascending bounds; direction is re-applied
    -- per-mref inside resolve_mref_source_and_extent.
    local reversed =
        pack_pos_ticks(lo_f, lo_s, tpf) > pack_pos_ticks(hi_f, hi_s, tpf)
    local a_lo_f, a_lo_s, a_hi_f, a_hi_s
    if reversed then
        a_lo_f, a_lo_s, a_hi_f, a_hi_s = hi_f, hi_s, lo_f, lo_s
    else
        a_lo_f, a_lo_s, a_hi_f, a_hi_s = lo_f, lo_s, hi_f, hi_s
    end

    local entries = {}
    for _, r in ipairs(list_media_refs(db, seq_id, nil)) do
        if mref_passes_filter(r, layer_track_id, audio_track_id)
           and mref_overlaps_request(r, a_lo_f, a_lo_s, a_hi_f, a_hi_s, tpf) then
            local m_lo_f, m_lo_s, m_hi_f, m_hi_s =
                clip_to_mref_extent(r, a_lo_f, a_lo_s, a_hi_f, a_hi_s)
            local file_in, file_out, seq_start_f, seq_end_f =
                resolve_mref_source_and_extent(r, reversed,
                    m_lo_f, m_lo_s, m_hi_f, m_hi_s, tpf, master_clock_hz)
            local base = build_mref_entry_base(r, seq_start_f, seq_end_f,
                file_in, file_out, outer_chain)
            if r.track_type == "VIDEO" then
                emit_video_entry(entries, r, base)
            else
                emit_audio_channel_entries(entries, r, base, db, seq_id, outer_chain)
            end
        end
    end
    return entries
end

-- Forward declaration so pick_nested can call pick_seq_range recursively.
local pick_seq_range

-- Translate one in-flight entry's master-coord position to outer-coord using
-- a clip's own source/owner ratio. Mutates in place and returns the entry.
local function translate_to_outer(e, c, source_lo)
    -- Owner-frames-per-source-frame ratio for this clip; defined exactly
    -- by the row regardless of fps_mismatch_policy (the policy was applied
    -- at Insert/Set time when c.duration_frames was written).
    local source_span = c.source_out - c.source_in
    local owner_per_source = c.duration / source_span

    if owner_per_source < 0 then
        -- Reversed clip: inner low frame → outer high frame, inner high → outer low.
        -- The outer-start corresponds to the HIGHEST inner frame (= e.sequence_start
        -- + e.duration - 1) because the clip traverses source in descending order.
        local abs_opr    = -owner_per_source
        local inner_last = e.sequence_start + e.duration - 1
        e.sequence_start = c.sequence_start
            + round_int((c.source_in - inner_last) * abs_opr)
        e.duration       = round_int(e.duration * abs_opr)
    else
        local outer_offset_lo = (e.sequence_start - source_lo) * owner_per_source
        local outer_dur       = e.duration * owner_per_source
        e.sequence_start = c.sequence_start + round_int(outer_offset_lo
            + (source_lo - c.source_in) * owner_per_source)
        e.duration       = round_int(outer_dur)
    end
    return e
end

-- Resolve a nested sequence over an outer-coord range [outer_lo, outer_hi).
-- For each overlapping clip:
--   * compute the master-coord (= nested-coord) sub-range to recurse into;
--   * recurse, applying any layer override at the directly-referenced level;
--   * filter inner entries by the clip's own track type (no double counting);
--   * translate each entry from master-coord positioning to outer-coord;
--   * fold clip.volume into the entry's volume; AND clip.enabled into enabled;
--   * for audio entries, replace channel_state with this clip's override row
--     when present (per-channel — sparse table; absent row = inherit).
local function pick_nested(db, seq_id, outer_lo_f, outer_lo_s,
                              outer_hi_f, outer_hi_s, context,
                              outer_chain, layer_filter_for_v,
                              audio_filter_for_a)
    local entries = {}
    -- A reversed REQUEST (HIGH > LOW) only arises when a reversed clip
    -- recurses into the sequence it references. Reverse is resolved at the
    -- master leaf (direction-aware), so a reversed range reaching this
    -- sequence-of-sequences layer means a reversed clip references a NESTED
    -- (non-master) sequence — a case the nested path does not yet handle.
    -- Fail loud rather than silently returning nothing (1.14).
    assert(outer_lo_f <= outer_hi_f, string.format(
        "Sequence.pick_nested: reversed request [%d,%d) into nested sequence %s "
        .. "— reversed clips referencing nested sequences are not supported "
        .. "(reverse is resolved at the master leaf).",
        outer_lo_f, outer_hi_f, tostring(seq_id)))
    -- 018: clip overlap is still resolved on integer frame extents (the
    -- query bound). Subframe granularity at the outer endpoints can only
    -- include clips that frame-overlap; sub-frame-only overlap on this
    -- (sequence-of-sequences) layer is impossible because clip endpoints
    -- and the outer query are themselves at frame granularity for
    -- list_clips_overlapping. Subframe enters the math at the master leaf.
    local clips = list_clips_overlapping(db, seq_id, outer_lo_f, outer_hi_f)
    for _, c in ipairs(clips) do
        -- Layer filter at THIS level: filter clips whose track_type is VIDEO
        -- to the chosen V track only. Symmetrically filter AUDIO clips by
        -- the audio-track filter when one is in effect (Expand/Collapse).
        local v_filtered = (c.track_type == "VIDEO")
                       and layer_filter_for_v ~= nil
                       and c.track_id ~= layer_filter_for_v
        local a_filtered = (c.track_type == "AUDIO")
                       and audio_filter_for_a ~= nil
                       and c.track_id ~= audio_filter_for_a
        if not v_filtered and not a_filtered then
            -- G-R5 selector validation: both V layer and A audio track,
            -- if non-NULL, must point at a live track of c.sequence_id.
            if c.master_layer_track_id then
                assert_track_ref_valid(db, c.id, c.sequence_id,
                    c.master_layer_track_id, "master_layer_track_id")
            end
            if c.master_audio_track_id then
                assert_track_ref_valid(db, c.id, c.sequence_id,
                    c.master_audio_track_id, "master_audio_track_id")
            end

            -- channel_index must be < master's audio channel count.
            -- Iterate the clip's overrides (if any) and assert each is in
            -- bounds. For first-landing this checks only when the clip
            -- directly references a master (kind='master') so we have a
            -- concrete channel count; nested-of-nested defers to the
            -- master at its leaf via the recursion's downstream check
            -- on whatever clips the inner sequence holds.
            do
                local kind_stmt = db:prepare(
                    "SELECT kind FROM sequences WHERE id = ?")
                assert(kind_stmt, "Sequence.resolve (channel_index < master audio channel count): kind prepare failed")
                kind_stmt:bind_value(1, c.sequence_id)
                assert(kind_stmt:exec(), "Sequence.resolve (channel_index < master audio channel count): kind exec failed")
                local nk
                if kind_stmt:next() then nk = kind_stmt:value(0) end
                kind_stmt:finalize()
                if nk == "master" then
                    local channel_count = require("models.sequence").count_master_audio_channels(
                        c.sequence_id)
                    local Override = require("models.clip_channel_override")
                    for _, ov in ipairs(Override.find_all(c.id)) do
                        assert(ov.channel_index < channel_count, string.format(
                            "Sequence.resolve: channel_index must be < master's audio channel count: clip %s has "
                            .. "clip_channel_override(channel_index=%d) but "
                            .. "the referenced master sequence %s has only "
                            .. "%d audio channel(s). The master likely "
                            .. "shrank since the override was set; clear "
                            .. "or migrate the override.",
                            c.id, ov.channel_index,
                            c.sequence_id, channel_count))
                    end
                end
            end

            -- Layer to expose at the level THIS clip directly references.
            -- NULL → inherit the referenced sequence's default; explicit →
            -- this clip's per-clip override.
            local layer_for_inner = c.master_layer_track_id
            if layer_for_inner == nil then
                layer_for_inner = fetch_default_video_layer(db, c.sequence_id)
            end

            -- Audio-track selector at THIS clip's directly-referenced level.
            -- NULL = composite (today's behavior — no restriction). Non-NULL
            -- = single-track (Expand). There is no sequence-level "default
            -- audio track" symmetric to default_video_layer_track_id;
            -- composite IS the default.
            local audio_for_inner = c.master_audio_track_id

            -- Compute the source-coord (= nested-timebase) sub-range to
            -- recurse into, derived from the outer-coord intersection.
            -- Recurse over the FULL source-window the clip exposes
            -- ([c.source_in, c.source_out)), NOT intersected with the
            -- caller's playback window. The wrapper layer
            -- (get_video_in_range / get_audio_in_range) uses outer_lo /
            -- outer_hi as a clip-overlap filter; once a clip is in scope
            -- it's returned at its full owner-coord extent so consumers
            -- (TMB) get the complete clip and can play through without
            -- a re-fetch every frame. Pre-013 had this contract; the
            -- intersect-with-window form was a 013 regression that made
            -- TMB get 1-frame slices.
            local inner_chain = {}
            for i, v in ipairs(outer_chain) do inner_chain[i] = v end
            inner_chain[#inner_chain + 1] = c.id

            -- 018 (FR-013): thread sub-frame through the recursion seam.
            -- VIDEO clips have NULL subframes (no sub-frame concept on video);
            -- the explicit 0 here carries the "no sub-frame component" intent
            -- into the audio-leaf math (which ignores it for video entries).
            -- AUDIO clips MUST have non-NULL subframes; the load path asserts this.
            local c_lo_s, c_hi_s
            if c.track_type == "AUDIO" then
                assert(c.source_in_subframe ~= nil and c.source_out_subframe ~= nil,
                    string.format(
                    "Sequence.resolve: audio clip %s has NULL subframe(s)",
                    tostring(c.id)))
                c_lo_s, c_hi_s = c.source_in_subframe, c.source_out_subframe
            else
                assert(c.source_in_subframe == nil and c.source_out_subframe == nil,
                    string.format(
                    "Sequence.resolve: video clip %s has non-NULL subframe(s)",
                    tostring(c.id)))
                c_lo_s, c_hi_s = 0, 0
            end

            -- Pass the clip's NATURAL source window — no direction
            -- normalization here. Forward clips give source_in < source_out;
            -- reverse clips (DRP importer stores source_in > source_out to
            -- signal backward playback) give source_in > source_out. The
            -- master leaf is direction-aware: it resolves descending source
            -- and emits an entry with source_in > source_out, sample-accurate
            -- for audio (the +1-native-unit math needs the rate, which only
            -- the leaf has). Uniform across VIDEO and AUDIO — no per-medium
            -- reverse branch, no entry restoration.
            local inner = pick_seq_range(db, c.sequence_id,
                c.source_in, c_lo_s, c.source_out, c_hi_s,
                context, inner_chain,
                layer_for_inner, audio_for_inner)

            -- No double-counting: V clips materialize only V media; A only A.
            local want_kind = (c.track_type == "VIDEO") and "video" or "audio"
            for _, e in ipairs(inner) do
                if e.media_kind == want_kind then
                    -- Translate master-coord -> outer-coord; the inner
                    -- entry's sequence_start/duration are in this clip's
                    -- nested-timebase, so we use this clip's source ratio.
                    translate_to_outer(e, c, c.source_in)

                    -- Tag entry with the outermost owning clip's track so
                    -- consumers (playback TMB routing) know which timeline
                    -- track to address. Recursion bubbles outwards — each
                    -- enclosing pick_nested overwrites, so the topmost
                    -- (outermost) call wins.
                    e.owner_track_index = c.track_index
                    e.owner_track_type  = c.track_type
                    e.owner_clip_id     = c.id

                    -- Fold this clip's own volume + enabled into the chain.
                    e.volume  = e.volume * c.volume
                    e.enabled = e.enabled and c.enabled

                    -- Per-clip audio channel override: if this clip has a
                    -- row for the entry's channel, REPLACE the channel_state
                    -- (the override is the channel state of record at this
                    -- level — no divide-out gymnastics, no master-leaf
                    -- divisor problem at depth > 1).
                    if e.media_kind == "audio" and e.channel_index ~= nil then
                        local found, ov_enabled, ov_gain_db =
                            fetch_clip_channel_override(db, c.id, e.channel_index)
                        if found then
                            e.channel_state = {
                                enabled = ov_enabled, gain_db = ov_gain_db,
                            }
                        end
                    end

                    entries[#entries + 1] = e
                end
            end
        end
    end
    return entries
end

-- The resolver dispatch. Reads as a high-level algorithm (rule 2.5).
-- `layer_for_directly_referenced` and `audio_for_directly_referenced` are
-- the V / A track selectors that apply at the directly-referenced level
-- (master leaf or nested clip filter). NULL = composite/default for that
-- medium.
pick_seq_range = function(db, seq_id, lo_f, lo_s, hi_f, hi_s, context,
                             outer_chain,
                             layer_for_directly_referenced,
                             audio_for_directly_referenced)
    -- Cycle guard (G-R2). Loud assert with provenance chain.
    assert(not context.recursing_into[seq_id], string.format(
        "Sequence.resolve G-R2: cycle detected in chain — sequence %s is already "
        .. "being resolved. provenance=[%s]",
        tostring(seq_id), table.concat(outer_chain, ", ")))
    context.recursing_into[seq_id] = true

    local kind = fetch_kind(db, seq_id)
    local entries
    if kind == "master" then
        entries = pick_master_leaf(db, seq_id, lo_f, lo_s, hi_f, hi_s,
            layer_for_directly_referenced,
            audio_for_directly_referenced,
            outer_chain, context)
    else
        entries = pick_nested(db, seq_id, lo_f, lo_s, hi_f, hi_s,
            context, outer_chain,
            layer_for_directly_referenced,
            audio_for_directly_referenced)
    end

    context.recursing_into[seq_id] = nil
    return entries
end

-- Compose channel_state into the final volume/enabled for audio entries,
-- then strip the internal field. Called once at the public boundary.
local function finalize_entries(entries)
    for _, e in ipairs(entries) do
        if e.channel_state ~= nil then
            e.volume  = e.volume * db_to_linear(e.channel_state.gain_db)
            e.enabled = e.enabled and e.channel_state.enabled
            e.channel_state = nil
        end
    end
    return entries
end

-- Public boundary: callers pass integer-frame range endpoints. The resolver
-- internally threads (frame, subframe) pairs; sub-frame at the public
-- endpoint is implicitly 0 (FR-013 — today's marks UX is frame-aligned).
-- The actual sub-frame contribution enters at every recursion seam where
-- a clip's stored source_in_subframe / source_out_subframe is consumed.
function M.pick_in_range(db, seq_id, start_frame, end_frame, context)
    assert(seq_id, "Sequence:pick_in_range: seq_id required")
    assert(type(start_frame) == "number", "start_frame must be number")
    assert(type(end_frame) == "number", "end_frame must be number")
    assert(type(context) == "table", "context table required")
    context.recursing_into = context.recursing_into or {}
    local entries = pick_seq_range(db, seq_id,
        start_frame, 0, end_frame, 0,
        context, {}, nil, nil)
    return finalize_entries(entries)
end

return M
