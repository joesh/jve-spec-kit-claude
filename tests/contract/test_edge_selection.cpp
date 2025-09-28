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
 * Contract Test T013: Edge Selection API
 * 
 * Tests GET/POST /selection/edges API contract for edge selection.
 * Must fail initially per constitutional TDD requirement.
 * 
 * Contract Requirements:
 * - Support Cmd+click edge selection for ripple/roll operations
 * - Handle head/tail edge types
 * - Return EdgeSelectionResponse with selected edges
 * - Support selection modes: replace, add, remove, toggle
 * - Enable professional ripple trim and roll edit workflows
 */
class TestEdgeSelection : public TestBase
{
    Q_OBJECT

private slots:
    void initTestCase() override;
    void testGetEdgeSelectionEmpty();
    void testSetEdgeSelectionReplace();
    void testSetEdgeSelectionAdd();
    void testSetEdgeSelectionRemove();
    void testSetEdgeSelectionToggle();
    void testEdgeTypes();
    void testEdgeSelectionResponse();

private:
    QSqlDatabase m_database;
    SelectionAPI* m_selectionManager;
    QString m_projectId;
    QString m_sequenceId;
    QStringList m_testClipIds;
};

void TestEdgeSelection::initTestCase()
{
    TestBase::initTestCase();
    verifyTDDCompliance();
    
    if (!Migrations::createNewProject(m_testDatabasePath)) {
        QFAIL("Failed to create test project database");
    }
    
    m_database = QSqlDatabase::addDatabase("QSQLITE", "test_edge_selection");
    m_database.setDatabaseName(m_testDatabasePath);
    QVERIFY(m_database.open());
    
    Project project = Project::create("Edge Selection Test Project");
    QVERIFY(project.save(m_database));
    m_projectId = project.id();
    
    Sequence sequence = Sequence::create("Test Sequence", m_projectId, 29.97, 1920, 1080);
    QVERIFY(sequence.save(m_database));
    m_sequenceId = sequence.id();
    
    // Create test clip IDs for edge testing
    m_testClipIds = {"clip-1", "clip-2", "clip-3", "clip-4"};
    
    // This will fail until SelectionAPI edge methods are implemented (TDD requirement)
    m_selectionManager = new SelectionAPI(this);
    m_selectionManager->setDatabase(m_database);
}

void TestEdgeSelection::testGetEdgeSelectionEmpty()
{
    qCInfo(jveTests, "Testing GET /selection/edges with no selection");
    verifyLibraryFirstCompliance();
    
    // Get empty edge selection - THIS WILL FAIL until SelectionAPI is implemented
    EdgeSelectionResponse response = m_selectionManager->getEdgeSelection();
    
    // Verify empty edge selection response contract
    QCOMPARE(response.statusCode, 200);
    QVERIFY(response.selectedEdges.isEmpty());
    QCOMPARE(response.selectionCount, 0);
    
    verifyPerformance("Get edge selection", 10);
}

void TestEdgeSelection::testSetEdgeSelectionReplace()
{
    qCInfo(jveTests, "Testing POST /selection/edges with replace mode");
    
    // Prepare SetEdgeSelectionRequest with ClipEdge objects
    QJsonObject request;
    request["selection_mode"] = "replace";
    
    QJsonArray edges;
    QJsonObject edge1;
    edge1["clip_id"] = m_testClipIds[0];
    edge1["edge_type"] = "head"; // Start of clip
    edges.append(edge1);
    
    QJsonObject edge2;
    edge2["clip_id"] = m_testClipIds[1];
    edge2["edge_type"] = "tail"; // End of clip
    edges.append(edge2);
    
    request["edges"] = edges;
    
    EdgeSelectionResponse response = m_selectionManager->setEdgeSelection(request);
    
    // Verify replace edge selection response
    QCOMPARE(response.statusCode, 200);
    QCOMPARE(response.selectedEdges.size(), 2);
    QCOMPARE(response.selectionCount, 2);
    
    // Verify edge structure
    QVERIFY(response.selectedEdges[0].clipId == m_testClipIds[0]);
    QVERIFY(response.selectedEdges[0].edgeType == "head");
    QVERIFY(response.selectedEdges[1].clipId == m_testClipIds[1]);
    QVERIFY(response.selectedEdges[1].edgeType == "tail");
}

void TestEdgeSelection::testSetEdgeSelectionAdd()
{
    qCInfo(jveTests, "Testing POST /selection/edges with add mode (Cmd+click)");
    
    // First establish an edge selection
    QJsonObject initialRequest;
    initialRequest["selection_mode"] = "replace";
    QJsonArray initialEdges;
    QJsonObject initialEdge;
    initialEdge["clip_id"] = m_testClipIds[0];
    initialEdge["edge_type"] = "head";
    initialEdges.append(initialEdge);
    initialRequest["edges"] = initialEdges;
    m_selectionManager->setEdgeSelection(initialRequest);
    
    // Add to edge selection (Cmd+click behavior)
    QJsonObject addRequest;
    addRequest["selection_mode"] = "add";
    QJsonArray addEdges;
    
    QJsonObject addEdge1;
    addEdge1["clip_id"] = m_testClipIds[1];
    addEdge1["edge_type"] = "tail";
    addEdges.append(addEdge1);
    
    QJsonObject addEdge2;
    addEdge2["clip_id"] = m_testClipIds[2];
    addEdge2["edge_type"] = "head";
    addEdges.append(addEdge2);
    
    addRequest["edges"] = addEdges;
    
    EdgeSelectionResponse response = m_selectionManager->setEdgeSelection(addRequest);
    
    // Should now have 3 edges selected
    QCOMPARE(response.statusCode, 200);
    QCOMPARE(response.selectedEdges.size(), 3);
    QCOMPARE(response.selectionCount, 3);
    
    // Verify all edges are present
    QStringList selectedClipIds;
    for (const auto& edge : response.selectedEdges) {
        selectedClipIds.append(edge.clipId);
    }
    QVERIFY(selectedClipIds.contains(m_testClipIds[0])); // Original
    QVERIFY(selectedClipIds.contains(m_testClipIds[1])); // Added
    QVERIFY(selectedClipIds.contains(m_testClipIds[2])); // Added
}

void TestEdgeSelection::testSetEdgeSelectionRemove()
{
    qCInfo(jveTests, "Testing POST /selection/edges with remove mode");
    
    // Start with multiple edges selected
    QJsonObject initialRequest;
    initialRequest["selection_mode"] = "replace";
    QJsonArray initialEdges;
    
    QJsonObject edge1;
    edge1["clip_id"] = m_testClipIds[0];
    edge1["edge_type"] = "head";
    initialEdges.append(edge1);
    
    QJsonObject edge2;
    edge2["clip_id"] = m_testClipIds[1];
    edge2["edge_type"] = "tail";
    initialEdges.append(edge2);
    
    QJsonObject edge3;
    edge3["clip_id"] = m_testClipIds[2];
    edge3["edge_type"] = "head";
    initialEdges.append(edge3);
    
    initialRequest["edges"] = initialEdges;
    m_selectionManager->setEdgeSelection(initialRequest);
    
    // Remove from edge selection
    QJsonObject removeRequest;
    removeRequest["selection_mode"] = "remove";
    QJsonArray removeEdges;
    
    QJsonObject removeEdge;
    removeEdge["clip_id"] = m_testClipIds[1];
    removeEdge["edge_type"] = "tail"; // Remove the middle edge
    removeEdges.append(removeEdge);
    
    removeRequest["edges"] = removeEdges;
    
    EdgeSelectionResponse response = m_selectionManager->setEdgeSelection(removeRequest);
    
    // Should now have 2 edges selected (removed one)
    QCOMPARE(response.statusCode, 200);
    QCOMPARE(response.selectedEdges.size(), 2);
    QCOMPARE(response.selectionCount, 2);
    
    // Verify correct edges remain
    QStringList selectedClipIds;
    for (const auto& edge : response.selectedEdges) {
        selectedClipIds.append(edge.clipId);
    }
    QVERIFY(selectedClipIds.contains(m_testClipIds[0])); // Should remain
    QVERIFY(!selectedClipIds.contains(m_testClipIds[1])); // Should be removed
    QVERIFY(selectedClipIds.contains(m_testClipIds[2])); // Should remain
}

void TestEdgeSelection::testSetEdgeSelectionToggle()
{
    qCInfo(jveTests, "Testing POST /selection/edges with toggle mode");
    
    // Start with one edge selected
    QJsonObject initialRequest;
    initialRequest["selection_mode"] = "replace";
    QJsonArray initialEdges;
    QJsonObject initialEdge;
    initialEdge["clip_id"] = m_testClipIds[0];
    initialEdge["edge_type"] = "head";
    initialEdges.append(initialEdge);
    initialRequest["edges"] = initialEdges;
    m_selectionManager->setEdgeSelection(initialRequest);
    
    // Toggle selection (should remove selected, add unselected)
    QJsonObject toggleRequest;
    toggleRequest["selection_mode"] = "toggle";
    QJsonArray toggleEdges;
    
    QJsonObject toggleEdge1;
    toggleEdge1["clip_id"] = m_testClipIds[0];
    toggleEdge1["edge_type"] = "head"; // Should be removed (was selected)
    toggleEdges.append(toggleEdge1);
    
    QJsonObject toggleEdge2;
    toggleEdge2["clip_id"] = m_testClipIds[1];
    toggleEdge2["edge_type"] = "tail"; // Should be added (wasn't selected)
    toggleEdges.append(toggleEdge2);
    
    toggleRequest["edges"] = toggleEdges;
    
    EdgeSelectionResponse response = m_selectionManager->setEdgeSelection(toggleRequest);
    
    // Should now have only the second edge selected
    QCOMPARE(response.statusCode, 200);
    QCOMPARE(response.selectedEdges.size(), 1);
    QCOMPARE(response.selectionCount, 1);
    
    // Verify correct edge is selected
    QVERIFY(response.selectedEdges[0].clipId == m_testClipIds[1]);
    QVERIFY(response.selectedEdges[0].edgeType == "tail");
}

void TestEdgeSelection::testEdgeTypes()
{
    qCInfo(jveTests, "Testing head and tail edge types");
    
    // Test head edge selection
    QJsonObject headRequest;
    headRequest["selection_mode"] = "replace";
    QJsonArray headEdges;
    QJsonObject headEdge;
    headEdge["clip_id"] = m_testClipIds[0];
    headEdge["edge_type"] = "head";
    headEdges.append(headEdge);
    headRequest["edges"] = headEdges;
    
    EdgeSelectionResponse headResponse = m_selectionManager->setEdgeSelection(headRequest);
    
    if (headResponse.statusCode == 200) {
        QCOMPARE(headResponse.selectedEdges.size(), 1);
        QVERIFY(headResponse.selectedEdges[0].edgeType == "head");
    }
    
    // Test tail edge selection
    QJsonObject tailRequest;
    tailRequest["selection_mode"] = "replace";
    QJsonArray tailEdges;
    QJsonObject tailEdge;
    tailEdge["clip_id"] = m_testClipIds[1];
    tailEdge["edge_type"] = "tail";
    tailEdges.append(tailEdge);
    tailRequest["edges"] = tailEdges;
    
    EdgeSelectionResponse tailResponse = m_selectionManager->setEdgeSelection(tailRequest);
    
    if (tailResponse.statusCode == 200) {
        QCOMPARE(tailResponse.selectedEdges.size(), 1);
        QVERIFY(tailResponse.selectedEdges[0].edgeType == "tail");
    }
    
    // Test selecting both edges of same clip
    QJsonObject bothRequest;
    bothRequest["selection_mode"] = "replace";
    QJsonArray bothEdges;
    
    QJsonObject clipHeadEdge;
    clipHeadEdge["clip_id"] = m_testClipIds[2];
    clipHeadEdge["edge_type"] = "head";
    bothEdges.append(clipHeadEdge);
    
    QJsonObject clipTailEdge;
    clipTailEdge["clip_id"] = m_testClipIds[2];
    clipTailEdge["edge_type"] = "tail";
    bothEdges.append(clipTailEdge);
    
    bothRequest["edges"] = bothEdges;
    
    EdgeSelectionResponse bothResponse = m_selectionManager->setEdgeSelection(bothRequest);
    
    if (bothResponse.statusCode == 200) {
        QCOMPARE(bothResponse.selectedEdges.size(), 2);
        QVERIFY(bothResponse.selectedEdges[0].clipId == m_testClipIds[2]);
        QVERIFY(bothResponse.selectedEdges[1].clipId == m_testClipIds[2]);
        // Both head and tail edges of same clip should be selectable
    }
}

void TestEdgeSelection::testEdgeSelectionResponse()
{
    qCInfo(jveTests, "Testing EdgeSelectionResponse schema compliance");
    
    QJsonObject request;
    request["selection_mode"] = "replace";
    QJsonArray edges;
    QJsonObject edge;
    edge["clip_id"] = m_testClipIds[0];
    edge["edge_type"] = "head";
    edges.append(edge);
    request["edges"] = edges;
    
    EdgeSelectionResponse response = m_selectionManager->setEdgeSelection(request);
    
    // Convert to JSON for schema validation
    QJsonObject responseJson = response.toJson();
    
    // Verify required fields present
    QVERIFY(responseJson.contains("selected_edges"));
    QVERIFY(responseJson.contains("selection_count"));
    
    // Verify field types
    QVERIFY(responseJson["selected_edges"].isArray());
    QVERIFY(responseJson["selection_count"].isDouble());
    
    // Verify edge structure in array
    QJsonArray selectedEdges = responseJson["selected_edges"].toArray();
    if (selectedEdges.size() > 0) {
        QJsonObject firstEdge = selectedEdges.first().toObject();
        QVERIFY(firstEdge.contains("clip_id"));
        QVERIFY(firstEdge.contains("edge_type"));
        QVERIFY(firstEdge["clip_id"].isString());
        QVERIFY(firstEdge["edge_type"].isString());
        
        // Verify edge_type is valid enum value
        QString edgeType = firstEdge["edge_type"].toString();
        QVERIFY(edgeType == "head" || edgeType == "tail");
    }
}

QTEST_MAIN(TestEdgeSelection)
#include "test_edge_selection.moc"