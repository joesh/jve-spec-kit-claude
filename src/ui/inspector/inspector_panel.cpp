#include "inspector_panel.h"
#include <QLoggingCategory>
#include <QColorDialog>
#include <QFileDialog>
#include <QMessageBox>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonArray>

Q_LOGGING_CATEGORY(jveInspectorPanel, "jve.ui.inspector")

InspectorPanel::InspectorPanel(QWidget* parent)
    : QWidget(parent)
{
    setupUI();
    setupTabs();
    connectSignals();
    
    // Set initial state
    clearSelection();
    
    qCDebug(jveInspectorPanel, "Inspector panel initialized");
}

void InspectorPanel::setupUI()
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
        "QSlider::groove:horizontal { height: 4px; background: #444; }"
        "QSlider::handle:horizontal { width: 12px; height: 12px; background: %4; border-radius: 6px; }"
        "QSpinBox, QDoubleSpinBox, QLineEdit { background: #333; border: 1px solid #555; padding: 2px; }"
        "QCheckBox::indicator { width: 14px; height: 14px; }"
        "QCheckBox::indicator:checked { background: %4; }"
    ).arg(m_backgroundColor.name())
     .arg(m_groupBoxColor.name())
     .arg(m_groupBoxColor.lighter(120).name())
     .arg(m_sliderColor.name()));
}

void InspectorPanel::setupTabs()
{
    setupVideoTab();
    setupAudioTab();
    setupColorTab();
    setupMotionTab();
    setupEffectsTab();
}

void InspectorPanel::setupVideoTab()
{
    m_videoTab = new QWidget();
    m_videoScrollArea = new QScrollArea();
    m_videoScrollArea->setWidget(m_videoTab);
    m_videoScrollArea->setWidgetResizable(true);
    m_videoScrollArea->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    
    QVBoxLayout* videoLayout = new QVBoxLayout(m_videoTab);
    videoLayout->setContentsMargins(8, 8, 8, 8);
    videoLayout->setSpacing(4);
    
    // Transform group
    m_transformGroup = new QGroupBox("Transform");
    QFormLayout* transformLayout = new QFormLayout(m_transformGroup);
    
    transformLayout->addRow("Scale X:", createSliderProperty("scale_x", 0.0, 500.0, DEFAULT_SCALE));
    transformLayout->addRow("Scale Y:", createSliderProperty("scale_y", 0.0, 500.0, DEFAULT_SCALE));
    transformLayout->addRow("Rotation:", createSliderProperty("rotation", -360.0, 360.0, DEFAULT_ROTATION));
    transformLayout->addRow("Position X:", createSliderProperty("position_x", -1000.0, 1000.0, DEFAULT_POSITION));
    transformLayout->addRow("Position Y:", createSliderProperty("position_y", -1000.0, 1000.0, DEFAULT_POSITION));
    
    videoLayout->addWidget(m_transformGroup);
    
    // Crop group
    m_cropGroup = new QGroupBox("Crop");
    QFormLayout* cropLayout = new QFormLayout(m_cropGroup);
    
    cropLayout->addRow("Left:", createSliderProperty("crop_left", 0.0, 100.0, 0.0));
    cropLayout->addRow("Right:", createSliderProperty("crop_right", 0.0, 100.0, 0.0));
    cropLayout->addRow("Top:", createSliderProperty("crop_top", 0.0, 100.0, 0.0));
    cropLayout->addRow("Bottom:", createSliderProperty("crop_bottom", 0.0, 100.0, 0.0));
    
    videoLayout->addWidget(m_cropGroup);
    
    // Opacity group
    m_opacityGroup = new QGroupBox("Opacity");
    QFormLayout* opacityLayout = new QFormLayout(m_opacityGroup);
    
    opacityLayout->addRow("Opacity:", createSliderProperty("opacity", 0.0, 100.0, DEFAULT_OPACITY));
    opacityLayout->addRow("Blend Mode:", createComboProperty("blend_mode", 
        {"Normal", "Multiply", "Screen", "Overlay", "Soft Light", "Hard Light", "Color Dodge", "Color Burn"}, 0));
    
    videoLayout->addWidget(m_opacityGroup);
    
    videoLayout->addStretch();
    
    m_tabWidget->addTab(m_videoScrollArea, "Video");
}

void InspectorPanel::setupAudioTab()
{
    m_audioTab = new QWidget();
    m_audioScrollArea = new QScrollArea();
    m_audioScrollArea->setWidget(m_audioTab);
    m_audioScrollArea->setWidgetResizable(true);
    m_audioScrollArea->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    
    QVBoxLayout* audioLayout = new QVBoxLayout(m_audioTab);
    audioLayout->setContentsMargins(8, 8, 8, 8);
    audioLayout->setSpacing(4);
    
    // Volume group
    m_volumeGroup = new QGroupBox("Volume");
    QFormLayout* volumeLayout = new QFormLayout(m_volumeGroup);
    
    volumeLayout->addRow("Volume (dB):", createSliderProperty("volume", -60.0, 12.0, DEFAULT_VOLUME));
    volumeLayout->addRow("Mute:", createCheckProperty("mute", false));
    
    audioLayout->addWidget(m_volumeGroup);
    
    // Pan group
    m_panGroup = new QGroupBox("Pan");
    QFormLayout* panLayout = new QFormLayout(m_panGroup);
    
    panLayout->addRow("Pan:", createSliderProperty("pan", -100.0, 100.0, DEFAULT_PAN));
    panLayout->addRow("Channel:", createComboProperty("channel_routing", 
        {"Stereo", "Left Only", "Right Only", "Mono"}, 0));
    
    audioLayout->addWidget(m_panGroup);
    
    // Audio Effects group
    m_audioEffectsGroup = new QGroupBox("Audio Effects");
    QVBoxLayout* audioEffectsLayout = new QVBoxLayout(m_audioEffectsGroup);
    
    QTreeWidget* audioEffectStack = new QTreeWidget();
    audioEffectStack->setHeaderLabels({"Effect", "Enabled"});
    audioEffectStack->setMaximumHeight(100);
    audioEffectsLayout->addWidget(audioEffectStack);
    
    QHBoxLayout* audioEffectButtons = new QHBoxLayout();
    audioEffectButtons->addWidget(new QPushButton("Add"));
    audioEffectButtons->addWidget(new QPushButton("Remove"));
    audioEffectButtons->addStretch();
    audioEffectsLayout->addLayout(audioEffectButtons);
    
    audioLayout->addWidget(m_audioEffectsGroup);
    audioLayout->addStretch();
    
    m_tabWidget->addTab(m_audioScrollArea, "Audio");
}

void InspectorPanel::setupColorTab()
{
    m_colorTab = new QWidget();
    m_colorScrollArea = new QScrollArea();
    m_colorScrollArea->setWidget(m_colorTab);
    m_colorScrollArea->setWidgetResizable(true);
    m_colorScrollArea->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    
    QVBoxLayout* colorLayout = new QVBoxLayout(m_colorTab);
    colorLayout->setContentsMargins(8, 8, 8, 8);
    colorLayout->setSpacing(4);
    
    // Exposure group
    m_exposureGroup = new QGroupBox("Exposure");
    QFormLayout* exposureLayout = new QFormLayout(m_exposureGroup);
    
    exposureLayout->addRow("Exposure:", createSliderProperty("exposure", -3.0, 3.0, 0.0));
    exposureLayout->addRow("Contrast:", createSliderProperty("contrast", -100.0, 100.0, 0.0));
    exposureLayout->addRow("Highlights:", createSliderProperty("highlights", -100.0, 100.0, 0.0));
    exposureLayout->addRow("Shadows:", createSliderProperty("shadows", -100.0, 100.0, 0.0));
    exposureLayout->addRow("Whites:", createSliderProperty("whites", -100.0, 100.0, 0.0));
    exposureLayout->addRow("Blacks:", createSliderProperty("blacks", -100.0, 100.0, 0.0));
    
    colorLayout->addWidget(m_exposureGroup);
    
    // Color group
    QGroupBox* colorGroup = new QGroupBox("Color");
    QFormLayout* colorGroupLayout = new QFormLayout(colorGroup);
    
    colorGroupLayout->addRow("Temperature:", createSliderProperty("temperature", -100.0, 100.0, 0.0));
    colorGroupLayout->addRow("Tint:", createSliderProperty("tint", -100.0, 100.0, 0.0));
    colorGroupLayout->addRow("Saturation:", createSliderProperty("saturation", -100.0, 100.0, 0.0));
    colorGroupLayout->addRow("Vibrance:", createSliderProperty("vibrance", -100.0, 100.0, 0.0));
    
    colorLayout->addWidget(colorGroup);
    
    // Color wheels would go here (simplified for now)
    QGroupBox* colorWheelsGroup = new QGroupBox("Color Wheels");
    QHBoxLayout* wheelsLayout = new QHBoxLayout(colorWheelsGroup);
    wheelsLayout->addWidget(new QLabel("Shadows"));
    wheelsLayout->addWidget(new QLabel("Midtones"));
    wheelsLayout->addWidget(new QLabel("Highlights"));
    colorLayout->addWidget(colorWheelsGroup);
    
    colorLayout->addStretch();
    
    m_tabWidget->addTab(m_colorScrollArea, "Color");
}

void InspectorPanel::setupMotionTab()
{
    m_motionTab = new QWidget();
    m_motionScrollArea = new QScrollArea();
    m_motionScrollArea->setWidget(m_motionTab);
    m_motionScrollArea->setWidgetResizable(true);
    m_motionScrollArea->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    
    QVBoxLayout* motionLayout = new QVBoxLayout(m_motionTab);
    motionLayout->setContentsMargins(8, 8, 8, 8);
    motionLayout->setSpacing(4);
    
    // Keyframe group
    m_keyframeGroup = new QGroupBox("Keyframes");
    QVBoxLayout* keyframeLayout = new QVBoxLayout(m_keyframeGroup);
    
    // Keyframe controls
    QHBoxLayout* keyframeControls = new QHBoxLayout();
    keyframeControls->addWidget(new QPushButton("◀◀"));
    keyframeControls->addWidget(new QPushButton("◀"));
    keyframeControls->addWidget(new QPushButton("●"));
    keyframeControls->addWidget(new QPushButton("▶"));
    keyframeControls->addWidget(new QPushButton("▶▶"));
    keyframeControls->addStretch();
    keyframeLayout->addLayout(keyframeControls);
    
    // Keyframe tree
    m_keyframeTree = new QTreeWidget();
    m_keyframeTree->setHeaderLabels({"Property", "Value", "Time", "Interpolation"});
    keyframeLayout->addWidget(m_keyframeTree);
    
    motionLayout->addWidget(m_keyframeGroup);
    
    // Motion blur group
    QGroupBox* motionBlurGroup = new QGroupBox("Motion Blur");
    QFormLayout* motionBlurLayout = new QFormLayout(motionBlurGroup);
    
    motionBlurLayout->addRow("Enable:", createCheckProperty("motion_blur_enabled", false));
    motionBlurLayout->addRow("Shutter Angle:", createSliderProperty("motion_blur_angle", 0.0, 360.0, 180.0));
    motionBlurLayout->addRow("Samples:", createSpinProperty("motion_blur_samples", 1, 64, 8));
    
    motionLayout->addWidget(motionBlurGroup);
    motionLayout->addStretch();
    
    m_tabWidget->addTab(m_motionScrollArea, "Motion");
}

void InspectorPanel::setupEffectsTab()
{
    m_effectsTab = new QWidget();
    m_effectsScrollArea = new QScrollArea();
    m_effectsScrollArea->setWidget(m_effectsTab);
    m_effectsScrollArea->setWidgetResizable(true);
    m_effectsScrollArea->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    
    QVBoxLayout* effectsLayout = new QVBoxLayout(m_effectsTab);
    effectsLayout->setContentsMargins(8, 8, 8, 8);
    effectsLayout->setSpacing(4);
    
    // Effect browser
    QGroupBox* browserGroup = new QGroupBox("Effect Browser");
    QVBoxLayout* browserLayout = new QVBoxLayout(browserGroup);
    
    m_effectBrowser = new QComboBox();
    m_effectBrowser->addItems({
        "Blur & Sharpen/Gaussian Blur",
        "Blur & Sharpen/Sharpen",
        "Color Correction/Color Balance",
        "Color Correction/Hue/Saturation",
        "Distort/Transform",
        "Stylize/Glow",
        "Time/Echo",
        "Time/Posterize Time"
    });
    browserLayout->addWidget(m_effectBrowser);
    
    QHBoxLayout* browserButtons = new QHBoxLayout();
    m_addEffectButton = new QPushButton("Add Effect");
    browserButtons->addWidget(m_addEffectButton);
    browserButtons->addStretch();
    browserLayout->addLayout(browserButtons);
    
    effectsLayout->addWidget(browserGroup);
    
    // Effect stack
    QGroupBox* stackGroup = new QGroupBox("Effect Stack");
    QVBoxLayout* stackLayout = new QVBoxLayout(stackGroup);
    
    m_effectStack = new QTreeWidget();
    m_effectStack->setHeaderLabels({"Effect", "Enabled"});
    m_effectStack->setDragDropMode(QAbstractItemView::InternalMove);
    stackLayout->addWidget(m_effectStack);
    
    QHBoxLayout* stackButtons = new QHBoxLayout();
    m_removeEffectButton = new QPushButton("Remove");
    QPushButton* duplicateButton = new QPushButton("Duplicate");
    stackButtons->addWidget(m_removeEffectButton);
    stackButtons->addWidget(duplicateButton);
    stackButtons->addStretch();
    stackLayout->addLayout(stackButtons);
    
    effectsLayout->addWidget(stackGroup);
    
    // Presets
    QGroupBox* presetsGroup = new QGroupBox("Presets");
    QVBoxLayout* presetsLayout = new QVBoxLayout(presetsGroup);
    
    m_presetCombo = new QComboBox();
    m_presetCombo->addItems({"Default", "Film Look", "Vintage", "Black & White", "High Contrast"});
    presetsLayout->addWidget(m_presetCombo);
    
    QHBoxLayout* presetButtons = new QHBoxLayout();
    m_savePresetButton = new QPushButton("Save");
    m_deletePresetButton = new QPushButton("Delete");
    presetButtons->addWidget(m_savePresetButton);
    presetButtons->addWidget(m_deletePresetButton);
    presetButtons->addStretch();
    presetsLayout->addLayout(presetButtons);
    
    effectsLayout->addWidget(presetsGroup);
    effectsLayout->addStretch();
    
    m_tabWidget->addTab(m_effectsScrollArea, "Effects");
}

void InspectorPanel::connectSignals()
{
    connect(m_tabWidget, &QTabWidget::currentChanged, this, &InspectorPanel::onTabChanged);
    
    if (m_addEffectButton) {
        connect(m_addEffectButton, &QPushButton::clicked, [this]() {
            addEffect(m_effectBrowser->currentText());
        });
    }
    
    if (m_removeEffectButton) {
        connect(m_removeEffectButton, &QPushButton::clicked, [this]() {
            if (m_effectStack->currentItem()) {
                removeEffect(m_effectStack->currentItem()->text(0));
            }
        });
    }
    
    if (m_presetCombo) {
        connect(m_presetCombo, QOverload<const QString&>::of(&QComboBox::currentTextChanged),
                this, &InspectorPanel::onPresetSelected);
    }
}

QWidget* InspectorPanel::createSliderProperty(const QString& name, double min, double max, double value)
{
    QWidget* widget = new QWidget();
    QHBoxLayout* layout = new QHBoxLayout(widget);
    layout->setContentsMargins(0, 0, 0, 0);
    
    QSlider* slider = new QSlider(Qt::Horizontal);
    slider->setRange(static_cast<int>(min * 100), static_cast<int>(max * 100));
    slider->setValue(static_cast<int>(value * 100));
    slider->setObjectName(name);
    
    QDoubleSpinBox* spinBox = new QDoubleSpinBox();
    spinBox->setRange(min, max);
    spinBox->setValue(value);
    spinBox->setDecimals(2);
    spinBox->setSingleStep(0.1);
    spinBox->setMaximumWidth(80);
    
    // Keyframe button
    QPushButton* keyframeBtn = new QPushButton("◆");
    keyframeBtn->setMaximumSize(20, 20);
    keyframeBtn->setCheckable(true);
    keyframeBtn->setObjectName(name + "_keyframe");
    
    layout->addWidget(slider, 1);
    layout->addWidget(spinBox);
    layout->addWidget(keyframeBtn);
    
    // Connect signals
    connect(slider, &QSlider::valueChanged, [spinBox](int value) {
        spinBox->setValue(value / 100.0);
    });
    connect(spinBox, QOverload<double>::of(&QDoubleSpinBox::valueChanged), [slider](double value) {
        slider->setValue(static_cast<int>(value * 100));
    });
    connect(slider, &QSlider::valueChanged, this, &InspectorPanel::onPropertyValueChanged);
    connect(keyframeBtn, &QPushButton::clicked, this, &InspectorPanel::onKeyframeToggled);
    
    return widget;
}

QWidget* InspectorPanel::createSpinProperty(const QString& name, int min, int max, int value)
{
    QSpinBox* spinBox = new QSpinBox();
    spinBox->setRange(min, max);
    spinBox->setValue(value);
    spinBox->setObjectName(name);
    
    connect(spinBox, QOverload<int>::of(&QSpinBox::valueChanged), this, &InspectorPanel::onPropertyValueChanged);
    
    return spinBox;
}

QWidget* InspectorPanel::createCheckProperty(const QString& name, bool value)
{
    QCheckBox* checkBox = new QCheckBox();
    checkBox->setChecked(value);
    checkBox->setObjectName(name);
    
    connect(checkBox, &QCheckBox::toggled, this, &InspectorPanel::onPropertyValueChanged);
    
    return checkBox;
}

QWidget* InspectorPanel::createComboProperty(const QString& name, const QStringList& options, int selected)
{
    QComboBox* comboBox = new QComboBox();
    comboBox->addItems(options);
    comboBox->setCurrentIndex(selected);
    comboBox->setObjectName(name);
    
    connect(comboBox, QOverload<int>::of(&QComboBox::currentIndexChanged), this, &InspectorPanel::onPropertyValueChanged);
    
    return comboBox;
}

QWidget* InspectorPanel::createColorProperty(const QString& name, const QColor& color)
{
    QWidget* widget = new QWidget();
    QHBoxLayout* layout = new QHBoxLayout(widget);
    layout->setContentsMargins(0, 0, 0, 0);
    
    QPushButton* colorButton = new QPushButton();
    colorButton->setMaximumSize(30, 20);
    colorButton->setStyleSheet(QString("background-color: %1; border: 1px solid #666;").arg(color.name()));
    colorButton->setObjectName(name);
    
    QLineEdit* colorEdit = new QLineEdit(color.name());
    colorEdit->setMaximumWidth(80);
    
    layout->addWidget(colorButton);
    layout->addWidget(colorEdit, 1);
    
    connect(colorButton, &QPushButton::clicked, [this, colorButton, colorEdit]() {
        QColor currentColor = QColor(colorEdit->text());
        QColor newColor = QColorDialog::getColor(currentColor, this);
        if (newColor.isValid()) {
            colorEdit->setText(newColor.name());
            colorButton->setStyleSheet(QString("background-color: %1; border: 1px solid #666;").arg(newColor.name()));
            onPropertyValueChanged();
        }
    });
    
    connect(colorEdit, &QLineEdit::textChanged, this, &InspectorPanel::onPropertyValueChanged);
    
    return widget;
}

QWidget* InspectorPanel::createTextProperty(const QString& name, const QString& value)
{
    QLineEdit* lineEdit = new QLineEdit(value);
    lineEdit->setObjectName(name);
    
    connect(lineEdit, &QLineEdit::textChanged, this, &InspectorPanel::onPropertyValueChanged);
    
    return lineEdit;
}

// Core functionality methods
void InspectorPanel::setCommandDispatcher(CommandDispatcher* dispatcher)
{
    m_commandDispatcher = dispatcher;
}

void InspectorPanel::setSelectionManager(SelectionManager* selectionManager)
{
    m_selectionManager = selectionManager;
    if (m_selectionManager) {
        connect(m_selectionManager, &SelectionManager::selectionChanged,
                this, &InspectorPanel::onSelectionChanged);
    }
}

void InspectorPanel::setSelectedClips(const QStringList& clipIds)
{
    m_selectedClips = clipIds;
    loadPropertiesFromClips();
}

void InspectorPanel::clearSelection()
{
    m_selectedClips.clear();
    m_selectedMedia.clear();
    setEnabled(false);
}

void InspectorPanel::onSelectionChanged(const QStringList& selectedItems)
{
    setSelectedClips(selectedItems);
    setEnabled(!selectedItems.isEmpty());
}

void InspectorPanel::onPropertyValueChanged()
{
    QObject* sender = this->sender();
    if (!sender) return;
    
    QString propertyName = sender->objectName();
    if (propertyName.isEmpty()) return;
    
    QVariant value;
    
    // Extract value based on widget type
    if (QSlider* slider = qobject_cast<QSlider*>(sender)) {
        value = slider->value() / 100.0;
    } else if (QSpinBox* spinBox = qobject_cast<QSpinBox*>(sender)) {
        value = spinBox->value();
    } else if (QDoubleSpinBox* doubleSpinBox = qobject_cast<QDoubleSpinBox*>(sender)) {
        value = doubleSpinBox->value();
    } else if (QCheckBox* checkBox = qobject_cast<QCheckBox*>(sender)) {
        value = checkBox->isChecked();
    } else if (QComboBox* comboBox = qobject_cast<QComboBox*>(sender)) {
        value = comboBox->currentIndex();
    } else if (QLineEdit* lineEdit = qobject_cast<QLineEdit*>(sender)) {
        value = lineEdit->text();
    }
    
    if (value.isValid()) {
        savePropertyToClips(propertyName, value);
        emit propertyChanged(propertyName, value);
    }
}

void InspectorPanel::onKeyframeToggled()
{
    QPushButton* button = qobject_cast<QPushButton*>(sender());
    if (!button) return;
    
    QString propertyName = button->objectName().replace("_keyframe", "");
    
    if (button->isChecked()) {
        addKeyframe(propertyName);
    } else {
        removeKeyframe(propertyName);
    }
}

void InspectorPanel::onTabChanged(int index)
{
    Q_UNUSED(index)
    refreshProperties();
}

void InspectorPanel::onPresetSelected(const QString& presetName)
{
    applyPreset(presetName);
}

void InspectorPanel::addKeyframe(const QString& propertyName)
{
    qCDebug(jveInspectorPanel, "Adding keyframe for property: %s", qPrintable(propertyName));
    emit keyframeAdded(propertyName, m_currentPlayheadPosition, m_propertyValues.value(propertyName));
}

void InspectorPanel::removeKeyframe(const QString& propertyName)
{
    qCDebug(jveInspectorPanel, "Removing keyframe for property: %s", qPrintable(propertyName));
    emit keyframeRemoved(propertyName, m_currentPlayheadPosition);
}

void InspectorPanel::addEffect(const QString& effectType)
{
    qCDebug(jveInspectorPanel, "Adding effect: %s", qPrintable(effectType));
    emit effectAdded(effectType);
}

void InspectorPanel::removeEffect(const QString& effectId)
{
    qCDebug(jveInspectorPanel, "Removing effect: %s", qPrintable(effectId));
    emit effectRemoved(effectId);
}

void InspectorPanel::applyPreset(const QString& presetName)
{
    qCDebug(jveInspectorPanel, "Applying preset: %s", qPrintable(presetName));
    emit presetApplied(presetName);
}

void InspectorPanel::loadPropertiesFromClips()
{
    // TODO: Load actual properties from selected clips
    // For now, just enable the interface
    updateUIFromProperties();
}

void InspectorPanel::savePropertyToClips(const QString& propertyName, const QVariant& value)
{
    // Store locally
    m_propertyValues[propertyName] = value;
    
    // TODO: Save to actual clips via command system
    if (m_commandDispatcher && !m_selectedClips.isEmpty()) {
        // Create property update command
        qCDebug(jveInspectorPanel, "Saving property %s = %s to clips", 
                qPrintable(propertyName), qPrintable(value.toString()));
    }
}

void InspectorPanel::updateUIFromProperties()
{
    // TODO: Update UI controls from current property values
}

void InspectorPanel::refreshProperties()
{
    if (!m_selectedClips.isEmpty()) {
        loadPropertiesFromClips();
    }
}

void InspectorPanel::onPlayheadPositionChanged(qint64 timeMs)
{
    m_currentPlayheadPosition = timeMs;
    // TODO: Update keyframe buttons based on current time
}

// Placeholder implementations
void InspectorPanel::setSelectedMedia(const QStringList&) {}
void InspectorPanel::resetPropertiesToDefaults() {}
void InspectorPanel::copyPropertiesToClipboard() {}
void InspectorPanel::pastePropertiesFromClipboard() {}
void InspectorPanel::showVideoTab() { m_tabWidget->setCurrentIndex(0); }
void InspectorPanel::showAudioTab() { m_tabWidget->setCurrentIndex(1); }
void InspectorPanel::showColorTab() { m_tabWidget->setCurrentIndex(2); }
void InspectorPanel::showMotionTab() { m_tabWidget->setCurrentIndex(3); }
void InspectorPanel::showEffectsTab() { m_tabWidget->setCurrentIndex(4); }
void InspectorPanel::onResetProperty() {}
void InspectorPanel::onEffectStackChanged() {}
QWidget* InspectorPanel::createPropertyGroup(const QString&) { return nullptr; }
QWidget* InspectorPanel::createKeyframeControls(const QString&) { return nullptr; }
void InspectorPanel::updateKeyframeButtons(const QString&) {}
void InspectorPanel::navigateToNextKeyframe(const QString&) {}
void InspectorPanel::navigateToPrevKeyframe(const QString&) {}
void InspectorPanel::loadEffectStack() {}
void InspectorPanel::reorderEffects() {}
void InspectorPanel::toggleEffectEnabled(const QString&, bool) {}
void InspectorPanel::loadPresets() {}
void InspectorPanel::saveCurrentAsPreset(const QString&) {}
void InspectorPanel::deletePreset(const QString&) {}
QString InspectorPanel::formatTimecode(qint64) const { return QString(); }
QColor InspectorPanel::parseColorFromString(const QString&) const { return QColor(); }
QString InspectorPanel::formatColorToString(const QColor&) const { return QString(); }
void InspectorPanel::updatePropertyEnabled(const QString&, bool) {}