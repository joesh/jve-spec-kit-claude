// Zstandard (de)compression for Lua.
//
// Exposes two globals:
//   qt_zstd_decompress(frame) → decompressed_string, err_string
//   qt_zstd_compress(payload[, level]) → frame_string, err_string
// where `frame` is a raw zstd frame (magic 0x28 0xB5 0x2F 0xFD …).
//
// decompress is used by the DRP importer to read Resolve's Sm2Mp*.FieldsBlob
// payloads (protobuf-shaped metadata about media pool items, including the
// MediaRef UUIDs that link a synced video pool item to its external audio
// pool items). compress is its inverse, used by the DRT writer
// (exporters/drt_binary.lua: encode_fields_blob) to author the same blob.
// Resolve frames a FieldsBlob as
//   [BE32 version][BE32 size][0x81 marker][zstd frame]
// and the caller slices off / prepends those 9 header bytes — keeps each
// binding's contract narrow (thin one-to-one FFI, ENGINEERING 2.18).
//
// The one-shot ZSTD_compress embeds the content size in the frame header,
// so qt_zstd_decompress (which requires a content-size-known frame) reads
// the output back symmetrically.
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

// qt_zstd_compress(payload[, level]) → (frame, nil) | (nil, err)
static int lua_qt_zstd_compress(lua_State* L)
{
    size_t in_len = 0;
    const char* in = luaL_checklstring(L, 1, &in_len);
    int level = static_cast<int>(luaL_optinteger(L, 2, ZSTD_CLEVEL_DEFAULT));

    size_t bound = ZSTD_compressBound(in_len);
    std::vector<char> out(bound);
    size_t written = ZSTD_compress(out.data(), out.size(), in, in_len, level);

    if (ZSTD_isError(written)) {
        lua_pushnil(L);
        lua_pushfstring(L,
            "qt_zstd_compress: %s", ZSTD_getErrorName(written));
        return 2;
    }

    lua_pushlstring(L, out.data(), written);
    return 1;
}

static void register_zstd_bindings(lua_State* L)
{
    lua_pushcfunction(L, lua_qt_zstd_decompress);
    lua_setglobal(L, "qt_zstd_decompress");
    lua_pushcfunction(L, lua_qt_zstd_compress);
    lua_setglobal(L, "qt_zstd_compress");
}
