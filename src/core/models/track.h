#pragma once

#include <QString>
#include <QDateTime>
#include <QSqlDatabase>
#include <QList>
#include <QtMath>

// Forward declarations
class Clip;

/**
 * Render state for track rendering
 */
struct RenderState
{
    bool isVisible = true;
    double opacity = 1.0;
    double volume = 1.0;
    bool isMuted = false;
};

/**
 * Track entity - video/audio track containers within sequences
 * Core entity following Rule 2.27: Single responsibility - track data only
 */
class Track
{
public:
    enum Type {
        Video,
        Audio
    };
    
    enum BlendMode {
        None,
        Normal,
        Multiply,
        Screen,
        Overlay,
        SoftLight,
        HardLight
    };
    
    Track() = default;
    ~Track() = default;
    
    // Copy and move constructors
    Track(const Track& other) = default;
    Track& operator=(const Track& other) = default;
    Track(Track&& other) noexcept = default;
    Track& operator=(Track&& other) noexcept = default;
    
    /**
     * Create new video track
     * Algorithm: Generate UUID → Set video defaults → Associate with sequence
     */
    static Track createVideo(const QString& name, const QString& sequenceId);
    
    /**
     * Create new audio track
     * Algorithm: Generate UUID → Set audio defaults → Associate with sequence
     */
    static Track createAudio(const QString& name, const QString& sequenceId);
    
    /**
     * Load track from database by ID
     * Algorithm: Query database → Parse results → Construct object
     */
    static Track load(const QString& id, const QSqlDatabase& database);
    
    /**
     * Load all tracks for a sequence
     * Algorithm: Query by sequence → Parse results → Return ordered list
     */
    static QList<Track> loadBySequence(const QString& sequenceId, const QSqlDatabase& database);
    
    /**
     * Save track to database
     * Algorithm: Validate data → Execute insert/update → Update timestamps
     */
    bool save(const QSqlDatabase& database);
    
    // Core properties
    QString id() const { return m_id; }
    QString name() const { return m_name; }
    void setName(const QString& name);
    
    QString sequenceId() const { return m_sequenceId; }
    Type type() const { return m_type; }
    
    QDateTime createdAt() const { return m_createdAt; }
    QDateTime modifiedAt() const { return m_modifiedAt; }
    
    QString description() const { return m_description; }
    void setDescription(const QString& description);
    
    // Track management
    int layerIndex() const { return m_layerIndex; }
    void setLayerIndex(int index);
    void moveToLayer(int layer) { setLayerIndex(layer); }
    void moveUp() { setLayerIndex(m_layerIndex + 1); }
    void moveDown() { setLayerIndex(qMax(0, m_layerIndex - 1)); }
    
    // Track state
    bool isEnabled() const { return m_enabled; }
    void setEnabled(bool enabled);
    
    bool isMuted() const { return m_muted; }
    void setMuted(bool muted);
    
    bool isSoloed() const { return m_soloed; }
    void setSoloed(bool soloed);
    
    bool isLocked() const { return m_locked; }
    void setLocked(bool locked);
    
    // Video-specific properties
    double opacity() const { return m_type == Video ? m_opacity : qQNaN(); }
    void setOpacity(double opacity);
    
    BlendMode blendMode() const { return m_type == Video ? m_blendMode : None; }
    void setBlendMode(BlendMode mode);
    
    // Audio-specific properties
    double volume() const { return m_type == Audio ? m_volume : qQNaN(); }
    void setVolume(double volume);
    
    double pan() const { return m_type == Audio ? m_pan : qQNaN(); }
    void setPan(double pan);
    
    // Type-specific capabilities
    bool supportsOpacity() const { return m_type == Video; }
    bool supportsVolume() const { return m_type == Audio; }
    bool acceptsVideoClips() const { return m_type == Video; }
    bool acceptsAudioClips() const { return m_type == Audio; }
    
    // Derived state
    bool isEffectivelyMuted() const { return m_muted || (!m_enabled); }
    bool acceptsEditing() const { return !m_locked; }
    
    // Clip management
    int clipCount() const;
    qint64 duration() const;
    bool isEmpty() const { return clipCount() == 0; }
    
    void addClip(const Clip& clip);
    bool hasOverlappingClips(const Clip& clip) const;
    void insertClipAt(const Clip& clip, qint64 position);
    QList<Clip> getClipsAtTime(qint64 time) const;
    
    void trimToContent();
    void padToLength(qint64 length);
    void trimToLength(qint64 length);
    
    // Rendering
    bool isRenderableAtTime(double time) const;
    RenderState getRenderState(double time) const;
    
    // Validation and state
    bool isValid() const { return !m_id.isEmpty() && !m_name.isEmpty() && !m_sequenceId.isEmpty(); }

private:
    QString m_id;
    QString m_name;
    QString m_sequenceId;
    Type m_type;
    QDateTime m_createdAt;
    QDateTime m_modifiedAt;
    QString m_description;
    
    // Track organization
    int m_layerIndex = 0;
    
    // Track state
    bool m_enabled = true;
    bool m_muted = false;
    bool m_soloed = false;
    bool m_locked = false;
    
    // Video properties
    double m_opacity = 1.0;
    BlendMode m_blendMode = Normal;
    
    // Audio properties  
    double m_volume = 1.0;
    double m_pan = 0.0; // -1.0 = left, 0.0 = center, 1.0 = right
    
    // Cached clip information
    mutable int m_cachedClipCount = -1;
    mutable qint64 m_cachedDuration = -1;
    
    // Helper functions for algorithmic breakdown (Rule 2.26)
    void updateModifiedTime();
    void validateVideoProperties();
    void validateAudioProperties();
    void invalidateClipCache();
    void initializeDefaults();
};