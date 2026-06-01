// QProcess Lua bindings — thin one-to-one FFI for the Resolve helper
// supervisor (spec 023, T019, FR-007). Supervision *policy* lives in
// `core/resolve_bridge/helper_supervisor.lua`; this file only forwards
// QProcess primitives + signals.
//
// Multiple processes are keyed by integer handle id (next_id counter).
// Callbacks are stored as luaL_ref in LUA_REGISTRYINDEX per slot per
// handle; destroy releases the QProcess and unrefs every slot.
//
// Globals:
//   qt_process_create()                       -> id
//   qt_process_start(id, program, args)       -> ok, err
//   qt_process_wait_for_started(id, ms)       -> bool
//   qt_process_state(id)                      -> "not_running"|"starting"|"running"
//   qt_process_terminate(id)                  -> nil
//   qt_process_kill(id)                       -> nil
//   qt_process_write(id, bytes)               -> bytes_written, err
//   qt_process_pid(id)                        -> integer
//   qt_process_set_finished_cb(id, fn)        fn(exit_code, exit_status_string)
//   qt_process_set_stdout_cb(id, fn)          fn(chunk)
//   qt_process_set_stderr_cb(id, fn)          fn(chunk)
//   qt_process_set_error_cb(id, fn)           fn(error_string)
//   qt_process_destroy(id)
//
// Errors come back as (nil, "message") tuples — never aborts — so the
// supervisor can surface structured errors per FR-006/FR-007.

#include <QProcess>
#include <QString>
#include <QStringList>
#include <QByteArray>
#include <lua.hpp>
#include <functional>
#include <unordered_map>
#include "../../jve_log.h"
#include "../../jve_lua_callback.h"

namespace {

struct ProcSlot {
    QProcess* proc = nullptr;
    int finished_cb = LUA_NOREF;
    int stdout_cb = LUA_NOREF;
    int stderr_cb = LUA_NOREF;
    int error_cb = LUA_NOREF;
};

static std::unordered_map<int, ProcSlot> s_procs;
static int s_next_id = 1;
static lua_State* s_proc_L = nullptr;

static ProcSlot* find_slot(int id) {
    auto it = s_procs.find(id);
    return it == s_procs.end() ? nullptr : &it->second;
}

static void invoke_cb(int ref, std::function<int(lua_State*)> push_args) {
    if (!s_proc_L || ref == LUA_NOREF) return;
    lua_rawgeti(s_proc_L, LUA_REGISTRYINDEX, ref);
    int n = push_args(s_proc_L);
    if (lua_pcall(s_proc_L, n, 0, 0) != 0) {
        jve_handle_lua_callback_error(s_proc_L, "qt_process callback");
    }
}

static int lua_qt_process_create(lua_State* L) {
    int id = s_next_id++;
    ProcSlot slot;
    slot.proc = new QProcess();
    s_proc_L = L;

    QObject::connect(slot.proc,
        QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
        [id](int code, QProcess::ExitStatus status) {
            auto* s = find_slot(id);
            if (!s) return;
            const char* status_str =
                status == QProcess::NormalExit ? "normal" : "crash";
            invoke_cb(s->finished_cb, [code, status_str](lua_State* L) {
                lua_pushinteger(L, code);
                lua_pushstring(L, status_str);
                return 2;
            });
        });

    QObject::connect(slot.proc, &QProcess::readyReadStandardOutput, [id]() {
        auto* s = find_slot(id);
        if (!s || s->stdout_cb == LUA_NOREF) return;
        QByteArray chunk = s->proc->readAllStandardOutput();
        invoke_cb(s->stdout_cb, [&chunk](lua_State* L) {
            lua_pushlstring(L, chunk.constData(), chunk.size());
            return 1;
        });
    });

    QObject::connect(slot.proc, &QProcess::readyReadStandardError, [id]() {
        auto* s = find_slot(id);
        if (!s || s->stderr_cb == LUA_NOREF) return;
        QByteArray chunk = s->proc->readAllStandardError();
        invoke_cb(s->stderr_cb, [&chunk](lua_State* L) {
            lua_pushlstring(L, chunk.constData(), chunk.size());
            return 1;
        });
    });

    QObject::connect(slot.proc, &QProcess::errorOccurred,
        [id](QProcess::ProcessError err) {
            auto* s = find_slot(id);
            if (!s) return;
            const char* name = "unknown";
            switch (err) {
                case QProcess::FailedToStart: name = "failed_to_start"; break;
                case QProcess::Crashed:       name = "crashed"; break;
                case QProcess::Timedout:      name = "timed_out"; break;
                case QProcess::WriteError:    name = "write_error"; break;
                case QProcess::ReadError:     name = "read_error"; break;
                default: break;
            }
            invoke_cb(s->error_cb, [name](lua_State* L) {
                lua_pushstring(L, name);
                return 1;
            });
        });

    s_procs[id] = slot;
    lua_pushinteger(L, id);
    return 1;
}

static ProcSlot* require_slot(lua_State* L, int id, const char* fn) {
    auto* slot = find_slot(id);
    if (!slot) {
        luaL_error(L, "%s: unknown handle %d", fn, id);
    }
    return slot;
}

static int lua_qt_process_start(lua_State* L) {
    int id = (int)luaL_checkinteger(L, 1);
    const char* program = luaL_checkstring(L, 2);
    luaL_checktype(L, 3, LUA_TTABLE);
    auto* slot = require_slot(L, id, "qt_process_start");
    QStringList args;
    int n = (int)lua_objlen(L, 3);
    for (int i = 1; i <= n; i++) {
        lua_rawgeti(L, 3, i);
        if (lua_type(L, -1) != LUA_TSTRING) {
            lua_pop(L, 1);
            lua_pushnil(L);
            lua_pushfstring(L,
                "qt_process_start: args[%d] not a string", i);
            return 2;
        }
        args << QString::fromUtf8(lua_tostring(L, -1));
        lua_pop(L, 1);
    }
    slot->proc->start(QString::fromUtf8(program), args);
    lua_pushboolean(L, 1);
    return 1;
}

static int lua_qt_process_wait_for_started(lua_State* L) {
    int id = (int)luaL_checkinteger(L, 1);
    int timeout_ms = (int)luaL_checkinteger(L, 2);
    auto* slot = require_slot(L, id, "qt_process_wait_for_started");
    bool ok = slot->proc->waitForStarted(timeout_ms);
    lua_pushboolean(L, ok ? 1 : 0);
    return 1;
}

static int lua_qt_process_state(lua_State* L) {
    int id = (int)luaL_checkinteger(L, 1);
    auto* slot = require_slot(L, id, "qt_process_state");
    switch (slot->proc->state()) {
        case QProcess::NotRunning: lua_pushstring(L, "not_running"); break;
        case QProcess::Starting:   lua_pushstring(L, "starting"); break;
        case QProcess::Running:    lua_pushstring(L, "running"); break;
    }
    return 1;
}

static int lua_qt_process_terminate(lua_State* L) {
    int id = (int)luaL_checkinteger(L, 1);
    auto* slot = require_slot(L, id, "qt_process_terminate");
    slot->proc->terminate();
    return 0;
}

static int lua_qt_process_kill(lua_State* L) {
    int id = (int)luaL_checkinteger(L, 1);
    auto* slot = require_slot(L, id, "qt_process_kill");
    slot->proc->kill();
    return 0;
}

static int lua_qt_process_write(lua_State* L) {
    int id = (int)luaL_checkinteger(L, 1);
    size_t len = 0;
    const char* data = luaL_checklstring(L, 2, &len);
    auto* slot = require_slot(L, id, "qt_process_write");
    qint64 written = slot->proc->write(data, (qint64)len);
    if (written < 0) {
        lua_pushnil(L);
        lua_pushstring(L, "qt_process_write: write failed");
        return 2;
    }
    lua_pushinteger(L, (lua_Integer)written);
    return 1;
}

static int lua_qt_process_pid(lua_State* L) {
    int id = (int)luaL_checkinteger(L, 1);
    auto* slot = require_slot(L, id, "qt_process_pid");
    lua_pushinteger(L, (lua_Integer)slot->proc->processId());
    return 1;
}

static int set_callback_slot(lua_State* L, const char* fn, int ProcSlot::*member) {
    int id = (int)luaL_checkinteger(L, 1);
    luaL_checktype(L, 2, LUA_TFUNCTION);
    auto* slot = require_slot(L, id, fn);
    s_proc_L = L;
    if (slot->*member != LUA_NOREF)
        luaL_unref(L, LUA_REGISTRYINDEX, slot->*member);
    lua_pushvalue(L, 2);
    slot->*member = luaL_ref(L, LUA_REGISTRYINDEX);
    return 0;
}

static int lua_qt_process_set_finished_cb(lua_State* L) {
    return set_callback_slot(L, "qt_process_set_finished_cb",
        &ProcSlot::finished_cb);
}

static int lua_qt_process_set_stdout_cb(lua_State* L) {
    return set_callback_slot(L, "qt_process_set_stdout_cb",
        &ProcSlot::stdout_cb);
}

static int lua_qt_process_set_stderr_cb(lua_State* L) {
    return set_callback_slot(L, "qt_process_set_stderr_cb",
        &ProcSlot::stderr_cb);
}

static int lua_qt_process_set_error_cb(lua_State* L) {
    return set_callback_slot(L, "qt_process_set_error_cb",
        &ProcSlot::error_cb);
}

static int lua_qt_process_destroy(lua_State* L) {
    int id = (int)luaL_checkinteger(L, 1);
    auto it = s_procs.find(id);
    if (it == s_procs.end()) return 0;
    ProcSlot& slot = it->second;
    for (int* ref : { &slot.finished_cb, &slot.stdout_cb,
                       &slot.stderr_cb, &slot.error_cb }) {
        if (*ref != LUA_NOREF) {
            luaL_unref(L, LUA_REGISTRYINDEX, *ref);
            *ref = LUA_NOREF;
        }
    }
    if (slot.proc) {
        if (slot.proc->state() != QProcess::NotRunning) {
            slot.proc->kill();
            slot.proc->waitForFinished(1000);
        }
        slot.proc->deleteLater();
        slot.proc = nullptr;
    }
    s_procs.erase(it);
    return 0;
}

} // namespace

static void register_process_bindings(lua_State* L) {
    lua_pushcfunction(L, lua_qt_process_create);
    lua_setglobal(L, "qt_process_create");
    lua_pushcfunction(L, lua_qt_process_start);
    lua_setglobal(L, "qt_process_start");
    lua_pushcfunction(L, lua_qt_process_wait_for_started);
    lua_setglobal(L, "qt_process_wait_for_started");
    lua_pushcfunction(L, lua_qt_process_state);
    lua_setglobal(L, "qt_process_state");
    lua_pushcfunction(L, lua_qt_process_terminate);
    lua_setglobal(L, "qt_process_terminate");
    lua_pushcfunction(L, lua_qt_process_kill);
    lua_setglobal(L, "qt_process_kill");
    lua_pushcfunction(L, lua_qt_process_write);
    lua_setglobal(L, "qt_process_write");
    lua_pushcfunction(L, lua_qt_process_pid);
    lua_setglobal(L, "qt_process_pid");
    lua_pushcfunction(L, lua_qt_process_set_finished_cb);
    lua_setglobal(L, "qt_process_set_finished_cb");
    lua_pushcfunction(L, lua_qt_process_set_stdout_cb);
    lua_setglobal(L, "qt_process_set_stdout_cb");
    lua_pushcfunction(L, lua_qt_process_set_stderr_cb);
    lua_setglobal(L, "qt_process_set_stderr_cb");
    lua_pushcfunction(L, lua_qt_process_set_error_cb);
    lua_setglobal(L, "qt_process_set_error_cb");
    lua_pushcfunction(L, lua_qt_process_destroy);
    lua_setglobal(L, "qt_process_destroy");
}
