#include "context_menu_manager.h"
#include <QApplication>
#include <QKeySequence>

Q_LOGGING_CATEGORY(jveContextMenus, "jve.ui.contextmenus")

ContextMenuManager::ContextMenuManager(QObject* parent)
    : QObject(parent)
{
    setupDefaultActions();
    qCDebug(jveContextMenus, "Context menu manager initialized with %d actions", m_actionInfos.size());
}

QMenu* ContextMenuManager::createContextMenu(MenuContext context, const QPoint& position, QWidget* parent)
{
    m_currentContext = context;
    m_lastClickPosition = position;
    
    switch (context) {
        case TimelineContext:
            return createTimelineContextMenu(position, parent);
        case InspectorContext:
            return createInspectorContextMenu(position, parent);
        case MediaBrowserContext:
            return createMediaBrowserContextMenu(position, parent);
        case ProjectContext:
            return createProjectContextMenu(position, parent);
        case ClipContext:
            return createClipContextMenu(m_selectedClipIds, parent);
        case TrackContext:
            return createTrackContextMenu(m_selectedTrackIds.isEmpty() ? QString() : m_selectedTrackIds.first(), parent);
        case SelectionContext:
            return createSelectionContextMenu(m_selectedClipIds, parent);
        case EmptySpaceContext:
            return createEmptySpaceContextMenu(parent);
        default:
            return createTimelineContextMenu(position, parent);
    }
}

QMenu* ContextMenuManager::createTimelineContextMenu(const QPoint& position, QWidget* parent)
{
    auto* menu = new QMenu(parent);
    menu->setAttribute(Qt::WA_DeleteOnClose);
    
    qCDebug(jveContextMenus, "Creating timeline context menu at position (%d, %d)", position.x(), position.y());
    
    // Add actions based on selection state
    if (m_hasSelection) {
        addEditingActions(menu);
        addSeparator(menu);
        addTimelineActions(menu);
    } else {
        // Empty timeline area
        menu->addAction("Paste", this, [this]() { emit pasteRequested(); });
        menu->addAction("Select All", this, [this]() { emit selectAllRequested(); });
        addSeparator(menu);
        menu->addAction("Add Video Track", this, [this]() { qCDebug(jveContextMenus) << "Add video track requested"; });
        menu->addAction("Add Audio Track", this, [this]() { qCDebug(jveContextMenus) << "Add audio track requested"; });
    }
    
    addSeparator(menu);
    addPlaybackActions(menu);
    addSeparator(menu);
    addNavigationActions(menu);
    
    // Connect menu signals
    connect(menu, &QMenu::aboutToShow, this, &ContextMenuManager::onMenuAboutToShow);
    connect(menu, &QMenu::aboutToHide, this, &ContextMenuManager::onMenuAboutToHide);
    
    return menu;
}

QMenu* ContextMenuManager::createInspectorContextMenu(const QPoint& position, QWidget* parent)
{
    auto* menu = new QMenu(parent);
    menu->setAttribute(Qt::WA_DeleteOnClose);
    
    qCDebug(jveContextMenus, "Creating inspector context menu");
    
    addPropertyActions(menu);
    
    if (m_hasSelection) {
        addSeparator(menu);
        menu->addAction("Reset All Properties", this, [this]() { 
            emit resetPropertyRequested("all"); 
        });
    }
    
    connect(menu, &QMenu::aboutToShow, this, &ContextMenuManager::onMenuAboutToShow);
    connect(menu, &QMenu::aboutToHide, this, &ContextMenuManager::onMenuAboutToHide);
    
    return menu;
}

QMenu* ContextMenuManager::createMediaBrowserContextMenu(const QPoint& position, QWidget* parent)
{
    auto* menu = new QMenu(parent);
    menu->setAttribute(Qt::WA_DeleteOnClose);
    
    qCDebug(jveContextMenus, "Creating media browser context menu");
    
    // Import and organization actions
    menu->addAction("Import Media...", this, [this]() { emit importMediaRequested(); })->setShortcut(QKeySequence("Ctrl+I"));
    addSeparator(menu);
    
    addOrganizationActions(menu);
    
    if (m_hasSelection) {
        addSeparator(menu);
        menu->addAction("Reveal in Finder", this, [this]() {
            if (!m_selectedClipIds.isEmpty()) {
                emit revealInFinderRequested(m_selectedClipIds.first());
            }
        });
        
        menu->addAction("Relink Media...", this, [this]() {
            if (!m_selectedClipIds.isEmpty()) {
                emit relinkMediaRequested(m_selectedClipIds.first());
            }
        });
        
        addSeparator(menu);
        menu->addAction("Delete", this, [this]() { emit deleteRequested(); })->setShortcut(QKeySequence::Delete);
    }
    
    connect(menu, &QMenu::aboutToShow, this, &ContextMenuManager::onMenuAboutToShow);
    connect(menu, &QMenu::aboutToHide, this, &ContextMenuManager::onMenuAboutToHide);
    
    return menu;
}

QMenu* ContextMenuManager::createProjectContextMenu(const QPoint& position, QWidget* parent)
{
    auto* menu = new QMenu(parent);
    menu->setAttribute(Qt::WA_DeleteOnClose);
    
    qCDebug(jveContextMenus, "Creating project context menu");
    
    addProjectActions(menu);
    
    if (m_hasSelection) {
        addSeparator(menu);
        menu->addAction("Sequence Settings...", this, [this]() {
            if (!m_selectedClipIds.isEmpty()) {
                emit sequenceSettingsRequested(m_selectedClipIds.first());
            }
        });
        
        menu->addAction("Duplicate Sequence", this, [this]() {
            if (!m_selectedClipIds.isEmpty()) {
                emit duplicateSequenceRequested(m_selectedClipIds.first());
            }
        });
        
        addSeparator(menu);
        menu->addAction("Delete Sequence", this, [this]() {
            if (!m_selectedClipIds.isEmpty()) {
                emit deleteSequenceRequested(m_selectedClipIds.first());
            }
        });
    }
    
    connect(menu, &QMenu::aboutToShow, this, &ContextMenuManager::onMenuAboutToShow);
    connect(menu, &QMenu::aboutToHide, this, &ContextMenuManager::onMenuAboutToHide);
    
    return menu;
}

QMenu* ContextMenuManager::createClipContextMenu(const QStringList& selectedClipIds, QWidget* parent)
{
    auto* menu = new QMenu(parent);
    menu->setAttribute(Qt::WA_DeleteOnClose);
    
    qCDebug(jveContextMenus, "Creating clip context menu for %d clips", selectedClipIds.size());
    
    addEditingActions(menu);
    addSeparator(menu);
    addTimelineActions(menu);
    addSeparator(menu);
    
    // Clip-specific actions
    if (selectedClipIds.size() > 1) {
        menu->addAction("Link Clips", this, [this]() { emit linkClipsRequested(); });
        menu->addAction("Unlink Clips", this, [this]() { emit unlinkClipsRequested(); });
        addSeparator(menu);
    }
    
    menu->addAction("Speed/Duration...", this, [this]() { 
        qCDebug(jveContextMenus) << "Speed/Duration requested"; 
    });
    menu->addAction("Audio Gain...", this, [this]() { 
        qCDebug(jveContextMenus) << "Audio Gain requested"; 
    });
    
    connect(menu, &QMenu::aboutToShow, this, &ContextMenuManager::onMenuAboutToShow);
    connect(menu, &QMenu::aboutToHide, this, &ContextMenuManager::onMenuAboutToHide);
    
    return menu;
}

QMenu* ContextMenuManager::createTrackContextMenu(const QString& trackId, QWidget* parent)
{
    auto* menu = new QMenu(parent);
    menu->setAttribute(Qt::WA_DeleteOnClose);
    
    qCDebug(jveContextMenus, "Creating track context menu for track: %s", qPrintable(trackId));
    
    addSelectionActions(menu);
    addSeparator(menu);
    
    // Track-specific actions
    menu->addAction("Add Video Track Above", this, [this]() { 
        qCDebug(jveContextMenus) << "Add video track above requested"; 
    });
    menu->addAction("Add Video Track Below", this, [this]() { 
        qCDebug(jveContextMenus) << "Add video track below requested"; 
    });
    menu->addAction("Add Audio Track", this, [this]() { 
        qCDebug(jveContextMenus) << "Add audio track requested"; 
    });
    addSeparator(menu);
    
    menu->addAction("Track Settings...", this, [this]() { 
        qCDebug(jveContextMenus) << "Track settings requested"; 
    });
    menu->addAction("Delete Track", this, [this]() { 
        qCDebug(jveContextMenus) << "Delete track requested"; 
    });
    
    connect(menu, &QMenu::aboutToShow, this, &ContextMenuManager::onMenuAboutToShow);
    connect(menu, &QMenu::aboutToHide, this, &ContextMenuManager::onMenuAboutToHide);
    
    return menu;
}

QMenu* ContextMenuManager::createSelectionContextMenu(const QStringList& selectedItemIds, QWidget* parent)
{
    auto* menu = new QMenu(parent);
    menu->setAttribute(Qt::WA_DeleteOnClose);
    
    qCDebug(jveContextMenus, "Creating selection context menu for %d items", selectedItemIds.size());
    
    addEditingActions(menu);
    addSeparator(menu);
    addSelectionActions(menu);
    
    connect(menu, &QMenu::aboutToShow, this, &ContextMenuManager::onMenuAboutToShow);
    connect(menu, &QMenu::aboutToHide, this, &ContextMenuManager::onMenuAboutToHide);
    
    return menu;
}

QMenu* ContextMenuManager::createEmptySpaceContextMenu(QWidget* parent)
{
    auto* menu = new QMenu(parent);
    menu->setAttribute(Qt::WA_DeleteOnClose);
    
    qCDebug(jveContextMenus, "Creating empty space context menu");
    
    menu->addAction("Paste", this, [this]() { emit pasteRequested(); })->setShortcut(QKeySequence::Paste);
    menu->addAction("Select All", this, [this]() { emit selectAllRequested(); })->setShortcut(QKeySequence::SelectAll);
    
    connect(menu, &QMenu::aboutToShow, this, &ContextMenuManager::onMenuAboutToShow);
    connect(menu, &QMenu::aboutToHide, this, &ContextMenuManager::onMenuAboutToHide);
    
    return menu;
}

void ContextMenuManager::setupDefaultActions()
{
    // Editing actions
    m_editingActionIds << "cut" << "copy" << "paste" << "delete" << "duplicate";
    
    // Timeline actions  
    m_timelineActionIds << "split_clip" << "blade_all_tracks" << "ripple_delete" << "ripple_trim"
                       << "roll_edit" << "slip_edit" << "slide_edit" << "link_clips" << "unlink_clips";
    
    // Selection actions
    m_selectionActionIds << "select_all" << "deselect_all" << "invert_selection" 
                        << "select_all_on_track" << "select_from_playhead" << "select_to_playhead";
    
    // Navigation actions
    m_navigationActionIds << "go_to_in_point" << "go_to_out_point" << "go_to_beginning" 
                         << "go_to_end" << "next_edit" << "previous_edit";
    
    // Property actions
    m_propertyActionIds << "reset_property" << "copy_keyframes" << "paste_keyframes"
                       << "delete_keyframes" << "add_keyframe" << "remove_keyframe";
    
    // Organization actions
    m_organizationActionIds << "create_bin" << "rename_bin" << "delete_bin" << "import_media"
                           << "relink_media" << "reveal_in_finder";
    
    // Project actions
    m_projectActionIds << "new_sequence" << "duplicate_sequence" << "sequence_settings"
                      << "delete_sequence";
    
    // Playback actions
    m_playbackActionIds << "play_pause" << "stop" << "mark_in" << "mark_out" << "clear_in_out";
    
    // Tool actions
    m_toolActionIds << "select_tool" << "tool_options";
    
    qCDebug(jveContextMenus, "Registered %d action categories", 
            m_editingActionIds.size() + m_timelineActionIds.size() + m_selectionActionIds.size() +
            m_navigationActionIds.size() + m_propertyActionIds.size() + m_organizationActionIds.size() +
            m_projectActionIds.size() + m_playbackActionIds.size() + m_toolActionIds.size());
}

void ContextMenuManager::addEditingActions(QMenu* menu)
{
    menu->addAction("Cut", this, [this]() { emit cutRequested(); })->setShortcut(QKeySequence::Cut);
    menu->addAction("Copy", this, [this]() { emit copyRequested(); })->setShortcut(QKeySequence::Copy);
    menu->addAction("Paste", this, [this]() { emit pasteRequested(); })->setShortcut(QKeySequence::Paste);
    menu->addAction("Delete", this, [this]() { emit deleteRequested(); })->setShortcut(QKeySequence::Delete);
    menu->addAction("Duplicate", this, [this]() { emit duplicateRequested(); })->setShortcut(QKeySequence("Ctrl+D"));
}

void ContextMenuManager::addTimelineActions(QMenu* menu)
{
    menu->addAction("Split Clip", this, [this]() { emit splitClipRequested(); })->setShortcut(QKeySequence("Ctrl+K"));
    menu->addAction("Blade All Tracks", this, [this]() { emit bladeAllTracksRequested(); })->setShortcut(QKeySequence("Shift+Ctrl+K"));
    menu->addAction("Ripple Delete", this, [this]() { emit rippleDeleteRequested(); })->setShortcut(QKeySequence("Shift+Delete"));
    
    auto* advancedMenu = menu->addMenu("Advanced Edit");
    advancedMenu->addAction("Ripple Trim", this, [this]() { emit rippleTrimRequested(); });
    advancedMenu->addAction("Roll Edit", this, [this]() { emit rollEditRequested(); });
    advancedMenu->addAction("Slip Edit", this, [this]() { emit slipEditRequested(); });
    advancedMenu->addAction("Slide Edit", this, [this]() { emit slideEditRequested(); });
}

void ContextMenuManager::addSelectionActions(QMenu* menu)
{
    menu->addAction("Select All", this, [this]() { emit selectAllRequested(); })->setShortcut(QKeySequence::SelectAll);
    menu->addAction("Deselect All", this, [this]() { emit deselectAllRequested(); })->setShortcut(QKeySequence("Ctrl+D"));
    menu->addAction("Invert Selection", this, [this]() { emit invertSelectionRequested(); });
    
    if (!m_selectedTrackIds.isEmpty()) {
        menu->addAction("Select All on Track", this, [this]() { 
            emit selectAllOnTrackRequested(m_selectedTrackIds.first()); 
        });
    }
}

void ContextMenuManager::addNavigationActions(QMenu* menu)
{
    menu->addAction("Go to In Point", this, [this]() { emit goToInPointRequested(); })->setShortcut(QKeySequence("Shift+I"));
    menu->addAction("Go to Out Point", this, [this]() { emit goToOutPointRequested(); })->setShortcut(QKeySequence("Shift+O"));
    addSeparator(menu);
    menu->addAction("Go to Beginning", this, [this]() { emit goToBeginningRequested(); })->setShortcut(QKeySequence("Home"));
    menu->addAction("Go to End", this, [this]() { emit goToEndRequested(); })->setShortcut(QKeySequence("End"));
    addSeparator(menu);
    menu->addAction("Next Edit", this, [this]() { emit nextEditRequested(); })->setShortcut(QKeySequence("Down"));
    menu->addAction("Previous Edit", this, [this]() { emit previousEditRequested(); })->setShortcut(QKeySequence("Up"));
}

void ContextMenuManager::addPropertyActions(QMenu* menu)
{
    if (m_hasSelection) {
        menu->addAction("Reset to Default", this, [this]() { emit resetPropertyRequested("current"); });
        addSeparator(menu);
    }
    
    menu->addAction("Copy Keyframes", this, [this]() { emit copyKeyframesRequested(); });
    menu->addAction("Paste Keyframes", this, [this]() { emit pasteKeyframesRequested(); });
    menu->addAction("Delete Keyframes", this, [this]() { emit deleteKeyframesRequested(); });
    addSeparator(menu);
    menu->addAction("Add Keyframe", this, [this]() { emit addKeyframeRequested(); });
    menu->addAction("Remove Keyframe", this, [this]() { emit removeKeyframeRequested(); });
}

void ContextMenuManager::addOrganizationActions(QMenu* menu)
{
    menu->addAction("New Bin", this, [this]() { emit createBinRequested(); });
    
    if (m_hasSelection) {
        menu->addAction("Rename", this, [this]() { 
            if (!m_selectedClipIds.isEmpty()) {
                emit renameBinRequested(m_selectedClipIds.first());
            }
        })->setShortcut(QKeySequence("F2"));
    }
}

void ContextMenuManager::addProjectActions(QMenu* menu)
{
    menu->addAction("New Sequence...", this, [this]() { emit newSequenceRequested(); })->setShortcut(QKeySequence("Ctrl+N"));
}

void ContextMenuManager::addPlaybackActions(QMenu* menu)
{
    menu->addAction("Play/Pause", this, [this]() { emit playPauseRequested(); })->setShortcut(QKeySequence("Space"));
    menu->addAction("Stop", this, [this]() { emit stopRequested(); })->setShortcut(QKeySequence("K"));
    addSeparator(menu);
    menu->addAction("Mark In", this, [this]() { emit markInRequested(); })->setShortcut(QKeySequence("I"));
    menu->addAction("Mark Out", this, [this]() { emit markOutRequested(); })->setShortcut(QKeySequence("O"));
    menu->addAction("Clear In/Out", this, [this]() { emit clearInOutRequested(); })->setShortcut(QKeySequence("Alt+X"));
}

void ContextMenuManager::addToolActions(QMenu* menu)
{
    auto* toolsMenu = menu->addMenu("Tools");
    toolsMenu->addAction("Selection (V)", this, [this]() { emit selectToolRequested("selection"); })->setShortcut(QKeySequence("V"));
    toolsMenu->addAction("Blade (B)", this, [this]() { emit selectToolRequested("blade"); })->setShortcut(QKeySequence("B"));
    toolsMenu->addAction("Hand (H)", this, [this]() { emit selectToolRequested("hand"); })->setShortcut(QKeySequence("H"));
    toolsMenu->addAction("Zoom (Z)", this, [this]() { emit selectToolRequested("zoom"); })->setShortcut(QKeySequence("Z"));
}

void ContextMenuManager::addSeparator(QMenu* menu)
{
    menu->addSeparator();
}

void ContextMenuManager::setHasSelection(bool hasSelection)
{
    m_hasSelection = hasSelection;
}

void ContextMenuManager::setSelectedClips(const QStringList& clipIds)
{
    m_selectedClipIds = clipIds;
    setHasSelection(!clipIds.isEmpty());
}

void ContextMenuManager::setSelectedTracks(const QStringList& trackIds)
{
    m_selectedTrackIds = trackIds;
}

void ContextMenuManager::setPlayheadPosition(double position)
{
    m_playheadPosition = position;
}

void ContextMenuManager::setCurrentContext(MenuContext context)
{
    m_currentContext = context;
}

void ContextMenuManager::onActionTriggered()
{
    auto* action = qobject_cast<QAction*>(sender());
    if (!action) return;
    
    QString actionId = action->data().toString();
    qCDebug(jveContextMenus, "Context menu action triggered: %s", qPrintable(actionId));
    emitActionSignal(actionId);
}

void ContextMenuManager::onMenuAboutToShow()
{
    qCDebug(jveContextMenus, "Context menu about to show");
    updateActionStates();
}

void ContextMenuManager::onMenuAboutToHide()
{
    qCDebug(jveContextMenus, "Context menu about to hide");
}

void ContextMenuManager::updateActionStates()
{
    // Update action enabled/disabled states based on current selection and context
    for (auto& action : m_actions) {
        action->setEnabled(isActionEnabled(action->data().toString()));
    }
}

void ContextMenuManager::emitActionSignal(const QString& actionId)
{
    // This would emit specific signals based on actionId
    // For now, we're using lambda connections in the menu creation methods
    qCDebug(jveContextMenus, "Would emit signal for action: %s", qPrintable(actionId));
}

bool ContextMenuManager::isActionEnabled(const QString& actionId) const
{
    // Implement logic to determine if action should be enabled
    // Based on current selection, context, etc.
    Q_UNUSED(actionId)
    return true; // For now, enable all actions
}