#pragma once

#include <QWidget>
#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QTabWidget>
#include <QScrollArea>
#include <QGroupBox>
#include <QLabel>
#include <QLineEdit>
#include <QSpinBox>
#include <QDoubleSpinBox>
#include <QSlider>
#include <QCheckBox>
#include <QComboBox>
#include <QPushButton>
#include <QTextEdit>
#include <QTreeWidget>
#include <QTreeWidgetItem>
#include <QSplitter>
#include <QFrame>
#include <QFormLayout>
#include <QGridLayout>
#include <QProgressBar>

#include "core/models/clip.h"
#include "core/models/media.h"
#include "core/models/property.h"
#include "core/commands/command_dispatcher.h"
#include "ui/selection/selection_manager.h"

/**
 * Professional inspector panel for property editing
 * 
 * Features:
 * - Multi-tab interface (Video, Audio, Color, Motion, Effects)
 * - Real-time property editing with immediate preview
 * - Keyframe editing and animation controls
 * - Professional parameter grouping and organization
 * - Undo/redo integration for all property changes
 * - Context-sensitive property display based on selection
 * - Professional color correction and grading controls
 * - Audio mixing and effects parameters
 * - Motion controls with bezier curve editing
 * - Effect stack management
 * 
 * Design follows Avid/FCP7/Resolve inspector patterns
 */
class InspectorPanel : public QWidget
{
    Q_OBJECT

public:
    explicit InspectorPanel(QWidget* parent = nullptr);
    ~InspectorPanel() = default;

    // Core functionality
    void setCommandDispatcher(CommandDispatcher* dispatcher);
    void setSelectionManager(SelectionManager* selectionManager);
    
    // Selection handling
    void setSelectedClips(const QStringList& clipIds);
    void setSelectedMedia(const QStringList& mediaIds);
    void clearSelection();
    
    // Property management
    void refreshProperties();
    void resetPropertiesToDefaults();
    void copyPropertiesToClipboard();
    void pastePropertiesFromClipboard();
    
    // Tab management
    void showVideoTab();
    void showAudioTab();
    void showColorTab();
    void showMotionTab();
    void showEffectsTab();

signals:
    void propertyChanged(const QString& propertyName, const QVariant& value);
    void keyframeAdded(const QString& propertyName, qint64 time, const QVariant& value);
    void keyframeRemoved(const QString& propertyName, qint64 time);
    void effectAdded(const QString& effectType);
    void effectRemoved(const QString& effectId);
    void presetApplied(const QString& presetName);

public slots:
    void onSelectionChanged(const QStringList& selectedItems);
    void onPlayheadPositionChanged(qint64 timeMs);
    void onPropertyValueChanged();
    void onKeyframeToggled();
    void onResetProperty();

private slots:
    void onTabChanged(int index);
    void onEffectStackChanged();
    void onPresetSelected(const QString& presetName);

private:
    // Setup methods
    void setupUI();
    void setupTabs();
    void setupVideoTab();
    void setupAudioTab();
    void setupColorTab();
    void setupMotionTab();
    void setupEffectsTab();
    void connectSignals();
    
    // Property UI creation
    QWidget* createPropertyGroup(const QString& title);
    QWidget* createSliderProperty(const QString& name, double min, double max, double value);
    QWidget* createSpinProperty(const QString& name, int min, int max, int value);
    QWidget* createCheckProperty(const QString& name, bool value);
    QWidget* createComboProperty(const QString& name, const QStringList& options, int selected);
    QWidget* createColorProperty(const QString& name, const QColor& color);
    QWidget* createTextProperty(const QString& name, const QString& value);
    
    // Keyframe UI
    QWidget* createKeyframeControls(const QString& propertyName);
    void updateKeyframeButtons(const QString& propertyName);
    void addKeyframe(const QString& propertyName);
    void removeKeyframe(const QString& propertyName);
    void navigateToNextKeyframe(const QString& propertyName);
    void navigateToPrevKeyframe(const QString& propertyName);
    
    // Effect management
    void loadEffectStack();
    void addEffect(const QString& effectType);
    void removeEffect(const QString& effectId);
    void reorderEffects();
    void toggleEffectEnabled(const QString& effectId, bool enabled);
    
    // Preset management
    void loadPresets();
    void applyPreset(const QString& presetName);
    void saveCurrentAsPreset(const QString& name);
    void deletePreset(const QString& name);
    
    // Property synchronization
    void loadPropertiesFromClips();
    void savePropertyToClips(const QString& propertyName, const QVariant& value);
    void updateUIFromProperties();
    
    // Helper methods
    QString formatTimecode(qint64 timeMs) const;
    QColor parseColorFromString(const QString& colorString) const;
    QString formatColorToString(const QColor& color) const;
    void updatePropertyEnabled(const QString& propertyName, bool enabled);
    
private:
    // Core components
    CommandDispatcher* m_commandDispatcher = nullptr;
    SelectionManager* m_selectionManager = nullptr;
    
    // UI components
    QVBoxLayout* m_mainLayout = nullptr;
    QTabWidget* m_tabWidget = nullptr;
    
    // Tab widgets
    QWidget* m_videoTab = nullptr;
    QWidget* m_audioTab = nullptr;
    QWidget* m_colorTab = nullptr;
    QWidget* m_motionTab = nullptr;
    QWidget* m_effectsTab = nullptr;
    
    // Video tab controls
    QScrollArea* m_videoScrollArea = nullptr;
    QGroupBox* m_transformGroup = nullptr;
    QGroupBox* m_cropGroup = nullptr;
    QGroupBox* m_opacityGroup = nullptr;
    QSlider* m_scaleXSlider = nullptr;
    QSlider* m_scaleYSlider = nullptr;
    QSlider* m_rotationSlider = nullptr;
    QSlider* m_positionXSlider = nullptr;
    QSlider* m_positionYSlider = nullptr;
    QSlider* m_opacitySlider = nullptr;
    
    // Audio tab controls
    QScrollArea* m_audioScrollArea = nullptr;
    QGroupBox* m_volumeGroup = nullptr;
    QGroupBox* m_panGroup = nullptr;
    QGroupBox* m_audioEffectsGroup = nullptr;
    QSlider* m_volumeSlider = nullptr;
    QSlider* m_panSlider = nullptr;
    QCheckBox* m_muteCheckBox = nullptr;
    
    // Color tab controls
    QScrollArea* m_colorScrollArea = nullptr;
    QGroupBox* m_exposureGroup = nullptr;
    QGroupBox* m_colorWheelsGroup = nullptr;
    QGroupBox* m_curvesGroup = nullptr;
    QSlider* m_exposureSlider = nullptr;
    QSlider* m_contrastSlider = nullptr;
    QSlider* m_saturationSlider = nullptr;
    QSlider* m_highlightsSlider = nullptr;
    QSlider* m_shadowsSlider = nullptr;
    
    // Motion tab controls
    QScrollArea* m_motionScrollArea = nullptr;
    QGroupBox* m_keyframeGroup = nullptr;
    QTreeWidget* m_keyframeTree = nullptr;
    
    // Effects tab controls
    QScrollArea* m_effectsScrollArea = nullptr;
    QVBoxLayout* m_effectsLayout = nullptr;
    QTreeWidget* m_effectStack = nullptr;
    QPushButton* m_addEffectButton = nullptr;
    QPushButton* m_removeEffectButton = nullptr;
    QComboBox* m_effectBrowser = nullptr;
    
    // Current state
    QStringList m_selectedClips;
    QStringList m_selectedMedia;
    qint64 m_currentPlayheadPosition = 0;
    QMap<QString, QVariant> m_propertyValues;
    QMap<QString, bool> m_keyframeProperties;
    
    // Presets
    QComboBox* m_presetCombo = nullptr;
    QPushButton* m_savePresetButton = nullptr;
    QPushButton* m_deletePresetButton = nullptr;
    
    // Constants
    static constexpr double DEFAULT_SCALE = 100.0;
    static constexpr double DEFAULT_ROTATION = 0.0;
    static constexpr double DEFAULT_POSITION = 0.0;
    static constexpr double DEFAULT_OPACITY = 100.0;
    static constexpr double DEFAULT_VOLUME = 0.0; // dB
    static constexpr double DEFAULT_PAN = 0.0;
    
    // Styling
    QColor m_backgroundColor = QColor(40, 40, 40);
    QColor m_groupBoxColor = QColor(50, 50, 50);
    QColor m_sliderColor = QColor(70, 130, 180);
    QFont m_labelFont = QFont("Arial", 9);
    QFont m_valueFont = QFont("Arial", 8);
};