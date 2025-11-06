#include <QtTest/QtTest>
#include <QTreeWidget>
#include <QLineEdit>
#include <QTemporaryDir>
#include <QSqlDatabase>
#include <QSqlQuery>
#include <QSqlError>
#include <QDir>
#include <QElapsedTimer>

#include "src/lua/simple_lua_engine.h"
#include "src/lua/qt_bindings.h"

using namespace Qt::StringLiterals;

namespace {
const char* kMasterClipId = "master_clip_1";
}

static bool sForceOffscreen = []() {
    qputenv("QT_QPA_PLATFORM", QByteArray("offscreen"));
    return true;
}();

static bool sEnsureSqlitePath = []() {
    if (qEnvironmentVariableIsEmpty("JVE_SQLITE3_PATH")) {
        qputenv("JVE_SQLITE3_PATH", QByteArray("/opt/homebrew/opt/sqlite/lib/libsqlite3.dylib"));
    }
    return true;
}();

class TestProjectBrowserRename : public QObject {
    Q_OBJECT

private:
    std::unique_ptr<QTemporaryDir> m_tempDir;
    QString m_dbPath;
    std::unique_ptr<SimpleLuaEngine> m_engine;
    lua_State* m_L = nullptr;
    QWidget* m_browserWidget = nullptr;
    QTreeWidget* m_tree = nullptr;

private:
    void setupDatabase();
    void setupLuaEnvironment();
    bool callLuaBool(const char* funcName);
    bool callLuaBoolWithString(const char* funcName, const QString& value);
    bool callLuaBoolWithInt(const char* funcName, int value);
    QString callLuaString(const char* funcName);
    QWidget* fetchWidgetFromLua(const char* globalName);
    QLineEdit* waitForActiveEditor();
    void startRenameSession();
    void typeIntoEditor(const QString& text);
    QString currentTimelineClipName();
    QString currentTreeItemName() const;
    bool waitForMasterClipName(const QString& expected, int timeoutMs = 5000);

private slots:
    void initTestCase();
    void cleanupTestCase();
    void init();
    void cleanup();

    void testRenameAppliesImmediately();
    void testRenameCancelRestoresOriginal();
};

void TestProjectBrowserRename::initTestCase() {
    m_tempDir = std::make_unique<QTemporaryDir>();
    QVERIFY2(m_tempDir->isValid(), "Failed to create temporary directory");
    m_dbPath = m_tempDir->filePath("rename_test.db");
    setupDatabase();
    setupLuaEnvironment();

    m_browserWidget = fetchWidgetFromLua("__test_project_browser_widget");
    QVERIFY(m_browserWidget);
    m_browserWidget->show();
    QTest::qWait(50);

    m_tree = m_browserWidget->findChild<QTreeWidget*>();
    QVERIFY(m_tree);

    QVERIFY(callLuaBoolWithInt("__test_select_timeline_clip", 1));
    QVERIFY(callLuaBoolWithString("__test_focus_master_clip", kMasterClipId));
}

void TestProjectBrowserRename::cleanupTestCase() {
    if (m_browserWidget) {
        m_browserWidget->close();
        m_browserWidget->deleteLater();
        m_browserWidget = nullptr;
    }
    m_tree = nullptr;
    m_engine.reset();
    m_L = nullptr;
    m_tempDir.reset();
}

void TestProjectBrowserRename::init() {
    QVERIFY(callLuaBoolWithString("__test_focus_master_clip", kMasterClipId));
}

void TestProjectBrowserRename::cleanup() {
}

void TestProjectBrowserRename::setupDatabase() {
    QSqlDatabase db = QSqlDatabase::addDatabase("QSQLITE", "project_browser_rename");
    db.setDatabaseName(m_dbPath);
    QVERIFY2(db.open(), qPrintable(db.lastError().text()));

    auto execSql = [&](const QString& sql) {
        QSqlQuery q(db);
        QVERIFY2(q.exec(sql), qPrintable(q.lastError().text() + u"\nSQL: "_s + sql));
    };

    execSql(uR"(
        CREATE TABLE projects (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            created_at INTEGER,
            modified_at INTEGER,
            settings TEXT DEFAULT '{}'
        );
    )"_s);

    execSql(uR"(
        CREATE TABLE sequences (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            name TEXT NOT NULL,
            kind TEXT NOT NULL,
            frame_rate REAL NOT NULL,
            width INTEGER NOT NULL,
            height INTEGER NOT NULL,
            playhead_time INTEGER DEFAULT 0,
            selected_clip_ids TEXT DEFAULT '[]',
            selected_edge_infos TEXT DEFAULT '[]',
            viewport_start_time INTEGER DEFAULT 0,
            viewport_duration INTEGER DEFAULT 10000,
            mark_in_time INTEGER,
            mark_out_time INTEGER,
            current_sequence_number INTEGER DEFAULT 0
        );
    )"_s);

    execSql(uR"(
        CREATE TABLE tracks (
            id TEXT PRIMARY KEY,
            sequence_id TEXT NOT NULL,
            name TEXT NOT NULL,
            track_type TEXT NOT NULL,
            track_index INTEGER NOT NULL,
            enabled INTEGER NOT NULL DEFAULT 1
        );
    )"_s);

    execSql(uR"(
        CREATE TABLE media (
            id TEXT PRIMARY KEY,
            project_id TEXT,
            name TEXT,
            file_path TEXT,
            duration INTEGER,
            frame_rate REAL,
            width INTEGER,
            height INTEGER,
            audio_channels INTEGER,
            codec TEXT,
            created_at INTEGER,
            modified_at INTEGER,
            metadata TEXT
        );
    )"_s);

    execSql(uR"(
        CREATE TABLE clips (
            id TEXT PRIMARY KEY,
            project_id TEXT,
            clip_kind TEXT NOT NULL,
            name TEXT,
            track_id TEXT,
            media_id TEXT,
            source_sequence_id TEXT,
            parent_clip_id TEXT,
            owner_sequence_id TEXT,
            start_time INTEGER,
            duration INTEGER,
            source_in INTEGER,
            source_out INTEGER,
            enabled INTEGER DEFAULT 1,
            offline INTEGER DEFAULT 0,
            created_at INTEGER,
            modified_at INTEGER
        );
    )"_s);

    execSql(uR"(
        CREATE TABLE commands (
            id TEXT PRIMARY KEY,
            parent_id TEXT,
            parent_sequence_number INTEGER,
            sequence_number INTEGER UNIQUE NOT NULL,
            command_type TEXT NOT NULL,
            command_args TEXT,
            pre_hash TEXT,
            post_hash TEXT,
            timestamp INTEGER,
            playhead_time INTEGER DEFAULT 0,
            selected_clip_ids TEXT DEFAULT '[]',
            selected_edge_infos TEXT DEFAULT '[]',
            selected_gap_infos TEXT DEFAULT '[]',
            selected_clip_ids_pre TEXT DEFAULT '[]',
            selected_edge_infos_pre TEXT DEFAULT '[]',
            selected_gap_infos_pre TEXT DEFAULT '[]'
        );
    )"_s);

    execSql(uR"(
        INSERT INTO projects (id, name, created_at, modified_at, settings)
        VALUES ('default_project', 'Default Project', 0, 0, '{}');
    )"_s);

    execSql(uR"(
        INSERT INTO sequences (id, project_id, name, kind, frame_rate, width, height,
                               playhead_time, selected_clip_ids, selected_edge_infos,
                               viewport_start_time, viewport_duration, mark_in_time, mark_out_time,
                               current_sequence_number)
        VALUES ('default_sequence', 'default_project', 'Timeline', 'timeline',
                24.0, 1920, 1080, 0, '[]', '[]', 0, 10000, NULL, NULL, 0);
    )"_s);

    execSql(uR"(
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
        VALUES ('track_v1', 'default_sequence', 'Video 1', 'VIDEO', 1, 1);
    )"_s);

    execSql(uR"(
        INSERT INTO media (id, project_id, name, file_path, duration, frame_rate,
                           width, height, audio_channels, codec, created_at, modified_at, metadata)
        VALUES ('media_1', 'default_project', 'name1', '/tmp/file.mov', 1000, 24.0,
                1920, 1080, 2, 'ProRes', 0, 0, '{}');
    )"_s);

    execSql(uR"(
        INSERT INTO clips (id, project_id, clip_kind, name, media_id, source_sequence_id,
                           duration, source_in, source_out, enabled, offline, created_at, modified_at)
        VALUES ('master_clip_1', 'default_project', 'master', 'name1', 'media_1', NULL,
                1000, 0, 1000, 1, 0, 0, 0);
    )"_s);

    execSql(uR"(
        INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id,
                           parent_clip_id, owner_sequence_id, start_time, duration,
                           source_in, source_out, enabled, offline, created_at, modified_at)
        VALUES ('timeline_clip_1', 'default_project', 'timeline', 'name1',
                'track_v1', 'media_1', 'master_clip_1', 'default_sequence',
                0, 1000, 0, 1000, 1, 0, 0, 0);
    )"_s);

    db.close();
    QSqlDatabase::removeDatabase("project_browser_rename");
}

void TestProjectBrowserRename::setupLuaEnvironment() {
    m_engine = std::make_unique<SimpleLuaEngine>();
    m_L = m_engine->getLuaState();
    QVERIFY(m_L);

    QString script = QString(R"(
        local database = require('core.database')
        database.init('%1')
        local db = database.get_connection()
        database.set_project_setting('default_project', 'bin_hierarchy', {
            { id = 'bin_root', name = 'Test Bin' }
        })

        local command_manager = require('core.command_manager')
        command_manager.init(db, 'default_sequence', 'default_project')

        local timeline_state = require('ui.timeline.timeline_state')
        timeline_state.init('default_sequence')
        local clips = timeline_state.get_clips()
        if clips and clips[1] then
            timeline_state.set_selection({clips[1]})
        end

        local project_browser = require('ui.project_browser')
        local widget = project_browser.create()
        rawset(_G, '__test_project_browser_widget', widget)

        rawset(_G, '__test_focus_master_clip', function(id)
            local ok, err = project_browser.focus_master_clip(id, {skip_activate = true, skip_focus = true})
            if not ok and err then
                return false, err
            end
            return ok
        end)

        rawset(_G, '__test_start_inline_rename', function()
            return project_browser.start_inline_rename()
        end)

        rawset(_G, '__test_get_timeline_clip_name', function()
            local state = require('ui.timeline.timeline_state')
            local clip_list = state.get_clips()
            if clip_list and clip_list[1] then
                return clip_list[1].name or ''
            end
            return ''
        end)

        rawset(_G, '__test_select_timeline_clip', function(index)
            local state = require('ui.timeline.timeline_state')
            local clip_list = state.get_clips()
            if clip_list and clip_list[index] then
                state.set_selection({clip_list[index]})
                return true
            end
            return false
        end)

        rawset(_G, '__test_get_master_clip_name', function()
            local db_module = require('core.database')
            local conn = db_module.get_connection()
            local stmt = conn:prepare("SELECT name FROM clips WHERE id = 'master_clip_1'")
            if not stmt then
                return ''
            end
            local result = ''
            if stmt:exec() and stmt:next() then
                result = stmt:value(0) or ''
            end
            stmt:finalize()
            return result
        end)
    )").arg(m_dbPath.replace('\\', "\\\\"));

    QVERIFY2(m_engine->executeString(script), qPrintable(m_engine->getLastError()));
}

bool TestProjectBrowserRename::callLuaBool(const char* funcName) {
    int base = lua_gettop(m_L);
    lua_getglobal(m_L, "__jve_error_handler");
    int errFunc = base + 1;
    lua_getglobal(m_L, funcName);
    if (!lua_isfunction(m_L, -1)) {
        lua_settop(m_L, base);
        return false;
    }
    if (lua_pcall(m_L, 0, 1, errFunc) != LUA_OK) {
        qWarning() << "Lua error:" << lua_tostring(m_L, -1);
        lua_settop(m_L, base);
        return false;
    }
    bool result = lua_toboolean(m_L, -1);
    lua_settop(m_L, base);
    return result;
}

bool TestProjectBrowserRename::callLuaBoolWithString(const char* funcName, const QString& value) {
    int base = lua_gettop(m_L);
    lua_getglobal(m_L, "__jve_error_handler");
    int errFunc = base + 1;
    lua_getglobal(m_L, funcName);
    if (!lua_isfunction(m_L, -1)) {
        lua_settop(m_L, base);
        QTest::qFail(qPrintable(QStringLiteral("Missing Lua function: %1").arg(funcName)), __FILE__, __LINE__);
        return false;
    }
    QByteArray utf8 = value.toUtf8();
    lua_pushlstring(m_L, utf8.constData(), utf8.size());
    if (lua_pcall(m_L, 1, 2, errFunc) != LUA_OK) {
        qWarning() << "Lua error:" << lua_tostring(m_L, -1);
        lua_settop(m_L, base);
        return false;
    }
    bool ok = lua_toboolean(m_L, -2);
    if (!ok) {
        const char* err = lua_tostring(m_L, -1);
        if (err) {
            qWarning() << "Lua returned error:" << err;
        }
    }
    lua_settop(m_L, base);
    return ok;
}

bool TestProjectBrowserRename::callLuaBoolWithInt(const char* funcName, int value) {
    int base = lua_gettop(m_L);
    lua_getglobal(m_L, "__jve_error_handler");
    int errFunc = base + 1;
    lua_getglobal(m_L, funcName);
    if (!lua_isfunction(m_L, -1)) {
        lua_settop(m_L, base);
        QTest::qFail(qPrintable(QStringLiteral("Missing Lua function: %1").arg(funcName)), __FILE__, __LINE__);
        return false;
    }
    lua_pushinteger(m_L, value);
    if (lua_pcall(m_L, 1, 1, errFunc) != LUA_OK) {
        qWarning() << "Lua error:" << lua_tostring(m_L, -1);
        lua_settop(m_L, base);
        return false;
    }
    bool ok = lua_toboolean(m_L, -1);
    lua_settop(m_L, base);
    return ok;
}

QString TestProjectBrowserRename::callLuaString(const char* funcName) {
    int base = lua_gettop(m_L);
    lua_getglobal(m_L, "__jve_error_handler");
    int errFunc = base + 1;
    lua_getglobal(m_L, funcName);
    if (!lua_isfunction(m_L, -1)) {
        lua_settop(m_L, base);
        return {};
    }
    if (lua_pcall(m_L, 0, 1, errFunc) != LUA_OK) {
        qWarning() << "Lua error:" << lua_tostring(m_L, -1);
        lua_settop(m_L, base);
        return {};
    }
    const char* result = lua_tostring(m_L, -1);
    QString text = result ? QString::fromUtf8(result) : QString();
    lua_settop(m_L, base);
    return text;
}

QWidget* TestProjectBrowserRename::fetchWidgetFromLua(const char* globalName) {
    lua_getglobal(m_L, globalName);
    QWidget* widget = static_cast<QWidget*>(lua_to_widget(m_L, -1));
    lua_pop(m_L, 1);
    return widget;
}

QLineEdit* TestProjectBrowserRename::waitForActiveEditor() {
    QLineEdit* editor = nullptr;
    QElapsedTimer timer;
    timer.start();
    while (timer.elapsed() < 2000) {
        editor = m_tree->findChild<QLineEdit*>();
        if (editor) {
            break;
        }
        QTest::qWait(20);
    }
    if (!editor) {
        QTest::qFail("Timed out waiting for inline rename editor", __FILE__, __LINE__);
        return nullptr;
    }
    editor->setFocus(Qt::OtherFocusReason);
    return editor;
}

void TestProjectBrowserRename::startRenameSession() {
    QVERIFY(callLuaBoolWithInt("__test_select_timeline_clip", 1));
    QVERIFY(callLuaBoolWithString("__test_focus_master_clip", kMasterClipId));
    QVERIFY(callLuaBool("__test_start_inline_rename"));
}

void TestProjectBrowserRename::typeIntoEditor(const QString& text) {
    QLineEdit* editor = waitForActiveEditor();
    editor->setFocus(Qt::OtherFocusReason);
    editor->selectAll();
    QTest::keyClicks(editor, text);
}

QString TestProjectBrowserRename::currentTimelineClipName() {
    return callLuaString("__test_get_timeline_clip_name");
}

QString TestProjectBrowserRename::currentTreeItemName() const {
    auto* item = m_tree->currentItem();
    if (!item) {
        return {};
    }
    return item->text(0);
}

bool TestProjectBrowserRename::waitForMasterClipName(const QString& expected, int timeoutMs) {
    QElapsedTimer timer;
    timer.start();
    while (timer.elapsed() < timeoutMs) {
        if (callLuaString("__test_get_master_clip_name") == expected) {
            return true;
        }
        QTest::qWait(50);
    }
    return callLuaString("__test_get_master_clip_name") == expected;
}

void TestProjectBrowserRename::testRenameAppliesImmediately() {
    startRenameSession();
    typeIntoEditor("name2");
    QLineEdit* editor = m_tree->findChild<QLineEdit*>();
    QVERIFY(editor);
    QTest::keyClick(editor, Qt::Key_Return);

    QVERIFY(waitForMasterClipName(QStringLiteral("name2"), 10000));
    QTRY_COMPARE_WITH_TIMEOUT(currentTimelineClipName(), QStringLiteral("name2"), 3000);
    QCOMPARE(currentTreeItemName(), QStringLiteral("name2"));
}

void TestProjectBrowserRename::testRenameCancelRestoresOriginal() {
    startRenameSession();
    typeIntoEditor("temp-name");
    QLineEdit* editor = m_tree->findChild<QLineEdit*>();
    QVERIFY(editor);
    QTest::keyClick(editor, Qt::Key_Escape);

    QVERIFY(waitForMasterClipName(QStringLiteral("name2"), 2000));
    QCOMPARE(currentTreeItemName(), QStringLiteral("name2"));
    QTRY_COMPARE_WITH_TIMEOUT(currentTimelineClipName(), QStringLiteral("name2"), 500);
}

QTEST_MAIN(TestProjectBrowserRename)
#include "test_project_browser_rename.moc"
