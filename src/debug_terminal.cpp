#include "debug_terminal.h"
#include "jve_log.h"

#include <QFile>

extern "C" {
#include <lauxlib.h>
}

#include <cstdio>

DebugTerminal::DebugTerminal(const QString& socket_path, lua_State* L, QObject* parent)
    : QObject(parent), m_socket_path(socket_path), m_lua_state(L) {}

DebugTerminal::~DebugTerminal() {
    if (m_server) {
        m_server->close();
    }
    // Remove the socket file so a subsequent run can bind the same path.
    QFile::remove(m_socket_path);
}

bool DebugTerminal::start() {
    // QLocalServer refuses to bind if the path already exists, so remove
    // any stale socket from a prior crashed run. Safe — if another JVE
    // is actually listening, the user would have hit a flag collision
    // before getting here.
    QFile::remove(m_socket_path);

    m_server = new QLocalServer(this);
    if (!m_server->listen(m_socket_path)) {
        JVE_LOG_ERROR(Ui, "DebugTerminal: failed to listen on %s: %s",
                      qPrintable(m_socket_path),
                      qPrintable(m_server->errorString()));
        delete m_server;
        m_server = nullptr;
        return false;
    }
    connect(m_server, &QLocalServer::newConnection,
            this, &DebugTerminal::onNewConnection);
    JVE_LOG_EVENT(Ui, "DebugTerminal: listening on %s", qPrintable(m_socket_path));
    return true;
}

void DebugTerminal::onNewConnection() {
    QLocalSocket* incoming = m_server->nextPendingConnection();
    if (!incoming) return;

    if (m_client) {
        // Single-client policy: reject + close the second connection
        // with a one-line error so the client sees why.
        incoming->write("ERROR: debug terminal already has a client\n");
        incoming->flush();
        incoming->disconnectFromServer();
        incoming->deleteLater();
        JVE_LOG_EVENT(Ui, "DebugTerminal: rejected second connection (busy)");
        return;
    }

    m_client = incoming;
    m_pending.clear();
    connect(m_client, &QLocalSocket::readyRead,    this, &DebugTerminal::onReadyRead);
    connect(m_client, &QLocalSocket::disconnected, this, &DebugTerminal::onDisconnected);

    m_client->write("jve> ");
    m_client->flush();
    JVE_LOG_EVENT(Ui, "DebugTerminal: client connected");
}

void DebugTerminal::onReadyRead() {
    if (!m_client) return;
    m_pending += m_client->readAll();

    // Process all complete lines accumulated so far.
    while (true) {
        int nl = m_pending.indexOf('\n');
        if (nl < 0) break;
        QByteArray line = m_pending.left(nl);
        m_pending.remove(0, nl + 1);
        // Trim trailing \r for clients that send CRLF.
        if (line.endsWith('\r')) line.chop(1);
        handleLine(line);
    }
}

void DebugTerminal::onDisconnected() {
    JVE_LOG_EVENT(Ui, "DebugTerminal: client disconnected");
    if (m_client) {
        m_client->deleteLater();
        m_client = nullptr;
    }
    m_pending.clear();
}

// ─── Lua helpers (file-local) ───────────────────────────────────────────────
//
// Format the top-of-stack Lua value into a one-line string. Truncates
// deep tables and long strings so a runaway response can't flood the
// terminal. Newlines in strings are escaped to keep the framing
// (one response = one line).

namespace {

void appendEscaped(QByteArray& out, const char* s, qsizetype n) {
    for (qsizetype i = 0; i < n; ++i) {
        unsigned char c = static_cast<unsigned char>(s[i]);
        switch (c) {
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            case '\\': out += "\\\\"; break;
            case '"':  out += "\\\""; break;
            default:
                if (c < 32 || c == 127) {
                    char buf[8];
                    std::snprintf(buf, sizeof(buf), "\\x%02x", c);
                    out += buf;
                } else {
                    out += static_cast<char>(c);
                }
        }
    }
}

void formatValue(lua_State* L, int idx, QByteArray& out, int depth_left);

void formatTable(lua_State* L, int idx, QByteArray& out, int depth_left) {
    if (depth_left <= 0) {
        out += "{...}";
        return;
    }
    out += "{";
    // Manual lua_absindex (LuaJIT 2.1 lacks the helper).
    if (idx < 0 && idx > LUA_REGISTRYINDEX) idx = lua_gettop(L) + 1 + idx;
    lua_pushnil(L);
    bool first = true;
    int items = 0;
    while (lua_next(L, idx) != 0) {
        if (!first) out += ", ";
        first = false;
        if (++items > 32) {
            out += "...";
            lua_pop(L, 2);  // pop value + key
            break;
        }
        // key at -2, value at -1
        if (lua_type(L, -2) == LUA_TSTRING) {
            size_t klen = 0;
            const char* k = lua_tolstring(L, -2, &klen);
            appendEscaped(out, k, qsizetype(klen));
        } else {
            out += "[";
            formatValue(L, -2, out, depth_left - 1);
            out += "]";
        }
        out += "=";
        formatValue(L, -1, out, depth_left - 1);
        lua_pop(L, 1);  // pop value, keep key for next iteration
    }
    out += "}";
}

void formatValue(lua_State* L, int idx, QByteArray& out, int depth_left) {
    int t = lua_type(L, idx);
    switch (t) {
        case LUA_TNIL:     out += "nil"; break;
        case LUA_TBOOLEAN: out += lua_toboolean(L, idx) ? "true" : "false"; break;
        case LUA_TNUMBER: {
            char buf[64];
            std::snprintf(buf, sizeof(buf), "%.14g", lua_tonumber(L, idx));
            out += buf;
            break;
        }
        case LUA_TSTRING: {
            size_t n = 0;
            const char* s = lua_tolstring(L, idx, &n);
            out += '"';
            // Cap string length to keep responses one line and short.
            qsizetype cap = qsizetype(n);
            if (cap > 256) cap = 256;
            appendEscaped(out, s, cap);
            if (qsizetype(n) > cap) out += "...";
            out += '"';
            break;
        }
        case LUA_TTABLE:
            formatTable(L, idx, out, depth_left);
            break;
        case LUA_TFUNCTION: out += "<function>"; break;
        case LUA_TUSERDATA: out += "<userdata>"; break;
        case LUA_TTHREAD:   out += "<thread>"; break;
        case LUA_TLIGHTUSERDATA: out += "<lightuserdata>"; break;
        default: out += "<unknown>"; break;
    }
}

}  // namespace

// Pop the top-of-stack Lua error into a QByteArray. Handles non-string
// errors (table / nil / userdata thrown by `error{...}`) safely —
// lua_tostring returns NULL for those, and QByteArray::operator+= on a
// null char* is fragile. Always returns the top-of-stack value as a
// human-readable message, then pops it.
static QByteArray popLuaError(lua_State* L) {
    const char* msg = lua_tostring(L, -1);
    QByteArray out = msg ? QByteArray(msg) : QByteArray("<non-string error>");
    lua_pop(L, 1);
    return out;
}

void DebugTerminal::writeError(const QByteArray& msg) {
    QByteArray reply = "ERROR: ";
    reply += msg;
    reply += "\njve> ";
    m_client->write(reply);
    m_client->flush();
}

void DebugTerminal::writeReply(const QByteArray& body) {
    if (body.isEmpty()) {
        m_client->write("jve> ");
    } else {
        QByteArray reply = body;
        reply += "\njve> ";
        m_client->write(reply);
    }
    m_client->flush();
}

void DebugTerminal::handleLine(const QByteArray& line) {
    if (!m_client) return;
    if (!m_lua_state) {
        writeError("no Lua state");
        return;
    }

    QByteArray trimmed = line.trimmed();
    if (trimmed.isEmpty()) {
        writeReply(QByteArray());
        return;
    }

    lua_State* L = m_lua_state;
    int top_before = lua_gettop(L);

    // Try as expression first: prepend "return " so the user can type
    // bare values (`Clip.load('c1').source_in`) without explicit return.
    QByteArray with_return = "return " + trimmed;
    int rc = luaL_loadbuffer(L, with_return.constData(),
                             size_t(with_return.size()), "=debug_terminal");
    if (rc != 0) {
        // Expression parse failed — try as a statement chunk.
        lua_pop(L, 1);  // pop the parse error
        rc = luaL_loadbuffer(L, trimmed.constData(),
                             size_t(trimmed.size()), "=debug_terminal");
        if (rc != 0) {
            writeError(popLuaError(L));
            return;
        }
    }

    rc = lua_pcall(L, 0, LUA_MULTRET, 0);
    if (rc != 0) {
        writeError(popLuaError(L));
        return;
    }

    // Format each return value on the stack (above top_before).
    int n_returns = lua_gettop(L) - top_before;
    QByteArray reply;
    for (int i = 1; i <= n_returns; ++i) {
        if (i > 1) reply += ", ";
        formatValue(L, top_before + i, reply, /*depth_left=*/ 3);
    }
    lua_pop(L, n_returns);
    writeReply(reply);
}
