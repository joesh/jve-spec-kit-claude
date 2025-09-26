#pragma once

#include <QString>
#include <QDateTime>
#include <QSqlDatabase>
#include <QVariant>
#include <QVariantMap>

// Forward declarations
class Media;

/**
 * Clip entity - media references within tracks
 * Core entity following Rule 2.27: Single responsibility - clip data only
 */
class Clip
{
public:
    Clip() = default;
    ~Clip() = default;
    
    // Copy and move constructors
    Clip(const Clip& other) = default;
    Clip& operator=(const Clip& other) = default;
    Clip(Clip&& other) noexcept = default;
    Clip& operator=(Clip&& other) noexcept = default;
    
    /**
     * Create new clip with media reference
     * Algorithm: Generate UUID → Associate media → Initialize timeline position
     */
    static Clip create(const QString& name, const QString& mediaId);
    
    /**
     * Load clip from database by ID
     * Algorithm: Query database → Parse results → Construct object
     */
    static Clip load(const QString& id, const QSqlDatabase& database);
    
    /**
     * Save clip to database
     * Algorithm: Validate data → Execute insert/update → Update timestamps
     */
    bool save(const QSqlDatabase& database);
    
    // Core properties
    QString id() const { return m_id; }
    QString name() const { return m_name; }
    void setName(const QString& name);
    
    QString mediaId() const { return m_mediaId; }
    QDateTime createdAt() const { return m_createdAt; }
    QDateTime modifiedAt() const { return m_modifiedAt; }
    
    // Media relationship
    Media getMedia(const QSqlDatabase& database) const;
    
    // Timeline positioning
    qint64 timelineStart() const { return m_timelineStart; }
    qint64 timelineEnd() const { return m_timelineEnd; }
    qint64 duration() const { return m_timelineEnd - m_timelineStart; }
    void setTimelinePosition(qint64 start, qint64 end);
    
    // Source timing (which part of media to use)
    qint64 sourceStart() const { return m_sourceStart; }
    qint64 sourceEnd() const { return m_sourceEnd; }
    qint64 sourceDuration() const { return m_sourceEnd - m_sourceStart; }
    void setSourceRange(qint64 start, qint64 end);
    
    // Transformations
    double x() const { return m_x; }
    double y() const { return m_y; }
    void setPosition(double x, double y);
    
    double scaleX() const { return m_scaleX; }
    double scaleY() const { return m_scaleY; }
    void setScale(double scaleX, double scaleY);
    
    double rotation() const { return m_rotation; }
    void setRotation(double rotation);
    
    double opacity() const { return m_opacity; }
    void setOpacity(double opacity);
    
    // Trimming operations
    void trimStart(qint64 offset);  // Positive = trim from start, negative = extend
    void trimEnd(qint64 offset);    // Positive = extend end, negative = trim from end
    
    // Property management
    void setProperty(const QString& key, const QVariant& value);
    QVariant getProperty(const QString& key, const QVariant& defaultValue = QVariant()) const;
    bool hasProperty(const QString& key) const;
    void removeProperty(const QString& key);
    QStringList propertyKeys() const;
    
    // Validation and state
    bool isValid() const { return !m_id.isEmpty() && !m_name.isEmpty() && !m_mediaId.isEmpty(); }

private:
    QString m_id;
    QString m_name;
    QString m_mediaId;
    QDateTime m_createdAt;
    QDateTime m_modifiedAt;
    
    // Timeline positioning
    qint64 m_timelineStart = 0;
    qint64 m_timelineEnd = 0;
    
    // Source range (which part of media to use)
    qint64 m_sourceStart = 0;
    qint64 m_sourceEnd = 0;
    
    // Transformations
    double m_x = 0.0;
    double m_y = 0.0;
    double m_scaleX = 1.0;
    double m_scaleY = 1.0;
    double m_rotation = 0.0;
    double m_opacity = 1.0;
    
    // Properties cache
    mutable QVariantMap m_properties;
    mutable bool m_propertiesLoaded = false;
    
    // Helper functions for algorithmic breakdown (Rule 2.26)
    void updateModifiedTime();
    void validateTimelinePosition();
    void validateSourceRange();
    void validateTransformations();
    void loadProperties(const QSqlDatabase& database) const;
    void saveProperties(const QSqlDatabase& database) const;
};