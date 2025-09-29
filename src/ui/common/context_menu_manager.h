#pragma once

#include <QObject>
#include <QMenu>
#include <QAction>
#include <QPoint>
#include <QWidget>
#include <QStringList>
#include <QLoggingCategory>

Q_DECLARE_LOGGING_CATEGORY(jveContextMenus)

/**
 * Professional context menu system for video editing
 * 
 * Features:
 * - Context-sensitive menus that adapt based on selection and panel
 * - Professional video editing actions (cut, copy, paste, delete, etc.)
 * - Timeline-specific actions (split, blade, ripple delete, etc.)
 * - Inspector actions (reset to default, copy keyframes, etc.)
 * - Media browser actions (import, create bin, rename, etc.)
 * - Project actions (new sequence, duplicate, settings, etc.)
 * - Professional keyboard shortcut integration
 * - Dynamic menu construction based on current state
 * 
 * Design Philosophy:
 * - Menus adapt based on what's selected and where the user clicked
 * - Industry-standard actions following Avid/FCP7/Resolve patterns
 * - Clear action hierarchies with separators for organization
 * - Consistent terminology across all panels
 * 
 * Context Types:
 * - Timeline: Clip operations, track management, playhead control
 * - Inspector: Property manipulation, keyframe operations
 * - Media Browser: Asset management, bin organization
 * - Project: Sequence and project-level operations
 */
class ContextMenuManager : public QObject
{
    Q_OBJECT

public:
    enum MenuContext {
        TimelineContext,        // Timeline panel operations
        InspectorContext,       // Property inspector operations
        MediaBrowserContext,    // Media browser operations
        ProjectContext,         // Project panel operations
        ClipContext,           // Individual clip operations
        TrackContext,          // Track-level operations
        SelectionContext,      // Multi-selection operations
        EmptySpaceContext      // Empty area operations
    };

    enum ActionCategory {
        EditingActions,        // Cut, copy, paste, delete
        TimelineActions,       // Split, blade, ripple operations
        SelectionActions,      // Select all, invert selection
        NavigationActions,     // Go to beginning/end, next/previous edit
        PropertyActions,       // Reset, copy keyframes, etc.
        OrganizationActions,   // Create bin, rename, move
        ProjectActions,        // New sequence, settings, etc.
        PlaybackActions,       // Play, stop, mark in/out
        ToolActions           // Tool selection and options
    };

    struct MenuActionInfo {
        QString id;
        QString text;
        QString shortcut;
        QString iconName;
        ActionCategory category;
        bool enabled = true;
        bool checkable = false;
        bool checked = false;
        QString toolTip;
    };

    explicit ContextMenuManager(QObject* parent = nullptr);
    ~ContextMenuManager() = default;

    // Menu creation and management
    QMenu* createContextMenu(MenuContext context, const QPoint& position, QWidget* parent = nullptr);
    QMenu* createTimelineContextMenu(const QPoint& position, QWidget* parent = nullptr);
    QMenu* createInspectorContextMenu(const QPoint& position, QWidget* parent = nullptr);
    QMenu* createMediaBrowserContextMenu(const QPoint& position, QWidget* parent = nullptr);
    QMenu* createProjectContextMenu(const QPoint& position, QWidget* parent = nullptr);
    
    // Context-specific menus
    QMenu* createClipContextMenu(const QStringList& selectedClipIds, QWidget* parent = nullptr);
    QMenu* createTrackContextMenu(const QString& trackId, QWidget* parent = nullptr);
    QMenu* createSelectionContextMenu(const QStringList& selectedItemIds, QWidget* parent = nullptr);
    QMenu* createEmptySpaceContextMenu(QWidget* parent = nullptr);

    // Action management
    void registerAction(const MenuActionInfo& actionInfo);
    void enableAction(const QString& actionId, bool enabled);
    void setActionText(const QString& actionId, const QString& text);
    void setActionShortcut(const QString& actionId, const QString& shortcut);
    
    // State management
    void setHasSelection(bool hasSelection);
    void setSelectedClips(const QStringList& clipIds);
    void setSelectedTracks(const QStringList& trackIds);
    void setPlayheadPosition(double position);
    void setCurrentContext(MenuContext context);

signals:
    // Editing actions
    void cutRequested();
    void copyRequested();
    void pasteRequested();
    void deleteRequested();
    void duplicateRequested();
    
    // Timeline actions
    void splitClipRequested();
    void bladeAllTracksRequested();
    void rippleDeleteRequested();
    void rippleTrimRequested();
    void rollEditRequested();
    void slipEditRequested();
    void slideEditRequested();
    void linkClipsRequested();
    void unlinkClipsRequested();
    
    // Selection actions
    void selectAllRequested();
    void deselectAllRequested();
    void invertSelectionRequested();
    void selectAllOnTrackRequested(const QString& trackId);
    void selectFromPlayheadRequested();
    void selectToPlayheadRequested();
    
    // Navigation actions
    void goToInPointRequested();
    void goToOutPointRequested();
    void goToBeginningRequested();
    void goToEndRequested();
    void nextEditRequested();
    void previousEditRequested();
    
    // Property actions
    void resetPropertyRequested(const QString& propertyId);
    void copyKeyframesRequested();
    void pasteKeyframesRequested();
    void deleteKeyframesRequested();
    void addKeyframeRequested();
    void removeKeyframeRequested();
    
    // Organization actions
    void createBinRequested();
    void renameBinRequested(const QString& binId);
    void deleteBinRequested(const QString& binId);
    void importMediaRequested();
    void relinkMediaRequested(const QString& mediaId);
    void revealInFinderRequested(const QString& mediaId);
    
    // Project actions
    void newSequenceRequested();
    void duplicateSequenceRequested(const QString& sequenceId);
    void sequenceSettingsRequested(const QString& sequenceId);
    void deleteSequenceRequested(const QString& sequenceId);
    
    // Playback actions
    void playPauseRequested();
    void stopRequested();
    void markInRequested();
    void markOutRequested();
    void clearInOutRequested();
    
    // Tool actions
    void selectToolRequested(const QString& toolName);
    void toolOptionsRequested(const QString& toolName);

public slots:
    void onActionTriggered();
    void onMenuAboutToShow();
    void onMenuAboutToHide();

private:
    void setupDefaultActions();
    void addEditingActions(QMenu* menu);
    void addTimelineActions(QMenu* menu);
    void addSelectionActions(QMenu* menu);
    void addNavigationActions(QMenu* menu);
    void addPropertyActions(QMenu* menu);
    void addOrganizationActions(QMenu* menu);
    void addProjectActions(QMenu* menu);
    void addPlaybackActions(QMenu* menu);
    void addToolActions(QMenu* menu);
    
    QAction* createAction(const MenuActionInfo& info, QMenu* parent);
    void addSeparator(QMenu* menu);
    void updateActionStates();
    void emitActionSignal(const QString& actionId);
    
    bool isValidForContext(const QString& actionId, MenuContext context) const;
    QString getActionText(const QString& actionId) const;
    QString getActionShortcut(const QString& actionId) const;
    bool isActionEnabled(const QString& actionId) const;

private:
    QHash<QString, MenuActionInfo> m_actionInfos;
    QHash<QString, QAction*> m_actions;
    MenuContext m_currentContext = TimelineContext;
    
    // State tracking
    bool m_hasSelection = false;
    QStringList m_selectedClipIds;
    QStringList m_selectedTrackIds;
    double m_playheadPosition = 0.0;
    QPoint m_lastClickPosition;
    
    // Action categories for organization
    QStringList m_editingActionIds;
    QStringList m_timelineActionIds;
    QStringList m_selectionActionIds;
    QStringList m_navigationActionIds;
    QStringList m_propertyActionIds;
    QStringList m_organizationActionIds;
    QStringList m_projectActionIds;
    QStringList m_playbackActionIds;
    QStringList m_toolActionIds;
};