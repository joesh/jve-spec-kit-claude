#include "main_window.h"
#include "../../core/api/project_manager.h"
#include "../../core/persistence/migrations.h"
#include "../../core/models/project.h"
#include "../../core/models/sequence.h"
#include <QApplication>
#include <QMessageBox>
#include <QFileDialog>
#include <QInputDialog>
#include <QStandardPaths>
#include <QDesktopServices>
#include <QUrl>
#include <QSplitter>
#include <QLoggingCategory>
#include <QSqlDatabase>
#include <QSqlError>
#include <QDir>

Q_LOGGING_CATEGORY(jveMainWindow, "jve.ui.main")

MainWindow::MainWindow(QWidget* parent)
    : QMainWindow(parent)
{
    // Initialize core components first
    m_commandDispatcher = new CommandDispatcher(this);
    m_selectionManager = new SelectionManager(this);
    m_keyboardShortcuts = new KeyboardShortcuts(this);
    m_commandBridge = new UICommandBridge(m_commandDispatcher, m_selectionManager, this);
    m_settings = new QSettings(this);
    
    // Initialize database for command system
    initializeDatabase();
    
    setupUI();
    setupMenuBar();
    setupToolBars();
    setupStatusBar();
    setupDockWidgets();
    setupCentralWidget();
    connectSignals();
    setupKeyboardShortcuts();
    
    // Initialize workspace management
    initializeWorkspaces();
    
    // Restore window state
    restoreState();
    restoreWindowGeometry();
    
    // Setup timers
    m_statusTimer = new QTimer(this);
    m_statusTimer->setSingleShot(true);
    connect(m_statusTimer, &QTimer::timeout, [this]() {
        m_statusLabel->setText("Ready");
    });
    
    m_autosaveTimer = new QTimer(this);
    m_autosaveTimer->setInterval(AUTOSAVE_INTERVAL_MS);
    connect(m_autosaveTimer, &QTimer::timeout, this, &MainWindow::saveProject);
    
    // Initialize UI state
    enableProjectActions(false);
    updateWindowTitle();
    
    qCDebug(jveMainWindow, "Main window initialized");
    
    // Test command execution (temporary debug code) - run after UI is fully set up
    testCommandExecution();
    
    // Test auto import (temporary debug code) - run after UI is fully set up 
    testAutoImport();
}

void MainWindow::setupUI()
{
    // Set window properties
    setWindowTitle("JVE Editor");
    setMinimumSize(1200, 800);
    resize(1600, 1000);
    
    // Enable docking
    setDockNestingEnabled(true);
    setDockOptions(QMainWindow::AllowTabbedDocks | QMainWindow::AllowNestedDocks);
    
    // Apply professional styling
    m_styleSheet = QString(
        "QMainWindow { background: %1; }"
        "QMenuBar { background: %1; border-bottom: 1px solid #333; padding: 4px; }"
        "QMenuBar::item { background: transparent; padding: 6px 12px; }"
        "QMenuBar::item:selected { background: %2; }"
        "QMenu { background: %1; border: 1px solid #333; }"
        "QMenu::item { padding: 6px 24px; }"
        "QMenu::item:selected { background: %2; }"
        "QMenu::separator { height: 1px; background: #333; margin: 2px 0; }"
        "QToolBar { background: %1; border: none; spacing: 2px; }"
        "QToolBar::separator { background: #333; width: 1px; margin: 4px; }"
        "QStatusBar { background: %1; border-top: 1px solid #333; }"
        "QDockWidget { background: %1; }"
        "QDockWidget::title { background: #333; padding: 4px; text-align: center; }"
        "QDockWidget::close-button, QDockWidget::float-button {"
        "    background: transparent; border: none; padding: 2px;"
        "}"
        "QSplitter::handle { background: #333; }"
    ).arg(m_backgroundColor.name()).arg(m_accentColor.name());
    
    setStyleSheet(m_styleSheet);
    setFont(m_applicationFont);
}

void MainWindow::setupMenuBar()
{
    m_menuBar = menuBar();
    
    // Create menus
    m_fileMenu = createFileMenu();
    m_editMenu = createEditMenu();
    m_viewMenu = createViewMenu();
    m_sequenceMenu = createSequenceMenu();
    m_clipMenu = createClipMenu();
    m_effectsMenu = createEffectsMenu();
    m_windowMenu = createWindowMenu();
    m_helpMenu = createHelpMenu();
    
    // Add menus to menu bar
    m_menuBar->addMenu(m_fileMenu);
    m_menuBar->addMenu(m_editMenu);
    m_menuBar->addMenu(m_viewMenu);
    m_menuBar->addMenu(m_sequenceMenu);
    m_menuBar->addMenu(m_clipMenu);
    m_menuBar->addMenu(m_effectsMenu);
    m_menuBar->addMenu(m_windowMenu);
    m_menuBar->addMenu(m_helpMenu);
}

void MainWindow::setupToolBars()
{
    // Create toolbars
    m_mainToolBar = createMainToolBar();
    m_editToolBar = createEditToolBar();
    m_playbackToolBar = createPlaybackToolBar();
    m_toolsToolBar = createToolsToolBar();
    
    // Add toolbars to window
    addToolBar(Qt::TopToolBarArea, m_mainToolBar);
    addToolBar(Qt::TopToolBarArea, m_editToolBar);
    addToolBar(Qt::TopToolBarArea, m_playbackToolBar);
    addToolBar(Qt::TopToolBarArea, m_toolsToolBar);
    
    // Set toolbar properties
    m_mainToolBar->setMovable(true);
    m_editToolBar->setMovable(true);
    m_playbackToolBar->setMovable(true);
    m_toolsToolBar->setMovable(true);
}

void MainWindow::setupStatusBar()
{
    m_statusBar = statusBar();
    
    // Status label
    m_statusLabel = new QLabel("Ready");
    m_statusLabel->setMinimumWidth(200);
    m_statusBar->addWidget(m_statusLabel);
    
    // Add separator
    m_statusBar->addPermanentWidget(new QLabel("|"));
    
    // Time display
    m_timeLabel = new QLabel("00:00:00:00");
    m_timeLabel->setMinimumWidth(80);
    m_statusBar->addPermanentWidget(m_timeLabel);
    
    // Frame rate display
    m_frameRateLabel = new QLabel("23.98 fps");
    m_frameRateLabel->setMinimumWidth(70);
    m_statusBar->addPermanentWidget(m_frameRateLabel);
    
    // Resolution display
    m_resolutionLabel = new QLabel("1920x1080");
    m_resolutionLabel->setMinimumWidth(80);
    m_statusBar->addPermanentWidget(m_resolutionLabel);
    
    // Progress bar
    m_progressBar = new QProgressBar();
    m_progressBar->setVisible(false);
    m_progressBar->setMaximumWidth(200);
    m_statusBar->addPermanentWidget(m_progressBar);
}

void MainWindow::setupDockWidgets()
{
    // Create dock widgets
    m_timelineDock = createTimelineDock();
    m_inspectorDock = createInspectorDock();
    m_mediaBrowserDock = createMediaBrowserDock();
    m_projectDock = createProjectDock();
    
    // Add dock widgets to window
    addDockWidget(Qt::BottomDockWidgetArea, m_timelineDock);
    addDockWidget(Qt::RightDockWidgetArea, m_inspectorDock);
    addDockWidget(Qt::LeftDockWidgetArea, m_mediaBrowserDock);
    addDockWidget(Qt::LeftDockWidgetArea, m_projectDock);
    
    // Tab the left side panels
    tabifyDockWidget(m_mediaBrowserDock, m_projectDock);
    m_mediaBrowserDock->raise(); // Make media browser the active tab
    
    // Set initial sizes - timeline should take significant vertical space
    resizeDocks({m_timelineDock}, {400}, Qt::Vertical);
    resizeDocks({m_mediaBrowserDock, m_inspectorDock}, {300, 300}, Qt::Horizontal);
}

void MainWindow::setupCentralWidget()
{
    // Create placeholder central widget (viewer will go here later)
    m_centralWidget = new QWidget();
    m_centralWidget->setMinimumSize(400, 300);
    
    QVBoxLayout* layout = new QVBoxLayout(m_centralWidget);
    layout->setContentsMargins(20, 20, 20, 20);
    
    m_placeholderLabel = new QLabel("Viewer Panel\n(To be implemented)");
    m_placeholderLabel->setAlignment(Qt::AlignCenter);
    m_placeholderLabel->setStyleSheet(
        "QLabel { "
        "   background: #333; "
        "   border: 2px dashed #666; "
        "   border-radius: 8px; "
        "   color: #999; "
        "   font-size: 18px; "
        "   padding: 40px; "
        "}"
    );
    
    layout->addWidget(m_placeholderLabel);
    setCentralWidget(m_centralWidget);
}

void MainWindow::connectSignals()
{
    // Connect panel signals
    if (m_timelinePanel) {
        connect(m_timelinePanel, &TimelinePanel::playheadPositionChanged,
                this, [this](qint64 timeMs) {
                    // Update time display
                    qint64 frames = timeMs * 24 / 1000; // Assume 24fps for now
                    qint64 seconds = frames / 24;
                    qint64 minutes = seconds / 60;
                    qint64 hours = minutes / 60;
                    
                    m_timeLabel->setText(QString("%1:%2:%3:%4")
                        .arg(hours, 2, 10, QChar('0'))
                        .arg(minutes % 60, 2, 10, QChar('0'))
                        .arg(seconds % 60, 2, 10, QChar('0'))
                        .arg(frames % 24, 2, 10, QChar('0')));
                });
    }
    
    if (m_projectPanel) {
        connect(m_projectPanel, &ProjectPanel::projectChanged, this, &MainWindow::onProjectChanged);
        connect(m_projectPanel, &ProjectPanel::sequenceSelected, this, &MainWindow::onSequenceSelected);
    }
    
    if (m_mediaBrowserPanel) {
        connect(m_mediaBrowserPanel, &MediaBrowserPanel::mediaImportRequested,
                this, [this](const QStringList& filePaths, const QString& binId) {
                    Q_UNUSED(binId)
                    onMediaImported(filePaths);
                });
    }
}

void MainWindow::setupKeyboardShortcuts()
{
    // Load default shortcuts into the keyboard shortcuts system
    m_keyboardShortcuts->loadDefaultShortcuts();
    
    // Connect keyboard shortcut signals to main window actions
    connect(m_keyboardShortcuts, &KeyboardShortcuts::playPauseRequested, 
            this, [this]() { qCDebug(jveMainWindow) << "Play/Pause requested"; });
    connect(m_keyboardShortcuts, &KeyboardShortcuts::stopRequested,
            this, [this]() { qCDebug(jveMainWindow) << "Stop requested"; });
    connect(m_keyboardShortcuts, &KeyboardShortcuts::playBackwardRequested,
            this, [this]() { qCDebug(jveMainWindow) << "Play backward requested"; });
    connect(m_keyboardShortcuts, &KeyboardShortcuts::playForwardRequested,
            this, [this]() { qCDebug(jveMainWindow) << "Play forward requested"; });
    
    // Editing shortcuts
    connect(m_keyboardShortcuts, &KeyboardShortcuts::bladeToolRequested,
            this, [this]() { qCDebug(jveMainWindow) << "Blade tool requested"; });
    connect(m_keyboardShortcuts, &KeyboardShortcuts::selectionToolRequested,
            this, [this]() { qCDebug(jveMainWindow) << "Selection tool requested"; });
    connect(m_keyboardShortcuts, &KeyboardShortcuts::arrowToolRequested,
            this, [this]() { qCDebug(jveMainWindow) << "Arrow tool requested"; });
    
    // Timeline shortcuts
    connect(m_keyboardShortcuts, &KeyboardShortcuts::splitClipRequested,
            this, [this]() { qCDebug(jveMainWindow) << "Split clip requested"; });
    connect(m_keyboardShortcuts, &KeyboardShortcuts::deleteClipRequested,
            this, [this]() { qCDebug(jveMainWindow) << "Delete clip requested"; });
    connect(m_keyboardShortcuts, &KeyboardShortcuts::copyRequested,
            m_commandBridge, &UICommandBridge::copySelectedClips);
    connect(m_keyboardShortcuts, &KeyboardShortcuts::pasteRequested,
            this, [this]() { 
                // Paste to current timeline position - would need playhead position
                qCDebug(jveMainWindow) << "Paste requested - would paste to current timeline position"; 
            });
    connect(m_keyboardShortcuts, &KeyboardShortcuts::cutRequested,
            m_commandBridge, &UICommandBridge::cutSelectedClips);
    connect(m_keyboardShortcuts, &KeyboardShortcuts::undoRequested,
            m_commandBridge, &UICommandBridge::undo);
    connect(m_keyboardShortcuts, &KeyboardShortcuts::redoRequested,
            m_commandBridge, &UICommandBridge::redo);
    
    // Selection shortcuts
    connect(m_keyboardShortcuts, &KeyboardShortcuts::selectAllRequested,
            m_commandBridge, &UICommandBridge::selectAllClips);
    connect(m_keyboardShortcuts, &KeyboardShortcuts::deselectAllRequested,
            m_commandBridge, &UICommandBridge::deselectAllClips);
    
    // Navigation shortcuts
    connect(m_keyboardShortcuts, &KeyboardShortcuts::zoomInRequested,
            this, [this]() { qCDebug(jveMainWindow) << "Zoom in requested"; });
    connect(m_keyboardShortcuts, &KeyboardShortcuts::zoomOutRequested,
            this, [this]() { qCDebug(jveMainWindow) << "Zoom out requested"; });
    connect(m_keyboardShortcuts, &KeyboardShortcuts::zoomToFitRequested,
            this, [this]() { qCDebug(jveMainWindow) << "Zoom to fit requested"; });
    
    // Window shortcuts
    connect(m_keyboardShortcuts, &KeyboardShortcuts::toggleTimelineRequested,
            this, &MainWindow::onToggleTimeline);
    connect(m_keyboardShortcuts, &KeyboardShortcuts::toggleInspectorRequested,
            this, &MainWindow::onToggleInspector);
    connect(m_keyboardShortcuts, &KeyboardShortcuts::toggleMediaBrowserRequested,
            this, &MainWindow::onToggleMediaBrowser);
    connect(m_keyboardShortcuts, &KeyboardShortcuts::toggleProjectRequested,
            this, &MainWindow::onToggleProject);
    connect(m_keyboardShortcuts, &KeyboardShortcuts::toggleFullScreenRequested,
            this, &MainWindow::onToggleFullScreen);
    
    // Set keyboard shortcut context based on focus
    connect(this, &MainWindow::projectOpened, [this](const Project&) {
        m_keyboardShortcuts->setActiveContext(KeyboardShortcuts::GlobalContext);
    });
    
    // Traditional action shortcuts (fallback for menu access)
    m_newProjectAction->setShortcut(QKeySequence::New);
    m_openProjectAction->setShortcut(QKeySequence::Open);
    m_saveProjectAction->setShortcut(QKeySequence::Save);
    m_saveProjectAsAction->setShortcut(QKeySequence::SaveAs);
    m_importMediaAction->setShortcut(QKeySequence("Ctrl+I"));
    m_exitAction->setShortcut(QKeySequence::Quit);
    m_showPreferencesAction->setShortcut(QKeySequence::Preferences);
}

// Menu creation methods
QMenu* MainWindow::createFileMenu()
{
    QMenu* menu = new QMenu("&File", this);
    
    m_newProjectAction = menu->addAction("&New Project...");
    m_openProjectAction = menu->addAction("&Open Project...");
    
    // Recent projects submenu
    m_recentProjectsMenu = menu->addMenu("Open &Recent");
    updateRecentProjectsMenu();
    
    menu->addSeparator();
    
    m_saveProjectAction = menu->addAction("&Save Project");
    m_saveProjectAsAction = menu->addAction("Save Project &As...");
    m_closeProjectAction = menu->addAction("&Close Project");
    
    menu->addSeparator();
    
    m_importMediaAction = menu->addAction("&Import Media...");
    menu->addAction("Import Project...", this, &MainWindow::importProject);
    
    menu->addSeparator();
    
    m_exportSequenceAction = menu->addAction("&Export Sequence...");
    menu->addAction("Export Frame...", this, &MainWindow::exportFrame);
    
    menu->addSeparator();
    
    m_exitAction = menu->addAction("E&xit");
    
    // Connect actions
    connect(m_newProjectAction, &QAction::triggered, this, &MainWindow::onNewProject);
    connect(m_openProjectAction, &QAction::triggered, this, &MainWindow::onOpenProject);
    connect(m_saveProjectAction, &QAction::triggered, this, &MainWindow::onSaveProject);
    connect(m_saveProjectAsAction, &QAction::triggered, this, &MainWindow::onSaveProjectAs);
    connect(m_closeProjectAction, &QAction::triggered, this, &MainWindow::onCloseProject);
    connect(m_importMediaAction, &QAction::triggered, this, &MainWindow::onImportMedia);
    connect(m_exportSequenceAction, &QAction::triggered, this, &MainWindow::onExportSequence);
    connect(m_exitAction, &QAction::triggered, this, &MainWindow::onExit);
    
    return menu;
}

QMenu* MainWindow::createEditMenu()
{
    QMenu* menu = new QMenu("&Edit", this);
    
    m_undoAction = menu->addAction("&Undo");
    m_redoAction = menu->addAction("&Redo");
    
    menu->addSeparator();
    
    m_cutAction = menu->addAction("Cu&t");
    m_copyAction = menu->addAction("&Copy");
    m_pasteAction = menu->addAction("&Paste");
    
    menu->addSeparator();
    
    m_selectAllAction = menu->addAction("Select &All");
    m_deselectAllAction = menu->addAction("&Deselect All");
    
    menu->addSeparator();
    
    menu->addAction("Find...", this, [this]() {
        // TODO: Implement find functionality
    })->setShortcut(QKeySequence::Find);
    
    // Connect actions
    connect(m_undoAction, &QAction::triggered, this, &MainWindow::onUndo);
    connect(m_redoAction, &QAction::triggered, this, &MainWindow::onRedo);
    connect(m_cutAction, &QAction::triggered, this, &MainWindow::onCut);
    connect(m_copyAction, &QAction::triggered, this, &MainWindow::onCopy);
    connect(m_pasteAction, &QAction::triggered, this, &MainWindow::onPaste);
    connect(m_selectAllAction, &QAction::triggered, this, &MainWindow::onSelectAll);
    connect(m_deselectAllAction, &QAction::triggered, this, &MainWindow::onDeselectAll);
    
    return menu;
}

QMenu* MainWindow::createViewMenu()
{
    QMenu* menu = new QMenu("&View", this);
    
    // Layout management
    m_resetLayoutAction = menu->addAction("&Reset Layout");
    connect(m_resetLayoutAction, &QAction::triggered, this, &MainWindow::onResetLayout);
    
    menu->addSeparator();
    
    // Panel toggles
    m_toggleTimelineAction = menu->addAction("Timeline Panel");
    m_toggleTimelineAction->setCheckable(true);
    m_toggleTimelineAction->setChecked(true);
    connect(m_toggleTimelineAction, &QAction::triggered, this, &MainWindow::onToggleTimeline);
    
    m_toggleInspectorAction = menu->addAction("Inspector Panel");
    m_toggleInspectorAction->setCheckable(true);
    m_toggleInspectorAction->setChecked(true);
    connect(m_toggleInspectorAction, &QAction::triggered, this, &MainWindow::onToggleInspector);
    
    m_toggleMediaBrowserAction = menu->addAction("Media Browser Panel");
    m_toggleMediaBrowserAction->setCheckable(true);
    m_toggleMediaBrowserAction->setChecked(true);
    connect(m_toggleMediaBrowserAction, &QAction::triggered, this, &MainWindow::onToggleMediaBrowser);
    
    m_toggleProjectAction = menu->addAction("Project Panel");
    m_toggleProjectAction->setCheckable(true);
    m_toggleProjectAction->setChecked(true);
    connect(m_toggleProjectAction, &QAction::triggered, this, &MainWindow::onToggleProject);
    
    menu->addSeparator();
    
    // Workspace management
    m_workspacesMenu = menu->addMenu("&Workspaces");
    
    menu->addSeparator();
    
    // Full screen and preferences
    m_toggleFullScreenAction = menu->addAction("&Full Screen");
    m_toggleFullScreenAction->setCheckable(true);
    connect(m_toggleFullScreenAction, &QAction::triggered, this, &MainWindow::onToggleFullScreen);
    
    menu->addSeparator();
    
    m_showPreferencesAction = menu->addAction("&Preferences...");
    connect(m_showPreferencesAction, &QAction::triggered, this, &MainWindow::onShowPreferences);
    
    return menu;
}

QMenu* MainWindow::createSequenceMenu()
{
    QMenu* menu = new QMenu("&Sequence", this);
    
    menu->addAction("New Sequence...", [this]() {
        if (m_projectPanel) {
            m_projectPanel->createSequence();
        }
    })->setShortcut(QKeySequence("Ctrl+N"));
    
    menu->addAction("Sequence Settings...", [this]() {
        // TODO: Show sequence settings dialog
    });
    
    menu->addSeparator();
    
    menu->addAction("Add Tracks...", [this]() {
        // TODO: Add tracks dialog
    });
    
    menu->addAction("Delete Tracks...", [this]() {
        // TODO: Delete tracks dialog
    });
    
    return menu;
}

QMenu* MainWindow::createClipMenu()
{
    QMenu* menu = new QMenu("&Clip", this);
    
    menu->addAction("Split Clip", [this]() {
        if (m_timelinePanel) {
            m_timelinePanel->splitClipAtPlayhead();
        }
    })->setShortcut(QKeySequence("B"));
    
    menu->addAction("Delete Clips", [this]() {
        if (m_timelinePanel) {
            m_timelinePanel->deleteSelectedClips();
        }
    })->setShortcut(QKeySequence::Delete);
    
    menu->addAction("Ripple Delete", [this]() {
        if (m_timelinePanel) {
            m_timelinePanel->rippleDeleteSelectedClips();
        }
    })->setShortcut(QKeySequence("Shift+Delete"));
    
    menu->addSeparator();
    
    menu->addAction("Speed/Duration...", [this]() {
        // TODO: Speed/Duration dialog
    });
    
    menu->addAction("Audio Gain...", [this]() {
        // TODO: Audio gain dialog
    });
    
    return menu;
}

QMenu* MainWindow::createEffectsMenu()
{
    QMenu* menu = new QMenu("E&ffects", this);
    
    menu->addAction("Video Effects", [this]() {
        // TODO: Video effects browser
    });
    
    menu->addAction("Audio Effects", [this]() {
        // TODO: Audio effects browser
    });
    
    menu->addSeparator();
    
    menu->addAction("Remove Effects", [this]() {
        // TODO: Remove effects from selection
    });
    
    menu->addAction("Copy Effects", [this]() {
        // TODO: Copy effects
    });
    
    menu->addAction("Paste Effects", [this]() {
        // TODO: Paste effects
    });
    
    return menu;
}

QMenu* MainWindow::createWindowMenu()
{
    QMenu* menu = new QMenu("&Window", this);
    
    m_newWindowAction = menu->addAction("&New Window");
    connect(m_newWindowAction, &QAction::triggered, this, &MainWindow::onNewWindow);
    
    menu->addSeparator();
    
    m_minimizeAction = menu->addAction("&Minimize");
    m_minimizeAction->setShortcut(QKeySequence("Ctrl+M"));
    connect(m_minimizeAction, &QAction::triggered, this, &MainWindow::onMinimizeWindow);
    
    m_zoomAction = menu->addAction("&Zoom");
    connect(m_zoomAction, &QAction::triggered, this, &MainWindow::onZoomWindow);
    
    menu->addSeparator();
    
    menu->addAction("Arrange Windows", this, &MainWindow::onArrangeWindows);
    
    return menu;
}

QMenu* MainWindow::createHelpMenu()
{
    QMenu* menu = new QMenu("&Help", this);
    
    m_showHelpAction = menu->addAction("&JVE Editor Help");
    m_showHelpAction->setShortcut(QKeySequence::HelpContents);
    connect(m_showHelpAction, &QAction::triggered, this, &MainWindow::onShowHelp);
    
    m_keyboardShortcutsAction = menu->addAction("&Keyboard Shortcuts");
    connect(m_keyboardShortcutsAction, &QAction::triggered, this, &MainWindow::onKeyboardShortcuts);
    
    menu->addSeparator();
    
    m_aboutAction = menu->addAction("&About JVE Editor");
    connect(m_aboutAction, &QAction::triggered, this, &MainWindow::onAbout);
    
    return menu;
}

// Toolbar creation methods
QToolBar* MainWindow::createMainToolBar()
{
    QToolBar* toolbar = new QToolBar("Main", this);
    toolbar->setObjectName("MainToolBar");
    
    toolbar->addAction(m_newProjectAction);
    toolbar->addAction(m_openProjectAction);
    toolbar->addAction(m_saveProjectAction);
    toolbar->addSeparator();
    toolbar->addAction(m_importMediaAction);
    toolbar->addAction(m_exportSequenceAction);
    
    return toolbar;
}

QToolBar* MainWindow::createEditToolBar()
{
    QToolBar* toolbar = new QToolBar("Edit", this);
    toolbar->setObjectName("EditToolBar");
    
    toolbar->addAction(m_undoAction);
    toolbar->addAction(m_redoAction);
    toolbar->addSeparator();
    toolbar->addAction(m_cutAction);
    toolbar->addAction(m_copyAction);
    toolbar->addAction(m_pasteAction);
    
    return toolbar;
}

QToolBar* MainWindow::createPlaybackToolBar()
{
    QToolBar* toolbar = new QToolBar("Playback", this);
    toolbar->setObjectName("PlaybackToolBar");
    
    // TODO: Add playback controls when viewer is implemented
    toolbar->addAction("Play", [this]() {
        // TODO: Implement play functionality
    });
    
    toolbar->addAction("Stop", [this]() {
        // TODO: Implement stop functionality
    });
    
    return toolbar;
}

QToolBar* MainWindow::createToolsToolBar()
{
    QToolBar* toolbar = new QToolBar("Tools", this);
    toolbar->setObjectName("ToolsToolBar");
    
    // TODO: Add editing tools when implemented
    toolbar->addAction("Selection", [this]() {
        // TODO: Selection tool
    });
    
    toolbar->addAction("Blade", [this]() {
        // TODO: Blade tool
    });
    
    return toolbar;
}

// Dock widget creation methods
QDockWidget* MainWindow::createTimelineDock()
{
    QDockWidget* dock = new QDockWidget("Timeline", this);
    dock->setObjectName("TimelineDock");
    dock->setAllowedAreas(Qt::BottomDockWidgetArea | Qt::TopDockWidgetArea);
    
    m_timelinePanel = new TimelinePanel();
    m_timelinePanel->setCommandDispatcher(m_commandDispatcher);
    m_timelinePanel->setSelectionManager(m_selectionManager);
    m_timelinePanel->setCommandBridge(m_commandBridge);
    
    dock->setWidget(m_timelinePanel);
    return dock;
}

QDockWidget* MainWindow::createInspectorDock()
{
    QDockWidget* dock = new QDockWidget("Inspector", this);
    dock->setObjectName("InspectorDock");
    dock->setAllowedAreas(Qt::LeftDockWidgetArea | Qt::RightDockWidgetArea);
    
    m_inspectorPanel = new InspectorPanel();
    m_inspectorPanel->setCommandDispatcher(m_commandDispatcher);
    m_inspectorPanel->setSelectionManager(m_selectionManager);
    
    dock->setWidget(m_inspectorPanel);
    return dock;
}

QDockWidget* MainWindow::createMediaBrowserDock()
{
    QDockWidget* dock = new QDockWidget("Media Browser", this);
    dock->setObjectName("MediaBrowserDock");
    dock->setAllowedAreas(Qt::LeftDockWidgetArea | Qt::RightDockWidgetArea);
    
    m_mediaBrowserPanel = new MediaBrowserPanel();
    m_mediaBrowserPanel->setCommandDispatcher(m_commandDispatcher);
    
    dock->setWidget(m_mediaBrowserPanel);
    return dock;
}

QDockWidget* MainWindow::createProjectDock()
{
    QDockWidget* dock = new QDockWidget("Project", this);
    dock->setObjectName("ProjectDock");
    dock->setAllowedAreas(Qt::LeftDockWidgetArea | Qt::RightDockWidgetArea);
    
    m_projectPanel = new ProjectPanel();
    m_projectPanel->setCommandDispatcher(m_commandDispatcher);
    
    dock->setWidget(m_projectPanel);
    return dock;
}

// Core functionality implementations
void MainWindow::newProject()
{
    if (hasUnsavedChanges() && !confirmCloseProject()) {
        return;
    }
    
    // TODO: Show new project dialog
    QString projectName = QInputDialog::getText(this, "New Project", "Project name:", QLineEdit::Normal, "Untitled Project");
    if (projectName.isEmpty()) {
        return;
    }
    
    m_currentProject = Project::create(projectName);
    
    // Set project in panels
    if (m_projectPanel) {
        m_projectPanel->setProject(m_currentProject);
    }
    if (m_mediaBrowserPanel) {
        m_mediaBrowserPanel->setProject(m_currentProject);
    }
    
    enableProjectActions(true);
    updateWindowTitle();
    m_hasUnsavedChanges = false;
    
    // Start autosave timer
    m_autosaveTimer->start();
    
    emit projectOpened(m_currentProject);
    qCDebug(jveMainWindow, "New project created: %s", qPrintable(projectName));
}

void MainWindow::openProject()
{
    QString filePath = QFileDialog::getOpenFileName(
        this,
        "Open Project",
        QStandardPaths::writableLocation(QStandardPaths::DocumentsLocation),
        "JVE Projects (*.jve);;All Files (*)"
    );
    
    if (!filePath.isEmpty()) {
        openProject(filePath);
    }
}

void MainWindow::openProject(const QString& filePath)
{
    if (hasUnsavedChanges() && !confirmCloseProject()) {
        return;
    }
    
    // TODO: Load project from file
    qCDebug(jveMainWindow, "Opening project: %s", qPrintable(filePath));
    
    // For now, create a sample project
    m_currentProject = Project::create(QFileInfo(filePath).baseName());
    
    // Set project in panels
    if (m_projectPanel) {
        m_projectPanel->setProject(m_currentProject);
    }
    if (m_mediaBrowserPanel) {
        m_mediaBrowserPanel->setProject(m_currentProject);
    }
    
    enableProjectActions(true);
    updateWindowTitle();
    m_hasUnsavedChanges = false;
    m_lastSavedPath = filePath;
    
    // Add to recent projects
    addToRecentProjects(filePath);
    updateRecentProjectsMenu();
    
    // Start autosave timer
    m_autosaveTimer->start();
    
    emit projectOpened(m_currentProject);
}

void MainWindow::saveProject()
{
    if (m_lastSavedPath.isEmpty()) {
        saveProjectAs();
        return;
    }
    
    // TODO: Save project to file
    qCDebug(jveMainWindow, "Saving project: %s", qPrintable(m_lastSavedPath));
    
    m_hasUnsavedChanges = false;
    updateWindowTitle();
    
    m_statusLabel->setText("Project saved");
    m_statusTimer->start(STATUS_TIMEOUT_MS);
}

void MainWindow::saveProjectAs()
{
    QString filePath = QFileDialog::getSaveFileName(
        this,
        "Save Project As",
        QStandardPaths::writableLocation(QStandardPaths::DocumentsLocation) + "/" + m_currentProject.name() + ".jve",
        "JVE Projects (*.jve)"
    );
    
    if (!filePath.isEmpty()) {
        m_lastSavedPath = filePath;
        saveProject();
        addToRecentProjects(filePath);
        updateRecentProjectsMenu();
    }
}

void MainWindow::closeProject()
{
    if (hasUnsavedChanges() && !confirmCloseProject()) {
        return;
    }
    
    m_currentProject = Project();
    
    // Clear panels
    if (m_projectPanel) {
        m_projectPanel->setProject(m_currentProject);
    }
    if (m_mediaBrowserPanel) {
        m_mediaBrowserPanel->setProject(m_currentProject);
    }
    
    enableProjectActions(false);
    updateWindowTitle();
    m_hasUnsavedChanges = false;
    m_lastSavedPath.clear();
    
    // Stop autosave timer
    m_autosaveTimer->stop();
    
    emit projectClosed();
    qCDebug(jveMainWindow, "Project closed");
}

// Event handlers
void MainWindow::closeEvent(QCloseEvent* event)
{
    if (hasUnsavedChanges() && !confirmCloseProject()) {
        event->ignore();
        return;
    }
    
    saveState();
    saveWindowGeometry();
    event->accept();
}

void MainWindow::resizeEvent(QResizeEvent* event)
{
    QMainWindow::resizeEvent(event);
    saveWindowGeometry();
}

void MainWindow::keyPressEvent(QKeyEvent* event)
{
    // Handle global keyboard shortcuts
    switch (event->key()) {
    case Qt::Key_Space:
        // TODO: Play/pause when viewer is implemented
        event->accept();
        break;
    case Qt::Key_Home:
        // TODO: Go to beginning when viewer is implemented
        event->accept();
        break;
    case Qt::Key_End:
        // TODO: Go to end when viewer is implemented
        event->accept();
        break;
    default:
        QMainWindow::keyPressEvent(event);
        break;
    }
}

void MainWindow::dragEnterEvent(QDragEnterEvent* event)
{
    if (event->mimeData()->hasUrls()) {
        event->acceptProposedAction();
    }
}

void MainWindow::dropEvent(QDropEvent* event)
{
    QStringList filePaths;
    for (const QUrl& url : event->mimeData()->urls()) {
        if (url.isLocalFile()) {
            filePaths.append(url.toLocalFile());
        }
    }
    
    if (!filePaths.isEmpty()) {
        // Check if any files are project files
        for (const QString& filePath : filePaths) {
            if (filePath.endsWith(".jve")) {
                openProject(filePath);
                return;
            }
        }
        
        // Otherwise, import as media
        onMediaImported(filePaths);
    }
    
    event->acceptProposedAction();
}

// Utility methods
QString MainWindow::getProjectDisplayName() const
{
    if (m_currentProject.id().isEmpty()) {
        return "No Project";
    }
    
    QString displayName = m_currentProject.name();
    if (m_hasUnsavedChanges) {
        displayName += " *";
    }
    
    return displayName;
}

bool MainWindow::hasUnsavedChanges() const
{
    return m_hasUnsavedChanges && !m_currentProject.id().isEmpty();
}

bool MainWindow::confirmCloseProject()
{
    QMessageBox::StandardButton reply = QMessageBox::question(
        this,
        "Unsaved Changes",
        "You have unsaved changes. Do you want to save before closing?",
        QMessageBox::Save | QMessageBox::Discard | QMessageBox::Cancel
    );
    
    switch (reply) {
    case QMessageBox::Save:
        saveProject();
        return !m_hasUnsavedChanges; // Only proceed if save was successful
    case QMessageBox::Discard:
        return true;
    case QMessageBox::Cancel:
    default:
        return false;
    }
}

void MainWindow::updateWindowTitle()
{
    QString title = QString("JVE Editor - %1").arg(getProjectDisplayName());
    setWindowTitle(title);
}

void MainWindow::enableProjectActions(bool enabled)
{
    m_saveProjectAction->setEnabled(enabled);
    m_saveProjectAsAction->setEnabled(enabled);
    m_closeProjectAction->setEnabled(enabled);
    m_exportSequenceAction->setEnabled(enabled);
    
    // Enable editing actions only when project is open
    m_undoAction->setEnabled(enabled);
    m_redoAction->setEnabled(enabled);
    m_cutAction->setEnabled(enabled);
    m_copyAction->setEnabled(enabled);
    m_pasteAction->setEnabled(enabled);
    m_selectAllAction->setEnabled(enabled);
    m_deselectAllAction->setEnabled(enabled);
}

void MainWindow::updateRecentProjectsMenu()
{
    m_recentProjectsMenu->clear();
    
    QStringList recentProjects = getRecentProjects();
    for (const QString& filePath : recentProjects) {
        QAction* action = m_recentProjectsMenu->addAction(QFileInfo(filePath).fileName());
        connect(action, &QAction::triggered, [this, filePath]() {
            openProject(filePath);
        });
    }
    
    if (recentProjects.isEmpty()) {
        QAction* noRecentAction = m_recentProjectsMenu->addAction("No Recent Projects");
        noRecentAction->setEnabled(false);
    }
}

QStringList MainWindow::getRecentProjects() const
{
    return m_settings->value("recentProjects").toStringList();
}

void MainWindow::addToRecentProjects(const QString& filePath)
{
    QStringList recentProjects = getRecentProjects();
    recentProjects.removeAll(filePath); // Remove if already in list
    recentProjects.prepend(filePath);   // Add to front
    
    // Limit to maximum number
    while (recentProjects.size() > MAX_RECENT_PROJECTS) {
        recentProjects.removeLast();
    }
    
    m_settings->setValue("recentProjects", recentProjects);
}

void MainWindow::saveState()
{
    m_settings->setValue("windowState", QMainWindow::saveState());
    m_settings->setValue("currentWorkspace", m_currentWorkspace);
}

void MainWindow::restoreState()
{
    QByteArray state = m_settings->value("windowState").toByteArray();
    if (!state.isEmpty()) {
        QMainWindow::restoreState(state);
    }
    
    m_currentWorkspace = m_settings->value("currentWorkspace", "Default").toString();
}

void MainWindow::saveWindowGeometry()
{
    m_settings->setValue("windowGeometry", geometry());
}

void MainWindow::restoreWindowGeometry()
{
    QRect geometry = m_settings->value("windowGeometry", QRect(100, 100, 1600, 1000)).toRect();
    setGeometry(geometry);
}

void MainWindow::initializeWorkspaces()
{
    // TODO: Implement workspace management
    m_currentWorkspace = "Default";
}

// Slot implementations - placeholder for now
void MainWindow::onNewProject() { newProject(); }
void MainWindow::onOpenProject() { openProject(); }
void MainWindow::onSaveProject() { saveProject(); }
void MainWindow::onSaveProjectAs() { saveProjectAs(); }
void MainWindow::onCloseProject() { closeProject(); }
void MainWindow::onImportMedia() 
{ 
    // Open file dialog to select media files
    QStringList filePaths = QFileDialog::getOpenFileNames(
        this,
        "Import Media Files",
        QStandardPaths::writableLocation(QStandardPaths::MoviesLocation),
        "Media Files (*.mp4 *.mov *.avi *.mkv *.wav *.mp3 *.aac *.jpg *.png);;All Files (*)"
    );
    
    if (!filePaths.isEmpty()) {
        // Import each file and collect media IDs
        QStringList mediaIds;
        ProjectManager* projectManager = new ProjectManager(this);
        
        for (const QString& filePath : filePaths) {
            QJsonObject request;
            request["file_path"] = filePath;
            
            // Import media through API - use dummy project ID for now
            QJsonObject response = projectManager->importMedia("current-project", request);
            
            if (!response.contains("error") && response.contains("id")) {
                mediaIds.append(response["id"].toString());
                qCDebug(jveMainWindow, "Successfully imported media: %s -> %s", 
                       qPrintable(filePath), qPrintable(response["id"].toString()));
            } else {
                qCWarning(jveMainWindow, "Failed to import media: %s - %s", 
                         qPrintable(filePath), qPrintable(response["error"].toString()));
            }
        }
        
        if (!mediaIds.isEmpty()) {
            onMediaImported(mediaIds);
        }
        
        projectManager->deleteLater();
    }
}
void MainWindow::onExportSequence() { exportSequence(); }
void MainWindow::onExit() { close(); }

void MainWindow::onUndo() { /* TODO: Implement undo */ }
void MainWindow::onRedo() { /* TODO: Implement redo */ }
void MainWindow::onCut() { /* TODO: Implement cut */ }
void MainWindow::onCopy() { /* TODO: Implement copy */ }
void MainWindow::onPaste() { /* TODO: Implement paste */ }
void MainWindow::onSelectAll() { /* TODO: Implement select all */ }
void MainWindow::onDeselectAll() { /* TODO: Implement deselect all */ }

void MainWindow::onResetLayout() { resetLayout(); }
void MainWindow::onToggleTimeline() { toggleTimelinePanel(); }
void MainWindow::onToggleInspector() { toggleInspectorPanel(); }
void MainWindow::onToggleMediaBrowser() { toggleMediaBrowserPanel(); }
void MainWindow::onToggleProject() { toggleProjectPanel(); }
void MainWindow::onToggleFullScreen() { toggleFullScreen(); }
void MainWindow::onShowPreferences() { showPreferences(); }

void MainWindow::onNewWindow() { /* TODO: Implement new window */ }
void MainWindow::onMinimizeWindow() { showMinimized(); }
void MainWindow::onZoomWindow() { showMaximized(); }
void MainWindow::onArrangeWindows() { /* TODO: Implement arrange windows */ }

void MainWindow::onShowHelp() { /* TODO: Implement help */ }
void MainWindow::onKeyboardShortcuts() { /* TODO: Implement shortcuts dialog */ }
void MainWindow::onAbout() { /* TODO: Implement about dialog */ }

void MainWindow::onWorkspaceChanged() { /* TODO: Implement workspace change */ }
void MainWindow::onSaveWorkspace() { /* TODO: Implement save workspace */ }
void MainWindow::onManageWorkspaces() { /* TODO: Implement manage workspaces */ }

void MainWindow::onUpdateStatus() { /* TODO: Implement status update */ }
void MainWindow::onUpdateProgress() { /* TODO: Implement progress update */ }

void MainWindow::onProjectChanged(const Project& project) {
    m_currentProject = project;
    updateWindowTitle();
    m_hasUnsavedChanges = true;
}

void MainWindow::onSequenceSelected(const QString& sequenceId) {
    Q_UNUSED(sequenceId)
    // TODO: Load sequence in timeline
}

void MainWindow::onMediaImported(const QStringList& mediaIds) {
    m_statusLabel->setText(QString("Imported %1 media files").arg(mediaIds.size()));
    m_statusTimer->start(STATUS_TIMEOUT_MS);
    
    // Auto-add imported media as clips to the timeline
    if (!mediaIds.isEmpty() && m_commandBridge && !m_currentSequenceId.isEmpty()) {
        // Use the current sequence from the initialized database
        QString sequenceId = m_currentSequenceId;
        QString trackId = "track-1";       // Default video track (would need track creation)
        qint64 startTime = 0;              // Start at beginning
        
        for (int i = 0; i < mediaIds.size(); ++i) {
            const QString& mediaId = mediaIds[i];
            
            // Place clips sequentially, assume 10 second duration for now
            qint64 clipStartTime = startTime + (i * 10000); // 10 seconds apart in milliseconds
            qint64 clipDuration = 10000; // 10 seconds in milliseconds
            
            m_commandBridge->createClip(sequenceId, trackId, mediaId, clipStartTime, clipDuration);
            
            qCDebug(jveMainWindow, "Creating clip from media %s at time %lld", 
                   qPrintable(mediaId), clipStartTime);
        }
        
        qCDebug(jveMainWindow, "Added %d clips to timeline", mediaIds.size());
    }
}

void MainWindow::onCommandExecuted() {
    m_hasUnsavedChanges = true;
    updateWindowTitle();
}

void MainWindow::onProgressUpdate(int percentage, const QString& message) {
    if (percentage >= 0 && percentage <= 100) {
        m_progressBar->setValue(percentage);
        m_progressBar->setVisible(true);
        if (!message.isEmpty()) {
            m_statusLabel->setText(message);
        }
    } else {
        m_progressBar->setVisible(false);
    }
}

// Test command execution  
void MainWindow::testCommandExecution()
{
    qCDebug(jveMainWindow, "Testing command execution...");
    
    if (!m_commandBridge || m_currentSequenceId.isEmpty()) {
        qCWarning(jveMainWindow, "Cannot test commands - command bridge or sequence not ready");
        return;
    }
    
    // Test creating a clip
    QString testMediaId = "test-media-123";
    QString trackId = "track-1";
    qint64 startTime = 0;
    qint64 duration = 5000; // 5 seconds
    
    qCDebug(jveMainWindow, "Executing test createClip command...");
    m_commandBridge->createClip(m_currentSequenceId, trackId, testMediaId, startTime, duration);
    qCDebug(jveMainWindow, "Test createClip command sent");
}

// Test auto import function
void MainWindow::testAutoImport()
{
    qCDebug(jveMainWindow, "Testing auto import...");
    
    if (!m_commandBridge) {
        qCWarning(jveMainWindow, "Cannot test auto import - command bridge not ready");
        return;
    }
    
    // Test importing the provided image path
    QStringList testFiles;
    testFiles << "/var/folders/xf/0xjb7ffs77d4lttc9drj0pb80000gn/T/TemporaryItems/NSIRD_screencaptureui_XMpVQs/Screenshot 2025-01-29 at 11.44.19 AM.png";
    
    qCDebug(jveMainWindow, "Executing test import for %d files...", testFiles.size());
    
    // This should trigger the media import system and create clips
    for (const QString& filePath : testFiles) {
        if (QFile::exists(filePath)) {
            qCDebug(jveMainWindow, "Importing file: %s", qPrintable(filePath));
            m_commandBridge->importMedia(QStringList() << filePath);
        } else {
            qCWarning(jveMainWindow, "Test file does not exist: %s", qPrintable(filePath));
            // Create a dummy clip anyway for testing
            QString testMediaId = "test-image-media";
            QString trackId = "track-1";
            qint64 startTime = 1000; // Start at 1 second
            qint64 duration = 3000; // 3 seconds
            
            qCDebug(jveMainWindow, "Creating dummy clip for testing...");
            m_commandBridge->createClip(m_currentSequenceId, trackId, testMediaId, startTime, duration);
        }
    }
    
    qCDebug(jveMainWindow, "Test auto import completed");
}

// Database initialization
void MainWindow::initializeDatabase()
{
    // Create a temporary database for the session
    // In a real application, this would open an existing project or create a new one
    QString tempDir = QStandardPaths::writableLocation(QStandardPaths::TempLocation);
    QString dbPath = QDir(tempDir).filePath("jve_session.db");
    
    // Remove existing temp database to start fresh
    if (QFile::exists(dbPath)) {
        QFile::remove(dbPath);
    }
    
    // Create new database
    if (!Migrations::createNewProject(dbPath)) {
        qCWarning(jveMainWindow, "Failed to create session database");
        return;
    }
    
    // Connect to the database
    m_database = QSqlDatabase::addDatabase("QSQLITE", "main_session");
    m_database.setDatabaseName(dbPath);
    
    if (!m_database.open()) {
        qCWarning(jveMainWindow, "Failed to open session database: %s", 
                 qPrintable(m_database.lastError().text()));
        return;
    }
    
    // Set database on command dispatcher
    m_commandDispatcher->setDatabase(m_database);
    
    // Create a default project and sequence
    Project project = Project::create("Default Project");
    if (project.save(m_database)) {
        m_currentProjectId = project.id();
        
        // Create a default sequence
        Sequence sequence = Sequence::create("Sequence 1", m_currentProjectId, 29.97, 1920, 1080);
        if (sequence.save(m_database)) {
            m_currentSequenceId = sequence.id();
            // Set the current sequence in the command bridge
            // (This requires adding a setter method to UICommandBridge)
            qCInfo(jveMainWindow, "Initialized session with project: %s, sequence: %s", 
                   qPrintable(m_currentProjectId), qPrintable(m_currentSequenceId));
        } else {
            qCWarning(jveMainWindow, "Failed to create default sequence");
        }
    } else {
        qCWarning(jveMainWindow, "Failed to create default project");
    }
}

// Placeholder implementations
void MainWindow::recentProjects() {}
void MainWindow::resetLayout() {}
void MainWindow::saveWorkspace(const QString&) {}
void MainWindow::loadWorkspace(const QString&) {}
void MainWindow::deleteWorkspace(const QString&) {}
void MainWindow::setWorkspacePreset(const QString&) {}
void MainWindow::toggleTimelinePanel() { m_timelineDock->setVisible(!m_timelineDock->isVisible()); }
void MainWindow::toggleInspectorPanel() { m_inspectorDock->setVisible(!m_inspectorDock->isVisible()); }
void MainWindow::toggleMediaBrowserPanel() { m_mediaBrowserDock->setVisible(!m_mediaBrowserDock->isVisible()); }
void MainWindow::toggleProjectPanel() { m_projectDock->setVisible(!m_projectDock->isVisible()); }
void MainWindow::toggleFullScreen() { setWindowState(windowState() ^ Qt::WindowFullScreen); }
void MainWindow::showPreferences() {}
void MainWindow::importMedia() { onImportMedia(); } // Public interface - calls the slot
void MainWindow::importProject() {}
void MainWindow::exportSequence() {}
void MainWindow::exportFrame() {}
void MainWindow::saveCurrentWorkspace() {}
void MainWindow::restoreWorkspaceFromSettings(const QString&) {}
void MainWindow::createWorkspacePresets() {}
void MainWindow::updateProjectState() {}
void MainWindow::updateMenuStates() {}
void MainWindow::updateToolBarStates() {}
void MainWindow::updateStatusBar() {}
void MainWindow::updateProgressBar(int, const QString&) {}
void MainWindow::showProjectInTitle() {}