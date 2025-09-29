#include "theme_manager.h"
#include <QApplication>
#include <QDebug>
#include <QDir>
#include <QStandardPaths>
#include <QJsonDocument>
#include <QFile>

Q_LOGGING_CATEGORY(jveTheme, "jve.ui.theme")

ThemeManager::ThemeManager(QObject* parent)
    : QObject(parent)
    , m_application(qobject_cast<QApplication*>(QApplication::instance()))
{
    qCDebug(jveTheme) << "Initializing ThemeManager";
    
    // Initialize settings
    m_settings = new QSettings(this);
    
    // Set up theme directory
    QString appDataPath = QStandardPaths::writableLocation(QStandardPaths::AppConfigLocation);
    m_themeDirectory = QDir(appDataPath).absoluteFilePath(CUSTOM_THEMES_DIR);
    ensureThemeDirectory();
    
    // Initialize built-in themes
    initializeBuiltInThemes();
    
    // Load custom themes
    loadCustomFonts();
    
    // Set up preview timer
    m_previewTimer = new QTimer(this);
    m_previewTimer->setSingleShot(true);
    connect(m_previewTimer, &QTimer::timeout, this, &ThemeManager::onPreviewTimer);
    
    // Load saved theme
    loadSavedTheme();
}

void ThemeManager::initializeBuiltInThemes()
{
    qCDebug(jveTheme) << "Creating built-in themes";
    
    m_builtInThemes[ProfessionalDark] = createProfessionalDarkTheme();
    m_builtInThemes[AvidStyle] = createAvidStyleTheme();
    m_builtInThemes[FinalCutPro] = createFinalCutProTheme();
    m_builtInThemes[DaVinciDark] = createDaVinciDarkTheme();
    m_builtInThemes[HighContrast] = createHighContrastTheme();
    m_builtInThemes[LightProfessional] = createLightProfessionalTheme();
    
    // Set default theme
    m_currentTheme = m_builtInThemes[ProfessionalDark];
    m_currentThemeType = ProfessionalDark;
    m_currentThemeName = m_currentTheme.name;
}

ThemeManager::Theme ThemeManager::createProfessionalDarkTheme() const
{
    Theme theme;
    theme.name = "Professional Dark";
    theme.description = "Default professional dark theme optimized for video editing";
    theme.type = ProfessionalDark;
    theme.isBuiltIn = true;
    
    // Professional dark color palette
    theme.colors.isDark = true;
    theme.colors.colors[WindowBackground] = QColor(45, 45, 45);
    theme.colors.colors[PanelBackground] = QColor(60, 60, 60);
    theme.colors.colors[AlternateBackground] = QColor(55, 55, 55);
    theme.colors.colors[ToolbarBackground] = QColor(50, 50, 50);
    
    theme.colors.colors[ButtonBackground] = QColor(80, 80, 80);
    theme.colors.colors[ButtonPressed] = QColor(100, 100, 100);
    theme.colors.colors[ButtonHover] = QColor(90, 90, 90);
    theme.colors.colors[ButtonDisabled] = QColor(70, 70, 70);
    
    theme.colors.colors[PrimaryText] = QColor(220, 220, 220);
    theme.colors.colors[SecondaryText] = QColor(180, 180, 180);
    theme.colors.colors[DisabledText] = QColor(120, 120, 120);
    theme.colors.colors[SelectedText] = QColor(255, 255, 255);
    
    theme.colors.colors[SelectionBackground] = QColor(70, 130, 180);
    theme.colors.colors[SelectionBorder] = QColor(100, 150, 200);
    theme.colors.colors[FocusIndicator] = QColor(255, 165, 0);
    theme.colors.colors[HoverIndicator] = QColor(135, 206, 235, 100);
    
    theme.colors.colors[TimelineBackground] = QColor(40, 40, 40);
    theme.colors.colors[TrackBackground] = QColor(65, 65, 65);
    theme.colors.colors[ClipBackground] = QColor(100, 150, 200);
    theme.colors.colors[PlayheadColor] = QColor(255, 255, 255);
    
    theme.colors.colors[SuccessColor] = QColor(76, 175, 80);
    theme.colors.colors[WarningColor] = QColor(255, 193, 7);
    theme.colors.colors[ErrorColor] = QColor(244, 67, 54);
    theme.colors.colors[InfoColor] = QColor(33, 150, 243);
    
    // Professional fonts
    theme.fonts.fontFamily = "System";
    theme.fonts.baseFontSize = 10;
    theme.fonts.fonts[ApplicationFont] = QFont("Arial", 10);
    theme.fonts.fonts[MenuFont] = QFont("Arial", 9);
    theme.fonts.fonts[ButtonFont] = QFont("Arial", 9);
    theme.fonts.fonts[HeaderFont] = QFont("Arial", 11, QFont::Bold);
    theme.fonts.fonts[TimelineFont] = QFont("Consolas", 9);
    theme.fonts.fonts[MonospaceFont] = QFont("Courier New", 9);
    
    return theme;
}

ThemeManager::Theme ThemeManager::createAvidStyleTheme() const
{
    Theme theme = createProfessionalDarkTheme();
    theme.name = "Avid Style";
    theme.description = "Avid Media Composer inspired color scheme";
    theme.type = AvidStyle;
    
    // Avid-inspired colors (darker blues and grays)
    theme.colors.colors[WindowBackground] = QColor(35, 35, 40);
    theme.colors.colors[PanelBackground] = QColor(50, 50, 55);
    theme.colors.colors[SelectionBackground] = QColor(65, 105, 140);
    theme.colors.colors[FocusIndicator] = QColor(120, 160, 200);
    theme.colors.colors[ClipBackground] = QColor(85, 125, 165);
    
    return theme;
}

ThemeManager::Theme ThemeManager::createFinalCutProTheme() const
{
    Theme theme = createProfessionalDarkTheme();
    theme.name = "Final Cut Pro";
    theme.description = "Final Cut Pro 7 inspired interface";
    theme.type = FinalCutPro;
    
    // FCP7-inspired colors (warmer grays)
    theme.colors.colors[WindowBackground] = QColor(48, 48, 48);
    theme.colors.colors[PanelBackground] = QColor(65, 65, 65);
    theme.colors.colors[SelectionBackground] = QColor(180, 130, 70);
    theme.colors.colors[FocusIndicator] = QColor(220, 165, 100);
    theme.colors.colors[ClipBackground] = QColor(160, 120, 80);
    
    return theme;
}

ThemeManager::Theme ThemeManager::createDaVinciDarkTheme() const
{
    Theme theme = createProfessionalDarkTheme();
    theme.name = "DaVinci Dark";
    theme.description = "DaVinci Resolve inspired color grading theme";
    theme.type = DaVinciDark;
    
    // DaVinci-inspired colors (very dark for color work)
    theme.colors.colors[WindowBackground] = QColor(25, 25, 25);
    theme.colors.colors[PanelBackground] = QColor(40, 40, 40);
    theme.colors.colors[TimelineBackground] = QColor(30, 30, 30);
    theme.colors.colors[SelectionBackground] = QColor(200, 80, 80);
    theme.colors.colors[FocusIndicator] = QColor(240, 120, 120);
    theme.colors.colors[ClipBackground] = QColor(180, 100, 100);
    
    return theme;
}

ThemeManager::Theme ThemeManager::createHighContrastTheme() const
{
    Theme theme = createProfessionalDarkTheme();
    theme.name = "High Contrast";
    theme.description = "High contrast accessibility theme";
    theme.type = HighContrast;
    
    // High contrast colors
    theme.colors.colors[WindowBackground] = QColor(0, 0, 0);
    theme.colors.colors[PanelBackground] = QColor(20, 20, 20);
    theme.colors.colors[PrimaryText] = QColor(255, 255, 255);
    theme.colors.colors[SelectionBackground] = QColor(255, 255, 0);
    theme.colors.colors[SelectionBorder] = QColor(255, 255, 255);
    theme.colors.colors[FocusIndicator] = QColor(0, 255, 255);
    theme.colors.colors[ButtonBackground] = QColor(100, 100, 100);
    
    return theme;
}

ThemeManager::Theme ThemeManager::createLightProfessionalTheme() const
{
    Theme theme = createProfessionalDarkTheme();
    theme.name = "Light Professional";
    theme.description = "Light theme for bright environment editing";
    theme.type = LightProfessional;
    
    // Light professional colors
    theme.colors.isDark = false;
    theme.colors.colors[WindowBackground] = QColor(240, 240, 240);
    theme.colors.colors[PanelBackground] = QColor(250, 250, 250);
    theme.colors.colors[AlternateBackground] = QColor(245, 245, 245);
    theme.colors.colors[ToolbarBackground] = QColor(235, 235, 235);
    
    theme.colors.colors[PrimaryText] = QColor(50, 50, 50);
    theme.colors.colors[SecondaryText] = QColor(100, 100, 100);
    theme.colors.colors[DisabledText] = QColor(150, 150, 150);
    theme.colors.colors[SelectedText] = QColor(0, 0, 0);
    
    theme.colors.colors[SelectionBackground] = QColor(70, 130, 180);
    theme.colors.colors[FocusIndicator] = QColor(255, 165, 0);
    theme.colors.colors[TimelineBackground] = QColor(230, 230, 230);
    theme.colors.colors[TrackBackground] = QColor(245, 245, 245);
    
    return theme;
}

void ThemeManager::setCurrentTheme(ThemeType type)
{
    if (m_builtInThemes.contains(type)) {
        m_currentTheme = m_builtInThemes[type];
        m_currentThemeType = type;
        m_currentThemeName = m_currentTheme.name;
        applyCurrentTheme();
        saveCurrentTheme();
        emit themeChanged(type, m_currentTheme.name);
        qCDebug(jveTheme) << "Theme changed to:" << m_currentTheme.name;
    }
}

void ThemeManager::setCurrentTheme(const QString& themeName)
{
    // Check built-in themes first
    for (auto it = m_builtInThemes.begin(); it != m_builtInThemes.end(); ++it) {
        if (it.value().name == themeName) {
            setCurrentTheme(it.key());
            return;
        }
    }
    
    // Check custom themes
    if (m_customThemes.contains(themeName)) {
        m_currentTheme = m_customThemes[themeName];
        m_currentThemeType = CustomTheme;
        m_currentThemeName = themeName;
        applyCurrentTheme();
        saveCurrentTheme();
        emit themeChanged(CustomTheme, themeName);
        qCDebug(jveTheme) << "Custom theme changed to:" << themeName;
    }
}

ThemeManager::ThemeType ThemeManager::getCurrentThemeType() const
{
    return m_currentThemeType;
}

QString ThemeManager::getCurrentThemeName() const
{
    return m_currentThemeName;
}

ThemeManager::Theme ThemeManager::getCurrentTheme() const
{
    return m_currentTheme;
}

QStringList ThemeManager::getAvailableThemes() const
{
    QStringList themes;
    
    // Add built-in themes
    for (auto it = m_builtInThemes.begin(); it != m_builtInThemes.end(); ++it) {
        themes << it.value().name;
    }
    
    // Add custom themes
    themes << m_customThemes.keys();
    
    return themes;
}

ThemeManager::Theme ThemeManager::getTheme(ThemeType type) const
{
    return m_builtInThemes.value(type);
}

ThemeManager::Theme ThemeManager::getTheme(const QString& themeName) const
{
    // Check built-in themes
    for (const Theme& theme : m_builtInThemes) {
        if (theme.name == themeName) {
            return theme;
        }
    }
    
    // Check custom themes
    return m_customThemes.value(themeName);
}

QColor ThemeManager::getColor(ColorRole role) const
{
    return m_currentTheme.colors.colors.value(role, QColor(128, 128, 128));
}

QFont ThemeManager::getFont(FontRole role) const
{
    return m_currentTheme.fonts.fonts.value(role, QFont());
}

void ThemeManager::applyTheme(ThemeType type)
{
    setCurrentTheme(type);
}

void ThemeManager::applyTheme(const QString& themeName)
{
    setCurrentTheme(themeName);
}

void ThemeManager::applyCurrentTheme()
{
    if (m_application) {
        updateApplicationPalette();
        updateApplicationFonts();
        
        // Apply custom stylesheet
        QString styleSheet = generateStyleSheet(m_currentTheme);
        m_application->setStyleSheet(styleSheet);
        
        qCDebug(jveTheme) << "Applied theme:" << m_currentTheme.name;
    }
}

void ThemeManager::updateApplicationPalette()
{
    if (m_application) {
        QPalette palette = createPalette(m_currentTheme.colors);
        m_application->setPalette(palette);
    }
}

void ThemeManager::updateApplicationFonts()
{
    if (m_application) {
        QFont appFont = getFont(ApplicationFont);
        m_application->setFont(appFont);
    }
}

QPalette ThemeManager::createPalette(const ThemeColors& colors) const
{
    QPalette palette;
    
    // Window colors
    palette.setColor(QPalette::Window, colors.colors.value(WindowBackground));
    palette.setColor(QPalette::WindowText, colors.colors.value(PrimaryText));
    
    // Base colors
    palette.setColor(QPalette::Base, colors.colors.value(PanelBackground));
    palette.setColor(QPalette::AlternateBase, colors.colors.value(AlternateBackground));
    
    // Text colors
    palette.setColor(QPalette::Text, colors.colors.value(PrimaryText));
    palette.setColor(QPalette::BrightText, colors.colors.value(SelectedText));
    palette.setColor(QPalette::ToolTipText, colors.colors.value(PrimaryText));
    
    // Button colors
    palette.setColor(QPalette::Button, colors.colors.value(ButtonBackground));
    palette.setColor(QPalette::ButtonText, colors.colors.value(PrimaryText));
    
    // Selection colors
    palette.setColor(QPalette::Highlight, colors.colors.value(SelectionBackground));
    palette.setColor(QPalette::HighlightedText, colors.colors.value(SelectedText));
    
    return palette;
}

QString ThemeManager::generateStyleSheet(const Theme& theme) const
{
    QString styleSheet;
    
    // Main window styling
    styleSheet += QString(
        "QMainWindow {"
        "    background-color: %1;"
        "    color: %2;"
        "}"
    ).arg(theme.colors.colors.value(WindowBackground).name(),
          theme.colors.colors.value(PrimaryText).name());
    
    // Panel styling
    styleSheet += QString(
        "QDockWidget {"
        "    background-color: %1;"
        "    color: %2;"
        "    titlebar-close-icon: none;"
        "    titlebar-normal-icon: none;"
        "}"
        "QDockWidget::title {"
        "    background-color: %3;"
        "    padding: 4px;"
        "}"
    ).arg(theme.colors.colors.value(PanelBackground).name(),
          theme.colors.colors.value(PrimaryText).name(),
          theme.colors.colors.value(ToolbarBackground).name());
    
    // Button styling
    styleSheet += QString(
        "QPushButton {"
        "    background-color: %1;"
        "    color: %2;"
        "    border: 1px solid %3;"
        "    padding: 4px 8px;"
        "    border-radius: 2px;"
        "}"
        "QPushButton:hover {"
        "    background-color: %4;"
        "}"
        "QPushButton:pressed {"
        "    background-color: %5;"
        "}"
        "QPushButton:disabled {"
        "    background-color: %6;"
        "    color: %7;"
        "}"
    ).arg(theme.colors.colors.value(ButtonBackground).name(),
          theme.colors.colors.value(PrimaryText).name(),
          theme.colors.colors.value(SelectionBorder).name(),
          theme.colors.colors.value(ButtonHover).name(),
          theme.colors.colors.value(ButtonPressed).name(),
          theme.colors.colors.value(ButtonDisabled).name(),
          theme.colors.colors.value(DisabledText).name());
    
    // Menu styling
    styleSheet += QString(
        "QMenuBar {"
        "    background-color: %1;"
        "    color: %2;"
        "}"
        "QMenuBar::item:selected {"
        "    background-color: %3;"
        "}"
        "QMenu {"
        "    background-color: %1;"
        "    color: %2;"
        "    border: 1px solid %4;"
        "}"
        "QMenu::item:selected {"
        "    background-color: %3;"
        "}"
    ).arg(theme.colors.colors.value(ToolbarBackground).name(),
          theme.colors.colors.value(PrimaryText).name(),
          theme.colors.colors.value(SelectionBackground).name(),
          theme.colors.colors.value(SelectionBorder).name());
    
    return styleSheet;
}

void ThemeManager::saveCurrentTheme()
{
    m_settings->beginGroup(THEME_SETTINGS_GROUP);
    m_settings->setValue(CURRENT_THEME_KEY, m_currentThemeName);
    m_settings->endGroup();
    m_settings->sync();
}

void ThemeManager::loadSavedTheme()
{
    m_settings->beginGroup(THEME_SETTINGS_GROUP);
    QString savedTheme = m_settings->value(CURRENT_THEME_KEY, "Professional Dark").toString();
    m_settings->endGroup();
    
    setCurrentTheme(savedTheme);
}

void ThemeManager::loadCustomFonts()
{
    // Load any custom fonts from the application bundle
    QDir fontsDir(":/fonts");
    if (fontsDir.exists()) {
        QStringList fontFiles = fontsDir.entryList(QStringList() << "*.ttf" << "*.otf", QDir::Files);
        for (const QString& fontFile : fontFiles) {
            QString fontPath = fontsDir.absoluteFilePath(fontFile);
            int fontId = QFontDatabase::addApplicationFont(fontPath);
            if (fontId != -1) {
                QStringList fontFamilies = QFontDatabase::applicationFontFamilies(fontId);
                qCDebug(jveTheme) << "Loaded custom font:" << fontFamilies;
            }
        }
    }
}

void ThemeManager::ensureThemeDirectory() const
{
    QDir dir(m_themeDirectory);
    if (!dir.exists()) {
        dir.mkpath(".");
        qCDebug(jveTheme) << "Created theme directory:" << m_themeDirectory;
    }
}

QColor ThemeManager::adjustColorBrightness(const QColor& color, int amount) const
{
    int h, s, l;
    color.getHsl(&h, &s, &l);
    l = qBound(0, l + amount, 255);
    return QColor::fromHsl(h, s, l, color.alpha());
}

bool ThemeManager::isColorDark(const QColor& color) const
{
    // Calculate luminance
    double luminance = (0.299 * color.red() + 0.587 * color.green() + 0.114 * color.blue()) / 255.0;
    return luminance < 0.5;
}

void ThemeManager::onPreviewTimer()
{
    qCDebug(jveTheme) << "Preview timer timeout - applying preview theme";
    
    // Apply the currently previewed theme permanently
    if (!m_previewThemeName.isEmpty()) {
        setCurrentTheme(m_previewThemeName);
        m_previewThemeName.clear();
        saveCurrentTheme();
        
        emit themeChanged(m_currentTheme.type, m_currentTheme.name);
        qCDebug(jveTheme) << "Preview theme applied and saved:" << m_currentTheme.name;
    }
}

void ThemeManager::onSystemThemeChanged()
{
    qCDebug(jveTheme) << "System theme changed - checking for auto-adaptation";
    
    // Check if we should adapt to system theme changes
    if (m_settings->value("adaptToSystemTheme", false).toBool()) {
        // Detect system theme (simplified detection)
        bool systemIsDark = false;
        if (m_application) {
            QPalette systemPalette = m_application->palette();
            QColor windowColor = systemPalette.color(QPalette::Window);
            systemIsDark = isColorDark(windowColor);
        }
        
        // Switch to appropriate theme
        if (systemIsDark && !m_currentTheme.colors.isDark) {
            setCurrentTheme("Professional Dark");
            qCDebug(jveTheme) << "Switched to dark theme following system";
        } else if (!systemIsDark && m_currentTheme.colors.isDark) {
            setCurrentTheme("Light Professional");
            qCDebug(jveTheme) << "Switched to light theme following system";
        }
    }
}

void ThemeManager::onHighDPIChanged(qreal ratio)
{
    qCDebug(jveTheme) << "High DPI changed - ratio:" << ratio;
    
    // Update fonts for new DPI scaling
    Theme updatedTheme = m_currentTheme;
    
    // Scale font sizes based on DPI ratio
    for (auto& font : updatedTheme.fonts.fonts) {
        int originalSize = font.pointSize();
        if (originalSize > 0) {
            int scaledSize = qRound(originalSize * ratio);
            font.setPointSize(qMax(8, scaledSize)); // Minimum font size of 8
        }
    }
    
    // Apply updated theme
    m_currentTheme = updatedTheme;
    emit themeChanged(m_currentTheme.type, m_currentTheme.name);
    
    qCDebug(jveTheme) << "Fonts scaled for DPI ratio:" << ratio;
}