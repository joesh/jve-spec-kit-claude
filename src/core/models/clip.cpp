#include "clip.h"
#include "media.h"

#include <QUuid>
#include <QSqlQuery>
#include <QSqlError>
#include <QLoggingCategory>

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
        SELECT id, name, media_id, created_at, modified_at,
               timeline_start, timeline_end, source_start, source_end,
               position_x, position_y, scale_x, scale_y, rotation, opacity
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
    clip.m_name = query.value("name").toString();
    clip.m_mediaId = query.value("media_id").toString();
    clip.m_createdAt = QDateTime::fromSecsSinceEpoch(query.value("created_at").toLongLong());
    clip.m_modifiedAt = QDateTime::fromSecsSinceEpoch(query.value("modified_at").toLongLong());
    clip.m_timelineStart = query.value("timeline_start").toLongLong();
    clip.m_timelineEnd = query.value("timeline_end").toLongLong();
    clip.m_sourceStart = query.value("source_start").toLongLong();
    clip.m_sourceEnd = query.value("source_end").toLongLong();
    clip.m_x = query.value("position_x").toDouble();
    clip.m_y = query.value("position_y").toDouble();
    clip.m_scaleX = query.value("scale_x").toDouble();
    clip.m_scaleY = query.value("scale_y").toDouble();
    clip.m_rotation = query.value("rotation").toDouble();
    clip.m_opacity = query.value("opacity").toDouble();
    
    clip.validateTimelinePosition();
    clip.validateSourceRange();
    clip.validateTransformations();
    
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
    
    updateModifiedTime();
    
    QSqlQuery query(database);
    query.prepare(R"(
        INSERT OR REPLACE INTO clips 
        (id, name, media_id, created_at, modified_at,
         timeline_start, timeline_end, source_start, source_end,
         position_x, position_y, scale_x, scale_y, rotation, opacity)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    )");
    
    query.addBindValue(m_id);
    query.addBindValue(m_name);
    query.addBindValue(m_mediaId);
    query.addBindValue(m_createdAt.toSecsSinceEpoch());
    query.addBindValue(m_modifiedAt.toSecsSinceEpoch());
    query.addBindValue(m_timelineStart);
    query.addBindValue(m_timelineEnd);
    query.addBindValue(m_sourceStart);
    query.addBindValue(m_sourceEnd);
    query.addBindValue(m_x);
    query.addBindValue(m_y);
    query.addBindValue(m_scaleX);
    query.addBindValue(m_scaleY);
    query.addBindValue(m_rotation);
    query.addBindValue(m_opacity);
    
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
    // This would load properties from the properties table
    // For now, just mark as loaded
    m_propertiesLoaded = true;
    
    QSqlQuery query(database);
    query.prepare("SELECT name, value FROM properties WHERE clip_id = ?");
    query.addBindValue(m_id);
    
    if (query.exec()) {
        while (query.next()) {
            QString name = query.value("name").toString();
            QVariant value = query.value("value");
            m_properties[name] = value;
        }
    }
}

void Clip::saveProperties(const QSqlDatabase& database) const
{
    // This would save properties to the properties table
    // For now, just a placeholder
    
    // First, delete existing properties for this clip
    QSqlQuery deleteQuery(database);
    deleteQuery.prepare("DELETE FROM properties WHERE clip_id = ?");
    deleteQuery.addBindValue(m_id);
    deleteQuery.exec();
    
    // Then insert current properties
    QSqlQuery insertQuery(database);
    insertQuery.prepare("INSERT INTO properties (clip_id, name, value) VALUES (?, ?, ?)");
    
    for (auto it = m_properties.begin(); it != m_properties.end(); ++it) {
        insertQuery.addBindValue(m_id);
        insertQuery.addBindValue(it.key());
        insertQuery.addBindValue(it.value());
        insertQuery.exec();
    }
}