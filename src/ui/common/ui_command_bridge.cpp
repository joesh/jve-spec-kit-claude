#include "ui_command_bridge.h"
#include <QJsonArray>
#include <QUuid>
#include <QVariant>

Q_LOGGING_CATEGORY(jveUICommandBridge, "jve.ui.commandbridge")

UICommandBridge::UICommandBridge(CommandDispatcher* commandDispatcher, 
                                SelectionManager* selectionManager,
                                QObject* parent)
    : QObject(parent)
    , m_commandDispatcher(commandDispatcher)
    , m_selectionManager(selectionManager)
{
    Q_ASSERT(commandDispatcher);
    Q_ASSERT(selectionManager);
    
    // Note: CommandDispatcher doesn't have async signals in current implementation
    // Commands are executed synchronously
    
    // Connect to selection manager
    connect(m_selectionManager, &SelectionManager::selectionChanged,
            this, &UICommandBridge::onSelectionChanged);
    
    // Initialize command timeout timer
    m_commandTimeoutTimer = new QTimer(this);
    m_commandTimeoutTimer->setSingleShot(true);
    m_commandTimeoutTimer->setInterval(COMMAND_TIMEOUT_MS);
    
    qCDebug(jveUICommandBridge, "UI Command Bridge initialized");
}

// Timeline operations
void UICommandBridge::createClip(const QString& sequenceId, const QString& trackId, 
                                const QString& mediaId, qint64 startTime, qint64 duration)
{
    QJsonObject parameters;
    parameters["sequence_id"] = sequenceId;
    parameters["track_id"] = trackId;
    parameters["media_id"] = mediaId;
    parameters["start_time"] = startTime;
    parameters["duration"] = duration;
    
    QJsonObject command = buildTimelineCommand("create_clip", parameters);
    executeCommand("create_clip", command);
    
    qCDebug(jveUICommandBridge, "Creating clip: media=%s, track=%s, start=%lld, duration=%lld", 
            qPrintable(mediaId), qPrintable(trackId), startTime, duration);
}

void UICommandBridge::deleteClip(const QString& clipId)
{
    QJsonObject parameters;
    parameters["clip_id"] = clipId;
    
    QJsonObject command = buildTimelineCommand("delete_clip", parameters);
    executeCommand("delete_clip", command);
    
    qCDebug(jveUICommandBridge, "Deleting clip: %s", qPrintable(clipId));
}

void UICommandBridge::deleteSelectedClips()
{
    QStringList selectedClips = m_selectionManager->getSelectedItems();
    if (selectedClips.isEmpty()) {
        qCDebug(jveUICommandBridge, "No clips selected for deletion");
        return;
    }
    
    for (const QString& clipId : selectedClips) {
        deleteClip(clipId);
    }
    
    qCDebug(jveUICommandBridge, "Deleting %d selected clips", selectedClips.size());
}

void UICommandBridge::splitClip(const QString& clipId, qint64 splitTime)
{
    QJsonObject parameters;
    parameters["clip_id"] = clipId;
    parameters["split_time"] = splitTime;
    
    QJsonObject command = buildTimelineCommand("split_clip", parameters);
    executeCommand("split_clip", command);
    
    qCDebug(jveUICommandBridge, "Splitting clip %s at time %lld", qPrintable(clipId), splitTime);
}

void UICommandBridge::splitClipsAtPlayhead(qint64 playheadTime)
{
    QStringList selectedClips = m_selectionManager->getSelectedItems();
    if (selectedClips.isEmpty()) {
        // If no clips selected, split all clips at playhead position
        qCDebug(jveUICommandBridge, "No clips selected, would split all clips at playhead %lld", playheadTime);
        return;
    }
    
    for (const QString& clipId : selectedClips) {
        splitClip(clipId, playheadTime);
    }
    
    qCDebug(jveUICommandBridge, "Splitting %d clips at playhead time %lld", selectedClips.size(), playheadTime);
}

void UICommandBridge::rippleDeleteClip(const QString& clipId)
{
    QJsonObject parameters;
    parameters["clip_id"] = clipId;
    
    QJsonObject command = buildTimelineCommand("ripple_delete", parameters);
    executeCommand("ripple_delete", command);
    
    qCDebug(jveUICommandBridge, "Ripple deleting clip: %s", qPrintable(clipId));
}

void UICommandBridge::rippleDeleteSelectedClips()
{
    QStringList selectedClips = m_selectionManager->getSelectedItems();
    if (selectedClips.isEmpty()) {
        qCDebug(jveUICommandBridge, "No clips selected for ripple deletion");
        return;
    }
    
    for (const QString& clipId : selectedClips) {
        rippleDeleteClip(clipId);
    }
    
    qCDebug(jveUICommandBridge, "Ripple deleting %d selected clips", selectedClips.size());
}

void UICommandBridge::moveClip(const QString& clipId, const QString& newTrackId, qint64 newTime)
{
    QJsonObject parameters;
    parameters["clip_id"] = clipId;
    parameters["track_id"] = newTrackId;
    parameters["start_time"] = newTime;
    
    QJsonObject command = buildTimelineCommand("move_clip", parameters);
    executeCommand("move_clip", command);
    
    qCDebug(jveUICommandBridge, "Moving clip %s to track %s at time %lld", 
            qPrintable(clipId), qPrintable(newTrackId), newTime);
}

// Selection operations
void UICommandBridge::selectClip(const QString& clipId, bool addToSelection)
{
    if (!addToSelection) {
        m_selectionManager->clear();
    }
    m_selectionManager->addToSelection(clipId);
    
    qCDebug(jveUICommandBridge, "Selected clip: %s (add=%s)", qPrintable(clipId), addToSelection ? "true" : "false");
}

void UICommandBridge::selectClips(const QStringList& clipIds, bool replaceSelection)
{
    if (replaceSelection) {
        m_selectionManager->clear();
    }
    for (const QString& clipId : clipIds) {
        m_selectionManager->addToSelection(clipId);
    }
    
    qCDebug(jveUICommandBridge, "Selected %d clips (replace=%s)", clipIds.size(), replaceSelection ? "true" : "false");
}

void UICommandBridge::selectAllClips()
{
    // This would typically query the current sequence for all clips
    qCDebug(jveUICommandBridge, "Selecting all clips in sequence");
    // Implementation would depend on having access to sequence data
    if (m_selectionManager) {
        // For now, just log the action
        qCDebug(jveUICommandBridge, "Would select all clips in current sequence");
    }
}

void UICommandBridge::deselectAllClips()
{
    m_selectionManager->clear();
    qCDebug(jveUICommandBridge, "Deselected all clips");
}

// Property operations
void UICommandBridge::setClipProperty(const QString& clipId, const QString& propertyName, const QVariant& value)
{
    QJsonObject parameters;
    parameters["clip_id"] = clipId;
    
    QJsonObject properties;
    properties[propertyName] = QJsonValue::fromVariant(value);
    parameters["properties"] = properties;
    
    QJsonObject command = buildPropertyCommand("set_properties", parameters);
    executeCommand("set_properties", command);
    
    qCDebug(jveUICommandBridge, "Setting property %s on clip %s", qPrintable(propertyName), qPrintable(clipId));
}

void UICommandBridge::setSelectedClipsProperty(const QString& propertyName, const QVariant& value)
{
    QStringList selectedClips = m_selectionManager->getSelectedItems();
    for (const QString& clipId : selectedClips) {
        setClipProperty(clipId, propertyName, value);
    }
    
    qCDebug(jveUICommandBridge, "Setting property %s on %d selected clips", 
            qPrintable(propertyName), selectedClips.size());
}

// Media operations
void UICommandBridge::importMedia(const QStringList& filePaths)
{
    QJsonObject parameters;
    
    QJsonArray paths;
    for (const QString& path : filePaths) {
        paths.append(path);
    }
    parameters["file_paths"] = paths;
    
    QJsonObject command = buildMediaCommand("import_media", parameters);
    executeCommand("import_media", command);
    
    qCDebug(jveUICommandBridge, "Importing %d media files", filePaths.size());
}

void UICommandBridge::createBin(const QString& name, const QString& parentBinId)
{
    QJsonObject parameters;
    parameters["name"] = name;
    if (!parentBinId.isEmpty()) {
        parameters["parent_bin_id"] = parentBinId;
    }
    
    QJsonObject command = buildMediaCommand("create_bin", parameters);
    executeCommand("create_bin", command);
    
    qCDebug(jveUICommandBridge, "Creating bin: %s (parent: %s)", qPrintable(name), qPrintable(parentBinId));
}

// Project operations
void UICommandBridge::createSequence(const QString& name, int width, int height, double frameRate)
{
    QJsonObject parameters;
    parameters["name"] = name;
    parameters["width"] = width;
    parameters["height"] = height;
    parameters["frame_rate"] = frameRate;
    
    QJsonObject command = buildProjectCommand("create_sequence", parameters);
    executeCommand("create_sequence", command);
    
    qCDebug(jveUICommandBridge, "Creating sequence: %s (%dx%d @ %gfps)", 
            qPrintable(name), width, height, frameRate);
}

// Clipboard operations
void UICommandBridge::cutSelectedClips()
{
    copySelectedClips();
    deleteSelectedClips();
    qCDebug(jveUICommandBridge, "Cut selected clips");
}

void UICommandBridge::copySelectedClips()
{
    QStringList selectedClips = m_selectionManager->getSelectedItems();
    if (selectedClips.isEmpty()) {
        qCDebug(jveUICommandBridge, "No clips selected to copy");
        return;
    }
    
    // Store clipboard data
    QJsonArray clipData;
    for (const QString& clipId : selectedClips) {
        QJsonObject clipInfo = getClipParameters(clipId);
        clipData.append(clipInfo);
    }
    
    m_clipboardData["clips"] = clipData;
    m_hasClipboardData = true;
    
    qCDebug(jveUICommandBridge, "Copied %d clips to clipboard", selectedClips.size());
}

void UICommandBridge::pasteClips(const QString& targetTrackId, qint64 targetTime)
{
    if (!m_hasClipboardData) {
        qCDebug(jveUICommandBridge, "No clipboard data to paste");
        return;
    }
    
    QJsonObject parameters;
    parameters["target_track_id"] = targetTrackId;
    parameters["target_time"] = targetTime;
    parameters["clipboard_data"] = m_clipboardData;
    
    QJsonObject command = buildTimelineCommand("paste_clips", parameters);
    executeCommand("paste_clips", command);
    
    qCDebug(jveUICommandBridge, "Pasting clips to track %s at time %lld", qPrintable(targetTrackId), targetTime);
}

// Undo/redo operations
void UICommandBridge::undo()
{
    QJsonObject parameters;
    executeCommand("undo", parameters);
    qCDebug(jveUICommandBridge, "Executing undo");
}

void UICommandBridge::redo()
{
    QJsonObject parameters;
    executeCommand("redo", parameters);
    qCDebug(jveUICommandBridge, "Executing redo");
}

bool UICommandBridge::canUndo() const
{
    // This would query the command manager
    return true; // Placeholder
}

bool UICommandBridge::canRedo() const
{
    // This would query the command manager
    return true; // Placeholder
}

// Command execution
void UICommandBridge::executeCommand(const QString& commandType, const QJsonObject& parameters)
{
    logCommandExecution(commandType, parameters);
    
    QString commandId = QUuid::createUuid().toString(QUuid::WithoutBraces);
    m_pendingCommands[commandId] = commandType;
    
    // Execute through command dispatcher
    CommandResponse response = m_commandDispatcher->executeCommand(parameters);
    
    // Convert response to JSON
    QJsonObject responseObj;
    responseObj["success"] = response.success;
    responseObj["commandId"] = response.commandId;
    responseObj["delta"] = response.delta;
    responseObj["postHash"] = response.postHash;
    responseObj["inverseDelta"] = response.inverseDelta;
    
    if (!response.success) {
        onCommandFailed(commandId, response.error.message);
    } else {
        onCommandCompleted(commandId, responseObj);
    }
}

void UICommandBridge::executeCommandAsync(const QString& commandType, const QJsonObject& parameters)
{
    // For now, execute synchronously
    // In a full implementation, this would use async execution
    executeCommand(commandType, parameters);
}

// Command building helpers
QJsonObject UICommandBridge::buildTimelineCommand(const QString& operation, const QJsonObject& parameters)
{
    QJsonObject command;
    command["command_type"] = operation;
    
    // Wrap parameters in args object as expected by CommandDispatcher
    QJsonObject args = parameters;
    args["sequence_id"] = m_currentSequenceId;
    command["args"] = args;
    
    return command;
}

QJsonObject UICommandBridge::buildSelectionCommand(const QString& operation, const QJsonObject& parameters)
{
    QJsonObject command;
    command["command_type"] = operation;
    
    // Wrap parameters in args object as expected by CommandDispatcher
    QJsonObject args = parameters;
    args["sequence_id"] = m_currentSequenceId;
    
    // Add current selection context
    QJsonArray selectedClips;
    for (const QString& clipId : m_selectedClipIds) {
        selectedClips.append(clipId);
    }
    args["selected_clips"] = selectedClips;
    command["args"] = args;
    
    return command;
}

QJsonObject UICommandBridge::buildPropertyCommand(const QString& operation, const QJsonObject& parameters)
{
    QJsonObject command;
    command["command_type"] = operation;
    
    // Wrap parameters in args object as expected by CommandDispatcher
    QJsonObject args = parameters;
    args["sequence_id"] = m_currentSequenceId;
    command["args"] = args;
    
    return command;
}

QJsonObject UICommandBridge::buildMediaCommand(const QString& operation, const QJsonObject& parameters)
{
    QJsonObject command;
    command["command_type"] = operation;
    
    // Wrap parameters in args object as expected by CommandDispatcher
    command["args"] = parameters;
    
    return command;
}

QJsonObject UICommandBridge::buildProjectCommand(const QString& operation, const QJsonObject& parameters)
{
    QJsonObject command;
    command["command_type"] = operation;
    
    // Wrap parameters in args object as expected by CommandDispatcher
    command["args"] = parameters;
    
    return command;
}

QJsonObject UICommandBridge::getClipParameters(const QString& clipId)
{
    QJsonObject params;
    params["clip_id"] = clipId;
    // In a full implementation, this would load clip data
    return params;
}

QJsonObject UICommandBridge::getSelectionParameters()
{
    QJsonObject params;
    QJsonArray selectedClips;
    for (const QString& clipId : m_selectedClipIds) {
        selectedClips.append(clipId);
    }
    params["selected_clips"] = selectedClips;
    return params;
}

// Slots
void UICommandBridge::onCommandCompleted(const QString& commandId, const QJsonObject& result)
{
    QString commandType = m_pendingCommands.take(commandId);
    if (commandType.isEmpty()) return;
    
    logCommandResult(commandType, result);
    processCommandResult(commandType, result);
    
    emit commandExecuted(commandType, true, QString());
    qCDebug(jveUICommandBridge, "Command completed: %s", qPrintable(commandType));
}

void UICommandBridge::onCommandFailed(const QString& commandId, const QString& error)
{
    QString commandType = m_pendingCommands.take(commandId);
    if (commandType.isEmpty()) return;
    
    handleCommandError(commandType, error);
    emit commandExecuted(commandType, false, error);
    qCDebug(jveUICommandBridge, "Command failed: %s - %s", qPrintable(commandType), qPrintable(error));
}

void UICommandBridge::onSelectionChanged()
{
    m_selectedClipIds = m_selectionManager->getSelectedItems();
    emit selectionChanged(m_selectedClipIds);
    qCDebug(jveUICommandBridge, "Selection changed: %d clips selected", m_selectedClipIds.size());
}

void UICommandBridge::processCommandResult(const QString& commandType, const QJsonObject& result)
{
    updateUIFromResult(commandType, result);
    extractClipChanges(result);
    extractSelectionChanges(result);
    extractSequenceChanges(result);
}

void UICommandBridge::updateUIFromResult(const QString& commandType, const QJsonObject& result)
{
    Q_UNUSED(commandType)
    Q_UNUSED(result)
    // Implementation would update UI state based on command results
}

void UICommandBridge::extractClipChanges(const QJsonObject& result)
{
    qCDebug(jveUICommandBridge, "Extracting clip changes from result with keys: %s", 
            qPrintable(QJsonDocument(result).toJson(QJsonDocument::Compact)));
    
    // Extract the delta object which contains the actual clip changes
    QJsonObject delta = result["delta"].toObject();
    
    if (delta.contains("clips_created")) {
        QJsonArray created = delta["clips_created"].toArray();
        for (const auto& value : created) {
            QJsonObject clip = value.toObject();
            QString clipId = clip["id"].toString();
            QString sequenceId = ""; // sequence_id not provided in delta, will get from current sequence
            QString trackId = clip["track_id"].toString();
            emit clipCreated(clipId, sequenceId, trackId);
        }
    }
    
    if (delta.contains("clips_deleted")) {
        QJsonArray deleted = delta["clips_deleted"].toArray();
        for (const auto& value : deleted) {
            QString clipId = value.toString();
            emit clipDeleted(clipId);
        }
    }
    
    if (delta.contains("clips_modified")) {
        QJsonArray modified = delta["clips_modified"].toArray();
        for (const auto& value : modified) {
            QJsonObject clip = value.toObject();
            QString clipId = clip["clip_id"].toString();
            QString trackId = clip["track_id"].toString();
            qint64 newTime = clip["start_time"].toVariant().toLongLong();
            emit clipMoved(clipId, trackId, newTime);
        }
    }
}

void UICommandBridge::extractSelectionChanges(const QJsonObject& result)
{
    Q_UNUSED(result)
    // Would extract selection changes from command results
}

void UICommandBridge::extractSequenceChanges(const QJsonObject& result)
{
    if (result.contains("sequence_id")) {
        QString sequenceId = result["sequence_id"].toString();
        m_currentSequenceId = sequenceId;
        emit sequenceChanged(sequenceId);
    }
}

void UICommandBridge::handleCommandError(const QString& commandType, const QString& error)
{
    emit errorOccurred(commandType, error);
    qCWarning(jveUICommandBridge, "Command error [%s]: %s", qPrintable(commandType), qPrintable(error));
}

void UICommandBridge::logCommandExecution(const QString& commandType, const QJsonObject& parameters)
{
    Q_UNUSED(parameters)
    qCDebug(jveUICommandBridge, "Executing command: %s", qPrintable(commandType));
}

void UICommandBridge::logCommandResult(const QString& commandType, const QJsonObject& result)
{
    Q_UNUSED(result)
    qCDebug(jveUICommandBridge, "Command result: %s", qPrintable(commandType));
}