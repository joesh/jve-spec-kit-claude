#include <QtTest/QtTest>
#include <QApplication>
#include <QSqlDatabase>
#include <QSqlQuery>
#include <QTemporaryDir>
#include <QPoint>
#include <QRect>
#include <QDateTime>
#include <QFileInfo>
#include <QSqlError>
#include <QCoreApplication>
#include <QMouseEvent>
#include <QByteArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <limits>

#include "../../src/lua/simple_lua_engine.h"
#include "../../src/ui/timeline/scriptable_timeline.h"
#include "../../src/core/persistence/migrations.h"
#include "../../src/core/resource_paths.h"

#include <algorithm>
#include <cmath>

namespace {
const bool kForceOffscreenPlatform = []() {
    qputenv("QT_QPA_PLATFORM", QByteArrayLiteral("offscreen"));
    return true;
}();
}  // namespace

class TestBatchRippleGapDrag : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase();
    void cleanupTestCase();
    void init();
    void cleanup();

    void testCanonicalGapDragRight();
    void testGapDragClampsToNeighbor();

private:
    void waitForUi();
    void executeLua(const QString& code);
    double getLuaNumber(const char* globalName);
    QJsonObject getLuaJsonObject(const char* globalName);
    void populateCanonicalScenario();
    void reloadTimelineState();
    JVE::ScriptableTimeline* locateVideoTimeline();
    void fetchTimelineMetrics();
    QPoint pointForEdge(const QString& clipId, bool insideClip) const;
    int timeToPixel(int timeMs) const;

    QTemporaryDir* m_tempDir = nullptr;
    QString m_dbPath;
    QSqlDatabase m_db;
    QString m_connectionName;
    int m_connectionCounter = 0;

    SimpleLuaEngine* m_luaEngine = nullptr;
    QWidget* m_mainWindow = nullptr;
    JVE::ScriptableTimeline* m_videoTimeline = nullptr;

    double m_viewportStart = 0.0;
    double m_viewportDuration = 10000.0;
    double m_trackHeightV1 = 50.0;
    double m_trackHeightV2 = 50.0;
    int m_videoWidgetWidth = 0;
    int m_videoWidgetHeight = 0;
    QRect m_clipRectV2;
    QRect m_clipRectV1;
};

void TestBatchRippleGapDrag::initTestCase()
{
    m_tempDir = new QTemporaryDir();
    QVERIFY(m_tempDir->isValid());

    Migrations::initialize();

}

void TestBatchRippleGapDrag::cleanupTestCase()
{
    if (m_db.isValid() && m_db.isOpen()) {
        m_db.close();
    }
    if (!m_connectionName.isEmpty()) {
        QString name = m_connectionName;
        m_connectionName.clear();
        m_db = QSqlDatabase();
        QSqlDatabase::removeDatabase(name);
    }
    m_dbPath.clear();

    delete m_tempDir;
    m_tempDir = nullptr;
}

void TestBatchRippleGapDrag::init()
{
    // Recreate fresh project database for each test to avoid residual locks
    // Clean out timeline-specific tables while keeping project/track metadata intact
    if (m_luaEngine) {
        executeLua(R"(
            local db = require('core.database')
            local conn = db.get_connection()
            if conn then
                conn:close()
            end
        )");
    }

    m_dbPath = m_tempDir->path() + QStringLiteral("/batch_ripple_gap_drag_%1.db").arg(++m_connectionCounter);
    QVERIFY(Migrations::createNewProject(m_dbPath));

    if (m_db.isValid() && m_db.isOpen()) {
        m_db.close();
        if (!m_connectionName.isEmpty()) {
            QString name = m_connectionName;
            m_connectionName.clear();
            m_db = QSqlDatabase();
            QSqlDatabase::removeDatabase(name);
        }
    }

    m_connectionName = QStringLiteral("test_batch_ripple_gap_drag_conn_%1").arg(m_connectionCounter);
    m_db = QSqlDatabase::addDatabase("QSQLITE", m_connectionName);
    m_db.setDatabaseName(m_dbPath);
    QVERIFY(m_db.open());

    // Ensure the Lua runtime points at our test database
    qputenv("JVE_TEST_MODE", "1");
    qputenv("JVE_PROJECT_PATH", m_dbPath.toUtf8());

    // Seed canonical scenario before initializing UI (avoids connection locking)
    populateCanonicalScenario();

    m_luaEngine = new SimpleLuaEngine();
    QString layoutScript = QString::fromStdString(
        JVE::ResourcePaths::getScriptPath("ui/layout.lua")
    );
    QVERIFY(QFileInfo(layoutScript).exists());
    QVERIFY(m_luaEngine->executeFile(layoutScript));

    m_mainWindow = m_luaEngine->getCreatedMainWindow();
    QVERIFY(m_mainWindow != nullptr);

    reloadTimelineState();

    // Locate the video timeline widget used for user interactions
    m_videoTimeline = locateVideoTimeline();
    QVERIFY(m_videoTimeline != nullptr);
    m_videoTimeline->setFocus(Qt::OtherFocusReason);
    m_videoTimeline->resize(1200, 200);
    waitForUi();

    fetchTimelineMetrics();
}

void TestBatchRippleGapDrag::cleanup()
{
    if (m_luaEngine) {
        executeLua(R"(
            local db = require('core.database')
            local conn = db.get_connection()
            if conn then
                conn:close()
            end
        )");
    }

    if (m_mainWindow) {
        m_mainWindow->close();
        m_mainWindow = nullptr;
    }

    delete m_luaEngine;
    m_luaEngine = nullptr;
    m_videoTimeline = nullptr;

    if (m_db.isOpen()) {
        m_db.close();
    }
    if (!m_connectionName.isEmpty()) {
        QString name = m_connectionName;
        m_connectionName.clear();
        m_db = QSqlDatabase();
        QSqlDatabase::removeDatabase(name);
    }

}

void TestBatchRippleGapDrag::waitForUi()
{
    QTest::qWait(100);
    QApplication::processEvents();
}

void TestBatchRippleGapDrag::executeLua(const QString& code)
{
    QVERIFY2(m_luaEngine && m_luaEngine->executeString(code),
             qPrintable(QStringLiteral("Lua execution failed: %1").arg(m_luaEngine->getLastError())));
}

double TestBatchRippleGapDrag::getLuaNumber(const char* globalName)
{
    lua_State* L = m_luaEngine->getLuaState();
    lua_getglobal(L, globalName);
    if (!lua_isnumber(L, -1)) {
        QString message = QStringLiteral("Lua global '%1' is not numeric").arg(globalName);
        lua_pop(L, 1);
        QTest::qFail(message.toUtf8().constData(), __FILE__, __LINE__);
        return 0.0;
    }
    double value = lua_tonumber(L, -1);
    lua_pop(L, 1);
    return value;
}

QJsonObject TestBatchRippleGapDrag::getLuaJsonObject(const char* globalName)
{
    QJsonObject result;
    lua_State* L = m_luaEngine->getLuaState();
    lua_getglobal(L, globalName);

    if (lua_isstring(L, -1)) {
        size_t length = 0;
        const char* jsonChars = lua_tolstring(L, -1, &length);
        if (jsonChars && length > 0) {
            const QByteArray payload(jsonChars, static_cast<int>(length));
            const QJsonDocument doc = QJsonDocument::fromJson(payload);
            if (!doc.isNull() && doc.isObject()) {
                result = doc.object();
            }
        }
    }

    lua_pop(L, 1);
    return result;
}

void TestBatchRippleGapDrag::populateCanonicalScenario()
{
    const qint64 now = QDateTime::currentSecsSinceEpoch();

    // Temporarily release Lua-side database handle to avoid write locks
    if (m_luaEngine) {
        executeLua(R"(
            local db = require('core.database')
            local conn = db.get_connection()
            if conn then
                conn:close()
            end
        )");
    }

    // Determine available media columns (schema varies between revisions)
    QStringList mediaColumns;
    {
        QSqlQuery pragma(m_db);
        QVERIFY2(pragma.exec("PRAGMA table_info(media)"), pragma.lastError().text().toUtf8().constData());
        while (pragma.next()) {
            mediaColumns << pragma.value(1).toString();
        }
    }

    {
        QSqlQuery pragma(m_db);
        QVERIFY2(pragma.exec("PRAGMA table_info(commands)"), pragma.lastError().text().toUtf8().constData());
        QStringList commandColumns;
        while (pragma.next()) {
            commandColumns << pragma.value(1).toString();
        }

        if (!commandColumns.contains("parent_sequence_number")) {
            QSqlQuery alter(m_db);
            QVERIFY2(alter.exec("ALTER TABLE commands ADD COLUMN parent_sequence_number INTEGER"), alter.lastError().text().toUtf8().constData());
            QVERIFY2(alter.exec("ALTER TABLE commands ADD COLUMN playhead_time INTEGER NOT NULL DEFAULT 0"), alter.lastError().text().toUtf8().constData());
            QVERIFY2(alter.exec("ALTER TABLE commands ADD COLUMN selected_clip_ids TEXT"), alter.lastError().text().toUtf8().constData());
            QVERIFY2(alter.exec("ALTER TABLE commands ADD COLUMN selected_edge_infos TEXT"), alter.lastError().text().toUtf8().constData());
        }
    }

    auto ensureColumn = [&](const char* name) {
        const QString column = QString::fromLatin1(name);
        QVERIFY2(mediaColumns.contains(column), qPrintable(QStringLiteral("Media table missing required column '%1'").arg(column)));
    };

    ensureColumn("id");
    ensureColumn("file_path");
    ensureColumn("duration");

    const bool hasNameColumn = mediaColumns.contains(QStringLiteral("name"));
    const bool hasFileNameColumn = mediaColumns.contains(QStringLiteral("file_name"));
    QVERIFY2(hasNameColumn || hasFileNameColumn,
             "Media table missing both 'name' and 'file_name' columns");

    auto quote = [](const QString& value) {
        QString escaped = value;
        escaped.replace("'", "''");
        return QStringLiteral("'%1'").arg(escaped);
    };

    auto buildMediaInsert = [&](const QString& id,
                                const QString& name,
                                const QString& path,
                                int duration) -> QString {
        QStringList columns;
        QStringList values;

        auto appendIfPresent = [&](const char* column, const QString& value) {
            const QString colName = QString::fromLatin1(column);
            if (mediaColumns.contains(colName)) {
                columns << colName;
                values << value;
            }
        };

        appendIfPresent("id", quote(id));
        appendIfPresent("project_id", quote(QStringLiteral("default_project")));
        if (hasNameColumn) {
            appendIfPresent("name", quote(name));
        }
        if (hasFileNameColumn) {
            appendIfPresent("file_name", quote(name));
        }
        appendIfPresent("file_path", quote(path));
        appendIfPresent("duration", QString::number(duration));
        appendIfPresent("frame_rate", QStringLiteral("30.0"));
        appendIfPresent("width", QString::number(1920));
        appendIfPresent("height", QString::number(1080));
        appendIfPresent("audio_channels", QString::number(2));
        appendIfPresent("codec", quote(QStringLiteral("prores")));
        appendIfPresent("file_size", QString::number(0));
        appendIfPresent("created_at", QString::number(now));
        appendIfPresent("modified_at", QString::number(now));

        if (columns.isEmpty()) {
            QTest::qFail("Unable to construct media insert statement", __FILE__, __LINE__);
            return QString();
        }

        return QStringLiteral("INSERT INTO media (%1) VALUES (%2)")
            .arg(columns.join(", "))
            .arg(values.join(", "));
    };

    {
        QSqlQuery insertMedia(m_db);
        const QString sql = buildMediaInsert(
            QStringLiteral("media_v2_clip"),
            QStringLiteral("Clip A"),
            QStringLiteral("/tmp/clip_a.mov"),
            8000
        );
        QVERIFY2(insertMedia.exec(sql), insertMedia.lastError().text().toUtf8().constData());
    }

    {
        QSqlQuery insertMedia(m_db);
        const QString sql = buildMediaInsert(
            QStringLiteral("media_v1_clip"),
            QStringLiteral("Clip B"),
            QStringLiteral("/tmp/clip_b.mov"),
            10000
        );
        QVERIFY2(insertMedia.exec(sql), insertMedia.lastError().text().toUtf8().constData());
    }

    // Insert V2 clip A spanning 0-5s
    {
        QSqlQuery insertClip(m_db);
        insertClip.prepare("INSERT INTO clips (id, track_id, media_id, start_time, duration, source_in, source_out, enabled)"
                           " VALUES ('clip_v2_a', 'video2', 'media_v2_clip', 0, 5000, 0, 5000, 1)");
        QVERIFY2(insertClip.exec(), insertClip.lastError().text().toUtf8().constData());
    }

    // Insert V1 clip B starting at 3s (gap before)
    {
        QSqlQuery insertClip(m_db);
        insertClip.prepare("INSERT INTO clips (id, track_id, media_id, start_time, duration, source_in, source_out, enabled)"
                           " VALUES ('clip_v1_b', 'video1', 'media_v1_clip', 3000, 5000, 0, 5000, 1)");
        QVERIFY2(insertClip.exec(), insertClip.lastError().text().toUtf8().constData());
    }

    // Re-open Lua database connection for subsequent commands
    if (m_luaEngine) {
        executeLua(R"(
            local db = require('core.database')
            local path = db.get_path()
            if path then
                db.set_path(path)
            end
        )");
        waitForUi();
    }
}

void TestBatchRippleGapDrag::reloadTimelineState()
{
    executeLua(R"(
        local timeline_state = require('ui.timeline.timeline_state')
        timeline_state.reload_clips()
    )");
    waitForUi();
}

JVE::ScriptableTimeline* TestBatchRippleGapDrag::locateVideoTimeline()
{
    const auto timelines = m_mainWindow->findChildren<JVE::ScriptableTimeline*>();
    if (timelines.isEmpty()) {
        return nullptr;
    }

    JVE::ScriptableTimeline* best = nullptr;
    int bestScore = std::numeric_limits<int>::min();

    for (JVE::ScriptableTimeline* timeline : timelines) {
        const QSize size = timeline->size();
        const QPoint globalPos = timeline->mapToGlobal(QPoint(0, 0));
        const int score = size.height() * 10 - globalPos.y();
        if (!best || score > bestScore) {
            best = timeline;
            bestScore = score;
        }
    }

    return best;
}

void TestBatchRippleGapDrag::fetchTimelineMetrics()
{
    executeLua(R"(
        local state = require('ui.timeline.timeline_state')
        TEST_viewport_start = state.get_viewport_start_time()
        TEST_viewport_duration = state.get_viewport_duration()
        TEST_track_height_v1 = state.get_track_height('video1')
        TEST_track_height_v2 = state.get_track_height('video2')
        local layout = state.debug_get_layout_metrics('video')
        if layout then
            TEST_video_layout = qt_json_encode(layout)
        else
            TEST_video_layout = ''
        end
        local clip_v2 = state.debug_get_clip_layout('video', 'clip_v2_a')
        if clip_v2 then
            TEST_clip_v2_layout = qt_json_encode(clip_v2)
        else
            TEST_clip_v2_layout = ''
        end
        local clip_v1 = state.debug_get_clip_layout('video', 'clip_v1_b')
        if clip_v1 then
            TEST_clip_v1_layout = qt_json_encode(clip_v1)
        else
            TEST_clip_v1_layout = ''
        end
    )");

    m_viewportStart = getLuaNumber("TEST_viewport_start");
    m_viewportDuration = getLuaNumber("TEST_viewport_duration");
    m_trackHeightV1 = getLuaNumber("TEST_track_height_v1");
    m_trackHeightV2 = getLuaNumber("TEST_track_height_v2");

    const QJsonObject videoLayout = getLuaJsonObject("TEST_video_layout");
    m_videoWidgetWidth = videoLayout.value("widget_width").toInt(m_videoTimeline->width());
    m_videoWidgetHeight = videoLayout.value("widget_height").toInt(m_videoTimeline->height());

    const auto buildRect = [](const QJsonObject& obj) -> QRect {
        if (obj.isEmpty()) {
            return QRect();
        }
        const int x = obj.value("x").toInt();
        const int y = obj.value("y").toInt();
        const int width = obj.value("width").toInt();
        const int height = obj.value("height").toInt();
        return QRect(x, y, width, height);
    };

    m_clipRectV2 = buildRect(getLuaJsonObject("TEST_clip_v2_layout"));
    m_clipRectV1 = buildRect(getLuaJsonObject("TEST_clip_v1_layout"));

}

int TestBatchRippleGapDrag::timeToPixel(int timeMs) const
{
    const double layoutWidth = static_cast<double>(m_videoWidgetWidth > 0 ? m_videoWidgetWidth
                                                                         : m_videoTimeline->width());
    const double pixelsPerMs = layoutWidth / m_viewportDuration;
    const double layoutRelative = (static_cast<double>(timeMs) - m_viewportStart) * pixelsPerMs;

    const double scaleX = (m_videoWidgetWidth > 0)
                              ? static_cast<double>(m_videoTimeline->width()) / m_videoWidgetWidth
                              : 1.0;
    const double actualRelative = layoutRelative * scaleX;

    return static_cast<int>(std::floor(actualRelative));
}

QPoint TestBatchRippleGapDrag::pointForEdge(const QString& clipId, bool insideClip) const
{
    const QRect clipRect = (clipId == QLatin1String("clip_v2_a")) ? m_clipRectV2 : m_clipRectV1;

    const int actualWidth = std::max(1, m_videoTimeline->width());
    const int actualHeight = std::max(1, m_videoTimeline->height());

    if (clipRect.isNull()) {
        // Fallback to center of widget if layout data is unavailable
        const int fallbackX = insideClip ? actualWidth / 2 : (actualWidth / 2) - 8;
        const int fallbackY = actualHeight / 2;
        return QPoint(std::clamp(fallbackX, 0, actualWidth - 1),
                      std::clamp(fallbackY, 0, actualHeight - 1));
    }

    const double scaleX = (m_videoWidgetWidth > 0)
                              ? static_cast<double>(actualWidth) / m_videoWidgetWidth
                              : 1.0;
    const double scaleY = (m_videoWidgetHeight > 0)
                              ? static_cast<double>(actualHeight) / m_videoWidgetHeight
                              : 1.0;

    const double layoutX = insideClip ? (clipRect.x() + std::min(8, clipRect.width() / 3))
                                      : (clipRect.x() - 6);
    const double layoutY = clipRect.center().y();

    int x = static_cast<int>(std::round(layoutX * scaleX));
    int y = static_cast<int>(std::round(layoutY * scaleY));

    x = std::clamp(x, 0, actualWidth - 1);
    y = std::clamp(y, 0, actualHeight - 1);

    return QPoint(x, y);
}

void TestBatchRippleGapDrag::testCanonicalGapDragRight()
{
    QVERIFY(m_videoTimeline != nullptr);

    // Ensure widget receives mouse events
    m_videoTimeline->setAttribute(Qt::WA_TransparentForMouseEvents, false);
    m_videoTimeline->show();
    waitForUi();

    // Move playhead away from zero so snapping doesn't pull to origin
    executeLua("require('ui.timeline.timeline_state').set_playhead_time(5000)");
    waitForUi();

    const auto sendMouseEvent = [&](QEvent::Type type, const QPoint& localPos, Qt::MouseButton button,
                                    Qt::MouseButtons buttons, Qt::KeyboardModifiers modifiers) {
        const QPoint globalPos = m_videoTimeline->mapToGlobal(localPos);
        QMouseEvent event(type,
                          QPointF(localPos),
                          QPointF(localPos),
                          QPointF(globalPos),
                          button,
                          buttons,
                          modifiers,
                          Qt::MouseEventSource::MouseEventNotSynthesized);
        QCoreApplication::sendEvent(m_videoTimeline, &event);
    };

    const QPoint v2InPoint = pointForEdge("clip_v2_a", true);
    sendMouseEvent(QEvent::MouseMove, v2InPoint, Qt::NoButton, Qt::NoButton, Qt::NoModifier);
    sendMouseEvent(QEvent::MouseButtonPress, v2InPoint, Qt::LeftButton, Qt::LeftButton, Qt::NoModifier);
    sendMouseEvent(QEvent::MouseButtonRelease, v2InPoint, Qt::LeftButton, Qt::NoButton, Qt::NoModifier);
    waitForUi();

    executeLua(R"(
        local state = require('ui.timeline.timeline_state')
        TEST_edge_count = #state.get_selected_edges()
    )");
    QCOMPARE(static_cast<int>(getLuaNumber("TEST_edge_count")), 1);

    const QPoint v1GapPoint = pointForEdge("clip_v1_b", false);
#ifdef Q_OS_MAC
    const Qt::KeyboardModifiers commandModifier = Qt::ControlModifier;
#else
    const Qt::KeyboardModifiers commandModifier = Qt::MetaModifier;
#endif

    sendMouseEvent(QEvent::MouseMove, v1GapPoint, Qt::NoButton, Qt::NoButton, commandModifier);
    sendMouseEvent(QEvent::MouseButtonPress, v1GapPoint, Qt::LeftButton, Qt::LeftButton, commandModifier);
    sendMouseEvent(QEvent::MouseButtonRelease, v1GapPoint, Qt::LeftButton, Qt::NoButton, commandModifier);
    waitForUi();

    executeLua(R"(
        local state = require('ui.timeline.timeline_state')
        TEST_edge_count = #state.get_selected_edges()
    )");
    QCOMPARE(static_cast<int>(getLuaNumber("TEST_edge_count")), 2);

    // Drag V2 bracket (with gap edge still selected) to the right by 1000ms
    const int deltaPixels = timeToPixel(1000) - timeToPixel(0);
    const QPoint dragTarget = v2InPoint + QPoint(deltaPixels, 0);

    sendMouseEvent(QEvent::MouseButtonPress, v2InPoint, Qt::LeftButton, Qt::LeftButton, Qt::NoModifier);
    sendMouseEvent(QEvent::MouseMove, v2InPoint + QPoint(10, 0), Qt::NoButton, Qt::LeftButton, Qt::NoModifier);
    sendMouseEvent(QEvent::MouseMove, dragTarget, Qt::NoButton, Qt::LeftButton, Qt::NoModifier);
    sendMouseEvent(QEvent::MouseButtonRelease, dragTarget, Qt::LeftButton, Qt::NoButton, Qt::NoModifier);
    waitForUi();

    // Verify timeline changes were persisted using Lua-side database access
    executeLua(R"LUAVAL(
        local db = require('core.database')
        local conn = db.get_connection()
        local stmt = conn:prepare("SELECT duration, source_in FROM clips WHERE id='clip_v2_a'")
        assert(stmt and stmt:exec(), "clip_v2_a query failed")
        assert(stmt:next(), "clip_v2_a missing after canonical drag")
        TEST_clip_v2_duration = stmt:value(0)
        TEST_clip_v2_source_in = stmt:value(1)
        stmt:finalize()

        local stmt_b = conn:prepare("SELECT start_time, duration FROM clips WHERE id='clip_v1_b'")
        assert(stmt_b and stmt_b:exec(), "clip_v1_b query failed")
        assert(stmt_b:next(), "clip_v1_b missing after canonical drag")
        TEST_clip_v1_b_start = stmt_b:value(0)
        TEST_clip_v1_b_duration = stmt_b:value(1)
        stmt_b:finalize()
    )LUAVAL");

    QCOMPARE(static_cast<int>(getLuaNumber("TEST_clip_v2_duration")), 4000);  // duration shortened by 1s
    QCOMPARE(static_cast<int>(getLuaNumber("TEST_clip_v2_source_in")), 1000);  // source advanced by 1s
    QCOMPARE(static_cast<int>(getLuaNumber("TEST_clip_v1_b_start")), 2000);  // clip moved left by 1s (gap closed)
    QCOMPARE(static_cast<int>(getLuaNumber("TEST_clip_v1_b_duration")), 5000);  // duration unchanged
}

void TestBatchRippleGapDrag::testGapDragClampsToNeighbor()
{
    QVERIFY(m_videoTimeline != nullptr);

    m_videoTimeline->setAttribute(Qt::WA_TransparentForMouseEvents, false);
    m_videoTimeline->show();
    waitForUi();

    executeLua("require('ui.timeline.timeline_state').set_playhead_time(5000)");
    waitForUi();

    executeLua(R"LUACODE(
        local db = require('core.database')
        local conn = db.get_connection()
        local insert = conn:prepare("INSERT INTO clips (id, track_id, media_id, start_time, duration, source_in, source_out, enabled) VALUES ('extra_clip', 'video1', 'media_v1_clip', 0, 2000, 0, 2000, 1)")
        assert(insert:exec())
        insert:finalize()
    )LUACODE");
    reloadTimelineState();
    fetchTimelineMetrics();
    waitForUi();

    const auto sendMouseEvent = [&](QEvent::Type type, const QPoint& localPos, Qt::MouseButton button,
                                    Qt::MouseButtons buttons, Qt::KeyboardModifiers modifiers) {
        const QPoint globalPos = m_videoTimeline->mapToGlobal(localPos);
        QMouseEvent event(type, localPos, globalPos, button, buttons, modifiers);
        QCoreApplication::sendEvent(m_videoTimeline, &event);
    };

    const QPoint v2InPoint = pointForEdge("clip_v2_a", true);
    sendMouseEvent(QEvent::MouseMove, v2InPoint, Qt::NoButton, Qt::NoButton, Qt::NoModifier);
    sendMouseEvent(QEvent::MouseButtonPress, v2InPoint, Qt::LeftButton, Qt::LeftButton, Qt::NoModifier);
    sendMouseEvent(QEvent::MouseButtonRelease, v2InPoint, Qt::LeftButton, Qt::NoButton, Qt::NoModifier);
    waitForUi();

    executeLua(R"(
        local state = require('ui.timeline.timeline_state')
        TEST_edge_count = #state.get_selected_edges()
    )");
    QCOMPARE(static_cast<int>(getLuaNumber("TEST_edge_count")), 1);

    const QPoint v1GapPoint = pointForEdge("clip_v1_b", false);
#ifdef Q_OS_MAC
    const Qt::KeyboardModifiers commandModifier = Qt::ControlModifier;
#else
    const Qt::KeyboardModifiers commandModifier = Qt::MetaModifier;
#endif

    sendMouseEvent(QEvent::MouseMove, v1GapPoint, Qt::NoButton, Qt::NoButton, commandModifier);
    sendMouseEvent(QEvent::MouseButtonPress, v1GapPoint, Qt::LeftButton, Qt::LeftButton, commandModifier);
    sendMouseEvent(QEvent::MouseButtonRelease, v1GapPoint, Qt::LeftButton, Qt::NoButton, commandModifier);
    waitForUi();

    executeLua(R"(
        local state = require('ui.timeline.timeline_state')
        TEST_edge_count = #state.get_selected_edges()
    )");
    QCOMPARE(static_cast<int>(getLuaNumber("TEST_edge_count")), 2);

    // Attempt to drag right by 5000ms (greater than available 1000ms gap)
    const int deltaPixels = timeToPixel(5000) - timeToPixel(0);
    const QPoint dragTarget = v2InPoint + QPoint(deltaPixels, 0);

    sendMouseEvent(QEvent::MouseButtonPress, v2InPoint, Qt::LeftButton, Qt::LeftButton, Qt::NoModifier);
    sendMouseEvent(QEvent::MouseMove, v2InPoint + QPoint(10, 0), Qt::NoButton, Qt::LeftButton, Qt::NoModifier);
    sendMouseEvent(QEvent::MouseMove, dragTarget, Qt::NoButton, Qt::LeftButton, Qt::NoModifier);
    sendMouseEvent(QEvent::MouseButtonRelease, dragTarget, Qt::LeftButton, Qt::NoButton, Qt::NoModifier);
    waitForUi();

    executeLua(R"LUA(
        local db = require('core.database')
        local conn = db.get_connection()
        local stmt = conn:prepare("SELECT duration, source_in FROM clips WHERE id='clip_v2_a'")
        assert(stmt and stmt:exec(), "clip_v2_a query failed (clamp test)")
        assert(stmt:next(), "clip_v2_a missing after clamp drag")
        TEST_clip_v2_duration = stmt:value(0)
        TEST_clip_v2_source_in = stmt:value(1)
        stmt:finalize()

        local stmt_b = conn:prepare("SELECT start_time FROM clips WHERE id='clip_v1_b'")
        assert(stmt_b and stmt_b:exec(), "clip_v1_b query failed (clamp test)")
        assert(stmt_b:next(), "clip_v1_b missing after clamp drag")
        TEST_clip_v1_b_start = stmt_b:value(0)
        stmt_b:finalize()

        local stmt_a = conn:prepare("SELECT start_time, duration FROM clips WHERE id='extra_clip'")
        assert(stmt_a and stmt_a:exec(), "extra_clip query failed (clamp test)")
        assert(stmt_a:next(), "extra_clip missing after clamp drag")
        TEST_clip_extra_start = stmt_a:value(0)
        TEST_clip_extra_duration = stmt_a:value(1)
        stmt_a:finalize()
    )LUA");

    QCOMPARE(static_cast<int>(getLuaNumber("TEST_clip_v2_duration")), 4000);  // clamp to 1000ms trim
    QCOMPARE(static_cast<int>(getLuaNumber("TEST_clip_v2_source_in")), 1000);
    QCOMPARE(static_cast<int>(getLuaNumber("TEST_clip_v1_b_start")), 2000);  // clipped to neighbor's out-point
    QCOMPARE(static_cast<int>(getLuaNumber("TEST_clip_extra_start")), 0);
    QCOMPARE(static_cast<int>(getLuaNumber("TEST_clip_extra_duration")), 2000);


    executeLua(R"(
        local db = require('core.database')
        local conn = db.get_connection()
        if conn then
            conn:close()
        end
    )");
}

QTEST_MAIN(TestBatchRippleGapDrag)

#include "test_batch_ripple_gap_drag.moc"
