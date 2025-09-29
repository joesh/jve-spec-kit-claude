#pragma once

#include <QObject>
#include <QDrag>
#include <QMimeData>
#include <QPixmap>
#include <QPoint>
#include <QDropEvent>
#include <QDragEnterEvent>
#include <QDragMoveEvent>
#include <QDragLeaveEvent>
#include <QWidget>
#include <QAbstractItemView>
#include <QListWidget>
#include <QTreeWidget>
#include <QPainter>
#include <QApplication>
#include <QCursor>
#include <QLoggingCategory>
#include <QStringList>
#include <QUrl>
#include <QFileInfo>
#include <QJsonObject>
#include <QJsonDocument>

Q_DECLARE_LOGGING_CATEGORY(jveDragDrop)

/**
 * Professional drag and drop management system for video editing
 * 
 * Features:
 * - Media asset drag from browser to timeline/bins
 * - Timeline clip drag and drop with snap, ripple, and overwrite modes
 * - Bin organization with drag-drop folder management
 * - External file import via drag-drop from filesystem
 * - Professional visual feedback during drag operations
 * - Industry-standard drop zones and insertion indicators
 * - Context-sensitive drop validation and rejection
 * - Multi-selection drag support for professional workflows
 * 
 * Drag Sources:
 * - Media Browser: Assets, bins, sequences
 * - Timeline: Clips, selections, ranges
 * - Project Panel: Sequences, bins, nested projects
 * - External: Files from filesystem, other applications
 * 
 * Drop Targets:
 * - Timeline: Clip placement with professional editing modes
 * - Media Browser: Asset organization and bin management
 * - Project Panel: Project organization and structure
 * - Inspector: Property assignment and keyframe data
 * 
 * Visual Feedback:
 * - Custom drag cursors indicating operation type
 * - Drop zone highlighting with professional styling
 * - Insertion indicators showing precise placement
 * - Rejection feedback for invalid operations
 * 
 * Professional Editing Modes:
 * - Insert Mode: Timeline insertion with ripple
 * - Overwrite Mode: Replace existing content
 * - Replace Mode: Smart replacement of similar content
 * - Three-Point Editing: Professional source/record workflows
 */
class DragDropManager : public QObject
{
    Q_OBJECT

public:
    enum DragType {
        MediaAssetDrag,      // Media files, clips, sequences
        TimelineClipDrag,    // Timeline clips being repositioned
        BinFolderDrag,       // Bin organization operations
        ExternalFileDrag,    // Files from filesystem
        PropertyDrag,        // Property values, keyframes
        SelectionDrag        // Multi-selection operations
    };

    enum DropMode {
        InsertMode,          // Insert with ripple (default)
        OverwriteMode,       // Overwrite existing content
        ReplaceMode,         // Smart replace similar content
        ThreePointMode       // Professional 3-point editing
    };

    enum DropZone {
        TimelineZone,        // Timeline tracks and playhead
        MediaBrowserZone,    // Media browser bins and assets
        ProjectPanelZone,    // Project structure organization
        InspectorZone,       // Property assignment
        InvalidZone          // Rejection zone
    };

    struct DragData {
        DragType type;
        QStringList itemIds;     // IDs of dragged items
        QJsonObject metadata;    // Additional drag context
        QWidget* sourceWidget;   // Originating widget
        QPoint startPosition;    // Drag start position
    };

    struct DropInfo {
        DropZone zone;
        DropMode mode;
        QPoint position;         // Drop position in widget coordinates
        QString targetId;        // Target track, bin, or container ID
        qint64 timePosition;     // Timeline position (for timeline drops)
        bool isValidDrop;        // Whether drop is allowed
    };

    explicit DragDropManager(QObject* parent = nullptr);
    ~DragDropManager() = default;

    // Drag initiation
    void startDrag(DragType type, const QStringList& itemIds, 
                  const QJsonObject& metadata, QWidget* sourceWidget);
    void startMediaAssetDrag(const QStringList& assetIds, QWidget* sourceWidget);
    void startTimelineClipDrag(const QStringList& clipIds, QWidget* sourceWidget);
    void startBinFolderDrag(const QStringList& binIds, QWidget* sourceWidget);

    // Drop handling
    bool handleDragEnter(QDragEnterEvent* event, QWidget* targetWidget);
    bool handleDragMove(QDragMoveEvent* event, QWidget* targetWidget);
    void handleDragLeave(QDragLeaveEvent* event, QWidget* targetWidget);
    bool handleDrop(QDropEvent* event, QWidget* targetWidget);

    // Drop mode configuration
    void setDropMode(DropMode mode);
    DropMode getDropMode() const;
    void toggleDropMode(); // Cycle through modes

    // Validation
    bool validateDrop(const DragData& dragData, const DropInfo& dropInfo) const;
    DropZone identifyDropZone(QWidget* targetWidget, const QPoint& position) const;

    // Visual feedback
    void showDropIndicator(QWidget* targetWidget, const QPoint& position, bool isValid = true);
    void hideDropIndicator(QWidget* targetWidget);
    void updateDragCursor(DragType type, DropMode mode, bool isValidTarget = true);

    // External file handling
    bool acceptExternalFiles(const QList<QUrl>& urls) const;
    QStringList getSupportedFileExtensions() const;
    void processExternalFileDrop(const QList<QUrl>& urls, const DropInfo& dropInfo);

    // Professional editing features
    void enableSnapToPlayhead(bool enabled);
    void enableSnapToClips(bool enabled);
    void setSnapTolerance(int pixels);
    bool isSnapEnabled() const;

signals:
    // Drag lifecycle
    void dragStarted(DragType type, const QStringList& itemIds);
    void dragMoved(const QPoint& position, bool isValidTarget);
    void dragFinished(bool dropAccepted);

    // Drop operations
    void mediaDropped(const QStringList& assetIds, const QString& targetBin);
    void clipsDropped(const QStringList& clipIds, const QString& targetTrack, qint64 timePosition);
    void binsReorganized(const QStringList& binIds, const QString& targetParent);
    void externalFilesDropped(const QList<QUrl>& files, const DropInfo& dropInfo);
    void propertyDropped(const QString& propertyName, const QJsonObject& value, const QString& targetClip);

    // Timeline operations
    void timelineInsertRequested(const QStringList& assetIds, const QString& trackId, qint64 time);
    void timelineOverwriteRequested(const QStringList& assetIds, const QString& trackId, qint64 time);
    void timelineReplaceRequested(const QStringList& assetIds, const QString& trackId, qint64 time);

    // Visual feedback
    void showInsertionIndicator(const QPoint& position);
    void hideInsertionIndicator();
    void showDropZoneHighlight(DropZone zone, bool highlight);
    void dragFeedbackUpdate();
    void snapFeedbackUpdate();

public slots:
    void onSelectionChanged(const QStringList& selectedItems);
    void onPlayheadPositionChanged(qint64 position);
    void onDropModeChanged(DropMode mode);

private slots:
    void onDragTimer();
    void onSnapTimer();

private:
    // Setup
    void setupMimeTypes();
    void setupDragCursors();
    void setupDropZones();

    // Drag creation
    QDrag* createDrag(const DragData& dragData);
    QMimeData* createMimeData(const DragData& dragData);
    QPixmap createDragPixmap(const DragData& dragData);

    // Drop validation
    bool isValidMediaTarget(const QString& targetId, DropZone zone) const;
    bool isValidTimelineTarget(const QString& trackId, qint64 time) const;
    bool isValidBinTarget(const QString& binId) const;

    // Professional editing helpers
    qint64 snapToNearestPosition(qint64 position, const QString& trackId) const;
    QStringList getSnappablePositions(const QString& trackId) const;
    bool shouldSnapToPlayhead(qint64 position) const;

    // Visual feedback implementation
    void drawInsertionIndicator(QWidget* widget, const QPoint& position);
    void drawDropZoneHighlight(QWidget* widget, DropZone zone, bool highlight);
    void drawTimelineDropIndicator(QWidget* timeline, const QString& trackId, qint64 time);

    // Drop handling helpers
    void handleTimelineDrop(DragType type, const QStringList& itemIds, const QPoint& position);
    void handleMediaBrowserDrop(DragType type, const QStringList& itemIds, const QPoint& position);
    void handleProjectPanelDrop(DragType type, const QStringList& itemIds, const QPoint& position);
    void handleInspectorDrop(DragType type, const QStringList& itemIds, const QPoint& position);

    // Cursor management
    void setCursorForOperation(DragType type, DropMode mode, bool isValid);
    QCursor createCustomCursor(const QString& iconName, const QString& text = QString());

private:
    // Current drag state
    DragData m_currentDragData;
    bool m_isDragging = false;
    QWidget* m_currentTarget = nullptr;
    DropInfo m_currentDropInfo;

    // Drop mode configuration
    DropMode m_dropMode = InsertMode;
    bool m_snapToPlayhead = true;
    bool m_snapToClips = true;
    int m_snapTolerance = 10;

    // Visual feedback
    QWidget* m_indicatorWidget = nullptr;
    QPoint m_indicatorPosition;
    bool m_showingIndicator = false;

    // Supported mime types
    QStringList m_mediaMimeTypes;
    QStringList m_supportedExtensions;

    // Professional editing state
    qint64 m_playheadPosition = 0;
    QStringList m_selectedItems;
    bool m_dragActive = false;
    bool m_snapActive = false;

    // Cursors for different operations
    QCursor m_insertCursor;
    QCursor m_overwriteCursor;
    QCursor m_replaceCursor;
    QCursor m_invalidCursor;

    // Constants
    static constexpr int DRAG_START_DISTANCE = 10;
    static constexpr int SNAP_TOLERANCE_DEFAULT = 10;
    static constexpr int DRAG_PIXMAP_MAX_WIDTH = 300;
    static constexpr int DRAG_PIXMAP_MAX_HEIGHT = 200;
};