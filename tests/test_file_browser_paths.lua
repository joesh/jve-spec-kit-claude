--- Pure black-box tests for core.file_browser_paths.
---
--- No qt_constants, no dialog stubs — file_browser_paths owns the
--- JSON-on-disk persistence and the extract_dir rule, independent of
--- any OS dialog. The thin file_browser wrapper that calls the dialog
--- is intentionally untested at this layer (mocking the OS file dialog
--- would re-introduce the boundary stub we just removed).
---
--- Coverage:
---   extract_dir  — file-with-extension → parent; bare path → itself;
---                  nil / "" → nil
---   get_dir      — cache-miss + fallback; cache-hit ignores fallback;
---                  no cache + no fallback → ""
---   persist_dir  — round-trips to disk; required-args assert
---   set_persistence_path — re-reads from new file (no cache leak)

require("test_env")

print("=== test_file_browser_paths.lua ===")

local function fresh_tmpfile()
    local p = string.format("/tmp/jve/file_browser_paths_%d_%d.json",
        os.time(), math.random(1e9))
    os.execute("mkdir -p /tmp/jve")
    os.remove(p)
    return p
end

-- Reload module fresh so each scenario starts with no cached state.
local function fresh_module(path)
    package.loaded["core.file_browser_paths"] = nil
    local m = require("core.file_browser_paths")
    if path then m.set_persistence_path(path) end
    return m
end

-- ── extract_dir ──────────────────────────────────────────────────────
print("-- extract_dir --")
do
    local paths = fresh_module()
    assert(paths.extract_dir("/Users/joe/footage/clip001.mp4") == "/Users/joe/footage",
        "file with extension → parent dir")
    assert(paths.extract_dir("/Users/joe/footage") == "/Users/joe/footage",
        "bare path (no extension) → itself")
    assert(paths.extract_dir(nil) == nil, "nil input → nil")
    assert(paths.extract_dir("") == nil, "empty string → nil")
    -- Hidden-file vs extension edge case: a dotfile in a dir should
    -- still take the parent dir.
    assert(paths.extract_dir("/home/u/proj/.env.local") == "/home/u/proj",
        "dotted filename → parent dir")
    print("  PASS")
end

-- ── get_dir: no persisted, no fallback → "" ──────────────────────────
print("-- get_dir empty when no persistence + no fallback --")
do
    local paths = fresh_module(fresh_tmpfile())
    assert(paths.get_dir("never_used") == "",
        "missing entry + no fallback must return empty string")
    print("  PASS")
end

-- ── get_dir: fallback honored when no persistence ────────────────────
print("-- get_dir uses fallback when no persisted entry --")
do
    local paths = fresh_module(fresh_tmpfile())
    assert(paths.get_dir("never_used", "/Users/me/Movies") == "/Users/me/Movies",
        "fallback returned when entry absent")
    print("  PASS")
end

-- ── persist_dir → get_dir round-trip; fallback ignored on hit ────────
print("-- persist_dir round-trip; cache hit ignores fallback --")
do
    local paths = fresh_module(fresh_tmpfile())
    paths.persist_dir("import_media", "/Users/joe/footage")
    assert(paths.get_dir("import_media") == "/Users/joe/footage",
        "persisted dir returned by get_dir")
    assert(paths.get_dir("import_media", "/should/be/ignored") == "/Users/joe/footage",
        "cache hit must ignore fallback argument")
    print("  PASS")
end

-- ── Independent names don't collide ──────────────────────────────────
print("-- distinct names persist independently --")
do
    local paths = fresh_module(fresh_tmpfile())
    paths.persist_dir("dialog_a", "/path/a")
    paths.persist_dir("dialog_b", "/path/b")
    assert(paths.get_dir("dialog_a") == "/path/a",
        "dialog_a persisted independently")
    assert(paths.get_dir("dialog_b") == "/path/b",
        "dialog_b persisted independently")
    assert(paths.get_dir("dialog_c") == "",
        "unrelated name still empty")
    print("  PASS")
end

-- ── Overwrite an existing entry ──────────────────────────────────────
print("-- persist_dir overwrites prior value --")
do
    local paths = fresh_module(fresh_tmpfile())
    paths.persist_dir("scratch", "/first")
    paths.persist_dir("scratch", "/second")
    assert(paths.get_dir("scratch") == "/second",
        "second persist must win")
    print("  PASS")
end

-- ── persist_dir asserts on missing args ──────────────────────────────
print("-- persist_dir asserts on missing args --")
do
    local paths = fresh_module(fresh_tmpfile())
    local ok = pcall(paths.persist_dir, nil, "/some/dir")
    assert(not ok, "persist_dir(nil, ...) must assert")
    ok = pcall(paths.persist_dir, "name", nil)
    assert(not ok, "persist_dir(name, nil) must assert")
    print("  PASS")
end

-- ── Cross-instance round-trip: data written by instance A is visible
--    to instance B that loads from the same file (proves disk I/O works,
--    not just the in-memory cache). ─────────────────────────────────
print("-- cross-instance disk round-trip --")
do
    local file = fresh_tmpfile()
    local a = fresh_module(file)
    a.persist_dir("session_persistent", "/Users/joe/Documents/JVE")

    -- New module instance, same file → must read what A wrote.
    local b = fresh_module(file)
    assert(b.get_dir("session_persistent") == "/Users/joe/Documents/JVE",
        "second instance must load persisted data from disk")
    print("  PASS")
end

-- ── set_persistence_path drops cache ─────────────────────────────────
-- If cache survived a path switch, get_dir would return entries from
-- the prior file instead of reading the new one fresh.
print("-- set_persistence_path drops cache --")
do
    local file_x = fresh_tmpfile()
    local file_y = fresh_tmpfile()
    local paths = fresh_module(file_x)
    paths.persist_dir("env_x", "/x")
    assert(paths.get_dir("env_x") == "/x")

    -- Switch to a fresh file — env_x must be absent in the new file's view.
    paths.set_persistence_path(file_y)
    assert(paths.get_dir("env_x") == "",
        "cache must drop when persistence path changes")
    print("  PASS")
end

-- ── Corrupt JSON: caller sees empty cache, no crash ──────────────────
print("-- corrupt JSON file resets to empty --")
do
    local file = fresh_tmpfile()
    local f = io.open(file, "w"); f:write("this is not json {"); f:close()
    local paths = fresh_module(file)
    assert(paths.get_dir("any_name") == "",
        "corrupt JSON must produce empty cache, not crash")
    -- Once empty, a fresh persist still works.
    paths.persist_dir("after_corrupt", "/recovered")
    assert(paths.get_dir("after_corrupt") == "/recovered",
        "writes after corrupt-reset still persist")
    print("  PASS")
end

print("\nPASS test_file_browser_paths.lua")
