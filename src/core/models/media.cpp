#include "media.h"

#include <QUuid>
#include <QSqlQuery>
#include <QSqlError>
#include <QLoggingCategory>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>

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
    
    // Set minimum valid values to satisfy schema constraints
    media.m_metadata.duration = 1000; // 1 second minimum
    media.m_metadata.framerate = 30.0; // Default framerate
    
    qCDebug(jveMedia, "Created media: %s at path: %s", qPrintable(filename), qPrintable(filepath));
    return media;
}

Media Media::load(const QString& id, const QSqlDatabase& database)
{
    // Algorithm: Query database → Parse results → Construct object
    QSqlQuery query(database);
    query.prepare(R"(
        SELECT id, file_path, file_name, duration, frame_rate, metadata
        FROM media WHERE id = ?
    )");
    query.addBindValue(id);
    
    if (!query.exec()) {
        qCWarning(jveMedia, "Failed to load media: %s", qPrintable(query.lastError().text()));
        return Media();
    }
    
    if (!query.next()) {
        qCDebug(jveMedia, "Media not found: %s", qPrintable(id));
        return Media();
    }
    
    Media media;
    media.m_id = query.value("id").toString();
    media.m_filepath = query.value("file_path").toString();
    media.m_filename = query.value("file_name").toString();
    media.m_metadata.duration = query.value("duration").toLongLong();
    media.m_metadata.framerate = query.value("frame_rate").toDouble();
    
    // Parse JSON metadata
    QString metadataJson = query.value("metadata").toString();
    QJsonDocument metadataDoc = QJsonDocument::fromJson(metadataJson.toUtf8());
    QJsonObject metadataObj = metadataDoc.object();
    
    // Load extended metadata from JSON
    media.m_metadata.width = metadataObj["width"].toInt();
    media.m_metadata.height = metadataObj["height"].toInt();
    media.m_metadata.videoCodec = metadataObj["videoCodec"].toString();
    media.m_metadata.audioCodec = metadataObj["audioCodec"].toString();
    media.m_metadata.bitrate = metadataObj["bitrate"].toInt();
    media.m_status = static_cast<Status>(metadataObj["status"].toInt());
    media.m_type = static_cast<Type>(metadataObj["type"].toInt());
    media.m_createdAt = QDateTime::fromSecsSinceEpoch(metadataObj["createdAt"].toVariant().toLongLong());
    media.m_modifiedAt = QDateTime::fromSecsSinceEpoch(metadataObj["modifiedAt"].toVariant().toLongLong());
    media.m_fileModifiedTime = QDateTime::fromSecsSinceEpoch(metadataObj["fileModifiedTime"].toVariant().toLongLong());
    media.m_fileSize = metadataObj["fileSize"].toVariant().toLongLong();
    media.m_proxyPath = metadataObj["proxyPath"].toString();
    media.m_thumbnailPath = metadataObj["thumbnailPath"].toString();
    media.m_useProxy = metadataObj["useProxy"].toBool();
    
    media.validateMetadata();
    
    qCDebug(jveMedia, "Loaded media: %s", qPrintable(media.m_filename));
    return media;
}

bool Media::save(const QSqlDatabase& database)
{
    // Algorithm: Validate data → Execute insert/update → Update timestamps
    if (!isValid()) {
        qCWarning(jveMedia, "Cannot save invalid media");
        return false;
    }
    
    updateModifiedTime();
    
    QSqlQuery query(database);
    QString sqlStatement = R"(
        INSERT OR REPLACE INTO media 
        (id, file_path, file_name, duration, frame_rate, metadata)
        VALUES (?, ?, ?, ?, ?, ?)
    )";
    
    if (!query.prepare(sqlStatement)) {
        qCWarning(jveMedia, "Failed to prepare query: %s", qPrintable(query.lastError().text()));
        qCWarning(jveMedia, "SQL was: %s", qPrintable(sqlStatement));
        return false;
    }
    
    query.addBindValue(m_id);
    query.addBindValue(m_filepath);
    query.addBindValue(m_filename);
    query.addBindValue(m_metadata.duration);
    query.addBindValue(m_metadata.framerate); // Schema now uses REAL
    
    // Serialize all additional metadata to JSON
    QJsonObject metadataObj;
    metadataObj["width"] = m_metadata.width;
    metadataObj["height"] = m_metadata.height;
    metadataObj["videoCodec"] = m_metadata.videoCodec;
    metadataObj["audioCodec"] = m_metadata.audioCodec;
    metadataObj["bitrate"] = m_metadata.bitrate;
    metadataObj["status"] = static_cast<int>(m_status);
    metadataObj["type"] = static_cast<int>(m_type);
    metadataObj["createdAt"] = m_createdAt.toSecsSinceEpoch();
    metadataObj["modifiedAt"] = m_modifiedAt.toSecsSinceEpoch();
    metadataObj["fileModifiedTime"] = m_fileModifiedTime.toSecsSinceEpoch();
    metadataObj["fileSize"] = m_fileSize;
    metadataObj["proxyPath"] = m_proxyPath;
    metadataObj["thumbnailPath"] = m_thumbnailPath;
    metadataObj["useProxy"] = m_useProxy;
    
    query.addBindValue(QJsonDocument(metadataObj).toJson(QJsonDocument::Compact));
    
    qCDebug(jveMedia, "SQL: %s", qPrintable(query.lastQuery()));
    qCDebug(jveMedia, "Parameter count: %lld", (long long)query.boundValues().size());
    
    if (!query.exec()) {
        qCWarning(jveMedia, "Failed to save media: %s", qPrintable(query.lastError().text()));
        qCWarning(jveMedia, "SQL was: %s", qPrintable(query.lastQuery()));
        qCWarning(jveMedia, "Bound values: %s", qPrintable(QVariant(query.boundValues()).toString()));
        return false;
    }
    
    qCDebug(jveMedia, "Saved media: %s", qPrintable(m_filename));
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