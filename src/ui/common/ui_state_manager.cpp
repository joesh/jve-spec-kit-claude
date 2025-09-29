#include "ui_state_manager.h"
#include <QApplication>
#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QDebug>

Q_LOGGING_CATEGORY(jveUIState, "jve.ui.state")

UIStateManager::UIStateManager(QObject* parent)
    : QObject(parent)
{
    qCDebug(jveUIState) << "Initializing UIStateManager";
    
    // Set default settings path
    QString defaultPath = QStandardPaths::writableLocation(QStandardPaths::AppConfigLocation);
    setSettingsPath(defaultPath);
    
    // Ensure settings directory exists
    ensureSettingsDirectory();
    
    // Setup auto-save timer
    setupAutoSave();
    
    // Create default workspaces
    createDefaultWorkspaces();
    
    // Connect to application exit for cleanup
    connect(QApplication::instance(), &QApplication::aboutToQuit,
            this, &UIStateManager::onApplicationExit);
}

UIStateManager::~UIStateManager()
{
    // Clean up settings instances
    for (auto it = m_settings.begin(); it != m_settings.end(); ++it) {
        delete it.value();
    }
    m_settings.clear();
}

void UIStateManager::setApplicationName(const QString& appName)
{
    m_applicationName = appName;
    qCDebug(jveUIState) << "Application name set to:" << appName;
}

void UIStateManager::setSettingsPath(const QString& path)
{
    m_settingsPath = path;
    qCDebug(jveUIState) << "Settings path set to:" << path;
    
    // Ensure directory exists
    ensureSettingsDirectory();
}

void UIStateManager::setAutoSaveInterval(int milliseconds)
{
    m_autoSaveInterval = milliseconds;
    if (m_autoSaveTimer) {
        m_autoSaveTimer->setInterval(milliseconds);
    }
    qCDebug(jveUIState) << "Auto-save interval set to:" << milliseconds << "ms";
}

void UIStateManager::enableCrashRecovery(bool enabled)
{
    m_crashRecoveryEnabled = enabled;
    qCDebug(jveUIState) << "Crash recovery:" << (enabled ? "enabled" : "disabled");
}

void UIStateManager::saveWindowState(QMainWindow* mainWindow, StateScope scope)
{
    if (!mainWindow) return;
    
    WindowState state;
    state.geometry = mainWindow->geometry();
    state.isMaximized = mainWindow->isMaximized();
    state.isFullScreen = mainWindow->isFullScreen();
    state.dockingState = mainWindow->saveState();
    state.activeWorkspace = m_currentWorkspace;
    
    // Save visible panels
    const QList<QDockWidget*> dockWidgets = mainWindow->findChildren<QDockWidget*>();
    for (QDockWidget* dock : dockWidgets) {
        if (dock->isVisible()) {
            state.visiblePanels << dock->objectName();
        }
    }
    
    setWindowState(state, scope);
    qCDebug(jveUIState) << "Window state saved for scope:" << scope;
}

void UIStateManager::restoreWindowState(QMainWindow* mainWindow, StateScope scope)
{
    if (!mainWindow) return;
    
    WindowState state = getWindowState(scope);
    
    if (!state.geometry.isNull()) {
        mainWindow->setGeometry(state.geometry);
    }
    
    if (state.isMaximized) {
        mainWindow->showMaximized();
    } else if (state.isFullScreen) {
        mainWindow->showFullScreen();
    }
    
    if (!state.dockingState.isEmpty()) {
        mainWindow->restoreState(state.dockingState);
    }
    
    m_currentWorkspace = state.activeWorkspace;
    m_mainWindow = mainWindow;
    
    qCDebug(jveUIState) << "Window state restored for scope:" << scope;
}

UIStateManager::WindowState UIStateManager::getWindowState(StateScope scope) const
{
    QSettings* settings = getSettings(scope);
    QJsonObject json = QJsonDocument::fromJson(
        settings->value("window_state").toByteArray()).object();
    
    return windowStateFromJson(json);
}

void UIStateManager::setWindowState(const WindowState& state, StateScope scope)
{
    QSettings* settings = getSettings(scope);
    QJsonObject json = windowStateToJson(state);
    QByteArray data = QJsonDocument(json).toJson(QJsonDocument::Compact);
    
    settings->setValue("window_state", data);
    settings->sync();
    
    m_hasUnsavedChanges = true;
    emit stateChanged(scope, "window_state");
}

void UIStateManager::savePanelState(const QString& panelId, QDockWidget* panel, StateScope scope)
{
    if (!panel) return;
    
    PanelState state;
    state.panelId = panelId;
    state.isVisible = panel->isVisible();
    state.isFloating = panel->isFloating();
    state.floatingGeometry = panel->geometry();
    
    // Determine dock area
    if (QMainWindow* mainWindow = qobject_cast<QMainWindow*>(panel->parent())) {
        state.dockArea = mainWindow->dockWidgetArea(panel);
    }
    
    setPanelState(panelId, state, scope);
    m_trackedPanels[panelId] = panel;
    
    qCDebug(jveUIState) << "Panel state saved:" << panelId;
}

void UIStateManager::restorePanelState(const QString& panelId, QDockWidget* panel, StateScope scope)
{
    if (!panel) return;
    
    PanelState state = getPanelState(panelId, scope);
    
    panel->setVisible(state.isVisible);
    
    if (state.isFloating) {
        panel->setFloating(true);
        if (!state.floatingGeometry.isNull()) {
            panel->setGeometry(state.floatingGeometry);
        }
    } else {
        panel->setFloating(false);
        if (QMainWindow* mainWindow = qobject_cast<QMainWindow*>(panel->parent())) {
            mainWindow->addDockWidget(state.dockArea, panel);
        }
    }
    
    m_trackedPanels[panelId] = panel;
    qCDebug(jveUIState) << "Panel state restored:" << panelId;
}

UIStateManager::PanelState UIStateManager::getPanelState(const QString& panelId, StateScope scope) const
{
    QSettings* settings = getSettings(scope);
    QString key = QString("%1%2").arg(PANEL_KEY_PREFIX, panelId);
    QJsonObject json = QJsonDocument::fromJson(
        settings->value(key).toByteArray()).object();
    
    return panelStateFromJson(json);
}

void UIStateManager::setPanelState(const QString& panelId, const PanelState& state, StateScope scope)
{
    QSettings* settings = getSettings(scope);
    QString key = QString("%1%2").arg(PANEL_KEY_PREFIX, panelId);
    QJsonObject json = panelStateToJson(state);
    QByteArray data = QJsonDocument(json).toJson(QJsonDocument::Compact);
    
    settings->setValue(key, data);
    settings->sync();
    
    m_hasUnsavedChanges = true;
    emit stateChanged(scope, key);
}

void UIStateManager::saveSplitterState(const QString& splitterId, QSplitter* splitter, StateScope scope)
{
    if (!splitter) return;
    
    SplitterState state;
    state.splitterId = splitterId;
    state.state = splitter->saveState();
    state.sizes = splitter->sizes();
    state.orientation = splitter->orientation();
    
    setSplitterState(splitterId, state, scope);
    m_trackedSplitters[splitterId] = splitter;
    
    qCDebug(jveUIState) << "Splitter state saved:" << splitterId;
}

void UIStateManager::restoreSplitterState(const QString& splitterId, QSplitter* splitter, StateScope scope)
{
    if (!splitter) return;
    
    SplitterState state = getSplitterState(splitterId, scope);
    
    if (!state.state.isEmpty()) {
        splitter->restoreState(state.state);
    } else if (!state.sizes.isEmpty()) {
        splitter->setSizes(state.sizes);
    }
    
    splitter->setOrientation(state.orientation);
    m_trackedSplitters[splitterId] = splitter;
    
    qCDebug(jveUIState) << "Splitter state restored:" << splitterId;
}

UIStateManager::SplitterState UIStateManager::getSplitterState(const QString& splitterId, StateScope scope) const
{
    QSettings* settings = getSettings(scope);
    QString key = QString("%1%2").arg(SPLITTER_KEY_PREFIX, splitterId);
    QJsonObject json = QJsonDocument::fromJson(
        settings->value(key).toByteArray()).object();
    
    return splitterStateFromJson(json);
}

void UIStateManager::setSplitterState(const QString& splitterId, const SplitterState& state, StateScope scope)
{
    QSettings* settings = getSettings(scope);
    QString key = QString("%1%2").arg(SPLITTER_KEY_PREFIX, splitterId);
    QJsonObject json = splitterStateToJson(state);
    QByteArray data = QJsonDocument(json).toJson(QJsonDocument::Compact);
    
    settings->setValue(key, data);
    settings->sync();
    
    m_hasUnsavedChanges = true;
    emit stateChanged(scope, key);
}

void UIStateManager::saveViewState(const QString& viewId, const ViewState& state, StateScope scope)
{
    setViewState(viewId, state, scope);
    qCDebug(jveUIState) << "View state saved:" << viewId;
}

UIStateManager::ViewState UIStateManager::getViewState(const QString& viewId, StateScope scope) const
{
    QSettings* settings = getSettings(scope);
    QString key = QString("%1%2").arg(VIEW_KEY_PREFIX, viewId);
    QJsonObject json = QJsonDocument::fromJson(
        settings->value(key).toByteArray()).object();
    
    return viewStateFromJson(json);
}

void UIStateManager::setViewState(const QString& viewId, const ViewState& state, StateScope scope)
{
    QSettings* settings = getSettings(scope);
    QString key = QString("%1%2").arg(VIEW_KEY_PREFIX, viewId);
    QJsonObject json = viewStateToJson(state);
    QByteArray data = QJsonDocument(json).toJson(QJsonDocument::Compact);
    
    settings->setValue(key, data);
    settings->sync();
    
    m_hasUnsavedChanges = true;
    emit stateChanged(scope, key);
}

void UIStateManager::saveWorkspace(const QString& workspaceName, WorkspaceType type)
{
    Q_UNUSED(type)
    
    QJsonObject workspaceData = captureCurrentWorkspaceState();
    saveWorkspaceToSettings(workspaceName, workspaceData);
    
    qCDebug(jveUIState) << "Workspace saved:" << workspaceName;
}

void UIStateManager::loadWorkspace(const QString& workspaceName)
{
    QJsonObject workspaceData = loadWorkspaceFromSettings(workspaceName);
    if (!workspaceData.isEmpty()) {
        applyWorkspaceState(workspaceData);
        m_currentWorkspace = workspaceName;
        emit workspaceChanged(workspaceName);
        qCDebug(jveUIState) << "Workspace loaded:" << workspaceName;
    }
}

void UIStateManager::deleteWorkspace(const QString& workspaceName)
{
    QSettings* settings = getSettings(WorkspaceScope);
    QString key = QString("%1%2").arg(WORKSPACE_KEY_PREFIX, workspaceName);
    settings->remove(key);
    settings->sync();
    
    qCDebug(jveUIState) << "Workspace deleted:" << workspaceName;
}

QStringList UIStateManager::getAvailableWorkspaces() const
{
    QSettings* settings = getSettings(WorkspaceScope);
    QStringList workspaces;
    
    settings->beginGroup("");
    const QStringList keys = settings->allKeys();
    for (const QString& key : keys) {
        if (key.startsWith(WORKSPACE_KEY_PREFIX)) {
            QString workspaceName = key.mid(QString(WORKSPACE_KEY_PREFIX).length());
            workspaces << workspaceName;
        }
    }
    settings->endGroup();
    
    return workspaces;
}

QString UIStateManager::getCurrentWorkspace() const
{
    return m_currentWorkspace;
}

void UIStateManager::createDefaultWorkspaces()
{
    if (m_defaultWorkspaces.isEmpty()) {
        m_defaultWorkspaces[EditingWorkspace] = createEditingWorkspaceData();
        m_defaultWorkspaces[ColorWorkspace] = createColorWorkspaceData();
        m_defaultWorkspaces[AudioWorkspace] = createAudioWorkspaceData();
        m_defaultWorkspaces[EffectsWorkspace] = createEffectsWorkspaceData();
        
        qCDebug(jveUIState) << "Default workspaces created";
    }
}

void UIStateManager::resetToDefaultWorkspace(WorkspaceType type)
{
    if (m_defaultWorkspaces.contains(type)) {
        applyWorkspaceState(m_defaultWorkspaces[type]);
        qCDebug(jveUIState) << "Reset to default workspace:" << type;
    }
}

void UIStateManager::setValue(const QString& key, const QVariant& value, StateScope scope)
{
    QSettings* settings = getSettings(scope);
    settings->setValue(key, value);
    settings->sync();
    
    m_hasUnsavedChanges = true;
    emit stateChanged(scope, key);
}

QVariant UIStateManager::getValue(const QString& key, const QVariant& defaultValue, StateScope scope) const
{
    QSettings* settings = getSettings(scope);
    return settings->value(key, defaultValue);
}

void UIStateManager::removeValue(const QString& key, StateScope scope)
{
    QSettings* settings = getSettings(scope);
    settings->remove(key);
    settings->sync();
    
    emit stateChanged(scope, key);
}

void UIStateManager::saveAllStates()
{
    if (m_mainWindow) {
        saveWindowState(m_mainWindow, ApplicationScope);
    }
    
    // Save all tracked panels
    for (auto it = m_trackedPanels.begin(); it != m_trackedPanels.end(); ++it) {
        savePanelState(it.key(), it.value(), ApplicationScope);
    }
    
    // Save all tracked splitters
    for (auto it = m_trackedSplitters.begin(); it != m_trackedSplitters.end(); ++it) {
        saveSplitterState(it.key(), it.value(), ApplicationScope);
    }
    
    emit autoSaveCompleted();
    qCDebug(jveUIState) << "All states saved";
}

void UIStateManager::restoreAllStates()
{
    if (m_mainWindow) {
        restoreWindowState(m_mainWindow, ApplicationScope);
    }
    
    qCDebug(jveUIState) << "All states restored";
}

QSettings* UIStateManager::getSettings(StateScope scope) const
{
    if (!m_settings.contains(scope)) {
        QString filePath = getSettingsFilePath(scope);
        m_settings[scope] = new QSettings(filePath, QSettings::IniFormat);
    }
    
    return m_settings[scope];
}

QString UIStateManager::getSettingsFilePath(StateScope scope) const
{
    QString scopeName = getScopeKey(scope);
    QString fileName = QString("%1_%2.ini").arg(m_applicationName.toLower(), scopeName);
    return QDir(m_settingsPath).absoluteFilePath(fileName);
}

QString UIStateManager::getScopeKey(StateScope scope) const
{
    switch (scope) {
    case ApplicationScope: return "application";
    case ProjectScope: return "project";
    case SessionScope: return "session";
    case WorkspaceScope: return "workspace";
    default: return "unknown";
    }
}

QJsonObject UIStateManager::windowStateToJson(const WindowState& state) const
{
    QJsonObject json;
    json["geometry"] = QJsonArray{state.geometry.x(), state.geometry.y(), 
                                 state.geometry.width(), state.geometry.height()};
    json["isMaximized"] = state.isMaximized;
    json["isFullScreen"] = state.isFullScreen;
    json["dockingState"] = QString::fromLatin1(state.dockingState.toBase64());
    json["visiblePanels"] = QJsonArray::fromStringList(state.visiblePanels);
    json["activeWorkspace"] = state.activeWorkspace;
    return json;
}

UIStateManager::WindowState UIStateManager::windowStateFromJson(const QJsonObject& json) const
{
    WindowState state;
    
    if (json.contains("geometry")) {
        QJsonArray geom = json["geometry"].toArray();
        if (geom.size() == 4) {
            state.geometry = QRect(geom[0].toInt(), geom[1].toInt(), 
                                 geom[2].toInt(), geom[3].toInt());
        }
    }
    
    state.isMaximized = json["isMaximized"].toBool();
    state.isFullScreen = json["isFullScreen"].toBool();
    state.dockingState = QByteArray::fromBase64(json["dockingState"].toString().toLatin1());
    state.activeWorkspace = json["activeWorkspace"].toString();
    
    QJsonArray panels = json["visiblePanels"].toArray();
    for (const QJsonValue& panel : panels) {
        state.visiblePanels << panel.toString();
    }
    
    return state;
}

QJsonObject UIStateManager::panelStateToJson(const PanelState& state) const
{
    QJsonObject json;
    json["panelId"] = state.panelId;
    json["isVisible"] = state.isVisible;
    json["isFloating"] = state.isFloating;
    json["floatingGeometry"] = QJsonArray{state.floatingGeometry.x(), state.floatingGeometry.y(),
                                        state.floatingGeometry.width(), state.floatingGeometry.height()};
    json["dockArea"] = static_cast<int>(state.dockArea);
    json["tabIndex"] = state.tabIndex;
    json["customData"] = state.customData;
    return json;
}

UIStateManager::PanelState UIStateManager::panelStateFromJson(const QJsonObject& json) const
{
    PanelState state;
    state.panelId = json["panelId"].toString();
    state.isVisible = json["isVisible"].toBool();
    state.isFloating = json["isFloating"].toBool();
    state.dockArea = static_cast<Qt::DockWidgetArea>(json["dockArea"].toInt());
    state.tabIndex = json["tabIndex"].toInt();
    state.customData = json["customData"].toObject();
    
    if (json.contains("floatingGeometry")) {
        QJsonArray geom = json["floatingGeometry"].toArray();
        if (geom.size() == 4) {
            state.floatingGeometry = QRect(geom[0].toInt(), geom[1].toInt(),
                                         geom[2].toInt(), geom[3].toInt());
        }
    }
    
    return state;
}

QJsonObject UIStateManager::splitterStateToJson(const SplitterState& state) const
{
    QJsonObject json;
    json["splitterId"] = state.splitterId;
    json["state"] = QString::fromLatin1(state.state.toBase64());
    json["orientation"] = static_cast<int>(state.orientation);
    
    QJsonArray sizes;
    for (int size : state.sizes) {
        sizes.append(size);
    }
    json["sizes"] = sizes;
    
    return json;
}

UIStateManager::SplitterState UIStateManager::splitterStateFromJson(const QJsonObject& json) const
{
    SplitterState state;
    state.splitterId = json["splitterId"].toString();
    state.state = QByteArray::fromBase64(json["state"].toString().toLatin1());
    state.orientation = static_cast<Qt::Orientation>(json["orientation"].toInt());
    
    QJsonArray sizes = json["sizes"].toArray();
    for (const QJsonValue& size : sizes) {
        state.sizes << size.toInt();
    }
    
    return state;
}

QJsonObject UIStateManager::viewStateToJson(const ViewState& state) const
{
    QJsonObject json;
    json["viewId"] = state.viewId;
    json["zoomLevel"] = state.zoomLevel;
    json["scrollPosition"] = QJsonArray{state.scrollPosition.x(), state.scrollPosition.y()};
    json["viewMode"] = state.viewMode;
    json["filterState"] = state.filterState;
    json["headerState"] = QString::fromLatin1(state.headerState.toBase64());
    return json;
}

UIStateManager::ViewState UIStateManager::viewStateFromJson(const QJsonObject& json) const
{
    ViewState state;
    state.viewId = json["viewId"].toString();
    state.zoomLevel = json["zoomLevel"].toDouble(1.0);
    state.viewMode = json["viewMode"].toString();
    state.filterState = json["filterState"].toObject();
    state.headerState = QByteArray::fromBase64(json["headerState"].toString().toLatin1());
    
    if (json.contains("scrollPosition")) {
        QJsonArray pos = json["scrollPosition"].toArray();
        if (pos.size() == 2) {
            state.scrollPosition = QPoint(pos[0].toInt(), pos[1].toInt());
        }
    }
    
    return state;
}

void UIStateManager::setupAutoSave()
{
    m_autoSaveTimer = new QTimer(this);
    m_autoSaveTimer->setInterval(m_autoSaveInterval);
    m_autoSaveTimer->setSingleShot(false);
    
    connect(m_autoSaveTimer, &QTimer::timeout, this, &UIStateManager::onAutoSave);
    m_autoSaveTimer->start();
}

void UIStateManager::ensureSettingsDirectory() const
{
    QDir dir(m_settingsPath);
    if (!dir.exists()) {
        dir.mkpath(".");
        qCDebug(jveUIState) << "Created settings directory:" << m_settingsPath;
    }
}

QJsonObject UIStateManager::captureCurrentWorkspaceState() const
{
    QJsonObject workspace;
    workspace["name"] = m_currentWorkspace;
    workspace["timestamp"] = QDateTime::currentDateTime().toString(Qt::ISODate);
    
    // Would capture current window and panel states here
    return workspace;
}

void UIStateManager::applyWorkspaceState(const QJsonObject& workspaceData)
{
    Q_UNUSED(workspaceData)
    // Would apply workspace configuration here
}

QJsonObject UIStateManager::createEditingWorkspaceData() const
{
    QJsonObject workspace;
    workspace["name"] = "Editing";
    workspace["type"] = EditingWorkspace;
    workspace["description"] = "Standard editing layout with timeline focus";
    return workspace;
}

QJsonObject UIStateManager::createColorWorkspaceData() const
{
    QJsonObject workspace;
    workspace["name"] = "Color";
    workspace["type"] = ColorWorkspace;
    workspace["description"] = "Color correction focused layout";
    return workspace;
}

QJsonObject UIStateManager::createAudioWorkspaceData() const
{
    QJsonObject workspace;
    workspace["name"] = "Audio";
    workspace["type"] = AudioWorkspace;
    workspace["description"] = "Audio mixing focused layout";
    return workspace;
}

QJsonObject UIStateManager::createEffectsWorkspaceData() const
{
    QJsonObject workspace;
    workspace["name"] = "Effects";
    workspace["type"] = EffectsWorkspace;
    workspace["description"] = "Effects and compositing layout";
    return workspace;
}

void UIStateManager::onAutoSave()
{
    if (m_hasUnsavedChanges) {
        emit autoSaveStarted();
        
        try {
            saveAllStates();
            if (m_crashRecoveryEnabled) {
                saveCrashRecoveryData();
            }
            m_hasUnsavedChanges = false;
        } catch (const std::exception& e) {
            emit autoSaveFailed(QString::fromStdString(e.what()));
        }
    }
}

void UIStateManager::onApplicationExit()
{
    qCDebug(jveUIState) << "Application exiting, saving final state";
    saveAllStates();
    clearCrashRecoveryData();
}

void UIStateManager::onSettingsFileChanged()
{
    qCDebug(jveUIState) << "Settings file changed - reloading configuration";
    
    // Reload settings from all scopes
    for (auto scope : {ApplicationScope, ProjectScope, SessionScope, WorkspaceScope}) {
        if (m_settings.contains(scope)) {
            delete m_settings[scope];
            m_settings.remove(scope);
        }
    }
    
    // Re-initialize settings
    restoreAllStates();
    emit settingsReloaded();
}

void UIStateManager::saveCrashRecoveryData()
{
    if (!m_crashRecoveryEnabled) {
        return;
    }
    
    qCDebug(jveUIState) << "Saving crash recovery data";
    
    QJsonObject recoveryData;
    recoveryData["timestamp"] = QDateTime::currentDateTime().toString(Qt::ISODate);
    recoveryData["version"] = QCoreApplication::applicationVersion();
    
    // Save current state
    if (m_mainWindow) {
        WindowState windowState = getWindowState(ApplicationScope);
        recoveryData["windowState"] = windowStateToJson(windowState);
    }
    
    // Save current workspace
    recoveryData["currentWorkspace"] = m_currentWorkspace;
    recoveryData["workspaceState"] = captureCurrentWorkspaceState();
    
    // Write to crash recovery file
    QString recoveryPath = QDir(m_settingsPath).absoluteFilePath("crash_recovery.json");
    QFile recoveryFile(recoveryPath);
    if (recoveryFile.open(QIODevice::WriteOnly)) {
        QJsonDocument doc(recoveryData);
        recoveryFile.write(doc.toJson());
        recoveryFile.close();
        qCDebug(jveUIState) << "Crash recovery data saved to:" << recoveryPath;
    } else {
        qCWarning(jveUIState) << "Failed to save crash recovery data:" << recoveryFile.errorString();
    }
}

void UIStateManager::clearCrashRecoveryData()
{
    QString recoveryPath = QDir(m_settingsPath).absoluteFilePath("crash_recovery.json");
    QFile recoveryFile(recoveryPath);
    if (recoveryFile.exists()) {
        if (recoveryFile.remove()) {
            qCDebug(jveUIState) << "Crash recovery data cleared";
        } else {
            qCWarning(jveUIState) << "Failed to clear crash recovery data:" << recoveryFile.errorString();
        }
    }
}

void UIStateManager::saveWorkspaceToSettings(const QString& workspaceName, const QJsonObject& workspaceData)
{
    QSettings* settings = getSettings(WorkspaceScope);
    settings->beginGroup("CustomWorkspaces");
    
    // Convert QJsonObject to settings-compatible format
    settings->setValue(workspaceName + "/name", workspaceData["name"].toString());
    settings->setValue(workspaceName + "/type", workspaceData["type"].toInt());
    settings->setValue(workspaceName + "/description", workspaceData["description"].toString());
    
    // Save workspace configuration as JSON string
    QJsonDocument doc(workspaceData);
    settings->setValue(workspaceName + "/configuration", doc.toJson(QJsonDocument::Compact));
    
    settings->endGroup();
    settings->sync();
    
    qCDebug(jveUIState) << "Workspace saved to settings:" << workspaceName;
}

QJsonObject UIStateManager::loadWorkspaceFromSettings(const QString& workspaceName) const
{
    QSettings* settings = getSettings(WorkspaceScope);
    settings->beginGroup("CustomWorkspaces");
    
    if (!settings->childGroups().contains(workspaceName)) {
        settings->endGroup();
        return QJsonObject();
    }
    
    settings->beginGroup(workspaceName);
    
    QJsonObject workspaceData;
    workspaceData["name"] = settings->value("name").toString();
    workspaceData["type"] = settings->value("type").toInt();
    workspaceData["description"] = settings->value("description").toString();
    
    // Load full configuration from JSON string
    QByteArray configData = settings->value("configuration").toByteArray();
    if (!configData.isEmpty()) {
        QJsonDocument doc = QJsonDocument::fromJson(configData);
        if (!doc.isNull() && doc.isObject()) {
            QJsonObject fullConfig = doc.object();
            // Merge with basic data
            for (auto it = fullConfig.begin(); it != fullConfig.end(); ++it) {
                workspaceData[it.key()] = it.value();
            }
        }
    }
    
    settings->endGroup();
    settings->endGroup();
    
    qCDebug(jveUIState) << "Workspace loaded from settings:" << workspaceName;
    return workspaceData;
}

void UIStateManager::onWorkspaceChangeRequested(const QString& workspaceName)
{
    qCDebug(jveUIState) << "Workspace change requested:" << workspaceName;
    
    if (m_currentWorkspace == workspaceName) {
        qCDebug(jveUIState) << "Already in requested workspace";
        return;
    }
    
    // Save current workspace state before switching
    if (!m_currentWorkspace.isEmpty()) {
        QJsonObject currentState = captureCurrentWorkspaceState();
        saveWorkspaceToSettings(m_currentWorkspace, currentState);
    }
    
    // Load and apply new workspace
    QJsonObject newWorkspaceData = loadWorkspaceFromSettings(workspaceName);
    if (!newWorkspaceData.isEmpty()) {
        applyWorkspaceState(newWorkspaceData);
        m_currentWorkspace = workspaceName;
        emit workspaceChanged(workspaceName);
        qCDebug(jveUIState) << "Switched to workspace:" << workspaceName;
    } else {
        qCWarning(jveUIState) << "Failed to load workspace:" << workspaceName;
    }
}