require("test_env")

-- clip_insertion.lua requires models.clip_link, which needs a DB.
-- We mock the sequence/clip objects and stub clip_link to test the orchestration logic.

-- Stub clip_link before requiring clip_insertion
local link_calls = {}
package.loaded["models.clip_link"] = {
    link_two_clips = function(clip_a, clip_b)
        link_calls[#link_calls + 1] = {clip_a, clip_b}
    end
}

local insert_selected_clip = require("core.clip_insertion")

local pass_count = 0
local fail_count = 0

local function check(label, condition)
    if condition then
        pass_count = pass_count + 1
    else
        fail_count = fail_count + 1
        print("FAIL: " .. label)
    end
end

local function expect_error(label, fn, pattern)
    local ok, err = pcall(fn)
    if not ok then
        if pattern and not tostring(err):match(pattern) then
            fail_count = fail_count + 1
            print("FAIL (wrong error): " .. label .. " got: " .. tostring(err))
        else
            pass_count = pass_count + 1
        end
    else
        fail_count = fail_count + 1
        print("FAIL (expected error): " .. label)
    end
end

-- Helper: create mock sequence that records insert_clip calls
local function make_mock_sequence(opts)
    opts = opts or {}
    local inserts = {}
    return {
        inserts = inserts,
        target_video_track = function(self, idx)
            return "video_track_" .. idx
        end,
        target_audio_track = function(self, idx)
            return "audio_track_" .. idx
        end,
        insert_clip = function(self, clip_data, track, pos)
            local id = "inserted_" .. (#inserts + 1)
            inserts[#inserts + 1] = {clip_data = clip_data, track = track, pos = pos, id = id}
            return id
        end,
    }
end

-- Helper: create mock selected_clip
local function make_mock_clip(opts)
    opts = opts or {}
    local has_video = opts.has_video ~= false  -- default true
    local audio_channels = opts.audio_channels or 0
    return {
        video = has_video and {kind = "video", name = "V1"} or nil,
        has_video = function(self) return has_video end,
        has_audio = function(self) return audio_channels > 0 end,
        audio_channel_count = function(self) return audio_channels end,
        audio = function(self, ch)
            return {kind = "audio", channel = ch, name = "A" .. (ch + 1)}
        end,
    }
end

print("\n=== Clip Insertion Tests (T19) ===")

-- ============================================================
-- Video-only clip insertion
-- ============================================================
print("\n--- video-only ---")
do
    link_calls = {}
    local seq = make_mock_sequence()
    local clip = make_mock_clip({has_video = true, audio_channels = 0})
    local state = {selected_clip = clip, sequence = seq, insert_pos = 100}

    insert_selected_clip(state)

    check("video-only: 1 insert", #seq.inserts == 1)
    check("video-only: video data", seq.inserts[1].clip_data.kind == "video")
    check("video-only: video track", seq.inserts[1].track == "video_track_0")
    check("video-only: insert pos", seq.inserts[1].pos == 100)
    check("video-only: no linking", #link_calls == 0)
end

-- ============================================================
-- Audio-only clip insertion (no video)
-- ============================================================
print("\n--- audio-only ---")
do
    link_calls = {}
    local seq = make_mock_sequence()
    local clip = make_mock_clip({has_video = false, audio_channels = 2})
    local state = {selected_clip = clip, sequence = seq, insert_pos = 50}

    insert_selected_clip(state)

    check("audio-only: 2 inserts", #seq.inserts == 2)
    check("audio-only: ch0 track", seq.inserts[1].track == "audio_track_0")
    check("audio-only: ch1 track", seq.inserts[1+1].track == "audio_track_1")
    check("audio-only: ch0 data", seq.inserts[1].clip_data.channel == 0)
    check("audio-only: ch1 data", seq.inserts[2].clip_data.channel == 1)
    -- 2 clips → 1 link call (clips[1] linked to clips[2])
    check("audio-only: 1 link", #link_calls == 1)
end

-- ============================================================
-- Video + stereo audio (3 clips → 2 link calls)
-- ============================================================
print("\n--- video + stereo audio ---")
do
    link_calls = {}
    local seq = make_mock_sequence()
    local clip = make_mock_clip({has_video = true, audio_channels = 2})
    local state = {selected_clip = clip, sequence = seq, insert_pos = 0}

    insert_selected_clip(state)

    check("v+a: 3 inserts", #seq.inserts == 3)
    check("v+a: first is video", seq.inserts[1].clip_data.kind == "video")
    check("v+a: second is audio ch0", seq.inserts[2].clip_data.channel == 0)
    check("v+a: third is audio ch1", seq.inserts[3].clip_data.channel == 1)
    -- 3 clips → link pairs: (1,2) and (1,3)
    check("v+a: 2 link calls", #link_calls == 2)
    check("v+a: link first pair", link_calls[1][1] == seq.inserts[1].id)
    check("v+a: link first pair b", link_calls[1][2] == seq.inserts[2].id)
    check("v+a: link second pair", link_calls[2][1] == seq.inserts[1].id)
    check("v+a: link second pair b", link_calls[2][2] == seq.inserts[3].id)
end

-- ============================================================
-- Single audio channel (1 video + 1 audio = 2 clips → 1 link)
-- ============================================================
print("\n--- video + mono audio ---")
do
    link_calls = {}
    local seq = make_mock_sequence()
    local clip = make_mock_clip({has_video = true, audio_channels = 1})
    local state = {selected_clip = clip, sequence = seq, insert_pos = 10}

    insert_selected_clip(state)

    check("v+mono: 2 inserts", #seq.inserts == 2)
    check("v+mono: 1 link", #link_calls == 1)
end

-- ============================================================
-- Missing state fields → assert
-- ============================================================
print("\n--- missing state fields ---")
do
    expect_error("nil selected_clip", function()
        insert_selected_clip({sequence = {}, insert_pos = 0})
    end)

    expect_error("nil sequence", function()
        insert_selected_clip({selected_clip = make_mock_clip(), insert_pos = 0})
    end)

    expect_error("nil insert_pos", function()
        insert_selected_clip({selected_clip = make_mock_clip(), sequence = make_mock_sequence()})
    end)
end

-- ============================================================
-- Summary
-- ============================================================
print(string.format("\n=== Clip Insertion: %d passed, %d failed ===", pass_count, fail_count))
if fail_count > 0 then
    os.exit(1)
end
print("✅ test_clip_insertion.lua passed")
