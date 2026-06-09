// QLocalSocket Lua bindings — thin one-to-one FFI for the Resolve helper
// client (spec 023, T020, FR-006/FR-007). Protocol framing / correlation
// live in `core/resolve_bridge/client.lua`; this file only forwards
// QLocalSocket primitives + signals.
//
// Sockets keyed by integer handle id. Callbacks stored as luaL_ref.
// Destroy releases the QLocalSocket and unrefs every slot.
//
// Globals:
//   qt_local_socket_create()                      -> id
//   qt_local_socket_connect(id, path)             -> nil (async; use cbs)
//   qt_local_socket_wait_for_connected(id, ms)    -> bool
//   qt_local_socket_state(id)                     -> "unconnected"|"connecting"|"connected"|"closing"
//   qt_local_socket_write(id, bytes)              -> bytes_written, err
//   qt_local_socket_read_all(id)                  -> string
//   qt_local_socket_flush(id)                     -> bool
//   qt_local_socket_close(id)                     -> nil
//   qt_local_socket_set_connected_cb(id, fn)      fn()
//   qt_local_socket_set_ready_read_cb(id, fn)     fn()  (caller reads via read_all)
//   qt_local_socket_set_disconnected_cb(id, fn)   fn()
//   qt_local_socket_set_error_cb(id, fn)          fn(error_string)
//   qt_local_socket_destroy(id)
//
// Errors come back as (nil, msg) tuples; unknown handles raise luaL_error
// (caller bug, not recoverable).

#include <QLocalSocket>
#include <QString>
#include <QByteArray>
#include <lua.hpp>
#include <functional>
#include <unordered_map>
#include "../../jve_log.h"
#include "../../jve_lua_callback.h"

namespace {

struct SockSlot {
    QLocalSocket* sock = nullptr;
    int connected_cb = LUA_NOREF;
    int ready_read_cb = LUA_NOREF;
    int disconnected_cb = LUA_NOREF;
    int error_cb = LUA_NOREF;
};

static std::unordered_map<int, SockSlot> s_socks;
static int s_socket_next_id = 1;
static lua_State* s_socket_L = nullptr;

static SockSlot* socket_find_slot(int id) {
    auto it = s_socks.find(id);
    return it == s_socks.end() ? nullptr : &it->second;
}

static SockSlot* socket_require_slot(lua_State* L, int id, const char* fn) {
    auto* slot = socket_find_slot(id);
    if (!slot) {
        luaL_error(L, "%s: unknown handle %d", fn, id);
    }
    return slot;
}

static void socket_invoke_cb(int ref, std::function<int(lua_State*)> push_args) {
    jve_invoke_lua_callback(s_socket_L, ref, std::move(push_args),
                            "qt_local_socket callback");
}

static const char* socket_error_name(QLocalSocket::LocalSocketError err) {
    switch (err) {
        case QLocalSocket::ConnectionRefusedError: return "connection_refused";
        case QLocalSocket::PeerClosedError:        return "peer_closed";
        case QLocalSocket::ServerNotFoundError:    return "server_not_found";
        case QLocalSocket::SocketAccessError:      return "access_denied";
        case QLocalSocket::SocketResourceError:    return "resource_exhausted";
        case QLocalSocket::SocketTimeoutError:     return "timeout";
        case QLocalSocket::DatagramTooLargeError:  return "datagram_too_large";
        case QLocalSocket::ConnectionError:        return "connection_error";
        case QLocalSocket::UnsupportedSocketOperationError: return "unsupported_op";
        case QLocalSocket::UnknownSocketError:     return "unknown";
        case QLocalSocket::OperationError:         return "operation_error";
        default:                                   return "unknown";
    }
}

static int lua_qt_local_socket_create(lua_State* L) {
    int id = s_socket_next_id++;
    SockSlot slot;
    slot.sock = new QLocalSocket();
    s_socket_L = L;

    QObject::connect(slot.sock, &QLocalSocket::connected, [id]() {
        auto* s = socket_find_slot(id);
        if (!s) return;
        socket_invoke_cb(s->connected_cb, [](lua_State*) { return 0; });
    });

    QObject::connect(slot.sock, &QLocalSocket::readyRead, [id]() {
        auto* s = socket_find_slot(id);
        if (!s) return;
        socket_invoke_cb(s->ready_read_cb, [](lua_State*) { return 0; });
    });

    QObject::connect(slot.sock, &QLocalSocket::disconnected, [id]() {
        auto* s = socket_find_slot(id);
        if (!s) return;
        socket_invoke_cb(s->disconnected_cb, [](lua_State*) { return 0; });
    });

    QObject::connect(slot.sock, &QLocalSocket::errorOccurred,
        [id](QLocalSocket::LocalSocketError err) {
            auto* s = socket_find_slot(id);
            if (!s) return;
            const char* name = socket_error_name(err);
            socket_invoke_cb(s->error_cb, [name](lua_State* L) {
                lua_pushstring(L, name);
                return 1;
            });
        });

    s_socks[id] = slot;
    lua_pushinteger(L, id);
    return 1;
}

static int lua_qt_local_socket_connect(lua_State* L) {
    int id = (int)luaL_checkinteger(L, 1);
    const char* path = luaL_checkstring(L, 2);
    auto* slot = socket_require_slot(L, id, "qt_local_socket_connect");
    slot->sock->connectToServer(QString::fromUtf8(path));
    return 0;
}

static int lua_qt_local_socket_wait_for_connected(lua_State* L) {
    int id = (int)luaL_checkinteger(L, 1);
    int timeout_ms = (int)luaL_checkinteger(L, 2);
    auto* slot = socket_require_slot(L, id, "qt_local_socket_wait_for_connected");
    bool ok = slot->sock->waitForConnected(timeout_ms);
    lua_pushboolean(L, ok ? 1 : 0);
    return 1;
}

static int lua_qt_local_socket_state(lua_State* L) {
    int id = (int)luaL_checkinteger(L, 1);
    auto* slot = socket_require_slot(L, id, "qt_local_socket_state");
    switch (slot->sock->state()) {
        case QLocalSocket::UnconnectedState: lua_pushstring(L, "unconnected"); break;
        case QLocalSocket::ConnectingState:  lua_pushstring(L, "connecting"); break;
        case QLocalSocket::ConnectedState:   lua_pushstring(L, "connected"); break;
        case QLocalSocket::ClosingState:     lua_pushstring(L, "closing"); break;
        default:                             lua_pushstring(L, "unknown"); break;
    }
    return 1;
}

static int lua_qt_local_socket_write(lua_State* L) {
    int id = (int)luaL_checkinteger(L, 1);
    size_t len = 0;
    const char* data = luaL_checklstring(L, 2, &len);
    auto* slot = socket_require_slot(L, id, "qt_local_socket_write");
    qint64 written = slot->sock->write(data, (qint64)len);
    if (written < 0) {
        lua_pushnil(L);
        lua_pushstring(L, "qt_local_socket_write: write failed");
        return 2;
    }
    lua_pushinteger(L, (lua_Integer)written);
    return 1;
}

static int lua_qt_local_socket_read_all(lua_State* L) {
    int id = (int)luaL_checkinteger(L, 1);
    auto* slot = socket_require_slot(L, id, "qt_local_socket_read_all");
    QByteArray data = slot->sock->readAll();
    lua_pushlstring(L, data.constData(), data.size());
    return 1;
}

static int lua_qt_local_socket_flush(lua_State* L) {
    int id = (int)luaL_checkinteger(L, 1);
    auto* slot = socket_require_slot(L, id, "qt_local_socket_flush");
    lua_pushboolean(L, slot->sock->flush() ? 1 : 0);
    return 1;
}

static int lua_qt_local_socket_close(lua_State* L) {
    int id = (int)luaL_checkinteger(L, 1);
    auto* slot = socket_require_slot(L, id, "qt_local_socket_close");
    slot->sock->close();
    return 0;
}

static int set_socket_callback_slot(
    lua_State* L, const char* fn, int SockSlot::*member) {
    int id = (int)luaL_checkinteger(L, 1);
    luaL_checktype(L, 2, LUA_TFUNCTION);
    auto* slot = socket_require_slot(L, id, fn);
    s_socket_L = L;
    if (slot->*member != LUA_NOREF)
        luaL_unref(L, LUA_REGISTRYINDEX, slot->*member);
    lua_pushvalue(L, 2);
    slot->*member = luaL_ref(L, LUA_REGISTRYINDEX);
    return 0;
}

static int lua_qt_local_socket_set_connected_cb(lua_State* L) {
    return set_socket_callback_slot(L,
        "qt_local_socket_set_connected_cb", &SockSlot::connected_cb);
}
static int lua_qt_local_socket_set_ready_read_cb(lua_State* L) {
    return set_socket_callback_slot(L,
        "qt_local_socket_set_ready_read_cb", &SockSlot::ready_read_cb);
}
static int lua_qt_local_socket_set_disconnected_cb(lua_State* L) {
    return set_socket_callback_slot(L,
        "qt_local_socket_set_disconnected_cb", &SockSlot::disconnected_cb);
}
static int lua_qt_local_socket_set_error_cb(lua_State* L) {
    return set_socket_callback_slot(L,
        "qt_local_socket_set_error_cb", &SockSlot::error_cb);
}

static int lua_qt_local_socket_destroy(lua_State* L) {
    int id = (int)luaL_checkinteger(L, 1);
    auto it = s_socks.find(id);
    if (it == s_socks.end()) return 0;
    SockSlot& slot = it->second;
    for (int* ref : { &slot.connected_cb, &slot.ready_read_cb,
                       &slot.disconnected_cb, &slot.error_cb }) {
        if (*ref != LUA_NOREF) {
            luaL_unref(L, LUA_REGISTRYINDEX, *ref);
            *ref = LUA_NOREF;
        }
    }
    if (slot.sock) {
        slot.sock->disconnectFromServer();
        slot.sock->deleteLater();
        slot.sock = nullptr;
    }
    s_socks.erase(it);
    return 0;
}

} // namespace

static void register_local_socket_bindings(lua_State* L) {
    lua_pushcfunction(L, lua_qt_local_socket_create);
    lua_setglobal(L, "qt_local_socket_create");
    lua_pushcfunction(L, lua_qt_local_socket_connect);
    lua_setglobal(L, "qt_local_socket_connect");
    lua_pushcfunction(L, lua_qt_local_socket_wait_for_connected);
    lua_setglobal(L, "qt_local_socket_wait_for_connected");
    lua_pushcfunction(L, lua_qt_local_socket_state);
    lua_setglobal(L, "qt_local_socket_state");
    lua_pushcfunction(L, lua_qt_local_socket_write);
    lua_setglobal(L, "qt_local_socket_write");
    lua_pushcfunction(L, lua_qt_local_socket_read_all);
    lua_setglobal(L, "qt_local_socket_read_all");
    lua_pushcfunction(L, lua_qt_local_socket_flush);
    lua_setglobal(L, "qt_local_socket_flush");
    lua_pushcfunction(L, lua_qt_local_socket_close);
    lua_setglobal(L, "qt_local_socket_close");
    lua_pushcfunction(L, lua_qt_local_socket_set_connected_cb);
    lua_setglobal(L, "qt_local_socket_set_connected_cb");
    lua_pushcfunction(L, lua_qt_local_socket_set_ready_read_cb);
    lua_setglobal(L, "qt_local_socket_set_ready_read_cb");
    lua_pushcfunction(L, lua_qt_local_socket_set_disconnected_cb);
    lua_setglobal(L, "qt_local_socket_set_disconnected_cb");
    lua_pushcfunction(L, lua_qt_local_socket_set_error_cb);
    lua_setglobal(L, "qt_local_socket_set_error_cb");
    lua_pushcfunction(L, lua_qt_local_socket_destroy);
    lua_setglobal(L, "qt_local_socket_destroy");
}
