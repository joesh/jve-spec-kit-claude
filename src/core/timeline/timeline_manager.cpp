#include "timeline_manager.h"

#include <QLoggingCategory>
#include <QDebug>
#include <QSqlQuery>
#include <QSqlError>
#include <QtMath>
#include <algorithm>

Q_LOGGING_CATEGORY(jveTimeline, "jve.timeline")

TimelineManager::TimelineManager(QObject* parent)
    : QObject(parent)
{
    qCDebug(jveTimeline, "Initializing TimelineManager");
    
    // Algorithm: Create timer → Configure → Connect signals
    m_playbackTimer = new QTimer(this);
    m_playbackTimer->setSingleShot(false);
    m_playbackTimer->setInterval(16); // ~60fps updates
    
    connect(m_playbackTimer, &QTimer::timeout, this, &TimelineManager::onPlaybackTimer);
}

void TimelineManager::loadSequence(const QString& sequenceId, QSqlDatabase& database)
{
    qCDebug(jveTimeline, "Loading sequence: %s", qPrintable(sequenceId));
    
    // Algorithm: Store references → Load metadata → Load clips → Validate
    m_sequenceId = sequenceId;
    m_database = &database;
    
    // Load sequence metadata
    QSqlQuery query(database);
    query.prepare("SELECT frame_rate, duration FROM sequences WHERE id = ?");
    query.addBindValue(sequenceId);
    
    if (query.exec() && query.next()) {
        m_framerate = query.value("frame_rate").toDouble();
        m_sequenceDuration = query.value("duration").toLongLong();
    }
    
    loadClipsFromDatabase();
    validateTimelineConsistency();
}

void TimelineManager::setFramerate(double framerate)
{
    qCDebug(jveTimeline, "Setting framerate: %g", framerate);
    m_framerate = framerate;
}

void TimelineManager::play()
{
    qCDebug(jveTimeline, "Starting playback");
    
    // Algorithm: Set state → Start timer → Notify
    m_playbackState = PlaybackState::Playing;
    m_playbackDirection = PlaybackDirection::Forward;
    m_playbackTimer->start();
    
    emit playbackStateChanged(m_playbackState);
}

void TimelineManager::pause()
{
    qCDebug(jveTimeline, "Pausing playback");
    
    // Algorithm: Set state → Stop timer → Notify
    m_playbackState = PlaybackState::Paused;
    m_playbackTimer->stop();
    
    emit playbackStateChanged(m_playbackState);
}

void TimelineManager::stop()
{
    qCDebug(jveTimeline, "Stopping playback");
    
    // Algorithm: Stop timer → Reset position → Set state → Notify
    m_playbackTimer->stop();
    m_currentTime = 0;
    m_playbackState = PlaybackState::Stopped;
    
    emit playbackStateChanged(m_playbackState);
    emit currentTimeChanged(m_currentTime);
}

void TimelineManager::seek(qint64 timeMs)
{
    qCDebug(jveTimeline, "Seeking to: %lld", timeMs);
    
    // Algorithm: Clamp time → Set position → Notify
    // Allow seeking beyond current content for professional editor behavior
    qint64 maxSeekTime = qMax(m_sequenceDuration, qint64(24 * 60 * 60 * 1000)); // 24 hours max
    m_currentTime = qBound(qint64(0), timeMs, maxSeekTime);
    
    emit currentTimeChanged(m_currentTime);
    emit frameChanged(getCurrentFrame());
}

void TimelineManager::seekToFrame(int frameNumber)
{
    qCDebug(jveTimeline, "Seeking to frame: %d", frameNumber);
    
    // Algorithm: Calculate time → Seek to time
    qint64 frameTime = qRound(static_cast<double>(frameNumber) * getFrameDuration());
    seek(frameTime);
}

qint64 TimelineManager::getFrameDuration() const
{
    return qRound(1000.0 / m_framerate);
}

int TimelineManager::getCurrentFrame() const
{
    return qRound(static_cast<double>(m_currentTime) / getFrameDuration());
}

void TimelineManager::snapToFrame()
{
    qCDebug(jveTimeline, "Snapping to frame");
    
    // Algorithm: Get current frame → Calculate exact time → Seek
    int currentFrame = getCurrentFrame();
    qint64 frameTime = currentFrame * getFrameDuration();
    seek(frameTime);
}

void TimelineManager::stepForward()
{
    qCDebug(jveTimeline, "Stepping forward");
    
    // Algorithm: Calculate next frame → Seek
    qint64 nextTime = m_currentTime + getFrameDuration();
    seek(nextTime);
}

void TimelineManager::stepBackward()
{
    qCDebug(jveTimeline, "Stepping backward");
    
    // Algorithm: Calculate previous frame → Seek
    qint64 prevTime = m_currentTime - getFrameDuration();
    seek(prevTime);
}

void TimelineManager::goToStart()
{
    qCDebug(jveTimeline, "Going to start");
    seek(0);
}

void TimelineManager::goToEnd()
{
    qCDebug(jveTimeline, "Going to end");
    seek(m_sequenceDuration);
}

void TimelineManager::handleKeyPress(char key)
{
    qCDebug(jveTimeline, "Handling key press: %c", key);
    
    // Algorithm: Route by key → Execute command
    switch (key) {
    case 'J':
        // Reverse play/shuttle
        if (m_playbackState == PlaybackState::Playing) {
            if (m_playbackDirection == PlaybackDirection::Forward) {
                m_playbackDirection = PlaybackDirection::Reverse;
            } else {
                stepBackward();
            }
        } else {
            stepBackward();
        }
        break;
        
    case 'K':
        // Pause/play toggle
        if (m_playbackState == PlaybackState::Playing) {
            pause();
        } else {
            play();
        }
        break;
        
    case 'L':
        // Forward play/shuttle
        if (m_playbackState == PlaybackState::Playing) {
            m_playbackDirection = PlaybackDirection::Forward;
        } else {
            play();
        }
        break;
    }
}

void TimelineManager::addClip(const ClipInfo& clip)
{
    qCDebug(jveTimeline, "Adding clip: %s", qPrintable(clip.id));
    
    // Algorithm: Validate → Insert → Sort → Update metrics
    m_clips.append(clip);
    
    // Sort clips by start time for efficient operations
    std::sort(m_clips.begin(), m_clips.end(), 
              [](const ClipInfo& a, const ClipInfo& b) {
                  return a.start < b.start;
              });
    
    validateTimelineConsistency();
}

ClipInfo TimelineManager::getClip(const QString& clipId) const
{
    // Algorithm: Search clips → Return match or empty
    for (const ClipInfo& clip : m_clips) {
        if (clip.id == clipId) {
            return clip;
        }
    }
    return ClipInfo();
}

RippleResult TimelineManager::performRipple(const RippleOperation& operation)
{
    qCDebug(jveTimeline, "Performing ripple operation: %d", static_cast<int>(operation.type));
    
    // Algorithm: Validate → Execute → Update positions → Return result
    RippleResult result;
    result.success = true;
    
    switch (operation.type) {
    case RippleType::Delete:
        {
            // Find clip to delete
            ClipInfo* clipToDelete = findClipById(operation.clipId);
            if (!clipToDelete) {
                result.success = false;
                result.errorMessage = "Clip not found for deletion";
                break;
            }
            
            qint64 deletedDuration = clipToDelete->end - clipToDelete->start;
            qint64 deletePosition = clipToDelete->start;
            
            // Remove the clip
            m_clips.removeOne(*clipToDelete);
            
            // Shift clips after deletion point
            shiftClipsAfterPosition(deletePosition, -deletedDuration, operation.affectTracks);
            
            // Record affected clips
            for (const ClipInfo& clip : m_clips) {
                if (operation.affectTracks.contains(clip.trackId) && clip.start >= deletePosition) {
                    result.affectedClips.append(clip.id);
                }
            }
        }
        break;
        
    case RippleType::Insert:
        {
            qint64 insertDuration = operation.clip.end - operation.clip.start;
            
            // Shift clips after insertion point
            shiftClipsAfterPosition(operation.insertPosition, insertDuration, operation.affectTracks);
            
            // Add the new clip
            ClipInfo insertClip = operation.clip;
            insertClip.start = operation.insertPosition;
            insertClip.end = operation.insertPosition + insertDuration;
            addClip(insertClip);
            
            // Record affected clips (clips that overlap or come after the insertion point)
            for (const ClipInfo& clip : m_clips) {
                if (operation.affectTracks.contains(clip.trackId) && clip.id != insertClip.id) {
                    // Clip is affected if it overlaps the insertion point or comes after it
                    if (clip.start >= operation.insertPosition || 
                        (clip.start < operation.insertPosition && clip.end > operation.insertPosition)) {
                        result.affectedClips.append(clip.id);
                    }
                }
            }
        }
        break;
        
    case RippleType::Move:
        // Implementation for move operations
        result.success = false;
        result.errorMessage = "Move ripple not yet implemented";
        break;
    }
    
    validateTimelineConsistency();
    return result;
}

void TimelineManager::removeGaps(const QStringList& trackIds)
{
    qCDebug(jveTimeline, "Removing gaps on tracks: %s", qPrintable(trackIds.join(", ")));
    
    // Algorithm: Find gaps → Shift clips → Validate
    for (const QString& trackId : trackIds) {
        QList<ClipInfo> trackClips = getClipsOnTracks({trackId});
        
        if (trackClips.size() < 2) {
            continue; // No gaps possible with less than 2 clips
        }
        
        // Sort by start time
        std::sort(trackClips.begin(), trackClips.end(),
                  [](const ClipInfo& a, const ClipInfo& b) {
                      return a.start < b.start;
                  });
        
        // Close gaps by shifting clips left
        qint64 writePosition = trackClips.first().end;
        for (int i = 1; i < trackClips.size(); i++) {
            ClipInfo& clip = trackClips[i];
            if (clip.start > writePosition) {
                qint64 gapSize = clip.start - writePosition;
                
                // Update clip in main list
                ClipInfo* mainClip = findClipById(clip.id);
                if (mainClip) {
                    mainClip->start -= gapSize;
                    mainClip->end -= gapSize;
                }
                
                writePosition = mainClip->end;
            } else {
                writePosition = clip.end;
            }
        }
    }
}

QList<TimelineGap> TimelineManager::findGaps(const QStringList& trackIds) const
{
    qCDebug(jveTimeline, "Finding gaps on tracks: %s", qPrintable(trackIds.join(", ")));
    
    // Algorithm: Analyze clips → Identify gaps → Return list
    QList<TimelineGap> gaps;
    
    for (const QString& trackId : trackIds) {
        QList<ClipInfo> trackClips = getClipsOnTracks({trackId});
        
        if (trackClips.size() < 2) {
            continue;
        }
        
        // Sort by start time
        std::sort(trackClips.begin(), trackClips.end(),
                  [](const ClipInfo& a, const ClipInfo& b) {
                      return a.start < b.start;
                  });
        
        // Find gaps between consecutive clips
        for (int i = 0; i < trackClips.size() - 1; i++) {
            qint64 gapStart = trackClips[i].end;
            qint64 gapEnd = trackClips[i + 1].start;
            
            if (gapEnd > gapStart) {
                TimelineGap gap;
                gap.start = gapStart;
                gap.duration = gapEnd - gapStart;
                gap.trackId = trackId;
                gaps.append(gap);
            }
        }
    }
    
    return gaps;
}

void TimelineManager::setSnapEnabled(bool enabled)
{
    qCDebug(jveTimeline, "Setting snap enabled: %s", enabled ? "true" : "false");
    m_snapEnabled = enabled;
}

void TimelineManager::setSnapTolerance(int toleranceMs)
{
    qCDebug(jveTimeline, "Setting snap tolerance: %d", toleranceMs);
    m_snapTolerance = toleranceMs;
}

void TimelineManager::setSnapPoints(const QList<qint64>& points)
{
    qCDebug(jveTimeline, "Setting snap points: %lld", static_cast<long long>(points.size()));
    m_snapPoints = points;
}

qint64 TimelineManager::getSnappedTime(qint64 timeMs) const
{
    // Algorithm: Check snap enabled → Find nearest → Apply tolerance → Return result
    if (!m_snapEnabled || m_snapPoints.isEmpty()) {
        return timeMs;
    }
    
    qint64 nearestPoint = findNearestSnapPoint(timeMs);
    qint64 distance = qAbs(timeMs - nearestPoint);
    
    if (distance <= m_snapTolerance) {
        return nearestPoint;
    }
    
    return timeMs;
}

void TimelineManager::setMagneticTimelineEnabled(bool enabled)
{
    qCDebug(jveTimeline, "Setting magnetic timeline enabled: %s", enabled ? "true" : "false");
    m_magneticTimelineEnabled = enabled;
}

ClipDragResult TimelineManager::dragClip(const ClipInfo& clip, qint64 newStartTime)
{
    qCDebug(jveTimeline, "Dragging clip: %s to: %lld", qPrintable(clip.id), newStartTime);
    
    // Algorithm: Check magnetic → Find snap target → Calculate result
    ClipDragResult result;
    
    qint64 clipDuration = clip.end - clip.start;
    qint64 snappedStart = getSnappedTime(newStartTime);
    
    if (snappedStart != newStartTime) {
        result.snapped = true;
        result.snapTarget = "snap_point";
    } else if (m_magneticTimelineEnabled) {
        // Check snapping to other clips
        for (const ClipInfo& otherClip : m_clips) {
            if (otherClip.id != clip.id && otherClip.trackId == clip.trackId) {
                // Check start-to-start snap
                qint64 startDistance = qAbs(newStartTime - otherClip.start);
                if (startDistance <= m_snapTolerance) {
                    snappedStart = otherClip.start;
                    result.snapped = true;
                    result.snapTarget = otherClip.id;
                    break;
                }
                
                // Check start-to-end snap
                qint64 endDistance = qAbs(newStartTime - otherClip.end);
                if (endDistance <= m_snapTolerance) {
                    snappedStart = otherClip.end;
                    result.snapped = true;
                    result.snapTarget = otherClip.id;
                    break;
                }
            }
        }
    }
    
    result.newStart = snappedStart;
    result.newEnd = snappedStart + clipDuration;
    
    return result;
}

TimelineMetrics TimelineManager::calculateMetrics() const
{
    qCDebug(jveTimeline, "Calculating timeline metrics");
    
    // Algorithm: Analyze clips → Calculate stats → Return metrics
    TimelineMetrics metrics;
    
    metrics.clipCount = m_clips.size();
    
    // Calculate track count, total duration, and average clip length
    QSet<QString> uniqueTracks;
    qint64 totalClipDuration = 0;
    qint64 timelineEnd = 0;
    
    for (const ClipInfo& clip : m_clips) {
        uniqueTracks.insert(clip.trackId);
        totalClipDuration += (clip.end - clip.start);
        timelineEnd = qMax(timelineEnd, clip.end);  // Find the end of timeline content
    }
    
    // Set total duration to actual timeline content duration
    metrics.totalDuration = timelineEnd;
    
    metrics.trackCount = uniqueTracks.size();
    metrics.trackIds = uniqueTracks.values();
    
    if (metrics.clipCount > 0) {
        metrics.averageClipLength = static_cast<double>(totalClipDuration) / metrics.clipCount;
    }
    
    return metrics;
}

void TimelineManager::onPlaybackTimer()
{
    // Algorithm: Update position → Check bounds → Notify
    if (m_playbackState != PlaybackState::Playing) {
        return;
    }
    
    updatePlaybackPosition();
    
    emit currentTimeChanged(m_currentTime);
    emit frameChanged(getCurrentFrame());
}

void TimelineManager::updatePlaybackPosition()
{
    qint64 increment = m_playbackTimer->interval(); // Usually 16ms for 60fps
    
    if (m_playbackDirection == PlaybackDirection::Forward) {
        m_currentTime += increment;
        if (m_currentTime >= m_sequenceDuration) {
            stop(); // Auto-stop at end
        }
    } else {
        m_currentTime -= increment;
        if (m_currentTime <= 0) {
            m_currentTime = 0;
            pause(); // Pause at beginning in reverse
        }
    }
}

void TimelineManager::validateTimelineConsistency()
{
    // Algorithm: Check overlaps → Validate durations → Log issues
    // For M1 Foundation, basic validation
    qCDebug(jveTimeline, "Validating timeline consistency");
}

ClipInfo* TimelineManager::findClipById(const QString& clipId)
{
    for (ClipInfo& clip : m_clips) {
        if (clip.id == clipId) {
            return &clip;
        }
    }
    return nullptr;
}

QList<ClipInfo> TimelineManager::getClipsOnTracks(const QStringList& trackIds) const
{
    QList<ClipInfo> result;
    for (const ClipInfo& clip : m_clips) {
        if (trackIds.contains(clip.trackId)) {
            result.append(clip);
        }
    }
    return result;
}

void TimelineManager::shiftClipsAfterPosition(qint64 position, qint64 offset, const QStringList& trackIds)
{
    for (ClipInfo& clip : m_clips) {
        if (trackIds.contains(clip.trackId)) {
            // Shift clips that start at or after the position
            if (clip.start >= position) {
                clip.start += offset;
                clip.end += offset;
            }
            // For clips that overlap the position, extend their end time
            else if (clip.start < position && clip.end > position) {
                clip.end += offset;
            }
        }
    }
}

qint64 TimelineManager::findNearestSnapPoint(qint64 timeMs) const
{
    if (m_snapPoints.isEmpty()) {
        return timeMs;
    }
    
    qint64 nearest = m_snapPoints.first();
    qint64 minDistance = qAbs(timeMs - nearest);
    
    for (qint64 point : m_snapPoints) {
        qint64 distance = qAbs(timeMs - point);
        if (distance < minDistance) {
            minDistance = distance;
            nearest = point;
        }
    }
    
    return nearest;
}

void TimelineManager::loadClipsFromDatabase()
{
    if (!m_database) {
        return;
    }
    
    // Algorithm: Query clips → Parse results → Populate list
    QSqlQuery query(*m_database);
    query.prepare(
        "SELECT c.id, c.start_value, c.duration_value, c.track_id, c.media_id "
        "FROM clips c "
        "JOIN tracks t ON c.track_id = t.id "
        "JOIN sequences s ON t.sequence_id = s.id "
        "WHERE s.id = ? "
        "ORDER BY c.start_value"
    );
    query.addBindValue(m_sequenceId);
    
    m_clips.clear();
    if (query.exec()) {
        while (query.next()) {
            ClipInfo clip;
            clip.id = query.value("id").toString();
            clip.start = query.value("start_value").toLongLong();
            clip.end = clip.start + query.value("duration_value").toLongLong();
            clip.trackId = query.value("track_id").toString();
            clip.mediaId = query.value("media_id").toString();
            
            m_clips.append(clip);
        }
    }
    
    qCDebug(jveTimeline, "Loaded %lld clips from database", static_cast<long long>(m_clips.size()));
}
