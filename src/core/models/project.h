#pragma once

#include <QString>
#include <QDateTime>
#include <QSqlDatabase>
#include <QJsonObject>
#include <QVariant>

/**
 * Project entity - top-level container with settings
 * Core entity following Rule 2.27: Single responsibility - project data only
 */
class Project
{
public:
    Project() = default;
    ~Project() = default;
    
    // Copy and move constructors
    Project(const Project& other) = default;
    Project& operator=(const Project& other) = default;
    Project(Project&& other) noexcept = default;
    Project& operator=(Project&& other) noexcept = default;
    
    /**
     * Create new project with generated ID
     * Algorithm: Generate UUID → Set creation time → Initialize defaults
     */
    static Project create(const QString& name);
    
    /**
     * Create project with specific ID (for testing/determinism)
     * Algorithm: Use provided ID → Set creation time → Initialize defaults
     */
    static Project createWithId(const QString& id, const QString& name);
    
    /**
     * Load project from database by ID
     * Algorithm: Query database → Parse results → Construct object
     */
    static Project load(const QString& id, const QSqlDatabase& database);
    
    /**
     * Save project to database
     * Algorithm: Validate data → Execute insert/update → Update timestamps
     */
    bool save(const QSqlDatabase& database);
    
    // Core properties
    QString id() const { return m_id; }
    QString name() const { return m_name; }
    void setName(const QString& name);
    
    QDateTime createdAt() const { return m_createdAt; }
    QDateTime modifiedAt() const { return m_modifiedAt; }
    
    // For testing/deterministic serialization
    void setCreatedAt(const QDateTime& dateTime) { m_createdAt = dateTime; }
    void setModifiedAt(const QDateTime& dateTime) { m_modifiedAt = dateTime; }
    
    // Settings management
    QString settings() const { return m_settings; }
    void setSettings(const QString& settingsJson);
    QVariant getSetting(const QString& key, const QVariant& defaultValue = QVariant()) const;
    void setSetting(const QString& key, const QVariant& value);
    
    // Validation and state
    bool isValid() const { return !m_id.isEmpty() && !m_name.isEmpty(); }
    
    // Serialization for deterministic testing
    QString serialize() const;
    static Project deserialize(const QString& data);

private:
    QString m_id;
    QString m_name;
    QDateTime m_createdAt;
    QDateTime m_modifiedAt;
    QString m_settings = "{}"; // JSON string
    
    // Helper functions for algorithmic breakdown (Rule 2.26)
    void updateModifiedTime();
    bool validateSettings(const QString& settingsJson) const;
    QJsonObject parseSettings() const;
    void setSettingsFromJson(const QJsonObject& json);
};