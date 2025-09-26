#include "../common/test_base.h"
#include "../../src/core/commands/command.h"
#include "../../src/core/commands/command_manager.h"
#include "../../src/core/persistence/migrations.h"

#include <QTest>

/**
 * Contract Test T011: Command Entity
 * 
 * Tests the Command entity API contract - deterministic operation logging.
 * Must fail initially per constitutional TDD requirement.
 * 
 * Contract Requirements:
 * - Command creation with deterministic serialization
 * - Command execution and undo/redo operations
 * - Command sequence management and replay
 * - Command validation and integrity checks
 * - Performance requirements for command processing
 * - Constitutional determinism compliance
 */
class TestCommandEntity : public TestBase
{
    Q_OBJECT

private slots:
    void initTestCase() override;
    void testCommandCreation();
    void testCommandExecution();
    void testCommandSerialization();
    void testCommandSequencing();
    void testCommandReplay();
    void testCommandDeterminism();
    void testCommandPerformance();

private:
    QSqlDatabase m_database;
    QString m_projectId;
};

void TestCommandEntity::initTestCase()
{
    TestBase::initTestCase();
    verifyTDDCompliance();
    
    if (!Migrations::createNewProject(m_testDatabasePath)) {
        QFAIL("Failed to create test project database");
    }
    
    m_database = QSqlDatabase::addDatabase("QSQLITE", "test_command_entity");
    m_database.setDatabaseName(m_testDatabasePath);
    QVERIFY(m_database.open());
    
    // Create test project
    Project project = Project::create("Command Test Project");
    QVERIFY(project.save(m_database));
    m_projectId = project.id();
}

void TestCommandEntity::testCommandCreation()
{
    qCInfo(jveTests) << "Testing Command creation contract";
    verifyLibraryFirstCompliance();
    
    Command command = Command::create("CreateClip", m_projectId);
    command.setParameter("name", "Test Clip");
    command.setParameter("media_id", "test-media-id");
    command.setParameter("timeline_start", 5000);
    
    QVERIFY(!command.id().isEmpty());
    QCOMPARE(command.type(), QString("CreateClip"));
    QCOMPARE(command.projectId(), m_projectId);
    QVERIFY(command.createdAt().isValid());
    QCOMPARE(command.sequenceNumber(), 0); // Not assigned yet
    
    // Parameter validation
    QCOMPARE(command.getParameter("name").toString(), QString("Test Clip"));
    QCOMPARE(command.getParameter("media_id").toString(), QString("test-media-id"));
    QCOMPARE(command.getParameter("timeline_start").toInt(), 5000);
    
    verifyPerformance("Command creation", 10);
}

void TestCommandEntity::testCommandExecution()
{
    qCInfo(jveTests) << "Testing command execution contract";
    
    CommandManager manager(m_database);
    
    // Create test command
    Command command = Command::create("SetClipProperty", m_projectId);
    command.setParameter("clip_id", "test-clip-id");
    command.setParameter("property", "opacity");
    command.setParameter("value", 0.75);
    command.setParameter("previous_value", 1.0); // For undo
    
    // Execute command
    ExecutionResult result = manager.execute(command);
    QVERIFY(result.success);
    QVERIFY(!result.errorMessage.isEmpty() == false); // No error message
    
    // Verify command was logged
    QVERIFY(command.sequenceNumber() > 0); // Should be assigned
    QCOMPARE(command.status(), Command::Executed);
    QVERIFY(command.executedAt().isValid());
    
    // Test undo
    Command undoCommand = command.createUndo();
    ExecutionResult undoResult = manager.execute(undoCommand);
    QVERIFY(undoResult.success);
    
    // Verify undo command
    QCOMPARE(undoCommand.type(), QString("SetClipProperty"));
    QCOMPARE(undoCommand.getParameter("value").toDouble(), 1.0); // Restored value
}

void TestCommandEntity::testCommandSerialization()
{
    qCInfo(jveTests) << "Testing command serialization contract";
    
    Command command = Command::create("ComplexOperation", m_projectId);
    command.setParameter("string_param", "test string");
    command.setParameter("number_param", 42.5);
    command.setParameter("bool_param", true);
    command.setParameter("array_param", QVariantList{1, 2, 3});
    
    QJsonObject metadata;
    metadata["user_id"] = "test-user";
    metadata["timestamp"] = QDateTime::currentMSecsSinceEpoch();
    command.setMetadata(metadata);
    
    // Serialize to JSON
    QString serialized = command.serialize();
    QVERIFY(!serialized.isEmpty());
    QVERIFY(serialized.contains("ComplexOperation"));
    QVERIFY(serialized.contains("test string"));
    QVERIFY(serialized.contains("42.5"));
    
    // Deserialize and verify
    Command deserialized = Command::deserialize(serialized);
    QCOMPARE(deserialized.type(), command.type());
    QCOMPARE(deserialized.projectId(), command.projectId());
    QCOMPARE(deserialized.getParameter("string_param").toString(), 
             command.getParameter("string_param").toString());
    QCOMPARE(deserialized.getParameter("number_param").toDouble(),
             command.getParameter("number_param").toDouble());
    QCOMPARE(deserialized.getParameter("bool_param").toBool(),
             command.getParameter("bool_param").toBool());
}

void TestCommandEntity::testCommandSequencing()
{
    qCInfo(jveTests) << "Testing command sequencing contract";
    
    CommandManager manager(m_database);
    
    // Execute sequence of commands
    QList<Command> commands;
    
    Command cmd1 = Command::create("CreateSequence", m_projectId);
    cmd1.setParameter("name", "Main Timeline");
    commands.append(cmd1);
    
    Command cmd2 = Command::create("AddTrack", m_projectId);
    cmd2.setParameter("sequence_id", "seq-1");
    cmd2.setParameter("type", "video");
    commands.append(cmd2);
    
    Command cmd3 = Command::create("AddClip", m_projectId);
    cmd3.setParameter("track_id", "track-1");
    cmd3.setParameter("media_id", "media-1");
    commands.append(cmd3);
    
    // Execute in sequence
    for (auto& cmd : commands) {
        ExecutionResult result = manager.execute(cmd);
        QVERIFY(result.success);
    }
    
    // Verify sequence numbering
    QCOMPARE(cmd1.sequenceNumber(), 1);
    QCOMPARE(cmd2.sequenceNumber(), 2);
    QCOMPARE(cmd3.sequenceNumber(), 3);
    
    // Verify database sequence integrity
    QList<Command> allCommands = Command::loadByProject(m_projectId, m_database);
    for (int i = 0; i < allCommands.size() - 1; i++) {
        QVERIFY(allCommands[i].sequenceNumber() < allCommands[i + 1].sequenceNumber());
    }
}

void TestCommandEntity::testCommandReplay()
{
    qCInfo(jveTests) << "Testing command replay contract";
    
    CommandManager manager(m_database);
    
    // Create initial state
    Command setupCmd = Command::create("SetupProject", m_projectId);
    setupCmd.setParameter("initial_state", true);
    QVERIFY(manager.execute(setupCmd).success);
    
    // Record operations
    QList<Command> operationSequence;
    
    Command op1 = Command::create("ModifyProperty", m_projectId);
    op1.setParameter("property", "brightness");
    op1.setParameter("value", 120);
    operationSequence.append(op1);
    
    Command op2 = Command::create("ModifyProperty", m_projectId);
    op2.setParameter("property", "contrast");
    op2.setParameter("value", 1.2);
    operationSequence.append(op2);
    
    // Execute original sequence
    for (auto& cmd : operationSequence) {
        QVERIFY(manager.execute(cmd).success);
    }
    
    // Reset to initial state
    manager.revertToSequence(setupCmd.sequenceNumber());
    
    // Replay operations
    ReplayResult result = manager.replayFromSequence(setupCmd.sequenceNumber() + 1);
    QVERIFY(result.success);
    QCOMPARE(result.commandsReplayed, operationSequence.size());
    
    // Verify final state matches
    Command finalState1 = manager.getCurrentState();
    
    // Reset and replay again
    manager.revertToSequence(setupCmd.sequenceNumber());
    ReplayResult result2 = manager.replayFromSequence(setupCmd.sequenceNumber() + 1);
    QVERIFY(result2.success);
    
    Command finalState2 = manager.getCurrentState();
    
    // States should be identical (deterministic)
    QCOMPARE(finalState1.serialize(), finalState2.serialize());
}

void TestCommandEntity::testCommandDeterminism()
{
    qCInfo(jveTests) << "Testing constitutional determinism contract";
    verifyCommandDeterminism({"CreateClip", "SetProperty", "DeleteClip"});
    
    CommandManager manager1(m_database);
    CommandManager manager2(m_database);
    
    // Create identical command sequences
    QList<QPair<QString, QVariantMap>> commandSpecs = {
        {"CreateClip", {{"name", "Clip1"}, {"position", 1000}}},
        {"SetProperty", {{"clip_id", "clip1"}, {"property", "opacity"}, {"value", 0.8}}},
        {"CreateClip", {{"name", "Clip2"}, {"position", 5000}}},
        {"SetProperty", {{"clip_id", "clip2"}, {"property", "scale"}, {"value", 1.5}}}
    };
    
    // Execute sequence with manager 1
    QString state1;
    for (const auto& spec : commandSpecs) {
        Command cmd = Command::create(spec.first, m_projectId);
        for (auto it = spec.second.begin(); it != spec.second.end(); ++it) {
            cmd.setParameter(it.key(), it.value());
        }
        QVERIFY(manager1.execute(cmd).success);
    }
    state1 = manager1.getProjectState(m_projectId);
    
    // Reset database to initial state
    manager1.revertToSequence(0);
    
    // Execute same sequence with manager 2  
    QString state2;
    for (const auto& spec : commandSpecs) {
        Command cmd = Command::create(spec.first, m_projectId);
        for (auto it = spec.second.begin(); it != spec.second.end(); ++it) {
            cmd.setParameter(it.key(), it.value());
        }
        QVERIFY(manager2.execute(cmd).success);
    }
    state2 = manager2.getProjectState(m_projectId);
    
    // Results must be identical (constitutional requirement)
    QCOMPARE(state1, state2);
}

void TestCommandEntity::testCommandPerformance()
{
    qCInfo(jveTests) << "Testing command performance contract";
    
    CommandManager manager(m_database);
    
    // Test individual command execution performance
    m_timer.restart();
    
    Command fastCommand = Command::create("FastOperation", m_projectId);
    fastCommand.setParameter("value", 42);
    QVERIFY(manager.execute(fastCommand).success);
    
    verifyPerformance("Single command execution", 10);
    
    // Test batch command execution performance
    m_timer.restart();
    
    for (int i = 0; i < 100; i++) {
        Command batchCmd = Command::create("BatchOperation", m_projectId);
        batchCmd.setParameter("index", i);
        batchCmd.setParameter("value", i * 2.5);
        QVERIFY(manager.execute(batchCmd).success);
    }
    
    verifyPerformance("100 command batch execution", 500);
    
    // Test replay performance  
    int startSequence = fastCommand.sequenceNumber();
    
    m_timer.restart();
    ReplayResult replay = manager.replayFromSequence(startSequence);
    QVERIFY(replay.success);
    QVERIFY(replay.commandsReplayed >= 100);
    
    verifyPerformance("Command replay (100+ commands)", 200);
}

QTEST_MAIN(TestCommandEntity)
#include "test_command_entity.moc"