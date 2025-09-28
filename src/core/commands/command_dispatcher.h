#pragma once

#include <QObject>
#include <QJsonObject>
#include <QSqlDatabase>
#include "command_manager.h"
#include "command.h"

struct ErrorResponse {
    QString code;
    QString message;
    QJsonObject data;
    QString hint;
    QString audience;
};

struct CommandResponse {
    QString commandId;
    bool success = false;
    QJsonObject delta;
    QString postHash;
    QJsonObject inverseDelta;
    ErrorResponse error;
};

/**
 * CommandDispatcher - Core command execution engine
 * 
 * Implements the apply_command(cmd, args) → delta|error pattern
 * for deterministic editing operations with replay capability.
 * 
 * This is a stub implementation that will fail all tests initially
 * per TDD requirements.
 */
class CommandDispatcher : public QObject
{
    Q_OBJECT

public:
    explicit CommandDispatcher(QObject* parent = nullptr);
    
    void setDatabase(const QSqlDatabase& database);
    CommandResponse executeCommand(const QJsonObject& request);
    CommandResponse undoCommand();
    CommandResponse redoCommand();
    QString getStateHash() const;
    void reset();

private:
    // Algorithm implementations
    QJsonObject createCommandDelta(const Command& command, const QString& commandType);
    
    QSqlDatabase m_database;
    QList<CommandResponse> m_commandHistory;
    QList<Command> m_undoStack; // Store complete undo commands
    CommandManager* m_commandManager;
    QString m_currentProjectId;
};