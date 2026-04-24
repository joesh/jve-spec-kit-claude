// Zstandard decompression for Lua.
//
// Exposes a single global:
//   qt_zstd_decompress(frame) → decompressed_string, err_string
// where `frame` is a raw zstd frame (magic 0x28 0xB5 0x2F 0xFD …).
//
// Used by the DRP importer to decompress Resolve's Sm2Mp*.FieldsBlob
// payloads (protobuf-shaped metadata about media pool items, including
// the MediaRef UUIDs that link a synced video pool item to its external
// audio pool items). Resolve frames a FieldsBlob as
//   [BE32 version][BE32 size][0x81 marker][zstd frame]
// and the caller is expected to slice off those 9 header bytes before
// calling this function — keeps the binding's contract narrow.
//
// Errors (rather than aborts) because a malformed FieldsBlob should
// surface to the Lua importer with actionable context (which clip / blob
// failed), not crash the whole editor.

#include <zstd.h>
#include <lua.hpp>
#include <QByteArray>
#include <vector>

// qt_zstd_decompress(frame) → (decompressed, nil) | (nil, err)
static int lua_qt_zstd_decompress(lua_State* L)
{
    size_t in_len = 0;
    const char* in = luaL_checklstring(L, 1, &in_len);

    // ZSTD_getFrameContentSize returns the exact size for a well-formed
    // frame; ZSTD_CONTENTSIZE_UNKNOWN for streaming/truncated; ERROR for
    // malformed. We require a content-size-known frame — FieldsBlob
    // always provides one — so any other return is an error.
    unsigned long long expected = ZSTD_getFrameContentSize(in, in_len);
    if (expected == ZSTD_CONTENTSIZE_ERROR) {
        lua_pushnil(L);
        lua_pushliteral(L, "qt_zstd_decompress: malformed zstd frame");
        return 2;
    }
    if (expected == ZSTD_CONTENTSIZE_UNKNOWN) {
        lua_pushnil(L);
        lua_pushliteral(L,
            "qt_zstd_decompress: frame has no declared content size");
        return 2;
    }
    // Sanity cap: the FieldsBlob entries we parse are at most a few
    // hundred KB. Refuse anything outlandish to avoid decompression bombs
    // if a malformed blob claims a gigabyte.
    const unsigned long long kMaxOut = 64 * 1024 * 1024;  // 64 MiB
    if (expected > kMaxOut) {
        lua_pushnil(L);
        lua_pushfstring(L,
            "qt_zstd_decompress: declared size %lu exceeds %lu-byte cap",
            static_cast<unsigned long>(expected),
            static_cast<unsigned long>(kMaxOut));
        return 2;
    }

    std::vector<char> out(static_cast<size_t>(expected));
    size_t actual = ZSTD_decompress(
        out.data(), out.size(), in, in_len);

    if (ZSTD_isError(actual)) {
        lua_pushnil(L);
        lua_pushfstring(L,
            "qt_zstd_decompress: %s", ZSTD_getErrorName(actual));
        return 2;
    }
    if (actual != expected) {
        lua_pushnil(L);
        lua_pushfstring(L,
            "qt_zstd_decompress: size mismatch (got %lu, expected %lu)",
            static_cast<unsigned long>(actual),
            static_cast<unsigned long>(expected));
        return 2;
    }

    lua_pushlstring(L, out.data(), actual);
    return 1;
}

static void register_zstd_bindings(lua_State* L)
{
    lua_pushcfunction(L, lua_qt_zstd_decompress);
    lua_setglobal(L, "qt_zstd_decompress");
}
