#pragma once

#include <QObject>
#include <QString>
#include <QList>
#include <QSqlDatabase>
#include <QTimer>
#include <QElapsedTimer>
#include <QThread>

/**
 * Timeline data structures for professional video editing
 */
enum class PlaybackState {
    Stopped,
    Playing,
    Paused
};

enum class PlaybackDirection {
    Forward,
    Reverse
};

enum class RippleType {
    Insert,
    Delete,
    Move
};

struct ClipInfo {
    QString id;
    qint64 start = 0;
    qint64 end = 0;
    QString trackId;
    QString mediaId;
    bool enabled = true;
};

struct TimelineGap {
    qint64 start = 0;
    qint64 duration = 0;
    QString trackId;
};

struct RippleOperation {
    RippleType type;
    QString clipId;
    ClipInfo clip;
    qint64 insertPosition = 0;
    QStringList affectTracks;
};

struct RippleResult {
    bool success = false;
    QString errorMessage;
    QStringList affectedClips;
    QList<ClipInfo> newPositions;
};

struct ClipDragResult {
    bool snapped = false;
    qint64 newStart = 0;
    qint64 newEnd = 0;
    QString snapTarget;
};

struct TimelineMetrics {
    qint64 totalDuration = 0;
    int clipCount = 0;
    int trackCount = 0;
    double averageClipLength = 0.0;
    QStringList trackIds;
};

// Performance constants
const int MAX_TIMELINE_RENDER_MS = 16; // 60fps requirement

/**
 * TimelineManager: Professional video editing timeline operations
 * 
 * Constitutional requirements:
 * - Playback control with professional J/K/L navigation patterns
 * - Frame-accurate positioning and trimming operations
 * - Ripple editing and gap management for efficient workflows
 * - Snap-to behavior and magnetic timeline for precision editing
 * - 60fps performance requirements for smooth preview playback
 * 
 * Engineering Rules:
 * - Rule 2.14: No hardcoded constants (uses schema_constants.h)
 * - Rule 2.26: Functions read like algorithms calling subfunctions
 * - Rule 2.27: Short, focused functions with single responsibilities
 */
class TimelineManager : public QObject
{
    Q_OBJECT

public:
    explicit TimelineManager(QObject* parent = nullptr);
    
    // Sequence management
    void loadSequence(const QString& sequenceId, QSqlDatabase& database);
    void setFramerate(double framerate);
    double framerate() const { return m_framerate; }
    
    // Playback control
    void play();
    void pause();
    void stop();
    void seek(qint64 timeMs);
    void seekToFrame(int frameNumber);
    
    // Playback state
    PlaybackState playbackState() const { return m_playbackState; }
    PlaybackDirection playbackDirection() const { return m_playbackDirection; }
    qint64 currentTime() const { return m_currentTime; }
    bool isPlaying() const { return m_playbackState == PlaybackState::Playing; }
    
    // Frame operations
    qint64 getFrameDuration() const;
    int getCurrentFrame() const;
    void snapToFrame();
    void stepForward();
    void stepBackward();
    void goToStart();
    void goToEnd();
    qint64 getSequenceDuration() const { return m_sequenceDuration; }
    
    // Navigation
    void handleKeyPress(char key);
    
    // Clip management
    void addClip(const ClipInfo& clip);
    ClipInfo getClip(const QString& clipId) const;
    QList<ClipInfo> getAllClips() const { return m_clips; }
    
    // Ripple editing
    RippleResult performRipple(const RippleOperation& operation);
    void removeGaps(const QStringList& trackIds);
    QList<TimelineGap> findGaps(const QStringList& trackIds) const;
    
    // Snap behavior
    void setSnapEnabled(bool enabled);
    bool isSnapEnabled() const { return m_snapEnabled; }
    void setSnapTolerance(int toleranceMs);
    int snapTolerance() const { return m_snapTolerance; }
    void setSnapPoints(const QList<qint64>& points);
    qint64 getSnappedTime(qint64 timeMs) const;
    
    // Magnetic timeline
    void setMagneticTimelineEnabled(bool enabled);
    ClipDragResult dragClip(const ClipInfo& clip, qint64 newStartTime);
    
    // Performance and metrics
    TimelineMetrics calculateMetrics() const;

signals:
    void playbackStateChanged(PlaybackState state);
    void currentTimeChanged(qint64 timeMs);
    void frameChanged(int frameNumber);

private slots:
    void onPlaybackTimer();

private:
    // Algorithm implementations
    void updatePlaybackPosition();
    void validateTimelineConsistency();
    ClipInfo* findClipById(const QString& clipId);
    QList<ClipInfo> getClipsOnTracks(const QStringList& trackIds) const;
    void shiftClipsAfterPosition(qint64 position, qint64 offset, const QStringList& trackIds);
    qint64 findNearestSnapPoint(qint64 timeMs) const;
    void loadClipsFromDatabase();
    
    // Core state
    QString m_sequenceId;
    QSqlDatabase* m_database = nullptr;
    double m_framerate = 29.97;
    qint64 m_sequenceDuration = 0;
    
    // Playback state
    PlaybackState m_playbackState = PlaybackState::Stopped;
    PlaybackDirection m_playbackDirection = PlaybackDirection::Forward;
    qint64 m_currentTime = 0;
    QTimer* m_playbackTimer;
    
    // Timeline content
    QList<ClipInfo> m_clips;
    
    // Snap system
    bool m_snapEnabled = false;
    int m_snapTolerance = 100;
    QList<qint64> m_snapPoints;
    bool m_magneticTimelineEnabled = false;
    
    // Performance tracking
    mutable QElapsedTimer m_performanceTimer;
};