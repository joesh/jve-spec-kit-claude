// Bug-reporter crypto bindings (feature 027 T007).
//
// Exposes SHA-256 (and, in T030, HMAC-SHA256) to Lua so the bug-reporter
// pipeline can compute cluster signatures (`bug_reporter.signature`) and
// payload integrity hashes (`bug_reporter.transport`) without shelling
// out to `openssl dgst` or rolling pure-Lua crypto.
//
// Co-located in src/bug_reporter/ rather than src/lua/qt_bindings/
// because the only consumers are bug-reporter modules; co-location
// keeps the blast-radius of binding-shape changes scoped.

#include <lua.hpp>
#include <openssl/evp.h>
#include <cstdint>
#include <cstring>

namespace {

// hex-encode `len` bytes from `bytes` into `out` (which MUST hold at
// least 2*len bytes — no NUL terminator written; caller-managed).
void bytes_to_hex_lower(const unsigned char* bytes, size_t len, char* out)
{
    static const char* kHex = "0123456789abcdef";
    for (size_t i = 0; i < len; ++i) {
        out[2 * i + 0] = kHex[(bytes[i] >> 4) & 0x0F];
        out[2 * i + 1] = kHex[bytes[i] & 0x0F];
    }
}

// qt_sha256(message: string) -> hex_string (64 lowercase chars).
//
// Accepts arbitrary bytes via lua_tolstring — the message may contain
// embedded NULs (cluster signatures concatenate user-typed text with
// pipe delimiters, anything can appear). Returns NIST CAVP-compliant
// SHA-256 hex.
int lua_qt_sha256(lua_State* L)
{
    if (lua_gettop(L) != 1) {
        return luaL_error(L, "qt_sha256: expected exactly 1 argument, got %d", lua_gettop(L));
    }
    if (!lua_isstring(L, 1)) {
        return luaL_error(L, "qt_sha256: argument must be a string");
    }

    size_t msg_len = 0;
    const char* msg = lua_tolstring(L, 1, &msg_len);

    unsigned char digest[EVP_MAX_MD_SIZE];
    unsigned int digest_len = 0;

    if (EVP_Digest(reinterpret_cast<const unsigned char*>(msg),
                   msg_len,
                   digest,
                   &digest_len,
                   EVP_sha256(),
                   nullptr) != 1) {
        return luaL_error(L, "qt_sha256: EVP_Digest failed (openssl)");
    }
    if (digest_len != 32) {
        return luaL_error(L, "qt_sha256: unexpected digest length %u", digest_len);
    }

    char hex_buf[64];
    bytes_to_hex_lower(digest, 32, hex_buf);
    lua_pushlstring(L, hex_buf, 64);
    return 1;
}

} // namespace

// Public registration entry — wired from src/qt_bindings.cpp's main
// registration so the binding is available as the global `qt_sha256`.
extern "C" void register_bug_reporter_crypto_bindings(lua_State* L)
{
    lua_pushcfunction(L, lua_qt_sha256);
    lua_setglobal(L, "qt_sha256");
}
