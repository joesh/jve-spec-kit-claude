#include "project.h"

#include <QUuid>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSqlQuery>
#include <QSqlError>
#include <QLoggingCategory>

Q_LOGGING_CATEGORY(jveProject, "jve.models.project")

Project Project::create(const QString& name)
{
    // Algorithm: Generate UUID → Set creation time → Initialize defaults
    QString id = QUuid::createUuid().toString(QUuid::WithoutBraces);
    return createWithId(id, name);
}

Project Project::createWithId(const QString& id, const QString& name)
{
    // Algorithm: Use provided ID → Set creation time → Initialize defaults
    Project project;
    project.m_id = id;
    project.m_name = name;
    project.m_createdAt = QDateTime::currentDateTime();
    project.m_modifiedAt = project.m_createdAt;
    project.m_settings = "{}";
    
    qCDebug(jveProject, "Created project: %s with ID: %s", qPrintable(name), qPrintable(id));
    return project;
}

Project Project::load(const QString& id, const QSqlDatabase& database)
{
    // Algorithm: Query database → Parse results → Construct object
    QSqlQuery query(database);
    query.prepare("SELECT id, name, created_at, modified_at, settings FROM projects WHERE id = ?");
    query.addBindValue(id);
    
    if (!query.exec()) {
        qCWarning(jveProject, "Failed to load project: %s", qPrintable(query.lastError().text()));
        return Project(); // Invalid project
    }
    
    if (!query.next()) {
        qCDebug(jveProject, "Project not found: %s", qPrintable(id));
        return Project(); // Invalid project
    }
    
    Project project;
    project.m_id = query.value("id").toString();
    project.m_name = query.value("name").toString();
    project.m_createdAt = QDateTime::fromSecsSinceEpoch(query.value("created_at").toLongLong());
    project.m_modifiedAt = QDateTime::fromSecsSinceEpoch(query.value("modified_at").toLongLong());
    project.m_settings = query.value("settings").toString();
    
    if (!project.validateSettings(project.m_settings)) {
        qCWarning(jveProject, "Invalid settings JSON for project: %s", qPrintable(id));
        project.m_settings = "{}"; // Reset to default
    }
    
    qCDebug(jveProject, "Loaded project: %s", qPrintable(project.m_name));
    return project;
}

bool Project::save(const QSqlDatabase& database)
{
    // Algorithm: Validate data → Execute insert/update → Update timestamps
    if (!isValid()) {
        qCWarning(jveProject, "Cannot save invalid project");
        return false;
    }
    
    updateModifiedTime();
    
    QSqlQuery query(database);
    query.prepare(R"(
        INSERT OR REPLACE INTO projects 
        (id, name, created_at, modified_at, settings)
        VALUES (?, ?, ?, ?, ?)
    )");
    
    query.addBindValue(m_id);
    query.addBindValue(m_name);
    query.addBindValue(m_createdAt.toSecsSinceEpoch());
    query.addBindValue(m_modifiedAt.toSecsSinceEpoch());
    query.addBindValue(m_settings);
    
    if (!query.exec()) {
        qCWarning(jveProject, "Failed to save project: %s", qPrintable(query.lastError().text()));
        return false;
    }
    
    qCDebug(jveProject, "Saved project: %s", qPrintable(m_name));
    return true;
}

void Project::setName(const QString& name)
{
    if (m_name != name) {
        m_name = name;
        updateModifiedTime();
    }
}

void Project::setSettings(const QString& settingsJson)
{
    if (validateSettings(settingsJson)) {
        if (m_settings != settingsJson) {
            m_settings = settingsJson;
            updateModifiedTime();
        }
    } else {
        qCWarning(jveProject, "Invalid settings JSON provided");
    }
}

QVariant Project::getSetting(const QString& key, const QVariant& defaultValue) const
{
    QJsonObject settings = parseSettings();
    if (settings.contains(key)) {
        return settings.value(key).toVariant();
    }
    return defaultValue;
}

void Project::setSetting(const QString& key, const QVariant& value)
{
    QJsonObject settings = parseSettings();
    settings[key] = QJsonValue::fromVariant(value);
    setSettingsFromJson(settings);
}

QString Project::serialize() const
{
    QJsonObject json;
    json["id"] = m_id;
    json["name"] = m_name;
    json["created_at"] = m_createdAt.toSecsSinceEpoch();
    json["modified_at"] = m_modifiedAt.toSecsSinceEpoch();
    json["settings"] = QJsonDocument::fromJson(m_settings.toUtf8()).object();
    
    QJsonDocument doc(json);
    return doc.toJson(QJsonDocument::Compact);
}

Project Project::deserialize(const QString& data)
{
    QJsonParseError error;
    QJsonDocument doc = QJsonDocument::fromJson(data.toUtf8(), &error);
    
    if (error.error != QJsonParseError::NoError) {
        qCWarning(jveProject, "Failed to deserialize project: %s", qPrintable(error.errorString()));
        return Project();
    }
    
    QJsonObject json = doc.object();
    
    Project project;
    project.m_id = json["id"].toString();
    project.m_name = json["name"].toString();
    project.m_createdAt = QDateTime::fromSecsSinceEpoch(json["created_at"].toInt());
    project.m_modifiedAt = QDateTime::fromSecsSinceEpoch(json["modified_at"].toInt());
    
    // Convert settings back to JSON string
    QJsonDocument settingsDoc(json["settings"].toObject());
    project.m_settings = settingsDoc.toJson(QJsonDocument::Compact);
    
    return project;
}

void Project::updateModifiedTime()
{
    m_modifiedAt = QDateTime::currentDateTime();
}

bool Project::validateSettings(const QString& settingsJson) const
{
    if (settingsJson.isEmpty()) {
        return false;
    }
    
    QJsonParseError error;
    QJsonDocument::fromJson(settingsJson.toUtf8(), &error);
    return error.error == QJsonParseError::NoError;
}

QJsonObject Project::parseSettings() const
{
    QJsonParseError error;
    QJsonDocument doc = QJsonDocument::fromJson(m_settings.toUtf8(), &error);
    
    if (error.error != QJsonParseError::NoError) {
        qCWarning(jveProject, "Failed to parse settings JSON: %s", qPrintable(error.errorString()));
        return QJsonObject(); // Empty object
    }
    
    return doc.object();
}

void Project::setSettingsFromJson(const QJsonObject& json)
{
    QJsonDocument doc(json);
    QString newSettings = doc.toJson(QJsonDocument::Compact);
    
    if (m_settings != newSettings) {
        m_settings = newSettings;
        updateModifiedTime();
    }
}