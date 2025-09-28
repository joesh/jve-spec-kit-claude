#include "../common/test_base.h"
#include "../../src/core/commands/command_dispatcher.h"
#include "../../src/core/models/project.h"
#include "../../src/core/models/sequence.h"
#include "../../src/core/persistence/migrations.h"

#include <QTest>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>

/**
 * Contract Test T007: Command Redo API
 * 
 * Tests POST /commands/redo API contract for command re-application.
 * Must fail initially per constitutional TDD requirement.
 * 
 * Contract Requirements:
 * - Re-apply last undone command
 * - Return CommandResponse with redo operation details
 * - Maintain undo/redo stack for professional editor behavior
 * - Return ErrorResponse when no command to redo
 */
class TestCommandRedo : public TestBase
{
    Q_OBJECT

private slots:
    void initTestCase() override;
    void testCommandRedoAfterUndo();
    void testCommandRedoEmpty();
    void testUndoRedoChain();
    void testRedoInvalidatesOnNewCommand();

private:
    QSqlDatabase m_database;
    CommandDispatcher* m_dispatcher;
    QString m_projectId;
    QString m_sequenceId;
};

void TestCommandRedo::initTestCase()
{
    TestBase::initTestCase();
    verifyTDDCompliance();
    
    if (!Migrations::createNewProject(m_testDatabasePath)) {
        QFAIL("Failed to create test project database");
    }
    
    m_database = QSqlDatabase::addDatabase("QSQLITE", "test_command_redo");
    m_database.setDatabaseName(m_testDatabasePath);
    QVERIFY(m_database.open());
    
    Project project = Project::create("Redo Test Project");
    QVERIFY(project.save(m_database));
    m_projectId = project.id();
    
    Sequence sequence = Sequence::create("Test Sequence", m_projectId, 29.97, 1920, 1080);
    QVERIFY(sequence.save(m_database));
    m_sequenceId = sequence.id();
    
    m_dispatcher = new CommandDispatcher(this);
    m_dispatcher->setDatabase(m_database);
}

void TestCommandRedo::testCommandRedoAfterUndo()
{
    qCInfo(jveTests, "Testing POST /commands/redo after undo operation");
    verifyLibraryFirstCompliance();
    
    // Execute -> Undo -> Redo sequence
    QJsonObject createRequest;
    createRequest["command_type"] = "create_clip";
    QJsonObject args;
    args["sequence_id"] = m_sequenceId;
    args["track_id"] = "track1";
    args["media_id"] = "media1";
    args["start_time"] = 0;
    args["end_time"] = 5000;
    createRequest["args"] = args;
    
    // Execute command
    CommandResponse createResponse = m_dispatcher->executeCommand(createRequest);
    QString postCreateHash = createResponse.postHash;
    
    // Undo command
    CommandResponse undoResponse = m_dispatcher->undoCommand();
    
    // Redo command - THIS WILL FAIL until redo is implemented
    CommandResponse redoResponse = m_dispatcher->redoCommand();
    
    // Verify redo response contract
    QVERIFY(!redoResponse.commandId.isEmpty());
    QVERIFY(redoResponse.success);
    QVERIFY(!redoResponse.delta.isEmpty());
    QVERIFY(!redoResponse.postHash.isEmpty());
    
    // Redo should restore the create operation
    QVERIFY(redoResponse.delta.contains("clips_created"));
    QJsonArray clipsCreated = redoResponse.delta["clips_created"].toArray();
    QCOMPARE(clipsCreated.size(), 1);
    
    // State should match post-create state
    QCOMPARE(redoResponse.postHash, postCreateHash);
    
    verifyPerformance("Redo command", 50);
}

void TestCommandRedo::testCommandRedoEmpty()
{
    qCInfo(jveTests, "Testing POST /commands/redo with no commands to redo");
    
    CommandDispatcher freshDispatcher;
    freshDispatcher.setDatabase(m_database);
    
    CommandResponse response = freshDispatcher.redoCommand();
    
    // Should return error response
    QVERIFY(!response.success);
    QVERIFY(response.error.code == "NO_COMMAND_TO_REDO");
    QCOMPARE(response.error.audience, QString("user"));
    QVERIFY(!response.error.hint.isEmpty());
}

void TestCommandRedo::testUndoRedoChain()
{
    qCInfo(jveTests, "Testing multiple undo/redo operations");
    
    // Execute multiple commands
    QJsonObject request1;
    request1["command_type"] = "create_clip";
    QJsonObject args1;
    args1["sequence_id"] = m_sequenceId;
    args1["track_id"] = "track1";
    args1["media_id"] = "media1";
    args1["start_time"] = 0;
    args1["end_time"] = 5000;
    request1["args"] = args1;
    
    QJsonObject request2;
    request2["command_type"] = "create_clip";
    QJsonObject args2;
    args2["sequence_id"] = m_sequenceId;
    args2["track_id"] = "track1";
    args2["media_id"] = "media2";
    args2["start_time"] = 5000;
    args2["end_time"] = 10000;
    request2["args"] = args2;
    
    CommandResponse create1 = m_dispatcher->executeCommand(request1);
    CommandResponse create2 = m_dispatcher->executeCommand(request2);
    
    // Undo both commands
    m_dispatcher->undoCommand(); // Undo create2
    m_dispatcher->undoCommand(); // Undo create1
    
    // Redo should restore in original order
    CommandResponse redo1 = m_dispatcher->redoCommand(); // Should redo create1
    QVERIFY(redo1.success);
    
    CommandResponse redo2 = m_dispatcher->redoCommand(); // Should redo create2
    QVERIFY(redo2.success);
    
    // Third redo should fail
    CommandResponse redo3 = m_dispatcher->redoCommand();
    QVERIFY(!redo3.success);
    QVERIFY(redo3.error.code == "NO_COMMAND_TO_REDO");
}

void TestCommandRedo::testRedoInvalidatesOnNewCommand()
{
    qCInfo(jveTests, "Testing redo stack invalidation on new command execution");
    
    // Execute -> Undo -> Execute New -> Redo should fail
    QJsonObject request1;
    request1["command_type"] = "create_clip";
    QJsonObject args1;
    args1["sequence_id"] = m_sequenceId;
    args1["track_id"] = "track1";
    args1["media_id"] = "media1";
    args1["start_time"] = 0;
    args1["end_time"] = 5000;
    request1["args"] = args1;
    
    m_dispatcher->executeCommand(request1);
    m_dispatcher->undoCommand();
    
    // Execute different command - should invalidate redo stack
    QJsonObject request2;
    request2["command_type"] = "create_clip";
    QJsonObject args2;
    args2["sequence_id"] = m_sequenceId;
    args2["track_id"] = "track2";
    args2["media_id"] = "media2";
    args2["start_time"] = 1000;
    args2["end_time"] = 6000;
    request2["args"] = args2;
    
    m_dispatcher->executeCommand(request2);
    
    // Redo should now fail because stack was invalidated
    CommandResponse redoResponse = m_dispatcher->redoCommand();
    QVERIFY(!redoResponse.success);
    QVERIFY(redoResponse.error.code == "NO_COMMAND_TO_REDO");
}

QTEST_MAIN(TestCommandRedo)
#include "test_command_redo.moc"