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
    // Create horizontal layout to separate track headers from timeline content
    m_horizontalLayout = new QHBoxLayout();
    m_horizontalLayout->setContentsMargins(0, 0, 0, 0);
    m_horizontalLayout->setSpacing(0);
    
    // Create fixed track header area (non-scrollable horizontally)
    m_trackHeaderWidget = new TrackHeaderWidget(this);
    m_trackHeaderWidget->setFixedWidth(200); // m_trackHeaderWidth
    
    // Create scroll area for VERTICAL scrolling only (when too many tracks)
    m_scrollArea = new QScrollArea();
    m_scrollArea->setWidgetResizable(true);
    m_scrollArea->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff); // NO horizontal scrolling
    m_scrollArea->setVerticalScrollBarPolicy(Qt::ScrollBarAsNeeded);     // YES vertical scrolling
    
    // Create timeline content widget (handles its own viewport/time scrolling)
    m_drawingWidget = new ScriptableTimelineWidget(this);
    m_drawingWidget->setMinimumHeight(400); // Height grows with tracks
    m_drawingWidget->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);
    m_scrollArea->setWidget(m_drawingWidget);
    
    // Add track header area and scroll area to horizontal layout
    m_horizontalLayout->addWidget(m_trackHeaderWidget);
    m_horizontalLayout->addWidget(m_scrollArea, 1); // Give scroll area stretch factor
    
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
    
    // Add custom horizontal scrollbar for timeline viewport control
    m_timelineScrollBar = new QScrollBar(Qt::Horizontal);
    m_timelineScrollBar->setRange(0, 1000000); // Large range for timeline navigation
    m_timelineScrollBar->setValue(0);
    
    // Add the horizontal layout (track headers + scroll area) to main layout
    m_mainLayout->addLayout(m_horizontalLayout);
    m_mainLayout->addWidget(m_timelineScrollBar); // Timeline viewport scrollbar at bottom
    
    setLayout(m_mainLayout);
    
    // Connect timeline scrollbar to viewport updates
    connect(m_timelineScrollBar, &QScrollBar::valueChanged, this, &TimelinePanel::onTimelineScrollChanged);
    
    // Ensure this widget can receive keyboard focus for zoom shortcuts
    setFocusPolicy(Qt::StrongFocus);
    if (m_drawingWidget) {
        m_drawingWidget->setFocusPolicy(Qt::StrongFocus);
    }
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
                        m_drawingWidget->refreshTimeline();
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
        
        // Refresh timeline using command system
        if (m_drawingWidget) {
            m_drawingWidget->refreshTimeline();
        } else {
            update(); // Fallback
        }
        
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
    qCDebug(jveTimelinePanel, "setZoomLevel called: requested=%f, clamped=%f, current=%f", zoomFactor, clampedZoom, m_zoomFactor);
    if (m_zoomFactor != clampedZoom) {
        double oldZoom = m_zoomFactor;
        m_zoomFactor = clampedZoom;
        updateClipPositions();
        updateScrollBars();
        update();
        qCDebug(jveTimelinePanel, "Zoom level changed: %f -> %f", oldZoom, m_zoomFactor);
        
        // Force complete redraw of all timeline elements
        if (m_drawingWidget) {
            m_drawingWidget->refreshTimeline();
        }
        if (m_timelineWidget) {
            m_timelineWidget->update();
        }
        if (m_scrollArea) {
            m_scrollArea->update();
        }
        
        // Force immediate repaint
        repaint();
        if (m_drawingWidget) {
            m_drawingWidget->repaint();
        }
    } else {
        qCDebug(jveTimelinePanel, "Zoom level unchanged: %f", m_zoomFactor);
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
    qCDebug(jveTimelinePanel, "TimelinePanel keyPressEvent: key=%d, text='%s'", event->key(), event->text().toUtf8().constData());
    
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
    
    // Check if the click was on the TimelineWidget (which handles its own events)
    // If so, don't interfere with the selection
    if (m_drawingWidget && m_drawingWidget->geometry().contains(event->pos())) {
        // Let TimelineWidget handle this - don't interfere
        QWidget::mousePressEvent(event);
        return;
    }
    
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
            
            // Note: Playhead positioning is now handled by TimelineWidget for ruler clicks
            // Only handle selection rectangle here
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
    
    // Just draw the container background - TimelineWidget handles timeline content
    painter.fillRect(rect(), m_backgroundColor);
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
    // Forward to TimelineWidget which has the actual working hit detection
    // This method is called by the old TimelinePanel mouse handlers that shouldn't be used
    // when TimelineWidget is handling mouse events properly
    
    // For now, iterate through clips and check collision
    // (TimelineWidget already has this logic working)
    for (const auto& clip : m_clips) {
        qint64 startTime = clip.timelineStart();
        qint64 duration = clip.duration();
        
        // Calculate clip rectangle using same logic as TimelineWidget 
        int rulerHeight = 32;
        qint64 viewportStartTime = m_viewportStartTime;
        qint64 relativeStartTime = startTime - viewportStartTime;
        int x = static_cast<int>(relativeStartTime * m_zoomFactor);
        int y = rulerHeight + 2;
        int width = static_cast<int>(duration * m_zoomFactor);
        int height = 44;
        
        QRect clipRect(x, y, width, height);
        
        if (clipRect.contains(pos)) {
            return clip.id();
        }
    }
    
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

void TimelinePanel::onTimelineScrollChanged(int value)
{
    // Convert scrollbar value to timeline position
    // For now, simple linear mapping - could be improved with proper time ranges
    double scrollPercent = value / 1000000.0; // Normalize to 0-1
    qint64 maxTime = 3600000; // 1 hour max timeline for now
    
    m_viewportStartTime = static_cast<qint64>(scrollPercent * maxTime);
    // Calculate viewport end time based on zoom level and widget width
    int timelineWidth = m_drawingWidget ? m_drawingWidget->width() : 1500;
    qint64 viewportDuration = static_cast<qint64>(timelineWidth / m_zoomFactor);
    m_viewportEndTime = m_viewportStartTime + viewportDuration;
    
    qCDebug(jveTimelinePanel, "Timeline viewport: %lld - %lld ms", m_viewportStartTime, m_viewportEndTime);
    
    // Update display
    updateViewport();
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

// ScriptableTimelineWidget implementation - handles drawing via commands
ScriptableTimelineWidget::ScriptableTimelineWidget(TimelinePanel* parent)
    : JVE::ScriptableTimeline("timeline_widget", parent), m_timelinePanel(parent)
{
    setMinimumSize(2000, 400);
    
    // Generate initial timeline rendering
    refreshTimeline();
}

void ScriptableTimelineWidget::refreshTimeline()
{
    if (!m_timelinePanel) {
        return;
    }
    
    qCDebug(jveTimelinePanel, "ScriptableTimelineWidget refreshTimeline called");
    
    // Clear previous commands and regenerate
    clearCommands();
    generateTimelineCommands();
    
    // Trigger repaint using ScriptableTimeline's update()
    update();
}

void ScriptableTimelineWidget::generateTimelineCommands()
{
    // Generate all timeline drawing commands
    generateRulerCommands();
    generateClipCommands();
    generatePlayheadCommands();
}

void ScriptableTimelineWidget::generateRulerCommands()
{
    int rulerHeight = 32;
    
    // Draw ruler background
    addRect(0, 0, width(), rulerHeight, "#505050");
    
    // Draw time markers every 5 seconds with zoom
    qint64 viewportStartTime = m_timelinePanel->getViewportStartTime();
    qint64 viewportEndTime = m_timelinePanel->getViewportEndTime();
    double zoomLevel = m_timelinePanel->getZoomLevel();
    
    // Calculate marker interval based on zoom level
    qint64 markerInterval = 5000; // 5 seconds
    if (zoomLevel < 0.01) markerInterval = 30000;  // 30 seconds for very zoomed out
    else if (zoomLevel < 0.05) markerInterval = 10000; // 10 seconds for zoomed out
    
    qint64 firstMarker = (viewportStartTime / markerInterval) * markerInterval;
    
    for (qint64 time = firstMarker; time <= viewportEndTime + markerInterval; time += markerInterval) {
        if (time < viewportStartTime) continue;
        
        qint64 relativeTime = time - viewportStartTime;
        int x = static_cast<int>(relativeTime * zoomLevel);
        
        // Draw marker line
        addLine(x, 20, x, rulerHeight, "#cccccc", 1);
        
        // Draw time text
        int seconds = time / 1000;
        int minutes = seconds / 60;
        seconds %= 60;
        QString timeStr = QString("%1:%2").arg(minutes).arg(seconds, 2, 10, QChar('0'));
        addText(x + 2, 15, timeStr, "#cccccc");
    }
}

void ScriptableTimelineWidget::generateClipCommands()
{
    const auto& clips = m_timelinePanel->getClips();
    if (clips.isEmpty()) return;
    
    qCDebug(jveTimelinePanel, "Drawing %d clips via commands", clips.size());
    
    int rulerHeight = 32;
    qint64 viewportStartTime = m_timelinePanel->getViewportStartTime();
    double zoomLevel = m_timelinePanel->getZoomLevel();
    
    for (const auto& clip : clips) {
        qint64 startTime = clip.timelineStart();
        qint64 duration = clip.duration();
        
        // Calculate clip position relative to viewport
        qint64 relativeStartTime = startTime - viewportStartTime;
        int x = static_cast<int>(relativeStartTime * zoomLevel);
        int y = rulerHeight + 2;
        int width = static_cast<int>(duration * zoomLevel);
        int height = 44;
        
        // Check if clip is selected
        bool isSelected = m_selectedClipIds.contains(clip.id());
        QString clipColor = isSelected ? "#ffa500" : "#6496c8"; // Orange for selected, blue for normal
        
        // Draw clip rectangle
        addRect(x, y, width, height, clipColor);
        
        // Draw clip name if there's space
        if (width > 50) {
            addText(x + 4, y + 20, clip.name(), "#ffffff");
        }
        
        qCDebug(jveTimelinePanel, "Generated clip command at x=%d, y=%d, width=%d, height=%d", 
                x, y, width, height);
    }
}

void ScriptableTimelineWidget::generatePlayheadCommands()
{
    qint64 playheadTime = m_timelinePanel->getPlayheadPosition();
    qint64 viewportStartTime = m_timelinePanel->getViewportStartTime();
    qint64 relativeTime = playheadTime - viewportStartTime;
    
    double zoomLevel = m_timelinePanel->getZoomLevel();
    int x = static_cast<int>(relativeTime * zoomLevel);
    
    // Draw playhead line
    addLine(x, 0, x, height(), "#ff6b6b", 2);
    
    // Draw playhead triangle at top
    addRect(x - 5, 0, 10, 10, "#ff6b6b");
}

void ScriptableTimelineWidget::mousePressEvent(QMouseEvent* event)
{
    if (!m_timelinePanel) {
        return;
    }
    
    QPoint clickPos = event->pos();
    qCDebug(jveTimelinePanel, "Timeline click at %d, %d", clickPos.x(), clickPos.y());
    
    // Ensure timeline has focus for keyboard shortcuts
    if (m_timelinePanel) {
        m_timelinePanel->setFocus();
        qCDebug(jveTimelinePanel, "Timeline focus set");
    }
    
    int rulerHeight = 32;
    
    // Debug the ruler area check
    qCDebug(jveTimelinePanel, "Ruler check: y=%d <= %d (rulerHeight)? %s", 
            clickPos.y(), rulerHeight, clickPos.y() <= rulerHeight ? "YES" : "NO");
    
    // Check if clicked in ruler area for playhead scrubbing
    if (clickPos.y() <= rulerHeight && clickPos.x() >= 0) {
        // Convert click position to time and set playhead (no track header offset)
        qint64 newTime = static_cast<qint64>(clickPos.x() / m_timelinePanel->getZoomLevel());
        qCDebug(jveTimelinePanel, "Playhead scrub: click at %d,%d -> time %lld", clickPos.x(), clickPos.y(), newTime);
        m_timelinePanel->setPlayheadPosition(newTime);
        
        // Start playhead dragging
        m_isDraggingPlayhead = true;
        m_dragStartPos = clickPos;
        
        // Note: refreshTimeline() already called by setPlayheadPosition()
        qCDebug(jveTimelinePanel, "After setPlayheadPosition, current position: %lld", m_timelinePanel->getPlayheadPosition());
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
        
        // Calculate clip rectangle (viewport-aware, no track header offset)
        int rulerHeight = 32;
        qint64 viewportStartTime = m_timelinePanel->getViewportStartTime();
        qint64 relativeStartTime = startTime - viewportStartTime;
        int x = static_cast<int>(relativeStartTime * m_timelinePanel->getZoomLevel());
        int y = rulerHeight + 2;
        int width = static_cast<int>(duration * m_timelinePanel->getZoomLevel());
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

void ScriptableTimelineWidget::mouseMoveEvent(QMouseEvent* event)
{
    if (m_isDraggingPlayhead) {
        // Update playhead position during drag
        QPoint currentPos = event->pos();
        
        // Update playhead position during drag (no track header offset)
        qint64 newTime = static_cast<qint64>(currentPos.x() / m_timelinePanel->getZoomLevel());
        m_timelinePanel->setPlayheadPosition(newTime);
        // Note: refreshTimeline() already called by setPlayheadPosition()
        qCDebug(jveTimelinePanel, "Playhead drag: position %lld", newTime);
        return;
    }
    
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
                
                // Calculate clip rectangle (viewport-aware, no track header offset)
                int rulerHeight = 32;
                qint64 viewportStartTime = m_timelinePanel->getViewportStartTime();
                qint64 relativeStartTime = startTime - viewportStartTime;
                int x = static_cast<int>(relativeStartTime * m_timelinePanel->getZoomLevel());
                int y = rulerHeight + 2;
                int width = static_cast<int>(duration * m_timelinePanel->getZoomLevel());
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

void ScriptableTimelineWidget::mouseReleaseEvent(QMouseEvent* event)
{
    if (m_isDraggingPlayhead) {
        // End playhead dragging
        m_isDraggingPlayhead = false;
        qCDebug(jveTimelinePanel, "Finished playhead dragging");
        return;
    }
    
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

// Old drawing methods removed - now using ScriptableTimeline command system

// TrackHeaderWidget implementation
TrackHeaderWidget::TrackHeaderWidget(TimelinePanel* parent)
    : QWidget(parent), m_timelinePanel(parent)
{
    setStyleSheet("TrackHeaderWidget { background-color: rgb(60, 60, 60); }");
}

void TrackHeaderWidget::paintEvent(QPaintEvent* event)
{
    QPainter painter(this);
    painter.setRenderHint(QPainter::Antialiasing);
    
    // Draw background
    painter.fillRect(rect(), QColor(60, 60, 60));
    
    // Draw ruler area at top
    int rulerHeight = 32;
    QRect rulerRect(0, 0, width(), rulerHeight);
    painter.fillRect(rulerRect, QColor(80, 80, 80));
    
    // Draw ruler label
    painter.setPen(Qt::white);
    painter.setFont(QFont("Arial", 10));
    painter.drawText(rulerRect, Qt::AlignCenter, "Time");
    
    // Draw track header for V1 (video track 1)
    int trackHeight = 48;
    int y = rulerHeight + 2;
    QRect trackRect(0, y, width(), trackHeight);
    painter.fillRect(trackRect, QColor(70, 70, 70));
    
    // Draw track border
    painter.setPen(QColor(40, 40, 40));
    painter.drawRect(trackRect);
    
    // Draw track label
    painter.setPen(Qt::white);
    painter.setFont(QFont("Arial", 9, QFont::Bold));
    painter.drawText(trackRect, Qt::AlignCenter, "V1");
    
    QWidget::paintEvent(event);
}

void TrackHeaderWidget::mousePressEvent(QMouseEvent* event)
{
    qCDebug(jveTimelinePanel, "Track header clicked at %d, %d", event->pos().x(), event->pos().y());
    QWidget::mousePressEvent(event);
}

#include "timeline_panel.moc"