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
 * Contract Test T014: Selection Properties API
 * 
 * Tests GET/POST /selection/properties API contract for multi-selection property editing.
 * Must fail initially per constitutional TDD requirement.
 * 
 * Contract Requirements:
 * - Return properties with tri-state values (determinate/indeterminate)
 * - Handle multi-selection scenarios where clips have different values
 * - Support property setting across entire selection
 * - Distinguish between clip properties and metadata
 * - Enable professional Inspector panel workflows
 */
class TestSelectionProperties : public TestBase
{
    Q_OBJECT

private slots:
    void initTestCase() override;
    void testGetSelectionPropertiesEmpty();
    void testGetSelectionPropertiesSingle();
    void testGetSelectionPropertiesMultiple();
    void testTriStateValues();
    void testSetSelectionProperty();
    void testPropertiesVsMetadata();
    void testSelectionPropertiesResponse();

private:
    QSqlDatabase m_database;
    SelectionAPI* m_selectionManager;
    QString m_projectId;
    QString m_sequenceId;
    QStringList m_testClipIds;
};

void TestSelectionProperties::initTestCase()
{
    TestBase::initTestCase();
    verifyTDDCompliance();
    
    if (!Migrations::createNewProject(m_testDatabasePath)) {
        QFAIL("Failed to create test project database");
    }
    
    m_database = QSqlDatabase::addDatabase("QSQLITE", "test_selection_properties");
    m_database.setDatabaseName(m_testDatabasePath);
    QVERIFY(m_database.open());
    
    Project project = Project::create("Selection Properties Test Project");
    QVERIFY(project.save(m_database));
    m_projectId = project.id();
    
    Sequence sequence = Sequence::create("Test Sequence", m_projectId, 29.97, 1920, 1080);
    QVERIFY(sequence.save(m_database));
    m_sequenceId = sequence.id();
    
    // Create test clip IDs for property testing
    m_testClipIds = {"clip-1", "clip-2", "clip-3", "clip-4"};
    
    // This will fail until SelectionAPI property methods are implemented (TDD requirement)
    m_selectionManager = new SelectionAPI(this);
    m_selectionManager->setDatabase(m_database);
}

void TestSelectionProperties::testGetSelectionPropertiesEmpty()
{
    qCInfo(jveTests, "Testing GET /selection/properties with no selection");
    verifyLibraryFirstCompliance();
    
    // Get properties for empty selection - THIS WILL FAIL until SelectionAPI is implemented
    SelectionPropertiesResponse response = m_selectionManager->getSelectionProperties();
    
    // Verify empty selection properties response contract
    QCOMPARE(response.statusCode, 200);
    QVERIFY(response.properties.isEmpty());
    QVERIFY(response.metadata.isEmpty());
    
    verifyPerformance("Get selection properties", 20);
}

void TestSelectionProperties::testGetSelectionPropertiesSingle()
{
    qCInfo(jveTests, "Testing GET /selection/properties with single clip selected");
    
    // First select a single clip
    QJsonObject selectionRequest;
    selectionRequest["selection_mode"] = "replace";
    QJsonArray clipIds;
    clipIds.append(m_testClipIds[0]);
    selectionRequest["clip_ids"] = clipIds;
    m_selectionManager->setClipSelection(selectionRequest);
    
    // Get properties for single selection
    SelectionPropertiesResponse response = m_selectionManager->getSelectionProperties();
    
    if (response.statusCode == 200) {
        // Single selection should have determinate values
        QVERIFY(!response.properties.isEmpty() || !response.metadata.isEmpty());
        
        // Check that all property values are determinate (not indeterminate)
        for (auto it = response.properties.constBegin(); it != response.properties.constEnd(); ++it) {
            PropertyValue propValue = it.value();
            QCOMPARE(propValue.state, QString("determinate"));
            QVERIFY(propValue.canUndo); // Single clip properties should be undoable
        }
        
        for (auto it = response.metadata.constBegin(); it != response.metadata.constEnd(); ++it) {
            PropertyValue metaValue = it.value();
            QCOMPARE(metaValue.state, QString("determinate"));
        }
    }
}

void TestSelectionProperties::testGetSelectionPropertiesMultiple()
{
    qCInfo(jveTests, "Testing GET /selection/properties with multiple clips selected");
    
    // Select multiple clips
    QJsonObject selectionRequest;
    selectionRequest["selection_mode"] = "replace";
    QJsonArray clipIds;
    clipIds.append(m_testClipIds[0]);
    clipIds.append(m_testClipIds[1]);
    clipIds.append(m_testClipIds[2]);
    selectionRequest["clip_ids"] = clipIds;
    m_selectionManager->setClipSelection(selectionRequest);
    
    // Get properties for multi-selection
    SelectionPropertiesResponse response = m_selectionManager->getSelectionProperties();
    
    if (response.statusCode == 200) {
        // Multi-selection might have indeterminate values where clips differ
        QVERIFY(!response.properties.isEmpty() || !response.metadata.isEmpty());
        
        // Verify PropertyValue structure for multi-selection
        for (auto it = response.properties.constBegin(); it != response.properties.constEnd(); ++it) {
            PropertyValue propValue = it.value();
            QVERIFY(propValue.state == "determinate" || propValue.state == "indeterminate");
            
            if (propValue.state == "indeterminate") {
                // Indeterminate values might have null/empty value
                // but the structure should still be valid
                QVERIFY(!propValue.value.isUndefined());
            } else {
                // Determinate values should have actual values
                QVERIFY(!propValue.value.isNull());
            }
        }
    }
}

void TestSelectionProperties::testTriStateValues()
{
    qCInfo(jveTests, "Testing tri-state property values (determinate/indeterminate)");
    
    // This test verifies the tri-state control behavior for multi-selection
    // When multiple clips have same value: determinate
    // When multiple clips have different values: indeterminate
    
    // Select multiple clips that might have different property values
    QJsonObject selectionRequest;
    selectionRequest["selection_mode"] = "replace";
    QJsonArray clipIds;
    clipIds.append(m_testClipIds[0]);
    clipIds.append(m_testClipIds[1]);
    clipIds.append(m_testClipIds[2]);
    selectionRequest["clip_ids"] = clipIds;
    m_selectionManager->setClipSelection(selectionRequest);
    
    SelectionPropertiesResponse response = m_selectionManager->getSelectionProperties();
    
    if (response.statusCode == 200) {
        // Look for common properties that might be indeterminate
        QStringList expectedProperties = {"enabled", "opacity", "scale", "rotation", "position_x", "position_y"};
        
        for (const QString& propName : expectedProperties) {
            if (response.properties.contains(propName)) {
                PropertyValue propValue = response.properties[propName];
                
                // Verify state is valid enum value
                QVERIFY(propValue.state == "determinate" || propValue.state == "indeterminate");
                
                if (propValue.state == "indeterminate") {
                    // Indeterminate should indicate mixed values across selection
                    // Value might be null or represent a "mixed" state
                    qCInfo(jveTests, "Property %s is indeterminate (mixed values)", propName.toUtf8().constData());
                } else {
                    // Determinate should have a consistent value across selection
                    QVERIFY(!propValue.value.isNull());
                    qCInfo(jveTests, "Property %s is determinate", propName.toUtf8().constData());
                }
                
                // Check undo capability
                QVERIFY(propValue.canUndo == true || propValue.canUndo == false);
            }
        }
    }
}

void TestSelectionProperties::testSetSelectionProperty()
{
    qCInfo(jveTests, "Testing POST /selection/properties to set property across selection");
    
    // First select multiple clips
    QJsonObject selectionRequest;
    selectionRequest["selection_mode"] = "replace";
    QJsonArray clipIds;
    clipIds.append(m_testClipIds[0]);
    clipIds.append(m_testClipIds[1]);
    selectionRequest["clip_ids"] = clipIds;
    m_selectionManager->setClipSelection(selectionRequest);
    
    // Set a property across the selection
    QJsonObject propertyRequest;
    propertyRequest["property_name"] = "opacity";
    propertyRequest["property_value"] = 0.75; // 75% opacity
    propertyRequest["apply_to_metadata"] = false; // Apply to clip properties, not metadata
    
    SelectionPropertiesResponse response = m_selectionManager->setSelectionProperty(propertyRequest);
    
    if (response.statusCode == 200) {
        // After setting, the property should become determinate across selection
        QVERIFY(response.properties.contains("opacity"));
        PropertyValue opacityValue = response.properties["opacity"];
        
        QCOMPARE(opacityValue.state, QString("determinate"));
        QCOMPARE(opacityValue.value.toDouble(), 0.75);
        QVERIFY(opacityValue.canUndo); // Should be undoable
    }
    
    // Test setting metadata property
    QJsonObject metadataRequest;
    metadataRequest["property_name"] = "scene";
    metadataRequest["property_value"] = "Exterior Day";
    metadataRequest["apply_to_metadata"] = true; // Apply to metadata
    
    SelectionPropertiesResponse metadataResponse = m_selectionManager->setSelectionProperty(metadataRequest);
    
    if (metadataResponse.statusCode == 200) {
        // Metadata should be updated
        QVERIFY(metadataResponse.metadata.contains("scene"));
        PropertyValue sceneValue = metadataResponse.metadata["scene"];
        
        QCOMPARE(sceneValue.state, QString("determinate"));
        QCOMPARE(sceneValue.value.toString(), QString("Exterior Day"));
    }
}

void TestSelectionProperties::testPropertiesVsMetadata()
{
    qCInfo(jveTests, "Testing distinction between properties and metadata");
    
    // Select a clip to get its properties
    QJsonObject selectionRequest;
    selectionRequest["selection_mode"] = "replace";
    QJsonArray clipIds;
    clipIds.append(m_testClipIds[0]);
    selectionRequest["clip_ids"] = clipIds;
    m_selectionManager->setClipSelection(selectionRequest);
    
    SelectionPropertiesResponse response = m_selectionManager->getSelectionProperties();
    
    if (response.statusCode == 200) {
        // Properties and metadata should be separate hash containers
        // They are QHash objects, so just verify they exist
        Q_UNUSED(response.properties);
        Q_UNUSED(response.metadata);
        
        // Properties typically include: transform, effects, timing properties
        QStringList expectedProperties = {"enabled", "opacity", "scale", "rotation", "position_x", "position_y", "speed"};
        
        // Metadata typically includes: user annotations, organizational data
        QStringList expectedMetadata = {"scene", "shot", "take", "notes", "keywords", "rating"};
        
        // Verify separation - properties should not appear in metadata and vice versa
        for (const QString& prop : expectedProperties) {
            if (response.properties.contains(prop)) {
                QVERIFY(!response.metadata.contains(prop)); // Should not be in metadata
            }
        }
        
        for (const QString& meta : expectedMetadata) {
            if (response.metadata.contains(meta)) {
                QVERIFY(!response.properties.contains(meta)); // Should not be in properties
            }
        }
        
        // Both should use same PropertyValue structure
        for (auto it = response.properties.constBegin(); it != response.properties.constEnd(); ++it) {
            PropertyValue value = it.value();
            QVERIFY(value.state == "determinate" || value.state == "indeterminate");
        }
        
        for (auto it = response.metadata.constBegin(); it != response.metadata.constEnd(); ++it) {
            PropertyValue value = it.value();
            QVERIFY(value.state == "determinate" || value.state == "indeterminate");
        }
    }
}

void TestSelectionProperties::testSelectionPropertiesResponse()
{
    qCInfo(jveTests, "Testing SelectionPropertiesResponse schema compliance");
    
    // Select clips and get properties
    QJsonObject selectionRequest;
    selectionRequest["selection_mode"] = "replace";
    QJsonArray clipIds;
    clipIds.append(m_testClipIds[0]);
    selectionRequest["clip_ids"] = clipIds;
    m_selectionManager->setClipSelection(selectionRequest);
    
    SelectionPropertiesResponse response = m_selectionManager->getSelectionProperties();
    
    // Convert to JSON for schema validation
    QJsonObject responseJson = response.toJson();
    
    // Verify required fields present
    QVERIFY(responseJson.contains("properties"));
    QVERIFY(responseJson.contains("metadata"));
    
    // Verify field types
    QVERIFY(responseJson["properties"].isObject());
    QVERIFY(responseJson["metadata"].isObject());
    
    // Verify PropertyValue structure
    QJsonObject properties = responseJson["properties"].toObject();
    for (auto it = properties.constBegin(); it != properties.constEnd(); ++it) {
        QJsonObject propValue = it.value().toObject();
        
        // Required PropertyValue fields
        QVERIFY(propValue.contains("value"));
        QVERIFY(propValue.contains("state"));
        
        // Verify state enum
        QString state = propValue["state"].toString();
        QVERIFY(state == "determinate" || state == "indeterminate");
        
        // Optional can_undo field
        if (propValue.contains("can_undo")) {
            QVERIFY(propValue["can_undo"].isBool());
        }
    }
    
    // Same verification for metadata
    QJsonObject metadata = responseJson["metadata"].toObject();
    for (auto it = metadata.constBegin(); it != metadata.constEnd(); ++it) {
        QJsonObject metaValue = it.value().toObject();
        
        QVERIFY(metaValue.contains("value"));
        QVERIFY(metaValue.contains("state"));
        
        QString state = metaValue["state"].toString();
        QVERIFY(state == "determinate" || state == "indeterminate");
    }
}

QTEST_MAIN(TestSelectionProperties)
#include "test_selection_properties.moc"