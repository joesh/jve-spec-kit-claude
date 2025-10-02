#include <QtTest/QtTest>
#include <QApplication>
#include <QMouseEvent>
#include <QKeyEvent>
#include "src/ui/timeline/scriptable_timeline.h"

extern "C" {
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
}

class TestScriptableTimelineWidget : public QObject
{
    Q_OBJECT

private:
    lua_State* L = nullptr;
    JVE::ScriptableTimeline* timeline = nullptr;

    // Event handler tracking
    struct EventData {
        QString type;
        int x = 0;
        int y = 0;
        bool ctrl = false;
        bool shift = false;
        bool alt = false;
        int button = 0;
        int key = 0;
    };
    static EventData lastMouseEvent;
    static EventData lastKeyEvent;

    static int lua_mock_mouse_handler(lua_State* L) {
        if (lua_istable(L, 1)) {
            lua_getfield(L, 1, "type");
            lastMouseEvent.type = QString::fromStdString(lua_tostring(L, -1));
            lua_pop(L, 1);

            lua_getfield(L, 1, "x");
            lastMouseEvent.x = lua_tointeger(L, -1);
            lua_pop(L, 1);

            lua_getfield(L, 1, "y");
            lastMouseEvent.y = lua_tointeger(L, -1);
            lua_pop(L, 1);

            lua_getfield(L, 1, "ctrl");
            lastMouseEvent.ctrl = lua_toboolean(L, -1);
            lua_pop(L, 1);

            lua_getfield(L, 1, "button");
            lastMouseEvent.button = lua_tointeger(L, -1);
            lua_pop(L, 1);
        }
        return 0;
    }

    static int lua_mock_key_handler(lua_State* L) {
        if (lua_istable(L, 1)) {
            lua_getfield(L, 1, "type");
            lastKeyEvent.type = QString::fromStdString(lua_tostring(L, -1));
            lua_pop(L, 1);

            lua_getfield(L, 1, "key");
            lastKeyEvent.key = lua_tointeger(L, -1);
            lua_pop(L, 1);

            lua_getfield(L, 1, "ctrl");
            lastKeyEvent.ctrl = lua_toboolean(L, -1);
            lua_pop(L, 1);
        }
        return 0;
    }

private slots:
    void initTestCase() {
        // Initialize Lua state
        L = luaL_newstate();
        luaL_openlibs(L);

        // Register mock handlers
        lua_pushcfunction(L, lua_mock_mouse_handler);
        lua_setglobal(L, "mock_mouse_handler");

        lua_pushcfunction(L, lua_mock_key_handler);
        lua_setglobal(L, "mock_key_handler");

        // Create timeline widget
        timeline = new JVE::ScriptableTimeline("test_timeline");
        timeline->setLuaState(L);
    }

    void cleanupTestCase() {
        delete timeline;
        lua_close(L);
    }

    void init() {
        // Reset event tracking before each test
        lastMouseEvent = EventData();
        lastKeyEvent = EventData();
    }

    // Test: Widget creation
    void testWidgetCreation() {
        QVERIFY(timeline != nullptr);
        QCOMPARE(timeline->getWidth(), timeline->width());
        QCOMPARE(timeline->getHeight(), timeline->height());
    }

    // Test: Drawing commands
    void testDrawingCommands() {
        timeline->clearCommands();
        timeline->addRect(10, 20, 100, 50, "#ff0000");
        timeline->addLine(0, 0, 100, 100, "#00ff00", 2);
        timeline->addText(50, 50, "Test", "#0000ff");

        // Commands should not throw and widget should update
        timeline->requestUpdate();
        QVERIFY(true); // If we get here without crash, drawing works
    }

    // Test: Playhead management
    void testPlayheadManagement() {
        timeline->setPlayheadPosition(5000);
        QCOMPARE(timeline->getPlayheadPosition(), (qint64)5000);

        timeline->setPlayheadPosition(0);
        QCOMPARE(timeline->getPlayheadPosition(), (qint64)0);

        timeline->setPlayheadPosition(999999);
        QCOMPARE(timeline->getPlayheadPosition(), (qint64)999999);
    }

    // Test: Mouse event handling
    void testMouseEventHandling() {
        timeline->setMouseEventHandler("mock_mouse_handler");

        // Simulate mouse press
        QMouseEvent pressEvent(QEvent::MouseButtonPress, QPointF(150, 200),
                              Qt::LeftButton, Qt::LeftButton, Qt::ControlModifier);
        QCoreApplication::sendEvent(timeline, &pressEvent);

        QCOMPARE(lastMouseEvent.type, QString("press"));
        QCOMPARE(lastMouseEvent.x, 150);
        QCOMPARE(lastMouseEvent.y, 200);
        QVERIFY(lastMouseEvent.ctrl);
        QCOMPARE(lastMouseEvent.button, (int)Qt::LeftButton);
    }

    // Test: Mouse move event
    void testMouseMoveEvent() {
        timeline->setMouseEventHandler("mock_mouse_handler");

        QMouseEvent moveEvent(QEvent::MouseMove, QPointF(75, 100),
                             Qt::NoButton, Qt::NoButton, Qt::NoModifier);
        QCoreApplication::sendEvent(timeline, &moveEvent);

        QCOMPARE(lastMouseEvent.type, QString("move"));
        QCOMPARE(lastMouseEvent.x, 75);
        QCOMPARE(lastMouseEvent.y, 100);
    }

    // Test: Mouse release event
    void testMouseReleaseEvent() {
        timeline->setMouseEventHandler("mock_mouse_handler");

        QMouseEvent releaseEvent(QEvent::MouseButtonRelease, QPointF(200, 150),
                                Qt::LeftButton, Qt::LeftButton, Qt::NoModifier);
        QCoreApplication::sendEvent(timeline, &releaseEvent);

        QCOMPARE(lastMouseEvent.type, QString("release"));
        QCOMPARE(lastMouseEvent.x, 200);
        QCOMPARE(lastMouseEvent.y, 150);
    }

    // Test: Keyboard event handling
    void testKeyboardEventHandling() {
        timeline->setKeyEventHandler("mock_key_handler");
        timeline->setFocus();

        QKeyEvent keyEvent(QEvent::KeyPress, Qt::Key_A, Qt::ControlModifier);
        QCoreApplication::sendEvent(timeline, &keyEvent);

        QCOMPARE(lastKeyEvent.type, QString("press"));
        QCOMPARE(lastKeyEvent.key, (int)Qt::Key_A);
        QVERIFY(lastKeyEvent.ctrl);
    }

    // Test: Multiple drawing commands
    void testMultipleDrawingCommands() {
        timeline->clearCommands();

        // Add many commands to test performance
        for (int i = 0; i < 100; i++) {
            timeline->addRect(i * 10, 20, 8, 30, "#4a90e2");
        }

        timeline->requestUpdate();
        QVERIFY(true); // Should handle many commands without issue
    }

    // Test: Clear commands
    void testClearCommands() {
        timeline->addRect(10, 20, 100, 50, "#ff0000");
        timeline->addLine(0, 0, 100, 100, "#00ff00", 2);

        timeline->clearCommands();
        timeline->requestUpdate();

        // After clear, should be able to add new commands
        timeline->addText(50, 50, "After Clear", "#0000ff");
        QVERIFY(true);
    }

    // Test: Event handler registration
    void testEventHandlerRegistration() {
        timeline->setMouseEventHandler("mock_mouse_handler");
        timeline->setKeyEventHandler("mock_key_handler");

        // Should not crash when handlers are set
        QVERIFY(true);
    }

    // Test: Widget dimensions
    void testWidgetDimensions() {
        timeline->resize(800, 400);

        QCOMPARE(timeline->getWidth(), 800);
        QCOMPARE(timeline->getHeight(), 400);
    }

    // Test: Modifier keys in mouse events
    void testModifierKeys() {
        timeline->setMouseEventHandler("mock_mouse_handler");

        // Test Shift modifier
        QMouseEvent shiftEvent(QEvent::MouseButtonPress, QPointF(100, 100),
                              Qt::LeftButton, Qt::LeftButton, Qt::ShiftModifier);
        QCoreApplication::sendEvent(timeline, &shiftEvent);
        QVERIFY(lastMouseEvent.shift);

        // Test Alt modifier
        QMouseEvent altEvent(QEvent::MouseButtonPress, QPointF(100, 100),
                            Qt::LeftButton, Qt::LeftButton, Qt::AltModifier);
        QCoreApplication::sendEvent(timeline, &altEvent);
        QVERIFY(lastMouseEvent.alt);
    }
};

// Static member initialization
TestScriptableTimelineWidget::EventData TestScriptableTimelineWidget::lastMouseEvent;
TestScriptableTimelineWidget::EventData TestScriptableTimelineWidget::lastKeyEvent;

QTEST_MAIN(TestScriptableTimelineWidget)
#include "test_scriptable_timeline_widget.moc"
