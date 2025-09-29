#pragma once

#include <QMainWindow>
#include <QMenuBar>
#include <QToolBar>
#include <QStatusBar>
#include <QDockWidget>
#include <QSplitter>
#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QAction>
#include <QActionGroup>
#include <QLabel>
#include <QProgressBar>
#include <QTimer>
#include <QSettings>
#include <QCloseEvent>
#include <QResizeEvent>
#include <QKeyEvent>
#include <QDragEnterEvent>
#include <QDropEvent>
#include <QMimeData>

#include "core/models/project.h"
#include "core/commands/command_dispatcher.h"
#include "ui/timeline/timeline_panel.h"
#include "ui/inspector/inspector_panel.h"
#include "ui/media/media_browser_panel.h"
#include "ui/project/project_panel.h"
#include "ui/selection/selection_manager.h"
#include "ui/input/keyboard_shortcuts.h"
#include "ui/common/ui_command_bridge.h"

/**
 * Professional main window for video editing application
 * 
 * Features:
 * - Professional docking layout similar to Avid/FCP7/Resolve
 * - Comprehensive menu system with keyboard shortcuts
 * - Multiple toolbar configurations
 * - Status bar with progress tracking and system information
 * - Customizable workspace layouts with presets
 * - Professional window management and state persistence
 * - Drag-and-drop file import to appropriate panels
 * - Full-screen and multi-monitor support
 * - Professional keyboard shortcut system
 * 
 * Layout Philosophy:
 * - Timeline dominates the bottom (industry standard)
 * - Inspector on the right for property editing
 * - Media browser on the left for asset management
 * - Project panel can be tabbed or floating
 * - Viewer in center (to be implemented later)
 * 
 * Design follows professional NLE window management patterns
 */
class MainWindow : public QMainWindow
{
    Q_OBJECT

public:
    explicit MainWindow(QWidget* parent = nullptr);
    ~MainWindow() = default;

    // Project management
    void newProject();
    void openProject();
    void openProject(const QString& filePath);
    void saveProject();
    void saveProjectAs();
    void closeProject();
    void recentProjects();
    
    // Workspace management
    void resetLayout();
    void saveWorkspace(const QString& name);
    void loadWorkspace(const QString& name);
    void deleteWorkspace(const QString& name);
    void setWorkspacePreset(const QString& preset);
    
    // View management
    void toggleTimelinePanel();
    void toggleInspectorPanel();
    void toggleMediaBrowserPanel();
    void toggleProjectPanel();
    void toggleFullScreen();
    void showPreferences();
    
    // Import and export
    void importMedia();
    void importProject();
    void exportSequence();
    void exportFrame();

signals:
    void projectOpened(const Project& project);
    void projectClosed();
    void workspaceChanged(const QString& workspaceName);

public slots:
    void onProjectChanged(const Project& project);
    void onSequenceSelected(const QString& sequenceId);
    void onMediaImported(const QStringList& mediaIds);
    void onCommandExecuted();
    void onProgressUpdate(int percentage, const QString& message);

protected:
    // Event handling
    void closeEvent(QCloseEvent* event) override;
    void resizeEvent(QResizeEvent* event) override;
    void keyPressEvent(QKeyEvent* event) override;
    void dragEnterEvent(QDragEnterEvent* event) override;
    void dropEvent(QDropEvent* event) override;

private slots:
    // File menu actions
    void onNewProject();
    void onOpenProject();
    void onSaveProject();
    void onSaveProjectAs();
    void onCloseProject();
    void onImportMedia();
    void onExportSequence();
    void onExit();
    
    // Edit menu actions
    void onUndo();
    void onRedo();
    void onCut();
    void onCopy();
    void onPaste();
    void onSelectAll();
    void onDeselectAll();
    
    // View menu actions
    void onResetLayout();
    void onToggleTimeline();
    void onToggleInspector();
    void onToggleMediaBrowser();
    void onToggleProject();
    void onToggleFullScreen();
    void onShowPreferences();
    
    // Window menu actions
    void onNewWindow();
    void onMinimizeWindow();
    void onZoomWindow();
    void onArrangeWindows();
    
    // Help menu actions
    void onShowHelp();
    void onKeyboardShortcuts();
    void onAbout();
    
    // Workspace actions
    void onWorkspaceChanged();
    void onSaveWorkspace();
    void onManageWorkspaces();
    
    // Status updates
    void onUpdateStatus();
    void onUpdateProgress();

private:
    // Setup methods
    void setupUI();
    void setupMenuBar();
    void setupToolBars();
    void setupStatusBar();
    void setupDockWidgets();
    void setupCentralWidget();
    void connectSignals();
    void setupKeyboardShortcuts();
    
    // Menu creation
    QMenu* createFileMenu();
    QMenu* createEditMenu();
    QMenu* createViewMenu();
    QMenu* createSequenceMenu();
    QMenu* createClipMenu();
    QMenu* createEffectsMenu();
    QMenu* createWindowMenu();
    QMenu* createHelpMenu();
    
    // Toolbar creation
    QToolBar* createMainToolBar();
    QToolBar* createEditToolBar();
    QToolBar* createPlaybackToolBar();
    QToolBar* createToolsToolBar();
    
    // Dock widget creation
    QDockWidget* createTimelineDock();
    QDockWidget* createInspectorDock();
    QDockWidget* createMediaBrowserDock();
    QDockWidget* createProjectDock();
    
    // Workspace management
    void initializeWorkspaces();
    void saveCurrentWorkspace();
    void restoreWorkspaceFromSettings(const QString& name);
    void createWorkspacePresets();
    
    // State management
    void saveState();
    void restoreState();
    void saveWindowGeometry();
    void restoreWindowGeometry();
    
    // Project state
    void updateProjectState();
    void updateWindowTitle();
    void updateRecentProjectsMenu();
    void enableProjectActions(bool enabled);
    
    // UI updates
    void updateMenuStates();
    void updateToolBarStates();
    void updateStatusBar();
    void updateProgressBar(int value, const QString& text = QString());
    
    // Utility methods
    QString getProjectDisplayName() const;
    bool hasUnsavedChanges() const;
    bool confirmCloseProject();
    void showProjectInTitle();
    QStringList getRecentProjects() const;
    void addToRecentProjects(const QString& filePath);
    
private:
    // Core components
    CommandDispatcher* m_commandDispatcher = nullptr;
    SelectionManager* m_selectionManager = nullptr;
    KeyboardShortcuts* m_keyboardShortcuts = nullptr;
    UICommandBridge* m_commandBridge = nullptr;
    Project m_currentProject;
    
    // UI panels
    TimelinePanel* m_timelinePanel = nullptr;
    InspectorPanel* m_inspectorPanel = nullptr;
    MediaBrowserPanel* m_mediaBrowserPanel = nullptr;
    ProjectPanel* m_projectPanel = nullptr;
    
    // Dock widgets
    QDockWidget* m_timelineDock = nullptr;
    QDockWidget* m_inspectorDock = nullptr;
    QDockWidget* m_mediaBrowserDock = nullptr;
    QDockWidget* m_projectDock = nullptr;
    
    // Central widget (future viewer)
    QWidget* m_centralWidget = nullptr;
    QLabel* m_placeholderLabel = nullptr;
    
    // Menu bar
    QMenuBar* m_menuBar = nullptr;
    QMenu* m_fileMenu = nullptr;
    QMenu* m_editMenu = nullptr;
    QMenu* m_viewMenu = nullptr;
    QMenu* m_sequenceMenu = nullptr;
    QMenu* m_clipMenu = nullptr;
    QMenu* m_effectsMenu = nullptr;
    QMenu* m_windowMenu = nullptr;
    QMenu* m_helpMenu = nullptr;
    QMenu* m_recentProjectsMenu = nullptr;
    QMenu* m_workspacesMenu = nullptr;
    
    // Tool bars
    QToolBar* m_mainToolBar = nullptr;
    QToolBar* m_editToolBar = nullptr;
    QToolBar* m_playbackToolBar = nullptr;
    QToolBar* m_toolsToolBar = nullptr;
    
    // Status bar
    QStatusBar* m_statusBar = nullptr;
    QLabel* m_statusLabel = nullptr;
    QLabel* m_timeLabel = nullptr;
    QLabel* m_frameRateLabel = nullptr;
    QLabel* m_resolutionLabel = nullptr;
    QProgressBar* m_progressBar = nullptr;
    
    // Actions - File menu
    QAction* m_newProjectAction = nullptr;
    QAction* m_openProjectAction = nullptr;
    QAction* m_saveProjectAction = nullptr;
    QAction* m_saveProjectAsAction = nullptr;
    QAction* m_closeProjectAction = nullptr;
    QAction* m_importMediaAction = nullptr;
    QAction* m_exportSequenceAction = nullptr;
    QAction* m_exitAction = nullptr;
    
    // Actions - Edit menu
    QAction* m_undoAction = nullptr;
    QAction* m_redoAction = nullptr;
    QAction* m_cutAction = nullptr;
    QAction* m_copyAction = nullptr;
    QAction* m_pasteAction = nullptr;
    QAction* m_selectAllAction = nullptr;
    QAction* m_deselectAllAction = nullptr;
    
    // Actions - View menu
    QAction* m_resetLayoutAction = nullptr;
    QAction* m_toggleTimelineAction = nullptr;
    QAction* m_toggleInspectorAction = nullptr;
    QAction* m_toggleMediaBrowserAction = nullptr;
    QAction* m_toggleProjectAction = nullptr;
    QAction* m_toggleFullScreenAction = nullptr;
    QAction* m_showPreferencesAction = nullptr;
    
    // Actions - Window menu
    QAction* m_newWindowAction = nullptr;
    QAction* m_minimizeAction = nullptr;
    QAction* m_zoomAction = nullptr;
    
    // Actions - Help menu
    QAction* m_showHelpAction = nullptr;
    QAction* m_keyboardShortcutsAction = nullptr;
    QAction* m_aboutAction = nullptr;
    
    // Workspace management
    QActionGroup* m_workspaceGroup = nullptr;
    QString m_currentWorkspace;
    QStringList m_workspacePresets;
    
    // State tracking
    bool m_isFullScreen = false;
    bool m_hasUnsavedChanges = false;
    QString m_lastSavedPath;
    QTimer* m_statusTimer = nullptr;
    QTimer* m_autosaveTimer = nullptr;
    
    // Settings
    QSettings* m_settings = nullptr;
    
    // Constants
    static constexpr int STATUS_TIMEOUT_MS = 5000;
    static constexpr int AUTOSAVE_INTERVAL_MS = 300000; // 5 minutes
    static constexpr int MAX_RECENT_PROJECTS = 10;
    
    // Professional styling
    QString m_styleSheet;
    QColor m_backgroundColor = QColor(30, 30, 30);
    QColor m_accentColor = QColor(70, 130, 180);
    QFont m_applicationFont = QFont("Arial", 9);
};