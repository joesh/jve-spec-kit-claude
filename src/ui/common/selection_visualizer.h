#pragma once

#include <QWidget>
#include <QPainter>
#include <QPen>
#include <QBrush>
#include <QColor>
#include <QRect>
#include <QRectF>
#include <QPoint>
#include <QTimer>
#include <QEasingCurve>
#include <QPropertyAnimation>
#include <QStringList>
#include <QHash>
#include <QLoggingCategory>

Q_DECLARE_LOGGING_CATEGORY(jveSelectionVisualizer)

/**
 * Professional selection visualization system for video editing
 * 
 * Features:
 * - Industry-standard selection highlighting following NLE conventions
 * - Multi-selection with professional visual feedback
 * - Animated selection transitions (fade in/out, color transitions)
 * - Context-sensitive selection styles (timeline, media browser, inspector)
 * - Selection state visualization (normal, hover, active, disabled)
 * - Professional color schemes matching Avid/FCP7/Resolve patterns
 * - High-DPI and retina display support
 * - Performance-optimized rendering for large selections
 * 
 * Design Philosophy:
 * - Clear visual hierarchy with subtle but distinct selection states
 * - Smooth animations that enhance workflow without being distracting
 * - Professional color palettes that work in low-light editing environments
 * - Consistent visual language across all UI panels
 * - Accessibility considerations for color-blind users
 * 
 * Visual States:
 * - Selected: Primary selection highlighting
 * - Hover: Mouse-over feedback
 * - Active: Currently focused/edited item
 * - Multi-selected: Multiple items selected together
 * - Disabled: Items that cannot be selected
 * - Partial: Items partially affected by operations
 */
class SelectionVisualizer : public QObject
{
    Q_OBJECT

public:
    enum SelectionState {
        None,           // No selection
        Selected,       // Standard selection
        Hover,          // Mouse hover
        Active,         // Currently active/focused
        MultiSelected,  // Part of multi-selection
        Disabled,       // Cannot be selected
        Partial         // Partially selected/affected
    };

    enum VisualizationStyle {
        TimelineStyle,      // Timeline clip selection
        ListStyle,          // List item selection (media browser)
        PropertyStyle,      // Property panel selection
        TreeStyle,          // Tree widget selection (project panel)
        TabStyle           // Tab selection
    };

    enum AnimationType {
        NoAnimation,        // Instant state change
        FadeAnimation,      // Fade in/out
        ColorTransition,    // Color interpolation
        ScaleAnimation,     // Scale effect
        GlowAnimation      // Glow effect
    };

    struct SelectionStyle {
        QColor backgroundColor;
        QColor borderColor;
        QColor textColor;
        int borderWidth = 1;
        int cornerRadius = 0;
        double opacity = 1.0;
        bool hasShadow = false;
        QColor shadowColor = QColor(0, 0, 0, 50);
        int shadowOffset = 2;
    };

    struct AnimationSettings {
        AnimationType type = FadeAnimation;
        int duration = 200;
        QEasingCurve curve = QEasingCurve::OutQuad;
        bool enabled = true;
    };

    explicit SelectionVisualizer(QObject* parent = nullptr);
    ~SelectionVisualizer() = default;

    // Style configuration
    void setVisualizationStyle(VisualizationStyle style);
    void setCustomStyle(SelectionState state, const SelectionStyle& style);
    SelectionStyle getStyle(SelectionState state) const;
    
    // Animation configuration
    void setAnimationSettings(const AnimationSettings& settings);
    void setAnimationsEnabled(bool enabled);
    bool areAnimationsEnabled() const;
    
    // Selection rendering
    void renderSelection(QPainter& painter, const QRect& rect, SelectionState state);
    void renderSelectionOutline(QPainter& painter, const QRect& rect, SelectionState state);
    void renderSelectionBackground(QPainter& painter, const QRect& rect, SelectionState state);
    void renderMultiSelection(QPainter& painter, const QList<QRect>& rects, SelectionState state);
    
    // Text rendering with selection
    void renderSelectedText(QPainter& painter, const QString& text, const QRect& rect, SelectionState state);
    QColor getTextColor(SelectionState state) const;
    
    // Interactive feedback
    void renderHoverEffect(QPainter& painter, const QRect& rect);
    void renderActiveEffect(QPainter& painter, const QRect& rect);
    void renderFocusIndicator(QPainter& painter, const QRect& rect);
    
    // Selection indicators
    void renderSelectionHandles(QPainter& painter, const QRect& rect);
    void renderSelectionBadge(QPainter& painter, const QRect& rect, const QString& text);
    void renderTriStateIndicator(QPainter& painter, const QRect& rect, int state); // 0=none, 1=partial, 2=full
    
    // Utility methods
    static QColor adjustColorForState(const QColor& baseColor, SelectionState state);
    static QPen createSelectionPen(const QColor& color, int width = 1);
    static QBrush createSelectionBrush(const QColor& color, double opacity = 1.0);
    
    // High-DPI support
    void setDevicePixelRatio(qreal ratio);
    qreal getDevicePixelRatio() const;

signals:
    void styleChanged(VisualizationStyle style);
    void animationCompleted();

public slots:
    void onSelectionChanged(const QStringList& selectedItems);
    void onHoverChanged(const QString& hoveredItem);
    void onActiveItemChanged(const QString& activeItem);

private slots:
    void onAnimationValueChanged(const QVariant& value);
    void onAnimationFinished();

private:
    // Style management
    void initializeDefaultStyles();
    void setupTimelineStyle();
    void setupListStyle();
    void setupPropertyStyle();
    void setupTreeStyle();
    void setupTabStyle();
    
    // Animation management
    void startAnimation(SelectionState fromState, SelectionState toState);
    void stopAnimations();
    QColor interpolateColor(const QColor& from, const QColor& to, qreal factor);
    
    // Rendering helpers
    void drawRoundedSelection(QPainter& painter, const QRect& rect, const SelectionStyle& style);
    void drawSelectionGlow(QPainter& painter, const QRect& rect, const QColor& color);
    void drawSelectionShadow(QPainter& painter, const QRect& rect, const SelectionStyle& style);
    
    // Performance optimization
    bool shouldRenderAnimation(const QRect& rect) const;
    void cacheSelectionPath(const QRect& rect);

private:
    VisualizationStyle m_currentStyle = TimelineStyle;
    QHash<SelectionState, SelectionStyle> m_styles;
    AnimationSettings m_animationSettings;
    
    // Animation state
    QPropertyAnimation* m_currentAnimation = nullptr;
    SelectionState m_animatingFromState = None;
    SelectionState m_animatingToState = None;
    qreal m_animationProgress = 0.0;
    
    // Visual state
    QStringList m_selectedItems;
    QString m_hoveredItem;
    QString m_activeItem;
    
    // Rendering optimization
    qreal m_devicePixelRatio = 1.0;
    QHash<QRect, QPainterPath> m_cachedPaths;
    
    // Professional color schemes
    static const QColor PRIMARY_SELECTION_COLOR;
    static const QColor SECONDARY_SELECTION_COLOR;
    static const QColor HOVER_COLOR;
    static const QColor ACTIVE_COLOR;
    static const QColor DISABLED_COLOR;
    static const QColor PARTIAL_COLOR;
};