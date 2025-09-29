#include "keyboard_shortcuts.h"
#include <QApplication>
#include <QSettings>
#include <QLoggingCategory>

Q_LOGGING_CATEGORY(jveKeyboardShortcuts, "jve.ui.input.shortcuts")

KeyboardShortcuts::KeyboardShortcuts(QWidget* parent)
    : QObject(parent), m_parentWidget(parent)
{
    setupDefaultShortcuts();
    loadShortcuts();
    
    qCDebug(jveKeyboardShortcuts, "Keyboard shortcuts system initialized with %d shortcuts", m_shortcuts.size());
}

void KeyboardShortcuts::setupDefaultShortcuts()
{
    // Clear existing shortcuts
    m_shortcuts.clear();
    
    setupPlaybackShortcuts();
    setupEditingShortcuts();
    setupSelectionShortcuts();
    setupNavigationShortcuts();
    setupTimelineShortcuts();
    setupToolsShortcuts();
    setupWindowShortcuts();
    setupFileShortcuts();
    setupViewShortcuts();
}

void KeyboardShortcuts::setupPlaybackShortcuts()
{
    // Professional video editing playback shortcuts
    registerShortcut("play_pause", "Play/Pause", QKeySequence(Qt::Key_Space), GlobalContext, PlaybackCategory);
    registerShortcut("stop", "Stop", QKeySequence(Qt::Key_K), GlobalContext, PlaybackCategory);
    registerShortcut("play_backward", "Play Backward", QKeySequence(Qt::Key_J), GlobalContext, PlaybackCategory);
    registerShortcut("play_forward", "Play Forward", QKeySequence(Qt::Key_L), GlobalContext, PlaybackCategory);
    
    // Shuttle controls
    registerShortcut("shuttle_slow_backward", "Shuttle Slow Backward", QKeySequence(Qt::SHIFT | Qt::Key_J), GlobalContext, PlaybackCategory);
    registerShortcut("shuttle_slow_forward", "Shuttle Slow Forward", QKeySequence(Qt::SHIFT | Qt::Key_L), GlobalContext, PlaybackCategory);
    registerShortcut("shuttle_fast_backward", "Shuttle Fast Backward", QKeySequence(Qt::CTRL | Qt::Key_J), GlobalContext, PlaybackCategory);
    registerShortcut("shuttle_fast_forward", "Shuttle Fast Forward", QKeySequence(Qt::CTRL | Qt::Key_L), GlobalContext, PlaybackCategory);
    
    // Frame stepping
    registerShortcut("frame_step_backward", "Step Backward One Frame", QKeySequence(Qt::Key_Left), GlobalContext, PlaybackCategory);
    registerShortcut("frame_step_forward", "Step Forward One Frame", QKeySequence(Qt::Key_Right), GlobalContext, PlaybackCategory);
    registerShortcut("frame_step_backward_10", "Step Backward 10 Frames", QKeySequence(Qt::SHIFT | Qt::Key_Left), GlobalContext, PlaybackCategory);
    registerShortcut("frame_step_forward_10", "Step Forward 10 Frames", QKeySequence(Qt::SHIFT | Qt::Key_Right), GlobalContext, PlaybackCategory);
    
    // Navigation
    registerShortcut("go_to_beginning", "Go to Beginning", QKeySequence(Qt::Key_Home), GlobalContext, PlaybackCategory);
    registerShortcut("go_to_end", "Go to End", QKeySequence(Qt::Key_End), GlobalContext, PlaybackCategory);
    
    // Mark in/out points
    registerShortcut("mark_in", "Mark In", QKeySequence(Qt::Key_I), GlobalContext, PlaybackCategory);
    registerShortcut("mark_out", "Mark Out", QKeySequence(Qt::Key_O), GlobalContext, PlaybackCategory);
    registerShortcut("clear_in_out", "Clear In/Out", QKeySequence(Qt::CTRL | Qt::Key_X), GlobalContext, PlaybackCategory);
}

void KeyboardShortcuts::setupEditingShortcuts()
{
    // Professional editing tools
    registerShortcut("blade_tool", "Blade Tool", QKeySequence(Qt::Key_B), TimelineContext, EditingCategory);
    registerShortcut("selection_tool", "Selection Tool", QKeySequence(Qt::Key_V), TimelineContext, EditingCategory);
    registerShortcut("arrow_tool", "Arrow Tool", QKeySequence(Qt::Key_A), TimelineContext, EditingCategory);
    registerShortcut("hand_tool", "Hand Tool", QKeySequence(Qt::Key_H), TimelineContext, EditingCategory);
    registerShortcut("zoom_tool", "Zoom Tool", QKeySequence(Qt::Key_Z), TimelineContext, EditingCategory);
    
    // Editing operations
    registerShortcut("split_clip", "Split Clip at Playhead", QKeySequence(Qt::Key_B), TimelineContext, EditingCategory);
    registerShortcut("delete_clip", "Delete Selected Clips", QKeySequence(Qt::Key_Delete), TimelineContext, EditingCategory);
    registerShortcut("ripple_delete", "Ripple Delete", QKeySequence(Qt::SHIFT | Qt::Key_Delete), TimelineContext, EditingCategory);
    registerShortcut("lift", "Lift", QKeySequence(Qt::Key_Delete), TimelineContext, EditingCategory);
    registerShortcut("extract", "Extract", QKeySequence(Qt::SHIFT | Qt::Key_Delete), TimelineContext, EditingCategory);
    
    // Clipboard operations
    registerShortcut("copy", "Copy", QKeySequence::Copy, GlobalContext, EditingCategory);
    registerShortcut("paste", "Paste", QKeySequence::Paste, GlobalContext, EditingCategory);
    registerShortcut("cut", "Cut", QKeySequence::Cut, GlobalContext, EditingCategory);
    
    // Undo/Redo
    registerShortcut("undo", "Undo", QKeySequence::Undo, GlobalContext, EditingCategory);
    registerShortcut("redo", "Redo", QKeySequence::Redo, GlobalContext, EditingCategory);
    
    // Advanced editing
    registerShortcut("match_frame", "Match Frame", QKeySequence(Qt::Key_F), TimelineContext, EditingCategory);
    registerShortcut("replace_edit", "Replace Edit", QKeySequence(Qt::Key_R), TimelineContext, EditingCategory);
    registerShortcut("insert_edit", "Insert Edit", QKeySequence(Qt::Key_Comma), TimelineContext, EditingCategory);
    registerShortcut("overwrite_edit", "Overwrite Edit", QKeySequence(Qt::Key_Period), TimelineContext, EditingCategory);
}

void KeyboardShortcuts::setupSelectionShortcuts()
{
    // Selection operations
    registerShortcut("select_all", "Select All", QKeySequence::SelectAll, GlobalContext, SelectionCategory);
    registerShortcut("deselect_all", "Deselect All", QKeySequence(Qt::CTRL | Qt::Key_D), GlobalContext, SelectionCategory);
    
    // Timeline selection
    registerShortcut("select_next_clip", "Select Next Clip", QKeySequence(Qt::Key_Down), TimelineContext, SelectionCategory);
    registerShortcut("select_previous_clip", "Select Previous Clip", QKeySequence(Qt::Key_Up), TimelineContext, SelectionCategory);
    registerShortcut("select_next_edit", "Select Next Edit Point", QKeySequence(Qt::CTRL | Qt::Key_Right), TimelineContext, SelectionCategory);
    registerShortcut("select_previous_edit", "Select Previous Edit Point", QKeySequence(Qt::CTRL | Qt::Key_Left), TimelineContext, SelectionCategory);
    
    // Extended selection
    registerShortcut("extend_selection_right", "Extend Selection Right", QKeySequence(Qt::SHIFT | Qt::Key_Right), TimelineContext, SelectionCategory);
    registerShortcut("extend_selection_left", "Extend Selection Left", QKeySequence(Qt::SHIFT | Qt::Key_Left), TimelineContext, SelectionCategory);
    registerShortcut("extend_selection_up", "Extend Selection Up", QKeySequence(Qt::SHIFT | Qt::Key_Up), TimelineContext, SelectionCategory);
    registerShortcut("extend_selection_down", "Extend Selection Down", QKeySequence(Qt::SHIFT | Qt::Key_Down), TimelineContext, SelectionCategory);
    
    // Select tracks
    registerShortcut("select_track", "Select Entire Track", QKeySequence(Qt::CTRL | Qt::Key_T), TimelineContext, SelectionCategory);
    registerShortcut("select_all_tracks", "Select All Tracks", QKeySequence(Qt::CTRL | Qt::SHIFT | Qt::Key_A), TimelineContext, SelectionCategory);
}

void KeyboardShortcuts::setupNavigationShortcuts()
{
    // Timeline navigation
    registerShortcut("next_track", "Next Track", QKeySequence(Qt::Key_Down), TimelineContext, NavigationCategory);
    registerShortcut("previous_track", "Previous Track", QKeySequence(Qt::Key_Up), TimelineContext, NavigationCategory);
    registerShortcut("next_edit", "Next Edit Point", QKeySequence(Qt::Key_E), TimelineContext, NavigationCategory);
    registerShortcut("previous_edit", "Previous Edit Point", QKeySequence(Qt::SHIFT | Qt::Key_E), TimelineContext, NavigationCategory);
    
    // Page navigation
    registerShortcut("page_up", "Page Up", QKeySequence(Qt::Key_PageUp), GlobalContext, NavigationCategory);
    registerShortcut("page_down", "Page Down", QKeySequence(Qt::Key_PageDown), GlobalContext, NavigationCategory);
    
    // Tab navigation
    registerShortcut("next_tab", "Next Tab", QKeySequence(Qt::CTRL | Qt::Key_Tab), GlobalContext, NavigationCategory);
    registerShortcut("previous_tab", "Previous Tab", QKeySequence(Qt::CTRL | Qt::SHIFT | Qt::Key_Tab), GlobalContext, NavigationCategory);
}

void KeyboardShortcuts::setupTimelineShortcuts()
{
    // Zoom controls
    registerShortcut("zoom_in", "Zoom In", QKeySequence(Qt::Key_Plus), TimelineContext, TimelineCategory);
    registerShortcut("zoom_out", "Zoom Out", QKeySequence(Qt::Key_Minus), TimelineContext, TimelineCategory);
    registerShortcut("zoom_to_fit", "Zoom to Fit", QKeySequence(Qt::SHIFT | Qt::Key_Z), TimelineContext, TimelineCategory);
    registerShortcut("zoom_to_selection", "Zoom to Selection", QKeySequence(Qt::Key_Backslash), TimelineContext, TimelineCategory);
    
    // Track controls
    registerShortcut("add_video_track", "Add Video Track", QKeySequence(Qt::CTRL | Qt::SHIFT | Qt::Key_V), TimelineContext, TimelineCategory);
    registerShortcut("add_audio_track", "Add Audio Track", QKeySequence(Qt::CTRL | Qt::SHIFT | Qt::Key_A), TimelineContext, TimelineCategory);
    registerShortcut("delete_track", "Delete Track", QKeySequence(Qt::CTRL | Qt::SHIFT | Qt::Key_Delete), TimelineContext, TimelineCategory);
    
    // Timeline view
    registerShortcut("toggle_track_height", "Toggle Track Height", QKeySequence(Qt::SHIFT | Qt::Key_T), TimelineContext, TimelineCategory);
    registerShortcut("show_audio_waveforms", "Show Audio Waveforms", QKeySequence(Qt::CTRL | Qt::Key_W), TimelineContext, TimelineCategory);
    registerShortcut("show_video_thumbnails", "Show Video Thumbnails", QKeySequence(Qt::CTRL | Qt::Key_T), TimelineContext, TimelineCategory);
}

void KeyboardShortcuts::setupToolsShortcuts()
{
    // Tool switching (Q/W/E/R/T pattern)
    registerShortcut("select_tool", "Select Tool", QKeySequence(Qt::Key_Q), TimelineContext, ToolsCategory);
    registerShortcut("track_select_tool", "Track Select Tool", QKeySequence(Qt::Key_W), TimelineContext, ToolsCategory);
    registerShortcut("edit_tool", "Edit Tool", QKeySequence(Qt::Key_E), TimelineContext, ToolsCategory);
    registerShortcut("ripple_tool", "Ripple Tool", QKeySequence(Qt::Key_R), TimelineContext, ToolsCategory);
    registerShortcut("slip_tool", "Slip Tool", QKeySequence(Qt::Key_T), TimelineContext, ToolsCategory);
    registerShortcut("slide_tool", "Slide Tool", QKeySequence(Qt::Key_Y), TimelineContext, ToolsCategory);
    registerShortcut("roll_tool", "Roll Tool", QKeySequence(Qt::Key_U), TimelineContext, ToolsCategory);
    
    // Additional tools
    registerShortcut("pen_tool", "Pen Tool", QKeySequence(Qt::Key_P), TimelineContext, ToolsCategory);
    registerShortcut("crop_tool", "Crop Tool", QKeySequence(Qt::Key_C), TimelineContext, ToolsCategory);
    registerShortcut("transform_tool", "Transform Tool", QKeySequence(Qt::Key_M), TimelineContext, ToolsCategory);
}

void KeyboardShortcuts::setupWindowShortcuts()
{
    // Panel toggles
    registerShortcut("toggle_timeline", "Toggle Timeline Panel", QKeySequence(Qt::Key_F1), GlobalContext, WindowCategory);
    registerShortcut("toggle_inspector", "Toggle Inspector Panel", QKeySequence(Qt::Key_F2), GlobalContext, WindowCategory);
    registerShortcut("toggle_media_browser", "Toggle Media Browser", QKeySequence(Qt::Key_F3), GlobalContext, WindowCategory);
    registerShortcut("toggle_project", "Toggle Project Panel", QKeySequence(Qt::Key_F4), GlobalContext, WindowCategory);
    
    // Workspace management
    registerShortcut("workspace_editing", "Editing Workspace", QKeySequence(Qt::Key_F5), GlobalContext, WindowCategory);
    registerShortcut("workspace_color", "Color Workspace", QKeySequence(Qt::Key_F6), GlobalContext, WindowCategory);
    registerShortcut("workspace_audio", "Audio Workspace", QKeySequence(Qt::Key_F7), GlobalContext, WindowCategory);
    registerShortcut("workspace_effects", "Effects Workspace", QKeySequence(Qt::Key_F8), GlobalContext, WindowCategory);
    
    // Window controls
    registerShortcut("toggle_fullscreen", "Toggle Full Screen", QKeySequence(Qt::Key_F11), GlobalContext, WindowCategory);
    registerShortcut("minimize_window", "Minimize Window", QKeySequence(Qt::CTRL | Qt::Key_M), GlobalContext, WindowCategory);
    registerShortcut("new_window", "New Window", QKeySequence(Qt::CTRL | Qt::SHIFT | Qt::Key_N), GlobalContext, WindowCategory);
}

void KeyboardShortcuts::setupFileShortcuts()
{
    // Project operations
    registerShortcut("new_project", "New Project", QKeySequence::New, GlobalContext, FileCategory);
    registerShortcut("open_project", "Open Project", QKeySequence::Open, GlobalContext, FileCategory);
    registerShortcut("save_project", "Save Project", QKeySequence::Save, GlobalContext, FileCategory);
    registerShortcut("save_project_as", "Save Project As", QKeySequence::SaveAs, GlobalContext, FileCategory);
    registerShortcut("close_project", "Close Project", QKeySequence::Close, GlobalContext, FileCategory);
    
    // Import/Export
    registerShortcut("import_media", "Import Media", QKeySequence(Qt::CTRL | Qt::Key_I), GlobalContext, FileCategory);
    registerShortcut("export_sequence", "Export Sequence", QKeySequence(Qt::CTRL | Qt::Key_E), GlobalContext, FileCategory);
    registerShortcut("export_frame", "Export Frame", QKeySequence(Qt::CTRL | Qt::SHIFT | Qt::Key_E), GlobalContext, FileCategory);
    
    // Sequence operations
    registerShortcut("new_sequence", "New Sequence", QKeySequence(Qt::CTRL | Qt::Key_N), GlobalContext, FileCategory);
    registerShortcut("sequence_settings", "Sequence Settings", QKeySequence(Qt::CTRL | Qt::SHIFT | Qt::Key_S), GlobalContext, FileCategory);
}

void KeyboardShortcuts::setupViewShortcuts()
{
    // View controls
    registerShortcut("fit_to_window", "Fit to Window", QKeySequence(Qt::SHIFT | Qt::Key_F), GlobalContext, ViewCategory);
    registerShortcut("actual_size", "Actual Size", QKeySequence(Qt::CTRL | Qt::Key_1), GlobalContext, ViewCategory);
    registerShortcut("zoom_25", "Zoom to 25%", QKeySequence(Qt::CTRL | Qt::Key_2), GlobalContext, ViewCategory);
    registerShortcut("zoom_50", "Zoom to 50%", QKeySequence(Qt::CTRL | Qt::Key_3), GlobalContext, ViewCategory);
    registerShortcut("zoom_100", "Zoom to 100%", QKeySequence(Qt::CTRL | Qt::Key_4), GlobalContext, ViewCategory);
    registerShortcut("zoom_200", "Zoom to 200%", QKeySequence(Qt::CTRL | Qt::Key_5), GlobalContext, ViewCategory);
    
    // Safe areas and guides
    registerShortcut("toggle_safe_areas", "Toggle Safe Areas", QKeySequence(Qt::Key_Apostrophe), GlobalContext, ViewCategory);
    registerShortcut("toggle_guides", "Toggle Guides", QKeySequence(Qt::Key_Semicolon), GlobalContext, ViewCategory);
    registerShortcut("toggle_grid", "Toggle Grid", QKeySequence(Qt::CTRL | Qt::Key_Semicolon), GlobalContext, ViewCategory);
}

void KeyboardShortcuts::registerShortcut(const QString& id, const QString& description,
                                        const QKeySequence& keySequence, ShortcutContext context,
                                        ShortcutCategory category, bool customizable)
{
    ShortcutInfo info;
    info.id = id;
    info.description = description;
    info.keySequence = keySequence;
    info.context = context;
    info.category = category;
    info.enabled = true;
    info.customizable = customizable;
    
    registerShortcut(info);
}

void KeyboardShortcuts::registerShortcut(const ShortcutInfo& info)
{
    m_shortcuts[info.id] = info;
    createShortcutObject(info.id);
    
    qCDebug(jveKeyboardShortcuts, "Registered shortcut: %s (%s)", 
            qPrintable(info.id), qPrintable(info.keySequence.toString()));
}

bool KeyboardShortcuts::setShortcut(const QString& id, const QKeySequence& newSequence)
{
    if (!m_shortcuts.contains(id)) {
        qCWarning(jveKeyboardShortcuts, "Shortcut not found: %s", qPrintable(id));
        return false;
    }
    
    if (!m_shortcuts[id].customizable) {
        qCWarning(jveKeyboardShortcuts, "Shortcut not customizable: %s", qPrintable(id));
        return false;
    }
    
    // Check for conflicts
    if (hasConflict(id, newSequence)) {
        qCWarning(jveKeyboardShortcuts, "Shortcut conflict detected for: %s", qPrintable(newSequence.toString()));
        return false;
    }
    
    m_shortcuts[id].keySequence = newSequence;
    updateShortcutObject(id);
    
    qCDebug(jveKeyboardShortcuts, "Updated shortcut %s to %s", qPrintable(id), qPrintable(newSequence.toString()));
    return true;
}

QKeySequence KeyboardShortcuts::getShortcut(const QString& id) const
{
    if (m_shortcuts.contains(id)) {
        return m_shortcuts[id].keySequence;
    }
    return QKeySequence();
}

bool KeyboardShortcuts::enableShortcut(const QString& id, bool enabled)
{
    if (!m_shortcuts.contains(id)) {
        return false;
    }
    
    m_shortcuts[id].enabled = enabled;
    
    if (m_shortcutObjects.contains(id)) {
        m_shortcutObjects[id]->setEnabled(enabled);
    }
    
    return true;
}

bool KeyboardShortcuts::isShortcutEnabled(const QString& id) const
{
    if (m_shortcuts.contains(id)) {
        return m_shortcuts[id].enabled;
    }
    return false;
}

void KeyboardShortcuts::setActiveContext(ShortcutContext context)
{
    if (m_activeContext == context) {
        return;
    }
    
    m_activeContext = context;
    
    // Update shortcut object states based on context
    for (auto it = m_shortcuts.begin(); it != m_shortcuts.end(); ++it) {
        const QString& id = it.key();
        const ShortcutInfo& info = it.value();
        
        if (m_shortcutObjects.contains(id)) {
            bool shouldBeActive = (info.context == GlobalContext || info.context == context);
            m_shortcutObjects[id]->setEnabled(info.enabled && shouldBeActive);
        }
    }
    
    qCDebug(jveKeyboardShortcuts, "Active context changed to: %d", static_cast<int>(context));
}

KeyboardShortcuts::ShortcutContext KeyboardShortcuts::getActiveContext() const
{
    return m_activeContext;
}

QStringList KeyboardShortcuts::getShortcutIds() const
{
    return m_shortcuts.keys();
}

QStringList KeyboardShortcuts::getShortcutIds(ShortcutCategory category) const
{
    QStringList ids;
    for (auto it = m_shortcuts.begin(); it != m_shortcuts.end(); ++it) {
        if (it.value().category == category) {
            ids.append(it.key());
        }
    }
    return ids;
}

QStringList KeyboardShortcuts::getShortcutIds(ShortcutContext context) const
{
    QStringList ids;
    for (auto it = m_shortcuts.begin(); it != m_shortcuts.end(); ++it) {
        if (it.value().context == context) {
            ids.append(it.key());
        }
    }
    return ids;
}

KeyboardShortcuts::ShortcutInfo KeyboardShortcuts::getShortcutInfo(const QString& id) const
{
    return m_shortcuts.value(id);
}

QStringList KeyboardShortcuts::getConflictingShortcuts(const QKeySequence& sequence, ShortcutContext context) const
{
    QStringList conflicts;
    for (auto it = m_shortcuts.begin(); it != m_shortcuts.end(); ++it) {
        const ShortcutInfo& info = it.value();
        if (info.keySequence == sequence && 
            (info.context == context || info.context == GlobalContext || context == GlobalContext)) {
            conflicts.append(it.key());
        }
    }
    return conflicts;
}

bool KeyboardShortcuts::hasConflict(const QString& id, const QKeySequence& sequence) const
{
    if (!m_shortcuts.contains(id)) {
        return false;
    }
    
    ShortcutContext context = m_shortcuts[id].context;
    QStringList conflicts = getConflictingShortcuts(sequence, context);
    conflicts.removeAll(id); // Remove self from conflicts
    
    return !conflicts.isEmpty();
}

void KeyboardShortcuts::createShortcutObject(const QString& id)
{
    if (!m_shortcuts.contains(id) || !m_parentWidget) {
        return;
    }
    
    const ShortcutInfo& info = m_shortcuts[id];
    
    QShortcut* shortcut = new QShortcut(info.keySequence, m_parentWidget);
    shortcut->setContext(Qt::ApplicationShortcut);
    shortcut->setEnabled(info.enabled);
    
    connect(shortcut, &QShortcut::activated, this, &KeyboardShortcuts::onShortcutTriggered);
    
    m_shortcutObjects[id] = shortcut;
}

void KeyboardShortcuts::updateShortcutObject(const QString& id)
{
    if (!m_shortcutObjects.contains(id) || !m_shortcuts.contains(id)) {
        return;
    }
    
    const ShortcutInfo& info = m_shortcuts[id];
    QShortcut* shortcut = m_shortcutObjects[id];
    
    shortcut->setKey(info.keySequence);
    shortcut->setEnabled(info.enabled);
}

void KeyboardShortcuts::removeShortcutObject(const QString& id)
{
    if (m_shortcutObjects.contains(id)) {
        delete m_shortcutObjects[id];
        m_shortcutObjects.remove(id);
    }
}

void KeyboardShortcuts::onShortcutTriggered()
{
    QShortcut* shortcut = qobject_cast<QShortcut*>(sender());
    if (!shortcut) {
        return;
    }
    
    // Find the shortcut ID
    QString id;
    for (auto it = m_shortcutObjects.begin(); it != m_shortcutObjects.end(); ++it) {
        if (it.value() == shortcut) {
            id = it.key();
            break;
        }
    }
    
    if (!id.isEmpty()) {
        emitShortcutSignal(id);
    }
}

void KeyboardShortcuts::emitShortcutSignal(const QString& id)
{
    // Emit specific signals for known shortcuts
    if (id == "play_pause") emit playPauseRequested();
    else if (id == "stop") emit stopRequested();
    else if (id == "play_backward") emit playBackwardRequested();
    else if (id == "play_forward") emit playForwardRequested();
    else if (id == "blade_tool") emit bladeToolRequested();
    else if (id == "selection_tool") emit selectionToolRequested();
    else if (id == "split_clip") emit splitClipRequested();
    else if (id == "delete_clip") emit deleteClipRequested();
    else if (id == "ripple_delete") emit rippleDeleteRequested();
    else if (id == "copy") emit copyRequested();
    else if (id == "paste") emit pasteRequested();
    else if (id == "cut") emit cutRequested();
    else if (id == "undo") emit undoRequested();
    else if (id == "redo") emit redoRequested();
    else if (id == "select_all") emit selectAllRequested();
    else if (id == "deselect_all") emit deselectAllRequested();
    else if (id == "zoom_in") emit zoomInRequested();
    else if (id == "zoom_out") emit zoomOutRequested();
    else if (id == "zoom_to_fit") emit zoomToFitRequested();
    else if (id == "toggle_timeline") emit toggleTimelineRequested();
    else if (id == "toggle_inspector") emit toggleInspectorRequested();
    else if (id == "toggle_media_browser") emit toggleMediaBrowserRequested();
    else if (id == "toggle_project") emit toggleProjectRequested();
    else if (id == "toggle_fullscreen") emit toggleFullScreenRequested();
    else {
        // Emit generic signal for custom shortcuts
        emit customShortcutTriggered(id);
    }
    
    qCDebug(jveKeyboardShortcuts, "Shortcut triggered: %s", qPrintable(id));
}

void KeyboardShortcuts::saveShortcuts()
{
    QSettings settings;
    settings.beginGroup(m_settingsGroup);
    
    for (auto it = m_shortcuts.begin(); it != m_shortcuts.end(); ++it) {
        const QString& id = it.key();
        const ShortcutInfo& info = it.value();
        
        if (info.customizable) {
            settings.setValue(getSettingsKey(id), info.keySequence.toString());
            settings.setValue(getSettingsKey(id) + "_enabled", info.enabled);
        }
    }
    
    settings.endGroup();
    qCDebug(jveKeyboardShortcuts, "Shortcuts saved to settings");
}

void KeyboardShortcuts::loadShortcuts()
{
    QSettings settings;
    settings.beginGroup(m_settingsGroup);
    
    for (auto it = m_shortcuts.begin(); it != m_shortcuts.end(); ++it) {
        const QString& id = it.key();
        ShortcutInfo& info = it.value();
        
        if (info.customizable) {
            QString keyString = settings.value(getSettingsKey(id), info.keySequence.toString()).toString();
            bool enabled = settings.value(getSettingsKey(id) + "_enabled", info.enabled).toBool();
            
            info.keySequence = QKeySequence(keyString);
            info.enabled = enabled;
            
            updateShortcutObject(id);
        }
    }
    
    settings.endGroup();
    qCDebug(jveKeyboardShortcuts, "Shortcuts loaded from settings");
}

void KeyboardShortcuts::resetToDefaults()
{
    // Clear settings
    QSettings settings;
    settings.beginGroup(m_settingsGroup);
    settings.clear();
    settings.endGroup();
    
    // Reload default shortcuts
    setupDefaultShortcuts();
    
    qCDebug(jveKeyboardShortcuts, "Shortcuts reset to defaults");
}

QString KeyboardShortcuts::getSettingsKey(const QString& id) const
{
    return QString("shortcut_%1").arg(id);
}

// Placeholder implementations for preset management
void KeyboardShortcuts::loadDefaultShortcuts() { setupDefaultShortcuts(); }
void KeyboardShortcuts::loadAvidPreset() { /* TODO: Implement Avid shortcuts */ }
void KeyboardShortcuts::loadFCP7Preset() { /* TODO: Implement FCP7 shortcuts */ }
void KeyboardShortcuts::loadResolvePreset() { /* TODO: Implement Resolve shortcuts */ }
void KeyboardShortcuts::saveCustomPreset(const QString&) { /* TODO: Implement custom preset saving */ }
void KeyboardShortcuts::loadCustomPreset(const QString&) { /* TODO: Implement custom preset loading */ }
QStringList KeyboardShortcuts::getAvailablePresets() const { return {"Default", "Avid", "FCP7", "Resolve"}; }
void KeyboardShortcuts::onContextChanged(ShortcutContext newContext) { setActiveContext(newContext); }