#include "command_dispatcher.h"
#include <QUuid>
#include <QLoggingCategory>
#include <QDebug>
#include <QSqlQuery>
#include <QJsonArray>

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
        
        // Create command-specific delta object
        QJsonObject delta = createCommandDelta(command, commandType);
        response.delta = delta;
        
        // Create inverse delta for undo
        Command undoCommand = command.createUndo();
        QJsonObject inverseDelta;
        inverseDelta["command_type"] = undoCommand.type();
        inverseDelta["command_id"] = undoCommand.id();
        response.inverseDelta = inverseDelta;
        
        // Store in history
        m_commandHistory.append(response);
        m_undoStack.append(undoCommand); // Store complete undo command
        
        qCInfo(jveCommandDispatcher, "Command executed successfully: %s", qPrintable(commandType));
    } else {
        response.success = false;
        
        // Map error messages to appropriate error codes
        QString errorMessage = result.errorMessage;
        qCDebug(jveCommandDispatcher, "Mapping error message: '%s'", qPrintable(errorMessage));
        
        if (errorMessage.contains("Unknown command type") || errorMessage.contains("Invalid command")) {
            response.error.code = "INVALID_COMMAND";
            response.error.message = "Invalid or unsupported command type";
            response.error.hint = "Check the command_type parameter";
            response.error.audience = "developer";
        } else if (errorMessage.contains("Missing required parameters") || 
                   errorMessage.contains("Invalid arguments") ||
                   (errorMessage.contains("Missing") && errorMessage.contains("parameter"))) {
            response.error.code = "INVALID_ARGUMENTS";
            response.error.message = result.errorMessage;
            response.error.hint = "Check required parameters for this command type";
            response.error.audience = "developer";
        } else {
            response.error.code = "EXECUTION_FAILED";
            response.error.message = result.errorMessage;
            response.error.hint = "Check command parameters and database state";
            response.error.audience = "user";
        }
        
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
    
    if (m_undoStack.isEmpty()) {
        response.success = false;
        response.error.code = "NO_COMMAND_TO_UNDO";
        response.error.message = "No commands to undo";
        response.error.hint = "Execute a command first";
        response.error.audience = "user";
        return response;
    }
    
    // Get the complete undo command from the stack
    Command undoCommand = m_undoStack.last();
    
    // Execute the undo command directly
    ExecutionResult result = m_commandManager->execute(undoCommand);
    
    if (result.success) {
        response.success = true;
        response.postHash = m_commandManager->getProjectState(m_currentProjectId);
        
        // Remove the undone command from both stacks
        m_commandHistory.removeLast();
        m_undoStack.removeLast();
        
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
    m_undoStack.clear();
}

QJsonObject CommandDispatcher::createCommandDelta(const Command& command, const QString& commandType)
{
    qCDebug(jveCommandDispatcher, "Creating delta for command type: %s", qPrintable(commandType));
    
    // Algorithm: Create base delta → Add command-specific data → Return delta
    QJsonObject delta;
    delta["command_type"] = commandType;
    delta["command_id"] = command.id();
    delta["sequence_number"] = command.sequenceNumber();
    
    // Add command-specific data based on type
    if (commandType == "create_clip") {
        // For create_clip, add clips_created array
        QJsonArray clipsCreated;
        QJsonObject clipInfo;
        
        QString createdClipId = command.getParameter("created_clip_id").toString();
        qCDebug(jveCommandDispatcher, "Created clip ID from command: %s", qPrintable(createdClipId));
        if (!createdClipId.isEmpty()) {
            clipInfo["id"] = createdClipId;
            clipInfo["track_id"] = command.getParameter("track_id").toString();
            clipInfo["media_id"] = command.getParameter("media_id").toString();
            clipInfo["start_time"] = command.getParameter("start_time").toInt();
            clipInfo["end_time"] = command.getParameter("end_time").toInt();
            clipsCreated.append(clipInfo);
        }
        
        delta["clips_created"] = clipsCreated;
        
    } else if (commandType == "delete_clip") {
        // For delete_clip, add clips_deleted array
        QJsonArray clipsDeleted;
        QString deletedClipId = command.getParameter("clip_id").toString();
        if (!deletedClipId.isEmpty()) {
            clipsDeleted.append(deletedClipId);
        }
        delta["clips_deleted"] = clipsDeleted;
        
    } else if (commandType == "split_clip") {
        // For split_clip, follow standard video editing convention:
        // - Original clip is modified (left part)
        // - One new clip is created (right part)
        QJsonArray clipsCreated;
        QString rightClipId = command.getParameter("right_clip_id").toString();
        
        if (!rightClipId.isEmpty()) {
            QJsonObject rightClipInfo;
            rightClipInfo["id"] = rightClipId;
            rightClipInfo["track_id"] = command.getParameter("track_id").toString();
            clipsCreated.append(rightClipInfo);
        }
        
        delta["clips_created"] = clipsCreated;
        
        // Original clip is modified (becomes the left part)
        QJsonArray clipsModified;
        QString originalClipId = command.getParameter("original_clip_id").toString();
        if (!originalClipId.isEmpty()) {
            clipsModified.append(originalClipId);
        }
        delta["clips_modified"] = clipsModified;
        
    } else if (commandType == "ripple_delete") {
        // For ripple_delete, add clips_deleted and clips_moved arrays
        QJsonArray clipsDeleted;
        QString deletedClipId = command.getParameter("clip_id").toString();
        if (!deletedClipId.isEmpty()) {
            clipsDeleted.append(deletedClipId);
        }
        delta["clips_deleted"] = clipsDeleted;
        
        // Ripple delete moves subsequent clips
        QJsonArray clipsMoved;
        QVariantList movedClips = command.getParameter("moved_clips").toList();
        for (const QVariant& clip : movedClips) {
            clipsMoved.append(QJsonValue::fromVariant(clip));
        }
        delta["clips_moved"] = clipsMoved;
        
    } else if (commandType == "ripple_trim") {
        // For ripple_trim, add clips_modified and clips_moved arrays
        QJsonArray clipsModified;
        QString modifiedClipId = command.getParameter("clip_id").toString();
        if (!modifiedClipId.isEmpty()) {
            clipsModified.append(modifiedClipId);
        }
        delta["clips_modified"] = clipsModified;
        
        // Ripple trim moves subsequent clips
        QJsonArray clipsMoved;
        QVariantList movedClips = command.getParameter("moved_clips").toList();
        for (const QVariant& clip : movedClips) {
            clipsMoved.append(QJsonValue::fromVariant(clip));
        }
        delta["clips_moved"] = clipsMoved;
        
    } else if (commandType == "roll_edit") {
        // For roll_edit, add clips_modified array
        QJsonArray clipsModified;
        QString clipAId = command.getParameter("clip_a_id").toString();
        QString clipBId = command.getParameter("clip_b_id").toString();
        if (!clipAId.isEmpty()) {
            clipsModified.append(clipAId);
        }
        if (!clipBId.isEmpty()) {
            clipsModified.append(clipBId);
        }
        delta["clips_modified"] = clipsModified;
    }
    
    return delta;
}