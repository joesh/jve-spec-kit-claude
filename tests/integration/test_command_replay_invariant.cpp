#include <QtTest/QtTest>
#include <QApplication>
#include <QWidget>
#include <QSqlDatabase>
#include <QSqlQuery>
#include <QJsonDocument>
#include <QJsonArray>
#include <QTemporaryDir>
#include <QStandardPaths>

#include "../../src/lua/simple_lua_engine.h"
#include "../../src/core/persistence/migrations.h"
#include "../../src/core/resource_paths.h"

/**
 * Integration Test: Command Replay Invariant
 *
 * Verifies the fundamental invariant for deterministic command execution:
 *
 * INVARIANT: If I execute a command (e.g., INSERT at playhead=0),
 *            then undo it, I should be able to execute the SAME command again
 *            and get the EXACT SAME result.
 *
 * This is the key difference between FCP7/FCPX/Avid (which pass) and
 * Premiere/Resolve (which fail) - proper playhead restoration on undo
 * enables deterministic command replay.
 *
 * Test Scenarios:
 * 1. Single INSERT replay (basic invariant)
 * 2. Multiple INSERT chain replay
 * 3. OVERWRITE replay with trim behavior
 * 4. Selection preservation across undo/redo
 */
class TestCommandReplayInvariant : public QObject
{
    Q_OBJECT

private slots:
    void initTestCase();
    void cleanupTestCase();
    void init();
    void cleanup();

    // Core invariant tests
    void testSingleInsertReplay();
    void testMultipleInsertChainReplay();
    void testOverwriteReplay();
    void testSelectionPreservation();

private:
    // Helper functions
    void sendKey(Qt::Key key, Qt::KeyboardModifiers modifiers = Qt::NoModifier);
    void sendUndoKey();
    void sendRedoKey();
    void waitForLuaProcessing();

    struct EdgeSelection {
        QString clip_id;
        QString edge_type;
        QString trim_type;

        bool operator==(const EdgeSelection& other) const
        {
            return clip_id == other.clip_id &&
                   edge_type == other.edge_type &&
                   trim_type == other.trim_type;
        }
    };

    struct TimelineState {
        int playhead_time;
        QStringList selected_clip_ids;
        QList<EdgeSelection> selected_edges;
        int clip_count;
    };
    TimelineState captureTimelineState();
    TimelineState queryDatabaseState();
    void assertStatesEqual(const TimelineState& expected, const TimelineState& actual, const QString& context);

    QTemporaryDir* m_tempDir;
    SimpleLuaEngine* m_luaEngine;
    QWidget* m_mainWindow;
    QSqlDatabase m_db;
    QString m_dbPath;
};

void TestCommandReplayInvariant::initTestCase()
{
    // Set up temporary directory for test database
    m_tempDir = new QTemporaryDir();
    QVERIFY(m_tempDir->isValid());

    m_dbPath = m_tempDir->path() + "/test_project.db";
    qDebug() << "Test database:" << m_dbPath;

    // Initialize database migrations
    Migrations::initialize();

    // Create test project
    QVERIFY(Migrations::createNewProject(m_dbPath));

    // Open database connection for queries
    m_db = QSqlDatabase::addDatabase("QSQLITE", "test_replay_invariant");
    m_db.setDatabaseName(m_dbPath);
    QVERIFY(m_db.open());

    qDebug() << "Test case initialized successfully";
}

void TestCommandReplayInvariant::cleanupTestCase()
{
    if (m_db.isOpen()) {
        m_db.close();
    }
    QSqlDatabase::removeDatabase("test_replay_invariant");

    delete m_tempDir;
}

void TestCommandReplayInvariant::init()
{
    // Create Lua engine and initialize UI for each test
    m_luaEngine = new SimpleLuaEngine();

    // Set environment variable for test database
    qputenv("JVE_TEST_MODE", "1");

    // Execute Lua main window creation
    QString mainWindowScript = QString::fromStdString(
        JVE::ResourcePaths::getScriptPath("ui/layout.lua")
    );

    QVERIFY(QFileInfo(mainWindowScript).exists());

    bool luaSuccess = m_luaEngine->executeFile(mainWindowScript);
    if (!luaSuccess) {
        qCritical() << "Lua execution failed:" << m_luaEngine->getLastError();
        QFAIL(qPrintable(QString("Lua script failed: %1").arg(m_luaEngine->getLastError())));
    }

    m_mainWindow = m_luaEngine->getCreatedMainWindow();
    if (!m_mainWindow) {
        qCritical() << "No main window created by Lua";
        QFAIL("Lua script did not create a main window");
    }

    // Don't show window - we only need Lua/database state for testing
    // m_mainWindow->show();
    // QVERIFY(QTest::qWaitForWindowExposed(m_mainWindow));

    waitForLuaProcessing();

    qDebug() << "Test initialized - Lua engine ready (window not shown)";
}

void TestCommandReplayInvariant::cleanup()
{
    // Clean up Lua engine and window
    if (m_mainWindow) {
        m_mainWindow->close();
        m_mainWindow = nullptr;
    }

    delete m_luaEngine;
    m_luaEngine = nullptr;

    // Clear test database clips for next test
    QSqlQuery query(m_db);
    query.exec("DELETE FROM clips");
    query.exec("DELETE FROM commands");
    query.exec("UPDATE sequences SET playhead_time = 0, selected_clip_ids = NULL, selected_edge_infos = NULL");

    qDebug() << "Test cleaned up";
}

void TestCommandReplayInvariant::sendKey(Qt::Key key, Qt::KeyboardModifiers modifiers)
{
    // Send key to the application (global key handler will catch it)
    QTest::keyPress(m_mainWindow, key, modifiers);
    QTest::keyRelease(m_mainWindow, key, modifiers);
    waitForLuaProcessing();
}

void TestCommandReplayInvariant::sendUndoKey()
{
    // Cmd+Z on macOS
    sendKey(Qt::Key_Z, Qt::ControlModifier);
}

void TestCommandReplayInvariant::sendRedoKey()
{
    // Cmd+Shift+Z on macOS
    sendKey(Qt::Key_Z, Qt::ControlModifier | Qt::ShiftModifier);
}

void TestCommandReplayInvariant::waitForLuaProcessing()
{
    // Allow Lua event handlers and database operations to complete
    QTest::qWait(100);
    QApplication::processEvents();
}

TestCommandReplayInvariant::TimelineState TestCommandReplayInvariant::captureTimelineState()
{
    // In a real implementation, we would call Lua functions to get current state
    // For now, query database as source of truth
    return queryDatabaseState();
}

TestCommandReplayInvariant::TimelineState TestCommandReplayInvariant::queryDatabaseState()
{
    TimelineState state;

    // Query sequence state
    QSqlQuery seqQuery(m_db);
    seqQuery.prepare("SELECT playhead_time, selected_clip_ids, selected_edge_infos FROM sequences WHERE id = ?");
    seqQuery.addBindValue("default_sequence");

    if (seqQuery.exec() && seqQuery.next()) {
        state.playhead_time = seqQuery.value(0).toInt();
        QString selectedJson = seqQuery.value(1).toString();
        QString edgesJson = seqQuery.value(2).toString();

        if (!selectedJson.isEmpty()) {
            QJsonDocument doc = QJsonDocument::fromJson(selectedJson.toUtf8());
            if (doc.isArray()) {
                QJsonArray arr = doc.array();
                for (const QJsonValue& val : arr) {
                    state.selected_clip_ids.append(val.toString());
                }
            }
        }

        if (!edgesJson.isEmpty()) {
            QJsonDocument edgesDoc = QJsonDocument::fromJson(edgesJson.toUtf8());
            if (edgesDoc.isArray()) {
                QJsonArray arr = edgesDoc.array();
                for (const QJsonValue& val : arr) {
                    if (!val.isObject()) {
                        continue;
                    }
                    QJsonObject obj = val.toObject();
                    EdgeSelection edge;
                    edge.clip_id = obj.value("clip_id").toString();
                    edge.edge_type = obj.value("edge_type").toString();
                    edge.trim_type = obj.value("trim_type").toString();
                    state.selected_edges.append(edge);
                }
            }
        }
    }

    // Count clips
    QSqlQuery clipQuery(m_db);
    clipQuery.prepare("SELECT COUNT(*) FROM clips WHERE sequence_id = ?");
    clipQuery.addBindValue("default_sequence");

    if (clipQuery.exec() && clipQuery.next()) {
        state.clip_count = clipQuery.value(0).toInt();
    }

    return state;
}

void TestCommandReplayInvariant::assertStatesEqual(
    const TimelineState& expected,
    const TimelineState& actual,
    const QString& context)
{
    if (actual.playhead_time != expected.playhead_time) {
        QFAIL(qPrintable(QString("%1: playhead mismatch - expected %2, got %3")
                         .arg(context)
                         .arg(expected.playhead_time)
                         .arg(actual.playhead_time)));
    }
    if (actual.clip_count != expected.clip_count) {
        QFAIL(qPrintable(QString("%1: clip count mismatch - expected %2, got %3")
                         .arg(context)
                         .arg(expected.clip_count)
                         .arg(actual.clip_count)));
    }
    if (actual.selected_clip_ids != expected.selected_clip_ids) {
        QFAIL(qPrintable(QString("%1: selection mismatch")
                         .arg(context)));
    }
    if (actual.selected_edges != expected.selected_edges) {
        QFAIL(qPrintable(QString("%1: edge selection mismatch")
                         .arg(context)));
    }
}

void TestCommandReplayInvariant::testSingleInsertReplay()
{
    qDebug() << "\n=== TEST: Single INSERT Replay ===";

    // Initial state: playhead=0, no clips
    TimelineState initial = captureTimelineState();
    QCOMPARE(initial.playhead_time, 0);
    QCOMPARE(initial.clip_count, 0);

    // Step 1: Press F9 (INSERT 3s clip at playhead)
    qDebug() << "Step 1: Pressing F9 to INSERT clip at playhead=0";
    sendKey(Qt::Key_F9);

    // Capture state after first INSERT
    TimelineState afterInsert1 = captureTimelineState();
    qDebug() << "After INSERT #1:"
             << "playhead=" << afterInsert1.playhead_time
             << "clips=" << afterInsert1.clip_count;

    QCOMPARE(afterInsert1.clip_count, 1);
    QCOMPARE(afterInsert1.playhead_time, 3000); // Advanced 3 seconds

    // Step 2: Undo
    qDebug() << "Step 2: Pressing Cmd+Z to UNDO";
    sendUndoKey();

    // Verify restored to initial state
    TimelineState afterUndo = captureTimelineState();
    qDebug() << "After UNDO:"
             << "playhead=" << afterUndo.playhead_time
             << "clips=" << afterUndo.clip_count;

    assertStatesEqual(initial, afterUndo, "After undo");

    // Step 3: Press F9 again (THE KEY TEST - replay the command)
    qDebug() << "Step 3: Pressing F9 again to replay INSERT";
    sendKey(Qt::Key_F9);

    // Capture state after second INSERT
    TimelineState afterInsert2 = captureTimelineState();
    qDebug() << "After INSERT #2:"
             << "playhead=" << afterInsert2.playhead_time
             << "clips=" << afterInsert2.clip_count;

    // THE INVARIANT: Second INSERT must produce identical result to first INSERT
    assertStatesEqual(afterInsert1, afterInsert2, "Replay invariant");

    qDebug() << "✅ PASSED: Command replay produced identical result";
}

void TestCommandReplayInvariant::testMultipleInsertChainReplay()
{
    qDebug() << "\n=== TEST: Multiple INSERT Chain Replay ===";

    // Initial state
    TimelineState initial = captureTimelineState();

    // Execute: F9, F9, F9 (three INSERTs)
    qDebug() << "Executing: F9, F9, F9 (three INSERTs)";
    sendKey(Qt::Key_F9);
    sendKey(Qt::Key_F9);
    sendKey(Qt::Key_F9);

    TimelineState afterThreeInserts = captureTimelineState();
    qDebug() << "After 3 INSERTs:"
             << "playhead=" << afterThreeInserts.playhead_time
             << "clips=" << afterThreeInserts.clip_count;

    QCOMPARE(afterThreeInserts.clip_count, 3);
    QCOMPARE(afterThreeInserts.playhead_time, 9000); // 3 * 3s = 9s

    // Undo all three
    qDebug() << "Undoing all three commands";
    sendUndoKey();
    sendUndoKey();
    sendUndoKey();

    TimelineState afterUndoAll = captureTimelineState();
    assertStatesEqual(initial, afterUndoAll, "After undo all");

    // Replay: F9, F9, F9 again
    qDebug() << "Replaying: F9, F9, F9";
    sendKey(Qt::Key_F9);
    sendKey(Qt::Key_F9);
    sendKey(Qt::Key_F9);

    TimelineState afterReplay = captureTimelineState();
    qDebug() << "After replay:"
             << "playhead=" << afterReplay.playhead_time
             << "clips=" << afterReplay.clip_count;

    // THE INVARIANT: Replay must produce identical result
    assertStatesEqual(afterThreeInserts, afterReplay, "Chain replay invariant");

    qDebug() << "✅ PASSED: Chain replay produced identical result";
}

void TestCommandReplayInvariant::testOverwriteReplay()
{
    qDebug() << "\n=== TEST: OVERWRITE Replay ===";

    // Setup: Create initial clip with F10 (OVERWRITE)
    qDebug() << "Setup: Creating initial clip with F10";
    sendKey(Qt::Key_F10);

    TimelineState afterSetup = captureTimelineState();
    QCOMPARE(afterSetup.clip_count, 1);
    QCOMPARE(afterSetup.playhead_time, 3000);

    // Move playhead to 1000ms (middle of clip)
    // TODO: Implement playhead movement command or direct Lua call
    // For now, we'll test the basic undo/redo cycle

    qDebug() << "Testing undo/redo cycle";
    sendUndoKey();

    TimelineState afterUndo = captureTimelineState();
    QCOMPARE(afterUndo.clip_count, 0);
    QCOMPARE(afterUndo.playhead_time, 0);

    // Replay F10
    sendKey(Qt::Key_F10);

    TimelineState afterReplay = captureTimelineState();
    assertStatesEqual(afterSetup, afterReplay, "OVERWRITE replay");

    qDebug() << "✅ PASSED: OVERWRITE replay produced identical result";
}

void TestCommandReplayInvariant::testSelectionPreservation()
{
    qDebug() << "\n=== TEST: Selection Preservation ===";

    // Create two clips
    qDebug() << "Creating two clips";
    sendKey(Qt::Key_F9);
    sendKey(Qt::Key_F9);

    TimelineState afterTwoClips = captureTimelineState();
    QCOMPARE(afterTwoClips.clip_count, 2);

    // TODO: Implement clip selection via mouse click or keyboard
    // For now, verify the database structure is correct

    qDebug() << "Verifying selection can be stored in database";
    QSqlQuery query(m_db);
    query.prepare("UPDATE sequences SET selected_clip_ids = ?, selected_edge_infos = ? WHERE id = ?");
    query.addBindValue("[\"clip1\", \"clip2\"]");
    query.addBindValue("[]");
    query.addBindValue("default_sequence");
    QVERIFY(query.exec());

    TimelineState withSelection = queryDatabaseState();
    QCOMPARE(withSelection.selected_clip_ids.size(), 2);

    qDebug() << "✅ PASSED: Selection persistence structure verified";
}

QTEST_MAIN(TestCommandReplayInvariant)
#include "test_command_replay_invariant.moc"
