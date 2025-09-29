#pragma once

#include <QObject>
#include <QApplication>
#include <QStyle>
#include <QStyleFactory>
#include <QPalette>
#include <QColor>
#include <QFont>
#include <QFontDatabase>
#include <QDir>
#include <QJsonObject>
#include <QJsonDocument>
#include <QSettings>
#include <QLoggingCategory>
#include <QTimer>

Q_DECLARE_LOGGING_CATEGORY(jveTheme)

/**
 * Professional theme management system for video editing application
 * 
 * Features:
 * - Industry-standard dark themes optimized for video editing environments
 * - Professional color palettes matching Avid Media Composer, FCP7, and DaVinci Resolve
 * - Dynamic theme switching with smooth transitions and preview modes
 * - High-contrast accessibility themes for professional color work
 * - Custom theme creation with color picker and preview tools
 * - Font management with professional typography for readability
 * - Icon theme management with vector-based professional icons
 * - Theme persistence and user preference management
 * 
 * Built-in Themes:
 * - Professional Dark: Primary dark theme optimized for long editing sessions
 * - Avid Style: Color scheme matching Avid Media Composer workflows
 * - Final Cut Pro: Inspired by Final Cut Pro 7 professional interface
 * - DaVinci Dark: Color grading optimized theme matching Resolve patterns
 * - High Contrast: Accessibility theme for professional color correction
 * - Light Professional: Light theme for bright environment editing
 * 
 * Color Philosophy:
 * - Background colors optimized for reduced eye strain during long sessions
 * - UI element colors that don't interfere with color-critical video content
 * - Professional gray scales that maintain color accuracy perception
 * - Accent colors that provide clear visual hierarchy without distraction
 * - Timeline and media colors that enhance professional editing workflow
 * 
 * Typography:
 * - Professional font stacks optimized for readability at various sizes
 * - Consistent font sizing hierarchy throughout the interface
 * - Support for international character sets and professional symbols
 * - High-DPI scaling support for professional displays
 * 
 * Theme Components:
 * - Window backgrounds and panel separators
 * - Button states, focus indicators, and interactive elements
 * - Timeline colors, playhead styling, and selection indicators
 * - Menu and context menu styling with professional appearance
 * - Dock widget styling and professional panel arrangements
 * - Status bar and toolbar professional appearance
 */
class ThemeManager : public QObject
{
    Q_OBJECT

public:
    enum ThemeType {
        ProfessionalDark,   // Default professional dark theme
        AvidStyle,          // Avid Media Composer inspired
        FinalCutPro,        // Final Cut Pro 7 inspired
        DaVinciDark,        // DaVinci Resolve inspired
        HighContrast,       // High contrast accessibility
        LightProfessional,  // Light theme for bright environments
        CustomTheme         // User-defined custom theme
    };

    enum ColorRole {
        // Background colors
        WindowBackground,           // Main window background
        PanelBackground,           // Panel backgrounds
        AlternateBackground,       // Alternate row colors
        ToolbarBackground,         // Toolbar and menu backgrounds
        
        // Interactive elements
        ButtonBackground,          // Button backgrounds
        ButtonPressed,             // Pressed button state
        ButtonHover,              // Hover button state
        ButtonDisabled,           // Disabled button state
        
        // Text colors
        PrimaryText,              // Primary text color
        SecondaryText,            // Secondary/dim text
        DisabledText,             // Disabled text
        SelectedText,             // Selected text
        
        // Selection and focus
        SelectionBackground,      // Selection background
        SelectionBorder,          // Selection border
        FocusIndicator,           // Focus indicator color
        HoverIndicator,           // Hover state indicator
        
        // Timeline specific
        TimelineBackground,       // Timeline panel background
        TrackBackground,          // Individual track background
        ClipBackground,           // Clip background color
        PlayheadColor,            // Playhead indicator
        
        // Status and feedback
        SuccessColor,             // Success state color
        WarningColor,             // Warning state color
        ErrorColor,               // Error state color
        InfoColor                 // Information color
    };

    enum FontRole {
        ApplicationFont,          // Default application font
        MenuFont,                 // Menu and context menu font
        ButtonFont,               // Button text font
        HeaderFont,               // Panel headers and titles
        TimelineFont,             // Timeline text and timecodes
        MonospaceFont             // Monospace font for technical data
    };

    struct ThemeColors {
        QHash<ColorRole, QColor> colors;
        QString name;
        QString description;
        bool isDark = true;
    };

    struct ThemeFonts {
        QHash<FontRole, QFont> fonts;
        QString fontFamily = "System";
        int baseFontSize = 10;
    };

    struct Theme {
        QString name;
        QString description;
        ThemeType type = ProfessionalDark;
        ThemeColors colors;
        ThemeFonts fonts;
        QJsonObject customData;
        bool isBuiltIn = true;
    };

    explicit ThemeManager(QObject* parent = nullptr);
    ~ThemeManager() = default;

    // Theme management
    void setCurrentTheme(ThemeType type);
    void setCurrentTheme(const QString& themeName);
    ThemeType getCurrentThemeType() const;
    QString getCurrentThemeName() const;
    Theme getCurrentTheme() const;

    // Built-in themes
    QStringList getAvailableThemes() const;
    Theme getTheme(ThemeType type) const;
    Theme getTheme(const QString& themeName) const;
    bool isThemeAvailable(const QString& themeName) const;

    // Custom theme management
    void createCustomTheme(const QString& name, const Theme& theme);
    void updateCustomTheme(const QString& name, const Theme& theme);
    void deleteCustomTheme(const QString& name);
    QStringList getCustomThemes() const;

    // Color management
    QColor getColor(ColorRole role) const;
    void setColor(ColorRole role, const QColor& color, const QString& themeName = QString());
    QPalette createPalette(const ThemeColors& colors) const;
    
    // Font management
    QFont getFont(FontRole role) const;
    void setFont(FontRole role, const QFont& font, const QString& themeName = QString());
    void setBaseFontSize(int size, const QString& themeName = QString());
    void loadCustomFonts();

    // Application integration
    void applyTheme(ThemeType type);
    void applyTheme(const QString& themeName);
    void applyCurrentTheme();
    void updateApplicationPalette();
    void updateApplicationFonts();

    // Theme persistence
    void saveTheme(const QString& themeName, const Theme& theme);
    Theme loadTheme(const QString& themeName) const;
    void saveCurrentTheme();
    void loadSavedTheme();

    // Theme preview and transitions
    void previewTheme(ThemeType type, int durationMs = 500);
    void previewTheme(const QString& themeName, int durationMs = 500);
    void endPreview();
    bool isPreviewActive() const;

    // Utility methods
    QString getStyleSheet() const;
    QString getStyleSheet(ThemeType type) const;
    QIcon createThemedIcon(const QString& iconName, const QColor& color = QColor()) const;
    QPixmap createThemedPixmap(const QString& imageName, const QSize& size = QSize()) const;

    // High-DPI support
    void setDevicePixelRatio(qreal ratio);
    qreal getDevicePixelRatio() const;
    void updateForHighDPI();

signals:
    // Theme change notifications
    void themeChanged(ThemeType type, const QString& themeName);
    void colorChanged(ColorRole role, const QColor& color);
    void fontChanged(FontRole role, const QFont& font);
    void customThemeCreated(const QString& themeName);
    void customThemeDeleted(const QString& themeName);

    // Preview notifications
    void previewStarted(const QString& themeName);
    void previewEnded();

public slots:
    void onSystemThemeChanged();
    void onHighDPIChanged(qreal ratio);

private slots:
    void onPreviewTimer();

private:
    // Built-in theme creation
    void initializeBuiltInThemes();
    Theme createProfessionalDarkTheme() const;
    Theme createAvidStyleTheme() const;
    Theme createFinalCutProTheme() const;
    Theme createDaVinciDarkTheme() const;
    Theme createHighContrastTheme() const;
    Theme createLightProfessionalTheme() const;

    // Theme application helpers
    void applyColors(const ThemeColors& colors);
    void applyFonts(const ThemeFonts& fonts);
    QString generateStyleSheet(const Theme& theme) const;
    QString generateWidgetStyleSheet(const QString& widgetType, const ThemeColors& colors) const;

    // Color utilities
    QColor adjustColorBrightness(const QColor& color, int amount) const;
    QColor blendColors(const QColor& color1, const QColor& color2, qreal factor) const;
    bool isColorDark(const QColor& color) const;

    // Font utilities
    void setupDefaultFonts();
    QFont createScaledFont(const QFont& baseFont, qreal scaleFactor) const;
    void validateFontAvailability();

    // Persistence helpers
    QJsonObject themeToJson(const Theme& theme) const;
    Theme themeFromJson(const QJsonObject& json) const;
    QString getThemeFilePath(const QString& themeName) const;
    void ensureThemeDirectory() const;

    // Preview management
    void startPreview(const Theme& theme, int durationMs);
    void applyPreviewTheme(const Theme& theme);
    void restoreOriginalTheme();

private:
    // Current theme state
    Theme m_currentTheme;
    ThemeType m_currentThemeType = ProfessionalDark;
    QString m_currentThemeName = "Professional Dark";

    // Built-in themes
    QHash<ThemeType, Theme> m_builtInThemes;
    QHash<QString, Theme> m_customThemes;

    // Preview state
    bool m_previewActive = false;
    Theme m_originalTheme;
    QTimer* m_previewTimer = nullptr;

    // Application integration
    QApplication* m_application = nullptr;
    qreal m_devicePixelRatio = 1.0;

    // Settings
    QSettings* m_settings = nullptr;
    QString m_themeDirectory;

    // Constants
    static constexpr const char* THEME_SETTINGS_GROUP = "Theme";
    static constexpr const char* CURRENT_THEME_KEY = "CurrentTheme";
    static constexpr const char* CUSTOM_THEMES_DIR = "themes";
    static constexpr int DEFAULT_PREVIEW_DURATION = 500;
};