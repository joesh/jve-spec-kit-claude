-- Diagnostic: read peak file directly with FFI and dump bins around click
local env = require("integration.integration_test_env")
local EMP = env.require_emp()
local ffi = require("ffi")

local PEAK_DIR = "/tmp/jve/test_waveform_e2e"
local PEAK_FILE = PEAK_DIR .. "/click_test.peaks"

-- Check if peak file exists from previous test
local f = io.open(PEAK_FILE, "rb")
if not f then
    print("Peak file not found — run test_waveform_end_to_end.lua first")
    return
end

-- Read header (64 bytes)
local hdr_data = f:read(64)
print(string.format("Header: %d bytes", #hdr_data))
print(string.format("  Magic: %s", hdr_data:sub(1, 4)))

-- Read level 0 peak data (starts at byte 64)
-- Each bin = 2 floats (min, max) = 8 bytes
-- Click bin should be at bin 187 (sample 48000 / 256)
local CLICK_BIN = math.floor(48000 / 256)  -- 187

-- Seek to bin area and read bins around click
for bin = CLICK_BIN - 3, CLICK_BIN + 3 do
    local offset = 64 + bin * 8  -- header + bin * (2 floats * 4 bytes)
    f:seek("set", offset)
    local bin_data = f:read(8)
    if bin_data and #bin_data == 8 then
        local min_val = ffi.cast("float*", ffi.new("char[4]", bin_data:sub(1, 4)))[0]
        local max_val = ffi.cast("float*", ffi.new("char[4]", bin_data:sub(5, 8)))[0]
        print(string.format("  Bin %d (samples %d..%d): min=%.4f max=%.4f %s",
            bin, bin * 256, (bin + 1) * 256, min_val, max_val,
            max_val > 0.5 and "<<< LOUD" or ""))
    end
end

f:close()

-- Also check via EMP.PEAK_LOAD for comparison
local handle = EMP.PEAK_LOAD(PEAK_FILE)
if handle then
    print("\nVia EMP.PEAK_QUERY:")
    for bin = CLICK_BIN - 3, CLICK_BIN + 3 do
        local p, c = EMP.PEAK_QUERY(handle, bin * 256, (bin + 1) * 256, 1)
        if p and c > 0 then
            local pd = ffi.cast("float*", p)
            print(string.format("  Bin %d: min=%.4f max=%.4f %s",
                bin, pd[0], pd[1], pd[1] > 0.5 and "<<< LOUD" or ""))
        end
    end
    EMP.PEAK_RELEASE(handle)
end
