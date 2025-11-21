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
 * Contract Test T005: Command Execute API
 * 
 * Tests POST /commands/execute API contract for deterministic command execution.
 * Must fail initially per constitutional TDD requirement.
 * 
 * Contract Requirements:
 * - Accept CommandRequest with command_type, args, target_selection
 * - Return CommandResponse with command_id, success, delta, post_hash
 * - Generate deterministic deltas for replay
 * - Support all editing commands: create_clip, delete_clip, split_clip, ripple_delete, ripple_trim, roll_edit
 * - Return ErrorResponse on invalid commands or arguments
 */
class TestCommandExecute : public TestBase
{
    Q_OBJECT

private slots:
    void initTestCase() override;
    void testCommandExecuteCreateClip();
    void testCommandExecuteDeleteClip();
    void testCommandExecuteSplitClip();
    void testCommandExecuteRippleDelete();
    void testCommandExecuteRippleTrim();
    void testCommandExecuteRollEdit();
    void testCommandExecuteInvalidCommand();
    void testCommandExecuteInvalidArguments();
    void testDeterministicDeltaGeneration();

private:
    QSqlDatabase m_database;
    CommandDispatcher* m_dispatcher;
    QString m_projectId;
    QString m_sequenceId;
};

void TestCommandExecute::initTestCase()
{
    TestBase::initTestCase();
    verifyTDDCompliance();
    
    if (!Migrations::createNewProject(m_testDatabasePath)) {
        QFAIL("Failed to create test project database");
    }
    
    m_database = QSqlDatabase::addDatabase("QSQLITE", "test_command_execute");
    m_database.setDatabaseName(m_testDatabasePath);
    QVERIFY(m_database.open());
    
    // Create test project and sequence
    Project project = Project::create("Command Test Project");
    QVERIFY(project.save(m_database));
    m_projectId = project.id();
    
    Sequence sequence = Sequence::create("Test Sequence", m_projectId, 29.97, 1920, 1080);
    QVERIFY(sequence.save(m_database));
    m_sequenceId = sequence.id();
    
    // This will fail until CommandDispatcher is implemented (TDD requirement)
    m_dispatcher = new CommandDispatcher(this);
    m_dispatcher->setDatabase(m_database);
}

void TestCommandExecute::testCommandExecuteCreateClip()
{
    qCInfo(jveTests, "Testing POST /commands/execute for create_clip command");
    verifyLibraryFirstCompliance();
    
    // Prepare CommandRequest
    QJsonObject request;
    request["command_type"] = "create_clip";
    
    QJsonObject args;
    args["sequence_id"] = m_sequenceId;
    args["track_id"] = "track1";
    args["media_id"] = "media1";
    args["start_value"] = 0;
    args["end_value"] = 5000;
    args["source_in"] = 0;
    args["source_out"] = 5000;
    request["args"] = args;
    
    // Execute command - THIS WILL FAIL until CommandDispatcher is implemented
    CommandResponse response = m_dispatcher->executeCommand(request);
    
    // Verify CommandResponse contract
    QVERIFY(!response.commandId.isEmpty());
    QVERIFY(response.success);
    QVERIFY(!response.delta.isEmpty());
    QVERIFY(!response.postHash.isEmpty());
    QVERIFY(!response.inverseDelta.isEmpty());
    
    // Verify delta contains created clip
    QVERIFY(response.delta.contains("clips_created"));
    QJsonArray clipsCreated = response.delta["clips_created"].toArray();
    QCOMPARE(clipsCreated.size(), 1);
    
    verifyPerformance("Command execution", 50);
}

void TestCommandExecute::testCommandExecuteDeleteClip()
{
    qCInfo(jveTests, "Testing POST /commands/execute for delete_clip command");
    
    // First create a clip to delete
    QJsonObject createRequest;
    createRequest["command_type"] = "create_clip";
    QJsonObject createArgs;
    createArgs["sequence_id"] = m_sequenceId;
    createArgs["track_id"] = "track1";
    createArgs["media_id"] = "media1";
    createArgs["start_value"] = 0;
    createArgs["end_value"] = 5000;
    createRequest["args"] = createArgs;
    
    CommandResponse createResponse = m_dispatcher->executeCommand(createRequest);
    QVERIFY(createResponse.success);
    
    // Extract clip ID from delta
    QString clipId = createResponse.delta["clips_created"].toArray().first().toObject()["id"].toString();
    
    // Now delete the clip
    QJsonObject deleteRequest;
    deleteRequest["command_type"] = "delete_clip";
    QJsonObject deleteArgs;
    deleteArgs["clip_id"] = clipId;
    deleteRequest["args"] = deleteArgs;
    
    CommandResponse response = m_dispatcher->executeCommand(deleteRequest);
    
    // Verify deletion response
    QVERIFY(response.success);
    QVERIFY(response.delta.contains("clips_deleted"));
    QJsonArray clipsDeleted = response.delta["clips_deleted"].toArray();
    QCOMPARE(clipsDeleted.size(), 1);
    QCOMPARE(clipsDeleted.first().toString(), clipId);
}

void TestCommandExecute::testCommandExecuteSplitClip()
{
    qCInfo(jveTests, "Testing POST /commands/execute for split_clip command");
    
    // First create a clip to split
    QJsonObject createRequest;
    createRequest["command_type"] = "create_clip";
    QJsonObject createArgs;
    createArgs["sequence_id"] = m_sequenceId;
    createArgs["track_id"] = "track1";
    createArgs["media_id"] = "media1";
    createArgs["start_value"] = 0;
    createArgs["end_value"] = 5000;
    createRequest["args"] = createArgs;
    
    CommandResponse createResponse = m_dispatcher->executeCommand(createRequest);
    QVERIFY(createResponse.success);
    
    // Extract clip ID from delta
    QString clipId = createResponse.delta["clips_created"].toArray().first().toObject()["id"].toString();
    
    // Now split the clip
    QJsonObject request;
    request["command_type"] = "split_clip";
    
    QJsonObject args;
    args["clip_id"] = clipId;
    args["split_value"] = 2500; // Split at 2.5 seconds
    request["args"] = args;
    
    CommandResponse response = m_dispatcher->executeCommand(request);
    
    QVERIFY(response.success);
    QVERIFY(response.delta.contains("clips_created"));
    QVERIFY(response.delta.contains("clips_modified"));
    
    // Split should create one new clip and modify the original
    QJsonArray clipsCreated = response.delta["clips_created"].toArray();
    QJsonArray clipsModified = response.delta["clips_modified"].toArray();
    QCOMPARE(clipsCreated.size(), 1);
    QCOMPARE(clipsModified.size(), 1);
}

void TestCommandExecute::testCommandExecuteRippleDelete()
{
    qCInfo(jveTests, "Testing POST /commands/execute for ripple_delete command");
    
    // First create a clip to ripple delete
    QJsonObject createRequest;
    createRequest["command_type"] = "create_clip";
    QJsonObject createArgs;
    createArgs["sequence_id"] = m_sequenceId;
    createArgs["track_id"] = "track1";
    createArgs["media_id"] = "media1";
    createArgs["start_value"] = 0;
    createArgs["end_value"] = 5000;
    createRequest["args"] = createArgs;
    
    CommandResponse createResponse = m_dispatcher->executeCommand(createRequest);
    QVERIFY(createResponse.success);
    
    // Extract clip ID from delta
    QString clipId = createResponse.delta["clips_created"].toArray().first().toObject()["id"].toString();
    
    QJsonObject request;
    request["command_type"] = "ripple_delete";
    
    QJsonObject args;
    args["clip_id"] = clipId;
    args["affect_tracks"] = QJsonArray{"track1", "track2"};
    request["args"] = args;
    
    CommandResponse response = m_dispatcher->executeCommand(request);
    
    QVERIFY(response.success);
    QVERIFY(response.delta.contains("clips_deleted"));
    QVERIFY(response.delta.contains("clips_moved"));
}

void TestCommandExecute::testCommandExecuteRippleTrim()
{
    qCInfo(jveTests, "Testing POST /commands/execute for ripple_trim command");
    
    // First create a clip to ripple trim
    QJsonObject createRequest;
    createRequest["command_type"] = "create_clip";
    QJsonObject createArgs;
    createArgs["sequence_id"] = m_sequenceId;
    createArgs["track_id"] = "track1";
    createArgs["media_id"] = "media1";
    createArgs["start_value"] = 0;
    createArgs["end_value"] = 5000;
    createRequest["args"] = createArgs;
    
    CommandResponse createResponse = m_dispatcher->executeCommand(createRequest);
    QVERIFY(createResponse.success);
    
    // Extract clip ID from delta
    QString clipId = createResponse.delta["clips_created"].toArray().first().toObject()["id"].toString();
    
    QJsonObject request;
    request["command_type"] = "ripple_trim";
    
    QJsonObject args;
    args["clip_id"] = clipId;
    args["edge"] = "head"; // or "tail"
    args["new_time"] = 1000;
    args["affect_tracks"] = QJsonArray{"track1"};
    request["args"] = args;
    
    CommandResponse response = m_dispatcher->executeCommand(request);
    
    QVERIFY(response.success);
    QVERIFY(response.delta.contains("clips_modified"));
    QVERIFY(response.delta.contains("clips_moved"));
}

void TestCommandExecute::testCommandExecuteRollEdit()
{
    qCInfo(jveTests, "Testing POST /commands/execute for roll_edit command");
    
    // Create two adjacent clips for roll edit
    QJsonObject createRequest1;
    createRequest1["command_type"] = "create_clip";
    QJsonObject createArgs1;
    createArgs1["sequence_id"] = m_sequenceId;
    createArgs1["track_id"] = "track1";
    createArgs1["media_id"] = "media1";
    createArgs1["start_value"] = 0;
    createArgs1["end_value"] = 3000;
    createRequest1["args"] = createArgs1;
    
    CommandResponse createResponse1 = m_dispatcher->executeCommand(createRequest1);
    QVERIFY(createResponse1.success);
    QString clipAId = createResponse1.delta["clips_created"].toArray().first().toObject()["id"].toString();
    
    QJsonObject createRequest2;
    createRequest2["command_type"] = "create_clip";
    QJsonObject createArgs2;
    createArgs2["sequence_id"] = m_sequenceId;
    createArgs2["track_id"] = "track1";
    createArgs2["media_id"] = "media1";
    createArgs2["start_value"] = 3000;
    createArgs2["end_value"] = 6000;
    createRequest2["args"] = createArgs2;
    
    CommandResponse createResponse2 = m_dispatcher->executeCommand(createRequest2);
    QVERIFY(createResponse2.success);
    QString clipBId = createResponse2.delta["clips_created"].toArray().first().toObject()["id"].toString();
    
    QJsonObject request;
    request["command_type"] = "roll_edit";
    
    QJsonObject args;
    args["clip_a_id"] = clipAId;
    args["clip_b_id"] = clipBId;
    args["new_boundary_time"] = 3000;
    request["args"] = args;
    
    CommandResponse response = m_dispatcher->executeCommand(request);
    
    QVERIFY(response.success);
    QVERIFY(response.delta.contains("clips_modified"));
    
    // Roll edit should modify exactly 2 clips
    QJsonArray clipsModified = response.delta["clips_modified"].toArray();
    QCOMPARE(clipsModified.size(), 2);
}

void TestCommandExecute::testCommandExecuteInvalidCommand()
{
    qCInfo(jveTests, "Testing POST /commands/execute with invalid command type");
    
    QJsonObject request;
    request["command_type"] = "invalid_command";
    request["args"] = QJsonObject();
    
    CommandResponse response = m_dispatcher->executeCommand(request);
    
    // Should return error response
    QVERIFY(!response.success);
    QVERIFY(response.error.code == "INVALID_COMMAND");
    QCOMPARE(response.error.audience, QString("developer"));
    QVERIFY(!response.error.hint.isEmpty());
}

void TestCommandExecute::testCommandExecuteInvalidArguments()
{
    qCInfo(jveTests, "Testing POST /commands/execute with invalid arguments");
    
    QJsonObject request;
    request["command_type"] = "create_clip";
    // Missing required arguments
    request["args"] = QJsonObject();
    
    CommandResponse response = m_dispatcher->executeCommand(request);
    
    QVERIFY(!response.success);
    QVERIFY(response.error.code == "INVALID_ARGUMENTS");
    QCOMPARE(response.error.audience, QString("developer"));
}

void TestCommandExecute::testDeterministicDeltaGeneration()
{
    qCInfo(jveTests, "Testing deterministic delta generation for replay");
    
    // Execute same command twice
    QJsonObject request;
    request["command_type"] = "create_clip";
    QJsonObject args;
    args["sequence_id"] = m_sequenceId;
    args["track_id"] = "track1";
    args["media_id"] = "media1";
    args["start_value"] = 1000;
    args["end_value"] = 6000;
    request["args"] = args;
    
    CommandResponse response1 = m_dispatcher->executeCommand(request);
    
    // Reset state and execute again
    m_dispatcher->reset();
    CommandResponse response2 = m_dispatcher->executeCommand(request);
    
    // Deltas should be identical for replay determinism
    QCOMPARE(QJsonDocument(response1.delta).toJson(),
             QJsonDocument(response2.delta).toJson());
    
    // Post hashes should be identical
    QCOMPARE(response1.postHash, response2.postHash);
}

QTEST_MAIN(TestCommandExecute)
#include "test_command_execute.moc"