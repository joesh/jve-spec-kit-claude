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
 * Contract Test T006: Command Undo API
 * 
 * Tests POST /commands/undo API contract for command reversal.
 * Must fail initially per constitutional TDD requirement.
 * 
 * Contract Requirements:
 * - Undo last command using inverse delta
 * - Return CommandResponse with undo operation details
 * - Maintain command history for deterministic replay
 * - Return ErrorResponse when no command to undo
 */
class TestCommandUndo : public TestBase
{
    Q_OBJECT

private slots:
    void initTestCase() override;
    void testCommandUndoSuccess();
    void testCommandUndoEmpty();
    void testCommandUndoChain();
    void testUndoInverseDeltaApplication();

private:
    QSqlDatabase m_database;
    CommandDispatcher* m_dispatcher;
    QString m_projectId;
    QString m_sequenceId;
};

void TestCommandUndo::initTestCase()
{
    TestBase::initTestCase();
    verifyTDDCompliance();
    
    if (!Migrations::createNewProject(m_testDatabasePath)) {
        QFAIL("Failed to create test project database");
    }
    
    m_database = QSqlDatabase::addDatabase("QSQLITE", "test_command_undo");
    m_database.setDatabaseName(m_testDatabasePath);
    QVERIFY(m_database.open());
    
    // Create test project and sequence
    Project project = Project::create("Undo Test Project");
    QVERIFY(project.save(m_database));
    m_projectId = project.id();
    
    Sequence sequence = Sequence::create("Test Sequence", m_projectId, 29.97, 1920, 1080);
    QVERIFY(sequence.save(m_database));
    m_sequenceId = sequence.id();
    
    m_dispatcher = new CommandDispatcher(this);
    m_dispatcher->setDatabase(m_database);
}

void TestCommandUndo::testCommandUndoSuccess()
{
    qCInfo(jveTests, "Testing POST /commands/undo after successful command");
    verifyLibraryFirstCompliance();
    
    // First execute a command
    QJsonObject createRequest;
    createRequest["command_type"] = "create_clip";
    QJsonObject args;
    args["sequence_id"] = m_sequenceId;
    args["track_id"] = "track1";
    args["media_id"] = "media1";
    args["start_value"] = 0;
    args["end_value"] = 5000;
    createRequest["args"] = args;
    
    CommandResponse createResponse = m_dispatcher->executeCommand(createRequest);
    
    // Now undo the command - THIS WILL FAIL until undo is implemented
    CommandResponse undoResponse = m_dispatcher->undoCommand();
    
    // Verify undo response contract
    QVERIFY(!undoResponse.commandId.isEmpty());
    QVERIFY(undoResponse.success);
    QVERIFY(!undoResponse.delta.isEmpty());
    QVERIFY(!undoResponse.postHash.isEmpty());
    
    // Undo delta should reverse the create operation
    QVERIFY(undoResponse.delta.contains("clips_deleted"));
    QJsonArray clipsDeleted = undoResponse.delta["clips_deleted"].toArray();
    QCOMPARE(clipsDeleted.size(), 1);
    
    verifyPerformance("Undo command", 50);
}

void TestCommandUndo::testCommandUndoEmpty()
{
    qCInfo(jveTests, "Testing POST /commands/undo with no commands to undo");
    
    // Fresh dispatcher with no command history
    CommandDispatcher freshDispatcher;
    freshDispatcher.setDatabase(m_database);
    
    CommandResponse response = freshDispatcher.undoCommand();
    
    // Should return error response
    QVERIFY(!response.success);
    QVERIFY(response.error.code == "NO_COMMAND_TO_UNDO");
    QCOMPARE(response.error.audience, QString("user"));
    QVERIFY(!response.error.hint.isEmpty());
}

void TestCommandUndo::testCommandUndoChain()
{
    qCInfo(jveTests, "Testing multiple undo operations in sequence");
    
    // Execute multiple commands
    QJsonObject request1;
    request1["command_type"] = "create_clip";
    QJsonObject args1;
    args1["sequence_id"] = m_sequenceId;
    args1["track_id"] = "track1";
    args1["media_id"] = "media1";
    args1["start_value"] = 0;
    args1["end_value"] = 5000;
    request1["args"] = args1;
    
    QJsonObject request2;
    request2["command_type"] = "create_clip";
    QJsonObject args2;
    args2["sequence_id"] = m_sequenceId;
    args2["track_id"] = "track1";
    args2["media_id"] = "media2";
    args2["start_value"] = 5000;
    args2["end_value"] = 10000;
    request2["args"] = args2;
    
    m_dispatcher->executeCommand(request1);
    m_dispatcher->executeCommand(request2);
    
    // Undo should reverse in LIFO order (last command first)
    CommandResponse undo1 = m_dispatcher->undoCommand();
    QVERIFY(undo1.success);
    
    CommandResponse undo2 = m_dispatcher->undoCommand();
    QVERIFY(undo2.success);
    
    // Third undo should fail
    CommandResponse undo3 = m_dispatcher->undoCommand();
    QVERIFY(!undo3.success);
    QVERIFY(undo3.error.code == "NO_COMMAND_TO_UNDO");
}

void TestCommandUndo::testUndoInverseDeltaApplication()
{
    qCInfo(jveTests, "Testing inverse delta application for state restoration");
    
    // Execute a command and capture initial state
    QJsonObject createRequest;
    createRequest["command_type"] = "create_clip";
    QJsonObject args;
    args["sequence_id"] = m_sequenceId;
    args["track_id"] = "track1";
    args["media_id"] = "media1";
    args["start_value"] = 1000;
    args["end_value"] = 6000;
    createRequest["args"] = args;
    
    QString initialHash = m_dispatcher->getStateHash();
    CommandResponse createResponse = m_dispatcher->executeCommand(createRequest);
    QString postCreateHash = createResponse.postHash;
    
    // Undo should restore exact initial state
    CommandResponse undoResponse = m_dispatcher->undoCommand();
    QString postUndoHash = undoResponse.postHash;
    
    // State hash should match initial state after undo
    QCOMPARE(postUndoHash, initialHash);
    QVERIFY(postUndoHash != postCreateHash);
}

QTEST_MAIN(TestCommandUndo)
#include "test_command_undo.moc"