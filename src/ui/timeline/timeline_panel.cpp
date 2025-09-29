#include "timeline_panel.h"

#include <QApplication>
#include <QScrollBar>
#include <QSizePolicy>
#include <QLoggingCategory>
#include <QtMath>

Q_LOGGING_CATEGORY(jveTimelinePanel, "jve.ui.timeline")

TimelinePanel::TimelinePanel(QWidget* parent)
    : QWidget(parent)
{
    qCDebug(jveTimelinePanel, "Initializing TimelinePanel");
    
    setupUI();
    setupLayout();
    setupActions();
    connectSignals();
    
    // Set focus policy for keyboard handling
    setFocusPolicy(Qt::StrongFocus);
    
    // Set minimum size for usability
    setMinimumSize(800, 300);
    
    qCDebug(jveTimelinePanel, "TimelinePanel initialized successfully");
}

void TimelinePanel::setupUI()
{
    // Create main scroll area for timeline
    m_scrollArea = new QScrollArea(this);
    m_scrollArea->setWidgetResizable(true);
    m_scrollArea->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOn);
    m_scrollArea->setVerticalScrollBarPolicy(Qt::ScrollBarAsNeeded);
    
    // Create timeline widget
    m_timelineWidget = new QWidget();
    m_timelineWidget->setMinimumSize(2000, 400); // Initial size
    m_timelineWidget->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);
    m_scrollArea->setWidget(m_timelineWidget);
    
    // Create rubber band for selection
    m_rubberBand = new QRubberBand(QRubberBand::Rectangle, m_timelineWidget);
    m_rubberBand->hide();
    
    // Set professional dark theme colors
    setStyleSheet(QString(
        "TimelinePanel { background-color: %1; }"
        "QScrollArea { background-color: %1; border: none; }"
        "QScrollBar:horizontal { background-color: %2; height: 16px; }"
        "QScrollBar:vertical { background-color: %2; width: 16px; }"
        "QScrollBar::handle { background-color: %3; border-radius: 4px; }"
        "QScrollBar::handle:hover { background-color: %4; }"
    ).arg(m_backgroundColor.name())
     .arg(m_trackColor.name())
     .arg(m_clipColor.name())
     .arg(m_selectedClipColor.name()));
}

void TimelinePanel::setupLayout()
{
    m_mainLayout = new QVBoxLayout(this);
    m_mainLayout->setContentsMargins(0, 0, 0, 0);
    m_mainLayout->setSpacing(0);
    
    // Add scroll area to main layout
    m_mainLayout->addWidget(m_scrollArea);
    
    setLayout(m_mainLayout);
}

void TimelinePanel::setupActions()
{
    // Professional keyboard shortcuts will be handled in keyPressEvent
    qCDebug(jveTimelinePanel, "Timeline actions configured");
}

void TimelinePanel::connectSignals()
{
    // Connect scroll area signals for viewport updates
    connect(m_scrollArea->horizontalScrollBar(), &QScrollBar::valueChanged,
            this, &TimelinePanel::updateViewport);
    connect(m_scrollArea->verticalScrollBar(), &QScrollBar::valueChanged,
            this, &TimelinePanel::updateViewport);
}

void TimelinePanel::setSequence(const Sequence& sequence)
{
    qCDebug(jveTimelinePanel, "Setting sequence: %s", qPrintable(sequence.name()));
    
    m_sequence = sequence;
    updateClipPositions();
    updateScrollBars();
    update();
}

void TimelinePanel::setCommandDispatcher(CommandDispatcher* dispatcher)
{
    m_commandDispatcher = dispatcher;
    qCDebug(jveTimelinePanel, "Command dispatcher connected");
}

void TimelinePanel::setSelectionManager(SelectionManager* selectionManager)
{
    if (m_selectionManager) {
        disconnect(m_selectionManager, nullptr, this, nullptr);
    }
    
    m_selectionManager = selectionManager;
    
    if (m_selectionManager) {
        connect(m_selectionManager, &SelectionManager::selectionChanged,
                this, &TimelinePanel::onSelectionChanged);
        qCDebug(jveTimelinePanel, "Selection manager connected");
    }
}

void TimelinePanel::setPlayheadPosition(qint64 timeMs)
{
    if (m_playheadPosition != timeMs) {
        m_playheadPosition = timeMs;
        update();
        emit playheadPositionChanged(timeMs);
    }
}

qint64 TimelinePanel::getPlayheadPosition() const
{
    return m_playheadPosition;
}

void TimelinePanel::setZoomLevel(double zoomFactor)
{
    double clampedZoom = qBound(MIN_ZOOM, zoomFactor, MAX_ZOOM);
    if (m_zoomFactor != clampedZoom) {
        m_zoomFactor = clampedZoom;
        updateClipPositions();
        updateScrollBars();
        update();
        qCDebug(jveTimelinePanel, "Zoom level set to: %f", m_zoomFactor);
    }
}

double TimelinePanel::getZoomLevel() const
{
    return m_zoomFactor;
}

void TimelinePanel::setTrackHeight(int height)
{
    int clampedHeight = qBound(MIN_TRACK_HEIGHT, height, MAX_TRACK_HEIGHT);
    if (m_trackHeight != clampedHeight) {
        m_trackHeight = clampedHeight;
        updateClipPositions();
        update();
        qCDebug(jveTimelinePanel, "Track height set to: %d", m_trackHeight);
    }
}

int TimelinePanel::getTrackHeight() const
{
    return m_trackHeight;
}

void TimelinePanel::selectClip(const QString& clipId)
{
    if (m_selectionManager) {
        m_selectionManager->select(clipId);
    }
}

void TimelinePanel::selectClips(const QStringList& clipIds)
{
    if (m_selectionManager) {
        m_selectionManager->selectAll(clipIds);
    }
}

void TimelinePanel::clearSelection()
{
    if (m_selectionManager) {
        m_selectionManager->clear();
    }
}

void TimelinePanel::keyPressEvent(QKeyEvent* event)
{
    // Professional keyboard shortcuts
    switch (event->key()) {
    case Qt::Key_Delete:
    case Qt::Key_Backspace:
        deleteSelectedClips();
        break;
        
    case Qt::Key_C:
        if (event->modifiers() & Qt::ControlModifier) {
            copySelectedClips();
        }
        break;
        
    case Qt::Key_V:
        if (event->modifiers() & Qt::ControlModifier) {
            pasteClips();
        }
        break;
        
    case Qt::Key_A:
        if (event->modifiers() & Qt::ControlModifier) {
            // Select all clips in timeline
            if (m_selectionManager) {
                QStringList allClips;
                // TODO: Get all clip IDs from sequence
                m_selectionManager->selectAll(allClips);
            }
        }
        break;
        
    case Qt::Key_B:
        // Blade tool (split at playhead)
        splitClipAtPlayhead();
        break;
        
    case Qt::Key_Equal:
    case Qt::Key_Plus:
        // Zoom in
        setZoomLevel(m_zoomFactor * 1.2);
        break;
        
    case Qt::Key_Minus:
        // Zoom out
        setZoomLevel(m_zoomFactor / 1.2);
        break;
        
    case Qt::Key_F:
        // Frame view
        frameView();
        break;
        
    default:
        QWidget::keyPressEvent(event);
        break;
    }
}

void TimelinePanel::mousePressEvent(QMouseEvent* event)
{
    setFocus(); // Ensure we receive keyboard events
    
    m_lastMousePos = event->pos();
    
    if (event->button() == Qt::LeftButton) {
        QString clipId = getClipAtPosition(event->pos());
        
        if (!clipId.isEmpty()) {
            // Click on clip
            if (event->modifiers() & Qt::ControlModifier) {
                // Multi-selection with Cmd+click
                if (m_selectionManager) {
                    m_selectionManager->toggleSelection(clipId);
                }
            } else if (event->modifiers() & Qt::ShiftModifier) {
                // Range selection with Shift+click
                // TODO: Implement range selection
            } else {
                // Single selection
                selectClip(clipId);
                m_draggedClip = clipId;
                m_isDragging = true;
            }
        } else {
            // Click on empty timeline
            if (!(event->modifiers() & Qt::ControlModifier)) {
                clearSelection();
            }
            
            // Start playhead positioning or selection rectangle
            qint64 clickTime = pixelToTime(event->pos().x() - m_trackHeaderWidth);
            setPlayheadPosition(clickTime);
            
            // Start selection rectangle
            m_isSelecting = true;
            m_selectionStart = event->pos();
            m_rubberBand->setGeometry(QRect(m_selectionStart, QSize()));
            m_rubberBand->show();
        }
    }
    
    QWidget::mousePressEvent(event);
}

void TimelinePanel::mouseMoveEvent(QMouseEvent* event)
{
    if (m_isDragging && !m_draggedClip.isEmpty()) {
        // Handle clip dragging
        QPoint delta = event->pos() - m_lastMousePos;
        qint64 timeDelta = pixelToTime(delta.x());
        
        // TODO: Implement clip dragging with snapping
        qCDebug(jveTimelinePanel, "Dragging clip %s by %lld ms", qPrintable(m_draggedClip), timeDelta);
        
    } else if (m_isSelecting) {
        // Update selection rectangle
        QRect selectionRect = QRect(m_selectionStart, event->pos()).normalized();
        m_rubberBand->setGeometry(selectionRect);
    }
    
    m_lastMousePos = event->pos();
    QWidget::mouseMoveEvent(event);
}

void TimelinePanel::mouseReleaseEvent(QMouseEvent* event)
{
    if (event->button() == Qt::LeftButton) {
        if (m_isDragging && !m_draggedClip.isEmpty()) {
            // Finish clip drag operation
            QPoint delta = event->pos() - m_lastMousePos;
            qint64 timeDelta = pixelToTime(delta.x());
            QString targetTrack = getTrackAtPosition(event->pos());
            
            if (timeDelta != 0 || !targetTrack.isEmpty()) {
                // Execute move command
                // TODO: Implement move command through dispatcher
                emit onClipMoved(m_draggedClip, targetTrack, m_playheadPosition + timeDelta);
            }
            
            m_isDragging = false;
            m_draggedClip.clear();
            
        } else if (m_isSelecting) {
            // Finish selection rectangle
            QRect selectionRect = m_rubberBand->geometry();
            
            // Find clips within selection rectangle
            QStringList selectedClips;
            // TODO: Implement clip selection by rectangle
            
            if (!selectedClips.isEmpty()) {
                selectClips(selectedClips);
            }
            
            m_rubberBand->hide();
            m_isSelecting = false;
        }
    }
    
    QWidget::mouseReleaseEvent(event);
}

void TimelinePanel::wheelEvent(QWheelEvent* event)
{
    if (event->modifiers() & Qt::ControlModifier) {
        // Zoom with Ctrl+wheel
        double scaleFactor = event->angleDelta().y() > 0 ? 1.1 : 0.9;
        setZoomLevel(m_zoomFactor * scaleFactor);
        event->accept();
    } else if (event->modifiers() & Qt::ShiftModifier) {
        // Horizontal scroll with Shift+wheel
        QScrollBar* hBar = m_scrollArea->horizontalScrollBar();
        hBar->setValue(hBar->value() - event->angleDelta().y());
        event->accept();
    } else {
        // Normal vertical scroll
        QWidget::wheelEvent(event);
    }
}

void TimelinePanel::contextMenuEvent(QContextMenuEvent* event)
{
    QString clipId = getClipAtPosition(event->pos());
    QMenu* menu = nullptr;
    
    if (!clipId.isEmpty()) {
        menu = createClipContextMenu(clipId);
    } else {
        QString trackId = getTrackAtPosition(event->pos());
        if (!trackId.isEmpty()) {
            menu = createTrackContextMenu(trackId);
        } else {
            qint64 time = pixelToTime(event->pos().x() - m_trackHeaderWidth);
            menu = createTimelineContextMenu(time);
        }
    }
    
    if (menu) {
        menu->exec(event->globalPos());
        menu->deleteLater();
    }
}

void TimelinePanel::paintEvent(QPaintEvent* event)
{
    QPainter painter(this);
    painter.setRenderHint(QPainter::Antialiasing, true);
    
    // Draw timeline components
    drawTimeline(painter);
    drawTracks(painter);
    drawClips(painter);
    drawPlayhead(painter);
    drawSelection(painter);
    drawRuler(painter);
    drawTrackHeaders(painter);
    
    QWidget::paintEvent(event);
}

void TimelinePanel::drawTimeline(QPainter& painter)
{
    // Fill background
    painter.fillRect(rect(), m_backgroundColor);
}

void TimelinePanel::drawTracks(QPainter& painter)
{
    // TODO: Draw track backgrounds and separators
    // This would iterate through sequence tracks and draw backgrounds
}

void TimelinePanel::drawClips(QPainter& painter)
{
    // TODO: Draw clips on timeline
    // This would iterate through clips and draw them with proper colors
}

void TimelinePanel::drawPlayhead(QPainter& painter)
{
    int playheadX = timeToPixel(m_playheadPosition) + m_trackHeaderWidth;
    
    painter.setPen(QPen(m_playheadColor, PLAYHEAD_WIDTH));
    painter.drawLine(playheadX, 0, playheadX, height());
}

void TimelinePanel::drawSelection(QPainter& painter)
{
    // TODO: Draw selection highlights on selected clips
}

void TimelinePanel::drawRuler(QPainter& painter)
{
    // TODO: Draw time ruler at top of timeline
    QRect rulerRect(m_trackHeaderWidth, 0, width() - m_trackHeaderWidth, m_rulerHeight);
    painter.fillRect(rulerRect, m_rulerColor);
    
    painter.setPen(Qt::white);
    painter.setFont(m_timeFont);
    
    // Draw time markings
    // TODO: Implement proper timecode display
}

void TimelinePanel::drawTrackHeaders(QPainter& painter)
{
    // TODO: Draw track headers on the left side
    QRect headerRect(0, m_rulerHeight, m_trackHeaderWidth, height() - m_rulerHeight);
    painter.fillRect(headerRect, m_trackColor);
}

// Helper methods
qint64 TimelinePanel::pixelToTime(int pixel) const
{
    return static_cast<qint64>(pixel / m_zoomFactor);
}

int TimelinePanel::timeToPixel(qint64 time) const
{
    return static_cast<int>(time * m_zoomFactor);
}

QString TimelinePanel::getClipAtPosition(const QPoint& pos) const
{
    // TODO: Implement hit testing for clips
    return QString();
}

QString TimelinePanel::getTrackAtPosition(const QPoint& pos) const
{
    // TODO: Implement hit testing for tracks
    return QString();
}

void TimelinePanel::updateClipPositions()
{
    // TODO: Update clip positions based on zoom and data
}

void TimelinePanel::updateScrollBars()
{
    // TODO: Update scroll bar ranges based on content
}

// Slot implementations
void TimelinePanel::onSelectionChanged(const QStringList& selectedItems)
{
    m_selectedClips = selectedItems;
    update();
    emit selectionChanged(selectedItems);
}

void TimelinePanel::onClipMoved(const QString& clipId, const QString& trackId, qint64 newTime)
{
    // TODO: Execute move command through command dispatcher
    qCDebug(jveTimelinePanel, "Clip moved: %s to track %s at time %lld", 
            qPrintable(clipId), qPrintable(trackId), newTime);
}

void TimelinePanel::updateViewport()
{
    update();
}

// Professional editing operations
void TimelinePanel::splitClipAtPlayhead()
{
    // TODO: Implement split operation
    qCDebug(jveTimelinePanel, "Split clip at playhead: %lld", m_playheadPosition);
}

void TimelinePanel::deleteSelectedClips()
{
    if (!m_selectedClips.isEmpty() && m_commandDispatcher) {
        // TODO: Execute delete command for selected clips
        qCDebug(jveTimelinePanel, "Deleting %d selected clips", m_selectedClips.size());
    }
}

void TimelinePanel::rippleDeleteSelectedClips()
{
    if (!m_selectedClips.isEmpty() && m_commandDispatcher) {
        // TODO: Execute ripple delete command
        qCDebug(jveTimelinePanel, "Ripple deleting %d selected clips", m_selectedClips.size());
    }
}

void TimelinePanel::copySelectedClips()
{
    // TODO: Implement copy operation
    qCDebug(jveTimelinePanel, "Copying %d selected clips", m_selectedClips.size());
}

void TimelinePanel::pasteClips()
{
    // TODO: Implement paste operation
    qCDebug(jveTimelinePanel, "Pasting clips at playhead: %lld", m_playheadPosition);
}

void TimelinePanel::zoomToFit()
{
    // TODO: Calculate zoom to fit all content
    qCDebug(jveTimelinePanel, "Zoom to fit");
}

void TimelinePanel::frameView()
{
    // TODO: Frame view to selected clips or all content
    qCDebug(jveTimelinePanel, "Frame view");
}

// Context menu creation
QMenu* TimelinePanel::createClipContextMenu(const QString& clipId)
{
    QMenu* menu = new QMenu(this);
    
    menu->addAction("Cut", [this, clipId]() {
        // TODO: Cut clip
    });
    
    menu->addAction("Copy", [this, clipId]() {
        // TODO: Copy clip
    });
    
    menu->addAction("Delete", [this, clipId]() {
        // TODO: Delete clip
    });
    
    menu->addSeparator();
    
    menu->addAction("Split", [this, clipId]() {
        splitClipAtPlayhead();
    });
    
    menu->addAction("Properties...", [this, clipId]() {
        // TODO: Show clip properties
    });
    
    return menu;
}

QMenu* TimelinePanel::createTrackContextMenu(const QString& trackId)
{
    QMenu* menu = new QMenu(this);
    
    menu->addAction("Add Track Above", [this, trackId]() {
        // TODO: Add track above
    });
    
    menu->addAction("Add Track Below", [this, trackId]() {
        // TODO: Add track below
    });
    
    menu->addSeparator();
    
    menu->addAction("Delete Track", [this, trackId]() {
        // TODO: Delete track
    });
    
    return menu;
}

QMenu* TimelinePanel::createTimelineContextMenu(qint64 time)
{
    QMenu* menu = new QMenu(this);
    
    menu->addAction("Paste", [this]() {
        pasteClips();
    });
    
    menu->addSeparator();
    
    menu->addAction("Add Video Track", [this]() {
        // TODO: Add video track
    });
    
    menu->addAction("Add Audio Track", [this]() {
        // TODO: Add audio track
    });
    
    return menu;
}

void TimelinePanel::onTrackHeaderClicked(const QString& trackId)
{
    // TODO: Track selection logic
    qCDebug(jveTimelinePanel, "Track header clicked: %s", qPrintable(trackId));
}

void TimelinePanel::onPlayheadMoved(qint64 newTime)
{
    setPlayheadPosition(newTime);
    emit playheadPositionChanged(newTime);
}

void TimelinePanel::resizeEvent(QResizeEvent* event)
{
    QWidget::resizeEvent(event);
    updateViewport();
}