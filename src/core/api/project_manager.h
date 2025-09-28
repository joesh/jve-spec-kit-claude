#pragma once

#include <QObject>
#include <QJsonObject>
#include <QJsonArray>
#include <QDateTime>
#include <QSqlDatabase>

struct ProjectResponse {
    QString id;
    QString name;
    QDateTime createdAt;
    QJsonArray sequences;
    QJsonArray media;
    
    QJsonObject toJson() const {
        QJsonObject obj;
        obj["id"] = id;
        obj["name"] = name;
        obj["created_at"] = createdAt.toString(Qt::ISODate);
        obj["sequences"] = sequences;
        obj["media"] = media;
        return obj;
    }
};

struct ProjectCreateResponse {
    int statusCode = 500;
    ProjectResponse project;
    struct {
        QString code;
        QString message;
        QJsonObject data;
        QString hint;
        QString audience;
    } error;
};

struct ProjectLoadResponse {
    int statusCode = 500;
    ProjectResponse project;
    struct {
        QString code;
        QString message;
        QJsonObject data;
        QString hint;
        QString audience;
    } error;
};

/**
 * ProjectManager - High-level project API implementation
 * 
 * Implements the REST API contract for project operations:
 * - POST /projects (create)
 * - GET /projects/{id} (load)
 * - PUT /projects/{id} (save)
 * - POST /projects/{id}/sequences (create sequence)
 * - POST /projects/{id}/media (import media)
 * 
 * This is a stub implementation that will fail all tests initially
 * per TDD requirements.
 */
class ProjectManager : public QObject
{
    Q_OBJECT

public:
    explicit ProjectManager(QObject* parent = nullptr);
    
    ProjectCreateResponse createProject(const QJsonObject& request);
    ProjectLoadResponse loadProject(const QString& projectId);
    bool saveProject(const QString& projectId);
    QJsonObject createSequence(const QString& projectId, const QJsonObject& request);
    QJsonObject importMedia(const QString& projectId, const QJsonObject& request);

private:
    QSqlDatabase m_database;
};