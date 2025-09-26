#pragma once

#include <QString>
#include <QVariant>
#include <QVariantMap>
#include <QJsonObject>
#include <QDateTime>
#include <QSqlDatabase>
#include <QSqlQuery>
#include <QList>

/**
 * Command: Deterministic operation logging for constitutional replay
 * 
 * Constitutional requirements:
 * - Deterministic serialization for identical replay results
 * - Command execution with undo/redo capability
 * - Sequence management and integrity validation
 * - Performance optimization for batch operations
 * - Constitutional compliance with state hash validation
 * 
 * Engineering Rules:
 * - Rule 2.14: No hardcoded constants (uses schema_constants.h)
 * - Rule 2.26: Functions read like algorithms calling subfunctions
 * - Rule 2.27: Short, focused functions with single responsibilities
 */
class Command
{
public:
    enum CommandStatus {
        Created,
        Executed,
        Undone,
        Failed
    };

    // Construction and factory
    static Command create(const QString& type, const QString& projectId);
    static Command deserialize(const QString& serializedData);
    static QList<Command> loadByProject(const QString& projectId, QSqlDatabase& database);
    static Command parseCommandFromQuery(QSqlQuery& query);
    
    // Core accessors
    QString id() const { return m_id; }
    QString type() const { return m_type; }
    QString projectId() const { return m_projectId; }
    int sequenceNumber() const { return m_sequenceNumber; }
    CommandStatus status() const { return m_status; }
    QDateTime createdAt() const { return m_createdAt; }
    QDateTime executedAt() const { return m_executedAt; }
    
    // Parameter management
    void setParameter(const QString& key, const QVariant& value);
    QVariant getParameter(const QString& key) const;
    QVariantMap getAllParameters() const { return m_parameters; }
    
    // Metadata management
    void setMetadata(const QJsonObject& metadata);
    QJsonObject getMetadata() const { return m_metadata; }
    
    // State management  
    void setPreHash(const QString& hash) { m_preHash = hash; }
    void setPostHash(const QString& hash) { m_postHash = hash; }
    QString preHash() const { return m_preHash; }
    QString postHash() const { return m_postHash; }
    
    // Execution state
    void setSequenceNumber(int number);
    void setStatus(CommandStatus status);
    void setExecutedAt(const QDateTime& timestamp);
    
    // Command operations
    Command createUndo() const;
    QString serialize() const;
    
    // Persistence
    bool save(QSqlDatabase& database);
    
private:
    Command() = default;
    explicit Command(const QString& id, const QString& type, const QString& projectId);
    
    // Algorithm implementations
    QString generateUniqueId();
    Command createUndoCommand() const;
    QJsonObject serializeToJson() const;
    bool parseFromJson(const QJsonObject& json);
    bool saveToDatabase(QSqlDatabase& database);
    CommandStatus stringToStatus(const QString& statusStr) const;
    QString statusToString(CommandStatus status) const;
    
    // Core state
    QString m_id;
    QString m_type;
    QString m_projectId;
    int m_sequenceNumber = 0;
    CommandStatus m_status = Created;
    
    // Timestamps
    QDateTime m_createdAt;
    QDateTime m_executedAt;
    
    // Data
    QVariantMap m_parameters;
    QJsonObject m_metadata;
    
    // State hashing
    QString m_preHash;
    QString m_postHash;
};

/**
 * ExecutionResult: Result of command execution
 */
struct ExecutionResult {
    bool success = false;
    QString errorMessage;
    QString resultData;
};

/**
 * ReplayResult: Result of command sequence replay
 */
struct ReplayResult {
    bool success = false;
    int commandsReplayed = 0;
    QString errorMessage;
    QStringList failedCommands;
};