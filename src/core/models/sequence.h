#pragma once

#include <QString>
#include <QDateTime>
#include <QSqlDatabase>
#include <QList>

// Forward declarations
class Track;

/**
 * Sequence entity - timeline container with tracks/clips
 * Core entity following Rule 2.27: Single responsibility - sequence data only
 */
class Sequence
{
public:
    Sequence() = default;
    ~Sequence() = default;
    
    // Copy and move constructors
    Sequence(const Sequence& other) = default;
    Sequence& operator=(const Sequence& other) = default;
    Sequence(Sequence&& other) noexcept = default;
    Sequence& operator=(Sequence&& other) noexcept = default;
    
    /**
     * Create new sequence with generated ID
     * Algorithm: Generate UUID → Set defaults → Associate with project
     */
    static Sequence create(const QString& name, const QString& projectId);
    
    /**
     * Load sequence from database by ID
     * Algorithm: Query database → Parse results → Construct object
     */
    static Sequence load(const QString& id, const QSqlDatabase& database);
    
    /**
     * Load all sequences for a project
     * Algorithm: Query by project → Parse results → Return list
     */
    static QList<Sequence> loadByProject(const QString& projectId, const QSqlDatabase& database);
    
    /**
     * Save sequence to database
     * Algorithm: Validate data → Execute insert/update → Update timestamps
     */
    bool save(const QSqlDatabase& database);
    
    // Core properties
    QString id() const { return m_id; }
    QString name() const { return m_name; }
    void setName(const QString& name);
    
    QString projectId() const { return m_projectId; }
    
    QDateTime createdAt() const { return m_createdAt; }
    QDateTime modifiedAt() const { return m_modifiedAt; }
    
    // Timeline properties
    double framerate() const { return m_framerate; }
    void setFramerate(double framerate);
    
    int width() const { return m_width; }
    int height() const { return m_height; }
    void setResolution(int width, int height);
    
    qint64 duration() const { return m_duration; } // Duration in milliseconds
    void setDuration(qint64 duration);
    
    // Description/metadata
    QString description() const { return m_description; }
    void setDescription(const QString& description);
    
    // Derived properties
    double aspectRatio() const;
    bool isDropFrame() const;
    qint64 durationInFrames() const;
    
    // Frame/time conversion utilities
    qint64 framesToMilliseconds(qint64 frames) const;
    qint64 millisecondsToFrames(qint64 milliseconds) const;
    QString formatTimecode(qint64 milliseconds) const;
    
    // Track management
    int trackCount() const;
    int videoTrackCount() const;
    int audioTrackCount() const;
    void addVideoTrack(const QString& name);
    void addAudioTrack(const QString& name);
    
    // Validation and state
    bool isValid() const { return !m_id.isEmpty() && !m_name.isEmpty() && !m_projectId.isEmpty(); }

private:
    QString m_id;
    QString m_name;
    QString m_projectId;
    QDateTime m_createdAt;
    QDateTime m_modifiedAt;
    QString m_description;
    
    // Timeline properties
    double m_framerate = 29.97; // Default NTSC
    int m_width = 1920;         // Default HD
    int m_height = 1080;
    qint64 m_duration = 0;      // Milliseconds
    
    // Track counts (cached for performance)
    mutable int m_cachedTrackCount = -1;
    mutable int m_cachedVideoTrackCount = -1;
    mutable int m_cachedAudioTrackCount = -1;
    
    // Helper functions for algorithmic breakdown (Rule 2.26)
    void updateModifiedTime();
    void validateFramerate();
    void validateResolution();
    void invalidateTrackCache();
    int queryTrackCount(const QSqlDatabase& database, const QString& trackType = QString()) const;
};