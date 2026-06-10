#include <QtTest/QtTest>
#include <QApplication>
#include <QMouseEvent>
#include <QKeyEvent>
#include "src/timeline_renderer.h"

extern "C" {
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
}

class TestTimelineRendererWidget : public QObject
{
    Q_OBJECT

private:
    lua_State* L = nullptr;
    JVE::TimelineRenderer* timeline = nullptr;

    // Event handler tracking
    struct EventData {
        QString type;
        int x = 0;
        int y = 0;
        bool ctrl = false;
        bool shift = false;
        bool alt = false;
        bool command = false;
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

            lua_getfield(L, 1, "shift");
            lastMouseEvent.shift = lua_toboolean(L, -1);
            lua_pop(L, 1);

            lua_getfield(L, 1, "alt");
            lastMouseEvent.alt = lua_toboolean(L, -1);
            lua_pop(L, 1);

            lua_getfield(L, 1, "command");
            if (!lua_isnil(L, -1)) {
                lastMouseEvent.command = lua_toboolean(L, -1);
                lastMouseEvent.ctrl = lastMouseEvent.ctrl || lastMouseEvent.command;
            }
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
        timeline = new JVE::TimelineRenderer("test_timeline");
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
        QMouseEvent pressEvent(QEvent::MouseButtonPress,
                               QPointF(150, 200),
                               QPointF(150, 200),
                               QPointF(timeline->mapToGlobal(QPoint(150, 200))),
                               Qt::LeftButton,
                               Qt::LeftButton,
                               Qt::ControlModifier,
                               Qt::MouseEventNotSynthesized);
        QCoreApplication::sendEvent(timeline, &pressEvent);

        QCOMPARE(lastMouseEvent.type, QString("press"));
        QCOMPARE(lastMouseEvent.x, 150);
        QCOMPARE(lastMouseEvent.y, 200);
        QVERIFY(lastMouseEvent.ctrl || lastMouseEvent.command);
        QCOMPARE(lastMouseEvent.button, (int)Qt::LeftButton);
    }

    // Test: Mouse move event
    void testMouseMoveEvent() {
        timeline->setMouseEventHandler("mock_mouse_handler");

        QMouseEvent moveEvent(QEvent::MouseMove,
                              QPointF(75, 100),
                              QPointF(75, 100),
                              QPointF(timeline->mapToGlobal(QPoint(75, 100))),
                              Qt::NoButton,
                              Qt::NoButton,
                              Qt::NoModifier,
                              Qt::MouseEventNotSynthesized);
        QCoreApplication::sendEvent(timeline, &moveEvent);

        QCOMPARE(lastMouseEvent.type, QString("move"));
        QCOMPARE(lastMouseEvent.x, 75);
        QCOMPARE(lastMouseEvent.y, 100);
    }

    // Test: Mouse release event
    void testMouseReleaseEvent() {
        timeline->setMouseEventHandler("mock_mouse_handler");

        QMouseEvent releaseEvent(QEvent::MouseButtonRelease,
                                 QPointF(200, 150),
                                 QPointF(200, 150),
                                 QPointF(timeline->mapToGlobal(QPoint(200, 150))),
                                 Qt::LeftButton,
                                 Qt::LeftButton,
                                 Qt::NoModifier,
                                 Qt::MouseEventNotSynthesized);
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

        // Reset state
        lastMouseEvent = EventData();

        // Test Shift modifier
        QMouseEvent shiftEvent(QEvent::MouseButtonPress,
                               QPointF(100, 100),
                               QPointF(100, 100),
                               QPointF(timeline->mapToGlobal(QPoint(100, 100))),
                               Qt::LeftButton,
                               Qt::LeftButton,
                               Qt::ShiftModifier,
                               Qt::MouseEventNotSynthesized);
        QCoreApplication::sendEvent(timeline, &shiftEvent);
        QVERIFY(lastMouseEvent.shift);
        QVERIFY(!lastMouseEvent.alt);

        // Reset state
        lastMouseEvent = EventData();

        // Test Alt modifier
        QMouseEvent altEvent(QEvent::MouseButtonPress,
                             QPointF(100, 100),
                             QPointF(100, 100),
                             QPointF(timeline->mapToGlobal(QPoint(100, 100))),
                             Qt::LeftButton,
                             Qt::LeftButton,
                             Qt::AltModifier,
                             Qt::MouseEventNotSynthesized);
        QCoreApplication::sendEvent(timeline, &altEvent);
        QVERIFY(lastMouseEvent.alt);
        QVERIFY(!lastMouseEvent.shift);

        // Reset state
        lastMouseEvent = EventData();

        // Test Ctrl modifier
        QMouseEvent ctrlEvent(QEvent::MouseButtonPress,
                              QPointF(100, 100),
                              QPointF(100, 100),
                              QPointF(timeline->mapToGlobal(QPoint(100, 100))),
                              Qt::LeftButton,
                              Qt::LeftButton,
                              Qt::ControlModifier,
                              Qt::MouseEventNotSynthesized);
        QCoreApplication::sendEvent(timeline, &ctrlEvent);
        QVERIFY(lastMouseEvent.ctrl || lastMouseEvent.command);
        QVERIFY(!lastMouseEvent.shift);
        QVERIFY(!lastMouseEvent.alt);
    }

    // The Lua side delivers exact float coordinates (no integer snapping
    // in the time->pixel map), so rasterization quality is the painter's
    // job. Domain rules pinned here:
    //
    // 1. A hairline (1px) rect renders at FULL intensity at every
    //    fractional x position. Without device-grid snapping, AA smears
    //    a fractional hairline across two columns at partial alpha, and
    //    the timeline's clip-boundary stripes pulse bright/dim while
    //    panning (Joe's "scrolling flickers", 2026-06-09).
    void testHairlineCrispAtFractionalPositions() {
        timeline->resize(200, 60);
        const qreal offsets[] = {10.0, 10.25, 10.5, 10.75};
        for (qreal x : offsets) {
            timeline->clearCommands();
            timeline->addRect(x, 10, 1, 40, "#ffffff");
            QImage img = timeline->grab().toImage();
            const qreal dpr = img.devicePixelRatio();
            const int row = int(30 * dpr);
            // A 1-logical-px hairline must occupy exactly dpr device
            // columns at full intensity — a fractional position smeared
            // by AA lights dpr+1 columns with dim ends and never reaches
            // a stable appearance while panning.
            int maxv = 0, lit = 0;
            for (int c = int(5 * dpr); c < int(20 * dpr); ++c) {
                const int v = qRed(img.pixel(c, row));
                maxv = qMax(maxv, v);
                if (v > 55) lit++;  // background is #232323 (35)
            }
            QVERIFY2(maxv == 255, qPrintable(QString(
                "hairline at x=%1 peaked at %2/255 — AA smeared it across "
                "columns; it will pulse while panning").arg(x).arg(maxv)));
            QVERIFY2(lit <= int(dpr + 0.5), qPrintable(QString(
                "hairline at x=%1 lights %2 device columns (expected %3) — "
                "fractional edges bleed while panning").arg(x).arg(lit).arg(int(dpr + 0.5))));
        }
    }

    // 3. A clip's drawn width never changes while panning. Scrolling moves
    //    viewport_start in whole frames but ppf is fractional, so every
    //    edge shifts by a fractional number of device pixels per step;
    //    snapping edges independently on the VIEWPORT grid makes each
    //    clip's width breathe between N and N+1 device columns at
    //    different scroll positions — the field shimmers (Joe's
    //    "scrolling still feels like it flickers", 2026-06-09). The
    //    renderer must anchor snapping to the CONTENT grid: given the
    //    pan offset, snap content coordinates and translate by whole
    //    device pixels.
    void testClipWidthRigidWhilePanning() {
        timeline->resize(200, 60);
        const qreal content_left = 100.37, width_px = 30.4;
        int first_width = -1;
        for (int step = 0; step <= 9; ++step) {
            const qreal pan = step * 0.31;  // fractional logical px, like real scroll steps
            timeline->clearCommands();
            timeline->setPanOffsetPx(pan);
            timeline->addRect(content_left - pan, 10, width_px, 40, "#ffffff");
            QImage img = timeline->grab().toImage();
            const qreal dpr = img.devicePixelRatio();
            const int row = int(30 * dpr);
            int lit = 0;
            for (int c = int(80 * dpr); c < int(145 * dpr); ++c) {
                if (qRed(img.pixel(c, row)) > 128) lit++;
            }
            if (first_width < 0) first_width = lit;
            QVERIFY2(lit == first_width, qPrintable(QString(
                "pan=%1: clip spans %2 device columns (first frame had %3) — "
                "width breathes while panning, the timeline shimmers")
                .arg(pan).arg(lit).arg(first_width)));
        }
    }

    // 2. Two same-color rects sharing a fractional edge (abutting clips)
    //    tile seamlessly — no darker AA seam column at the shared edge.
    void testAbuttingRectsNoSeam() {
        timeline->resize(200, 60);
        timeline->clearCommands();
        timeline->addRect(10.0, 10, 30.4, 40, "#808080");
        timeline->addRect(40.4, 10, 30.0, 40, "#808080");
        QImage img = timeline->grab().toImage();
        const qreal dpr = img.devicePixelRatio();
        const int row = int(30 * dpr);
        for (int c = int(12 * dpr); c < int(68 * dpr); ++c) {
            const int v = qRed(img.pixel(c, row));
            QVERIFY2(v == 0x80, qPrintable(QString(
                "column %1 = %2 (expected 128) — AA seam/gap at the shared "
                "fractional edge between abutting clips").arg(c).arg(v)));
        }
    }
};

// Static member initialization
TestTimelineRendererWidget::EventData TestTimelineRendererWidget::lastMouseEvent;
TestTimelineRendererWidget::EventData TestTimelineRendererWidget::lastKeyEvent;

QTEST_MAIN(TestTimelineRendererWidget)
#include "test_timeline_renderer_widget.moc"
