#include "track.h"
#include "clip.h"

#include <QUuid>
#include <QSqlQuery>
#include <QSqlError>
#include <QLoggingCategory>

Q_LOGGING_CATEGORY(jveTrack, "jve.models.track")

Track Track::createVideo(const QString& name, const QString& sequenceId)
{
    // Algorithm: Generate UUID → Set video defaults → Associate with sequence
    Track track;
    track.m_id = QUuid::createUuid().toString(QUuid::WithoutBraces);
    track.m_name = name;
    track.m_sequenceId = sequenceId;
    track.m_type = Video;
    track.m_createdAt = QDateTime::currentDateTime();
    track.m_modifiedAt = track.m_createdAt;
    track.initializeDefaults();
    
    qCDebug(jveTrack) << "Created video track:" << name << "for sequence:" << sequenceId;
    return track;
}

Track Track::createAudio(const QString& name, const QString& sequenceId)
{
    // Algorithm: Generate UUID → Set audio defaults → Associate with sequence
    Track track;
    track.m_id = QUuid::createUuid().toString(QUuid::WithoutBraces);
    track.m_name = name;
    track.m_sequenceId = sequenceId;
    track.m_type = Audio;
    track.m_createdAt = QDateTime::currentDateTime();
    track.m_modifiedAt = track.m_createdAt;
    track.initializeDefaults();
    
    qCDebug(jveTrack) << "Created audio track:" << name << "for sequence:" << sequenceId;
    return track;
}

Track Track::load(const QString& id, const QSqlDatabase& database)
{
    // Algorithm: Query database → Parse results → Construct object
    QSqlQuery query(database);
    query.prepare(R"(
        SELECT id, sequence_id, track_type, track_index, enabled, locked
        FROM tracks WHERE id = ?
    )");
    query.addBindValue(id);
    
    if (!query.exec()) {
        qCWarning(jveTrack) << "Failed to load track:" << query.lastError().text();
        return Track();
    }
    
    if (!query.next()) {
        qCDebug(jveTrack) << "Track not found:" << id;
        return Track();
    }
    
    Track track;
    track.m_id = query.value("id").toString();
    track.m_sequenceId = query.value("sequence_id").toString();
    track.m_type = query.value("track_type").toString() == "VIDEO" ? Video : Audio;
    track.m_layerIndex = query.value("track_index").toInt();
    track.m_enabled = query.value("enabled").toBool();
    track.m_locked = query.value("locked").toBool();
    
    // Set reasonable defaults for fields not in schema
    track.m_name = QString("Track %1").arg(track.m_layerIndex);
    track.m_createdAt = QDateTime::currentDateTime();
    track.m_modifiedAt = QDateTime::currentDateTime();
    
    track.validateVideoProperties();
    track.validateAudioProperties();
    
    qCDebug(jveTrack) << "Loaded track:" << track.m_name;
    return track;
}

QList<Track> Track::loadBySequence(const QString& sequenceId, const QSqlDatabase& database)
{
    // Algorithm: Query by sequence → Parse results → Return ordered list
    QList<Track> tracks;
    
    QSqlQuery query(database);
    query.prepare(R"(
        SELECT id FROM tracks 
        WHERE sequence_id = ? 
        ORDER BY track_index ASC
    )");
    query.addBindValue(sequenceId);
    
    if (!query.exec()) {
        qCWarning(jveTrack) << "Failed to load tracks for sequence:" << query.lastError().text();
        return tracks;
    }
    
    while (query.next()) {
        QString trackId = query.value("id").toString();
        Track track = load(trackId, database);
        if (track.isValid()) {
            tracks.append(track);
        }
    }
    
    qCDebug(jveTrack) << "Loaded" << tracks.size() << "tracks for sequence:" << sequenceId;
    return tracks;
}

bool Track::save(const QSqlDatabase& database)
{
    // Algorithm: Validate data → Execute insert/update → Update timestamps
    if (!isValid()) {
        qCWarning(jveTrack) << "Cannot save invalid track";
        return false;
    }
    
    updateModifiedTime();
    
    QSqlQuery query(database);
    query.prepare(R"(
        INSERT OR REPLACE INTO tracks 
        (id, sequence_id, track_type, track_index, enabled, locked)
        VALUES (?, ?, ?, ?, ?, ?)
    )");
    
    query.addBindValue(m_id);
    query.addBindValue(m_sequenceId);
    query.addBindValue(m_type == Video ? "VIDEO" : "AUDIO");
    query.addBindValue(1); // track_index default to 1
    query.addBindValue(m_enabled);
    query.addBindValue(m_locked);
    
    if (!query.exec()) {
        qCWarning(jveTrack) << "Failed to save track:" << query.lastError().text();
        return false;
    }
    
    qCDebug(jveTrack) << "Saved track:" << m_name;
    return true;
}

void Track::setName(const QString& name)
{
    if (m_name != name) {
        m_name = name;
        updateModifiedTime();
    }
}

void Track::setDescription(const QString& description)
{
    if (m_description != description) {
        m_description = description;
        updateModifiedTime();
    }
}

void Track::setLayerIndex(int index)
{
    if (index >= 0 && m_layerIndex != index) {
        m_layerIndex = index;
        updateModifiedTime();
    }
}

void Track::setEnabled(bool enabled)
{
    if (m_enabled != enabled) {
        m_enabled = enabled;
        updateModifiedTime();
    }
}

void Track::setMuted(bool muted)
{
    if (m_muted != muted) {
        m_muted = muted;
        updateModifiedTime();
    }
}

void Track::setSoloed(bool soloed)
{
    if (m_soloed != soloed) {
        m_soloed = soloed;
        updateModifiedTime();
    }
}

void Track::setLocked(bool locked)
{
    if (m_locked != locked) {
        m_locked = locked;
        updateModifiedTime();
    }
}

void Track::setOpacity(double opacity)
{
    if (m_type == Video) {
        double clampedOpacity = qBound(0.0, opacity, 1.0);
        if (m_opacity != clampedOpacity) {
            m_opacity = clampedOpacity;
            updateModifiedTime();
        }
    }
}

void Track::setBlendMode(BlendMode mode)
{
    if (m_type == Video && m_blendMode != mode) {
        m_blendMode = mode;
        updateModifiedTime();
    }
}

void Track::setVolume(double volume)
{
    if (m_type == Audio) {
        double clampedVolume = qMax(0.0, volume); // Allow boost > 1.0
        if (m_volume != clampedVolume) {
            m_volume = clampedVolume;
            updateModifiedTime();
        }
    }
}

void Track::setPan(double pan)
{
    if (m_type == Audio) {
        double clampedPan = qBound(-1.0, pan, 1.0);
        if (m_pan != clampedPan) {
            m_pan = clampedPan;
            updateModifiedTime();
        }
    }
}

int Track::clipCount() const
{
    // Placeholder - would query database for clips in this track
    return m_cachedClipCount >= 0 ? m_cachedClipCount : 0;
}

qint64 Track::duration() const
{
    // Placeholder - would calculate from clips in this track
    return m_cachedDuration >= 0 ? m_cachedDuration : 0;
}

void Track::addClip(const Clip& clip)
{
    // Placeholder - would add clip to database with track association
    if (m_cachedClipCount >= 0) m_cachedClipCount++;
    invalidateClipCache();
    updateModifiedTime();
}

bool Track::hasOverlappingClips(const Clip& clip) const
{
    // Placeholder - would check for overlaps with existing clips
    Q_UNUSED(clip)
    return false; // Simplified for now
}

void Track::insertClipAt(const Clip& clip, qint64 position)
{
    // Placeholder - would insert clip at specific position
    Q_UNUSED(clip)
    Q_UNUSED(position)
    addClip(clip); // Simplified
}

QList<Clip> Track::getClipsAtTime(qint64 time) const
{
    // Placeholder - would query clips overlapping the given time
    Q_UNUSED(time)
    return QList<Clip>(); // Simplified for now
}

void Track::trimToContent()
{
    // Placeholder - would trim track duration to actual content
    updateModifiedTime();
}

void Track::padToLength(qint64 length)
{
    if (m_cachedDuration < length) {
        m_cachedDuration = length;
        updateModifiedTime();
    }
}

void Track::trimToLength(qint64 length)
{
    if (m_cachedDuration > length) {
        m_cachedDuration = length;
        // Would also trim any clips that extend beyond this length
        updateModifiedTime();
    }
}

bool Track::isRenderableAtTime(double time) const
{
    Q_UNUSED(time)
    return m_enabled && !isEffectivelyMuted();
}

RenderState Track::getRenderState(double time) const
{
    Q_UNUSED(time)
    
    RenderState state;
    state.isVisible = m_enabled && !isEffectivelyMuted();
    state.opacity = m_type == Video ? m_opacity : 1.0;
    state.volume = m_type == Audio ? m_volume : 1.0;
    state.isMuted = isEffectivelyMuted();
    
    return state;
}

void Track::updateModifiedTime()
{
    m_modifiedAt = QDateTime::currentDateTime();
}

void Track::validateVideoProperties()
{
    if (m_type == Video) {
        m_opacity = qBound(0.0, m_opacity, 1.0);
    }
}

void Track::validateAudioProperties()
{
    if (m_type == Audio) {
        m_volume = qMax(0.0, m_volume); // Allow > 1.0 for gain
        m_pan = qBound(-1.0, m_pan, 1.0);
    }
}

void Track::invalidateClipCache()
{
    m_cachedClipCount = -1;
    m_cachedDuration = -1;
}

void Track::initializeDefaults()
{
    if (m_type == Video) {
        m_opacity = 1.0;
        m_blendMode = Normal;
        // Audio properties remain at defaults but are unused
    } else if (m_type == Audio) {
        m_volume = 1.0;
        m_pan = 0.0;
        // Video properties remain at defaults but are unused
    }
}