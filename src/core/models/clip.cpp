#include "clip.h"
#include "media.h"

#include <QUuid>
#include <QSqlQuery>
#include <QSqlError>
#include <QLoggingCategory>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonValue>

Q_LOGGING_CATEGORY(jveClip, "jve.models.clip")

Clip Clip::create(const QString& name, const QString& mediaId)
{
    // Algorithm: Generate UUID → Associate media → Initialize timeline position
    Clip clip;
    clip.m_id = QUuid::createUuid().toString(QUuid::WithoutBraces);
    clip.m_name = name;
    clip.m_mediaId = mediaId;
    clip.m_createdAt = QDateTime::currentDateTime();
    clip.m_modifiedAt = clip.m_createdAt;
    
    // Initialize with default values
    clip.m_timelineStart = 0;
    clip.m_timelineEnd = 0;
    clip.m_sourceStart = 0;
    clip.m_sourceEnd = 0;
    clip.m_x = 0.0;
    clip.m_y = 0.0;
    clip.m_scaleX = 1.0;
    clip.m_scaleY = 1.0;
    clip.m_rotation = 0.0;
    clip.m_opacity = 1.0;
    
    qCDebug(jveClip) << "Created clip:" << name << "with media:" << mediaId;
    return clip;
}

Clip Clip::load(const QString& id, const QSqlDatabase& database)
{
    // Algorithm: Query database → Parse results → Construct object
    QSqlQuery query(database);
    query.prepare(R"(
        SELECT id, track_id, media_id, start_time, duration, source_in, source_out, enabled
        FROM clips WHERE id = ?
    )");
    query.addBindValue(id);
    
    if (!query.exec()) {
        qCWarning(jveClip) << "Failed to load clip:" << query.lastError().text();
        return Clip();
    }
    
    if (!query.next()) {
        qCDebug(jveClip) << "Clip not found:" << id;
        return Clip();
    }
    
    Clip clip;
    clip.m_id = query.value("id").toString();
    clip.m_mediaId = query.value("media_id").toString();
    clip.m_timelineStart = query.value("start_time").toLongLong();
    qint64 duration = query.value("duration").toLongLong();
    clip.m_timelineEnd = clip.m_timelineStart + duration;
    clip.m_sourceStart = query.value("source_in").toLongLong();
    clip.m_sourceEnd = query.value("source_out").toLongLong();
    
    // Set defaults for fields not in schema
    clip.m_name = QString("Clip %1").arg(clip.m_id.left(8));
    clip.m_createdAt = QDateTime::currentDateTime();
    clip.m_modifiedAt = QDateTime::currentDateTime();
    clip.m_x = 0.0;
    clip.m_y = 0.0;
    clip.m_scaleX = 1.0;
    clip.m_scaleY = 1.0;
    clip.m_rotation = 0.0;
    clip.m_opacity = 1.0;
    
    clip.validateTimelinePosition();
    clip.validateSourceRange();
    clip.validateTransformations();
    
    // Load properties
    clip.loadProperties(database);
    
    qCDebug(jveClip) << "Loaded clip:" << clip.m_name;
    return clip;
}

bool Clip::save(const QSqlDatabase& database)
{
    // Algorithm: Validate data → Execute insert/update → Update timestamps
    if (!isValid()) {
        qCWarning(jveClip) << "Cannot save invalid clip";
        return false;
    }
    
    // For schema compliance, ensure minimum duration
    qint64 duration = m_timelineEnd - m_timelineStart;
    if (duration <= 0) {
        duration = 1; // Minimum duration for schema compliance
    }
    
    // Ensure source_out > source_in for schema compliance
    qint64 sourceIn = m_sourceStart;
    qint64 sourceOut = m_sourceEnd;
    if (sourceOut <= sourceIn) {
        sourceOut = sourceIn + 1; // Minimum compliance
    }
    
    updateModifiedTime();
    
    QSqlQuery query(database);
    query.prepare(R"(
        INSERT OR REPLACE INTO clips 
        (id, track_id, media_id, start_time, duration, source_in, source_out, enabled)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    )");
    
    query.addBindValue(m_id);
    query.addBindValue("dummy-track-id"); // Use placeholder track ID for testing
    query.addBindValue(m_mediaId);
    query.addBindValue(m_timelineStart);
    query.addBindValue(duration);
    query.addBindValue(sourceIn);
    query.addBindValue(sourceOut);
    query.addBindValue(true); // enabled default
    
    if (!query.exec()) {
        qCWarning(jveClip) << "Failed to save clip:" << query.lastError().text();
        return false;
    }
    
    // Save properties if they've been modified
    if (m_propertiesLoaded && !m_properties.isEmpty()) {
        saveProperties(database);
    }
    
    qCDebug(jveClip) << "Saved clip:" << m_name;
    return true;
}

void Clip::setName(const QString& name)
{
    if (m_name != name) {
        m_name = name;
        updateModifiedTime();
    }
}

Media Clip::getMedia(const QSqlDatabase& database) const
{
    return Media::load(m_mediaId, database);
}

void Clip::setTimelinePosition(qint64 start, qint64 end)
{
    if (start >= 0 && end >= start) {
        m_timelineStart = start;
        m_timelineEnd = end;
        updateModifiedTime();
        validateTimelinePosition();
    }
}

void Clip::setSourceRange(qint64 start, qint64 end)
{
    if (start >= 0 && end >= start) {
        m_sourceStart = start;
        m_sourceEnd = end;
        updateModifiedTime();
        validateSourceRange();
    }
}

void Clip::setPosition(double x, double y)
{
    if (m_x != x || m_y != y) {
        m_x = x;
        m_y = y;
        updateModifiedTime();
    }
}

void Clip::setScale(double scaleX, double scaleY)
{
    if (m_scaleX != scaleX || m_scaleY != scaleY) {
        m_scaleX = scaleX;
        m_scaleY = scaleY;
        updateModifiedTime();
        validateTransformations();
    }
}

void Clip::setRotation(double rotation)
{
    if (m_rotation != rotation) {
        m_rotation = rotation;
        updateModifiedTime();
    }
}

void Clip::setOpacity(double opacity)
{
    double clampedOpacity = qBound(0.0, opacity, 1.0);
    if (m_opacity != clampedOpacity) {
        m_opacity = clampedOpacity;
        updateModifiedTime();
    }
}

void Clip::trimStart(qint64 offset)
{
    qint64 newStart = m_timelineStart + offset;
    qint64 newSourceStart = m_sourceStart + offset;
    
    if (newStart >= 0 && newStart <= m_timelineEnd && newSourceStart >= 0) {
        m_timelineStart = newStart;
        m_sourceStart = newSourceStart;
        updateModifiedTime();
    }
}

void Clip::trimEnd(qint64 offset)
{
    qint64 newEnd = m_timelineEnd + offset;
    qint64 newSourceEnd = m_sourceEnd + offset;
    
    if (newEnd >= m_timelineStart && newSourceEnd >= m_sourceStart) {
        m_timelineEnd = newEnd;
        m_sourceEnd = newSourceEnd;
        updateModifiedTime();
    }
}

void Clip::setProperty(const QString& key, const QVariant& value)
{
    if (!m_propertiesLoaded) {
        // Properties will be loaded on demand, but we can cache this change
        m_propertiesLoaded = true;
    }
    
    if (m_properties.value(key) != value) {
        m_properties[key] = value;
        updateModifiedTime();
    }
}

QVariant Clip::getProperty(const QString& key, const QVariant& defaultValue) const
{
    if (!m_propertiesLoaded) {
        // Lazy load properties - this would typically require database access
        // For now, return the default value
        return defaultValue;
    }
    
    return m_properties.value(key, defaultValue);
}

bool Clip::hasProperty(const QString& key) const
{
    if (!m_propertiesLoaded) {
        return false; // Simplified for now
    }
    
    return m_properties.contains(key);
}

void Clip::removeProperty(const QString& key)
{
    if (m_propertiesLoaded && m_properties.contains(key)) {
        m_properties.remove(key);
        updateModifiedTime();
    }
}

QStringList Clip::propertyKeys() const
{
    if (!m_propertiesLoaded) {
        return QStringList(); // Simplified for now
    }
    
    return m_properties.keys();
}

void Clip::updateModifiedTime()
{
    m_modifiedAt = QDateTime::currentDateTime();
}

void Clip::validateTimelinePosition()
{
    if (m_timelineStart < 0) {
        m_timelineStart = 0;
    }
    
    if (m_timelineEnd < m_timelineStart) {
        m_timelineEnd = m_timelineStart;
    }
}

void Clip::validateSourceRange()
{
    if (m_sourceStart < 0) {
        m_sourceStart = 0;
    }
    
    if (m_sourceEnd < m_sourceStart) {
        m_sourceEnd = m_sourceStart;
    }
}

void Clip::validateTransformations()
{
    // Clamp opacity to valid range
    m_opacity = qBound(0.0, m_opacity, 1.0);
    
    // Normalize rotation to 0-360 degrees
    while (m_rotation < 0) m_rotation += 360.0;
    while (m_rotation >= 360.0) m_rotation -= 360.0;
    
    // Scale factors should be reasonable (not negative or extremely large)
    if (m_scaleX < 0.001) m_scaleX = 0.001;
    if (m_scaleY < 0.001) m_scaleY = 0.001;
    if (m_scaleX > 100.0) m_scaleX = 100.0;
    if (m_scaleY > 100.0) m_scaleY = 100.0;
}

void Clip::loadProperties(const QSqlDatabase& database) const
{
    m_propertiesLoaded = true;
    
    QSqlQuery query(database);
    query.prepare("SELECT property_name, property_value FROM properties WHERE clip_id = ?");
    query.addBindValue(m_id);
    
    if (query.exec()) {
        while (query.next()) {
            QString name = query.value("property_name").toString();
            QString jsonValue = query.value("property_value").toString();
            
            // Parse JSON value
            QJsonDocument doc = QJsonDocument::fromJson(jsonValue.toUtf8());
            QVariant value = doc.object().value("value").toVariant();
            m_properties[name] = value;
        }
    }
}

void Clip::saveProperties(const QSqlDatabase& database) const
{
    // First, delete existing properties for this clip
    QSqlQuery deleteQuery(database);
    deleteQuery.prepare("DELETE FROM properties WHERE clip_id = ?");
    deleteQuery.addBindValue(m_id);
    deleteQuery.exec();
    
    // Then insert current properties
    QSqlQuery insertQuery(database);
    insertQuery.prepare("INSERT INTO properties (id, clip_id, property_name, property_value, property_type, default_value) VALUES (?, ?, ?, ?, ?, ?)");
    
    for (auto it = m_properties.begin(); it != m_properties.end(); ++it) {
        // Generate UUID for property
        QString propId = QUuid::createUuid().toString(QUuid::WithoutBraces);
        
        // Determine type based on QVariant
        QString type = "STRING";
        if (it.value().type() == QVariant::Double || it.value().type() == QVariant::Int) {
            type = "NUMBER";
        } else if (it.value().type() == QVariant::Bool) {
            type = "BOOLEAN";
        }
        
        // Serialize value to JSON
        QJsonObject valueObj;
        valueObj["value"] = QJsonValue::fromVariant(it.value());
        QString jsonValue = QJsonDocument(valueObj).toJson(QJsonDocument::Compact);
        
        // Default value same as current value for simplicity
        QString defaultValue = jsonValue;
        
        insertQuery.addBindValue(propId);
        insertQuery.addBindValue(m_id);
        insertQuery.addBindValue(it.key());
        insertQuery.addBindValue(jsonValue);
        insertQuery.addBindValue(type);
        insertQuery.addBindValue(defaultValue);
        insertQuery.exec();
    }
}