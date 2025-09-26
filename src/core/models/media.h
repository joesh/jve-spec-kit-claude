#pragma once

#include <QString>
#include <QDateTime>
#include <QSqlDatabase>

/**
 * Media metadata structure
 * Contains technical information about media files
 */
struct MediaMetadata
{
    qint64 duration = 0;        // Duration in milliseconds
    int width = 0;              // Video width in pixels
    int height = 0;             // Video height in pixels
    double framerate = 0.0;     // Video framerate
    QString videoCodec;         // Video codec name
    QString audioCodec;         // Audio codec name
    int bitrate = 0;           // Bitrate in bps
    int audioChannels = 0;      // Number of audio channels
    int audioSampleRate = 0;    // Audio sample rate in Hz
};

/**
 * Media entity - source file references and metadata
 * Core entity following Rule 2.27: Single responsibility - media file data only
 */
class Media
{
public:
    enum Type {
        UnknownType,
        Video,
        Audio,
        Image
    };
    
    enum Status {
        Unknown,
        Online,
        Offline,
        Processing
    };
    
    Media() = default;
    ~Media() = default;
    
    // Copy and move constructors
    Media(const Media& other) = default;
    Media& operator=(const Media& other) = default;
    Media(Media&& other) noexcept = default;
    Media& operator=(Media&& other) noexcept = default;
    
    /**
     * Create new media entry
     * Algorithm: Generate UUID → Set file info → Initialize state
     */
    static Media create(const QString& filename, const QString& filepath);
    
    /**
     * Load media from database by ID
     * Algorithm: Query database → Parse results → Construct object
     */
    static Media load(const QString& id, const QSqlDatabase& database);
    
    /**
     * Save media to database
     * Algorithm: Validate data → Execute insert/update → Update timestamps
     */
    bool save(const QSqlDatabase& database);
    
    // Core properties
    QString id() const { return m_id; }
    QString filename() const { return m_filename; }
    QString filepath() const { return m_filepath; }
    void setFilepath(const QString& filepath);
    
    QDateTime createdAt() const { return m_createdAt; }
    QDateTime modifiedAt() const { return m_modifiedAt; }
    
    // File status
    Status status() const { return m_status; }
    void setStatus(Status status);
    bool isOnline() const { return m_status == Online; }
    void checkFileStatus();
    
    // File information
    QDateTime fileModifiedTime() const { return m_fileModifiedTime; }
    void setFileModifiedTime(const QDateTime& modifiedTime);
    qint64 fileSize() const { return m_fileSize; }
    void setFileSize(qint64 size);
    
    // Media type detection
    Type type() const { return m_type; }
    Type detectType() const;
    void setType(Type type);
    
    // Metadata management
    void setMetadata(const MediaMetadata& metadata);
    qint64 duration() const { return m_metadata.duration; }
    int width() const { return m_metadata.width; }
    int height() const { return m_metadata.height; }
    double framerate() const { return m_metadata.framerate; }
    QString videoCodec() const { return m_metadata.videoCodec; }
    QString audioCodec() const { return m_metadata.audioCodec; }
    int bitrate() const { return m_metadata.bitrate; }
    
    // Proxy management
    bool hasProxy() const { return !m_proxyPath.isEmpty(); }
    QString proxyPath() const { return m_proxyPath; }
    void setProxyPath(const QString& proxyPath);
    
    bool hasThumbnail() const { return !m_thumbnailPath.isEmpty(); }
    QString thumbnailPath() const { return m_thumbnailPath; }
    void setThumbnailPath(const QString& thumbnailPath);
    
    bool useProxy() const { return m_useProxy; }
    void setUseProxy(bool useProxy);
    QString getEffectivePath() const;
    
    // Validation and state
    bool isValid() const { return !m_id.isEmpty() && !m_filename.isEmpty(); }

private:
    QString m_id;
    QString m_filename;
    QString m_filepath;
    QDateTime m_createdAt;
    QDateTime m_modifiedAt;
    
    // File status
    Status m_status = Unknown;
    Type m_type = UnknownType;
    QDateTime m_fileModifiedTime;
    qint64 m_fileSize = 0;
    
    // Technical metadata
    MediaMetadata m_metadata;
    
    // Proxy management
    QString m_proxyPath;
    QString m_thumbnailPath;
    bool m_useProxy = false;
    
    // Helper functions for algorithmic breakdown (Rule 2.26)
    void updateModifiedTime();
    Type detectTypeFromExtension(const QString& filename) const;
    void validateMetadata();
};