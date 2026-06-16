-- Unit test for drp_importer._extract_seq_xml_media_links — the single-pass
-- tokenizer that replaces three full-file `.-` regex scans (Pass-4 orphan grep
-- + MediaRef→MediaFilePath UUID enrichment + MediaFilePath→MediaFrameRate
-- enrichment) over each DRP sequence XML.
--
-- Contract (must match the ORIGINAL non-overlapping gmatch semantics it
-- replaces — values derived from those patterns, NOT from the new code):
--   1. orphan_paths       — every <MediaFilePath> value, in document order.
--   2. ref_path_pairs     — each <MediaRef> paired with the NEXT
--                           <MediaFilePath> after it (keep-FIRST ref when
--                           several refs precede one path; the original
--                           `<MediaRef>..</>.-<MediaFilePath>..</>` consumes the
--                           first ref and the path, dropping the inner refs).
--   3. path_fr_pairs      — each <MediaFilePath> paired with the NEXT
--                           <MediaFrameRate> after it (keep-FIRST path).
-- Tags may span newlines; the caller passes OriginalClip-stripped content.

require("test_env")
local drp = require("importers.drp_importer")

print("=== test_drp_seq_xml_media_links.lua ===")

local extract = drp._extract_seq_xml_media_links
assert(type(extract) == "function",
    "drp_importer must export _extract_seq_xml_media_links")

local function find_pair(list, a, b)
    for _, p in ipairs(list) do
        if p[1] == a and p[2] == b then return true end
    end
    return false
end

-- ── Case 1: a ref + its path, and a path + its frame rate ──────────────
do
    local xml = [[
        <MediaRef>uuid-A</MediaRef>
        <MediaFilePath>/vol/cam/a.mov</MediaFilePath>
        <MediaFrameRate>00000000004f5340</MediaFrameRate>
    ]]
    local r = extract(xml)
    assert(find_pair(r.ref_path_pairs, "uuid-A", "/vol/cam/a.mov"),
        "ref must pair with the next path")
    assert(find_pair(r.path_fr_pairs, "/vol/cam/a.mov", "00000000004f5340"),
        "path must pair with the next frame rate")
    local saw_orphan = false
    for _, p in ipairs(r.orphan_paths) do if p == "/vol/cam/a.mov" then saw_orphan = true end end
    assert(saw_orphan, "path must appear as an orphan candidate")
    print("  ✓ case 1: ref→path, path→framerate, orphan path")
end

-- ── Case 2: keep-FIRST ref when two refs precede one path ──────────────
-- Original `<MediaRef>(R)</>.-<MediaFilePath>(F)</>` matches (R1,F) and
-- resumes after F; R2 (between R1 and F) is consumed by `.-` and never paired.
do
    local xml = [[
        <MediaRef>R1</MediaRef>
        <MediaRef>R2</MediaRef>
        <MediaFilePath>/vol/x.mov</MediaFilePath>
    ]]
    local r = extract(xml)
    assert(find_pair(r.ref_path_pairs, "R1", "/vol/x.mov"),
        "first ref must win the path")
    assert(not find_pair(r.ref_path_pairs, "R2", "/vol/x.mov"),
        "second (inner) ref must NOT pair — `.-` consumed it")
    print("  ✓ case 2: keep-first ref (R1 wins, R2 dropped)")
end

-- ── Case 3: keep-FIRST path for frame rate; trailing path has no rate ──
do
    local xml = [[
        <MediaFilePath>/vol/p1.mov</MediaFilePath>
        <MediaFilePath>/vol/p2.mov</MediaFilePath>
        <MediaFrameRate>0000000000505340</MediaFrameRate>
        <MediaFilePath>/vol/p3.mov</MediaFilePath>
    ]]
    local r = extract(xml)
    assert(find_pair(r.path_fr_pairs, "/vol/p1.mov", "0000000000505340"),
        "first path wins the frame rate")
    assert(not find_pair(r.path_fr_pairs, "/vol/p2.mov", "0000000000505340"),
        "second path must NOT pair (consumed by `.-`)")
    -- p3 has no following frame rate → no pair
    for _, p in ipairs(r.path_fr_pairs) do
        assert(p[1] ~= "/vol/p3.mov", "trailing path with no rate must not pair")
    end
    -- all three paths are orphan candidates regardless
    assert(#r.orphan_paths == 3, "all three paths are orphan candidates")
    print("  ✓ case 3: keep-first path for frame rate; trailing path unpaired")
end

-- ── Case 4: interleaved with unrelated tags + values trimmed ───────────
do
    local xml =
        "<DbId>99</DbId><MediaRef> uuid-B </MediaRef><Name>foo</Name>" ..
        "<MediaFilePath> /vol/b.mov </MediaFilePath>"
    local r = extract(xml)
    assert(find_pair(r.ref_path_pairs, "uuid-B", "/vol/b.mov"),
        "values must be whitespace-trimmed and unrelated tags ignored")
    print("  ✓ case 4: unrelated tags ignored, values trimmed")
end

print("\n✅ test_drp_seq_xml_media_links.lua passed")
