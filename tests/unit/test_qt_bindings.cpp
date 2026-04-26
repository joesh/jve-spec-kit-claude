#include <QtTest>
#include <QLabel>
#include <QMainWindow>

extern "C" {
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
}

#include "qt_bindings.h"
#include "simple_lua_engine.h"
#include "cpu_video_surface.h"

class TestQtBindings : public QObject
{
    Q_OBJECT

private slots:
    void init() { SimpleLuaEngine::s_lastCreatedMainWindow = nullptr; }

    void test_create_main_window_sets_global()
    {
        lua_State* L = luaL_newstate();
        luaL_openlibs(L);
        registerQtBindings(L);

        // qt_constants.WIDGET.CREATE_MAIN_WINDOW()
        lua_getglobal(L, "qt_constants");
        lua_getfield(L, -1, "WIDGET");
        lua_getfield(L, -1, "CREATE_MAIN_WINDOW");

        QVERIFY(lua_isfunction(L, -1));
        int rc = lua_pcall(L, 0, 1, 0);
        QVERIFY2(rc == LUA_OK, lua_tostring(L, -1));

        QWidget* window = static_cast<QWidget*>(lua_to_widget(L, -1));
        QVERIFY(window != nullptr);
        QCOMPARE(SimpleLuaEngine::s_lastCreatedMainWindow, window);

        delete window;
        SimpleLuaEngine::s_lastCreatedMainWindow = nullptr;
        lua_close(L);
    }

    void test_set_alignment_widget_signature()
    {
        lua_State* L = luaL_newstate();
        luaL_openlibs(L);
        registerQtBindings(L);

        // Create label
        lua_getglobal(L, "qt_constants");
        lua_getfield(L, -1, "WIDGET");
        lua_getfield(L, -1, "CREATE_LABEL");
        lua_pushstring(L, "Hello");
        int rc = lua_pcall(L, 1, 1, 0);
        QVERIFY2(rc == LUA_OK, lua_tostring(L, -1));

        QLabel* label = qobject_cast<QLabel*>(static_cast<QWidget*>(lua_to_widget(L, -1)));
        QVERIFY(label != nullptr);

        // Call qt_set_widget_alignment(label, "AlignCenter")
        lua_getglobal(L, "qt_set_widget_alignment");
        QVERIFY(lua_isfunction(L, -1));
        lua_pushvalue(L, -2); // push label userdata
        lua_pushstring(L, "AlignCenter");
        rc = lua_pcall(L, 2, 1, 0);
        QVERIFY2(rc == LUA_OK, lua_tostring(L, -1));
        QVERIFY(lua_toboolean(L, -1));

        QCOMPARE(label->alignment(), Qt::AlignCenter);

        delete label;
        lua_close(L);
    }

    void test_set_parent_accepts_nil()
    {
        lua_State* L = luaL_newstate();
        luaL_openlibs(L);
        registerQtBindings(L);

        QWidget* parent = new QWidget();
        QWidget* child = new QWidget();

        lua_getglobal(L, "qt_set_parent");
        QVERIFY(lua_isfunction(L, -1));
        lua_push_widget(L, child);
        lua_push_widget(L, parent);
        int rc = lua_pcall(L, 2, 1, 0);
        QVERIFY2(rc == LUA_OK, lua_tostring(L, -1));
        QVERIFY(lua_toboolean(L, -1));
        QCOMPARE(child->parentWidget(), parent);
        lua_pop(L, 1);

        lua_getglobal(L, "qt_set_parent");
        QVERIFY(lua_isfunction(L, -1));
        lua_push_widget(L, child);
        lua_pushnil(L);
        rc = lua_pcall(L, 2, 1, 0);
        QVERIFY2(rc == LUA_OK, lua_tostring(L, -1));
        QVERIFY(lua_toboolean(L, -1));
        QCOMPARE(child->parentWidget(), nullptr);

        delete child;
        delete parent;
        lua_close(L);
    }

    // Regression: EMP video-surface bindings must not crash when the underlying
    // QWidget has been destroyed but Lua still holds the userdata. Pre-fix code
    // dereferenced the stale `*widget_ptr` directly; post-fix it goes through
    // lua_to_widget(), which consults g_widgetRegistry's QPointer and returns
    // nullptr → the binding raises a Lua error instead of UAF-crashing.
    void test_emp_surface_bindings_handle_stale_widget()
    {
        lua_State* L = luaL_newstate();
        luaL_openlibs(L);
        registerQtBindings(L);

        // Create a real video surface, push it as widget userdata, then delete
        // the underlying QWidget. The userdata on the Lua stack now points at
        // a destroyed QObject — exactly the staleness case lua_to_widget exists to catch.
        CPUVideoSurface* surface = new CPUVideoSurface();
        lua_push_widget(L, surface);
        int udata_ref = luaL_ref(L, LUA_REGISTRYINDEX);

        delete surface;  // QPointer in g_widgetRegistry auto-nulls

        // Each EMP/PLAYBACK function in the fixed set must surface a Lua error
        // mentioning the staleness — not crash, not silently no-op.
        struct Call { const char* path[3]; int extra_args; };
        const Call calls[] = {
            {{"EMP", "SURFACE_FRAME_COUNT",        nullptr}, 0},
            {{"EMP", "SURFACE_UNIQUE_FRAME_COUNT", nullptr}, 0},
            {{"EMP", "SURFACE_FRAME_SIZE",         nullptr}, 0},
            {{"EMP", "SURFACE_SET_PAR",            nullptr}, 2},  // num, den
            {{"EMP", "SURFACE_SET_ROTATION",       nullptr}, 1},  // degrees
        };

        for (const auto& c : calls) {
            lua_getglobal(L, "qt_constants");
            lua_getfield(L, -1, c.path[0]);
            lua_getfield(L, -1, c.path[1]);
            QVERIFY2(lua_isfunction(L, -1),
                     qPrintable(QString("missing binding qt_constants.%1.%2").arg(c.path[0]).arg(c.path[1])));
            lua_rawgeti(L, LUA_REGISTRYINDEX, udata_ref);  // stale widget userdata
            for (int i = 0; i < c.extra_args; ++i) lua_pushinteger(L, 1);

            int rc = lua_pcall(L, 1 + c.extra_args, LUA_MULTRET, 0);
            QVERIFY2(rc != LUA_OK,
                     qPrintable(QString("%1.%2 must error on stale widget but returned LUA_OK")
                                .arg(c.path[0]).arg(c.path[1])));
            QString err = QString::fromUtf8(lua_tostring(L, -1));
            QVERIFY2(err.contains("null or destroyed") || err.contains("destroyed"),
                     qPrintable(QString("%1.%2 error did not mention staleness: %3")
                                .arg(c.path[0]).arg(c.path[1]).arg(err)));
            lua_settop(L, 0);
        }

        luaL_unref(L, LUA_REGISTRYINDEX, udata_ref);
        lua_close(L);
    }

    // Regression: video surfaces created via the Lua-side
    // qt_constants.WIDGET.CREATE_CPU_VIDEO_SURFACE() entry point must register
    // in g_widgetRegistry. Pre-fix, the two CREATE_*_VIDEO_SURFACE bindings
    // built userdata by hand instead of going through lua_push_widget, so the
    // resulting surface had no QPointer in the registry — meaning lua_to_widget
    // could not detect post-destruction staleness on it. The EMP staleness
    // protection only worked for surfaces a test pushed via lua_push_widget;
    // the production Lua path was silently unprotected.
    void test_lua_created_video_surface_is_registered_for_staleness()
    {
        lua_State* L = luaL_newstate();
        luaL_openlibs(L);
        registerQtBindings(L);

        // Production path: create surface via the Lua binding, exactly as the
        // app does at startup.
        lua_getglobal(L, "qt_constants");
        lua_getfield(L, -1, "WIDGET");
        lua_getfield(L, -1, "CREATE_CPU_VIDEO_SURFACE");
        QVERIFY(lua_isfunction(L, -1));
        int rc = lua_pcall(L, 0, 1, 0);
        QVERIFY2(rc == LUA_OK, lua_tostring(L, -1));

        // Hold the userdata via registry ref; recover the QWidget* via
        // lua_to_widget and confirm round-trip works (proves the surface IS
        // currently registered — lua_to_widget returns nullptr for unknown
        // widget addresses on the second/staleness-cleanup pass otherwise).
        QWidget* surface = static_cast<QWidget*>(lua_to_widget(L, -1));
        QVERIFY2(surface != nullptr, "fresh Lua-created surface must round-trip lua_to_widget");
        int udata_ref = luaL_ref(L, LUA_REGISTRYINDEX);
        lua_settop(L, 0);

        // Destroy the surface — QPointer in g_widgetRegistry must auto-null.
        delete surface;

        // EMP.SURFACE_FRAME_COUNT on the now-stale userdata must error, not
        // dereference a dangling pointer. Pre-fix this WOULD have UAF'd
        // because the surface was never in g_widgetRegistry.
        lua_getglobal(L, "qt_constants");
        lua_getfield(L, -1, "EMP");
        lua_getfield(L, -1, "SURFACE_FRAME_COUNT");
        QVERIFY(lua_isfunction(L, -1));
        lua_rawgeti(L, LUA_REGISTRYINDEX, udata_ref);
        rc = lua_pcall(L, 1, LUA_MULTRET, 0);
        QVERIFY2(rc != LUA_OK,
                 "SURFACE_FRAME_COUNT on Lua-created stale surface must error");
        QString err = QString::fromUtf8(lua_tostring(L, -1));
        QVERIFY2(err.contains("destroyed"),
                 qPrintable(QString("expected staleness error, got: %1").arg(err)));

        luaL_unref(L, LUA_REGISTRYINDEX, udata_ref);
        lua_close(L);
    }
};

QTEST_MAIN(TestQtBindings)
#include "test_qt_bindings.moc"
