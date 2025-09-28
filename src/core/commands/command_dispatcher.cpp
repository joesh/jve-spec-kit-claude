#include "command_dispatcher.h"
#include <QUuid>
#include <QLoggingCategory>
#include <QDebug>
#include <QSqlQuery>

Q_LOGGING_CATEGORY(jveCommandDispatcher, "jve.command.dispatcher")

CommandDispatcher::CommandDispatcher(QObject* parent)
    : QObject(parent), m_commandManager(nullptr)
{
}

void CommandDispatcher::setDatabase(const QSqlDatabase& database)
{
    m_database = database;
    
    // Initialize CommandManager with the database
    if (m_commandManager) {
        delete m_commandManager;
    }
    m_commandManager = new CommandManager(m_database);
    
    qCDebug(jveCommandDispatcher, "CommandDispatcher initialized with database");
}

CommandResponse CommandDispatcher::executeCommand(const QJsonObject& request)
{
    qCDebug(jveCommandDispatcher, "Executing command request");
    
    CommandResponse response;
    response.commandId = QUuid::createUuid().toString();
    
    if (!m_commandManager) {
        response.success = false;
        response.error.code = "NO_COMMAND_MANAGER";
        response.error.message = "CommandManager not initialized";
        response.error.hint = "Call setDatabase() first";
        response.error.audience = "developer";
        return response;
    }
    
    // Extract command details from request
    QString commandType = request["command_type"].toString();
    QJsonObject args = request["args"].toObject();
    QString projectId = request["project_id"].toString();
    
    if (commandType.isEmpty()) {
        response.success = false;
        response.error.code = "INVALID_COMMAND";
        response.error.message = "Missing command_type";
        response.error.hint = "Provide a valid command_type in the request";
        response.error.audience = "developer";
        return response;
    }
    
    // If project_id is not provided, try to derive it from sequence_id or use current project
    if (projectId.isEmpty()) {
        QString sequenceId = args["sequence_id"].toString();
        if (!sequenceId.isEmpty()) {
            // Try to get project_id from sequence
            QSqlQuery query(m_database);
            query.prepare("SELECT project_id FROM sequences WHERE id = ?");
            query.addBindValue(sequenceId);
            if (query.exec() && query.next()) {
                projectId = query.value(0).toString();
            }
        }
        
        // If still no project_id, use the first project in database (for single-project files)
        if (projectId.isEmpty()) {
            QSqlQuery query(m_database);
            query.prepare("SELECT id FROM projects LIMIT 1");
            if (query.exec() && query.next()) {
                projectId = query.value(0).toString();
            }
        }
        
        if (projectId.isEmpty()) {
            response.success = false;
            response.error.code = "INVALID_ARGUMENTS";
            response.error.message = "Cannot determine project_id";
            response.error.hint = "Provide a valid project_id in the request or ensure sequence_id is valid";
            response.error.audience = "developer";
            return response;
        }
    }
    
    // Store current project ID
    m_currentProjectId = projectId;
    
    // Create command object
    Command command = Command::create(commandType, projectId);
    
    // Set command parameters from args
    for (auto it = args.begin(); it != args.end(); ++it) {
        command.setParameter(it.key(), it.value().toVariant());
    }
    
    // Execute command through CommandManager
    ExecutionResult result = m_commandManager->execute(command);
    
    if (result.success) {
        response.success = true;
        response.commandId = command.id();
        response.postHash = command.postHash();
        
        // Create delta object (simplified for now)
        QJsonObject delta;
        delta["command_type"] = commandType;
        delta["command_id"] = command.id();
        delta["sequence_number"] = command.sequenceNumber();
        response.delta = delta;
        
        // Create inverse delta for undo
        Command undoCommand = command.createUndo();
        QJsonObject inverseDelta;
        inverseDelta["command_type"] = undoCommand.type();
        inverseDelta["command_id"] = undoCommand.id();
        response.inverseDelta = inverseDelta;
        
        // Store in history
        m_commandHistory.append(response);
        
        qCInfo(jveCommandDispatcher, "Command executed successfully: %s", qPrintable(commandType));
    } else {
        response.success = false;
        response.error.code = "EXECUTION_FAILED";
        response.error.message = result.errorMessage;
        response.error.hint = "Check command parameters and database state";
        response.error.audience = "user";
        
        qCWarning(jveCommandDispatcher, "Command execution failed: %s - %s", 
                  qPrintable(commandType), qPrintable(result.errorMessage));
    }
    
    return response;
}

CommandResponse CommandDispatcher::undoCommand()
{
    qCDebug(jveCommandDispatcher, "Executing undo command");
    
    CommandResponse response;
    response.commandId = QUuid::createUuid().toString();
    
    if (!m_commandManager) {
        response.success = false;
        response.error.code = "NO_COMMAND_MANAGER";
        response.error.message = "CommandManager not initialized";
        response.error.hint = "Call setDatabase() first";
        response.error.audience = "developer";
        return response;
    }
    
    if (m_commandHistory.isEmpty()) {
        response.success = false;
        response.error.code = "NO_COMMANDS";
        response.error.message = "No commands to undo";
        response.error.hint = "Execute a command first";
        response.error.audience = "user";
        return response;
    }
    
    // Get the last executed command from history
    CommandResponse lastCommand = m_commandHistory.last();
    
    // Create the undo command from the inverse delta
    Command originalCommand = Command::create(
        lastCommand.inverseDelta["command_type"].toString(), 
        m_currentProjectId
    );
    
    // Execute the undo
    ExecutionResult result = m_commandManager->executeUndo(originalCommand);
    
    if (result.success) {
        response.success = true;
        response.postHash = m_commandManager->getProjectState(m_currentProjectId);
        
        // Remove the undone command from history
        m_commandHistory.removeLast();
        
        qCInfo(jveCommandDispatcher, "Undo executed successfully");
    } else {
        response.success = false;
        response.error.code = "UNDO_FAILED";
        response.error.message = result.errorMessage;
        response.error.hint = "Check database state and command history";
        response.error.audience = "user";
        
        qCWarning(jveCommandDispatcher, "Undo execution failed: %s", qPrintable(result.errorMessage));
    }
    
    return response;
}

CommandResponse CommandDispatcher::redoCommand()
{
    qCDebug(jveCommandDispatcher, "Executing redo command");
    
    CommandResponse response;
    response.commandId = QUuid::createUuid().toString();
    
    if (!m_commandManager) {
        response.success = false;
        response.error.code = "NO_COMMAND_MANAGER";
        response.error.message = "CommandManager not initialized";
        response.error.hint = "Call setDatabase() first";
        response.error.audience = "developer";
        return response;
    }
    
    // For now, redo is not implemented in this simplified version
    // A full implementation would maintain separate undo/redo stacks
    response.success = false;
    response.error.code = "NOT_IMPLEMENTED";
    response.error.message = "Redo not yet implemented";
    response.error.hint = "Use command replay functionality instead";
    response.error.audience = "user";
    
    return response;
}

QString CommandDispatcher::getStateHash() const
{
    if (!m_commandManager || m_currentProjectId.isEmpty()) {
        return QString();
    }
    
    return m_commandManager->getProjectState(m_currentProjectId);
}

void CommandDispatcher::reset()
{
    m_commandHistory.clear();
}