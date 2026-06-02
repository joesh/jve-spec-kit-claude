-- T032/Phase-A probe — decompress + dump the A005 MpVideoClip FieldsBlob.
--
-- Goal: identify positions of file_path, native_rate (24000/1001 → bytes),
-- duration (108 frames), width/height (1920×1080), so drt_writer can
-- rewrite them per payload instead of asserting media == A005.
--
-- Run:
--   ./build/bin/jve.app/Contents/MacOS/jve --test \
--     "$(pwd)/tools/resolve-helper/spikes/t032_probe_mp_video_clip_blob.lua"

local function fail(msg) io.write("FAIL: "..msg.."\n"); os.exit(1) end

local TEMPLATE_PATH =
    "src/lua/exporters/drt_canonical/full_reference_mp_video_clip_a005.xml"
local f = assert(io.open(TEMPLATE_PATH, "rb"),
    "cannot open " .. TEMPLATE_PATH)
local xml = f:read("*a"); f:close()

-- Pull the hex FieldsBlob (the first <FieldsBlob>...</FieldsBlob> only;
-- per PROVENANCE this is the outer Sm2MpVideoClip blob, the one that
-- carries the BtVideoInfo/Clip/Time/Geometry/etc. sub-blobs).
local hex = xml:match("<FieldsBlob>([0-9a-f]+)</FieldsBlob>")
assert(hex, "no FieldsBlob found in template")
io.write(string.format("outer FieldsBlob hex length: %d chars (%d bytes)\n",
    #hex, #hex/2))

-- Convert hex → bytes.
local raw = {}
for i = 1, #hex, 2 do
    raw[#raw+1] = string.char(tonumber(hex:sub(i, i+1), 16))
end
local bytes = table.concat(raw)
io.write(string.format("raw byte length: %d\n", #bytes))

-- First 8 bytes are envelope (existing notes say "00000002 00000173 81"
-- then zstd magic 28b52ffd). Strip envelope to find the zstd frame.
io.write(string.format("envelope first 16 bytes: %s\n",
    bytes:sub(1, 16):gsub(".", function(c)
        return string.format("%02x", string.byte(c))
    end)))

-- Locate zstd magic 28 b5 2f fd.
local zstd_magic = "\x28\xb5\x2f\xfd"
local zstd_start = bytes:find(zstd_magic, 1, true)
assert(zstd_start, "no zstd magic in outer FieldsBlob")
io.write(string.format("zstd frame starts at byte offset %d\n", zstd_start - 1))

-- Try to decompress everything from the magic onward.
local frame = bytes:sub(zstd_start)
io.write(string.format("zstd frame length: %d\n", #frame))

local decompressed, err = qt_zstd_decompress(frame)
if not decompressed then fail("decompress failed: " .. tostring(err)) end
io.write(string.format("decompressed length: %d\n", #decompressed))

-- Dump first 256 bytes as hex+ascii so we can eyeball TLV / pascal-strings.
local function dump(buf, n)
    n = math.min(n or #buf, #buf)
    for off = 0, n-1, 16 do
        local chunk = buf:sub(off+1, math.min(off+16, n))
        local hex_part, asc_part = {}, {}
        for i = 1, #chunk do
            local b = string.byte(chunk, i)
            hex_part[#hex_part+1] = string.format("%02x", b)
            asc_part[#asc_part+1] = (b >= 0x20 and b < 0x7f)
                and string.char(b) or "."
        end
        io.write(string.format("  %04x  %-48s  %s\n",
            off, table.concat(hex_part, " "), table.concat(asc_part)))
    end
end

io.write("\n=== decompressed first 512 bytes ===\n")
dump(decompressed, 512)

-- Probe known A005 markers anywhere in the payload.
local A005_BASENAME = "A005_C052_0925BL_001.mp4"
local pos = decompressed:find(A005_BASENAME, 1, true)
io.write(string.format("\nfile basename '%s' at offset: %s\n",
    A005_BASENAME, pos and tostring(pos-1) or "NOT FOUND"))

-- native_rate 24000/1001 = 23.97602... as LE double 0x401762d05f5e5e6f-ish.
-- Probe for the LE-double byte pattern.
local function le_double(x)
    -- portable LE double encoder via string.pack (LuaJIT supports lua 5.3 fmt)
    return string.pack("<d", x)
end
local rate_dbl = le_double(24000/1001)
local rate_pos = decompressed:find(rate_dbl, 1, true)
io.write(string.format("native_rate LE double at offset: %s\n",
    rate_pos and tostring(rate_pos-1) or "NOT FOUND"))

-- duration 108 — could be int32 LE, int64 LE, or inside a hex blob.
for _, fmt in ipairs({{"<i4", 4}, {"<i8", 8}, {">i4", 4}, {">i8", 8}}) do
    local enc = string.pack(fmt[1], 108)
    local p = decompressed:find(enc, 1, true)
    if p then
        io.write(string.format("duration 108 as %s at offset %d\n",
            fmt[1], p-1))
    end
end

-- width 1920 / height 1080
for _, w in ipairs({1920, 1080}) do
    for _, fmt in ipairs({{"<i4", 4}, {"<i8", 8}, {">i4", 4}, {">i8", 8}}) do
        local enc = string.pack(fmt[1], w)
        local p = decompressed:find(enc, 1, true)
        if p then
            io.write(string.format("%d as %s at offset %d\n", w, fmt[1], p-1))
        end
    end
end

-- Bake the decompressed buffer to /tmp for offline analysis.
local out = io.open("/tmp/jve/t032_mp_video_clip_decompressed.bin", "wb")
out:write(decompressed); out:close()
io.write("\nwrote /tmp/jve/t032_mp_video_clip_decompressed.bin\n")

print("\nT032 probe complete.")
os.exit(0)
