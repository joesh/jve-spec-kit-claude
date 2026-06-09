--- timeline_dsl.lua — ASCII timeline parser + TMB clip-entry renderer.
--
-- Format (one track per line):
--   V1: [name1 start-end][name2 start-end]...
--   A1: [name3 start-end]...
--
-- Track names: V<N> = video, A<N> = audio (N is the track number).
-- Clip syntax: [Name start-end]  (name = non-whitespace, start/end = integer frames).
-- Gaps are implicit where no clip covers a range.
--
-- Two renderers ship with this module:
--   M.parse(text) — pure parser, returns {tracks = {...}, track_order = {...}}
--   M.to_tmb(parsed, opts) — emits TMB clip entries grouped by track number, for
--     tests that hand clips directly to EMP.TMB_SET_TRACK_CLIPS (no DB layer).
--
-- The DB-backed ripple test runner has its own renderer in
-- tests/synthetic/helpers/ripple_test_runner.lua; both renderers share this
-- parser so the DSL stays consistent across test suites.

local M = {}

--- Parse a timeline text into a structured form.
-- @param text string: e.g. "V1: [A 0-100][B 100-400]\nA1: [D 0-600]"
-- @return table: {
--     tracks = { ["V1"] = {{name, start, end_pos}, ...}, ... },
--     track_order = { "V1", "A1", ... }  -- preserves declaration order
--   }
function M.parse(text)
    assert(type(text) == "string", "timeline_dsl.parse: text must be a string")
    local tracks = {}
    local track_order = {}
    for line in text:gmatch("[^\n]+") do
        local track_name, body = line:match("^%s*(%S+):%s*(.+)%s*$")
        if track_name and body then
            local clips = {}
            for name, s, e in body:gmatch("%[(%S+)%s+(%d+)-(%d+)%]") do
                table.insert(clips, {
                    name = name,
                    start = tonumber(s),
                    end_pos = tonumber(e),
                })
            end
            tracks[track_name] = clips
            table.insert(track_order, track_name)
        end
    end
    return { tracks = tracks, track_order = track_order }
end

--- Split a track name like "V1" or "A3" into (kind, number).
-- @param track_name string
-- @return string "video"|"audio", number
function M.track_kind_and_number(track_name)
    local prefix, num = track_name:match("^([VA])(%d+)$")
    assert(prefix, "timeline_dsl: track name must match V<N> or A<N>, got '" ..
        tostring(track_name) .. "'")
    return (prefix == "V") and "video" or "audio", tonumber(num)
end

--- Render a parsed timeline into TMB clip entries.
--
-- Every callback is CALLER-PROVIDED and REQUIRED — no silent defaults
-- (rule 2.13). A typo'd opts key would otherwise produce a unit
-- speed_ratio or a derived id_prefix the test then asserts against,
-- masking the bug as a confusing assertion mismatch instead of a clear
-- "you forgot to wire this".
--
-- @param parsed table: output of M.parse
-- @param opts table — ALL fields required:
--   path_for         function(track_name, clip_name) -> media_path (string)
--   source_in_for    function(track_name, clip_name, kind) -> number
--                       kind is "video"|"audio". Mixed-track tests must
--                       branch — video uses first_frame_tc, audio uses
--                       first_sample_tc — and the unit mismatch (frames
--                       vs samples) makes the wrong call silently wrong.
--   rate_for         function(track_name, kind) -> num, den
--                       kind is "video"|"audio". Audio rate is the sample
--                       rate (e.g. 48000, 1), video rate is fps.
--   speed_ratio_for  function(track_name, clip_name) -> number
--                       For uniform-speed timelines: pass `function() return 1.0 end`.
--   id_prefix_for    function(track_name) -> string
--                       For default-shape ids (e.g. "v1-clip-3"): pass
--                       `function(t) return t:lower() .. "-" end`.
-- @return table {
--     video = { [track_num] = { clip_entries... }, ... },
--     audio = { [track_num] = { clip_entries... }, ... },
--   }
function M.to_tmb(parsed, opts)
    assert(type(parsed) == "table" and parsed.tracks, "timeline_dsl.to_tmb: bad parsed input")
    assert(type(opts) == "table", "timeline_dsl.to_tmb: opts required")
    assert(type(opts.path_for) == "function",
        "timeline_dsl.to_tmb: opts.path_for(track, clip) -> path is required")
    assert(type(opts.source_in_for) == "function",
        "timeline_dsl.to_tmb: opts.source_in_for(track, clip, kind) -> number is required")
    assert(type(opts.rate_for) == "function",
        "timeline_dsl.to_tmb: opts.rate_for(track, kind) -> num, den is required")
    assert(type(opts.speed_ratio_for) == "function",
        "timeline_dsl.to_tmb: opts.speed_ratio_for(track, clip) -> number is required "
        .. "(pass `function() return 1.0 end` for uniform speed)")
    assert(type(opts.id_prefix_for) == "function",
        "timeline_dsl.to_tmb: opts.id_prefix_for(track) -> string is required "
        .. "(pass `function(t) return t:lower() .. '-' end` for default ids)")

    local out = { video = {}, audio = {} }
    for _, track_name in ipairs(parsed.track_order) do
        local kind, num = M.track_kind_and_number(track_name)
        local id_prefix = opts.id_prefix_for(track_name)
        assert(type(id_prefix) == "string" and id_prefix ~= "",
            string.format("timeline_dsl.to_tmb: id_prefix_for(%s) must return non-empty string",
                track_name))
        local rate_num, rate_den = opts.rate_for(track_name, kind)
        assert(type(rate_num) == "number" and type(rate_den) == "number" and rate_den > 0,
            string.format("timeline_dsl.to_tmb: rate_for(%s, %s) must return (num, den>0)",
                track_name, kind))
        local clips = {}
        for _, c in ipairs(parsed.tracks[track_name]) do
            local path = opts.path_for(track_name, c.name)
            assert(type(path) == "string" and path ~= "",
                string.format("timeline_dsl.to_tmb: path_for(%s, %s) returned bad path",
                    track_name, c.name))
            local source_in = opts.source_in_for(track_name, c.name, kind)
            assert(type(source_in) == "number",
                string.format("timeline_dsl.to_tmb: source_in_for(%s, %s, %s) must return number, got %s",
                    track_name, c.name, kind, type(source_in)))
            local speed_ratio = opts.speed_ratio_for(track_name, c.name)
            assert(type(speed_ratio) == "number" and speed_ratio > 0,
                string.format("timeline_dsl.to_tmb: speed_ratio_for(%s, %s) must return number > 0, got %s",
                    track_name, c.name, tostring(speed_ratio)))
            table.insert(clips, {
                clip_id        = id_prefix .. c.name,
                media_path     = path,
                sequence_start = c.start,
                duration       = c.end_pos - c.start,
                source_in      = source_in,
                rate_num       = rate_num,
                rate_den       = rate_den,
                speed_ratio    = speed_ratio,
            })
        end
        out[kind][num] = clips
    end
    return out
end

return M
