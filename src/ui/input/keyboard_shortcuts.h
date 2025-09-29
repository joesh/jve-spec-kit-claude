#pragma once

#include <QObject>
#include <QShortcut>
#include <QKeySequence>
#include <QWidget>
#include <QMap>
#include <QStringList>
#include <QLoggingCategory>

Q_DECLARE_LOGGING_CATEGORY(jveKeyboardShortcuts)

/**
 * Professional keyboard shortcuts system for video editing
 * 
 * Features:
 * - Industry-standard video editing shortcuts (J/K/L, Cmd+B, etc.)
 * - Context-sensitive shortcuts that adapt based on focused panel
 * - Customizable shortcuts with conflict detection
 * - Professional NLE patterns from Avid/FCP7/Resolve
 * - Global shortcuts that work across all panels
 * - Timeline-specific shortcuts for editing operations
 * - Inspector shortcuts for property manipulation
 * - Media browser shortcuts for asset management
 * 
 * Shortcut Categories:
 * - Playback: J/K/L, Space, I/O points
 * - Editing: B (blade), V (selection), A (arrow), etc.
 * - Timeline: +/- (zoom), up/down (track navigation)
 * - Selection: A (select all), Shift+click (extend)
 * - Tools: Q/W/E/R/T for different editing tools
 * 
 * Design follows professional NLE keyboard shortcut conventions
 */
class KeyboardShortcuts : public QObject
{
    Q_OBJECT

public:
    enum ShortcutContext {
        GlobalContext,          // Works everywhere
        TimelineContext,        // Only when timeline has focus
        InspectorContext,       // Only when inspector has focus
        MediaBrowserContext,    // Only when media browser has focus
        ProjectContext          // Only when project panel has focus
    };

    enum ShortcutCategory {
        PlaybackCategory,       // J/K/L, Space, I/O
        EditingCategory,        // B, V, A, blade tools
        SelectionCategory,      // Select all, extend selection
        NavigationCategory,     // Arrow keys, page up/down
        TimelineCategory,       // Zoom, track navigation
        ToolsCategory,          // Q/W/E/R/T tool switching
        WindowCategory,         // Panel toggles, workspace
        FileCategory,           // Save, open, import
        ViewCategory            // Zoom, fit to window
    };

    struct ShortcutInfo {
        QString id;
        QString description;
        QKeySequence keySequence;
        ShortcutContext context;
        ShortcutCategory category;
        bool enabled = true;
        bool customizable = true;
    };

    explicit KeyboardShortcuts(QWidget* parent = nullptr);
    ~KeyboardShortcuts() = default;

    // Shortcut registration
    void registerShortcut(const QString& id, const QString& description,
                         const QKeySequence& keySequence, ShortcutContext context,
                         ShortcutCategory category, bool customizable = true);
    
    void registerShortcut(const ShortcutInfo& info);
    
    // Shortcut management
    bool setShortcut(const QString& id, const QKeySequence& newSequence);
    QKeySequence getShortcut(const QString& id) const;
    bool enableShortcut(const QString& id, bool enabled);
    bool isShortcutEnabled(const QString& id) const;
    
    // Context management
    void setActiveContext(ShortcutContext context);
    ShortcutContext getActiveContext() const;
    
    // Shortcut queries
    QStringList getShortcutIds() const;
    QStringList getShortcutIds(ShortcutCategory category) const;
    QStringList getShortcutIds(ShortcutContext context) const;
    ShortcutInfo getShortcutInfo(const QString& id) const;
    
    // Conflict detection
    QStringList getConflictingShortcuts(const QKeySequence& sequence, ShortcutContext context) const;
    bool hasConflict(const QString& id, const QKeySequence& sequence) const;
    
    // Preset management
    void loadDefaultShortcuts();
    void loadAvidPreset();
    void loadFCP7Preset();
    void loadResolvePreset();
    void saveCustomPreset(const QString& name);
    void loadCustomPreset(const QString& name);
    QStringList getAvailablePresets() const;
    
    // Persistence
    void saveShortcuts();
    void loadShortcuts();
    void resetToDefaults();

signals:
    // Playback shortcuts
    void playPauseRequested();
    void stopRequested();
    void playBackwardRequested();
    void playForwardRequested();
    void shuttleSlowRequested();
    void shuttleFastRequested();
    void frameStepBackwardRequested();
    void frameStepForwardRequested();
    void goToBeginningRequested();
    void goToEndRequested();
    void markInRequested();
    void markOutRequested();
    
    // Editing shortcuts
    void bladeToolRequested();
    void selectionToolRequested();
    void arrowToolRequested();
    void handToolRequested();
    void zoomToolRequested();
    
    // Timeline shortcuts
    void splitClipRequested();
    void deleteClipRequested();
    void rippleDeleteRequested();
    void copyRequested();
    void pasteRequested();
    void cutRequested();
    void undoRequested();
    void redoRequested();
    
    // Selection shortcuts
    void selectAllRequested();
    void deselectAllRequested();
    void selectNextClipRequested();
    void selectPreviousClipRequested();
    void extendSelectionRequested();
    
    // Navigation shortcuts
    void zoomInRequested();
    void zoomOutRequested();
    void zoomToFitRequested();
    void nextTrackRequested();
    void previousTrackRequested();
    void nextEditRequested();
    void previousEditRequested();
    
    // Tool shortcuts
    void selectToolRequested(const QString& toolName);
    
    // Window shortcuts
    void toggleTimelineRequested();
    void toggleInspectorRequested();
    void toggleMediaBrowserRequested();
    void toggleProjectRequested();
    void toggleFullScreenRequested();
    
    // Custom shortcuts
    void customShortcutTriggered(const QString& id);

public slots:
    void onContextChanged(ShortcutContext newContext);
    void onShortcutTriggered();

private:
    void setupDefaultShortcuts();
    void setupPlaybackShortcuts();
    void setupEditingShortcuts();
    void setupSelectionShortcuts();
    void setupNavigationShortcuts();
    void setupTimelineShortcuts();
    void setupToolsShortcuts();
    void setupWindowShortcuts();
    void setupFileShortcuts();
    void setupViewShortcuts();
    
    void createShortcutObject(const QString& id);
    void updateShortcutObject(const QString& id);
    void removeShortcutObject(const QString& id);
    
    void emitShortcutSignal(const QString& id);
    QString getSettingsKey(const QString& id) const;
    
private:
    QWidget* m_parentWidget = nullptr;
    QMap<QString, ShortcutInfo> m_shortcuts;
    QMap<QString, QShortcut*> m_shortcutObjects;
    ShortcutContext m_activeContext = GlobalContext;
    
    // Preset shortcuts for different NLE systems
    QMap<QString, QMap<QString, QKeySequence>> m_presets;
    
    // Settings persistence
    QString m_settingsGroup = "KeyboardShortcuts";
    
    // Professional video editing shortcuts
    static const QMap<QString, ShortcutInfo> s_defaultShortcuts;
};