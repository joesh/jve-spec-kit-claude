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
#include <openssl/hmac.h>
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

// Parse a hex string into raw bytes. Returns false (and leaves out_len
// unset) on any non-hex character or odd length.
bool hex_to_bytes(const char* hex, size_t hex_len, unsigned char* out, size_t out_cap, size_t* out_len)
{
    if (hex_len % 2 != 0) return false;
    size_t need = hex_len / 2;
    if (need > out_cap) return false;
    for (size_t i = 0; i < need; ++i) {
        auto nibble = [](char c) -> int {
            if (c >= '0' && c <= '9') return c - '0';
            if (c >= 'a' && c <= 'f') return c - 'a' + 10;
            if (c >= 'A' && c <= 'F') return c - 'A' + 10;
            return -1;
        };
        int hi = nibble(hex[2 * i]);
        int lo = nibble(hex[2 * i + 1]);
        if (hi < 0 || lo < 0) return false;
        out[i] = static_cast<unsigned char>((hi << 4) | lo);
    }
    *out_len = need;
    return true;
}

// qt_hmac_sha256(key_hex: string, message: string) -> hex (64 chars).
//
// Feature 027 T030. Used by transport.lua to HMAC-sign the signed
// payload (metadata_json + "\n" + sha256_hex(zip_bytes)) for /report
// and the body for /heartbeat. Key is provided as hex because the
// stored nonce is hex; converting once at the boundary is cheaper than
// hex-decoding inside the HMAC routine on every call.
int lua_qt_hmac_sha256(lua_State* L)
{
    if (lua_gettop(L) != 2) {
        return luaL_error(L, "qt_hmac_sha256: expected exactly 2 arguments");
    }
    size_t key_hex_len = 0, msg_len = 0;
    const char* key_hex = lua_tolstring(L, 1, &key_hex_len);
    const char* msg = lua_tolstring(L, 2, &msg_len);
    if (!key_hex || !msg) {
        return luaL_error(L, "qt_hmac_sha256: both arguments must be strings");
    }

    unsigned char key_bytes[256];
    size_t key_len = 0;
    if (!hex_to_bytes(key_hex, key_hex_len, key_bytes, sizeof(key_bytes), &key_len)) {
        return luaL_error(L, "qt_hmac_sha256: key must be even-length hex");
    }

    unsigned char digest[EVP_MAX_MD_SIZE];
    unsigned int digest_len = 0;
    if (HMAC(EVP_sha256(),
             key_bytes, static_cast<int>(key_len),
             reinterpret_cast<const unsigned char*>(msg), msg_len,
             digest, &digest_len) == nullptr) {
        return luaL_error(L, "qt_hmac_sha256: HMAC failed (openssl)");
    }
    if (digest_len != 32) {
        return luaL_error(L, "qt_hmac_sha256: unexpected digest length %u", digest_len);
    }

    char hex_buf[64];
    bytes_to_hex_lower(digest, 32, hex_buf);
    lua_pushlstring(L, hex_buf, 64);
    return 1;
}

} // namespace

// Public registration entry — wired from src/qt_bindings.cpp's main
// registration so the binding is available as the global `qt_sha256`
// and `qt_hmac_sha256`.
extern "C" void register_bug_reporter_crypto_bindings(lua_State* L)
{
    lua_pushcfunction(L, lua_qt_sha256);
    lua_setglobal(L, "qt_sha256");
    lua_pushcfunction(L, lua_qt_hmac_sha256);
    lua_setglobal(L, "qt_hmac_sha256");
}
