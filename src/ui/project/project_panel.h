#pragma once

#include <QWidget>
#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QTreeWidget>
#include <QTreeWidgetItem>
#include <QLabel>
#include <QPushButton>
#include <QLineEdit>
#include <QComboBox>
#include <QSpinBox>
#include <QGroupBox>
#include <QFormLayout>
#include <QProgressBar>
#include <QTextEdit>
#include <QDateTimeEdit>
#include <QCheckBox>
#include <QSplitter>
#include <QScrollArea>
#include <QTabWidget>
#include <QTableWidget>
#include <QHeaderView>
#include <QMenu>
#include <QAction>
#include <QTimer>
#include <QFileDialog>
#include <QMessageBox>

#include "core/models/project.h"
#include "core/models/sequence.h"
#include "core/commands/command_dispatcher.h"

/**
 * Professional project panel for project management and organization
 * 
 * Features:
 * - Project overview and metadata editing
 * - Sequence management and organization
 * - Project settings and preferences
 * - Timeline and export settings
 * - Recent projects and templates
 * - Project statistics and analytics
 * - Collaboration and sharing controls
 * - Project backup and archival tools
 * - Professional project organization similar to Avid/FCP7/Resolve
 * 
 * Design follows professional NLE project management patterns
 */
class ProjectPanel : public QWidget
{
    Q_OBJECT

public:
    explicit ProjectPanel(QWidget* parent = nullptr);
    ~ProjectPanel() = default;

    // Core functionality
    void setCommandDispatcher(CommandDispatcher* dispatcher);
    void setProject(const Project& project);
    void refreshProject();
    
    // Project management
    void newProject();
    void openProject();
    void saveProject();
    void saveProjectAs();
    void closeProject();
    void recentProjects();
    
    // Sequence management
    void createSequence();
    void deleteSequence(const QString& sequenceId);
    void renameSequence(const QString& sequenceId, const QString& newName);
    void duplicateSequence(const QString& sequenceId);
    void setSequenceSettings(const QString& sequenceId);
    
    // Project settings
    void editProjectSettings();
    void editTimelineSettings();
    void editExportSettings();
    void editCollaborationSettings();
    
    // Project operations
    void archiveProject();
    void exportProject();
    void importProjectData();
    void trimProject();
    void validateProject();

signals:
    void projectChanged(const Project& project);
    void sequenceSelected(const QString& sequenceId);
    void sequenceCreated(const QString& sequenceId, const QString& name);
    void sequenceDeleted(const QString& sequenceId);
    void projectSettingsChanged();
    void exportRequested(const QString& exportType);

public slots:
    void onProjectDataChanged();
    void onSequenceAdded(const QString& sequenceId);
    void onSequenceRemoved(const QString& sequenceId);
    void onProjectSaved();
    void onProjectModified(bool modified);

private slots:
    void onSequenceSelectionChanged();
    void onSequenceDoubleClicked(QTreeWidgetItem* item, int column);
    void onCreateSequenceClicked();
    void onDeleteSequenceClicked();
    void onRenameSequenceClicked();
    void onDuplicateSequenceClicked();
    void onSequenceSettingsClicked();
    void onProjectSettingsClicked();
    void onExportClicked();
    void onArchiveClicked();
    void onValidateClicked();
    void onProjectInfoChanged();
    void onRefreshStatistics();

private:
    // Setup methods
    void setupUI();
    void setupProjectInfo();
    void setupSequenceList();
    void setupProjectSettings();
    void setupProjectStatistics();
    void setupToolbar();
    void connectSignals();
    
    // Project info management
    void loadProjectInfo();
    void saveProjectInfo();
    void updateProjectDisplay();
    void validateProjectInfo();
    
    // Sequence list management
    void loadSequenceList();
    void updateSequenceList();
    void populateSequenceTree();
    QTreeWidgetItem* createSequenceItem(const Sequence& sequence);
    void updateSequenceItem(QTreeWidgetItem* item, const Sequence& sequence);
    
    // Settings management
    void loadProjectSettings();
    void saveProjectSettings();
    void resetSettingsToDefaults();
    void importSettingsFromTemplate();
    void exportSettingsAsTemplate();
    
    // Statistics and analytics
    void calculateProjectStatistics();
    void updateStatisticsDisplay();
    void generateProjectReport();
    
    // Context menus
    QMenu* createSequenceContextMenu(const QString& sequenceId);
    QMenu* createProjectContextMenu();
    
    // Validation and cleanup
    bool validateProjectData();
    void cleanupTempFiles();
    void optimizeProjectDatabase();
    
    // Utility methods
    QString formatProjectDuration(qint64 durationMs) const;
    QString formatProjectSize(qint64 bytes) const;
    QString formatSequenceInfo(const Sequence& sequence) const;
    QIcon getSequenceTypeIcon(const Sequence& sequence) const;
    
private:
    // Core components
    CommandDispatcher* m_commandDispatcher = nullptr;
    Project m_project;
    
    // UI layout
    QVBoxLayout* m_mainLayout = nullptr;
    QHBoxLayout* m_toolbarLayout = nullptr;
    QTabWidget* m_tabWidget = nullptr;
    
    // Toolbar components
    QPushButton* m_newProjectButton = nullptr;
    QPushButton* m_openProjectButton = nullptr;
    QPushButton* m_saveProjectButton = nullptr;
    QPushButton* m_exportButton = nullptr;
    QPushButton* m_settingsButton = nullptr;
    
    // Project Info tab
    QWidget* m_projectInfoTab = nullptr;
    QScrollArea* m_projectInfoScroll = nullptr;
    QGroupBox* m_projectDetailsGroup = nullptr;
    QFormLayout* m_projectDetailsLayout = nullptr;
    QLineEdit* m_projectNameEdit = nullptr;
    QTextEdit* m_projectDescriptionEdit = nullptr;
    QLineEdit* m_projectLocationEdit = nullptr;
    QComboBox* m_projectFormatCombo = nullptr;
    QDateTimeEdit* m_projectCreatedEdit = nullptr;
    QDateTimeEdit* m_projectModifiedEdit = nullptr;
    QLineEdit* m_projectAuthorEdit = nullptr;
    QLineEdit* m_projectCompanyEdit = nullptr;
    
    // Sequences tab
    QWidget* m_sequencesTab = nullptr;
    QVBoxLayout* m_sequencesLayout = nullptr;
    QHBoxLayout* m_sequenceButtonsLayout = nullptr;
    QTreeWidget* m_sequenceTree = nullptr;
    QPushButton* m_createSequenceButton = nullptr;
    QPushButton* m_deleteSequenceButton = nullptr;
    QPushButton* m_renameSequenceButton = nullptr;
    QPushButton* m_duplicateSequenceButton = nullptr;
    QPushButton* m_sequenceSettingsButton = nullptr;
    QLabel* m_sequenceCountLabel = nullptr;
    
    // Settings tab
    QWidget* m_settingsTab = nullptr;
    QScrollArea* m_settingsScroll = nullptr;
    QGroupBox* m_timelineSettingsGroup = nullptr;
    QGroupBox* m_exportSettingsGroup = nullptr;
    QGroupBox* m_collaborationSettingsGroup = nullptr;
    QComboBox* m_defaultFrameRateCombo = nullptr;
    QComboBox* m_defaultResolutionCombo = nullptr;
    QComboBox* m_defaultAudioRateCombo = nullptr;
    QSpinBox* m_undoLevelsSpinBox = nullptr;
    QCheckBox* m_autoSaveCheckBox = nullptr;
    QSpinBox* m_autoSaveIntervalSpinBox = nullptr;
    QLineEdit* m_scratchDiskEdit = nullptr;
    QPushButton* m_scratchDiskBrowseButton = nullptr;
    
    // Statistics tab
    QWidget* m_statisticsTab = nullptr;
    QScrollArea* m_statisticsScroll = nullptr;
    QGroupBox* m_projectStatsGroup = nullptr;
    QGroupBox* m_mediaStatsGroup = nullptr;
    QGroupBox* m_performanceStatsGroup = nullptr;
    QLabel* m_totalSequencesLabel = nullptr;
    QLabel* m_totalDurationLabel = nullptr;
    QLabel* m_totalMediaFilesLabel = nullptr;
    QLabel* m_totalProjectSizeLabel = nullptr;
    QLabel* m_unusedMediaLabel = nullptr;
    QLabel* m_offlineMediaLabel = nullptr;
    QProgressBar* m_projectHealthBar = nullptr;
    QPushButton* m_refreshStatsButton = nullptr;
    QPushButton* m_generateReportButton = nullptr;
    QPushButton* m_validateProjectButton = nullptr;
    
    // Current state
    QString m_selectedSequenceId;
    bool m_projectModified = false;
    QTimer* m_autoSaveTimer = nullptr;
    QTimer* m_statisticsTimer = nullptr;
    
    // Project statistics
    struct ProjectStatistics {
        int totalSequences = 0;
        qint64 totalDuration = 0;
        int totalMediaFiles = 0;
        qint64 totalProjectSize = 0;
        int unusedMediaFiles = 0;
        int offlineMediaFiles = 0;
        double projectHealth = 100.0;
    } m_statistics;
    
    // Constants
    static constexpr int AUTO_SAVE_INTERVAL_MS = 300000; // 5 minutes
    static constexpr int STATISTICS_REFRESH_MS = 30000;  // 30 seconds
    static constexpr int MAX_RECENT_PROJECTS = 10;
    
    // Professional styling
    QColor m_backgroundColor = QColor(40, 40, 40);
    QColor m_groupBoxColor = QColor(50, 50, 50);
    QColor m_selectedColor = QColor(70, 130, 180);
    QColor m_modifiedColor = QColor(255, 165, 0);
    QColor m_errorColor = QColor(180, 70, 70);
    QFont m_headerFont = QFont("Arial", 10, QFont::Bold);
    QFont m_contentFont = QFont("Arial", 9);
    QFont m_statisticsFont = QFont("Arial", 8);
};