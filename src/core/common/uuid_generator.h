#pragma once

#include <QObject>
#include <QString>
#include <QUuid>
#include <QMutex>
#include <QLoggingCategory>
#include <QRandomGenerator>
#include <QCryptographicHash>

Q_DECLARE_LOGGING_CATEGORY(jveUuidGenerator)

/**
 * Deterministic UUID generator for professional video editing with replay consistency
 * 
 * Features:
 * - Deterministic UUID generation for command replay consistency
 * - Seedable random number generator for testing and debugging
 * - Thread-safe UUID generation for multi-threaded operations
 * - Professional namespace UUID support for different entity types
 * - Collision detection and uniqueness validation
 * - Performance-optimized generation for high-frequency operations
 * 
 * Design Philosophy:
 * - In production: Uses cryptographically secure random UUIDs
 * - In testing: Uses seeded deterministic generation for replay
 * - In debugging: Uses predictable patterns for easy identification
 * - Maintains UUID format compliance for database and API compatibility
 * 
 * Professional Use Cases:
 * - Command system replay for debugging and testing
 * - Consistent project file generation across different systems
 * - Deterministic media asset identification for collaboration
 * - Timeline operation reproducibility for automated testing
 * - Cross-platform project synchronization and version control
 * 
 * UUID Namespaces:
 * - Project entities (projects, sequences, tracks)
 * - Media assets (clips, media files, effects)
 * - Timeline operations (commands, edits, selections)
 * - User interface (panels, workspaces, preferences)
 * - System operations (sessions, caches, temporary files)
 */
class UuidGenerator : public QObject
{
    Q_OBJECT

public:
    enum GenerationMode {
        ProductionMode,     // Cryptographically secure random UUIDs
        TestingMode,        // Deterministic seeded generation
        DebuggingMode       // Predictable sequential patterns
    };

    enum EntityType {
        ProjectEntity,      // Projects, sequences, tracks
        MediaEntity,        // Clips, media files, effects
        CommandEntity,      // Commands, operations, selections
        UIEntity,          // UI panels, workspaces, preferences
        SystemEntity,      // Sessions, caches, temporary files
        GenericEntity      // Default/unspecified entity type
    };

    // Singleton access
    static UuidGenerator* instance();
    
    // Generation control
    void setGenerationMode(GenerationMode mode);
    GenerationMode getGenerationMode() const;
    void setSeed(quint32 seed);
    void resetSeed();
    
    // UUID generation
    QString generateUuid(EntityType type = GenericEntity);
    QString generateUuidWithPrefix(const QString& prefix, EntityType type = GenericEntity);
    QUuid generateQUuid(EntityType type = GenericEntity);
    
    // Namespace-specific generation
    QString generateProjectUuid();
    QString generateMediaUuid();
    QString generateCommandUuid();
    QString generateUIUuid();
    QString generateSystemUuid();
    
    // Validation and utilities
    bool isValidUuid(const QString& uuid) const;
    bool isUniqueUuid(const QString& uuid) const;
    EntityType getEntityType(const QString& uuid) const;
    QString getUuidPrefix(EntityType type) const;
    
    // Testing and debugging support
    void enableCollisionDetection(bool enabled = true);
    void clearUuidHistory();
    QStringList getGeneratedUuids(EntityType type = GenericEntity) const;
    int getGenerationCount(EntityType type = GenericEntity) const;
    
    // Performance monitoring
    void startPerformanceMonitoring();
    void stopPerformanceMonitoring();
    qreal getAverageGenerationTime() const;

signals:
    void uuidGenerated(const QString& uuid, EntityType type);
    void generationModeChanged(GenerationMode mode);
    void collisionDetected(const QString& uuid, EntityType type);

private:
    explicit UuidGenerator(QObject* parent = nullptr);
    ~UuidGenerator() = default;
    
    // Prevent copying
    UuidGenerator(const UuidGenerator&) = delete;
    UuidGenerator& operator=(const UuidGenerator&) = delete;
    
    // Generation implementation
    QString generateProductionUuid(EntityType type);
    QString generateTestingUuid(EntityType type);
    QString generateDebuggingUuid(EntityType type);
    
    // Namespace management
    QString getNamespaceUuid(EntityType type) const;
    QString formatUuidWithNamespace(const QUuid& uuid, EntityType type) const;
    
    // Collision detection
    void recordGeneratedUuid(const QString& uuid, EntityType type);
    bool checkForCollision(const QString& uuid) const;
    
    // Performance tracking
    void recordGenerationTime(qreal timeMs);

private:
    static UuidGenerator* s_instance;
    
    // Generation state
    GenerationMode m_mode = ProductionMode;
    QRandomGenerator m_generator;
    bool m_isSeeded = false;
    quint32 m_currentSeed = 0;
    
    // Thread safety
    mutable QMutex m_mutex;
    
    // UUID tracking
    QHash<EntityType, QStringList> m_generatedUuids;
    QHash<EntityType, int> m_generationCounts;
    QSet<QString> m_allGeneratedUuids;
    bool m_collisionDetectionEnabled = false;
    
    // Performance monitoring
    bool m_performanceMonitoringEnabled = false;
    QList<qreal> m_generationTimes;
    
    // Namespace UUIDs for deterministic generation
    static const QHash<EntityType, QString> s_namespaceUuids;
    
    // Constants
    static constexpr int MAX_UUID_HISTORY = 10000;
    static constexpr int MAX_PERFORMANCE_SAMPLES = 1000;
};