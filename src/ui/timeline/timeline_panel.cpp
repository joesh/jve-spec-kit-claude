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
    setupContextMenus();
    
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
    
    // Create custom drawing widget for timeline content
    m_drawingWidget = new TimelineWidget(this);
    m_drawingWidget->setMinimumSize(2000, 400); // Initial size
    m_drawingWidget->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);
    m_scrollArea->setWidget(m_drawingWidget);
    
    // Keep reference to the generic widget for compatibility
    m_timelineWidget = m_drawingWidget;
    
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

void TimelinePanel::setupContextMenus()
{
    // Initialize context menu manager
    m_contextMenuManager = new ContextMenuManager(this);
    
    // Connect context menu signals to command bridge (will be set later)
    connect(m_contextMenuManager, &ContextMenuManager::cutRequested,
            this, [this]() { 
                if (m_commandBridge) {
                    m_commandBridge->cutSelectedClips();
                } else {
                    qCDebug(jveTimelinePanel) << "Cut requested but no command bridge set";
                }
            });
    connect(m_contextMenuManager, &ContextMenuManager::copyRequested,
            this, [this]() { 
                if (m_commandBridge) {
                    m_commandBridge->copySelectedClips();
                } else {
                    qCDebug(jveTimelinePanel) << "Copy requested but no command bridge set";
                }
            });
    connect(m_contextMenuManager, &ContextMenuManager::pasteRequested,
            this, [this]() { 
                qCDebug(jveTimelinePanel) << "Paste requested - would need target track and time";
            });
    connect(m_contextMenuManager, &ContextMenuManager::deleteRequested,
            this, [this]() { 
                if (m_commandBridge) {
                    m_commandBridge->deleteSelectedClips();
                } else {
                    qCDebug(jveTimelinePanel) << "Delete requested but no command bridge set";
                }
            });
    
    // Timeline-specific actions
    connect(m_contextMenuManager, &ContextMenuManager::splitClipRequested,
            this, [this]() { 
                if (m_commandBridge) {
                    m_commandBridge->splitClipsAtPlayhead(m_playheadPosition);
                } else {
                    qCDebug(jveTimelinePanel) << "Split clip requested at playhead position" << m_playheadPosition;
                }
            });
    connect(m_contextMenuManager, &ContextMenuManager::bladeAllTracksRequested,
            this, [this]() { 
                qCDebug(jveTimelinePanel) << "Blade all tracks requested at playhead position" << m_playheadPosition;
            });
    connect(m_contextMenuManager, &ContextMenuManager::rippleDeleteRequested,
            this, [this]() { 
                if (m_commandBridge) {
                    m_commandBridge->rippleDeleteSelectedClips();
                } else {
                    qCDebug(jveTimelinePanel) << "Ripple delete requested for selected clips";
                }
            });
    
    // Selection actions
    connect(m_contextMenuManager, &ContextMenuManager::selectAllRequested,
            this, [this]() { 
                if (m_commandBridge) {
                    m_commandBridge->selectAllClips();
                } else {
                    qCDebug(jveTimelinePanel) << "Select all requested";
                }
            });
    connect(m_contextMenuManager, &ContextMenuManager::deselectAllRequested,
            this, [this]() { 
                if (m_commandBridge) {
                    m_commandBridge->deselectAllClips();
                } else {
                    qCDebug(jveTimelinePanel) << "Deselect all requested";
                    m_selectedClips.clear();
                    update();
                }
            });
    
    // Playback actions
    connect(m_contextMenuManager, &ContextMenuManager::playPauseRequested,
            this, [this]() { qCDebug(jveTimelinePanel) << "Play/pause requested from timeline context menu"; });
    connect(m_contextMenuManager, &ContextMenuManager::markInRequested,
            this, [this]() { qCDebug(jveTimelinePanel) << "Mark in requested at" << m_playheadPosition; });
    connect(m_contextMenuManager, &ContextMenuManager::markOutRequested,
            this, [this]() { qCDebug(jveTimelinePanel) << "Mark out requested at" << m_playheadPosition; });
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

void TimelinePanel::setCommandBridge(UICommandBridge* commandBridge)
{
    m_commandBridge = commandBridge;
    
    if (m_commandBridge) {
        // Connect command bridge signals for UI updates
        connect(m_commandBridge, &UICommandBridge::clipCreated,
                this, [this](const QString& clipId, const QString& sequenceId, const QString& trackId) {
                    qCDebug(jveTimelinePanel) << "Clip created:" << clipId << "in sequence" << sequenceId << "track" << trackId;
                    
                    // Load actual clip data from database using the clipId
                    // For now, create clips with different positions for testing
                    static int clipIndex = 0;
                    Clip clip = Clip::create("Timeline Clip", clipId);
                    clip.setTrackId(trackId);
                    
                    // Position clips with different start times for visual differentiation
                    qint64 startTime = clipIndex * 6000; // 6 seconds apart
                    qint64 duration = clipIndex == 0 ? 5000 : 3000; // First clip 5s, second clip 3s
                    clip.setTimelinePosition(startTime, startTime + duration);
                    clipIndex++;
                    
                    m_clips.append(clip);
                    
                    // Trigger repaint of the actual drawing widget
                    if (m_drawingWidget) {
                        m_drawingWidget->update();
                    } else {
                        update(); // Fallback
                    }
                });
        
        connect(m_commandBridge, &UICommandBridge::clipDeleted,
                this, [this](const QString& clipId) {
                    qCDebug(jveTimelinePanel) << "Clip deleted:" << clipId;
                    m_selectedClips.removeAll(clipId);
                    update(); // Refresh timeline display
                });
        
        connect(m_commandBridge, &UICommandBridge::clipMoved,
                this, [this](const QString& clipId, const QString& trackId, qint64 newTime) {
                    qCDebug(jveTimelinePanel) << "Clip moved:" << clipId << "to track" << trackId << "at time" << newTime;
                    update(); // Refresh timeline display
                });
        
        // Note: Don't connect to UICommandBridge selectionChanged - only listen to SelectionManager
        // to avoid circular selection loops
    }
    
    qCDebug(jveTimelinePanel, "Command bridge set");
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
    qCDebug(jveTimelinePanel, "TimelinePanel::selectClip called with clipId: %s", qPrintable(clipId));
    if (m_selectionManager) {
        qCDebug(jveTimelinePanel, "Calling SelectionManager::select");
        m_selectionManager->select(clipId);
    } else {
        qCDebug(jveTimelinePanel, "SelectionManager is null!");
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
    qCDebug(jveTimelinePanel, "Context menu requested at position (%d, %d)", event->pos().x(), event->pos().y());
    
    // Update context menu manager state
    m_contextMenuManager->setSelectedClips(m_selectedClips);
    m_contextMenuManager->setPlayheadPosition(m_playheadPosition);
    
    QString clipId = getClipAtPosition(event->pos());
    QMenu* menu = nullptr;
    
    if (!clipId.isEmpty()) {
        qCDebug(jveTimelinePanel, "Right-clicked on clip: %s", qPrintable(clipId));
        m_contextMenuManager->setCurrentContext(ContextMenuManager::ClipContext);
        menu = m_contextMenuManager->createClipContextMenu(QStringList() << clipId, this);
    } else {
        QString trackId = getTrackAtPosition(event->pos());
        if (!trackId.isEmpty()) {
            qCDebug(jveTimelinePanel, "Right-clicked on track: %s", qPrintable(trackId));
            m_contextMenuManager->setCurrentContext(ContextMenuManager::TrackContext);
            m_contextMenuManager->setSelectedTracks(QStringList() << trackId);
            menu = m_contextMenuManager->createTrackContextMenu(trackId, this);
        } else {
            qCDebug(jveTimelinePanel, "Right-clicked on empty timeline space");
            m_contextMenuManager->setCurrentContext(ContextMenuManager::TimelineContext);
            menu = m_contextMenuManager->createTimelineContextMenu(event->pos(), this);
        }
    }
    
    if (menu) {
        menu->exec(event->globalPos());
    }
}

void TimelinePanel::paintEvent(QPaintEvent* event)
{
    qCDebug(jveTimelinePanel, "paintEvent called, widget size: %dx%d, clips count: %d, visible: %s, rect: %d,%d %dx%d", 
            width(), height(), m_clips.size(), 
            isVisible() ? "true" : "false",
            rect().x(), rect().y(), rect().width(), rect().height());
            
    QPainter painter(this);
    painter.setRenderHint(QPainter::Antialiasing, true);
    
    // Draw a bright test background to verify the canvas is working
    painter.fillRect(rect(), Qt::red);
    
    // Draw timeline components
    drawTimeline(painter);
    drawTracks(painter);
    drawClips(painter);
    drawPlayhead(painter);
    drawSelection(painter);
    drawRuler(painter);
    drawTrackHeaders(painter);
    
    // DON'T call QWidget::paintEvent(event) as it might override our custom drawing
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
    qCDebug(jveTimelinePanel, "drawClips called with %d clips", m_clips.size());
    
    if (m_clips.isEmpty()) {
        qCDebug(jveTimelinePanel, "No clips to draw");
        return;
    }
    
    // Set up clip drawing style
    painter.setRenderHint(QPainter::Antialiasing, true);
    
    for (const Clip& clip : m_clips) {
        // Extract clip parameters
        QString trackId = clip.trackId();
        qint64 startTime = clip.timelineStart();
        qint64 duration = clip.duration();
        
        qCDebug(jveTimelinePanel, "Drawing clip %s: track=%s, start=%lld, duration=%lld", 
                qPrintable(clip.id()), qPrintable(trackId), startTime, duration);
        
        // Calculate clip position and dimensions
        int x = timeToPixel(startTime);
        int y = getTrackYPosition(trackId);
        int width = timeToPixel(duration) - timeToPixel(0);
        int height = m_trackHeight - CLIP_MARGIN * 2;
        
        qCDebug(jveTimelinePanel, "Clip rect: x=%d, y=%d, width=%d, height=%d", x, y, width, height);
        
        // Skip if clip is off-screen
        if (x + width < 0 || x > this->width()) {
            continue;
        }
        
        // Determine clip color based on selection state
        QColor clipColor = m_selectedClips.contains(clip.id()) ? 
                          m_selectedClipColor : m_clipColor;
        
        // Draw clip rectangle
        QRect clipRect(x, y + CLIP_MARGIN, width, height);
        painter.fillRect(clipRect, clipColor);
        
        // Draw clip border
        painter.setPen(QPen(clipColor.darker(150), 1));
        painter.drawRect(clipRect);
        
        // Draw clip name (if space allows)
        if (width > 60) {
            painter.setPen(Qt::white);
            painter.setFont(m_clipFont);
            QRect textRect = clipRect.adjusted(4, 0, -4, 0);
            painter.drawText(textRect, Qt::AlignLeft | Qt::AlignVCenter, 
                           clip.name().isEmpty() ? clip.id().left(8) : clip.name());
        }
    }
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

int TimelinePanel::getTrackYPosition(const QString& trackId) const
{
    // For now, use a simple track index calculation
    // In a full implementation, this would query the track order from the sequence
    int trackIndex = 0; // Assume first track for demo
    return m_rulerHeight + (trackIndex * m_trackHeight);
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

// TimelineWidget implementation - handles actual drawing inside scroll area
TimelineWidget::TimelineWidget(TimelinePanel* parent)
    : QWidget(parent), m_timelinePanel(parent)
{
    setMinimumSize(2000, 400);
    
    // Enable custom painting
    setAttribute(Qt::WA_OpaquePaintEvent, false);
    setAutoFillBackground(false);
}

void TimelineWidget::paintEvent(QPaintEvent* event)
{
    if (!m_timelinePanel) {
        return;
    }
    
    qCDebug(jveTimelinePanel, "TimelineWidget paintEvent called, widget size: %dx%d", 
            width(), height());
    
    QPainter painter(this);
    painter.setRenderHint(QPainter::Antialiasing, true);
    
    // Draw dark background
    painter.fillRect(rect(), QColor(45, 45, 45));
    
    // Draw background chrome first (ruler and track headers)
    drawRuler(painter);
    drawTrackHeaders(painter);
    
    // Draw clips in the middle layer
    const auto& clips = m_timelinePanel->getClips();
    if (clips.size() > 0) {
        qCDebug(jveTimelinePanel, "Drawing %d clips on TimelineWidget", clips.size());
        
        // Draw clips directly here since we can't call private methods
        for (const auto& clip : clips) {
            QString trackId = clip.trackId();
            qint64 startTime = clip.timelineStart();
            qint64 duration = clip.duration();
            
            // Calculate clip position accounting for chrome
            int trackHeaderWidth = 200;
            int rulerHeight = 32;
            int x = trackHeaderWidth + static_cast<int>(startTime * 0.05); // Account for track header
            int y = rulerHeight + 2; // Account for ruler + small margin
            int width = static_cast<int>(duration * 0.05);
            int height = 44;
            
            QRect clipRect(x, y, width, height);
            
            // Check if this clip is selected (use direct tracking for immediate feedback)
            bool isSelected = m_selectedClipIds.contains(clip.id());
            
            // Use different color for selected clips
            QColor clipColor = isSelected ? QColor(255, 165, 0) : QColor(100, 150, 200); // Orange for selected, blue for normal
            painter.fillRect(clipRect, clipColor);
            
            // Draw border for selected clips
            if (isSelected) {
                painter.setPen(QPen(QColor(255, 200, 50), 2));
                painter.drawRect(clipRect);
            }
            
            qCDebug(jveTimelinePanel, "Drew clip at x=%d, y=%d, width=%d, height=%d", 
                    x, y, width, height);
        }
    }
    
    // Draw drag selection rectangle
    if (m_isDragSelecting) {
        painter.setPen(QPen(QColor(255, 255, 255, 128), 1, Qt::DashLine));
        painter.setBrush(QBrush(QColor(255, 255, 255, 32)));
        painter.drawRect(m_dragSelectionRect);
    }
    
    // Draw playhead on top of everything
    drawPlayhead(painter);
}

void TimelineWidget::mousePressEvent(QMouseEvent* event)
{
    if (!m_timelinePanel) {
        return;
    }
    
    QPoint clickPos = event->pos();
    qCDebug(jveTimelinePanel, "Timeline click at %d, %d", clickPos.x(), clickPos.y());
    
    int trackHeaderWidth = 200;
    int rulerHeight = 32;
    
    // Check if clicked in ruler area for playhead scrubbing
    if (clickPos.y() <= rulerHeight && clickPos.x() >= trackHeaderWidth) {
        // Convert click position to time and set playhead
        double zoomFactor = 0.05;
        qint64 newTime = static_cast<qint64>((clickPos.x() - trackHeaderWidth) / zoomFactor);
        m_timelinePanel->setPlayheadPosition(newTime);
        update();
        return;
    }
    
    // Check for modifier keys
    bool cmdPressed = (event->modifiers() & Qt::ControlModifier) || (event->modifiers() & Qt::MetaModifier);
    bool shiftPressed = event->modifiers() & Qt::ShiftModifier;
    
    // Find which clip was clicked
    const auto& clips = m_timelinePanel->getClips();
    QString clickedClipId;
    
    for (const auto& clip : clips) {
        qint64 startTime = clip.timelineStart();
        qint64 duration = clip.duration();
        
        // Calculate clip rectangle (same logic as in paintEvent)
        int trackHeaderWidth = 200;
        int rulerHeight = 32;
        int x = trackHeaderWidth + static_cast<int>(startTime * 0.05);
        int y = rulerHeight + 2;
        int width = static_cast<int>(duration * 0.05);
        int height = 44;
        
        QRect clipRect(x, y, width, height);
        
        if (clipRect.contains(clickPos)) {
            clickedClipId = clip.id();
            qCDebug(jveTimelinePanel, "Clicked on clip: %s", qPrintable(clickedClipId));
            break;
        }
    }
    
    if (!clickedClipId.isEmpty()) {
        // Handle clip selection with modifiers
        if (cmdPressed) {
            // Cmd+click: Add/remove from selection
            if (m_selectedClipIds.contains(clickedClipId)) {
                m_selectedClipIds.removeAll(clickedClipId);
                qCDebug(jveTimelinePanel, "Removed clip from selection: %s", qPrintable(clickedClipId));
            } else {
                m_selectedClipIds.append(clickedClipId);
                qCDebug(jveTimelinePanel, "Added clip to selection: %s", qPrintable(clickedClipId));
            }
        } else {
            // Normal click: Replace selection
            m_selectedClipIds.clear();
            m_selectedClipIds.append(clickedClipId);
            qCDebug(jveTimelinePanel, "Selected clip (replacing): %s", qPrintable(clickedClipId));
        }
        
        update(); // Refresh to show selection
        
        // Update the selection manager
        if (m_timelinePanel) {
            m_timelinePanel->selectClips(m_selectedClipIds);
        }
    } else {
        // Clicked on empty area
        if (!cmdPressed) {
            // Normal click on empty area: Start drag selection
            m_isDragSelecting = true;
            m_dragStartPos = clickPos;
            m_dragSelectionRect = QRect(clickPos, QSize(0, 0));
            
            // Clear selection unless Cmd is held
            m_selectedClipIds.clear();
            qCDebug(jveTimelinePanel, "Starting drag selection at %d, %d", clickPos.x(), clickPos.y());
        }
        
        update();
        
        // Update the selection manager
        if (m_timelinePanel) {
            m_timelinePanel->selectClips(m_selectedClipIds);
        }
    }
    
    QWidget::mousePressEvent(event);
}

void TimelineWidget::mouseMoveEvent(QMouseEvent* event)
{
    if (m_isDragSelecting) {
        // Update drag selection rectangle
        QPoint currentPos = event->pos();
        m_dragSelectionRect = QRect(
            qMin(m_dragStartPos.x(), currentPos.x()),
            qMin(m_dragStartPos.y(), currentPos.y()),
            qAbs(currentPos.x() - m_dragStartPos.x()),
            qAbs(currentPos.y() - m_dragStartPos.y())
        );
        
        // Find clips that intersect with the drag rectangle
        if (m_timelinePanel) {
            const auto& clips = m_timelinePanel->getClips();
            QStringList dragSelectedClips;
            
            for (const auto& clip : clips) {
                qint64 startTime = clip.timelineStart();
                qint64 duration = clip.duration();
                
                // Calculate clip rectangle
                int trackHeaderWidth = 200;
                int rulerHeight = 32;
                int x = trackHeaderWidth + static_cast<int>(startTime * 0.05);
                int y = rulerHeight + 2;
                int width = static_cast<int>(duration * 0.05);
                int height = 44;
                
                QRect clipRect(x, y, width, height);
                
                if (m_dragSelectionRect.intersects(clipRect)) {
                    dragSelectedClips.append(clip.id());
                }
            }
            
            // Update selection with drag-selected clips
            m_selectedClipIds = dragSelectedClips;
        }
        
        update(); // Refresh to show selection rectangle and selected clips
    }
    
    QWidget::mouseMoveEvent(event);
}

void TimelineWidget::mouseReleaseEvent(QMouseEvent* event)
{
    if (m_isDragSelecting) {
        // Finish drag selection
        m_isDragSelecting = false;
        qCDebug(jveTimelinePanel, "Finished drag selection, selected %d clips", m_selectedClipIds.size());
        
        // Update the selection manager with final selection
        if (m_timelinePanel) {
            m_timelinePanel->selectClips(m_selectedClipIds);
        }
        
        update(); // Clear the drag rectangle
    }
    
    QWidget::mouseReleaseEvent(event);
}

// Timeline chrome drawing methods

void TimelineWidget::drawRuler(QPainter& painter)
{
    if (!m_timelinePanel) return;
    
    // Ruler area - top 32 pixels
    int rulerHeight = 32;
    int trackHeaderWidth = 200;
    
    // Draw ruler background
    QRect rulerRect(trackHeaderWidth, 0, width() - trackHeaderWidth, rulerHeight);
    painter.fillRect(rulerRect, QColor(80, 80, 80));
    
    // Draw time markers
    painter.setPen(QColor(200, 200, 200));
    painter.setFont(QFont("Arial", 9));
    
    double zoomFactor = 0.05; // Same as clip drawing
    int timelineStart = -trackHeaderWidth / zoomFactor; // Account for scroll offset
    int timelineEnd = (width() - trackHeaderWidth) / zoomFactor;
    
    // Draw major time markers every 5 seconds (5000ms)
    for (qint64 time = 0; time <= timelineEnd; time += 5000) {
        int x = trackHeaderWidth + static_cast<int>(time * zoomFactor);
        if (x >= trackHeaderWidth && x <= width()) {
            // Draw tick mark
            painter.drawLine(x, rulerHeight - 8, x, rulerHeight);
            
            // Draw time label
            int seconds = time / 1000;
            int minutes = seconds / 60;
            int remainingSeconds = seconds % 60;
            QString timeText = QString("%1:%2").arg(minutes).arg(remainingSeconds, 2, 10, QChar('0'));
            
            QRect textRect(x - 20, 0, 40, rulerHeight - 8);
            painter.drawText(textRect, Qt::AlignCenter, timeText);
        }
    }
    
    // Draw minor time markers every 1 second (1000ms)
    painter.setPen(QColor(150, 150, 150));
    for (qint64 time = 0; time <= timelineEnd; time += 1000) {
        if (time % 5000 != 0) { // Skip major markers
            int x = trackHeaderWidth + static_cast<int>(time * zoomFactor);
            if (x >= trackHeaderWidth && x <= width()) {
                painter.drawLine(x, rulerHeight - 4, x, rulerHeight);
            }
        }
    }
}

void TimelineWidget::drawTrackHeaders(QPainter& painter)
{
    if (!m_timelinePanel) return;
    
    int trackHeaderWidth = 200;
    int rulerHeight = 32;
    int trackHeight = 48;
    
    // Draw track header background
    QRect headerRect(0, 0, trackHeaderWidth, height());
    painter.fillRect(headerRect, QColor(60, 60, 60));
    
    // Draw ruler corner
    QRect rulerCorner(0, 0, trackHeaderWidth, rulerHeight);
    painter.fillRect(rulerCorner, QColor(70, 70, 70));
    
    // Draw track header for video track
    int trackY = rulerHeight;
    QRect trackHeaderRect(0, trackY, trackHeaderWidth, trackHeight);
    
    // Track header background
    painter.fillRect(trackHeaderRect, QColor(55, 55, 55));
    
    // Track header border
    painter.setPen(QColor(40, 40, 40));
    painter.drawRect(trackHeaderRect);
    
    // Track label
    painter.setPen(QColor(220, 220, 220));
    painter.setFont(QFont("Arial", 10, QFont::Bold));
    painter.drawText(trackHeaderRect.adjusted(8, 0, -8, 0), Qt::AlignLeft | Qt::AlignVCenter, "V1");
    
    // Track controls (simplified)
    int buttonSize = 16;
    int buttonY = trackY + (trackHeight - buttonSize) / 2;
    
    // Visibility toggle (eye icon placeholder)
    QRect visibilityButton(trackHeaderWidth - 80, buttonY, buttonSize, buttonSize);
    painter.fillRect(visibilityButton, QColor(100, 150, 200));
    painter.setPen(QColor(255, 255, 255));
    painter.setFont(QFont("Arial", 8));
    painter.drawText(visibilityButton, Qt::AlignCenter, "👁");
    
    // Lock toggle (lock icon placeholder)
    QRect lockButton(trackHeaderWidth - 60, buttonY, buttonSize, buttonSize);
    painter.fillRect(lockButton, QColor(120, 120, 120));
    painter.drawText(lockButton, Qt::AlignCenter, "🔒");
    
    // Mute toggle (speaker icon placeholder)
    QRect muteButton(trackHeaderWidth - 40, buttonY, buttonSize, buttonSize);
    painter.fillRect(muteButton, QColor(200, 100, 100));
    painter.drawText(muteButton, Qt::AlignCenter, "🔊");
}

void TimelineWidget::drawPlayhead(QPainter& painter)
{
    if (!m_timelinePanel) return;
    
    int trackHeaderWidth = 200;
    qint64 playheadPosition = m_timelinePanel->getPlayheadPosition();
    double zoomFactor = 0.05;
    
    // Calculate playhead X position
    int playheadX = trackHeaderWidth + static_cast<int>(playheadPosition * zoomFactor);
    
    // Only draw if playhead is visible
    if (playheadX >= trackHeaderWidth && playheadX <= width()) {
        // Draw playhead line
        painter.setPen(QPen(QColor(255, 0, 0), 2)); // Red playhead
        painter.drawLine(playheadX, 0, playheadX, height());
        
        // Draw playhead top indicator (triangle)
        QPolygon playheadTop;
        playheadTop << QPoint(playheadX - 6, 0)
                   << QPoint(playheadX + 6, 0)
                   << QPoint(playheadX, 12);
        
        painter.setPen(Qt::NoPen);
        painter.setBrush(QColor(255, 0, 0));
        painter.drawPolygon(playheadTop);
    }
}

#include "timeline_panel.moc"