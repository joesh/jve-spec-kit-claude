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
};

QTEST_MAIN(TestQtBindings)
#include "test_qt_bindings.moc"
