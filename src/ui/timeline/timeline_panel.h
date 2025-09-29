#pragma once

#include <QWidget>
#include <QScrollArea>
#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QSplitter>
#include <QLabel>
#include <QGraphicsView>
#include <QGraphicsScene>
#include <QGraphicsItem>
#include <QRubberBand>
#include <QTimer>
#include <QKeyEvent>
#include <QMouseEvent>
#include <QWheelEvent>
#include <QContextMenuEvent>
#include <QMenu>
#include <QAction>
#include <QPainter>
#include <QBrush>
#include <QPen>
#include <QColor>
#include <QFont>
#include <QFontMetrics>
#include <QDateTime>

#include "core/models/sequence.h"
#include "core/models/track.h"
#include "core/models/clip.h"
#include "ui/common/context_menu_manager.h"
#include "core/commands/command_dispatcher.h"
#include "ui/selection/selection_manager.h"
#include "ui/common/ui_command_bridge.h"

/**
 * Professional timeline panel for video editing
 * 
 * Features:
 * - Multi-track timeline display with professional layout
 * - Clip visualization with thumbnails and waveforms
 * - Professional selection system (single, multi, range)
 * - Drag and drop for clip positioning
 * - Ripple and roll editing with visual feedback
 * - Professional zoom and pan controls
 * - Keyboard shortcuts following industry standards
 * - Context menus for editing operations
 * 
 * Design follows Avid/FCP7/Resolve patterns for professional workflows
 */
class TimelinePanel : public QWidget
{
    Q_OBJECT

public:
    explicit TimelinePanel(QWidget* parent = nullptr);
    ~TimelinePanel() = default;

    // Core functionality
    void setSequence(const Sequence& sequence);
    void setCommandDispatcher(CommandDispatcher* dispatcher);
    void setSelectionManager(SelectionManager* selectionManager);
    void setCommandBridge(UICommandBridge* commandBridge);
    
    // Timeline control
    void setPlayheadPosition(qint64 timeMs);
    qint64 getPlayheadPosition() const;
    void setZoomLevel(double zoomFactor);
    double getZoomLevel() const;
    void setTrackHeight(int height);
    int getTrackHeight() const;
    
    // Selection operations
    void selectClip(const QString& clipId);
    void selectClips(const QStringList& clipIds);
    void selectRange(qint64 startTime, qint64 endTime);
    void clearSelection();
    
    // Edit operations
    void splitClipAtPlayhead();
    void deleteSelectedClips();
    void rippleDeleteSelectedClips();
    void copySelectedClips();
    void pasteClips();
    
    // View operations
    void zoomToFit();
    void zoomToSelection();
    void frameView();

signals:
    void playheadPositionChanged(qint64 timeMs);
    void selectionChanged(const QStringList& clipIds);
    void clipDoubleClicked(const QString& clipId);
    void timelineRightClicked(const QPoint& position, const QString& context);
    void trackHeaderRightClicked(const QString& trackId, const QPoint& position);

protected:
    // Event handling
    void keyPressEvent(QKeyEvent* event) override;
    void mousePressEvent(QMouseEvent* event) override;
    void mouseMoveEvent(QMouseEvent* event) override;
    void mouseReleaseEvent(QMouseEvent* event) override;
    void wheelEvent(QWheelEvent* event) override;
    void contextMenuEvent(QContextMenuEvent* event) override;
    void resizeEvent(QResizeEvent* event) override;
    void paintEvent(QPaintEvent* event) override;

private slots:
    void onSelectionChanged(const QStringList& selectedItems);
    void onTrackHeaderClicked(const QString& trackId);
    void onClipMoved(const QString& clipId, const QString& trackId, qint64 newTime);
    void onPlayheadMoved(qint64 newTime);
    void updateViewport();

private:
    // Setup methods
    void setupUI();
    void setupLayout();
    void setupActions();
    void connectSignals();
    void setupContextMenus();
    
    // Drawing methods
    void drawTimeline(QPainter& painter);
    void drawTracks(QPainter& painter);
    void drawClips(QPainter& painter);
    void drawPlayhead(QPainter& painter);
    void drawSelection(QPainter& painter);
    void drawRuler(QPainter& painter);
    void drawTrackHeaders(QPainter& painter);
    
    // Helper methods
    QRect getClipRect(const Clip& clip) const;
    QRect getTrackRect(const Track& track) const;
    qint64 pixelToTime(int pixel) const;
    int timeToPixel(qint64 time) const;
    QString getTrackAtPosition(const QPoint& pos) const;
    QString getClipAtPosition(const QPoint& pos) const;
    void updateClipPositions();
    void updateScrollBars();
    
    // Professional editing helpers
    void performRippleEdit(const QString& clipId, qint64 deltaTime);
    void performRollEdit(const QString& clipId, qint64 deltaTime);
    void performSlipEdit(const QString& clipId, qint64 deltaTime);
    void performSlideEdit(const QString& clipId, qint64 deltaTime);
    
    // Context menu creation
    QMenu* createClipContextMenu(const QString& clipId);
    QMenu* createTrackContextMenu(const QString& trackId);
    QMenu* createTimelineContextMenu(qint64 time);

    // Core data
    Sequence m_sequence;
    CommandDispatcher* m_commandDispatcher = nullptr;
    SelectionManager* m_selectionManager = nullptr;
    ContextMenuManager* m_contextMenuManager = nullptr;
    UICommandBridge* m_commandBridge = nullptr;
    
    // UI components
    QScrollArea* m_scrollArea = nullptr;
    QWidget* m_timelineWidget = nullptr;
    QVBoxLayout* m_mainLayout = nullptr;
    QHBoxLayout* m_timelineLayout = nullptr;
    QSplitter* m_splitter = nullptr;
    
    // Timeline state
    qint64 m_playheadPosition = 0;
    double m_zoomFactor = 1.0;
    int m_trackHeight = 48;
    int m_trackHeaderWidth = 200;
    int m_rulerHeight = 32;
    
    // Selection and interaction
    QStringList m_selectedClips;
    QPoint m_lastMousePos;
    QString m_draggedClip;
    bool m_isDragging = false;
    bool m_isSelecting = false;
    QRubberBand* m_rubberBand = nullptr;
    QPoint m_selectionStart;
    
    // Professional editing state
    enum class EditMode {
        Select,
        Ripple,
        Roll,
        Slip,
        Slide
    } m_editMode = EditMode::Select;
    
    // Visual constants
    static constexpr int MIN_TRACK_HEIGHT = 24;
    static constexpr int MAX_TRACK_HEIGHT = 200;
    static constexpr double MIN_ZOOM = 0.1;
    static constexpr double MAX_ZOOM = 100.0;
    static constexpr int PLAYHEAD_WIDTH = 2;
    static constexpr int CLIP_MARGIN = 2;
    
    // Colors and styling
    QColor m_backgroundColor = QColor(45, 45, 45);
    QColor m_trackColor = QColor(60, 60, 60);
    QColor m_clipColor = QColor(100, 150, 200);
    QColor m_selectedClipColor = QColor(255, 165, 0);
    QColor m_playheadColor = QColor(255, 255, 255);
    QColor m_rulerColor = QColor(80, 80, 80);
    QFont m_timeFont = QFont("Arial", 10);
    QFont m_clipFont = QFont("Arial", 9);
};