
local function test_import()
    local schema = require('tests.import_schema')
    if type(schema) ~= "string" or #schema == 0 then
        error("Schema is empty or not a string")
    end
    print("Schema loaded successfully, length: " .. #schema)
    
    -- Check for a known table
    if not schema:find("CREATE TABLE IF NOT EXISTS projects") and not schema:find("CREATE TABLE projects") then
        error("Schema does not contain 'projects' table definition")
    end
end

if not pcall(test_import) then
    -- Try with different path assumption (if running from root)
    package.path = package.path .. ";./?.lua"
    test_import()
end
