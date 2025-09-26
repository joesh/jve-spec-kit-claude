#pragma once

#include <QVariant>
#include <QColor>
#include <QPointF>
#include <QStringList>
#include <QSqlDatabase>
#include <QSqlQuery>
#include <QString>
#include <QList>
#include <QMap>

/**
 * Property: Type-safe property system with validation and animation support
 * 
 * Constitutional requirements:
 * - Clip instance settings with comprehensive validation rules
 * - Animation/keyframe support for temporal property changes
 * - Property groups and categorization for UI organization
 * - Type-safe value storage with conversion and validation
 * - Performance optimization for large property collections
 * 
 * Engineering Rules:
 * - Rule 2.14: No hardcoded constants (uses schema_constants.h)
 * - Rule 2.26: Functions read like algorithms calling subfunctions
 * - Rule 2.27: Short, focused functions with single responsibilities
 */
class Property
{
public:
    enum PropertyType {
        String,
        Number,
        Boolean,
        Color,
        Point,
        Enum
    };

    struct Keyframe {
        qint64 time;        // Timestamp in milliseconds
        QVariant value;     // Value at this time
    };

    // Construction and identity
    static Property create(const QString& name, const QString& clipId);
    static Property load(const QString& id, QSqlDatabase& database);
    
    // Static factory methods
    static QList<Property> loadByClip(const QString& clipId, QSqlDatabase& database);
    static QList<Property> loadByGroup(const QString& clipId, const QString& group, QSqlDatabase& database);
    
    // Static group operations
    static bool resetGroup(const QString& clipId, const QString& group, QSqlDatabase& database);
    static bool copyGroup(const QString& fromClipId, const QString& group, const QString& toClipId, QSqlDatabase& database);

    // Core accessors
    QString id() const { return m_id; }
    QString name() const { return m_name; }
    QString clipId() const { return m_clipId; }
    PropertyType type() const { return m_type; }
    QString group() const { return m_group; }
    
    // Value management
    QVariant value() const { return m_value; }
    QVariant defaultValue() const { return m_defaultValue; }
    bool setValue(const QVariant& value);
    void setDefaultValue(const QVariant& defaultValue);
    
    // Type configuration
    void setType(PropertyType type);
    
    // Validation constraints
    QVariant minimum() const { return m_minimum; }
    QVariant maximum() const { return m_maximum; }
    void setMinimum(const QVariant& minimum);
    void setMaximum(const QVariant& maximum);
    
    // Enum validation
    QStringList enumValues() const { return m_enumValues; }
    void setEnumValues(const QStringList& values);
    
    // Group management
    void setGroup(const QString& group);
    
    // Animation support
    bool isAnimated() const;
    int keyframeCount() const;
    void addKeyframe(qint64 time, const QVariant& value);
    bool removeKeyframe(qint64 time);
    void clearKeyframes();
    double getValueAtTime(qint64 time) const;
    
    // Persistence
    bool save(QSqlDatabase& database);
    void markDirty() { m_isDirty = true; }
    bool isDirty() const { return m_isDirty; }

private:
    Property() = default;
    explicit Property(const QString& id, const QString& name, const QString& clipId);
    
    // Algorithm implementations
    bool validateValue(const QVariant& value) const;
    QVariant clampValue(const QVariant& value) const;
    bool saveToDatabase(QSqlDatabase& database);
    bool saveKeyframesToDatabase(QSqlDatabase& database);
    bool loadKeyframesFromDatabase(QSqlDatabase& database);
    QVariant interpolateValue(qint64 time) const;
    QString propertyTypeToString(PropertyType type) const;
    PropertyType stringToPropertyType(const QString& typeStr) const;

    // Core state
    QString m_id;
    QString m_name;
    QString m_clipId;
    PropertyType m_type = String;
    QString m_group;
    
    // Value state
    QVariant m_value;
    QVariant m_defaultValue;
    QVariant m_minimum;
    QVariant m_maximum;
    QStringList m_enumValues;
    
    // Animation state
    QMap<qint64, QVariant> m_keyframes;
    
    // Internal state
    bool m_isDirty = false;
    bool m_isLoaded = false;
};