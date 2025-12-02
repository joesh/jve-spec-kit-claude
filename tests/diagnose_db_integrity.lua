#!/usr/bin/env luajit
-- Diagnostic script to check for data integrity issues in the clips table

local sqlite3 = require("core.sqlite3")
local home = os.getenv("HOME")
local db_path = home .. "/Documents/JVE Projects/Untitled Project.jvp"

print("Scanning database: " .. db_path)

local db, err = sqlite3.open(db_path)
if not db then
    print("Failed to open DB: " .. tostring(err))
    os.exit(1)
end

print("Checking 'clips' table for NULL fps_numerator or fps_denominator...")

local stmt = db:prepare("SELECT id, name, fps_numerator, fps_denominator FROM clips")
if not stmt then
    print("Failed to prepare query: " .. db:last_error())
    os.exit(1)
end

local count = 0
local bad_count = 0

if stmt:exec() then
    while stmt:next() do
        count = count + 1
        local id = stmt:value(0)
        local name = stmt:value(1)
        local num = stmt:value(2)
        local den = stmt:value(3)
        
        if num == nil or den == nil then
            bad_count = bad_count + 1
            print(string.format("❌ CORRUPT CLIP FOUND: id=%s name='%s' num=%s den=%s", 
                tostring(id), tostring(name), tostring(num), tostring(den)))
        end
    end
end
stmt:finalize()

print(string.format("Scan complete. Checked %d clips. Found %d corrupt records.", count, bad_count))

if bad_count > 0 then
    print("\n--- Hypothesis ---")
    print("If clips have NULL frame rates, they were inserted by a code path that:")
    print("1. Did not populate 'fps_numerator'/'fps_denominator' in the INSERT statement.")
    print("2. Or passed 'nil' to bind_value.")
    print("3. Or the schema constraint 'NOT NULL' was missing when they were inserted (legacy schema persistence).")
end

db:close()
