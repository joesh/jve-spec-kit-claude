--- Relink planner: translate per-media relink results into RelinkClips args.
--
-- media_relinker.relink_media_batch returns { relinked, failed } — a per-media
-- view of which candidate files matched which media. Turning that into the
-- per-clip payload RelinkClips expects requires resolving:
--   - path conflicts when two media want the same target file (priority)
--   - splits when a candidate covers only some of a media's clips
--   - dedupe salvage for failures (sibling row already at the right path)
--
-- This module is the single place where that translation happens. Two
-- callers use it: show_relink_dialog (production UI path) and the
-- test_e2e_retime_relink binding test.
--
-- @file relink_planner.lua
local M = {}
local log = require("core.logger").for_area("media")

--- Given folder priority order and a media path, return its priority (lower = better).
local function get_folder_priority(path, folder_priority)
    for i, root in ipairs(folder_priority) do
        if path:sub(1, #root) == root then
            return i
        end
    end
    return #folder_priority + 1  -- unmatched = lowest
end

--- Build a fresh state bundle for one build_plan invocation.
local function new_state(folder_priority)
    return {
        folder_priority      = folder_priority,
        clip_relink_map      = {},
        media_path_changes   = {},
        media_tc_updates     = {},   -- media_id → probed_tc for metadata sync on path change
        media_duration_updates = {}, -- media_id → {duration_frames, audio_duration_samples}
        new_media_records    = {},   -- split-created clone media descriptors
        clone_path_to_id     = {},   -- new_path → clone media_id (this session)
        path_to_media        = {},   -- new_path → {media_id, priority}
        media_orig_paths     = {},   -- media_id → original file_path
        priority_losers      = {},   -- loser_media_id → winner_media_id
        db_path_cache        = {},   -- path → media_id|false (DB lookup memo)
    }
end

--- Resolve an "immovable" owner of a target path — a claim that cannot be
-- displaced by folder-priority tiebreak: a clone registered this session
-- (already committed to the RelinkClips plan) or an existing DB row.
-- Session path_to_media claims are intentionally NOT consulted here — those
-- ARE tentative and subject to tiebreak in handle_normal_entry.
local function find_immovable_owner(state, db, path)
    if state.clone_path_to_id[path] then return state.clone_path_to_id[path] end

    -- db_path_cache tri-state: nil = not yet looked up, false = cached miss,
    -- string = cached hit (the owner's media_id).
    local cached = state.db_path_cache[path]
    if cached == false then return nil end
    if cached then return cached end

    local stmt = db:prepare("SELECT id FROM media WHERE file_path = ? LIMIT 1")
    if not stmt then state.db_path_cache[path] = false; return nil end
    stmt:bind_value(1, path)
    local found_id = nil
    if stmt:exec() and stmt:next() then
        found_id = stmt:value(0)
    end
    stmt:finalize()
    state.db_path_cache[path] = found_id or false
    return found_id
end

--- Resolve any owner of a target path — session claims (clones or normal),
-- plus DB rows. Used by split-entry handling, where the split is never a
-- priority contender (a split candidate is atomic: either it fits and the
-- clips migrate, or another owner already has the path and the split's
-- clips join that owner).
local function find_path_owner(state, db, path)
    local claim = state.path_to_media[path]
    if claim then return claim.media_id end
    return find_immovable_owner(state, db, path)
end

--- Memoize the original file_path for a given media_id.
local function record_orig_path(state, Media, mid)
    if state.media_orig_paths[mid] then return end
    local m = Media.load(mid)
    assert(m, string.format("relink_planner: media not found: %s", mid))
    state.media_orig_paths[mid] = m:get_file_path()
end

--- Handle a split entry: some clips fit the candidate file, others don't.
-- If the target path is already claimed → reassign fitting clips to the
-- existing owner. Otherwise → register a clone (created later by RelinkClips).
local function handle_split_entry(state, db, Media, uuid, entry)
    local mid = entry.media_id
    local original = Media.load(mid)
    assert(original, "relink_planner: split source media not found: " .. mid)

    local existing_at_path = find_path_owner(state, db, entry.new_path)
    if existing_at_path then
        for _, clip_id in ipairs(entry.split_clip_ids) do
            state.clip_relink_map[clip_id] = { new_media_id = existing_at_path }
        end
        -- Register a session claim for the path if none exists yet (owner
        -- came from clones or DB). priority = 0 is a sentinel meaning
        -- "unbeatable in folder-priority tiebreak" — get_folder_priority
        -- returns values >= 1, so this claim always wins handle_normal_entry
        -- comparisons.
        state.path_to_media[entry.new_path] = state.path_to_media[entry.new_path] or
            { media_id = existing_at_path, priority = 0 }
        log.event("split→existing: media %s → existing %s (%d clips)",
            mid:sub(1, 8), existing_at_path:sub(1, 8), #entry.split_clip_ids)
        return
    end

    local dur = original.duration
    local fps_num = original.frame_rate and original.frame_rate.fps_numerator
    local fps_den = original.frame_rate and original.frame_rate.fps_denominator
    -- Schema enforces duration_frames > 0, fps_num > 0, fps_den > 0 on media.
    -- Nil/zero here means the source media row violates schema invariants and
    -- the split clone would inherit garbage. Surface the bad row instead of
    -- silently abandoning the relink (which would leave split_clip_ids
    -- unreferenced in clip_relink_map — a silent pipeline drop).
    assert(dur and dur > 0, string.format(
        "relink_planner.handle_split_entry: media %s has invalid duration=%s — cannot clone for split",
        mid, tostring(dur)))
    assert(fps_num and fps_num > 0, string.format(
        "relink_planner.handle_split_entry: media %s has invalid fps_numerator=%s — cannot clone for split",
        mid, tostring(fps_num)))
    assert(fps_den and fps_den > 0, string.format(
        "relink_planner.handle_split_entry: media %s has invalid fps_denominator=%s — cannot clone for split",
        mid, tostring(fps_den)))

    -- The clone is materialized inside RelinkClips Phase 1 so undo can fully
    -- revert. Here we only register intent.
    local clone_id = uuid.generate_with_prefix("media")
    state.clone_path_to_id[entry.new_path] = clone_id
    state.path_to_media[entry.new_path] = { media_id = clone_id, priority = 0 }
    -- Clone's metadata reflects the split-target file's TC (not the original
    -- media's TC — those refer to a different file). When probed_tc is
    -- absent the candidate had no authoritative TC to probe (rare: MP3,
    -- non-BWF WAV); the clone inherits original.metadata and the next
    -- relink that does get a probe will overwrite it.
    local clone_metadata = entry.probed_tc
        and Media.merge_probed_tc_into_metadata(original.metadata, entry.probed_tc)
        or original.metadata
    state.new_media_records[#state.new_media_records + 1] = {
        id = clone_id, path = entry.new_path, name = original.name,
        duration_frames = dur,
        fps_num = fps_num, fps_den = fps_den,
        audio_sample_rate = original.audio_sample_rate,
        audio_channels = original.audio_channels,
        width = original.width,
        height = original.height,
        metadata = clone_metadata,
    }
    for _, clip_id in ipairs(entry.split_clip_ids) do
        state.clip_relink_map[clip_id] = { new_media_id = clone_id }
    end
    log.event("split: media %s → clone %s (%d clips) at %s",
        mid:sub(1, 8), clone_id:sub(1, 8), #entry.split_clip_ids,
        entry.new_path:match("([^/]+)$") or entry.new_path)
end

--- Handle a non-split entry: pick a winner via folder priority when two
-- media want the same target path. Losers go into priority_losers.
local function handle_normal_entry(state, db, entry)
    local mid = entry.media_id

    -- Immovable owners (session clones or DB rows) cannot be displaced by
    -- folder-priority tiebreak — if one exists, mid loses immediately.
    local immovable = find_immovable_owner(state, db, entry.new_path)
    if immovable and immovable ~= mid then
        state.priority_losers[mid] = immovable
        return
    end

    -- Session path_to_media claims ARE subject to tiebreak below. Consult
    -- folder priority: lower index = higher priority.
    local my_priority = get_folder_priority(state.media_orig_paths[mid], state.folder_priority)
    local existing = state.path_to_media[entry.new_path]

    -- `media_tc_updates[mid] = entry.probed_tc` sets or clears in one line:
    -- Lua deletes the key when the value is nil, matching our "no probed TC →
    -- no metadata update" intent without a per-branch conditional.
    if not existing or existing.media_id == mid then
        if not existing then
            state.path_to_media[entry.new_path] = {
                media_id = mid, priority = my_priority
            }
        end
        state.media_path_changes[mid] = entry.new_path
        state.media_tc_updates[mid] = entry.probed_tc
        state.media_duration_updates[mid] = entry.probed_duration
    elseif my_priority < existing.priority then
        log.event("folder priority: %s (pri=%d) beats %s (pri=%d) for %s",
            mid:sub(1, 8), my_priority,
            existing.media_id:sub(1, 8), existing.priority,
            entry.new_path:match("([^/]+)$") or entry.new_path)
        state.media_path_changes[existing.media_id] = nil
        state.media_tc_updates[existing.media_id] = nil
        state.media_duration_updates[existing.media_id] = nil
        state.priority_losers[existing.media_id] = mid
        state.media_path_changes[mid] = entry.new_path
        state.media_tc_updates[mid] = entry.probed_tc
        state.media_duration_updates[mid] = entry.probed_duration
        state.path_to_media[entry.new_path] = {
            media_id = mid, priority = my_priority
        }
    else
        state.priority_losers[mid] = existing.media_id
    end
end

--- Follow priority_losers from `start_mid` until a media that isn't itself
-- a loser. Asserts on cycles — each media_id can appear in relinked[] at
-- most once, so displacement should form a DAG, not a cycle. A cycle
-- indicates an upstream bug (same media_id emitted twice by relinker).
-- `cache` memoizes results across calls; caller owns the table.
local function find_terminal_winner(priority_losers, start_mid, cache)
    if cache[start_mid] then return cache[start_mid] end
    local visited = { [start_mid] = true }
    local cur = start_mid
    while priority_losers[cur] do
        local next_mid = priority_losers[cur]
        assert(not visited[next_mid], string.format(
            "relink_planner: priority_losers cycle detected at %s — "
            .. "each media_id should appear in relinked[] only once",
            next_mid))
        visited[next_mid] = true
        cur = next_mid
    end
    cache[start_mid] = cur
    return cur
end

--- Flatten priority_losers: every loser maps directly at its terminal
-- winner, not an intermediate node that is itself displaced.
local function flatten_priority_chains(state)
    local cache = {}
    for loser_mid in pairs(state.priority_losers) do
        state.priority_losers[loser_mid] =
            find_terminal_winner(state.priority_losers, loser_mid, cache)
    end
end

--- Rewrite clip_relink_map entries whose target media is now itself a
-- priority_loser. This covers split-entries that reassigned clips to a
-- session owner before that owner was displaced — the clips need to
-- follow the chain to the terminal winner.
-- Precondition: flatten_priority_chains has already run, so every entry
-- in priority_losers points directly at the terminal winner.
local function rewrite_displaced_clip_assignments(state)
    for clip_id, relink in pairs(state.clip_relink_map) do
        local terminal = state.priority_losers[relink.new_media_id]
        if terminal then
            state.clip_relink_map[clip_id] = { new_media_id = terminal }
        end
    end
end

--- Resolve displacement chains from handle_normal_entry. Displacement can
-- form a chain A→B→C where each middle node is itself displaced; a naive
-- reassign_priority_losers walk cannot follow the chain in a single pass.
-- This pass runs before reassign_priority_losers: first flatten the
-- priority_losers map, then rewrite any clip_relink_map entries whose
-- target is now itself a loser.
local function resolve_priority_chains(state)
    flatten_priority_chains(state)
    rewrite_displaced_clip_assignments(state)
end

--- Walk priority_losers: reassign every clip on a loser to the winner,
--- unless the clip already has an assignment (e.g. from a split entry
--- for the same media_id that precedes this reassignment pass). Symmetric
--- to salvage_via_dedupe's first-writer-wins guard — prior, more-specific
--- assignments take precedence over a blanket loser→winner sweep.
local function reassign_priority_losers(state, Clip)
    for loser_mid, winner_mid in pairs(state.priority_losers) do
        local clips = Clip.find_clips_for_media(loser_mid)
        local reassigned = 0
        for _, clip in ipairs(clips) do
            if not state.clip_relink_map[clip.id] then
                state.clip_relink_map[clip.id] = { new_media_id = winner_mid }
                reassigned = reassigned + 1
            end
        end
        log.event("priority reassign: %d of %d clips from media %s → winner %s (others had prior assignment)",
            reassigned, #clips, loser_mid:sub(1, 8), winner_mid:sub(1, 8))
    end
end

--- Salvage failed entries via sibling-row dedupe.
-- Two media rows can share the same name (one from the project DB, one from
-- a prior import). The relinker rejected this media's candidates, but a
-- sibling row's existing file_path may still be on disk. If so, reassign
-- this media's clips to the sibling row — no new path write needed.
local function salvage_via_dedupe(state, db, Clip, project_id, failed_entries)
    local dedupe_stmt = db:prepare([[
        SELECT id, file_path FROM media
        WHERE project_id = ?
          AND name = (SELECT name FROM media WHERE id = ?)
          AND id != ?
    ]])
    local salvaged = 0
    for _, entry in ipairs(failed_entries) do
        local mid = entry.media_id
        assert(mid and mid ~= "",
            "relink_planner.salvage_via_dedupe: failed entry missing media_id")

        dedupe_stmt:bind_value(1, project_id)
        dedupe_stmt:bind_value(2, mid)
        dedupe_stmt:bind_value(3, mid)
        assert(dedupe_stmt:exec(), string.format(
            "relink_planner.salvage_via_dedupe: sibling query failed for media %s",
            tostring(mid)))
        while dedupe_stmt:next() do
            local sibling_id = dedupe_stmt:value(0)
            local sibling_path = dedupe_stmt:value(1)
            assert(sibling_path and sibling_path ~= "", string.format(
                "relink_planner.salvage_via_dedupe: sibling %s has empty file_path",
                tostring(sibling_id)))
            -- io.open nil means file not on disk — legitimate "no salvage" signal,
            -- keep looking for another sibling.
            local f = io.open(sibling_path, "r")
            if f then
                f:close()
                local clips = Clip.find_clips_for_media(mid)
                for _, clip in ipairs(clips) do
                    if not state.clip_relink_map[clip.id] then
                        state.clip_relink_map[clip.id] = { new_media_id = sibling_id }
                    end
                end
                log.event("dedupe: media %s → sibling %s (%d clips, %s)",
                    mid:sub(1, 8), sibling_id:sub(1, 8), #clips,
                    sibling_path:match("([^/]+)$") or sibling_path)
                salvaged = salvaged + #clips
                break
            end
        end
        dedupe_stmt:reset()
    end
    dedupe_stmt:finalize()
    return salvaged
end

--- Half-2 postcondition: every input entry must produce state. For split
-- entries, EVERY split_clip_id must land in clip_relink_map — partial
-- assignment is a silent drop. For normal entries, the media must appear
-- as either a winner (media_path_changes) or a loser (priority_losers).
local function assert_all_entries_accounted(state, relinked_entries)
    for _, entry in ipairs(relinked_entries) do
        local mid = entry.media_id

        if entry.needs_split and entry.split_clip_ids then
            for _, clip_id in ipairs(entry.split_clip_ids) do
                assert(state.clip_relink_map[clip_id], string.format(
                    "relink_planner: split entry for media %s dropped clip %s — "
                    .. "split_clip_id is not in clip_relink_map (silent pipeline drop)",
                    tostring(mid), tostring(clip_id)))
            end
        else
            local accounted = state.media_path_changes[mid] ~= nil
                or state.priority_losers[mid] ~= nil
            assert(accounted, string.format(
                "relink_planner: relinked entry for media %s produced no state "
                .. "change — not a winner, not a loser (silent pipeline drop)",
                tostring(mid)))
        end
    end
end

--- Half-2 postcondition: the final plan must be self-consistent. Runs
-- after all phases and asserts on contradictions that indicate the
-- planner itself has a bug.
local function assert_plan_consistency(state)
    -- A media cannot be both a winner (will get a path change) and a
    -- loser (its clips redirected elsewhere).
    for loser_mid in pairs(state.priority_losers) do
        assert(state.media_path_changes[loser_mid] == nil, string.format(
            "relink_planner: media %s appears in both priority_losers AND "
            .. "media_path_changes — planner produced contradictory plan",
            tostring(loser_mid)))
    end

    -- No clip_relink_map entry may target a displaced media. If this
    -- fires, resolve_priority_chains failed to rewrite some assignment.
    for clip_id, relink in pairs(state.clip_relink_map) do
        local target = relink.new_media_id
        assert(state.priority_losers[target] == nil, string.format(
            "relink_planner: clip %s targets displaced media %s (terminal=%s) — "
            .. "resolve_priority_chains did not rewrite this assignment",
            tostring(clip_id), tostring(target),
            tostring(state.priority_losers[target])))
    end
end

--- Build a RelinkClips plan from per-media relink results.
--
-- @param db             SQLite connection (for path-owner lookups)
-- @param relinked       Array of per-media entries from media_relinker.
--                       Each entry: {media_id, new_path, needs_split?, split_clip_ids?}
-- @param failed         Array of per-media entries that failed matching.
--                       Each entry: {media_id}
-- @param folder_priority Ordered array of folder roots (index 1 = highest)
-- @param project_id     Owning project (required for salvage query)
-- @return table {
--     clip_relink_map = { clip_id → {new_media_id, ...} },
--     media_path_changes = { media_id → new_path },
--     new_media_records = [ {id, path, name, ...} ],
--     salvaged_count = integer
-- }
function M.build_plan(db, relinked, failed, folder_priority, project_id)
    assert(db, "relink_planner.build_plan: db required")
    assert(type(relinked) == "table", "relink_planner.build_plan: relinked must be array")
    assert(type(failed) == "table", "relink_planner.build_plan: failed must be array (use {} for none)")
    assert(type(folder_priority) == "table", "relink_planner.build_plan: folder_priority must be array")
    assert(project_id and project_id ~= "", "relink_planner.build_plan: project_id required")

    local Media = require("models.media")
    local Clip = require("models.clip")
    local uuid = require("uuid")

    local state = new_state(folder_priority)

    for _, entry in ipairs(relinked) do
        record_orig_path(state, Media, entry.media_id)
        if entry.needs_split and entry.split_clip_ids then
            handle_split_entry(state, db, Media, uuid, entry)
        else
            handle_normal_entry(state, db, entry)
        end
    end

    -- Flatten displacement chains and rewrite clip assignments that predated
    -- a displacement — MUST run before reassign_priority_losers so losers
    -- map directly to terminal winners and the reassign pass does the
    -- right thing in a single walk.
    resolve_priority_chains(state)

    reassign_priority_losers(state, Clip)

    -- Half-2 postconditions: verify every input was accounted for and the
    -- resulting plan is self-consistent BEFORE salvage (which only touches
    -- failed entries, not the main plan).
    assert_all_entries_accounted(state, relinked)
    assert_plan_consistency(state)

    local salvaged = salvage_via_dedupe(state, db, Clip, project_id, failed)

    -- media_offline_notes: JSON-encode coverage info from failed entries
    -- that described a candidate the relinker rejected for extent.
    -- Clearing (nil) for successfully-relinked media so a previously-
    -- written note from an earlier run doesn't linger. RelinkClips
    -- executor writes these to media.offline_note.
    -- media_offline_notes pipeline: partial-coverage relinks carry a
    -- coverage table on the relinked entry; encode it to JSON so the
    -- RelinkClips executor writes media.offline_note. For clean relinks
    -- (no coverage info), emit the "__clear__" sentinel so any stale
    -- note from a previous run gets wiped — a clip that was formerly
    -- short but is now fully covered shouldn't keep rendering offline.
    local json = require("dkjson")
    local media_offline_notes = {}
    for _, entry in ipairs(relinked) do
        if entry.coverage then
            local encoded = assert(json.encode(entry.coverage), string.format(
                "relink_planner: failed to encode coverage for media %s",
                tostring(entry.media_id)))
            media_offline_notes[entry.media_id] = encoded
        end
    end
    for media_id in pairs(state.media_path_changes) do
        -- Every media in the change set that didn't just get a note
        -- attached above is a "fully relinked" case: clear any
        -- lingering offline_note from a prior run.
        if media_offline_notes[media_id] == nil then
            media_offline_notes[media_id] = "__clear__"
        end
    end

    return {
        clip_relink_map       = state.clip_relink_map,
        media_path_changes    = state.media_path_changes,
        media_tc_updates      = state.media_tc_updates,
        media_duration_updates = state.media_duration_updates,
        new_media_records     = state.new_media_records,
        media_offline_notes   = media_offline_notes,
        salvaged_count        = salvaged,
    }
end

return M
