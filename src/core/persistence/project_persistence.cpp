#include "project_persistence.h"
#include "migrations.h"
#include "schema_constants.h"

#include <QFileInfo>
#include <QDir>
#include <QSqlQuery>
#include <QSqlError>
#include <QLoggingCategory>
#include <QDebug>
#include <QDateTime>
#include <QStandardPaths>
#include <QLockFile>
#include <QThread>
#include <QSqlDatabase>

Q_LOGGING_CATEGORY(jvePersistence, "jve.persistence")

ProjectPersistence::ProjectPersistence(QObject* parent)
    : QObject(parent)
{
    qCDebug(jvePersistence) << "Initializing ProjectPersistence";
}

ProjectPersistence::~ProjectPersistence()
{
    // Algorithm: Release all locks → Cleanup resources
    for (auto it = m_activeLocks.begin(); it != m_activeLocks.end(); ++it) {
        releaseFileLock(it.key());
    }
}

PersistenceResult ProjectPersistence::saveProject(const QString& filePath, const ProjectData& data)
{
    qCDebug(jvePersistence) << "Saving project to:" << filePath;
    
    // Algorithm: Validate → Lock → Backup → Save → Unlock → Return result
    PersistenceResult result;
    
    if (!validateJveExtension(filePath)) {
        result.success = false;
        result.errorMessage = "Invalid file extension. Project files must have .jve extension.";
        return result;
    }
    
    if (!acquireFileLock(filePath)) {
        result.success = false;
        result.errorMessage = "Cannot acquire file lock. Project may be open in another instance.";
        return result;
    }
    
    // Create backup before saving
    if (QFile::exists(filePath)) {
        if (!createBackupBeforeSave(filePath)) {
            qCWarning(jvePersistence) << "Failed to create backup, but continuing with save";
        }
    }
    
    result = performAtomicSave(filePath, data);
    
    if (result.success) {
        cleanupOldBackups(filePath);
    }
    
    releaseFileLock(filePath);
    return result;
}

PersistenceResult ProjectPersistence::loadProject(const QString& filePath)
{
    qCDebug(jvePersistence) << "Loading project from:" << filePath;
    
    // Algorithm: Validate → Load → Return result
    PersistenceResult result;
    
    if (!QFile::exists(filePath)) {
        result.success = false;
        result.errorMessage = "Project file does not exist.";
        return result;
    }
    
    if (!validateJveExtension(filePath)) {
        result.success = false;
        result.errorMessage = "Invalid file extension. Expected .jve file.";
        return result;
    }
    
    return performAtomicLoad(filePath);
}

bool ProjectPersistence::validateFileFormat(const QString& filePath) const
{
    qCDebug(jvePersistence) << "Validating file format:" << filePath;
    
    // Algorithm: Check extension → Verify headers → Validate structure
    if (!validateJveExtension(filePath)) {
        return false;
    }
    
    QSqlDatabase testDb = QSqlDatabase::addDatabase("QSQLITE", 
        QString("validation_%1").arg(QDateTime::currentMSecsSinceEpoch()));
    testDb.setDatabaseName(filePath);
    
    if (!testDb.open()) {
        QSqlDatabase::removeDatabase(testDb.connectionName());
        return false;
    }
    
    // Check for required tables
    QSqlQuery query(testDb);
    query.exec("SELECT name FROM sqlite_master WHERE type='table' AND name='schema_version'");
    
    bool hasSchemaTable = query.next();
    testDb.close();
    QSqlDatabase::removeDatabase(testDb.connectionName());
    
    return hasSchemaTable;
}

PersistenceResult ProjectPersistence::createOldVersionFile(const QString& filePath, int version)
{
    qCDebug(jvePersistence) << "Creating old version file:" << filePath << "version:" << version;
    
    // Algorithm: Create database → Set version → Return result
    PersistenceResult result;
    
    QSqlDatabase db = QSqlDatabase::addDatabase("QSQLITE", 
        QString("oldversion_%1").arg(QDateTime::currentMSecsSinceEpoch()));
    db.setDatabaseName(filePath);
    
    if (!db.open()) {
        result.success = false;
        result.errorMessage = "Failed to create old version file";
        return result;
    }
    
    QSqlQuery query(db);
    query.exec("CREATE TABLE schema_version (version INTEGER PRIMARY KEY)");
    query.prepare("INSERT INTO schema_version (version) VALUES (?)");
    query.addBindValue(version);
    
    result.success = query.exec();
    if (!result.success) {
        result.errorMessage = query.lastError().text();
    }
    
    db.close();
    QSqlDatabase::removeDatabase(db.connectionName());
    
    return result;
}

QStringList ProjectPersistence::findBackupFiles(const QString& projectPath) const
{
    qCDebug(jvePersistence) << "Finding backup files for:" << projectPath;
    
    // Algorithm: Get directory → Filter backups → Return sorted list
    QFileInfo projectFile(projectPath);
    QDir projectDir = projectFile.dir();
    QString baseName = projectFile.baseName();
    
    QStringList nameFilters;
    nameFilters << QString("%1.backup.*.jve").arg(baseName);
    nameFilters << QString("%1.*.backup.jve").arg(baseName);
    
    QStringList backupFiles = projectDir.entryList(nameFilters, QDir::Files, QDir::Time);
    
    // Convert to full paths
    QStringList fullPaths;
    for (const QString& file : backupFiles) {
        fullPaths.append(projectDir.absoluteFilePath(file));
    }
    
    return fullPaths;
}

RecoveryResult ProjectPersistence::attemptRecovery(const QString& projectPath)
{
    qCDebug(jvePersistence) << "Attempting recovery for:" << projectPath;
    
    // Algorithm: Find backups → Try recovery → Return result
    RecoveryResult result;
    
    QStringList backupFiles = findBackupFiles(projectPath);
    if (backupFiles.isEmpty()) {
        result.success = false;
        result.errorMessage = "No backup files found for recovery";
        return result;
    }
    
    // Try most recent backup first
    for (const QString& backupPath : backupFiles) {
        if (validateFileFormat(backupPath)) {
            // Restore from backup
            if (QFile::remove(projectPath) && QFile::copy(backupPath, projectPath)) {
                result.success = true;
                result.usedBackup = true;
                result.backupPath = backupPath;
                qCInfo(jvePersistence) << "Successfully recovered from backup:" << backupPath;
                break;
            }
        }
    }
    
    if (!result.success) {
        result.errorMessage = "All backup files are corrupted or inaccessible";
    }
    
    return result;
}

QString ProjectPersistence::createManualBackup(const QString& projectPath, const QString& label)
{
    qCDebug(jvePersistence) << "Creating manual backup:" << projectPath << "label:" << label;
    
    // Algorithm: Generate path → Copy file → Return path
    QString backupPath = generateBackupPath(projectPath, label);
    
    if (QFile::copy(projectPath, backupPath)) {
        return backupPath;
    }
    
    return QString();
}

DatabaseInfo ProjectPersistence::getDatabaseInfo(const QString& projectPath) const
{
    qCDebug(jvePersistence) << "Getting database info for:" << projectPath;
    
    // Algorithm: Connect → Query info → Return structure
    DatabaseInfo info;
    
    QSqlDatabase db = QSqlDatabase::addDatabase("QSQLITE", 
        QString("dbinfo_%1").arg(QDateTime::currentMSecsSinceEpoch()));
    db.setDatabaseName(projectPath);
    
    if (db.open()) {
        QSqlQuery query(db);
        
        // Get journal mode
        query.exec("PRAGMA journal_mode");
        if (query.next()) {
            info.journalMode = query.value(0).toString().toLower();
        }
        
        // Get sync mode
        query.exec("PRAGMA synchronous");
        if (query.next()) {
            info.syncMode = query.value(0).toString();
        }
        
        // Get page info
        query.exec("PRAGMA page_size");
        if (query.next()) {
            info.pageSize = query.value(0).toLongLong();
        }
        
        query.exec("PRAGMA page_count");
        if (query.next()) {
            info.pageCount = query.value(0).toLongLong();
        }
        
        // WAL mode is acceptable if it's properly managed
        info.allowsWalMode = true;
        
        db.close();
    }
    
    QSqlDatabase::removeDatabase(db.connectionName());
    return info;
}

QStringList ProjectPersistence::getExternalDependencies(const ProjectData& data) const
{
    qCDebug(jvePersistence) << "Getting external dependencies";
    
    // Algorithm: Collect media paths → Filter valid → Return list
    QStringList dependencies;
    
    for (const Media& media : data.media) {
        QString path = media.filepath();
        if (!path.isEmpty() && QFile::exists(path)) {
            dependencies.append(path);
        }
    }
    
    return dependencies;
}

bool ProjectPersistence::validateJveExtension(const QString& filePath) const
{
    QFileInfo fileInfo(filePath);
    return fileInfo.suffix().toLower() == "jve";
}

PersistenceResult ProjectPersistence::performAtomicSave(const QString& filePath, const ProjectData& data)
{
    qCDebug(jvePersistence) << "Performing atomic save";
    
    // Algorithm: Create temp → Save to temp → Replace original → Return result
    PersistenceResult result;
    
    QString tempPath = filePath + ".tmp";
    
    // Remove temp file if it exists
    QFile::remove(tempPath);
    
    // Initialize database schema first (this creates its own connection)
    if (!Migrations::createNewProject(tempPath)) {
        QFile::remove(tempPath);
        result.success = false;
        result.errorMessage = "Failed to initialize database schema";
        return result;
    }
    
    // Create our own connection after the schema is created
    QSqlDatabase database;
    if (!createDatabaseConnection(tempPath, database)) {
        QFile::remove(tempPath);
        result.success = false;
        result.errorMessage = "Failed to create temporary database connection";
        return result;
    }
    
    // Save all data
    bool saveSuccess = saveProjectData(database, data);
    database.close();
    
    if (saveSuccess) {
        // Atomic replace: remove original and rename temp
        if (QFile::exists(filePath)) {
            QFile::remove(filePath);
        }
        
        if (QFile::rename(tempPath, filePath)) {
            result.success = true;
            emit saveProgress(100);
        } else {
            result.success = false;
            result.errorMessage = "Failed to replace project file atomically";
            QFile::remove(tempPath);
        }
    } else {
        result.success = false;
        result.errorMessage = "Failed to save project data";
        QFile::remove(tempPath);
    }
    
    return result;
}

PersistenceResult ProjectPersistence::performAtomicLoad(const QString& filePath)
{
    qCDebug(jvePersistence) << "Performing atomic load";
    
    // Algorithm: Connect → Load → Return result
    PersistenceResult result;
    
    QSqlDatabase database;
    if (!createDatabaseConnection(filePath, database)) {
        result.success = false;
        result.errorMessage = "Failed to open project database";
        return result;
    }
    
    ProjectData data = loadProjectData(database);
    database.close();
    
    if (!data.project.id().isEmpty()) {
        result.success = true;
        result.projectData = data;
        emit loadProgress(100);
    } else {
        result.success = false;
        result.errorMessage = "Failed to load project data";
    }
    
    return result;
}

bool ProjectPersistence::createDatabaseConnection(const QString& filePath, QSqlDatabase& database)
{
    QString connectionName = QString("project_%1_%2")
        .arg(QFileInfo(filePath).baseName())
        .arg(QDateTime::currentMSecsSinceEpoch());
    
    database = QSqlDatabase::addDatabase("QSQLITE", connectionName);
    database.setDatabaseName(filePath);
    
    if (!database.open()) {
        qCCritical(jvePersistence) << "Failed to open database:" << database.lastError().text();
        QSqlDatabase::removeDatabase(connectionName);
        return false;
    }
    
    return true;
}

bool ProjectPersistence::saveProjectData(QSqlDatabase& database, const ProjectData& data)
{
    qCDebug(jvePersistence) << "Saving project data";
    
    // Algorithm: Begin transaction → Save all → Commit → Return success
    database.transaction();
    
    bool success = true;
    success &= saveProjectToDatabase(database, data.project);
    success &= saveSequencesToDatabase(database, data.sequences);
    success &= saveTracksToDatabase(database, data.tracks);
    success &= saveMediaToDatabase(database, data.media);
    success &= saveClipsToDatabase(database, data.clips);
    
    if (success) {
        database.commit();
        qCDebug(jvePersistence) << "Successfully saved all project data";
    } else {
        database.rollback();
        qCWarning(jvePersistence) << "Failed to save project data, rolled back transaction";
    }
    
    return success;
}

ProjectData ProjectPersistence::loadProjectData(QSqlDatabase& database)
{
    qCDebug(jvePersistence) << "Loading project data";
    
    // Algorithm: Load project → Load related data → Return structure
    ProjectData data;
    
    data.project = loadProjectFromDatabase(database);
    if (!data.project.id().isEmpty()) {
        QString projectId = data.project.id();
        
        data.sequences = loadSequencesFromDatabase(database, projectId);
        data.tracks = loadTracksFromDatabase(database, projectId);
        data.clips = loadClipsFromDatabase(database, projectId);
        data.media = loadMediaFromDatabase(database);
        
        emit loadProgress(100);
    }
    
    return data;
}

bool ProjectPersistence::createBackupBeforeSave(const QString& filePath)
{
    QString backupPath = generateBackupPath(filePath);
    return QFile::copy(filePath, backupPath);
}

void ProjectPersistence::cleanupOldBackups(const QString& projectPath)
{
    QStringList backupFiles = findBackupFiles(projectPath);
    
    // Keep only the most recent backups
    if (backupFiles.size() > MAX_BACKUP_COUNT) {
        // Remove oldest backups
        for (int i = MAX_BACKUP_COUNT; i < backupFiles.size(); i++) {
            QFile::remove(backupFiles[i]);
        }
    }
}

QString ProjectPersistence::generateBackupPath(const QString& projectPath, const QString& label) const
{
    QFileInfo projectFile(projectPath);
    QDir projectDir = projectFile.dir();
    QString baseName = projectFile.baseName();
    
    QString timestamp = QDateTime::currentDateTime().toString("yyyyMMdd_hhmmss");
    QString backupName;
    
    if (!label.isEmpty()) {
        backupName = QString("%1.%2.%3.backup.jve").arg(baseName, label, timestamp);
    } else {
        backupName = QString("%1.backup.%2.jve").arg(baseName, timestamp);
    }
    
    return projectDir.absoluteFilePath(backupName);
}

bool ProjectPersistence::acquireFileLock(const QString& filePath)
{
    QString lockFile = filePath + ".lock";
    QString lockId = QString("lock_%1").arg(QDateTime::currentMSecsSinceEpoch());
    
    // For simplicity in M1 Foundation, use basic file existence check
    if (QFile::exists(lockFile)) {
        return false; // Already locked
    }
    
    QFile lock(lockFile);
    if (lock.open(QIODevice::WriteOnly)) {
        lock.write(lockId.toUtf8());
        lock.close();
        m_activeLocks[filePath] = lockId;
        return true;
    }
    
    return false;
}

void ProjectPersistence::releaseFileLock(const QString& filePath)
{
    if (m_activeLocks.contains(filePath)) {
        QString lockFile = filePath + ".lock";
        QFile::remove(lockFile);
        m_activeLocks.remove(filePath);
    }
}

void ProjectPersistence::updateMemoryUsage(size_t currentUsage)
{
    if (currentUsage > m_peakMemoryUsage) {
        m_peakMemoryUsage = currentUsage;
    }
}

// Database save implementations
bool ProjectPersistence::saveProjectToDatabase(QSqlDatabase& database, const Project& project)
{
    Project mutableProject = project; // Create mutable copy
    return mutableProject.save(database);
}

bool ProjectPersistence::saveSequencesToDatabase(QSqlDatabase& database, const QList<Sequence>& sequences)
{
    for (const Sequence& sequence : sequences) {
        Sequence mutableSequence = sequence; // Create mutable copy
        if (!mutableSequence.save(database)) {
            return false;
        }
    }
    return true;
}

bool ProjectPersistence::saveTracksToDatabase(QSqlDatabase& database, const QList<Track>& tracks)
{
    for (const Track& track : tracks) {
        Track mutableTrack = track; // Create mutable copy
        if (!mutableTrack.save(database)) {
            return false;
        }
    }
    return true;
}

bool ProjectPersistence::saveClipsToDatabase(QSqlDatabase& database, const QList<Clip>& clips)
{
    for (const Clip& clip : clips) {
        Clip mutableClip = clip; // Create mutable copy
        if (!mutableClip.save(database)) {
            return false;
        }
    }
    return true;
}

bool ProjectPersistence::saveMediaToDatabase(QSqlDatabase& database, const QList<Media>& media)
{
    for (const Media& mediaItem : media) {
        Media mutableMedia = mediaItem; // Create mutable copy
        if (!mutableMedia.save(database)) {
            return false;
        }
    }
    return true;
}

// Database load implementations
Project ProjectPersistence::loadProjectFromDatabase(QSqlDatabase& database)
{
    QSqlQuery query(database);
    query.exec("SELECT * FROM projects ORDER BY created_at DESC LIMIT 1");
    
    if (query.next()) {
        QString id = query.value("id").toString();
        return Project::load(id, database);
    }
    
    return Project();
}

QList<Sequence> ProjectPersistence::loadSequencesFromDatabase(QSqlDatabase& database, const QString& projectId)
{
    QList<Sequence> sequences;
    
    QSqlQuery query(database);
    query.prepare("SELECT id FROM sequences WHERE project_id = ?");
    query.addBindValue(projectId);
    
    if (query.exec()) {
        while (query.next()) {
            QString sequenceId = query.value("id").toString();
            Sequence sequence = Sequence::load(sequenceId, database);
            if (!sequence.id().isEmpty()) {
                sequences.append(sequence);
            }
        }
    }
    
    return sequences;
}

QList<Track> ProjectPersistence::loadTracksFromDatabase(QSqlDatabase& database, const QString& projectId)
{
    QList<Track> tracks;
    
    QSqlQuery query(database);
    query.prepare(
        "SELECT t.id FROM tracks t "
        "JOIN sequences s ON t.sequence_id = s.id "
        "WHERE s.project_id = ?"
    );
    query.addBindValue(projectId);
    
    if (query.exec()) {
        while (query.next()) {
            QString trackId = query.value("id").toString();
            Track track = Track::load(trackId, database);
            if (!track.id().isEmpty()) {
                tracks.append(track);
            }
        }
    }
    
    return tracks;
}

QList<Clip> ProjectPersistence::loadClipsFromDatabase(QSqlDatabase& database, const QString& projectId)
{
    QList<Clip> clips;
    
    QSqlQuery query(database);
    query.prepare(
        "SELECT c.id FROM clips c "
        "JOIN tracks t ON c.track_id = t.id "
        "JOIN sequences s ON t.sequence_id = s.id "
        "WHERE s.project_id = ?"
    );
    query.addBindValue(projectId);
    
    if (query.exec()) {
        while (query.next()) {
            QString clipId = query.value("id").toString();
            Clip clip = Clip::load(clipId, database);
            if (!clip.id().isEmpty()) {
                clips.append(clip);
            }
        }
    }
    
    return clips;
}

QList<Media> ProjectPersistence::loadMediaFromDatabase(QSqlDatabase& database)
{
    QList<Media> mediaList;
    
    QSqlQuery query(database);
    query.exec("SELECT id FROM media");
    
    while (query.next()) {
        QString mediaId = query.value("id").toString();
        Media media = Media::load(mediaId, database);
        if (!media.id().isEmpty()) {
            mediaList.append(media);
        }
    }
    
    return mediaList;
}