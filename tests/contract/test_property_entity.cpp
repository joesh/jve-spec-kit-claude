#include "../common/test_base.h"
#include "../../src/core/models/property.h"
#include "../../src/core/models/clip.h"
#include "../../src/core/models/media.h"
#include "../../src/core/persistence/migrations.h"

#include <QTest>

/**
 * Contract Test T010: Property Entity
 * 
 * Tests the Property entity API contract - clip instance settings with validation.
 * Must fail initially per constitutional TDD requirement.
 * 
 * Contract Requirements:
 * - Property creation with clip association
 * - Type-safe value storage and validation
 * - Property animation/keyframe support
 * - Default value management
 * - Property groups and categorization
 * - Validation rules and constraints
 */
class TestPropertyEntity : public TestBase
{
    Q_OBJECT

private slots:
    void initTestCase() override;
    void testPropertyCreation();
    void testPropertyTypes();
    void testPropertyValidation();
    void testPropertyAnimation();
    void testPropertyGroups();
    void testPropertyPerformance();

private:
    QSqlDatabase m_database;
    QString m_clipId;
};

void TestPropertyEntity::initTestCase()
{
    TestBase::initTestCase();
    verifyTDDCompliance();
    
    if (!Migrations::createNewProject(m_testDatabasePath)) {
        QFAIL("Failed to create test project database");
    }
    
    m_database = QSqlDatabase::addDatabase("QSQLITE", "test_property_entity");
    m_database.setDatabaseName(m_testDatabasePath);
    QVERIFY(m_database.open());
    
    // Create test clip
    Media media = Media::create("test.mp4", "/path/test.mp4");
    QVERIFY(media.save(m_database));
    
    Clip clip = Clip::create("Test Clip", media.id());
    QVERIFY(clip.save(m_database));
    m_clipId = clip.id();
}

void TestPropertyEntity::testPropertyCreation()
{
    qCInfo(jveTests) << "Testing Property creation contract";
    verifyLibraryFirstCompliance();
    
    Property brightness = Property::create("brightness", m_clipId);
    brightness.setValue(110.0);
    brightness.setType(Property::Number);
    
    QVERIFY(!brightness.id().isEmpty());
    QCOMPARE(brightness.name(), QString("brightness"));
    QCOMPARE(brightness.clipId(), m_clipId);
    QCOMPARE(brightness.value().toDouble(), 110.0);
    QCOMPARE(brightness.type(), Property::Number);
    
    verifyPerformance("Property creation", 10);
}

void TestPropertyEntity::testPropertyTypes()
{
    qCInfo(jveTests) << "Testing property type system contract";
    
    // Number property
    Property numberProp = Property::create("opacity", m_clipId);
    numberProp.setType(Property::Number);
    numberProp.setValue(0.75);
    QCOMPARE(numberProp.value().toDouble(), 0.75);
    
    // Boolean property  
    Property boolProp = Property::create("enabled", m_clipId);
    boolProp.setType(Property::Boolean);
    boolProp.setValue(true);
    QCOMPARE(boolProp.value().toBool(), true);
    
    // String property
    Property stringProp = Property::create("blend_mode", m_clipId);
    stringProp.setType(Property::String);
    stringProp.setValue("multiply");
    QCOMPARE(stringProp.value().toString(), QString("multiply"));
    
    // Color property
    Property colorProp = Property::create("color", m_clipId);
    colorProp.setType(Property::Color);
    colorProp.setValue(QColor(255, 128, 64));
    QCOMPARE(colorProp.value().value<QColor>(), QColor(255, 128, 64));
    
    // Point property
    Property pointProp = Property::create("position", m_clipId);
    pointProp.setType(Property::Point);
    pointProp.setValue(QPointF(100.0, 200.0));
    QCOMPARE(pointProp.value().toPointF(), QPointF(100.0, 200.0));
}

void TestPropertyEntity::testPropertyValidation()
{
    qCInfo(jveTests) << "Testing property validation contract";
    
    Property opacity = Property::create("opacity", m_clipId);
    opacity.setType(Property::Number);
    
    // Set validation range
    opacity.setMinimum(0.0);
    opacity.setMaximum(1.0);
    
    // Valid values
    opacity.setValue(0.5);
    QCOMPARE(opacity.value().toDouble(), 0.5);
    
    opacity.setValue(0.0);
    QCOMPARE(opacity.value().toDouble(), 0.0);
    
    opacity.setValue(1.0);
    QCOMPARE(opacity.value().toDouble(), 1.0);
    
    // Invalid values should be clamped
    opacity.setValue(-0.1);
    QVERIFY(opacity.value().toDouble() >= 0.0);
    
    opacity.setValue(1.5);
    QVERIFY(opacity.value().toDouble() <= 1.0);
    
    // Test enum validation
    Property blendMode = Property::create("blend_mode", m_clipId);
    blendMode.setType(Property::Enum);
    blendMode.setEnumValues({"normal", "multiply", "screen", "overlay"});
    
    blendMode.setValue("multiply");
    QCOMPARE(blendMode.value().toString(), QString("multiply"));
    
    // Invalid enum should revert or reject
    blendMode.setValue("invalid_mode");
    QVERIFY(blendMode.enumValues().contains(blendMode.value().toString()));
}

void TestPropertyEntity::testPropertyAnimation()
{
    qCInfo(jveTests) << "Testing property animation contract";
    
    Property animatedProp = Property::create("scale", m_clipId);
    animatedProp.setType(Property::Number);
    animatedProp.setValue(1.0);
    
    // Add keyframes
    animatedProp.addKeyframe(0, 1.0);      // Start at 1.0
    animatedProp.addKeyframe(1000, 2.0);   // Scale to 2.0 at 1 second
    animatedProp.addKeyframe(2000, 0.5);   // Scale to 0.5 at 2 seconds
    
    QCOMPARE(animatedProp.keyframeCount(), 3);
    QVERIFY(animatedProp.isAnimated());
    
    // Test interpolated values
    double valueAt500ms = animatedProp.getValueAtTime(500);
    QVERIFY(valueAt500ms > 1.0 && valueAt500ms < 2.0); // Interpolated
    
    double valueAt1500ms = animatedProp.getValueAtTime(1500);
    QVERIFY(valueAt1500ms > 0.5 && valueAt1500ms < 2.0); // Interpolated
    
    // Test keyframe removal
    animatedProp.removeKeyframe(1000);
    QCOMPARE(animatedProp.keyframeCount(), 2);
    
    // Clear all keyframes
    animatedProp.clearKeyframes();
    QCOMPARE(animatedProp.keyframeCount(), 0);
    QVERIFY(!animatedProp.isAnimated());
}

void TestPropertyEntity::testPropertyGroups()
{
    qCInfo(jveTests) << "Testing property grouping contract";
    
    // Transform group
    Property posX = Property::create("position.x", m_clipId);
    Property posY = Property::create("position.y", m_clipId);
    Property rotation = Property::create("rotation", m_clipId);
    Property scaleX = Property::create("scale.x", m_clipId);
    Property scaleY = Property::create("scale.y", m_clipId);
    
    // Set group membership
    posX.setGroup("Transform");
    posY.setGroup("Transform");
    rotation.setGroup("Transform");
    scaleX.setGroup("Transform");
    scaleY.setGroup("Transform");
    
    // Color Correction group
    Property brightness = Property::create("brightness", m_clipId);
    Property contrast = Property::create("contrast", m_clipId);
    Property saturation = Property::create("saturation", m_clipId);
    
    brightness.setGroup("Color Correction");
    contrast.setGroup("Color Correction");
    saturation.setGroup("Color Correction");
    
    // Save all properties
    QList<Property> allProps = {posX, posY, rotation, scaleX, scaleY, 
                               brightness, contrast, saturation};
    for (auto& prop : allProps) {
        QVERIFY(prop.save(m_database));
    }
    
    // Load properties by group
    QList<Property> transformProps = Property::loadByGroup(m_clipId, "Transform", m_database);
    QCOMPARE(transformProps.size(), 5);
    
    QList<Property> colorProps = Property::loadByGroup(m_clipId, "Color Correction", m_database);
    QCOMPARE(colorProps.size(), 3);
    
    // Test group operations
    Property::resetGroup(m_clipId, "Transform", m_database); // Reset to defaults
    Property::copyGroup(m_clipId, "Transform", "another-clip-id", m_database); // Copy to another clip
}

void TestPropertyEntity::testPropertyPerformance()
{
    qCInfo(jveTests) << "Testing property performance contract";
    
    m_timer.restart();
    
    // Create many properties quickly
    for (int i = 0; i < 100; i++) {
        Property prop = Property::create(QString("property_%1").arg(i), m_clipId);
        prop.setType(Property::Number);
        prop.setValue(i * 0.01);
        QVERIFY(prop.save(m_database));
    }
    
    verifyPerformance("100 property creation and save", 100);
    
    // Test batch loading performance
    m_timer.restart();
    QList<Property> allProps = Property::loadByClip(m_clipId, m_database);
    QVERIFY(allProps.size() >= 100);
    
    verifyPerformance("Property batch load", 50);
}

QTEST_MAIN(TestPropertyEntity)
#include "test_property_entity.moc"