#pragma once

#include <QWidget>
#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QSplitter>
#include <QTreeWidget>
#include <QTreeWidgetItem>
#include <QListWidget>
#include <QListWidgetItem>
#include <QTableWidget>
#include <QTableWidgetItem>
#include <QHeaderView>
#include <QLabel>
#include <QLineEdit>
#include <QPushButton>
#include <QComboBox>
#include <QProgressBar>
#include <QGroupBox>
#include <QScrollArea>
#include <QFileSystemWatcher>
#include <QTimer>
#include <QThread>
#include <QMutex>
#include <QFileInfo>
#include <QDir>
#include <QUrl>
#include <QMimeData>
#include <QDragEnterEvent>
#include <QDropEvent>
#include <QContextMenuEvent>
#include <QMenu>
#include <QAction>
#include <QPixmap>
#include <QIcon>

#include "core/models/media.h"
#include "core/models/project.h"
#include "core/commands/command_dispatcher.h"

/**
 * Professional media browser panel for asset management
 * 
 * Features:
 * - Hierarchical bin organization with drag-and-drop
 * - Multiple view modes (list, thumbnail, detail)
 * - Real-time thumbnail generation for video files
 * - Professional metadata display (duration, resolution, codec, etc.)
 * - Search and filtering capabilities
 * - Drag-and-drop import from file system
 * - Proxy media management
 * - Batch import and processing
 * - Media linking and relinking
 * - Professional context menus for media operations
 * - Bin organization similar to Avid/FCP7/Resolve
 * 
 * Design follows professional NLE media management patterns
 */
class MediaBrowserPanel : public QWidget
{
    Q_OBJECT

public:
    enum ViewMode {
        ListView,
        ThumbnailView,
        DetailView
    };

    enum SortMode {
        SortByName,
        SortByDate,
        SortBySize,
        SortByType,
        SortByDuration
    };

    explicit MediaBrowserPanel(QWidget* parent = nullptr);
    ~MediaBrowserPanel() = default;

    // Core functionality
    void setCommandDispatcher(CommandDispatcher* dispatcher);
    void setProject(const Project& project);
    
    // Bin management
    void createBin(const QString& name, const QString& parentBinId = QString());
    void deleteBin(const QString& binId);
    void renameBin(const QString& binId, const QString& newName);
    void moveBin(const QString& binId, const QString& newParentId);
    
    // Media management
    void importMedia(const QStringList& filePaths, const QString& binId = QString());
    void removeMedia(const QStringList& mediaIds);
    void moveMedia(const QStringList& mediaIds, const QString& toBinId);
    void relinkMedia(const QString& mediaId, const QString& newFilePath);
    
    // View control
    void setViewMode(ViewMode mode);
    ViewMode getViewMode() const;
    void setSortMode(SortMode mode, bool ascending = true);
    void setFilterText(const QString& filter);
    void refreshView();
    
    // Selection
    QStringList getSelectedMediaIds() const;
    QStringList getSelectedBinIds() const;
    void selectMedia(const QStringList& mediaIds);
    void selectBin(const QString& binId);
    void clearSelection();

signals:
    void mediaSelected(const QStringList& mediaIds);
    void binSelected(const QString& binId);
    void mediaDoubleClicked(const QString& mediaId);
    void mediaImportRequested(const QStringList& filePaths, const QString& binId);
    void mediaDroppedOnTimeline(const QStringList& mediaIds, const QPoint& position);
    void binCreated(const QString& binId, const QString& name);
    void binDeleted(const QString& binId);
    void mediaLinked(const QString& mediaId, const QString& filePath);

public slots:
    void onMediaImportProgress(const QString& mediaId, int progress);
    void onMediaImportCompleted(const QString& mediaId, bool success);
    void onThumbnailGenerated(const QString& mediaId, const QPixmap& thumbnail);

protected:
    // Event handling
    void dragEnterEvent(QDragEnterEvent* event) override;
    void dropEvent(QDropEvent* event) override;
    void contextMenuEvent(QContextMenuEvent* event) override;
    void resizeEvent(QResizeEvent* event) override;

private slots:
    void onBinSelectionChanged();
    void onMediaSelectionChanged();
    void onMediaDoubleClicked(QListWidgetItem* item);
    void onBinDoubleClicked(QTreeWidgetItem* item, int column);
    void onViewModeChanged();
    void onSortModeChanged();
    void onFilterTextChanged();
    void onRefreshRequested();
    void onImportRequested();
    void onCreateBinRequested();

private:
    // Setup methods
    void setupUI();
    void setupBinTree();
    void setupMediaView();
    void setupToolbar();
    void setupStatusBar();
    void connectSignals();
    
    // Bin management
    void loadBinHierarchy();
    void populateBinTree();
    QTreeWidgetItem* findBinItem(const QString& binId);
    QTreeWidgetItem* createBinItem(const QString& binId, const QString& name, QTreeWidgetItem* parent = nullptr);
    void updateBinItemCounts(QTreeWidgetItem* item);
    
    // Media display
    void loadMediaForBin(const QString& binId);
    void populateMediaView(const QList<Media>& mediaList);
    void updateMediaItem(const Media& media);
    QListWidgetItem* createMediaListItem(const Media& media);
    QTableWidgetItem* createMediaTableItem(const Media& media, int column);
    
    // Thumbnail management
    void requestThumbnail(const QString& mediaId);
    void generateThumbnails();
    QPixmap getMediaThumbnail(const Media& media);
    QIcon getMediaTypeIcon(const Media& media);
    
    // Search and filtering
    void applyFilter();
    bool matchesFilter(const Media& media, const QString& filter);
    void sortMedia();
    
    // Context menus
    QMenu* createBinContextMenu(const QString& binId);
    QMenu* createMediaContextMenu(const QStringList& mediaIds);
    
    // Drag and drop helpers
    bool isValidDropTarget(const QMimeData* mimeData);
    QStringList extractFilePaths(const QMimeData* mimeData);
    QString getDropTargetBin(const QPoint& position);
    
    // Utility methods
    QString formatDuration(qint64 durationMs) const;
    QString formatFileSize(qint64 bytes) const;
    QString getMediaCodecInfo(const Media& media) const;
    QString getMediaResolutionInfo(const Media& media) const;
    QColor getMediaStatusColor(const Media& media) const;
    
private:
    // Core components
    CommandDispatcher* m_commandDispatcher = nullptr;
    Project m_project;
    
    // UI layout
    QVBoxLayout* m_mainLayout = nullptr;
    QHBoxLayout* m_toolbarLayout = nullptr;
    QSplitter* m_splitter = nullptr;
    
    // Toolbar components
    QComboBox* m_viewModeCombo = nullptr;
    QComboBox* m_sortModeCombo = nullptr;
    QLineEdit* m_filterEdit = nullptr;
    QPushButton* m_refreshButton = nullptr;
    QPushButton* m_importButton = nullptr;
    QPushButton* m_createBinButton = nullptr;
    
    // Bin tree (left panel)
    QTreeWidget* m_binTree = nullptr;
    QVBoxLayout* m_binLayout = nullptr;
    QLabel* m_binLabel = nullptr;
    
    // Media view (right panel)
    QWidget* m_mediaWidget = nullptr;
    QVBoxLayout* m_mediaLayout = nullptr;
    QListWidget* m_mediaListView = nullptr;
    QTableWidget* m_mediaTableView = nullptr;
    QScrollArea* m_thumbnailArea = nullptr;
    QWidget* m_thumbnailWidget = nullptr;
    QLabel* m_mediaCountLabel = nullptr;
    
    // Status and progress
    QProgressBar* m_importProgress = nullptr;
    QLabel* m_statusLabel = nullptr;
    
    // Current state
    ViewMode m_viewMode = ListView;
    SortMode m_sortMode = SortByName;
    bool m_sortAscending = true;
    QString m_filterText;
    QString m_currentBinId;
    QStringList m_selectedMediaIds;
    QStringList m_selectedBinIds;
    
    // Media data
    QMap<QString, Media> m_mediaCache;
    QMap<QString, QPixmap> m_thumbnailCache;
    QStringList m_pendingThumbnails;
    
    // Background processing
    QFileSystemWatcher* m_fileWatcher = nullptr;
    QTimer* m_thumbnailTimer = nullptr;
    QMutex m_cacheMutex;
    
    // Constants
    static constexpr int THUMBNAIL_SIZE = 120;
    static constexpr int LIST_ITEM_HEIGHT = 24;
    static constexpr int DETAIL_ROW_HEIGHT = 20;
    static constexpr int MAX_CONCURRENT_THUMBNAILS = 4;
    
    // Professional styling
    QColor m_backgroundColor = QColor(35, 35, 35);
    QColor m_binTreeColor = QColor(45, 45, 45);
    QColor m_mediaViewColor = QColor(40, 40, 40);
    QColor m_selectedColor = QColor(70, 130, 180);
    QColor m_offlineColor = QColor(180, 70, 70);
    QFont m_binFont = QFont("Arial", 9);
    QFont m_mediaFont = QFont("Arial", 8);
    QFont m_statusFont = QFont("Arial", 7);
};