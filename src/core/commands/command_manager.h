#pragma once

#include "command.h"
#include <QSqlDatabase>
#include <QString>
#include <QList>
#include <QHash>

/**
 * CommandManager: Manages command execution, sequencing, and replay
 * 
 * Constitutional requirements:
 * - Deterministic command execution and replay
 * - Sequence number management with integrity validation
 * - State hash tracking for constitutional compliance
 * - Performance optimization for batch operations
 * - Undo/redo functionality with state consistency
 * 
 * Engineering Rules:
 * - Rule 2.14: No hardcoded constants (uses schema_constants.h)
 * - Rule 2.26: Functions read like algorithms calling subfunctions
 * - Rule 2.27: Short, focused functions with single responsibilities
 */
class CommandManager
{
public:
    explicit CommandManager(QSqlDatabase& database);
    
    // Command execution
    ExecutionResult execute(Command& command);
    ExecutionResult executeUndo(const Command& originalCommand);
    
    // Batch operations
    QList<ExecutionResult> executeBatch(QList<Command>& commands);
    
    // State management
    void revertToSequence(int sequenceNumber);
    QString getProjectState(const QString& projectId) const;
    Command getCurrentState() const;
    
    // Replay functionality
    ReplayResult replayFromSequence(int startSequenceNumber);
    ReplayResult replayAll();
    
    // Sequence integrity
    bool validateSequenceIntegrity() const;
    void repairSequenceNumbers();
    
private:
    // Algorithm implementations
    int getNextSequenceNumber();
    QString calculateStateHash(const QString& projectId) const;
    bool executeCommandImplementation(Command& command);
    bool validateCommandParameters(const Command& command) const;
    void updateCommandHashes(Command& command, const QString& preHash);
    QList<Command> loadCommandsFromSequence(int startSequence) const;
    
    // Command type implementations
    bool executeCreateProject(Command& command);
    bool executeLoadProject(Command& command);
    bool executeCreateSequence(Command& command);
    bool executeImportMedia(Command& command);
    bool executeSetClipProperty(Command& command);
    bool executeSetProperty(Command& command);
    bool executeModifyProperty(Command& command);
    bool executeCreateClip(Command& command);
    bool executeAddTrack(Command& command);
    bool executeAddClip(Command& command);
    bool executeSetupProject(Command& command);
    
    // Timeline operation commands
    bool executeTimelineCreateClip(Command& command);
    bool executeTimelineDeleteClip(Command& command);
    bool executeTimelineSplitClip(Command& command);
    bool executeTimelineRippleDelete(Command& command);
    bool executeTimelineRippleTrim(Command& command);
    bool executeTimelineRollEdit(Command& command);
    
    // Database reference
    QSqlDatabase& m_database;
    
    // State tracking
    int m_lastSequenceNumber;
    QString m_currentStateHash;
    
    // Performance cache
    mutable QHash<QString, QString> m_stateHashCache;
};