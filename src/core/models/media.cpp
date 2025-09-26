#include "media.h"

#include <QUuid>
#include <QSqlQuery>
#include <QSqlError>
#include <QLoggingCategory>
#include <QFileInfo>

Q_LOGGING_CATEGORY(jveMedia, "jve.models.media")

Media Media::create(const QString& filename, const QString& filepath)
{
    // Algorithm: Generate UUID → Set file info → Initialize state
    Media media;
    media.m_id = QUuid::createUuid().toString(QUuid::WithoutBraces);
    media.m_filename = filename;
    media.m_filepath = filepath;
    media.m_createdAt = QDateTime::currentDateTime();
    media.m_modifiedAt = media.m_createdAt;
    media.m_type = media.detectTypeFromExtension(filename);
    media.m_status = Unknown; // Will be determined by file check
    
    qCDebug(jveMedia) << "Created media:" << filename << "at path:" << filepath;
    return media;
}

Media Media::load(const QString& id, const QSqlDatabase& database)
{
    // Algorithm: Query database → Parse results → Construct object
    QSqlQuery query(database);
    query.prepare(R"(
        SELECT id, filename, filepath, created_at, modified_at, status, type,
               file_modified_time, file_size, duration, width, height, framerate,
               video_codec, audio_codec, bitrate, proxy_path, thumbnail_path, use_proxy
        FROM media WHERE id = ?
    )");
    query.addBindValue(id);
    
    if (!query.exec()) {
        qCWarning(jveMedia) << "Failed to load media:" << query.lastError().text();
        return Media();
    }
    
    if (!query.next()) {
        qCDebug(jveMedia) << "Media not found:" << id;
        return Media();
    }
    
    Media media;
    media.m_id = query.value("id").toString();
    media.m_filename = query.value("filename").toString();
    media.m_filepath = query.value("filepath").toString();
    media.m_createdAt = QDateTime::fromSecsSinceEpoch(query.value("created_at").toLongLong());
    media.m_modifiedAt = QDateTime::fromSecsSinceEpoch(query.value("modified_at").toLongLong());
    media.m_status = static_cast<Status>(query.value("status").toInt());
    media.m_type = static_cast<Type>(query.value("type").toInt());
    media.m_fileModifiedTime = QDateTime::fromSecsSinceEpoch(query.value("file_modified_time").toLongLong());
    media.m_fileSize = query.value("file_size").toLongLong();
    
    // Load metadata
    media.m_metadata.duration = query.value("duration").toLongLong();
    media.m_metadata.width = query.value("width").toInt();
    media.m_metadata.height = query.value("height").toInt();
    media.m_metadata.framerate = query.value("framerate").toDouble();
    media.m_metadata.videoCodec = query.value("video_codec").toString();
    media.m_metadata.audioCodec = query.value("audio_codec").toString();
    media.m_metadata.bitrate = query.value("bitrate").toInt();
    
    // Load proxy information
    media.m_proxyPath = query.value("proxy_path").toString();
    media.m_thumbnailPath = query.value("thumbnail_path").toString();
    media.m_useProxy = query.value("use_proxy").toBool();
    
    media.validateMetadata();
    
    qCDebug(jveMedia) << "Loaded media:" << media.m_filename;
    return media;
}

bool Media::save(const QSqlDatabase& database)
{
    // Algorithm: Validate data → Execute insert/update → Update timestamps
    if (!isValid()) {
        qCWarning(jveMedia) << "Cannot save invalid media";
        return false;
    }
    
    updateModifiedTime();
    
    QSqlQuery query(database);
    query.prepare(R"(
        INSERT OR REPLACE INTO media 
        (id, filename, filepath, created_at, modified_at, status, type,
         file_modified_time, file_size, duration, width, height, framerate,
         video_codec, audio_codec, bitrate, proxy_path, thumbnail_path, use_proxy)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    )");
    
    query.addBindValue(m_id);
    query.addBindValue(m_filename);
    query.addBindValue(m_filepath);
    query.addBindValue(m_createdAt.toSecsSinceEpoch());
    query.addBindValue(m_modifiedAt.toSecsSinceEpoch());
    query.addBindValue(static_cast<int>(m_status));
    query.addBindValue(static_cast<int>(m_type));
    query.addBindValue(m_fileModifiedTime.toSecsSinceEpoch());
    query.addBindValue(m_fileSize);
    query.addBindValue(m_metadata.duration);
    query.addBindValue(m_metadata.width);
    query.addBindValue(m_metadata.height);
    query.addBindValue(m_metadata.framerate);
    query.addBindValue(m_metadata.videoCodec);
    query.addBindValue(m_metadata.audioCodec);
    query.addBindValue(m_metadata.bitrate);
    query.addBindValue(m_proxyPath);
    query.addBindValue(m_thumbnailPath);
    query.addBindValue(m_useProxy);
    
    if (!query.exec()) {
        qCWarning(jveMedia) << "Failed to save media:" << query.lastError().text();
        return false;
    }
    
    qCDebug(jveMedia) << "Saved media:" << m_filename;
    return true;
}

void Media::setFilepath(const QString& filepath)
{
    if (m_filepath != filepath) {
        m_filepath = filepath;
        m_status = Unknown; // Need to recheck file status
        updateModifiedTime();
    }
}

void Media::setStatus(Status status)
{
    if (m_status != status) {
        m_status = status;
        updateModifiedTime();
    }
}

void Media::checkFileStatus()
{
    QFileInfo fileInfo(m_filepath);
    
    if (fileInfo.exists() && fileInfo.isFile()) {
        setStatus(Online);
        setFileModifiedTime(fileInfo.lastModified());
        setFileSize(fileInfo.size());
    } else {
        setStatus(Offline);
    }
}

void Media::setFileModifiedTime(const QDateTime& modifiedTime)
{
    m_fileModifiedTime = modifiedTime;
    updateModifiedTime();
}

void Media::setFileSize(qint64 size)
{
    m_fileSize = size;
    updateModifiedTime();
}

Media::Type Media::detectType() const
{
    return detectTypeFromExtension(m_filename);
}

void Media::setType(Type type)
{
    if (m_type != type) {
        m_type = type;
        updateModifiedTime();
    }
}

void Media::setMetadata(const MediaMetadata& metadata)
{
    m_metadata = metadata;
    validateMetadata();
    updateModifiedTime();
}

void Media::setProxyPath(const QString& proxyPath)
{
    if (m_proxyPath != proxyPath) {
        m_proxyPath = proxyPath;
        updateModifiedTime();
    }
}

void Media::setThumbnailPath(const QString& thumbnailPath)
{
    if (m_thumbnailPath != thumbnailPath) {
        m_thumbnailPath = thumbnailPath;
        updateModifiedTime();
    }
}

void Media::setUseProxy(bool useProxy)
{
    if (m_useProxy != useProxy) {
        m_useProxy = useProxy;
        updateModifiedTime();
    }
}

QString Media::getEffectivePath() const
{
    if (m_useProxy && hasProxy()) {
        return m_proxyPath;
    }
    return m_filepath;
}

void Media::updateModifiedTime()
{
    m_modifiedAt = QDateTime::currentDateTime();
}

Media::Type Media::detectTypeFromExtension(const QString& filename) const
{
    QString extension = QFileInfo(filename).suffix().toLower();
    
    // Video extensions
    QStringList videoExts = {"mp4", "mov", "avi", "mkv", "wmv", "flv", "webm", 
                            "m4v", "3gp", "asf", "rm", "rmvb", "ts", "mts"};
    if (videoExts.contains(extension)) {
        return Video;
    }
    
    // Audio extensions
    QStringList audioExts = {"mp3", "wav", "aac", "flac", "ogg", "m4a", "wma", 
                            "aiff", "ac3", "dts", "opus"};
    if (audioExts.contains(extension)) {
        return Audio;
    }
    
    // Image extensions
    QStringList imageExts = {"jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", 
                            "webp", "svg", "ico", "psd", "exr", "hdr"};
    if (imageExts.contains(extension)) {
        return Image;
    }
    
    return UnknownType;
}

void Media::validateMetadata()
{
    // Ensure metadata values are reasonable
    if (m_metadata.duration < 0) {
        m_metadata.duration = 0;
    }
    
    if (m_metadata.width < 0) {
        m_metadata.width = 0;
    }
    
    if (m_metadata.height < 0) {
        m_metadata.height = 0;
    }
    
    if (m_metadata.framerate < 0 || m_metadata.framerate > 1000) {
        m_metadata.framerate = 0; // Invalid framerate
    }
    
    if (m_metadata.bitrate < 0) {
        m_metadata.bitrate = 0;
    }
}