#include "../common/test_base.h"
#include "../../src/ui/selection/selection_manager.h"
#include "../../src/core/models/clip.h"
#include "../../src/core/persistence/migrations.h"

#include <QTest>

/**
 * Contract Test T012: Selection System
 * 
 * Tests the Selection system API contract - multi-selection with tri-state controls.
 * Must fail initially per constitutional TDD requirement.
 * 
 * Contract Requirements:
 * - Multi-selection of clips, tracks, and timeline elements
 * - Tri-state selection controls (none/partial/all)
 * - Edge selection with Cmd+click patterns
 * - Selection persistence across operations
 * - Selection-based operations and transformations
 * - Keyboard navigation and shortcuts
 */
class TestSelectionSystem : public TestBase
{
    Q_OBJECT

private slots:
    void initTestCase() override;
    void testBasicSelection();
    void testMultiSelection();
    void testTriStateControls();
    void testEdgeSelection();
    void testSelectionPersistence();
    void testSelectionOperations();
    void testKeyboardNavigation();
    void testSelectionPerformance();

private:
    QSqlDatabase m_database;
    SelectionManager* m_selectionManager;
    QList<QString> m_testClipIds;
};

void TestSelectionSystem::initTestCase()
{
    TestBase::initTestCase();
    verifyTDDCompliance();
    
    if (!Migrations::createNewProject(m_testDatabasePath)) {
        QFAIL("Failed to create test project database");
    }
    
    m_database = QSqlDatabase::addDatabase("QSQLITE", "test_selection_system");
    m_database.setDatabaseName(m_testDatabasePath);
    QVERIFY(m_database.open());
    
    m_selectionManager = new SelectionManager(this);
    
    // Create test clips
    Media media = Media::create("test.mp4", "/path/test.mp4");
    QVERIFY(media.save(m_database));
    
    for (int i = 0; i < 5; i++) {
        Clip clip = Clip::create(QString("Clip %1").arg(i + 1), media.id());
        clip.setTimelinePosition(i * 2000, (i + 1) * 2000); // Non-overlapping clips
        QVERIFY(clip.save(m_database));
        m_testClipIds.append(clip.id());
    }
}

void TestSelectionSystem::testBasicSelection()
{
    qCInfo(jveTests) << "Testing basic selection contract";
    verifyLibraryFirstCompliance();
    
    // Initial state - nothing selected
    QVERIFY(m_selectionManager->isEmpty());
    QCOMPARE(m_selectionManager->count(), 0);
    QVERIFY(m_selectionManager->getSelectedItems().isEmpty());
    
    // Select single item
    m_selectionManager->select(m_testClipIds[0]);
    QVERIFY(!m_selectionManager->isEmpty());
    QCOMPARE(m_selectionManager->count(), 1);
    QVERIFY(m_selectionManager->isSelected(m_testClipIds[0]));
    
    // Clear selection
    m_selectionManager->clear();
    QVERIFY(m_selectionManager->isEmpty());
    QVERIFY(!m_selectionManager->isSelected(m_testClipIds[0]));
    
    verifyPerformance("Basic selection operations", 10);
}

void TestSelectionSystem::testMultiSelection()
{
    qCInfo(jveTests) << "Testing multi-selection contract";
    
    m_selectionManager->clear();
    
    // Select multiple items
    m_selectionManager->select(m_testClipIds[0]);
    m_selectionManager->addToSelection(m_testClipIds[1]);
    m_selectionManager->addToSelection(m_testClipIds[2]);
    
    QCOMPARE(m_selectionManager->count(), 3);
    QVERIFY(m_selectionManager->isSelected(m_testClipIds[0]));
    QVERIFY(m_selectionManager->isSelected(m_testClipIds[1]));
    QVERIFY(m_selectionManager->isSelected(m_testClipIds[2]));
    QVERIFY(!m_selectionManager->isSelected(m_testClipIds[3]));
    
    // Remove from selection
    m_selectionManager->removeFromSelection(m_testClipIds[1]);
    QCOMPARE(m_selectionManager->count(), 2);
    QVERIFY(!m_selectionManager->isSelected(m_testClipIds[1]));
    
    // Toggle selection
    m_selectionManager->toggleSelection(m_testClipIds[3]); // Add
    QVERIFY(m_selectionManager->isSelected(m_testClipIds[3]));
    
    m_selectionManager->toggleSelection(m_testClipIds[0]); // Remove
    QVERIFY(!m_selectionManager->isSelected(m_testClipIds[0]));
    
    // Select all
    m_selectionManager->selectAll(m_testClipIds);
    QCOMPARE(m_selectionManager->count(), m_testClipIds.size());
    
    // Select none
    m_selectionManager->selectNone();
    QVERIFY(m_selectionManager->isEmpty());
}

void TestSelectionSystem::testTriStateControls()
{
    qCInfo(jveTests) << "Testing tri-state selection controls contract";
    
    m_selectionManager->clear();
    
    // Test tri-state logic for track selection
    QString trackId = "test-track-1";
    QList<QString> trackClips = {m_testClipIds[0], m_testClipIds[1], m_testClipIds[2]};
    
    // None selected (state: None)
    SelectionState trackState = m_selectionManager->getTrackSelectionState(trackId, trackClips);
    QCOMPARE(trackState, SelectionState::None);
    
    // Partial selection (state: Partial)
    m_selectionManager->select(trackClips[0]);
    m_selectionManager->addToSelection(trackClips[1]);
    trackState = m_selectionManager->getTrackSelectionState(trackId, trackClips);
    QCOMPARE(trackState, SelectionState::Partial);
    
    // All selected (state: All)
    m_selectionManager->addToSelection(trackClips[2]);
    trackState = m_selectionManager->getTrackSelectionState(trackId, trackClips);
    QCOMPARE(trackState, SelectionState::All);
    
    // Test tri-state control behavior
    // Click on tri-state control in "All" state should deselect all
    m_selectionManager->handleTriStateClick(trackId, trackClips, SelectionState::All);
    trackState = m_selectionManager->getTrackSelectionState(trackId, trackClips);
    QCOMPARE(trackState, SelectionState::None);
    
    // Click on tri-state control in "None" state should select all
    m_selectionManager->handleTriStateClick(trackId, trackClips, SelectionState::None);
    trackState = m_selectionManager->getTrackSelectionState(trackId, trackClips);
    QCOMPARE(trackState, SelectionState::All);
    
    // Click on tri-state control in "Partial" state should select all
    m_selectionManager->removeFromSelection(trackClips[0]); // Make partial
    trackState = m_selectionManager->getTrackSelectionState(trackId, trackClips);
    QCOMPARE(trackState, SelectionState::Partial);
    
    m_selectionManager->handleTriStateClick(trackId, trackClips, SelectionState::Partial);
    trackState = m_selectionManager->getTrackSelectionState(trackId, trackClips);
    QCOMPARE(trackState, SelectionState::All);
}

void TestSelectionSystem::testEdgeSelection()
{
    qCInfo(jveTests) << "Testing edge selection contract";
    
    m_selectionManager->clear();
    
    // Test edge selection with Cmd+Click pattern
    // First, select a clip normally
    m_selectionManager->select(m_testClipIds[1]);
    QCOMPARE(m_selectionManager->count(), 1);
    
    // Edge selection: Cmd+click on earlier clip should select range
    bool cmdPressed = true;
    m_selectionManager->handleClick(m_testClipIds[0], cmdPressed);
    
    // Should select range from clip 0 to clip 1
    QVERIFY(m_selectionManager->isSelected(m_testClipIds[0]));
    QVERIFY(m_selectionManager->isSelected(m_testClipIds[1]));
    QCOMPARE(m_selectionManager->count(), 2);
    
    // Edge selection: Cmd+click on later clip should extend range
    m_selectionManager->handleClick(m_testClipIds[3], cmdPressed);
    
    // Should now select clips 0-3
    for (int i = 0; i <= 3; i++) {
        QVERIFY(m_selectionManager->isSelected(m_testClipIds[i]));
    }
    QVERIFY(!m_selectionManager->isSelected(m_testClipIds[4]));
    QCOMPARE(m_selectionManager->count(), 4);
    
    // Test edge selection boundaries
    SelectionRange range = m_selectionManager->getSelectionRange();
    QCOMPARE(range.startId, m_testClipIds[0]);
    QCOMPARE(range.endId, m_testClipIds[3]);
    QCOMPARE(range.count, 4);
}

void TestSelectionSystem::testSelectionPersistence()
{
    qCInfo(jveTests) << "Testing selection persistence contract";
    
    // Create a selection
    m_selectionManager->clear();
    m_selectionManager->select(m_testClipIds[0]);
    m_selectionManager->addToSelection(m_testClipIds[2]);
    m_selectionManager->addToSelection(m_testClipIds[4]);
    
    QCOMPARE(m_selectionManager->count(), 3);
    
    // Save selection state
    SelectionSnapshot snapshot = m_selectionManager->saveSnapshot();
    QCOMPARE(snapshot.items.size(), 3);
    QVERIFY(snapshot.items.contains(m_testClipIds[0]));
    QVERIFY(snapshot.items.contains(m_testClipIds[2]));
    QVERIFY(snapshot.items.contains(m_testClipIds[4]));
    
    // Modify selection
    m_selectionManager->clear();
    m_selectionManager->select(m_testClipIds[1]);
    QCOMPARE(m_selectionManager->count(), 1);
    
    // Restore selection
    m_selectionManager->restoreSnapshot(snapshot);
    QCOMPARE(m_selectionManager->count(), 3);
    QVERIFY(m_selectionManager->isSelected(m_testClipIds[0]));
    QVERIFY(m_selectionManager->isSelected(m_testClipIds[2]));
    QVERIFY(m_selectionManager->isSelected(m_testClipIds[4]));
    QVERIFY(!m_selectionManager->isSelected(m_testClipIds[1]));
    
    // Test selection persistence across operations
    QString operationId = m_selectionManager->beginOperation("test_operation");
    
    // Selection should remain stable during operation
    QCOMPARE(m_selectionManager->count(), 3);
    
    m_selectionManager->endOperation(operationId);
    
    // Selection should still be intact
    QCOMPARE(m_selectionManager->count(), 3);
}

void TestSelectionSystem::testSelectionOperations()
{
    qCInfo(jveTests) << "Testing selection-based operations contract";
    
    // Create selection for batch operations
    m_selectionManager->clear();
    m_selectionManager->select(m_testClipIds[1]);
    m_selectionManager->addToSelection(m_testClipIds[2]);
    m_selectionManager->addToSelection(m_testClipIds[3]);
    
    // Test batch property changes
    QVariantMap properties;
    properties["opacity"] = 0.75;
    properties["volume"] = 0.8;
    
    SelectionOperation operation = m_selectionManager->createBatchOperation("SetProperties");
    operation.setParameters(properties);
    
    ExecutionResult result = m_selectionManager->executeOperation(operation);
    QVERIFY(result.success);
    QCOMPARE(result.affectedItems.size(), 3);
    
    // Verify all selected items were affected
    for (const QString& clipId : result.affectedItems) {
        QVERIFY(m_selectionManager->isSelected(clipId));
    }
    
    // Test selection-based transformations
    TransformData transform;
    transform.offsetX = 100.0;
    transform.offsetY = 50.0;
    transform.scaleX = 1.2;
    transform.scaleY = 1.2;
    
    SelectionOperation transformOp = m_selectionManager->createBatchOperation("Transform");
    transformOp.setTransform(transform);
    
    ExecutionResult transformResult = m_selectionManager->executeOperation(transformOp);
    QVERIFY(transformResult.success);
    QCOMPARE(transformResult.affectedItems.size(), 3);
    
    // Test undo for selection operations
    QVERIFY(m_selectionManager->canUndo());
    m_selectionManager->undo();
    
    // After undo, transformations should be reverted
    // (Implementation detail - would verify actual clip positions)
}

void TestSelectionSystem::testKeyboardNavigation()
{
    qCInfo(jveTests) << "Testing keyboard navigation contract";
    
    m_selectionManager->clear();
    
    // Test arrow key navigation
    m_selectionManager->select(m_testClipIds[2]); // Start in middle
    
    // Move selection right
    m_selectionManager->moveSelection(SelectionDirection::Right);
    QVERIFY(m_selectionManager->isSelected(m_testClipIds[3]));
    QVERIFY(!m_selectionManager->isSelected(m_testClipIds[2]));
    
    // Move selection left  
    m_selectionManager->moveSelection(SelectionDirection::Left);
    QVERIFY(m_selectionManager->isSelected(m_testClipIds[2]));
    QVERIFY(!m_selectionManager->isSelected(m_testClipIds[3]));
    
    // Test boundary conditions
    m_selectionManager->select(m_testClipIds[0]); // First clip
    m_selectionManager->moveSelection(SelectionDirection::Left);
    QVERIFY(m_selectionManager->isSelected(m_testClipIds[0])); // Should stay at boundary
    
    m_selectionManager->select(m_testClipIds.last()); // Last clip
    m_selectionManager->moveSelection(SelectionDirection::Right);
    QVERIFY(m_selectionManager->isSelected(m_testClipIds.last())); // Should stay at boundary
    
    // Test extend selection with Shift+Arrow
    m_selectionManager->select(m_testClipIds[1]);
    m_selectionManager->extendSelection(SelectionDirection::Right);
    
    QVERIFY(m_selectionManager->isSelected(m_testClipIds[1])); // Original selection preserved
    QVERIFY(m_selectionManager->isSelected(m_testClipIds[2])); // Extended to next
    QCOMPARE(m_selectionManager->count(), 2);
    
    // Test keyboard shortcuts
    m_selectionManager->handleKeyPress(Qt::Key_A, Qt::ControlModifier); // Ctrl+A = Select All
    QCOMPARE(m_selectionManager->count(), m_testClipIds.size());
    
    m_selectionManager->handleKeyPress(Qt::Key_D, Qt::ControlModifier); // Ctrl+D = Deselect All
    QVERIFY(m_selectionManager->isEmpty());
}

void TestSelectionSystem::testSelectionPerformance()
{
    qCInfo(jveTests) << "Testing selection performance contract";
    
    // Create many items for performance testing
    QList<QString> manyItems;
    for (int i = 0; i < 1000; i++) {
        manyItems.append(QString("performance_item_%1").arg(i));
    }
    
    m_selectionManager->clear();
    
    // Test batch selection performance
    m_timer.restart();
    m_selectionManager->selectAll(manyItems);
    QCOMPARE(m_selectionManager->count(), 1000);
    verifyPerformance("Select 1000 items", 100);
    
    // Test selection state query performance
    m_timer.restart();
    for (int i = 0; i < 1000; i++) {
        bool selected = m_selectionManager->isSelected(manyItems[i]);
        QVERIFY(selected);
    }
    verifyPerformance("1000 selection queries", 50);
    
    // Test tri-state calculation performance
    m_timer.restart();
    for (int i = 0; i < 100; i++) {
        QList<QString> subset = manyItems.mid(i * 10, 10);
        SelectionState state = m_selectionManager->getTrackSelectionState(
            QString("track_%1").arg(i), subset);
        QCOMPARE(state, SelectionState::All);
    }
    verifyPerformance("100 tri-state calculations", 50);
    
    // Test large selection operations
    m_timer.restart();
    m_selectionManager->clear();
    verifyPerformance("Clear 1000 item selection", 50);
}

QTEST_MAIN(TestSelectionSystem)
#include "test_selection_system.moc"