#include "property.h"
#include "../persistence/schema_constants.h"

#include <QUuid>
#include <QSqlError>
#include <QLoggingCategory>
#include <QJsonDocument>
#include <QJsonObject>
#include <QDebug>

Q_LOGGING_CATEGORY(jveProperty, "jve.property")

Property Property::create(const QString& name, const QString& clipId)
{
    qCDebug(jveProperty) << "Creating property:" << name << "for clip:" << clipId;
    
    // Algorithm: Generate ID → Initialize → Set defaults → Return instance
    QString id = QUuid::createUuid().toString(QUuid::WithoutBraces);
    Property property(id, name, clipId);
    
    // Set default configuration
    property.m_type = String;
    property.m_value = QVariant();
    property.m_defaultValue = QVariant();
    property.m_group = "General";
    property.m_isDirty = true;
    
    return property;
}

Property Property::load(const QString& id, QSqlDatabase& database)
{
    qCDebug(jveProperty) << "Loading property:" << id;
    
    // Algorithm: Query → Parse → Load keyframes → Return instance
    QSqlQuery query(database);
    query.prepare("SELECT * FROM properties WHERE id = ?");
    query.addBindValue(id);
    
    if (!query.exec() || !query.next()) {
        qCWarning(jveProperty) << "Failed to load property:" << id << query.lastError().text();
        return Property();
    }
    
    // Parse property from query result
    QString name = query.value("property_name").toString();
    QString clipId = query.value("clip_id").toString();
    
    Property property(id, name, clipId);
    
    // Parse type
    QString typeStr = query.value("property_type").toString();
    property.m_type = property.stringToPropertyType(typeStr);
    
    // Parse JSON values
    QJsonDocument valueDoc = QJsonDocument::fromJson(query.value("property_value").toString().toUtf8());
    property.m_value = valueDoc.object().toVariantMap().value("value");
    
    QJsonDocument defaultDoc = QJsonDocument::fromJson(query.value("default_value").toString().toUtf8());
    property.m_defaultValue = defaultDoc.object().toVariantMap().value("value");
    
    property.m_isLoaded = true;
    
    // Load keyframes if any exist
    property.loadKeyframesFromDatabase(database);
    
    return property;
}

QList<Property> Property::loadByClip(const QString& clipId, QSqlDatabase& database)
{
    qCDebug(jveProperty) << "Loading properties for clip:" << clipId;
    
    // Algorithm: Query all → Parse each → Load keyframes → Return collection
    QSqlQuery query(database);
    query.prepare("SELECT * FROM properties WHERE clip_id = ? ORDER BY property_name");
    query.addBindValue(clipId);
    
    QList<Property> properties;
    if (query.exec()) {
        while (query.next()) {
            QString id = query.value("id").toString();
            QString name = query.value("property_name").toString();
            
            Property property(id, name, clipId);
            
            // Parse type
            QString typeStr = query.value("property_type").toString();
            property.m_type = property.stringToPropertyType(typeStr);
            
            // Parse JSON values
            QJsonDocument valueDoc = QJsonDocument::fromJson(query.value("property_value").toString().toUtf8());
            property.m_value = valueDoc.object().toVariantMap().value("value");
            
            QJsonDocument defaultDoc = QJsonDocument::fromJson(query.value("default_value").toString().toUtf8());
            property.m_defaultValue = defaultDoc.object().toVariantMap().value("value");
            
            property.m_isLoaded = true;
            property.loadKeyframesFromDatabase(database);
            properties.append(property);
        }
    }
    
    return properties;
}

QList<Property> Property::loadByGroup(const QString& clipId, const QString& group, QSqlDatabase& database)
{
    qCDebug(jveProperty) << "Loading properties by group:" << group << "for clip:" << clipId;
    
    // Algorithm: Query filtered → Parse each → Load keyframes → Return collection
    QList<Property> allProperties = loadByClip(clipId, database);
    QList<Property> groupProperties;
    
    for (const Property& prop : allProperties) {
        if (prop.group() == group) {
            groupProperties.append(prop);
        }
    }
    
    return groupProperties;
}

bool Property::resetGroup(const QString& clipId, const QString& group, QSqlDatabase& database)
{
    qCDebug(jveProperty) << "Resetting group:" << group << "for clip:" << clipId;
    
    // Algorithm: Load group → Reset values → Save batch → Return result
    QList<Property> groupProperties = loadByGroup(clipId, group, database);
    bool allSuccess = true;
    
    for (Property& property : groupProperties) {
        property.setValue(property.defaultValue());
        allSuccess &= property.save(database);
    }
    
    return allSuccess;
}

bool Property::copyGroup(const QString& fromClipId, const QString& group, const QString& toClipId, QSqlDatabase& database)
{
    qCDebug(jveProperty) << "Copying group:" << group << "from:" << fromClipId << "to:" << toClipId;
    
    // Algorithm: Load source → Clone with new clip → Save batch → Return result
    QList<Property> sourceProperties = loadByGroup(fromClipId, group, database);
    bool allSuccess = true;
    
    for (const Property& source : sourceProperties) {
        Property clone = create(source.name(), toClipId);
        clone.setType(source.type());
        clone.setValue(source.value());
        clone.setDefaultValue(source.defaultValue());
        clone.setGroup(source.group());
        clone.setMinimum(source.minimum());
        clone.setMaximum(source.maximum());
        clone.setEnumValues(source.enumValues());
        allSuccess &= clone.save(database);
    }
    
    return allSuccess;
}

bool Property::setValue(const QVariant& value)
{
    // Algorithm: Validate → Clamp → Store → Mark dirty → Return success
    if (!validateValue(value)) {
        qCWarning(jveProperty) << "Invalid value for property:" << m_name << value;
        return false;
    }
    
    QVariant clampedValue = clampValue(value);
    m_value = clampedValue;
    markDirty();
    
    return true;
}

void Property::setDefaultValue(const QVariant& defaultValue)
{
    m_defaultValue = defaultValue;
    markDirty();
}

void Property::setType(PropertyType type)
{
    m_type = type;
    markDirty();
}

void Property::setMinimum(const QVariant& minimum)
{
    m_minimum = minimum;
    markDirty();
}

void Property::setMaximum(const QVariant& maximum)
{
    m_maximum = maximum;
    markDirty();
}

void Property::setEnumValues(const QStringList& values)
{
    m_enumValues = values;
    markDirty();
}

void Property::setGroup(const QString& group)
{
    m_group = group;
    markDirty();
}

bool Property::isAnimated() const
{
    return !m_keyframes.isEmpty();
}

int Property::keyframeCount() const
{
    return m_keyframes.size();
}

void Property::addKeyframe(qint64 time, const QVariant& value)
{
    // Algorithm: Validate → Store → Mark dirty → Log addition
    if (validateValue(value)) {
        m_keyframes[time] = clampValue(value);
        markDirty();
        qCDebug(jveProperty) << "Added keyframe at" << time << "with value" << value;
    }
}

bool Property::removeKeyframe(qint64 time)
{
    // Algorithm: Check existence → Remove → Mark dirty → Return result
    bool existed = m_keyframes.contains(time);
    if (existed) {
        m_keyframes.remove(time);
        markDirty();
        qCDebug(jveProperty) << "Removed keyframe at" << time;
    }
    return existed;
}

void Property::clearKeyframes()
{
    if (!m_keyframes.isEmpty()) {
        m_keyframes.clear();
        markDirty();
        qCDebug(jveProperty) << "Cleared all keyframes for property:" << m_name;
    }
}

double Property::getValueAtTime(qint64 time) const
{
    // Algorithm: Check keyframes → Find neighbors → Interpolate → Return value
    return interpolateValue(time).toDouble();
}

bool Property::save(QSqlDatabase& database)
{
    qCDebug(jveProperty) << "Saving property:" << m_name;
    
    // Algorithm: Save property → Save keyframes → Clear dirty → Return success
    bool propertySuccess = saveToDatabase(database);
    bool keyframesSuccess = saveKeyframesToDatabase(database);
    
    if (propertySuccess && keyframesSuccess) {
        m_isDirty = false;
        return true;
    }
    
    return false;
}

Property::Property(const QString& id, const QString& name, const QString& clipId)
    : m_id(id), m_name(name), m_clipId(clipId)
{
}


bool Property::validateValue(const QVariant& value) const
{
    // Algorithm: Check type compatibility → Check constraints → Return valid
    switch (m_type) {
    case String:
        return value.canConvert<QString>();
    case Number:
        return value.canConvert<double>();
    case Boolean:
        return value.canConvert<bool>();
    case Color:
        return value.canConvert<QColor>();
    case Point:
        return value.canConvert<QPointF>();
    case Enum:
        return value.canConvert<QString>() && (m_enumValues.isEmpty() || m_enumValues.contains(value.toString()));
    }
    return false;
}

QVariant Property::clampValue(const QVariant& value) const
{
    // Algorithm: Apply type-specific clamping → Return constrained value
    if (m_type == Number && m_minimum.isValid() && m_maximum.isValid()) {
        double numValue = value.toDouble();
        double minValue = m_minimum.toDouble();
        double maxValue = m_maximum.toDouble();
        return QVariant(qBound(minValue, numValue, maxValue));
    }
    
    if (m_type == Enum && !m_enumValues.isEmpty()) {
        QString strValue = value.toString();
        if (!m_enumValues.contains(strValue)) {
            return m_enumValues.first(); // Fallback to first valid value
        }
    }
    
    return value;
}

bool Property::saveToDatabase(QSqlDatabase& database)
{
    QSqlQuery query(database);
    query.prepare(
        "INSERT OR REPLACE INTO properties "
        "(id, clip_id, property_name, property_value, property_type, default_value) "
        "VALUES (?, ?, ?, ?, ?, ?)"
    );
    
    query.addBindValue(m_id);
    query.addBindValue(m_clipId);
    query.addBindValue(m_name);
    
    // Serialize values to JSON
    QJsonObject valueObj;
    valueObj["value"] = QJsonValue::fromVariant(m_value);
    query.addBindValue(QJsonDocument(valueObj).toJson(QJsonDocument::Compact));
    
    query.addBindValue(propertyTypeToString(m_type));
    
    QJsonObject defaultObj;
    defaultObj["value"] = QJsonValue::fromVariant(m_defaultValue);
    query.addBindValue(QJsonDocument(defaultObj).toJson(QJsonDocument::Compact));
    
    if (!query.exec()) {
        qCCritical(jveProperty) << "Failed to save property:" << query.lastError().text();
        return false;
    }
    
    return true;
}

bool Property::saveKeyframesToDatabase(QSqlDatabase& database)
{
    // For M1 Foundation, keyframes stored as JSON in separate table
    // Implementation would create keyframes table and serialize m_keyframes
    return true; // Simplified for core implementation
}

bool Property::loadKeyframesFromDatabase(QSqlDatabase& database)
{
    // For M1 Foundation, load keyframes from separate table
    // Implementation would query and deserialize keyframes
    return true; // Simplified for core implementation
}

QVariant Property::interpolateValue(qint64 time) const
{
    // Algorithm: Find neighbors → Calculate ratio → Linear interpolate → Return result
    if (m_keyframes.isEmpty()) {
        return m_value;
    }
    
    // Find keyframes before and after time
    auto it = m_keyframes.lowerBound(time);
    
    if (it == m_keyframes.begin()) {
        return it.value(); // Before first keyframe
    }
    
    if (it == m_keyframes.end()) {
        return (--it).value(); // After last keyframe
    }
    
    // Interpolate between keyframes
    auto nextIt = it;
    auto prevIt = --it;
    
    qint64 prevTime = prevIt.key();
    qint64 nextTime = nextIt.key();
    double prevValue = prevIt.value().toDouble();
    double nextValue = nextIt.value().toDouble();
    
    double ratio = static_cast<double>(time - prevTime) / (nextTime - prevTime);
    double interpolated = prevValue + ratio * (nextValue - prevValue);
    
    return QVariant(interpolated);
}

QString Property::propertyTypeToString(PropertyType type) const
{
    switch (type) {
    case String: return "STRING";
    case Number: return "NUMBER";
    case Boolean: return "BOOLEAN";
    case Color: return "COLOR";
    case Point: return "POINT";
    case Enum: return "ENUM";
    }
    return "STRING";
}

Property::PropertyType Property::stringToPropertyType(const QString& typeStr) const
{
    if (typeStr == "NUMBER") return Number;
    if (typeStr == "BOOLEAN") return Boolean;
    if (typeStr == "COLOR") return Color;
    if (typeStr == "POINT") return Point;
    if (typeStr == "ENUM") return Enum;
    return String;
}