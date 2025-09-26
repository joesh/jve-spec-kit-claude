#include "command.h"
#include "../persistence/schema_constants.h"

#include <QUuid>
#include <QJsonDocument>
#include <QSqlQuery>
#include <QSqlError>
#include <QLoggingCategory>
#include <QDebug>

Q_LOGGING_CATEGORY(jveCommand, "jve.command")

Command Command::create(const QString& type, const QString& projectId)
{
    qCDebug(jveCommand) << "Creating command:" << type << "for project:" << projectId;
    
    // Algorithm: Generate ID → Initialize → Set defaults → Return instance
    QString id = QUuid::createUuid().toString(QUuid::WithoutBraces);
    Command command(id, type, projectId);
    
    command.m_createdAt = QDateTime::currentDateTime();
    command.m_status = Created;
    
    return command;
}

Command Command::deserialize(const QString& serializedData)
{
    qCDebug(jveCommand) << "Deserializing command from JSON";
    
    // Algorithm: Parse JSON → Create instance → Set data → Return command
    QJsonDocument doc = QJsonDocument::fromJson(serializedData.toUtf8());
    if (doc.isNull() || !doc.isObject()) {
        qCWarning(jveCommand) << "Invalid JSON for command deserialization";
        return Command();
    }
    
    QJsonObject json = doc.object();
    Command command;
    
    if (!command.parseFromJson(json)) {
        qCWarning(jveCommand) << "Failed to parse command from JSON";
        return Command();
    }
    
    return command;
}

QList<Command> Command::loadByProject(const QString& projectId, QSqlDatabase& database)
{
    qCDebug(jveCommand) << "Loading commands for project:" << projectId;
    
    // Algorithm: Query → Parse each → Return sorted collection
    QSqlQuery query(database);
    query.prepare("SELECT * FROM commands WHERE 1=1 ORDER BY sequence_number"); // Project association via application logic
    
    QList<Command> commands;
    if (query.exec()) {
        while (query.next()) {
            Command command = parseCommandFromQuery(query);
            if (!command.id().isEmpty()) {
                commands.append(command);
            }
        }
    }
    
    return commands;
}

void Command::setParameter(const QString& key, const QVariant& value)
{
    m_parameters[key] = value;
}

QVariant Command::getParameter(const QString& key) const
{
    return m_parameters.value(key);
}

void Command::setMetadata(const QJsonObject& metadata)
{
    m_metadata = metadata;
}

void Command::setSequenceNumber(int number)
{
    m_sequenceNumber = number;
}

void Command::setStatus(CommandStatus status)
{
    m_status = status;
}

void Command::setExecutedAt(const QDateTime& timestamp)
{
    m_executedAt = timestamp;
}

Command Command::createUndo() const
{
    qCDebug(jveCommand) << "Creating undo command for:" << m_type;
    
    // Algorithm: Create opposite → Copy parameters → Swap values → Return undo
    Command undoCommand = Command::create(m_type, m_projectId);
    
    // Copy all parameters
    for (auto it = m_parameters.begin(); it != m_parameters.end(); ++it) {
        undoCommand.setParameter(it.key(), it.value());
    }
    
    // For property commands, swap value with previous_value
    if (m_type == "SetClipProperty" || m_type == "SetProperty") {
        QVariant currentValue = getParameter("value");
        QVariant previousValue = getParameter("previous_value");
        
        undoCommand.setParameter("value", previousValue);
        undoCommand.setParameter("previous_value", currentValue);
    }
    
    // Copy metadata
    undoCommand.setMetadata(m_metadata);
    
    return undoCommand;
}

QString Command::serialize() const
{
    qCDebug(jveCommand) << "Serializing command:" << m_type;
    
    // Algorithm: Create JSON object → Serialize → Return string
    QJsonObject json = serializeToJson();
    QJsonDocument doc(json);
    
    return QString::fromUtf8(doc.toJson(QJsonDocument::Compact));
}

bool Command::save(QSqlDatabase& database)
{
    qCDebug(jveCommand) << "Saving command:" << m_type;
    
    // Algorithm: Serialize parameters → Execute query → Return success
    return saveToDatabase(database);
}

Command::Command(const QString& id, const QString& type, const QString& projectId)
    : m_id(id), m_type(type), m_projectId(projectId)
{
}

QJsonObject Command::serializeToJson() const
{
    QJsonObject json;
    
    // Core properties
    json["id"] = m_id;
    json["type"] = m_type;
    json["project_id"] = m_projectId;
    json["sequence_number"] = m_sequenceNumber;
    json["status"] = statusToString(m_status);
    
    // Timestamps
    json["created_at"] = m_createdAt.toMSecsSinceEpoch();
    if (m_executedAt.isValid()) {
        json["executed_at"] = m_executedAt.toMSecsSinceEpoch();
    }
    
    // Parameters as nested object
    QJsonObject parametersObj;
    for (auto it = m_parameters.begin(); it != m_parameters.end(); ++it) {
        parametersObj[it.key()] = QJsonValue::fromVariant(it.value());
    }
    json["parameters"] = parametersObj;
    
    // Metadata
    if (!m_metadata.isEmpty()) {
        json["metadata"] = m_metadata;
    }
    
    // State hashes
    if (!m_preHash.isEmpty()) {
        json["pre_hash"] = m_preHash;
    }
    if (!m_postHash.isEmpty()) {
        json["post_hash"] = m_postHash;
    }
    
    return json;
}

bool Command::parseFromJson(const QJsonObject& json)
{
    // Algorithm: Extract fields → Validate → Set state → Return success
    if (!json.contains("id") || !json.contains("type")) {
        return false;
    }
    
    m_id = json["id"].toString();
    m_type = json["type"].toString();
    m_projectId = json["project_id"].toString();
    m_sequenceNumber = json["sequence_number"].toInt();
    m_status = stringToStatus(json["status"].toString());
    
    // Parse timestamps
    if (json.contains("created_at")) {
        qint64 timestamp = json["created_at"].toVariant().toLongLong();
        m_createdAt = QDateTime::fromMSecsSinceEpoch(timestamp);
    }
    
    if (json.contains("executed_at")) {
        qint64 timestamp = json["executed_at"].toVariant().toLongLong();
        m_executedAt = QDateTime::fromMSecsSinceEpoch(timestamp);
    }
    
    // Parse parameters
    if (json.contains("parameters")) {
        QJsonObject parametersObj = json["parameters"].toObject();
        for (auto it = parametersObj.begin(); it != parametersObj.end(); ++it) {
            m_parameters[it.key()] = it.value().toVariant();
        }
    }
    
    // Parse metadata
    if (json.contains("metadata")) {
        m_metadata = json["metadata"].toObject();
    }
    
    // Parse hashes
    m_preHash = json["pre_hash"].toString();
    m_postHash = json["post_hash"].toString();
    
    return true;
}

Command Command::parseCommandFromQuery(QSqlQuery& query)
{
    return parseCommandFromQuery(query, ""); // Default to empty project ID for backwards compatibility
}

Command Command::parseCommandFromQuery(QSqlQuery& query, const QString& projectId)
{
    QString id = query.value("id").toString();
    QString type = query.value("command_type").toString();
    
    Command command(id, type, projectId);
    command.m_sequenceNumber = query.value("sequence_number").toInt();
    command.m_preHash = query.value("pre_hash").toString();
    command.m_postHash = query.value("post_hash").toString();
    
    // Parse timestamp
    qint64 timestamp = query.value("timestamp").toLongLong();
    command.m_createdAt = QDateTime::fromMSecsSinceEpoch(timestamp);
    
    // Parse parameters from JSON
    QString argsJson = query.value("command_args").toString();
    if (!argsJson.isEmpty()) {
        QJsonDocument doc = QJsonDocument::fromJson(argsJson.toUtf8());
        if (doc.isObject()) {
            QJsonObject parametersObj = doc.object();
            for (auto it = parametersObj.begin(); it != parametersObj.end(); ++it) {
                command.m_parameters[it.key()] = it.value().toVariant();
            }
        }
    }
    
    return command;
}

bool Command::saveToDatabase(QSqlDatabase& database)
{
    QSqlQuery query(database);
    query.prepare(
        "INSERT OR REPLACE INTO commands "
        "(id, sequence_number, command_type, command_args, pre_hash, post_hash, timestamp) "
        "VALUES (?, ?, ?, ?, ?, ?, ?)"
    );
    
    query.addBindValue(m_id);
    query.addBindValue(m_sequenceNumber);
    query.addBindValue(m_type);
    
    // Serialize parameters to JSON
    QJsonObject parametersObj;
    for (auto it = m_parameters.begin(); it != m_parameters.end(); ++it) {
        parametersObj[it.key()] = QJsonValue::fromVariant(it.value());
    }
    QJsonDocument doc(parametersObj);
    query.addBindValue(QString::fromUtf8(doc.toJson(QJsonDocument::Compact)));
    
    query.addBindValue(m_preHash);
    query.addBindValue(m_postHash);
    query.addBindValue(m_createdAt.toMSecsSinceEpoch());
    
    if (!query.exec()) {
        qCCritical(jveCommand) << "Failed to save command:" << query.lastError().text();
        return false;
    }
    
    return true;
}

Command::CommandStatus Command::stringToStatus(const QString& statusStr) const
{
    if (statusStr == "Executed") return Executed;
    if (statusStr == "Undone") return Undone;
    if (statusStr == "Failed") return Failed;
    return Created;
}

QString Command::statusToString(CommandStatus status) const
{
    switch (status) {
    case Created: return "Created";
    case Executed: return "Executed";
    case Undone: return "Undone";
    case Failed: return "Failed";
    }
    return "Created";
}