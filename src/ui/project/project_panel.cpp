#include "project_panel.h"
#include <QLoggingCategory>
#include <QStandardPaths>
#include <QInputDialog>
#include <QApplication>
#include <QDesktopServices>
#include <QUrl>
#include <QDateTime>
#include <QFileInfo>
#include <QDir>

Q_LOGGING_CATEGORY(jveProjectPanel, "jve.ui.project")

ProjectPanel::ProjectPanel(QWidget* parent)
    : QWidget(parent)
{
    setupUI();
    setupProjectInfo();
    setupSequenceList();
    setupProjectSettings();
    setupProjectStatistics();
    setupToolbar();
    connectSignals();
    
    // Initialize auto-save timer
    m_autoSaveTimer = new QTimer(this);
    m_autoSaveTimer->setInterval(AUTO_SAVE_INTERVAL_MS);
    m_autoSaveTimer->setSingleShot(false);
    connect(m_autoSaveTimer, &QTimer::timeout, this, &ProjectPanel::saveProject);
    
    // Initialize statistics timer
    m_statisticsTimer = new QTimer(this);
    m_statisticsTimer->setInterval(STATISTICS_REFRESH_MS);
    m_statisticsTimer->setSingleShot(false);
    connect(m_statisticsTimer, &QTimer::timeout, this, &ProjectPanel::onRefreshStatistics);
    
    qCDebug(jveProjectPanel, "Project panel initialized");
}

void ProjectPanel::setupUI()
{
    m_mainLayout = new QVBoxLayout(this);
    m_mainLayout->setContentsMargins(4, 4, 4, 4);
    m_mainLayout->setSpacing(2);
    
    // Create tab widget
    m_tabWidget = new QTabWidget(this);
    m_tabWidget->setTabPosition(QTabWidget::North);
    m_mainLayout->addWidget(m_tabWidget);
    
    // Apply professional styling
    setStyleSheet(QString(
        "QTabWidget::pane { border: 1px solid #333; background: %1; }"
        "QTabBar::tab { background: %2; padding: 6px 12px; margin-right: 2px; }"
        "QTabBar::tab:selected { background: %3; }"
        "QGroupBox { font-weight: bold; border: 1px solid #444; margin: 8px 0; padding-top: 12px; }"
        "QGroupBox::title { subcontrol-origin: margin; left: 8px; padding: 0 4px; }"
        "QLineEdit, QTextEdit { background: #333; border: 1px solid #555; padding: 4px; }"
        "QComboBox, QSpinBox, QDateTimeEdit { background: #333; border: 1px solid #555; padding: 4px; }"
        "QPushButton { background: #444; border: 1px solid #666; padding: 6px 12px; }"
        "QPushButton:hover { background: #555; }"
        "QPushButton:pressed { background: #333; }"
        "QTreeWidget { background: %1; border: 1px solid #444; selection-background-color: %4; }"
        "QProgressBar { border: 1px solid #555; background: #333; }"
        "QProgressBar::chunk { background: %4; }"
    ).arg(m_backgroundColor.name())
     .arg(m_groupBoxColor.name())
     .arg(m_groupBoxColor.lighter(120).name())
     .arg(m_selectedColor.name()));
}

void ProjectPanel::setupProjectInfo()
{
    m_projectInfoTab = new QWidget();
    m_projectInfoScroll = new QScrollArea();
    m_projectInfoScroll->setWidget(m_projectInfoTab);
    m_projectInfoScroll->setWidgetResizable(true);
    m_projectInfoScroll->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    
    QVBoxLayout* infoLayout = new QVBoxLayout(m_projectInfoTab);
    infoLayout->setContentsMargins(8, 8, 8, 8);
    infoLayout->setSpacing(8);
    
    // Project details group
    m_projectDetailsGroup = new QGroupBox("Project Details");
    m_projectDetailsLayout = new QFormLayout(m_projectDetailsGroup);
    
    m_projectNameEdit = new QLineEdit();
    m_projectDetailsLayout->addRow("Name:", m_projectNameEdit);
    
    m_projectDescriptionEdit = new QTextEdit();
    m_projectDescriptionEdit->setMaximumHeight(80);
    m_projectDetailsLayout->addRow("Description:", m_projectDescriptionEdit);
    
    m_projectLocationEdit = new QLineEdit();
    m_projectLocationEdit->setReadOnly(true);
    m_projectDetailsLayout->addRow("Location:", m_projectLocationEdit);
    
    m_projectFormatCombo = new QComboBox();
    m_projectFormatCombo->addItems({"1080p 23.98", "1080p 24", "1080p 25", "1080p 29.97", "1080p 30", 
                                   "4K 23.98", "4K 24", "4K 25", "4K 29.97", "4K 30"});
    m_projectDetailsLayout->addRow("Format:", m_projectFormatCombo);
    
    m_projectCreatedEdit = new QDateTimeEdit();
    m_projectCreatedEdit->setReadOnly(true);
    m_projectCreatedEdit->setDisplayFormat("yyyy-MM-dd hh:mm:ss");
    m_projectDetailsLayout->addRow("Created:", m_projectCreatedEdit);
    
    m_projectModifiedEdit = new QDateTimeEdit();
    m_projectModifiedEdit->setReadOnly(true);
    m_projectModifiedEdit->setDisplayFormat("yyyy-MM-dd hh:mm:ss");
    m_projectDetailsLayout->addRow("Modified:", m_projectModifiedEdit);
    
    m_projectAuthorEdit = new QLineEdit();
    m_projectDetailsLayout->addRow("Author:", m_projectAuthorEdit);
    
    m_projectCompanyEdit = new QLineEdit();
    m_projectDetailsLayout->addRow("Company:", m_projectCompanyEdit);
    
    infoLayout->addWidget(m_projectDetailsGroup);
    infoLayout->addStretch();
    
    m_tabWidget->addTab(m_projectInfoScroll, "Project Info");
}

void ProjectPanel::setupSequenceList()
{
    m_sequencesTab = new QWidget();
    m_sequencesLayout = new QVBoxLayout(m_sequencesTab);
    m_sequencesLayout->setContentsMargins(8, 8, 8, 8);
    m_sequencesLayout->setSpacing(4);
    
    // Sequence buttons
    m_sequenceButtonsLayout = new QHBoxLayout();
    m_sequenceButtonsLayout->setSpacing(4);
    
    m_createSequenceButton = new QPushButton("Create");
    m_createSequenceButton->setToolTip("Create New Sequence");
    m_sequenceButtonsLayout->addWidget(m_createSequenceButton);
    
    m_deleteSequenceButton = new QPushButton("Delete");
    m_deleteSequenceButton->setToolTip("Delete Selected Sequence");
    m_deleteSequenceButton->setEnabled(false);
    m_sequenceButtonsLayout->addWidget(m_deleteSequenceButton);
    
    m_renameSequenceButton = new QPushButton("Rename");
    m_renameSequenceButton->setToolTip("Rename Selected Sequence");
    m_renameSequenceButton->setEnabled(false);
    m_sequenceButtonsLayout->addWidget(m_renameSequenceButton);
    
    m_duplicateSequenceButton = new QPushButton("Duplicate");
    m_duplicateSequenceButton->setToolTip("Duplicate Selected Sequence");
    m_duplicateSequenceButton->setEnabled(false);
    m_sequenceButtonsLayout->addWidget(m_duplicateSequenceButton);
    
    m_sequenceSettingsButton = new QPushButton("Settings");
    m_sequenceSettingsButton->setToolTip("Sequence Settings");
    m_sequenceSettingsButton->setEnabled(false);
    m_sequenceButtonsLayout->addWidget(m_sequenceSettingsButton);
    
    m_sequenceButtonsLayout->addStretch();
    m_sequencesLayout->addLayout(m_sequenceButtonsLayout);
    
    // Sequence tree
    m_sequenceTree = new QTreeWidget();
    m_sequenceTree->setHeaderLabels({"Name", "Format", "Duration", "Tracks", "Modified"});
    m_sequenceTree->setSelectionMode(QAbstractItemView::SingleSelection);
    m_sequenceTree->setContextMenuPolicy(Qt::CustomContextMenu);
    m_sequenceTree->setRootIsDecorated(false);
    m_sequenceTree->setAlternatingRowColors(true);
    m_sequencesLayout->addWidget(m_sequenceTree);
    
    // Sequence count label
    m_sequenceCountLabel = new QLabel("0 sequences");
    m_sequenceCountLabel->setFont(m_statisticsFont);
    m_sequenceCountLabel->setAlignment(Qt::AlignRight);
    m_sequencesLayout->addWidget(m_sequenceCountLabel);
    
    m_tabWidget->addTab(m_sequencesTab, "Sequences");
}

void ProjectPanel::setupProjectSettings()
{
    m_settingsTab = new QWidget();
    m_settingsScroll = new QScrollArea();
    m_settingsScroll->setWidget(m_settingsTab);
    m_settingsScroll->setWidgetResizable(true);
    m_settingsScroll->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    
    QVBoxLayout* settingsLayout = new QVBoxLayout(m_settingsTab);
    settingsLayout->setContentsMargins(8, 8, 8, 8);
    settingsLayout->setSpacing(8);
    
    // Timeline settings group
    m_timelineSettingsGroup = new QGroupBox("Timeline Settings");
    QFormLayout* timelineLayout = new QFormLayout(m_timelineSettingsGroup);
    
    m_defaultFrameRateCombo = new QComboBox();
    m_defaultFrameRateCombo->addItems({"23.98", "24", "25", "29.97", "30", "50", "59.94", "60"});
    timelineLayout->addRow("Default Frame Rate:", m_defaultFrameRateCombo);
    
    m_defaultResolutionCombo = new QComboBox();
    m_defaultResolutionCombo->addItems({"1920x1080", "3840x2160", "1280x720", "720x480", "720x576"});
    timelineLayout->addRow("Default Resolution:", m_defaultResolutionCombo);
    
    m_defaultAudioRateCombo = new QComboBox();
    m_defaultAudioRateCombo->addItems({"48000 Hz", "44100 Hz", "96000 Hz"});
    timelineLayout->addRow("Default Audio Rate:", m_defaultAudioRateCombo);
    
    m_undoLevelsSpinBox = new QSpinBox();
    m_undoLevelsSpinBox->setRange(10, 1000);
    m_undoLevelsSpinBox->setValue(100);
    timelineLayout->addRow("Undo Levels:", m_undoLevelsSpinBox);
    
    settingsLayout->addWidget(m_timelineSettingsGroup);
    
    // Export settings group
    m_exportSettingsGroup = new QGroupBox("Export Settings");
    QFormLayout* exportLayout = new QFormLayout(m_exportSettingsGroup);
    
    QHBoxLayout* scratchDiskLayout = new QHBoxLayout();
    m_scratchDiskEdit = new QLineEdit();
    m_scratchDiskBrowseButton = new QPushButton("Browse");
    scratchDiskLayout->addWidget(m_scratchDiskEdit, 1);
    scratchDiskLayout->addWidget(m_scratchDiskBrowseButton);
    exportLayout->addRow("Scratch Disk:", scratchDiskLayout);
    
    settingsLayout->addWidget(m_exportSettingsGroup);
    
    // Collaboration settings group
    m_collaborationSettingsGroup = new QGroupBox("Collaboration Settings");
    QFormLayout* collaborationLayout = new QFormLayout(m_collaborationSettingsGroup);
    
    m_autoSaveCheckBox = new QCheckBox();
    m_autoSaveCheckBox->setChecked(true);
    collaborationLayout->addRow("Auto Save:", m_autoSaveCheckBox);
    
    m_autoSaveIntervalSpinBox = new QSpinBox();
    m_autoSaveIntervalSpinBox->setRange(1, 60);
    m_autoSaveIntervalSpinBox->setValue(5);
    m_autoSaveIntervalSpinBox->setSuffix(" minutes");
    collaborationLayout->addRow("Auto Save Interval:", m_autoSaveIntervalSpinBox);
    
    settingsLayout->addWidget(m_collaborationSettingsGroup);
    settingsLayout->addStretch();
    
    m_tabWidget->addTab(m_settingsScroll, "Settings");
}

void ProjectPanel::setupProjectStatistics()
{
    m_statisticsTab = new QWidget();
    m_statisticsScroll = new QScrollArea();
    m_statisticsScroll->setWidget(m_statisticsTab);
    m_statisticsScroll->setWidgetResizable(true);
    m_statisticsScroll->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    
    QVBoxLayout* statsLayout = new QVBoxLayout(m_statisticsTab);
    statsLayout->setContentsMargins(8, 8, 8, 8);
    statsLayout->setSpacing(8);
    
    // Project statistics group
    m_projectStatsGroup = new QGroupBox("Project Statistics");
    QFormLayout* projectStatsLayout = new QFormLayout(m_projectStatsGroup);
    
    m_totalSequencesLabel = new QLabel("0");
    m_totalSequencesLabel->setFont(m_statisticsFont);
    projectStatsLayout->addRow("Total Sequences:", m_totalSequencesLabel);
    
    m_totalDurationLabel = new QLabel("00:00:00");
    m_totalDurationLabel->setFont(m_statisticsFont);
    projectStatsLayout->addRow("Total Duration:", m_totalDurationLabel);
    
    m_totalProjectSizeLabel = new QLabel("0 MB");
    m_totalProjectSizeLabel->setFont(m_statisticsFont);
    projectStatsLayout->addRow("Project Size:", m_totalProjectSizeLabel);
    
    statsLayout->addWidget(m_projectStatsGroup);
    
    // Media statistics group
    m_mediaStatsGroup = new QGroupBox("Media Statistics");
    QFormLayout* mediaStatsLayout = new QFormLayout(m_mediaStatsGroup);
    
    m_totalMediaFilesLabel = new QLabel("0");
    m_totalMediaFilesLabel->setFont(m_statisticsFont);
    mediaStatsLayout->addRow("Total Media Files:", m_totalMediaFilesLabel);
    
    m_unusedMediaLabel = new QLabel("0");
    m_unusedMediaLabel->setFont(m_statisticsFont);
    mediaStatsLayout->addRow("Unused Media:", m_unusedMediaLabel);
    
    m_offlineMediaLabel = new QLabel("0");
    m_offlineMediaLabel->setFont(m_statisticsFont);
    mediaStatsLayout->addRow("Offline Media:", m_offlineMediaLabel);
    
    statsLayout->addWidget(m_mediaStatsGroup);
    
    // Performance statistics group
    m_performanceStatsGroup = new QGroupBox("Project Health");
    QVBoxLayout* performanceLayout = new QVBoxLayout(m_performanceStatsGroup);
    
    QLabel* healthLabel = new QLabel("Overall Health:");
    healthLabel->setFont(m_statisticsFont);
    performanceLayout->addWidget(healthLabel);
    
    m_projectHealthBar = new QProgressBar();
    m_projectHealthBar->setRange(0, 100);
    m_projectHealthBar->setValue(100);
    m_projectHealthBar->setTextVisible(true);
    performanceLayout->addWidget(m_projectHealthBar);
    
    statsLayout->addWidget(m_performanceStatsGroup);
    
    // Action buttons
    QHBoxLayout* statsButtonsLayout = new QHBoxLayout();
    
    m_refreshStatsButton = new QPushButton("Refresh");
    m_refreshStatsButton->setToolTip("Refresh Statistics");
    statsButtonsLayout->addWidget(m_refreshStatsButton);
    
    m_generateReportButton = new QPushButton("Generate Report");
    m_generateReportButton->setToolTip("Generate Project Report");
    statsButtonsLayout->addWidget(m_generateReportButton);
    
    m_validateProjectButton = new QPushButton("Validate");
    m_validateProjectButton->setToolTip("Validate Project Integrity");
    statsButtonsLayout->addWidget(m_validateProjectButton);
    
    statsButtonsLayout->addStretch();
    statsLayout->addLayout(statsButtonsLayout);
    statsLayout->addStretch();
    
    m_tabWidget->addTab(m_statisticsScroll, "Statistics");
}

void ProjectPanel::setupToolbar()
{
    m_toolbarLayout = new QHBoxLayout();
    m_toolbarLayout->setContentsMargins(0, 0, 0, 0);
    m_toolbarLayout->setSpacing(4);
    
    m_newProjectButton = new QPushButton("New");
    m_newProjectButton->setToolTip("New Project");
    m_toolbarLayout->addWidget(m_newProjectButton);
    
    m_openProjectButton = new QPushButton("Open");
    m_openProjectButton->setToolTip("Open Project");
    m_toolbarLayout->addWidget(m_openProjectButton);
    
    m_saveProjectButton = new QPushButton("Save");
    m_saveProjectButton->setToolTip("Save Project");
    m_toolbarLayout->addWidget(m_saveProjectButton);
    
    m_toolbarLayout->addStretch();
    
    m_exportButton = new QPushButton("Export");
    m_exportButton->setToolTip("Export Project");
    m_toolbarLayout->addWidget(m_exportButton);
    
    m_settingsButton = new QPushButton("Settings");
    m_settingsButton->setToolTip("Project Settings");
    m_toolbarLayout->addWidget(m_settingsButton);
    
    // Insert toolbar at top
    m_mainLayout->insertLayout(0, m_toolbarLayout);
}

void ProjectPanel::connectSignals()
{
    // Toolbar buttons
    connect(m_newProjectButton, &QPushButton::clicked, this, &ProjectPanel::newProject);
    connect(m_openProjectButton, &QPushButton::clicked, this, &ProjectPanel::openProject);
    connect(m_saveProjectButton, &QPushButton::clicked, this, &ProjectPanel::saveProject);
    connect(m_exportButton, &QPushButton::clicked, this, &ProjectPanel::onExportClicked);
    connect(m_settingsButton, &QPushButton::clicked, this, &ProjectPanel::onProjectSettingsClicked);
    
    // Project info changes
    connect(m_projectNameEdit, &QLineEdit::textChanged, this, &ProjectPanel::onProjectInfoChanged);
    connect(m_projectDescriptionEdit, &QTextEdit::textChanged, this, &ProjectPanel::onProjectInfoChanged);
    connect(m_projectAuthorEdit, &QLineEdit::textChanged, this, &ProjectPanel::onProjectInfoChanged);
    connect(m_projectCompanyEdit, &QLineEdit::textChanged, this, &ProjectPanel::onProjectInfoChanged);
    
    // Sequence management
    connect(m_createSequenceButton, &QPushButton::clicked, this, &ProjectPanel::onCreateSequenceClicked);
    connect(m_deleteSequenceButton, &QPushButton::clicked, this, &ProjectPanel::onDeleteSequenceClicked);
    connect(m_renameSequenceButton, &QPushButton::clicked, this, &ProjectPanel::onRenameSequenceClicked);
    connect(m_duplicateSequenceButton, &QPushButton::clicked, this, &ProjectPanel::onDuplicateSequenceClicked);
    connect(m_sequenceSettingsButton, &QPushButton::clicked, this, &ProjectPanel::onSequenceSettingsClicked);
    
    connect(m_sequenceTree, &QTreeWidget::itemSelectionChanged, this, &ProjectPanel::onSequenceSelectionChanged);
    connect(m_sequenceTree, &QTreeWidget::itemDoubleClicked, this, &ProjectPanel::onSequenceDoubleClicked);
    connect(m_sequenceTree, &QTreeWidget::customContextMenuRequested, [this](const QPoint& pos) {
        QTreeWidgetItem* item = m_sequenceTree->itemAt(pos);
        if (item) {
            QString sequenceId = item->data(0, Qt::UserRole).toString();
            QMenu* menu = createSequenceContextMenu(sequenceId);
            menu->exec(m_sequenceTree->mapToGlobal(pos));
            menu->deleteLater();
        }
    });
    
    // Settings changes
    connect(m_scratchDiskBrowseButton, &QPushButton::clicked, [this]() {
        QString dir = QFileDialog::getExistingDirectory(this, "Select Scratch Disk Directory");
        if (!dir.isEmpty()) {
            m_scratchDiskEdit->setText(dir);
        }
    });
    
    connect(m_autoSaveCheckBox, &QCheckBox::toggled, [this](bool enabled) {
        if (enabled && m_autoSaveTimer) {
            m_autoSaveTimer->start();
        } else if (m_autoSaveTimer) {
            m_autoSaveTimer->stop();
        }
    });
    
    // Statistics buttons
    connect(m_refreshStatsButton, &QPushButton::clicked, this, &ProjectPanel::onRefreshStatistics);
    connect(m_generateReportButton, &QPushButton::clicked, [this]() {
        generateProjectReport();
    });
    connect(m_validateProjectButton, &QPushButton::clicked, this, &ProjectPanel::onValidateClicked);
}

void ProjectPanel::setCommandDispatcher(CommandDispatcher* dispatcher)
{
    m_commandDispatcher = dispatcher;
}

void ProjectPanel::setProject(const Project& project)
{
    m_project = project;
    loadProjectInfo();
    loadSequenceList();
    loadProjectSettings();
    calculateProjectStatistics();
    
    // Start timers if project is valid
    if (!m_project.id().isEmpty()) {
        if (m_autoSaveCheckBox->isChecked()) {
            m_autoSaveTimer->start();
        }
        m_statisticsTimer->start();
    }
    
    emit projectChanged(m_project);
}

void ProjectPanel::refreshProject()
{
    if (!m_project.id().isEmpty()) {
        loadSequenceList();
        calculateProjectStatistics();
        updateProjectDisplay();
    }
}

// Core functionality implementations
void ProjectPanel::newProject()
{
    qCDebug(jveProjectPanel, "Creating new project");
    // TODO: Implement new project creation
}

void ProjectPanel::openProject()
{
    QString filePath = QFileDialog::getOpenFileName(
        this,
        "Open Project",
        QStandardPaths::writableLocation(QStandardPaths::DocumentsLocation),
        "JVE Projects (*.jve);;All Files (*)"
    );
    
    if (!filePath.isEmpty()) {
        qCDebug(jveProjectPanel, "Opening project: %s", qPrintable(filePath));
        // TODO: Load project from file
    }
}

void ProjectPanel::saveProject()
{
    if (m_project.id().isEmpty()) {
        saveProjectAs();
        return;
    }
    
    qCDebug(jveProjectPanel, "Saving project: %s", qPrintable(m_project.name()));
    // TODO: Save project to database
    saveProjectInfo();
    saveProjectSettings();
    onProjectSaved();
}

void ProjectPanel::saveProjectAs()
{
    QString filePath = QFileDialog::getSaveFileName(
        this,
        "Save Project As",
        QStandardPaths::writableLocation(QStandardPaths::DocumentsLocation),
        "JVE Projects (*.jve)"
    );
    
    if (!filePath.isEmpty()) {
        qCDebug(jveProjectPanel, "Saving project as: %s", qPrintable(filePath));
        // TODO: Save project to new file
    }
}

void ProjectPanel::createSequence()
{
    bool ok;
    QString name = QInputDialog::getText(this, "Create Sequence", "Sequence name:", QLineEdit::Normal, "New Sequence", &ok);
    if (ok && !name.isEmpty()) {
        qCDebug(jveProjectPanel, "Creating sequence: %s", qPrintable(name));
        // TODO: Create sequence via command system
        QString sequenceId = QUuid::createUuid().toString(QUuid::WithoutBraces);
        emit sequenceCreated(sequenceId, name);
    }
}

// Project info management
void ProjectPanel::loadProjectInfo()
{
    if (m_project.id().isEmpty()) {
        // Clear all fields
        m_projectNameEdit->clear();
        m_projectDescriptionEdit->clear();
        m_projectLocationEdit->clear();
        m_projectCreatedEdit->setDateTime(QDateTime::currentDateTime());
        m_projectModifiedEdit->setDateTime(QDateTime::currentDateTime());
        m_projectAuthorEdit->clear();
        m_projectCompanyEdit->clear();
        return;
    }
    
    m_projectNameEdit->setText(m_project.name());
    m_projectDescriptionEdit->setPlainText(m_project.getSetting("description").toString());
    m_projectLocationEdit->setText(m_project.getSetting("location").toString());
    m_projectCreatedEdit->setDateTime(m_project.createdAt());
    m_projectModifiedEdit->setDateTime(m_project.modifiedAt());
    
    // TODO: Load additional project metadata
}

void ProjectPanel::saveProjectInfo()
{
    if (m_project.id().isEmpty()) return;
    
    // TODO: Save project info via command system
    qCDebug(jveProjectPanel, "Saving project info");
}

void ProjectPanel::loadSequenceList()
{
    m_sequenceTree->clear();
    
    if (m_project.id().isEmpty()) {
        m_sequenceCountLabel->setText("0 sequences");
        return;
    }
    
    // TODO: Load sequences from database
    // For now, create sample sequences
    QStringList sequenceNames = {"Main Timeline", "Rough Cut", "Final Cut"};
    
    for (const QString& name : sequenceNames) {
        QTreeWidgetItem* item = new QTreeWidgetItem();
        item->setText(0, name);
        item->setText(1, "1080p 23.98");
        item->setText(2, "00:05:30");
        item->setText(3, "V1 A1-2");
        item->setText(4, "2 hours ago");
        item->setData(0, Qt::UserRole, QUuid::createUuid().toString(QUuid::WithoutBraces));
        item->setIcon(0, QIcon()); // Would use sequence icon
        m_sequenceTree->addTopLevelItem(item);
    }
    
    m_sequenceCountLabel->setText(QString("%1 sequences").arg(m_sequenceTree->topLevelItemCount()));
}

void ProjectPanel::calculateProjectStatistics()
{
    if (m_project.id().isEmpty()) {
        m_statistics = ProjectStatistics();
        updateStatisticsDisplay();
        return;
    }
    
    // TODO: Calculate actual statistics from database
    m_statistics.totalSequences = m_sequenceTree->topLevelItemCount();
    m_statistics.totalDuration = 330000; // 5:30 in ms
    m_statistics.totalMediaFiles = 25;
    m_statistics.totalProjectSize = 1024 * 1024 * 1024; // 1GB
    m_statistics.unusedMediaFiles = 3;
    m_statistics.offlineMediaFiles = 1;
    m_statistics.projectHealth = 85.0;
    
    updateStatisticsDisplay();
}

void ProjectPanel::updateStatisticsDisplay()
{
    m_totalSequencesLabel->setText(QString::number(m_statistics.totalSequences));
    m_totalDurationLabel->setText(formatProjectDuration(m_statistics.totalDuration));
    m_totalMediaFilesLabel->setText(QString::number(m_statistics.totalMediaFiles));
    m_totalProjectSizeLabel->setText(formatProjectSize(m_statistics.totalProjectSize));
    m_unusedMediaLabel->setText(QString::number(m_statistics.unusedMediaFiles));
    m_offlineMediaLabel->setText(QString::number(m_statistics.offlineMediaFiles));
    m_projectHealthBar->setValue(static_cast<int>(m_statistics.projectHealth));
}

// Slot implementations
void ProjectPanel::onSequenceSelectionChanged()
{
    QList<QTreeWidgetItem*> selected = m_sequenceTree->selectedItems();
    bool hasSelection = !selected.isEmpty();
    
    m_deleteSequenceButton->setEnabled(hasSelection);
    m_renameSequenceButton->setEnabled(hasSelection);
    m_duplicateSequenceButton->setEnabled(hasSelection);
    m_sequenceSettingsButton->setEnabled(hasSelection);
    
    if (hasSelection) {
        m_selectedSequenceId = selected.first()->data(0, Qt::UserRole).toString();
        emit sequenceSelected(m_selectedSequenceId);
    } else {
        m_selectedSequenceId.clear();
    }
}

void ProjectPanel::onSequenceDoubleClicked(QTreeWidgetItem* item, int column)
{
    Q_UNUSED(column)
    if (item) {
        QString sequenceId = item->data(0, Qt::UserRole).toString();
        emit sequenceSelected(sequenceId);
    }
}

void ProjectPanel::onCreateSequenceClicked()
{
    createSequence();
}

void ProjectPanel::onDeleteSequenceClicked()
{
    if (!m_selectedSequenceId.isEmpty()) {
        QMessageBox::StandardButton reply = QMessageBox::question(
            this,
            "Delete Sequence",
            "Are you sure you want to delete this sequence?",
            QMessageBox::Yes | QMessageBox::No
        );
        
        if (reply == QMessageBox::Yes) {
            deleteSequence(m_selectedSequenceId);
        }
    }
}

void ProjectPanel::onRenameSequenceClicked()
{
    if (!m_selectedSequenceId.isEmpty()) {
        QList<QTreeWidgetItem*> selected = m_sequenceTree->selectedItems();
        if (!selected.isEmpty()) {
            QString currentName = selected.first()->text(0);
            bool ok;
            QString newName = QInputDialog::getText(this, "Rename Sequence", "New name:", QLineEdit::Normal, currentName, &ok);
            if (ok && !newName.isEmpty() && newName != currentName) {
                renameSequence(m_selectedSequenceId, newName);
            }
        }
    }
}

void ProjectPanel::onDuplicateSequenceClicked()
{
    if (!m_selectedSequenceId.isEmpty()) {
        duplicateSequence(m_selectedSequenceId);
    }
}

void ProjectPanel::onSequenceSettingsClicked()
{
    if (!m_selectedSequenceId.isEmpty()) {
        setSequenceSettings(m_selectedSequenceId);
    }
}

void ProjectPanel::onProjectSettingsClicked()
{
    m_tabWidget->setCurrentIndex(2); // Switch to settings tab
}

void ProjectPanel::onExportClicked()
{
    emit exportRequested("video");
}

void ProjectPanel::onArchiveClicked()
{
    archiveProject();
}

void ProjectPanel::onValidateClicked()
{
    validateProject();
}

void ProjectPanel::onProjectInfoChanged()
{
    onProjectModified(true);
}

void ProjectPanel::onRefreshStatistics()
{
    calculateProjectStatistics();
}

void ProjectPanel::onProjectDataChanged()
{
    refreshProject();
}

void ProjectPanel::onSequenceAdded(const QString& sequenceId)
{
    Q_UNUSED(sequenceId)
    loadSequenceList();
}

void ProjectPanel::onSequenceRemoved(const QString& sequenceId)
{
    Q_UNUSED(sequenceId)
    loadSequenceList();
}

void ProjectPanel::onProjectSaved()
{
    m_projectModified = false;
    m_projectModifiedEdit->setDateTime(QDateTime::currentDateTime());
    qCDebug(jveProjectPanel, "Project saved successfully");
}

void ProjectPanel::onProjectModified(bool modified)
{
    m_projectModified = modified;
    if (modified && !m_project.id().isEmpty()) {
        // Auto-save if enabled
        if (m_autoSaveCheckBox->isChecked() && m_autoSaveTimer && !m_autoSaveTimer->isActive()) {
            m_autoSaveTimer->start();
        }
    }
}

QMenu* ProjectPanel::createSequenceContextMenu(const QString& sequenceId)
{
    QMenu* menu = new QMenu(this);
    
    menu->addAction("Open", [this, sequenceId]() {
        emit sequenceSelected(sequenceId);
    });
    
    menu->addSeparator();
    
    menu->addAction("Rename", [this, sequenceId]() {
        m_selectedSequenceId = sequenceId;
        onRenameSequenceClicked();
    });
    
    menu->addAction("Duplicate", [this, sequenceId]() {
        duplicateSequence(sequenceId);
    });
    
    menu->addAction("Settings", [this, sequenceId]() {
        setSequenceSettings(sequenceId);
    });
    
    menu->addSeparator();
    
    menu->addAction("Delete", [this, sequenceId]() {
        m_selectedSequenceId = sequenceId;
        onDeleteSequenceClicked();
    });
    
    return menu;
}

// Utility methods
QString ProjectPanel::formatProjectDuration(qint64 durationMs) const
{
    qint64 seconds = durationMs / 1000;
    qint64 minutes = seconds / 60;
    qint64 hours = minutes / 60;
    
    return QString("%1:%2:%3")
        .arg(hours, 2, 10, QChar('0'))
        .arg(minutes % 60, 2, 10, QChar('0'))
        .arg(seconds % 60, 2, 10, QChar('0'));
}

QString ProjectPanel::formatProjectSize(qint64 bytes) const
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

// Placeholder implementations
void ProjectPanel::closeProject() {}
void ProjectPanel::recentProjects() {}
void ProjectPanel::deleteSequence(const QString&) {}
void ProjectPanel::renameSequence(const QString&, const QString&) {}
void ProjectPanel::duplicateSequence(const QString&) {}
void ProjectPanel::setSequenceSettings(const QString&) {}
void ProjectPanel::editProjectSettings() {}
void ProjectPanel::editTimelineSettings() {}
void ProjectPanel::editExportSettings() {}
void ProjectPanel::editCollaborationSettings() {}
void ProjectPanel::archiveProject() {}
void ProjectPanel::exportProject() {}
void ProjectPanel::importProjectData() {}
void ProjectPanel::trimProject() {}
void ProjectPanel::validateProject() {}
void ProjectPanel::updateProjectDisplay() {}
void ProjectPanel::validateProjectInfo() {}
void ProjectPanel::updateSequenceList() {}
void ProjectPanel::populateSequenceTree() {}
QTreeWidgetItem* ProjectPanel::createSequenceItem(const Sequence&) { return nullptr; }
void ProjectPanel::updateSequenceItem(QTreeWidgetItem*, const Sequence&) {}
void ProjectPanel::loadProjectSettings() {}
void ProjectPanel::saveProjectSettings() {}
void ProjectPanel::resetSettingsToDefaults() {}
void ProjectPanel::importSettingsFromTemplate() {}
void ProjectPanel::exportSettingsAsTemplate() {}
void ProjectPanel::generateProjectReport() {}
QMenu* ProjectPanel::createProjectContextMenu() { return nullptr; }
bool ProjectPanel::validateProjectData() { return true; }
void ProjectPanel::cleanupTempFiles() {}
void ProjectPanel::optimizeProjectDatabase() {}
QString ProjectPanel::formatSequenceInfo(const Sequence&) const { return QString(); }
QIcon ProjectPanel::getSequenceTypeIcon(const Sequence&) const { return QIcon(); }