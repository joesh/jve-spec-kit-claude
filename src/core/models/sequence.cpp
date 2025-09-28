#include "sequence.h"
#include "track.h"

#include <QUuid>
#include <QSqlQuery>
#include <QSqlError>
#include <QLoggingCategory>
#include <QtMath>

Q_LOGGING_CATEGORY(jveSequence, "jve.models.sequence")

Sequence Sequence::create(const QString& name, const QString& projectId, 
                         double framerate, int width, int height)
{
    // Algorithm: Generate UUID → Set canvas properties → Associate with project
    Sequence sequence;
    sequence.m_id = QUuid::createUuid().toString(QUuid::WithoutBraces);
    sequence.m_name = name;
    sequence.m_projectId = projectId;
    sequence.m_framerate = framerate;
    sequence.m_width = width;
    sequence.m_height = height;
    sequence.m_createdAt = QDateTime::currentDateTime();
    sequence.m_modifiedAt = sequence.m_createdAt;
    
    sequence.validateFramerate();
    sequence.validateCanvasResolution();
    
    // Initialize track counts for new sequence (empty = 0 tracks)
    sequence.m_cachedTrackCount = 0;
    sequence.m_cachedVideoTrackCount = 0;
    sequence.m_cachedAudioTrackCount = 0;
    
    qCDebug(jveSequence, "Created sequence: %s for project: %s canvas: %dx%d@%gfps", 
                        qPrintable(name), qPrintable(projectId), width, height, framerate);
    return sequence;
}

Sequence Sequence::load(const QString& id, const QSqlDatabase& database)
{
    // Algorithm: Query database → Parse results → Construct object
    QSqlQuery query(database);
    query.prepare(R"(
        SELECT id, project_id, name, frame_rate, width, height, timecode_start
        FROM sequences WHERE id = ?
    )");
    query.addBindValue(id);
    
    if (!query.exec()) {
        qCWarning(jveSequence, "Failed to load sequence: %s", qPrintable(query.lastError().text()));
        return Sequence();
    }
    
    if (!query.next()) {
        qCDebug(jveSequence, "Sequence not found: %s", qPrintable(id));
        return Sequence();
    }
    
    Sequence sequence;
    sequence.m_id = query.value("id").toString();
    sequence.m_projectId = query.value("project_id").toString();
    sequence.m_name = query.value("name").toString();
    sequence.m_framerate = query.value("frame_rate").toDouble();
    sequence.m_width = query.value("width").toInt();
    sequence.m_height = query.value("height").toInt();
    // timecode_start = query.value("timecode_start").toLongLong(); // Not stored in model yet
    
    // Set reasonable defaults for fields not in schema
    sequence.m_createdAt = QDateTime::currentDateTime();
    sequence.m_modifiedAt = QDateTime::currentDateTime();
    
    sequence.validateFramerate();
    sequence.validateCanvasResolution();
    
    qCDebug(jveSequence, "Loaded sequence: %s", qPrintable(sequence.m_name));
    return sequence;
}

QList<Sequence> Sequence::loadByProject(const QString& projectId, const QSqlDatabase& database)
{
    // Algorithm: Query by project → Parse results → Return list
    QList<Sequence> sequences;
    
    QSqlQuery query(database);
    query.prepare(R"(
        SELECT id FROM sequences 
        WHERE project_id = ? 
        ORDER BY name ASC
    )");
    query.addBindValue(projectId);
    
    if (!query.exec()) {
        qCWarning(jveSequence, "Failed to load sequences for project: %s", qPrintable(query.lastError().text()));
        return sequences;
    }
    
    while (query.next()) {
        QString sequenceId = query.value("id").toString();
        Sequence sequence = load(sequenceId, database);
        if (sequence.isValid()) {
            sequences.append(sequence);
        }
    }
    
    qCDebug(jveSequence, "Loaded %lld sequences for project: %s", (long long)sequences.size(), qPrintable(projectId));
    return sequences;
}

bool Sequence::save(const QSqlDatabase& database)
{
    // Algorithm: Validate data → Execute insert/update → Update timestamps
    if (!isValid()) {
        qCWarning(jveSequence, "Cannot save invalid sequence");
        return false;
    }
    
    updateModifiedTime();
    
    QSqlQuery query(database);
    query.prepare(R"(
        INSERT OR REPLACE INTO sequences 
        (id, project_id, name, frame_rate, width, height, timecode_start)
        VALUES (?, ?, ?, ?, ?, ?, ?)
    )");
    
    query.addBindValue(m_id);
    query.addBindValue(m_projectId);
    query.addBindValue(m_name);
    query.addBindValue(m_framerate);
    query.addBindValue(m_width);
    query.addBindValue(m_height);
    query.addBindValue(0); // timecode_start default to 0
    
    if (!query.exec()) {
        qCWarning(jveSequence, "Failed to save sequence: %s", qPrintable(query.lastError().text()));
        return false;
    }
    
    qCDebug(jveSequence, "Saved sequence: %s", qPrintable(m_name));
    return true;
}

void Sequence::setName(const QString& name)
{
    if (m_name != name) {
        m_name = name;
        updateModifiedTime();
    }
}

void Sequence::setFramerate(double framerate)
{
    if (framerate > 0 && framerate <= 120.0) { // Reasonable bounds
        m_framerate = framerate;
        updateModifiedTime();
        validateFramerate();
    }
}


void Sequence::setCanvasResolution(int width, int height)
{
    if (width > 0 && height > 0) {
        m_width = width;
        m_height = height;
        updateModifiedTime();
        validateCanvasResolution();
    }
}

qint64 Sequence::duration() const
{
    // Duration is calculated from clips, not stored
    // For now, return 0 - will implement when database is available
    return 0; // TODO: implement calculateDurationFromClips
}

double Sequence::aspectRatio() const
{
    if (m_height == 0) return 16.0 / 9.0; // Default
    return static_cast<double>(m_width) / static_cast<double>(m_height);
}

void Sequence::setDescription(const QString& description)
{
    if (m_description != description) {
        m_description = description;
        updateModifiedTime();
    }
}


bool Sequence::isDropFrame() const
{
    // Drop frame for NTSC framerates
    double diff29_97 = qAbs(m_framerate - 29.97);
    double diff59_94 = qAbs(m_framerate - 59.94);
    
    return diff29_97 < 0.01 || diff59_94 < 0.01;
}

qint64 Sequence::durationInFrames() const
{
    return millisecondsToFrames(duration()); // Use calculated duration
}

qint64 Sequence::framesToMilliseconds(qint64 frames) const
{
    if (m_framerate <= 0) return 0;
    return qRound(frames * 1000.0 / m_framerate);
}

qint64 Sequence::millisecondsToFrames(qint64 milliseconds) const
{
    if (m_framerate <= 0) return 0;
    return qRound(milliseconds * m_framerate / 1000.0);
}

QString Sequence::formatTimecode(qint64 milliseconds) const
{
    if (milliseconds < 0) return "00:00:00:00";
    
    qint64 totalFrames = millisecondsToFrames(milliseconds);
    
    int framesPerSecond = qRound(m_framerate);
    int framesPerMinute = framesPerSecond * 60;
    int framesPerHour = framesPerMinute * 60;
    
    int hours = totalFrames / framesPerHour;
    totalFrames %= framesPerHour;
    
    int minutes = totalFrames / framesPerMinute;
    totalFrames %= framesPerMinute;
    
    int seconds = totalFrames / framesPerSecond;
    int frames = totalFrames % framesPerSecond;
    
    // Use semicolon for drop frame timecode
    QString separator = isDropFrame() ? ";" : ":";
    
    return QString("%1:%2:%3%4%5")
        .arg(hours, 2, 10, QLatin1Char('0'))
        .arg(minutes, 2, 10, QLatin1Char('0'))
        .arg(seconds, 2, 10, QLatin1Char('0'))
        .arg(separator)
        .arg(frames, 2, 10, QLatin1Char('0'));
}

int Sequence::trackCount() const
{
    // This is a placeholder - will need database access
    // For now, return cached value or default
    return m_cachedTrackCount >= 0 ? m_cachedTrackCount : 0;
}

int Sequence::videoTrackCount() const
{
    return m_cachedVideoTrackCount >= 0 ? m_cachedVideoTrackCount : 0;
}

int Sequence::audioTrackCount() const
{
    return m_cachedAudioTrackCount >= 0 ? m_cachedAudioTrackCount : 0;
}

void Sequence::addVideoTrack(const QString& name)
{
    // This would create a new video track and associate it with this sequence
    // For now, just increment cache counters (initialized to 0 in create())
    m_cachedTrackCount++;
    m_cachedVideoTrackCount++;
    
    updateModifiedTime();
    qCDebug(jveSequence, "Added video track: %s to sequence: %s", qPrintable(name), qPrintable(m_name));
}

void Sequence::addAudioTrack(const QString& name)
{
    // This would create a new audio track and associate it with this sequence
    // For now, just increment cache counters (initialized to 0 in create())
    m_cachedTrackCount++;
    m_cachedAudioTrackCount++;
    
    updateModifiedTime();
    qCDebug(jveSequence, "Added audio track: %s to sequence: %s", qPrintable(name), qPrintable(m_name));
}

void Sequence::updateModifiedTime()
{
    m_modifiedAt = QDateTime::currentDateTime();
}

void Sequence::validateFramerate()
{
    if (m_framerate <= 0) {
        qCWarning(jveSequence, "Invalid framerate: %g", m_framerate);
        // No defaults - validation fails, caller must provide valid value
    } else if (m_framerate > 120.0) {
        qCWarning(jveSequence, "Framerate too high, clamping to 120: %g", m_framerate);
        m_framerate = 120.0;
    }
}

void Sequence::validateCanvasResolution()
{
    if (m_width <= 0) {
        qCWarning(jveSequence, "Invalid canvas width: %d", m_width);
        // No defaults - validation fails, caller must provide valid value
    }
    
    if (m_height <= 0) {
        qCWarning(jveSequence, "Invalid canvas height: %d", m_height);
        // No defaults - validation fails, caller must provide valid value  
    }
}


void Sequence::invalidateTrackCache()
{
    m_cachedTrackCount = -1;
    m_cachedVideoTrackCount = -1;
    m_cachedAudioTrackCount = -1;
}

int Sequence::queryTrackCount(const QSqlDatabase& database, const QString& trackType) const
{
    QSqlQuery query(database);
    
    if (trackType.isEmpty()) {
        query.prepare("SELECT COUNT(*) FROM tracks WHERE sequence_id = ?");
        query.addBindValue(m_id);
    } else {
        query.prepare("SELECT COUNT(*) FROM tracks WHERE sequence_id = ? AND track_type = ?");
        query.addBindValue(m_id);
        query.addBindValue(trackType);
    }
    
    if (query.exec() && query.next()) {
        return query.value(0).toInt();
    }
    
    qCWarning(jveSequence, "Failed to query track count: %s", qPrintable(query.lastError().text()));
    return 0;
}