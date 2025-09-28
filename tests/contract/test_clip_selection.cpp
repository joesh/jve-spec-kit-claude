#include "../common/test_base.h"
#include "../../src/core/api/selection_manager.h"
#include "../../src/core/models/project.h"
#include "../../src/core/models/sequence.h"
#include "../../src/core/persistence/migrations.h"

#include <QTest>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>

/**
 * Contract Test T012: Clip Selection API
 * 
 * Tests GET/POST /selection/clips API contract for multi-clip selection.
 * Must fail initially per constitutional TDD requirement.
 * 
 * Contract Requirements:
 * - Support selection modes: replace, add, remove, toggle
 * - Return ClipSelectionResponse with selected_clips array
 * - Handle multi-selection with Cmd+click behavior
 * - Integrate with Inspector for property editing
 */
class TestClipSelection : public TestBase
{
    Q_OBJECT

private slots:
    void initTestCase() override;
    void testGetClipSelectionEmpty();
    void testSetClipSelectionReplace();
    void testSetClipSelectionAdd();
    void testSetClipSelectionRemove();
    void testSetClipSelectionToggle();
    void testMultiClipSelection();
    void testSelectionResponse();

private:
    QSqlDatabase m_database;
    SelectionAPI* m_selectionManager;
    QString m_projectId;
    QString m_sequenceId;
    QStringList m_testClipIds;
};

void TestClipSelection::initTestCase()
{
    TestBase::initTestCase();
    verifyTDDCompliance();
    
    if (!Migrations::createNewProject(m_testDatabasePath)) {
        QFAIL("Failed to create test project database");
    }
    
    m_database = QSqlDatabase::addDatabase("QSQLITE", "test_clip_selection");
    m_database.setDatabaseName(m_testDatabasePath);
    QVERIFY(m_database.open());
    
    Project project = Project::create("Selection Test Project");
    QVERIFY(project.save(m_database));
    m_projectId = project.id();
    
    Sequence sequence = Sequence::create("Test Sequence", m_projectId, 29.97, 1920, 1080);
    QVERIFY(sequence.save(m_database));
    m_sequenceId = sequence.id();
    
    // Create test clip IDs
    m_testClipIds = {"clip-1", "clip-2", "clip-3", "clip-4"};
    
    // This will fail until SelectionAPI is implemented (TDD requirement)
    m_selectionManager = new SelectionAPI(this);
    m_selectionManager->setDatabase(m_database);
}

void TestClipSelection::testGetClipSelectionEmpty()
{
    qCInfo(jveTests, "Testing GET /selection/clips with no selection");
    verifyLibraryFirstCompliance();
    
    // Get empty selection - THIS WILL FAIL until SelectionManager is implemented
    ClipSelectionResponse response = m_selectionManager->getClipSelection();
    
    // Verify empty selection response contract
    QCOMPARE(response.statusCode, 200);
    QVERIFY(response.selectedClips.isEmpty());
    QCOMPARE(response.selectionCount, 0);
    
    verifyPerformance("Get clip selection", 10);
}

void TestClipSelection::testSetClipSelectionReplace()
{
    qCInfo(jveTests, "Testing POST /selection/clips with replace mode");
    
    // Prepare SetClipSelectionRequest
    QJsonObject request;
    request["selection_mode"] = "replace";
    QJsonArray clipIds;
    clipIds.append(m_testClipIds[0]);
    clipIds.append(m_testClipIds[1]);
    request["clip_ids"] = clipIds;
    
    ClipSelectionResponse response = m_selectionManager->setClipSelection(request);
    
    // Verify replace selection response
    QCOMPARE(response.statusCode, 200);
    QCOMPARE(response.selectedClips.size(), 2);
    QCOMPARE(response.selectionCount, 2);
    QVERIFY(response.selectedClips.contains(m_testClipIds[0]));
    QVERIFY(response.selectedClips.contains(m_testClipIds[1]));
}

void TestClipSelection::testSetClipSelectionAdd()
{
    qCInfo(jveTests, "Testing POST /selection/clips with add mode (Cmd+click)");
    
    // First establish a selection
    QJsonObject initialRequest;
    initialRequest["selection_mode"] = "replace";
    QJsonArray initialClips;
    initialClips.append(m_testClipIds[0]);
    initialRequest["clip_ids"] = initialClips;
    m_selectionManager->setClipSelection(initialRequest);
    
    // Add to selection
    QJsonObject addRequest;
    addRequest["selection_mode"] = "add";
    QJsonArray addClips;
    addClips.append(m_testClipIds[1]);
    addClips.append(m_testClipIds[2]);
    addRequest["clip_ids"] = addClips;
    
    ClipSelectionResponse response = m_selectionManager->setClipSelection(addRequest);
    
    // Should now have 3 clips selected
    QCOMPARE(response.statusCode, 200);
    QCOMPARE(response.selectedClips.size(), 3);
    QCOMPARE(response.selectionCount, 3);
    QVERIFY(response.selectedClips.contains(m_testClipIds[0])); // Original
    QVERIFY(response.selectedClips.contains(m_testClipIds[1])); // Added
    QVERIFY(response.selectedClips.contains(m_testClipIds[2])); // Added
}

void TestClipSelection::testSetClipSelectionRemove()
{
    qCInfo(jveTests, "Testing POST /selection/clips with remove mode");
    
    // Start with multiple clips selected
    QJsonObject initialRequest;
    initialRequest["selection_mode"] = "replace";
    QJsonArray initialClips;
    initialClips.append(m_testClipIds[0]);
    initialClips.append(m_testClipIds[1]);
    initialClips.append(m_testClipIds[2]);
    initialRequest["clip_ids"] = initialClips;
    m_selectionManager->setClipSelection(initialRequest);
    
    // Remove from selection
    QJsonObject removeRequest;
    removeRequest["selection_mode"] = "remove";
    QJsonArray removeClips;
    removeClips.append(m_testClipIds[1]);
    removeRequest["clip_ids"] = removeClips;
    
    ClipSelectionResponse response = m_selectionManager->setClipSelection(removeRequest);
    
    // Should now have 2 clips selected (removed clip-2)
    QCOMPARE(response.statusCode, 200);
    QCOMPARE(response.selectedClips.size(), 2);
    QCOMPARE(response.selectionCount, 2);
    QVERIFY(response.selectedClips.contains(m_testClipIds[0]));
    QVERIFY(!response.selectedClips.contains(m_testClipIds[1])); // Removed
    QVERIFY(response.selectedClips.contains(m_testClipIds[2]));
}

void TestClipSelection::testSetClipSelectionToggle()
{
    qCInfo(jveTests, "Testing POST /selection/clips with toggle mode");
    
    // Start with some clips selected
    QJsonObject initialRequest;
    initialRequest["selection_mode"] = "replace";
    QJsonArray initialClips;
    initialClips.append(m_testClipIds[0]);
    initialRequest["clip_ids"] = initialClips;
    m_selectionManager->setClipSelection(initialRequest);
    
    // Toggle selection (should add unselected, remove selected)
    QJsonObject toggleRequest;
    toggleRequest["selection_mode"] = "toggle";
    QJsonArray toggleClips;
    toggleClips.append(m_testClipIds[0]); // Should be removed (was selected)
    toggleClips.append(m_testClipIds[1]); // Should be added (wasn't selected)
    toggleRequest["clip_ids"] = toggleClips;
    
    ClipSelectionResponse response = m_selectionManager->setClipSelection(toggleRequest);
    
    // Should now have only clip-2 selected
    QCOMPARE(response.statusCode, 200);
    QCOMPARE(response.selectedClips.size(), 1);
    QCOMPARE(response.selectionCount, 1);
    QVERIFY(!response.selectedClips.contains(m_testClipIds[0])); // Toggled off
    QVERIFY(response.selectedClips.contains(m_testClipIds[1])); // Toggled on
}

void TestClipSelection::testMultiClipSelection()
{
    qCInfo(jveTests, "Testing multi-clip selection scenarios");
    
    // Test selecting all clips
    QJsonObject selectAllRequest;
    selectAllRequest["selection_mode"] = "replace";
    QJsonArray allClips;
    for (const QString& clipId : m_testClipIds) {
        allClips.append(clipId);
    }
    selectAllRequest["clip_ids"] = allClips;
    
    ClipSelectionResponse response = m_selectionManager->setClipSelection(selectAllRequest);
    
    QCOMPARE(response.statusCode, 200);
    QCOMPARE(response.selectedClips.size(), 4);
    QCOMPARE(response.selectionCount, 4);
    
    // Verify all clips are in selection
    for (const QString& clipId : m_testClipIds) {
        QVERIFY(response.selectedClips.contains(clipId));
    }
    
    // Test clearing selection (empty array)
    QJsonObject clearRequest;
    clearRequest["selection_mode"] = "replace";
    clearRequest["clip_ids"] = QJsonArray();
    
    ClipSelectionResponse clearResponse = m_selectionManager->setClipSelection(clearRequest);
    
    QCOMPARE(clearResponse.statusCode, 200);
    QVERIFY(clearResponse.selectedClips.isEmpty());
    QCOMPARE(clearResponse.selectionCount, 0);
}

void TestClipSelection::testSelectionResponse()
{
    qCInfo(jveTests, "Testing ClipSelectionResponse schema compliance");
    
    QJsonObject request;
    request["selection_mode"] = "replace";
    QJsonArray clipIds;
    clipIds.append(m_testClipIds[0]);
    clipIds.append(m_testClipIds[1]);
    request["clip_ids"] = clipIds;
    
    ClipSelectionResponse response = m_selectionManager->setClipSelection(request);
    
    // Convert to JSON for schema validation
    QJsonObject responseJson = response.toJson();
    
    // Verify required fields present
    QVERIFY(responseJson.contains("selected_clips"));
    QVERIFY(responseJson.contains("selection_count"));
    
    // Verify field types
    QVERIFY(responseJson["selected_clips"].isArray());
    QVERIFY(responseJson["selection_count"].isDouble());
    
    // Verify array contents are UUIDs
    QJsonArray selectedClips = responseJson["selected_clips"].toArray();
    for (const QJsonValue& value : selectedClips) {
        QVERIFY(value.isString());
        QString clipId = value.toString();
        QVERIFY(!clipId.isEmpty());
        // Verify it's one of our test clip IDs
        QVERIFY(m_testClipIds.contains(clipId));
    }
}

QTEST_MAIN(TestClipSelection)
#include "test_clip_selection.moc"