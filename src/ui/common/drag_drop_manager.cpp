#include "drag_drop_manager.h"
#include <QDebug>
#include <QTimer>
#include <QMimeData>
#include <QDrag>
#include <QPixmap>
#include <QPainter>
#include <QApplication>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonArray>
#include <QUrl>

Q_LOGGING_CATEGORY(jveDragDrop, "jve.ui.dragdrop")

DragDropManager::DragDropManager(QObject* parent)
    : QObject(parent)
{
    qCDebug(jveDragDrop) << "Initializing DragDropManager";
    
    setupMimeTypes();
    setupDragCursors();
    setupDropZones();
}

void DragDropManager::setupMimeTypes()
{
    // Professional video formats
    m_mediaMimeTypes << "video/mp4" << "video/quicktime" << "video/x-msvideo"
                     << "video/x-ms-wmv" << "video/webm" << "video/ogg";
    
    // Audio formats
    m_mediaMimeTypes << "audio/mpeg" << "audio/wav" << "audio/x-aiff"
                     << "audio/ogg" << "audio/flac" << "audio/x-m4a";
    
    // Image formats
    m_mediaMimeTypes << "image/jpeg" << "image/png" << "image/tiff"
                     << "image/bmp" << "image/gif" << "image/webp";
    
    // Professional formats
    m_mediaMimeTypes << "application/mxf" << "video/x-prores"
                     << "video/x-dnxhd" << "video/x-avid";
    
    // File extensions for validation
    m_supportedExtensions << ".mp4" << ".mov" << ".avi" << ".wmv" << ".webm"
                         << ".mp3" << ".wav" << ".aiff" << ".ogg" << ".flac" << ".m4a"
                         << ".jpg" << ".jpeg" << ".png" << ".tiff" << ".bmp" << ".gif"
                         << ".mxf" << ".prores" << ".dnxhd";
}

void DragDropManager::setupDragCursors()
{
    // Create custom cursors for different operations
    m_insertCursor = createCustomCursor("insert", "Insert");
    m_overwriteCursor = createCustomCursor("overwrite", "Overwrite");  
    m_replaceCursor = createCustomCursor("replace", "Replace");
    m_invalidCursor = createCustomCursor("invalid", "Invalid");
}

void DragDropManager::setupDropZones()
{
    qCDebug(jveDragDrop) << "Setting up drop zones for professional video editing";
}

void DragDropManager::startDrag(DragType type, const QStringList& itemIds, 
                               const QJsonObject& metadata, QWidget* sourceWidget)
{
    qCDebug(jveDragDrop) << "Starting drag operation" << type << "with items:" << itemIds;
    
    m_currentDragData.type = type;
    m_currentDragData.itemIds = itemIds;
    m_currentDragData.metadata = metadata;
    m_currentDragData.sourceWidget = sourceWidget;
    m_currentDragData.startPosition = QCursor::pos();
    
    m_isDragging = true;
    
    QDrag* drag = createDrag(m_currentDragData);
    if (drag) {
        updateDragCursor(type, m_dropMode, true);
        
        emit dragStarted(type, itemIds);
        
        Qt::DropAction dropAction = drag->exec(Qt::CopyAction | Qt::MoveAction, Qt::MoveAction);
        
        emit dragFinished(dropAction != Qt::IgnoreAction);
        m_isDragging = false;
    }
}

void DragDropManager::startMediaAssetDrag(const QStringList& assetIds, QWidget* sourceWidget)
{
    QJsonObject metadata;
    metadata["source"] = "media_browser";
    metadata["asset_count"] = assetIds.size();
    
    startDrag(MediaAssetDrag, assetIds, metadata, sourceWidget);
}

void DragDropManager::startTimelineClipDrag(const QStringList& clipIds, QWidget* sourceWidget)
{
    QJsonObject metadata;
    metadata["source"] = "timeline";
    metadata["clip_count"] = clipIds.size();
    
    startDrag(TimelineClipDrag, clipIds, metadata, sourceWidget);
}

void DragDropManager::startBinFolderDrag(const QStringList& binIds, QWidget* sourceWidget)
{
    QJsonObject metadata;
    metadata["source"] = "project_panel";
    metadata["bin_count"] = binIds.size();
    
    startDrag(BinFolderDrag, binIds, metadata, sourceWidget);
}

bool DragDropManager::handleDragEnter(QDragEnterEvent* event, QWidget* targetWidget)
{
    qCDebug(jveDragDrop) << "Drag enter on widget:" << targetWidget->objectName();
    
    // Check for external files
    if (event->mimeData()->hasUrls()) {
        QList<QUrl> urls = event->mimeData()->urls();
        if (acceptExternalFiles(urls)) {
            event->acceptProposedAction();
            return true;
        }
    }
    
    // Check for internal drag operations
    if (event->mimeData()->hasFormat("application/x-jve-drag")) {
        DropZone zone = identifyDropZone(targetWidget, event->pos());
        if (zone != InvalidZone) {
            event->acceptProposedAction();
            showDropIndicator(targetWidget, event->pos(), true);
            return true;
        }
    }
    
    event->ignore();
    return false;
}

bool DragDropManager::handleDragMove(QDragMoveEvent* event, QWidget* targetWidget)
{
    DropZone zone = identifyDropZone(targetWidget, event->pos());
    bool isValid = (zone != InvalidZone);
    
    if (isValid) {
        // Update drop info
        m_currentDropInfo.zone = zone;
        m_currentDropInfo.position = event->pos();
        m_currentDropInfo.isValidDrop = true;
        
        // Professional snapping for timeline
        if (zone == TimelineZone && m_snapToPlayhead) {
            // Snap logic would go here
            qint64 snappedTime = snapToNearestPosition(m_playheadPosition, "");
            m_currentDropInfo.timePosition = snappedTime;
        }
        
        showDropIndicator(targetWidget, event->pos(), true);
        event->acceptProposedAction();
    } else {
        showDropIndicator(targetWidget, event->pos(), false);
        event->ignore();
    }
    
    emit dragMoved(event->pos(), isValid);
    return isValid;
}

void DragDropManager::handleDragLeave(QDragLeaveEvent* event, QWidget* targetWidget)
{
    Q_UNUSED(event)
    qCDebug(jveDragDrop) << "Drag leave from widget:" << targetWidget->objectName();
    
    hideDropIndicator(targetWidget);
    m_currentTarget = nullptr;
}

bool DragDropManager::handleDrop(QDropEvent* event, QWidget* targetWidget)
{
    qCDebug(jveDragDrop) << "Drop on widget:" << targetWidget->objectName();
    
    hideDropIndicator(targetWidget);
    
    // Handle external files
    if (event->mimeData()->hasUrls()) {
        QList<QUrl> urls = event->mimeData()->urls();
        if (acceptExternalFiles(urls)) {
            DropInfo dropInfo = m_currentDropInfo;
            dropInfo.zone = identifyDropZone(targetWidget, event->pos());
            processExternalFileDrop(urls, dropInfo);
            event->acceptProposedAction();
            return true;
        }
    }
    
    // Handle internal drops
    if (event->mimeData()->hasFormat("application/x-jve-drag")) {
        QByteArray data = event->mimeData()->data("application/x-jve-drag");
        QJsonDocument doc = QJsonDocument::fromJson(data);
        QJsonObject dragObj = doc.object();
        
        DragType type = static_cast<DragType>(dragObj["type"].toInt());
        QStringList itemIds = dragObj["items"].toVariant().toStringList();
        
        DropZone zone = identifyDropZone(targetWidget, event->pos());
        
        switch (zone) {
        case TimelineZone:
            handleTimelineDrop(type, itemIds, event->pos());
            break;
        case MediaBrowserZone:
            handleMediaBrowserDrop(type, itemIds, event->pos());
            break;
        case ProjectPanelZone:
            handleProjectPanelDrop(type, itemIds, event->pos());
            break;
        case InspectorZone:
            handleInspectorDrop(type, itemIds, event->pos());
            break;
        default:
            event->ignore();
            return false;
        }
        
        event->acceptProposedAction();
        return true;
    }
    
    event->ignore();
    return false;
}

void DragDropManager::handleTimelineDrop(DragType type, const QStringList& itemIds, const QPoint& position)
{
    qCDebug(jveDragDrop) << "Timeline drop of type" << type << "items:" << itemIds;
    
    // Calculate target track and time position
    QString targetTrack = "track_1"; // This would be calculated from position
    qint64 timePosition = 1000; // This would be calculated from position
    
    switch (m_dropMode) {
    case InsertMode:
        emit timelineInsertRequested(itemIds, targetTrack, timePosition);
        break;
    case OverwriteMode:
        emit timelineOverwriteRequested(itemIds, targetTrack, timePosition);
        break;
    case ReplaceMode:
        emit timelineReplaceRequested(itemIds, targetTrack, timePosition);
        break;
    default:
        break;
    }
    
    emit clipsDropped(itemIds, targetTrack, timePosition);
}

void DragDropManager::handleMediaBrowserDrop(DragType type, const QStringList& itemIds, const QPoint& position)
{
    Q_UNUSED(position)
    qCDebug(jveDragDrop) << "Media browser drop of type" << type << "items:" << itemIds;
    
    QString targetBin = "root_bin"; // This would be calculated from position
    emit mediaDropped(itemIds, targetBin);
}

void DragDropManager::handleProjectPanelDrop(DragType type, const QStringList& itemIds, const QPoint& position)
{
    Q_UNUSED(position)
    qCDebug(jveDragDrop) << "Project panel drop of type" << type << "items:" << itemIds;
    
    QString targetParent = "root"; // This would be calculated from position
    emit binsReorganized(itemIds, targetParent);
}

void DragDropManager::handleInspectorDrop(DragType type, const QStringList& itemIds, const QPoint& position)
{
    Q_UNUSED(position)
    qCDebug(jveDragDrop) << "Inspector drop of type" << type << "items:" << itemIds;
    
    // Property assignment logic would go here
    if (type == PropertyDrag && !itemIds.isEmpty()) {
        QString targetClip = "selected_clip"; // This would come from selection
        QJsonObject value;
        value["property"] = itemIds.first();
        emit propertyDropped(itemIds.first(), value, targetClip);
    }
}

DragDropManager::DropZone DragDropManager::identifyDropZone(QWidget* targetWidget, const QPoint& position) const
{
    Q_UNUSED(position)
    
    QString widgetName = targetWidget->objectName();
    
    if (widgetName.contains("timeline", Qt::CaseInsensitive)) {
        return TimelineZone;
    } else if (widgetName.contains("media", Qt::CaseInsensitive) || 
               widgetName.contains("browser", Qt::CaseInsensitive)) {
        return MediaBrowserZone;
    } else if (widgetName.contains("project", Qt::CaseInsensitive)) {
        return ProjectPanelZone;
    } else if (widgetName.contains("inspector", Qt::CaseInsensitive)) {
        return InspectorZone;
    }
    
    return InvalidZone;
}

void DragDropManager::setDropMode(DropMode mode)
{
    if (m_dropMode != mode) {
        m_dropMode = mode;
        qCDebug(jveDragDrop) << "Drop mode changed to:" << mode;
        emit onDropModeChanged(mode);
    }
}

DragDropManager::DropMode DragDropManager::getDropMode() const
{
    return m_dropMode;
}

void DragDropManager::toggleDropMode()
{
    switch (m_dropMode) {
    case InsertMode:
        setDropMode(OverwriteMode);
        break;
    case OverwriteMode:
        setDropMode(ReplaceMode);
        break;
    case ReplaceMode:
        setDropMode(InsertMode);
        break;
    default:
        setDropMode(InsertMode);
        break;
    }
}

bool DragDropManager::validateDrop(const DragData& dragData, const DropInfo& dropInfo) const
{
    // Basic validation
    if (dropInfo.zone == InvalidZone) {
        return false;
    }
    
    // Type-specific validation
    switch (dragData.type) {
    case MediaAssetDrag:
        return (dropInfo.zone == TimelineZone || dropInfo.zone == MediaBrowserZone);
    case TimelineClipDrag:
        return (dropInfo.zone == TimelineZone);
    case BinFolderDrag:
        return (dropInfo.zone == MediaBrowserZone || dropInfo.zone == ProjectPanelZone);
    case PropertyDrag:
        return (dropInfo.zone == InspectorZone);
    default:
        return false;
    }
}

void DragDropManager::showDropIndicator(QWidget* targetWidget, const QPoint& position, bool isValid)
{
    m_indicatorWidget = targetWidget;
    m_indicatorPosition = position;
    m_showingIndicator = true;
    
    // Update cursor
    if (isValid) {
        updateDragCursor(m_currentDragData.type, m_dropMode, true);
    } else {
        QApplication::setOverrideCursor(m_invalidCursor);
    }
    
    // Trigger visual feedback
    emit showInsertionIndicator(position);
}

void DragDropManager::hideDropIndicator(QWidget* targetWidget)
{
    Q_UNUSED(targetWidget)
    
    if (m_showingIndicator) {
        m_showingIndicator = false;
        QApplication::restoreOverrideCursor();
        emit hideInsertionIndicator();
    }
}

void DragDropManager::updateDragCursor(DragType type, DropMode mode, bool isValidTarget)
{
    if (!isValidTarget) {
        QApplication::setOverrideCursor(m_invalidCursor);
        return;
    }
    
    switch (mode) {
    case InsertMode:
        QApplication::setOverrideCursor(m_insertCursor);
        break;
    case OverwriteMode:
        QApplication::setOverrideCursor(m_overwriteCursor);
        break;
    case ReplaceMode:
        QApplication::setOverrideCursor(m_replaceCursor);
        break;
    default:
        QApplication::setOverrideCursor(Qt::ArrowCursor);
        break;
    }
}

bool DragDropManager::acceptExternalFiles(const QList<QUrl>& urls) const
{
    for (const QUrl& url : urls) {
        if (url.isLocalFile()) {
            QFileInfo fileInfo(url.toLocalFile());
            QString suffix = "." + fileInfo.suffix().toLower();
            if (m_supportedExtensions.contains(suffix)) {
                return true;
            }
        }
    }
    return false;
}

QStringList DragDropManager::getSupportedFileExtensions() const
{
    return m_supportedExtensions;
}

void DragDropManager::processExternalFileDrop(const QList<QUrl>& urls, const DropInfo& dropInfo)
{
    qCDebug(jveDragDrop) << "Processing external file drop:" << urls.size() << "files";
    
    QStringList validFiles;
    for (const QUrl& url : urls) {
        if (url.isLocalFile()) {
            QFileInfo fileInfo(url.toLocalFile());
            QString suffix = "." + fileInfo.suffix().toLower();
            if (m_supportedExtensions.contains(suffix)) {
                validFiles << url.toLocalFile();
            }
        }
    }
    
    if (!validFiles.isEmpty()) {
        emit externalFilesDropped(urls, dropInfo);
    }
}

QDrag* DragDropManager::createDrag(const DragData& dragData)
{
    QDrag* drag = new QDrag(dragData.sourceWidget);
    
    // Create mime data
    QMimeData* mimeData = createMimeData(dragData);
    drag->setMimeData(mimeData);
    
    // Create drag pixmap
    QPixmap pixmap = createDragPixmap(dragData);
    drag->setPixmap(pixmap);
    
    return drag;
}

QMimeData* DragDropManager::createMimeData(const DragData& dragData)
{
    QMimeData* mimeData = new QMimeData();
    
    // Create JSON representation
    QJsonObject dragObj;
    dragObj["type"] = static_cast<int>(dragData.type);
    dragObj["items"] = QJsonArray::fromStringList(dragData.itemIds);
    dragObj["metadata"] = dragData.metadata;
    
    QJsonDocument doc(dragObj);
    mimeData->setData("application/x-jve-drag", doc.toJson());
    
    // Add text representation for debugging
    mimeData->setText(QString("JVE Drag: %1 items").arg(dragData.itemIds.size()));
    
    return mimeData;
}

QPixmap DragDropManager::createDragPixmap(const DragData& dragData)
{
    // Create a simple drag pixmap
    QPixmap pixmap(DRAG_PIXMAP_MAX_WIDTH, 40);
    pixmap.fill(Qt::transparent);
    
    QPainter painter(&pixmap);
    painter.setRenderHint(QPainter::Antialiasing);
    
    // Background
    painter.setBrush(QBrush(QColor(70, 130, 180, 180)));
    painter.setPen(QPen(QColor(70, 130, 180), 2));
    painter.drawRoundedRect(0, 0, pixmap.width(), pixmap.height(), 5, 5);
    
    // Text
    painter.setPen(Qt::white);
    QString text = QString("%1 item%2").arg(dragData.itemIds.size())
                                      .arg(dragData.itemIds.size() > 1 ? "s" : "");
    painter.drawText(10, 25, text);
    
    return pixmap;
}

qint64 DragDropManager::snapToNearestPosition(qint64 position, const QString& trackId) const
{
    Q_UNUSED(trackId)
    
    if (!m_snapToPlayhead) {
        return position;
    }
    
    // Simple snap to playhead logic
    if (abs(position - m_playheadPosition) <= m_snapTolerance * 100) { // Convert pixels to time
        return m_playheadPosition;
    }
    
    return position;
}

QCursor DragDropManager::createCustomCursor(const QString& iconName, const QString& text)
{
    Q_UNUSED(iconName)
    Q_UNUSED(text)
    
    // For now, return standard cursors
    // In a real implementation, this would create custom cursor pixmaps
    if (iconName == "insert") return Qt::DragMoveCursor;
    if (iconName == "overwrite") return Qt::DragCopyCursor;
    if (iconName == "replace") return Qt::DragLinkCursor;
    if (iconName == "invalid") return Qt::ForbiddenCursor;
    
    return Qt::ArrowCursor;
}

void DragDropManager::enableSnapToPlayhead(bool enabled)
{
    m_snapToPlayhead = enabled;
    qCDebug(jveDragDrop) << "Snap to playhead:" << enabled;
}

void DragDropManager::enableSnapToClips(bool enabled)
{
    m_snapToClips = enabled;
    qCDebug(jveDragDrop) << "Snap to clips:" << enabled;
}

void DragDropManager::setSnapTolerance(int pixels)
{
    m_snapTolerance = pixels;
    qCDebug(jveDragDrop) << "Snap tolerance set to:" << pixels;
}

bool DragDropManager::isSnapEnabled() const
{
    return m_snapToPlayhead || m_snapToClips;
}

void DragDropManager::onSelectionChanged(const QStringList& selectedItems)
{
    m_selectedItems = selectedItems;
}

void DragDropManager::onPlayheadPositionChanged(qint64 position)
{
    m_playheadPosition = position;
}

void DragDropManager::onDropModeChanged(DropMode mode)
{
    Q_UNUSED(mode)
    // Update UI indicators for drop mode
}

void DragDropManager::onDragTimer()
{
    // Timer for drag operation feedback and animations
    if (m_dragActive) {
        emit dragFeedbackUpdate();
        qCDebug(jveDragDrop) << "Drag timer tick - providing visual feedback";
    }
}

void DragDropManager::onSnapTimer()
{
    // Timer for snap operation processing
    if (m_snapActive) {
        // Process snap calculations and provide visual feedback
        emit snapFeedbackUpdate();
        qCDebug(jveDragDrop) << "Snap timer tick - processing snap feedback";
    }
}