#pragma once

#include "../models/project.h"
#include "../models/sequence.h"
#include "../models/track.h"
#include "../models/clip.h"
#include "../models/media.h"

#include <QObject>
#include <QString>
#include <QList>
#include <QSqlDatabase>
#include <QFileInfo>
#include <optional>
#include <future>

/**
 * Project persistence data structures
 */
struct ProjectData {
    Project project;
    QList<Sequence> sequences;
    QList<Track> tracks;
    QList<Clip> clips;
    QList<Media> media;
    
    ProjectData() = default;
};

struct PersistenceResult {
    bool success = false;
    QString errorMessage;
    std::optional<ProjectData> projectData;
};

struct MediaMetadata {
    qint64 duration = 0;
    int width = 0;
    int height = 0;
    double framerate = 0.0;
    QString codec;
    QString format;
};

struct RecoveryResult {
    bool success = false;
    bool usedBackup = false;
    QString backupPath;
    QString errorMessage;
};

struct DatabaseInfo {
    QString journalMode;
    QString syncMode;
    bool allowsWalMode = false;
    qint64 pageSize = 0;
    qint64 pageCount = 0;
};

/**
 * ProjectPersistence: Constitutional single-file project persistence
 * 
 * Constitutional requirements:
 * - Atomic save/load operations (all-or-nothing guarantee)
 * - Single-file .jve format with no sidecar files
 * - Concurrent access protection with file locking
 * - Automatic backup and recovery mechanisms
 * - Performance requirements for large projects
 * - Constitutional determinism and data integrity
 * 
 * Engineering Rules:
 * - Rule 2.14: No hardcoded constants (uses schema_constants.h)
 * - Rule 2.26: Functions read like algorithms calling subfunctions
 * - Rule 2.27: Short, focused functions with single responsibilities
 */
class ProjectPersistence : public QObject
{
    Q_OBJECT

public:
    explicit ProjectPersistence(QObject* parent = nullptr);
    ~ProjectPersistence() override;
    
    // Core persistence operations
    PersistenceResult saveProject(const QString& filePath, const ProjectData& data);
    PersistenceResult loadProject(const QString& filePath);
    
    // File validation
    bool validateFileFormat(const QString& filePath) const;
    PersistenceResult createOldVersionFile(const QString& filePath, int version);
    
    // Backup and recovery
    QStringList findBackupFiles(const QString& projectPath) const;
    RecoveryResult attemptRecovery(const QString& projectPath);
    QString createManualBackup(const QString& projectPath, const QString& label);
    
    // Constitutional compliance
    DatabaseInfo getDatabaseInfo(const QString& projectPath) const;
    QStringList getExternalDependencies(const ProjectData& data) const;
    
    // Performance monitoring
    size_t getPeakMemoryUsage() const { return m_peakMemoryUsage; }

signals:
    void saveProgress(int percentage);
    void loadProgress(int percentage);

private:
    // Algorithm implementations
    bool validateJveExtension(const QString& filePath) const;
    PersistenceResult performAtomicSave(const QString& filePath, const ProjectData& data);
    PersistenceResult performAtomicLoad(const QString& filePath);
    bool createDatabaseConnection(const QString& filePath, QSqlDatabase& database);
    bool saveProjectData(QSqlDatabase& database, const ProjectData& data);
    ProjectData loadProjectData(QSqlDatabase& database);
    bool createBackupBeforeSave(const QString& filePath);
    void cleanupOldBackups(const QString& projectPath);
    QString generateBackupPath(const QString& projectPath, const QString& label = "") const;
    bool acquireFileLock(const QString& filePath);
    void releaseFileLock(const QString& filePath);
    void updateMemoryUsage(size_t currentUsage);
    
    // Save/load implementations
    bool saveProjectToDatabase(QSqlDatabase& database, const Project& project);
    bool saveSequencesToDatabase(QSqlDatabase& database, const QList<Sequence>& sequences);
    bool saveTracksToDatabase(QSqlDatabase& database, const QList<Track>& tracks);
    bool saveClipsToDatabase(QSqlDatabase& database, const QList<Clip>& clips);
    bool saveMediaToDatabase(QSqlDatabase& database, const QList<Media>& media);
    
    Project loadProjectFromDatabase(QSqlDatabase& database);
    QList<Sequence> loadSequencesFromDatabase(QSqlDatabase& database, const QString& projectId);
    QList<Track> loadTracksFromDatabase(QSqlDatabase& database, const QString& projectId);
    QList<Clip> loadClipsFromDatabase(QSqlDatabase& database, const QString& projectId);
    QList<Media> loadMediaFromDatabase(QSqlDatabase& database);
    
    // File locking state
    QHash<QString, QString> m_activeLocks; // filepath -> lock identifier
    
    // Performance tracking
    mutable size_t m_peakMemoryUsage = 0;
    
    // Constants
    static const int MAX_BACKUP_COUNT = 5;
    static const qint64 LARGE_PROJECT_THRESHOLD = 10000000; // 10MB
};