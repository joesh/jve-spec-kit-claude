#include "uuid_generator.h"
#include <QElapsedTimer>
#include <QDebug>
#include <QDateTime>

Q_LOGGING_CATEGORY(jveUuidGenerator, "jve.core.uuid")

// Static member initialization
UuidGenerator* UuidGenerator::s_instance = nullptr;

// Namespace UUIDs for deterministic generation (fixed UUIDs for each entity type)
const QHash<UuidGenerator::EntityType, QString> UuidGenerator::s_namespaceUuids = {
    {ProjectEntity, "6ba7b810-9dad-11d1-80b4-00c04fd430c8"},  // Standard namespace UUID variant
    {MediaEntity,   "6ba7b811-9dad-11d1-80b4-00c04fd430c8"},
    {CommandEntity, "6ba7b812-9dad-11d1-80b4-00c04fd430c8"},
    {UIEntity,      "6ba7b813-9dad-11d1-80b4-00c04fd430c8"},
    {SystemEntity,  "6ba7b814-9dad-11d1-80b4-00c04fd430c8"},
    {GenericEntity, "6ba7b815-9dad-11d1-80b4-00c04fd430c8"}
};

UuidGenerator::UuidGenerator(QObject* parent)
    : QObject(parent)
    , m_generator(*QRandomGenerator::global())
{
    qCDebug(jveUuidGenerator, "UuidGenerator initialized");
}

UuidGenerator* UuidGenerator::instance()
{
    if (!s_instance) {
        s_instance = new UuidGenerator();
    }
    return s_instance;
}

void UuidGenerator::setGenerationMode(GenerationMode mode)
{
    QMutexLocker locker(&m_mutex);
    
    if (m_mode != mode) {
        GenerationMode oldMode = m_mode;
        m_mode = mode;
        
        qCDebug(jveUuidGenerator, "Generation mode changed from %d to %d", oldMode, mode);
        
        // Reset state when changing modes
        if (mode == TestingMode && !m_isSeeded) {
            // Set a default seed for testing mode
            setSeed(12345);
        }
        
        emit generationModeChanged(mode);
    }
}

UuidGenerator::GenerationMode UuidGenerator::getGenerationMode() const
{
    QMutexLocker locker(&m_mutex);
    return m_mode;
}

void UuidGenerator::setSeed(quint32 seed)
{
    QMutexLocker locker(&m_mutex);
    
    m_currentSeed = seed;
    m_generator.seed(seed);
    m_isSeeded = true;
    
    // Clear previous generation history when reseeding
    clearUuidHistory();
    
    qCDebug(jveUuidGenerator, "UUID generator seeded with: %u", seed);
}

void UuidGenerator::resetSeed()
{
    QMutexLocker locker(&m_mutex);
    
    m_generator = QRandomGenerator(*QRandomGenerator::global());
    m_isSeeded = false;
    m_currentSeed = 0;
    
    qCDebug(jveUuidGenerator, "UUID generator seed reset to random");
}

QString UuidGenerator::generateUuid(EntityType type)
{
    QElapsedTimer timer;
    if (m_performanceMonitoringEnabled) {
        timer.start();
    }
    
    QMutexLocker locker(&m_mutex);
    
    QString uuid;
    
    switch (m_mode) {
    case ProductionMode:
        uuid = generateProductionUuid(type);
        break;
    case TestingMode:
        uuid = generateTestingUuid(type);
        break;
    case DebuggingMode:
        uuid = generateDebuggingUuid(type);
        break;
    }
    
    // Record the generated UUID
    recordGeneratedUuid(uuid, type);
    
    // Check for collisions if enabled
    if (m_collisionDetectionEnabled && checkForCollision(uuid)) {
        emit collisionDetected(uuid, type);
        qCWarning(jveUuidGenerator, "UUID collision detected: %s", qPrintable(uuid));
    }
    
    // Record performance
    if (m_performanceMonitoringEnabled) {
        recordGenerationTime(timer.nsecsElapsed() / 1000000.0); // Convert to milliseconds
    }
    
    emit uuidGenerated(uuid, type);
    
    return uuid;
}

QString UuidGenerator::generateUuidWithPrefix(const QString& prefix, EntityType type)
{
    QString uuid = generateUuid(type);
    return prefix + "_" + uuid;
}

QUuid UuidGenerator::generateQUuid(EntityType type)
{
    QString uuidString = generateUuid(type);
    return QUuid::fromString(uuidString);
}

QString UuidGenerator::generateProjectUuid()
{
    return generateUuid(ProjectEntity);
}

QString UuidGenerator::generateMediaUuid()
{
    return generateUuid(MediaEntity);
}

QString UuidGenerator::generateCommandUuid()
{
    return generateUuid(CommandEntity);
}

QString UuidGenerator::generateUIUuid()
{
    return generateUuid(UIEntity);
}

QString UuidGenerator::generateSystemUuid()
{
    return generateUuid(SystemEntity);
}

QString UuidGenerator::generateProductionUuid(EntityType type)
{
    Q_UNUSED(type)
    // In production mode, use Qt's secure random UUID generation
    return QUuid::createUuid().toString(QUuid::WithoutBraces);
}

QString UuidGenerator::generateTestingUuid(EntityType type)
{
    // In testing mode, use deterministic generation based on seed and namespace
    QString namespaceUuid = getNamespaceUuid(type);
    QString data = QString("%1-%2-%3")
                     .arg(namespaceUuid)
                     .arg(m_generationCounts.value(type, 0))
                     .arg(m_currentSeed);
    
    // Create a deterministic UUID using SHA-256 hash
    QCryptographicHash hash(QCryptographicHash::Sha256);
    hash.addData(data.toUtf8());
    QByteArray hashResult = hash.result();
    
    // Format as UUID: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    QString uuid = QString("%1-%2-%3-%4-%5")
                     .arg(QString::fromLatin1(hashResult.left(4).toHex()))
                     .arg(QString::fromLatin1(hashResult.mid(4, 2).toHex()))
                     .arg(QString::fromLatin1(hashResult.mid(6, 2).toHex()))
                     .arg(QString::fromLatin1(hashResult.mid(8, 2).toHex()))
                     .arg(QString::fromLatin1(hashResult.mid(10, 6).toHex()));
    
    return uuid;
}

QString UuidGenerator::generateDebuggingUuid(EntityType type)
{
    // In debugging mode, use predictable sequential patterns
    QString prefix = getUuidPrefix(type);
    int count = m_generationCounts.value(type, 0);
    
    // Format: PREFIX-0000-0000-0000-000000000COUNT
    return QString("%1-%2-%3-%4-%5")
            .arg(prefix)
            .arg("0000")
            .arg("0000") 
            .arg("0000")
            .arg(QString("%1").arg(count, 12, 10, QChar('0')));
}

QString UuidGenerator::getNamespaceUuid(EntityType type) const
{
    return s_namespaceUuids.value(type, s_namespaceUuids.value(GenericEntity));
}

QString UuidGenerator::getUuidPrefix(EntityType type) const
{
    switch (type) {
    case ProjectEntity: return "PROJ";
    case MediaEntity:   return "MEDA";
    case CommandEntity: return "CMND";
    case UIEntity:      return "UIEL";
    case SystemEntity:  return "SYST";
    case GenericEntity: return "GENR";
    default:           return "UNKN";
    }
}

void UuidGenerator::recordGeneratedUuid(const QString& uuid, EntityType type)
{
    // Update generation count
    m_generationCounts[type] = m_generationCounts.value(type, 0) + 1;
    
    // Store in history (with size limit)
    if (!m_generatedUuids.contains(type)) {
        m_generatedUuids[type] = QStringList();
    }
    
    QStringList& history = m_generatedUuids[type];
    history.append(uuid);
    
    // Limit history size
    while (history.size() > MAX_UUID_HISTORY) {
        QString removed = history.takeFirst();
        m_allGeneratedUuids.remove(removed);
    }
    
    // Add to global set
    m_allGeneratedUuids.insert(uuid);
}

bool UuidGenerator::checkForCollision(const QString& uuid) const
{
    return m_allGeneratedUuids.contains(uuid);
}

bool UuidGenerator::isValidUuid(const QString& uuid) const
{
    QUuid testUuid = QUuid::fromString(uuid);
    return !testUuid.isNull();
}

bool UuidGenerator::isUniqueUuid(const QString& uuid) const
{
    QMutexLocker locker(&m_mutex);
    return !m_allGeneratedUuids.contains(uuid);
}

UuidGenerator::EntityType UuidGenerator::getEntityType(const QString& uuid) const
{
    // In debugging mode, we can extract the type from the prefix
    if (m_mode == DebuggingMode) {
        QString prefix = uuid.split('-').first();
        if (prefix == "PROJ") return ProjectEntity;
        if (prefix == "MEDA") return MediaEntity;
        if (prefix == "CMND") return CommandEntity;
        if (prefix == "UIEL") return UIEntity;
        if (prefix == "SYST") return SystemEntity;
    }
    
    // For other modes, we'd need to track the mapping separately
    // This is a simplified implementation
    return GenericEntity;
}

void UuidGenerator::enableCollisionDetection(bool enabled)
{
    QMutexLocker locker(&m_mutex);
    m_collisionDetectionEnabled = enabled;
    qCDebug(jveUuidGenerator, "Collision detection: %s", enabled ? "enabled" : "disabled");
}

void UuidGenerator::clearUuidHistory()
{
    m_generatedUuids.clear();
    m_generationCounts.clear();
    m_allGeneratedUuids.clear();
    qCDebug(jveUuidGenerator, "UUID generation history cleared");
}

QStringList UuidGenerator::getGeneratedUuids(EntityType type) const
{
    QMutexLocker locker(&m_mutex);
    return m_generatedUuids.value(type);
}

int UuidGenerator::getGenerationCount(EntityType type) const
{
    QMutexLocker locker(&m_mutex);
    return m_generationCounts.value(type, 0);
}

void UuidGenerator::startPerformanceMonitoring()
{
    QMutexLocker locker(&m_mutex);
    m_performanceMonitoringEnabled = true;
    m_generationTimes.clear();
    qCDebug(jveUuidGenerator, "Performance monitoring started");
}

void UuidGenerator::stopPerformanceMonitoring()
{
    QMutexLocker locker(&m_mutex);
    m_performanceMonitoringEnabled = false;
    qCDebug(jveUuidGenerator, "Performance monitoring stopped");
}

qreal UuidGenerator::getAverageGenerationTime() const
{
    QMutexLocker locker(&m_mutex);
    
    if (m_generationTimes.isEmpty()) {
        return 0.0;
    }
    
    qreal total = 0.0;
    for (qreal time : m_generationTimes) {
        total += time;
    }
    
    return total / m_generationTimes.size();
}

void UuidGenerator::recordGenerationTime(qreal timeMs)
{
    m_generationTimes.append(timeMs);
    
    // Limit sample size
    while (m_generationTimes.size() > MAX_PERFORMANCE_SAMPLES) {
        m_generationTimes.removeFirst();
    }
}