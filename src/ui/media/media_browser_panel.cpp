#include "media_browser_panel.h"
#include <QLoggingCategory>
#include <QMimeData>
#include <QApplication>
#include <QFileDialog>
#include <QInputDialog>
#include <QMessageBox>
#include <QStandardPaths>
#include <QDesktopServices>
#include <QProcess>
#include <QUrlQuery>

Q_LOGGING_CATEGORY(jveMediaBrowser, "jve.ui.media")

MediaBrowserPanel::MediaBrowserPanel(QWidget* parent)
    : QWidget(parent)
{
    setupUI();
    setupBinTree();
    setupMediaView();
    setupToolbar();
    setupStatusBar();
    connectSignals();
    
    // Initialize thumbnail timer
    m_thumbnailTimer = new QTimer(this);
    m_thumbnailTimer->setSingleShot(true);
    m_thumbnailTimer->setInterval(100);
    connect(m_thumbnailTimer, &QTimer::timeout, this, &MediaBrowserPanel::generateThumbnails);
    
    // Set initial state
    setViewMode(ListView);
    clearSelection();
    
    qCDebug(jveMediaBrowser, "Media browser panel initialized");
}

void MediaBrowserPanel::setupUI()
{
    m_mainLayout = new QVBoxLayout(this);
    m_mainLayout->setContentsMargins(4, 4, 4, 4);
    m_mainLayout->setSpacing(2);
    
    // Create main splitter
    m_splitter = new QSplitter(Qt::Horizontal, this);
    m_mainLayout->addWidget(m_splitter);
    
    // Apply professional styling
    setStyleSheet(QString(
        "QSplitter::handle { background: #333; width: 2px; }"
        "QTreeWidget { background: %1; border: 1px solid #444; selection-background-color: %2; }"
        "QListWidget { background: %3; border: 1px solid #444; selection-background-color: %2; }"
        "QTableWidget { background: %3; border: 1px solid #444; selection-background-color: %2; }"
        "QHeaderView::section { background: #555; border: 1px solid #333; padding: 4px; }"
        "QLineEdit { background: #333; border: 1px solid #555; padding: 4px; }"
        "QPushButton { background: #444; border: 1px solid #666; padding: 6px 12px; }"
        "QPushButton:hover { background: #555; }"
        "QPushButton:pressed { background: #333; }"
        "QComboBox { background: #444; border: 1px solid #666; padding: 4px; }"
        "QComboBox::drop-down { border: none; }"
        "QComboBox::down-arrow { width: 12px; height: 12px; }"
    ).arg(m_binTreeColor.name())
     .arg(m_selectedColor.name())
     .arg(m_mediaViewColor.name()));
}

void MediaBrowserPanel::setupBinTree()
{
    // Create bin panel
    QWidget* binPanel = new QWidget();
    m_binLayout = new QVBoxLayout(binPanel);
    m_binLayout->setContentsMargins(4, 4, 4, 4);
    m_binLayout->setSpacing(2);
    
    // Bin header
    m_binLabel = new QLabel("Project Bins");
    m_binLabel->setFont(m_binFont);
    m_binLabel->setStyleSheet("font-weight: bold; padding: 4px;");
    m_binLayout->addWidget(m_binLabel);
    
    // Bin tree
    m_binTree = new QTreeWidget();
    m_binTree->setHeaderLabel("Bins");
    m_binTree->setDragDropMode(QAbstractItemView::InternalMove);
    m_binTree->setSelectionMode(QAbstractItemView::SingleSelection);
    m_binTree->setContextMenuPolicy(Qt::CustomContextMenu);
    m_binTree->setMinimumWidth(200);
    m_binLayout->addWidget(m_binTree);
    
    m_splitter->addWidget(binPanel);
    m_splitter->setSizes({200, 600});
}

void MediaBrowserPanel::setupMediaView()
{
    // Create media panel
    m_mediaWidget = new QWidget();
    m_mediaLayout = new QVBoxLayout(m_mediaWidget);
    m_mediaLayout->setContentsMargins(4, 4, 4, 4);
    m_mediaLayout->setSpacing(2);
    
    // List view
    m_mediaListView = new QListWidget();
    m_mediaListView->setDragDropMode(QAbstractItemView::DragOnly);
    m_mediaListView->setSelectionMode(QAbstractItemView::ExtendedSelection);
    m_mediaListView->setContextMenuPolicy(Qt::CustomContextMenu);
    m_mediaListView->setUniformItemSizes(true);
    m_mediaLayout->addWidget(m_mediaListView);
    
    // Table view (initially hidden)
    m_mediaTableView = new QTableWidget();
    m_mediaTableView->setColumnCount(6);
    QStringList headers = {"Name", "Type", "Duration", "Size", "Resolution", "Status"};
    m_mediaTableView->setHorizontalHeaderLabels(headers);
    m_mediaTableView->setDragDropMode(QAbstractItemView::DragOnly);
    m_mediaTableView->setSelectionBehavior(QAbstractItemView::SelectRows);
    m_mediaTableView->setSelectionMode(QAbstractItemView::ExtendedSelection);
    m_mediaTableView->setContextMenuPolicy(Qt::CustomContextMenu);
    m_mediaTableView->horizontalHeader()->setStretchLastSection(true);
    m_mediaTableView->setVisible(false);
    m_mediaLayout->addWidget(m_mediaTableView);
    
    // Thumbnail view (initially hidden)
    m_thumbnailArea = new QScrollArea();
    m_thumbnailWidget = new QWidget();
    m_thumbnailArea->setWidget(m_thumbnailWidget);
    m_thumbnailArea->setWidgetResizable(true);
    m_thumbnailArea->setVisible(false);
    m_mediaLayout->addWidget(m_thumbnailArea);
    
    // Media count label
    m_mediaCountLabel = new QLabel("0 items");
    m_mediaCountLabel->setFont(m_statusFont);
    m_mediaCountLabel->setAlignment(Qt::AlignRight);
    m_mediaLayout->addWidget(m_mediaCountLabel);
    
    m_splitter->addWidget(m_mediaWidget);
}

void MediaBrowserPanel::setupToolbar()
{
    m_toolbarLayout = new QHBoxLayout();
    m_toolbarLayout->setContentsMargins(0, 0, 0, 0);
    m_toolbarLayout->setSpacing(4);
    
    // View mode combo
    m_viewModeCombo = new QComboBox();
    m_viewModeCombo->addItems({"List", "Thumbnails", "Details"});
    m_viewModeCombo->setToolTip("View Mode");
    m_toolbarLayout->addWidget(m_viewModeCombo);
    
    // Sort mode combo
    m_sortModeCombo = new QComboBox();
    m_sortModeCombo->addItems({"Name", "Date", "Size", "Type", "Duration"});
    m_sortModeCombo->setToolTip("Sort By");
    m_toolbarLayout->addWidget(m_sortModeCombo);
    
    // Filter edit
    m_filterEdit = new QLineEdit();
    m_filterEdit->setPlaceholderText("Search media...");
    m_filterEdit->setMaximumWidth(200);
    m_toolbarLayout->addWidget(m_filterEdit);
    
    m_toolbarLayout->addStretch();
    
    // Action buttons
    m_refreshButton = new QPushButton("Refresh");
    m_refreshButton->setToolTip("Refresh Media");
    m_toolbarLayout->addWidget(m_refreshButton);
    
    m_importButton = new QPushButton("Import");
    m_importButton->setToolTip("Import Media Files");
    m_toolbarLayout->addWidget(m_importButton);
    
    m_createBinButton = new QPushButton("New Bin");
    m_createBinButton->setToolTip("Create New Bin");
    m_toolbarLayout->addWidget(m_createBinButton);
    
    // Insert toolbar at top
    m_mainLayout->insertLayout(0, m_toolbarLayout);
}

void MediaBrowserPanel::setupStatusBar()
{
    QHBoxLayout* statusLayout = new QHBoxLayout();
    statusLayout->setContentsMargins(0, 0, 0, 0);
    
    // Import progress
    m_importProgress = new QProgressBar();
    m_importProgress->setVisible(false);
    m_importProgress->setMaximumHeight(16);
    statusLayout->addWidget(m_importProgress);
    
    // Status label
    m_statusLabel = new QLabel("Ready");
    m_statusLabel->setFont(m_statusFont);
    statusLayout->addWidget(m_statusLabel);
    
    statusLayout->addStretch();
    
    m_mainLayout->addLayout(statusLayout);
}

void MediaBrowserPanel::connectSignals()
{
    // View controls
    connect(m_viewModeCombo, QOverload<int>::of(&QComboBox::currentIndexChanged),
            this, &MediaBrowserPanel::onViewModeChanged);
    connect(m_sortModeCombo, QOverload<int>::of(&QComboBox::currentIndexChanged),
            this, &MediaBrowserPanel::onSortModeChanged);
    connect(m_filterEdit, &QLineEdit::textChanged, this, &MediaBrowserPanel::onFilterTextChanged);
    
    // Action buttons
    connect(m_refreshButton, &QPushButton::clicked, this, &MediaBrowserPanel::onRefreshRequested);
    connect(m_importButton, &QPushButton::clicked, this, &MediaBrowserPanel::onImportRequested);
    connect(m_createBinButton, &QPushButton::clicked, this, &MediaBrowserPanel::onCreateBinRequested);
    
    // Bin tree
    connect(m_binTree, &QTreeWidget::itemSelectionChanged, this, &MediaBrowserPanel::onBinSelectionChanged);
    connect(m_binTree, &QTreeWidget::itemDoubleClicked, this, &MediaBrowserPanel::onBinDoubleClicked);
    connect(m_binTree, &QTreeWidget::customContextMenuRequested, [this](const QPoint& pos) {
        QTreeWidgetItem* item = m_binTree->itemAt(pos);
        if (item) {
            QString binId = item->data(0, Qt::UserRole).toString();
            QMenu* menu = createBinContextMenu(binId);
            menu->exec(m_binTree->mapToGlobal(pos));
            menu->deleteLater();
        }
    });
    
    // Media views
    connect(m_mediaListView, &QListWidget::itemSelectionChanged, this, &MediaBrowserPanel::onMediaSelectionChanged);
    connect(m_mediaListView, &QListWidget::itemDoubleClicked, this, &MediaBrowserPanel::onMediaDoubleClicked);
    connect(m_mediaListView, &QListWidget::customContextMenuRequested, [this](const QPoint& pos) {
        QListWidgetItem* item = m_mediaListView->itemAt(pos);
        QStringList mediaIds;
        if (item) {
            mediaIds = getSelectedMediaIds();
        }
        QMenu* menu = createMediaContextMenu(mediaIds);
        menu->exec(m_mediaListView->mapToGlobal(pos));
        menu->deleteLater();
    });
    
    connect(m_mediaTableView, &QTableWidget::itemSelectionChanged, this, &MediaBrowserPanel::onMediaSelectionChanged);
    connect(m_mediaTableView, &QTableWidget::customContextMenuRequested, [this](const QPoint& pos) {
        QTableWidgetItem* item = m_mediaTableView->itemAt(pos);
        QStringList mediaIds;
        if (item) {
            mediaIds = getSelectedMediaIds();
        }
        QMenu* menu = createMediaContextMenu(mediaIds);
        menu->exec(m_mediaTableView->mapToGlobal(pos));
        menu->deleteLater();
    });
}

void MediaBrowserPanel::setCommandDispatcher(CommandDispatcher* dispatcher)
{
    m_commandDispatcher = dispatcher;
}

void MediaBrowserPanel::setProject(const Project& project)
{
    m_project = project;
    loadBinHierarchy();
    refreshView();
}

void MediaBrowserPanel::setViewMode(ViewMode mode)
{
    if (m_viewMode == mode) return;
    
    m_viewMode = mode;
    
    // Hide all views first
    m_mediaListView->setVisible(false);
    m_mediaTableView->setVisible(false);
    m_thumbnailArea->setVisible(false);
    
    // Show appropriate view
    switch (mode) {
    case ListView:
        m_mediaListView->setVisible(true);
        m_viewModeCombo->setCurrentIndex(0);
        break;
    case ThumbnailView:
        m_thumbnailArea->setVisible(true);
        m_viewModeCombo->setCurrentIndex(1);
        generateThumbnails();
        break;
    case DetailView:
        m_mediaTableView->setVisible(true);
        m_viewModeCombo->setCurrentIndex(2);
        break;
    }
    
    refreshView();
}

MediaBrowserPanel::ViewMode MediaBrowserPanel::getViewMode() const
{
    return m_viewMode;
}

void MediaBrowserPanel::setSortMode(SortMode mode, bool ascending)
{
    m_sortMode = mode;
    m_sortAscending = ascending;
    m_sortModeCombo->setCurrentIndex(static_cast<int>(mode));
    sortMedia();
}

void MediaBrowserPanel::setFilterText(const QString& filter)
{
    m_filterText = filter;
    m_filterEdit->setText(filter);
    applyFilter();
}

void MediaBrowserPanel::refreshView()
{
    if (!m_currentBinId.isEmpty()) {
        loadMediaForBin(m_currentBinId);
    }
}

QStringList MediaBrowserPanel::getSelectedMediaIds() const
{
    return m_selectedMediaIds;
}

QStringList MediaBrowserPanel::getSelectedBinIds() const
{
    return m_selectedBinIds;
}

void MediaBrowserPanel::clearSelection()
{
    m_selectedMediaIds.clear();
    m_selectedBinIds.clear();
    m_binTree->clearSelection();
    m_mediaListView->clearSelection();
    m_mediaTableView->clearSelection();
}

// Slot implementations
void MediaBrowserPanel::onBinSelectionChanged()
{
    QList<QTreeWidgetItem*> selected = m_binTree->selectedItems();
    if (!selected.isEmpty()) {
        QTreeWidgetItem* item = selected.first();
        QString binId = item->data(0, Qt::UserRole).toString();
        m_currentBinId = binId;
        m_selectedBinIds = {binId};
        loadMediaForBin(binId);
        emit binSelected(binId);
    }
}

void MediaBrowserPanel::onMediaSelectionChanged()
{
    m_selectedMediaIds.clear();
    
    if (m_viewMode == ListView) {
        QList<QListWidgetItem*> selected = m_mediaListView->selectedItems();
        for (QListWidgetItem* item : selected) {
            QString mediaId = item->data(Qt::UserRole).toString();
            m_selectedMediaIds.append(mediaId);
        }
    } else if (m_viewMode == DetailView) {
        QList<QTableWidgetItem*> selected = m_mediaTableView->selectedItems();
        QSet<int> selectedRows;
        for (QTableWidgetItem* item : selected) {
            selectedRows.insert(item->row());
        }
        for (int row : selectedRows) {
            QTableWidgetItem* nameItem = m_mediaTableView->item(row, 0);
            if (nameItem) {
                QString mediaId = nameItem->data(Qt::UserRole).toString();
                m_selectedMediaIds.append(mediaId);
            }
        }
    }
    
    emit mediaSelected(m_selectedMediaIds);
}

void MediaBrowserPanel::onMediaDoubleClicked(QListWidgetItem* item)
{
    if (item) {
        QString mediaId = item->data(Qt::UserRole).toString();
        emit mediaDoubleClicked(mediaId);
    }
}

void MediaBrowserPanel::onBinDoubleClicked(QTreeWidgetItem* item, int column)
{
    Q_UNUSED(column)
    if (item) {
        QString binId = item->data(0, Qt::UserRole).toString();
        qCDebug(jveMediaBrowser, "Bin double-clicked: %s", qPrintable(binId));
    }
}

void MediaBrowserPanel::onViewModeChanged()
{
    ViewMode mode = static_cast<ViewMode>(m_viewModeCombo->currentIndex());
    setViewMode(mode);
}

void MediaBrowserPanel::onSortModeChanged()
{
    SortMode mode = static_cast<SortMode>(m_sortModeCombo->currentIndex());
    setSortMode(mode, m_sortAscending);
}

void MediaBrowserPanel::onFilterTextChanged()
{
    QString filter = m_filterEdit->text();
    setFilterText(filter);
}

void MediaBrowserPanel::onRefreshRequested()
{
    refreshView();
    m_statusLabel->setText("Refreshed");
}

void MediaBrowserPanel::onImportRequested()
{
    QStringList filePaths = QFileDialog::getOpenFileNames(
        this,
        "Import Media Files",
        QStandardPaths::writableLocation(QStandardPaths::MoviesLocation),
        "Media Files (*.mp4 *.mov *.avi *.mkv *.mxf *.r3d *.wav *.aif *.mp3);;All Files (*)"
    );
    
    if (!filePaths.isEmpty()) {
        importMedia(filePaths, m_currentBinId);
    }
}

void MediaBrowserPanel::onCreateBinRequested()
{
    bool ok;
    QString name = QInputDialog::getText(this, "Create Bin", "Bin name:", QLineEdit::Normal, "New Bin", &ok);
    if (ok && !name.isEmpty()) {
        createBin(name, m_currentBinId);
    }
}

// Core functionality implementations
void MediaBrowserPanel::createBin(const QString& name, const QString& parentBinId)
{
    qCDebug(jveMediaBrowser, "Creating bin: %s (parent: %s)", qPrintable(name), qPrintable(parentBinId));
    // TODO: Implement actual bin creation via command system
    QString binId = QUuid::createUuid().toString(QUuid::WithoutBraces);
    emit binCreated(binId, name);
}

void MediaBrowserPanel::importMedia(const QStringList& filePaths, const QString& binId)
{
    qCDebug(jveMediaBrowser, "Importing %d files to bin: %s", filePaths.size(), qPrintable(binId));
    
    m_importProgress->setVisible(true);
    m_importProgress->setRange(0, filePaths.size());
    m_importProgress->setValue(0);
    
    emit mediaImportRequested(filePaths, binId);
}

void MediaBrowserPanel::loadBinHierarchy()
{
    m_binTree->clear();
    
    // TODO: Load actual bin hierarchy from project
    // For now, create sample bins
    QTreeWidgetItem* rootItem = createBinItem("root", "Master Bin");
    m_binTree->addTopLevelItem(rootItem);
    
    QTreeWidgetItem* videoItem = createBinItem("video", "Video", rootItem);
    QTreeWidgetItem* audioItem = createBinItem("audio", "Audio", rootItem);
    QTreeWidgetItem* graphicsItem = createBinItem("graphics", "Graphics", rootItem);
    
    rootItem->addChild(videoItem);
    rootItem->addChild(audioItem);
    rootItem->addChild(graphicsItem);
    
    m_binTree->expandAll();
}

void MediaBrowserPanel::loadMediaForBin(const QString& binId)
{
    qCDebug(jveMediaBrowser, "Loading media for bin: %s", qPrintable(binId));
    
    // TODO: Load actual media from database
    QList<Media> mediaList;
    populateMediaView(mediaList);
    
    m_mediaCountLabel->setText(QString("%1 items").arg(mediaList.size()));
}

void MediaBrowserPanel::populateMediaView(const QList<Media>& mediaList)
{
    // Clear current views
    m_mediaListView->clear();
    m_mediaTableView->setRowCount(0);
    
    for (const Media& media : mediaList) {
        updateMediaItem(media);
    }
    
    applyFilter();
    sortMedia();
}

QTreeWidgetItem* MediaBrowserPanel::createBinItem(const QString& binId, const QString& name, QTreeWidgetItem* parent)
{
    QTreeWidgetItem* item = new QTreeWidgetItem();
    item->setText(0, name);
    item->setData(0, Qt::UserRole, binId);
    item->setIcon(0, QIcon(":/icons/folder")); // Would use actual icon
    return item;
}

QListWidgetItem* MediaBrowserPanel::createMediaListItem(const Media& media)
{
    QListWidgetItem* item = new QListWidgetItem();
    item->setText(media.filename());
    item->setData(Qt::UserRole, media.id());
    item->setIcon(getMediaTypeIcon(media));
    return item;
}

void MediaBrowserPanel::updateMediaItem(const Media& media)
{
    // Update list view
    QListWidgetItem* listItem = createMediaListItem(media);
    m_mediaListView->addItem(listItem);
    
    // Update table view
    int row = m_mediaTableView->rowCount();
    m_mediaTableView->insertRow(row);
    
    m_mediaTableView->setItem(row, 0, new QTableWidgetItem(media.filename()));
    
    QString typeStr;
    switch (media.type()) {
        case Media::Video: typeStr = "Video"; break;
        case Media::Audio: typeStr = "Audio"; break;
        case Media::Image: typeStr = "Image"; break;
        default: typeStr = "Unknown"; break;
    }
    m_mediaTableView->setItem(row, 1, new QTableWidgetItem(typeStr));
    m_mediaTableView->setItem(row, 2, new QTableWidgetItem(formatDuration(media.duration())));
    m_mediaTableView->setItem(row, 3, new QTableWidgetItem(formatFileSize(media.fileSize())));
    m_mediaTableView->setItem(row, 4, new QTableWidgetItem(getMediaResolutionInfo(media)));
    m_mediaTableView->setItem(row, 5, new QTableWidgetItem(media.isOnline() ? "Online" : "Offline"));
    
    // Store media ID in first column
    m_mediaTableView->item(row, 0)->setData(Qt::UserRole, media.id());
    
    // Cache media
    m_mediaCache[media.id()] = media;
}

QIcon MediaBrowserPanel::getMediaTypeIcon(const Media& media)
{
    // TODO: Return appropriate icons based on media type
    Q_UNUSED(media)
    return QIcon();
}

void MediaBrowserPanel::applyFilter()
{
    if (m_filterText.isEmpty()) {
        // Show all items
        for (int i = 0; i < m_mediaListView->count(); ++i) {
            m_mediaListView->item(i)->setHidden(false);
        }
        for (int i = 0; i < m_mediaTableView->rowCount(); ++i) {
            m_mediaTableView->setRowHidden(i, false);
        }
    } else {
        // Filter items
        for (int i = 0; i < m_mediaListView->count(); ++i) {
            QListWidgetItem* item = m_mediaListView->item(i);
            QString mediaId = item->data(Qt::UserRole).toString();
            Media media = m_mediaCache.value(mediaId);
            bool matches = matchesFilter(media, m_filterText);
            item->setHidden(!matches);
        }
        for (int i = 0; i < m_mediaTableView->rowCount(); ++i) {
            QTableWidgetItem* nameItem = m_mediaTableView->item(i, 0);
            if (nameItem) {
                QString mediaId = nameItem->data(Qt::UserRole).toString();
                Media media = m_mediaCache.value(mediaId);
                bool matches = matchesFilter(media, m_filterText);
                m_mediaTableView->setRowHidden(i, !matches);
            }
        }
    }
}

bool MediaBrowserPanel::matchesFilter(const Media& media, const QString& filter)
{
    QString filterLower = filter.toLower();
    QString typeStr;
    switch (media.type()) {
        case Media::Video: typeStr = "video"; break;
        case Media::Audio: typeStr = "audio"; break;
        case Media::Image: typeStr = "image"; break;
        default: typeStr = "unknown"; break;
    }
    return media.filename().toLower().contains(filterLower) ||
           typeStr.contains(filterLower) ||
           media.filepath().toLower().contains(filterLower);
}

void MediaBrowserPanel::sortMedia()
{
    // TODO: Implement proper sorting
}

void MediaBrowserPanel::generateThumbnails()
{
    // TODO: Implement thumbnail generation
}

QMenu* MediaBrowserPanel::createBinContextMenu(const QString& binId)
{
    QMenu* menu = new QMenu(this);
    
    menu->addAction("Create Sub-Bin", [this, binId]() {
        onCreateBinRequested();
    });
    
    menu->addAction("Rename Bin", [this, binId]() {
        // TODO: Implement bin renaming
    });
    
    menu->addSeparator();
    
    menu->addAction("Delete Bin", [this, binId]() {
        // TODO: Implement bin deletion
    });
    
    return menu;
}

QMenu* MediaBrowserPanel::createMediaContextMenu(const QStringList& mediaIds)
{
    QMenu* menu = new QMenu(this);
    
    if (!mediaIds.isEmpty()) {
        menu->addAction("Add to Timeline", [this, mediaIds]() {
            // TODO: Add to timeline
        });
        
        menu->addSeparator();
        
        menu->addAction("Reveal in Finder", [this, mediaIds]() {
            // TODO: Reveal file location
        });
        
        menu->addAction("Relink Media", [this, mediaIds]() {
            // TODO: Relink media
        });
        
        menu->addSeparator();
        
        menu->addAction("Remove from Bin", [this, mediaIds]() {
            removeMedia(mediaIds);
        });
    } else {
        menu->addAction("Import Media", [this]() {
            onImportRequested();
        });
    }
    
    return menu;
}

// Event handlers
void MediaBrowserPanel::dragEnterEvent(QDragEnterEvent* event)
{
    if (isValidDropTarget(event->mimeData())) {
        event->acceptProposedAction();
    }
}

void MediaBrowserPanel::dropEvent(QDropEvent* event)
{
    if (isValidDropTarget(event->mimeData())) {
        QStringList filePaths = extractFilePaths(event->mimeData());
        QString targetBin = getDropTargetBin(event->position().toPoint());
        importMedia(filePaths, targetBin);
        event->acceptProposedAction();
    }
}

void MediaBrowserPanel::contextMenuEvent(QContextMenuEvent* event)
{
    QWidget::contextMenuEvent(event);
}

void MediaBrowserPanel::resizeEvent(QResizeEvent* event)
{
    QWidget::resizeEvent(event);
    // TODO: Adjust thumbnail layout
}

// Utility methods
QString MediaBrowserPanel::formatDuration(qint64 durationMs) const
{
    qint64 seconds = durationMs / 1000;
    qint64 minutes = seconds / 60;
    qint64 hours = minutes / 60;
    
    if (hours > 0) {
        return QString("%1:%2:%3")
            .arg(hours)
            .arg(minutes % 60, 2, 10, QChar('0'))
            .arg(seconds % 60, 2, 10, QChar('0'));
    } else {
        return QString("%1:%2")
            .arg(minutes)
            .arg(seconds % 60, 2, 10, QChar('0'));
    }
}

QString MediaBrowserPanel::formatFileSize(qint64 bytes) const
{
    const qint64 KB = 1024;
    const qint64 MB = KB * 1024;
    const qint64 GB = MB * 1024;
    
    if (bytes >= GB) {
        return QString("%1 GB").arg(bytes / double(GB), 0, 'f', 1);
    } else if (bytes >= MB) {
        return QString("%1 MB").arg(bytes / double(MB), 0, 'f', 1);
    } else if (bytes >= KB) {
        return QString("%1 KB").arg(bytes / double(KB), 0, 'f', 1);
    } else {
        return QString("%1 B").arg(bytes);
    }
}

QString MediaBrowserPanel::getMediaResolutionInfo(const Media& media) const
{
    return QString("%1x%2").arg(media.width()).arg(media.height());
}

bool MediaBrowserPanel::isValidDropTarget(const QMimeData* mimeData)
{
    return mimeData->hasUrls();
}

QStringList MediaBrowserPanel::extractFilePaths(const QMimeData* mimeData)
{
    QStringList filePaths;
    QList<QUrl> urls = mimeData->urls();
    for (const QUrl& url : urls) {
        if (url.isLocalFile()) {
            filePaths.append(url.toLocalFile());
        }
    }
    return filePaths;
}

QString MediaBrowserPanel::getDropTargetBin(const QPoint& position)
{
    Q_UNUSED(position)
    return m_currentBinId;
}

// Placeholder implementations
void MediaBrowserPanel::deleteBin(const QString&) {}
void MediaBrowserPanel::renameBin(const QString&, const QString&) {}
void MediaBrowserPanel::moveBin(const QString&, const QString&) {}
void MediaBrowserPanel::removeMedia(const QStringList&) {}
void MediaBrowserPanel::moveMedia(const QStringList&, const QString&) {}
void MediaBrowserPanel::relinkMedia(const QString&, const QString&) {}
void MediaBrowserPanel::selectMedia(const QStringList&) {}
void MediaBrowserPanel::selectBin(const QString&) {}
void MediaBrowserPanel::onMediaImportProgress(const QString&, int) {}
void MediaBrowserPanel::onMediaImportCompleted(const QString&, bool) {}
void MediaBrowserPanel::onThumbnailGenerated(const QString&, const QPixmap&) {}
QTreeWidgetItem* MediaBrowserPanel::findBinItem(const QString&) { return nullptr; }
void MediaBrowserPanel::updateBinItemCounts(QTreeWidgetItem*) {}
void MediaBrowserPanel::requestThumbnail(const QString&) {}
QPixmap MediaBrowserPanel::getMediaThumbnail(const Media&) { return QPixmap(); }
QString MediaBrowserPanel::getMediaCodecInfo(const Media&) const { return QString(); }
QColor MediaBrowserPanel::getMediaStatusColor(const Media&) const { return QColor(); }
QTableWidgetItem* MediaBrowserPanel::createMediaTableItem(const Media&, int) { return nullptr; }