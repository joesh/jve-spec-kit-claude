#include "selection_visualizer.h"
#include <QApplication>
#include <QPainterPath>
#include <QLinearGradient>
#include <QRadialGradient>

Q_LOGGING_CATEGORY(jveSelectionVisualizer, "jve.ui.selection.visualizer")

// Professional color scheme for video editing environments
const QColor SelectionVisualizer::PRIMARY_SELECTION_COLOR = QColor(70, 130, 180);     // Steel blue
const QColor SelectionVisualizer::SECONDARY_SELECTION_COLOR = QColor(100, 149, 237);  // Cornflower blue
const QColor SelectionVisualizer::HOVER_COLOR = QColor(135, 206, 235, 100);           // Sky blue with transparency
const QColor SelectionVisualizer::ACTIVE_COLOR = QColor(255, 215, 0);                 // Gold
const QColor SelectionVisualizer::DISABLED_COLOR = QColor(128, 128, 128, 100);        // Gray with transparency
const QColor SelectionVisualizer::PARTIAL_COLOR = QColor(255, 165, 0, 150);           // Orange with transparency

SelectionVisualizer::SelectionVisualizer(QObject* parent)
    : QObject(parent)
{
    initializeDefaultStyles();
    
    // Set up animation
    m_currentAnimation = new QPropertyAnimation(this);
    m_currentAnimation->setTargetObject(this);
    m_currentAnimation->setPropertyName("animationProgress");
    
    connect(m_currentAnimation, &QPropertyAnimation::valueChanged,
            this, &SelectionVisualizer::onAnimationValueChanged);
    connect(m_currentAnimation, &QPropertyAnimation::finished,
            this, &SelectionVisualizer::onAnimationFinished);
    
    qCDebug(jveSelectionVisualizer, "Selection visualizer initialized");
}

void SelectionVisualizer::setVisualizationStyle(VisualizationStyle style)
{
    if (m_currentStyle == style) return;
    
    m_currentStyle = style;
    
    switch (style) {
        case TimelineStyle:
            setupTimelineStyle();
            break;
        case ListStyle:
            setupListStyle();
            break;
        case PropertyStyle:
            setupPropertyStyle();
            break;
        case TreeStyle:
            setupTreeStyle();
            break;
        case TabStyle:
            setupTabStyle();
            break;
    }
    
    emit styleChanged(style);
    qCDebug(jveSelectionVisualizer, "Visualization style changed to %d", (int)style);
}

void SelectionVisualizer::setCustomStyle(SelectionState state, const SelectionStyle& style)
{
    m_styles[state] = style;
    qCDebug(jveSelectionVisualizer, "Custom style set for state %d", (int)state);
}

SelectionVisualizer::SelectionStyle SelectionVisualizer::getStyle(SelectionState state) const
{
    return m_styles.value(state, m_styles.value(Selected));
}

void SelectionVisualizer::setAnimationSettings(const AnimationSettings& settings)
{
    m_animationSettings = settings;
    qCDebug(jveSelectionVisualizer, "Animation settings updated: duration=%d, enabled=%s", 
            settings.duration, settings.enabled ? "true" : "false");
}

void SelectionVisualizer::setAnimationsEnabled(bool enabled)
{
    m_animationSettings.enabled = enabled;
    if (!enabled && m_currentAnimation && m_currentAnimation->state() == QPropertyAnimation::Running) {
        m_currentAnimation->stop();
    }
}

bool SelectionVisualizer::areAnimationsEnabled() const
{
    return m_animationSettings.enabled;
}

void SelectionVisualizer::renderSelection(QPainter& painter, const QRect& rect, SelectionState state)
{
    if (state == None) return;
    
    const SelectionStyle style = getStyle(state);
    
    painter.save();
    painter.setRenderHint(QPainter::Antialiasing, true);
    
    // Draw shadow first if enabled
    if (style.hasShadow) {
        drawSelectionShadow(painter, rect, style);
    }
    
    // Draw selection background
    renderSelectionBackground(painter, rect, state);
    
    // Draw selection outline
    renderSelectionOutline(painter, rect, state);
    
    painter.restore();
}

void SelectionVisualizer::renderSelectionBackground(QPainter& painter, const QRect& rect, SelectionState state)
{
    const SelectionStyle style = getStyle(state);
    QColor bgColor = style.backgroundColor;
    
    // Apply animation if in progress
    if (m_currentAnimation && m_currentAnimation->state() == QPropertyAnimation::Running) {
        const SelectionStyle fromStyle = getStyle(m_animatingFromState);
        const SelectionStyle toStyle = getStyle(m_animatingToState);
        bgColor = interpolateColor(fromStyle.backgroundColor, toStyle.backgroundColor, m_animationProgress);
    }
    
    QBrush brush = createSelectionBrush(bgColor, style.opacity);
    painter.setBrush(brush);
    painter.setPen(Qt::NoPen);
    
    if (style.cornerRadius > 0) {
        painter.drawRoundedRect(rect, style.cornerRadius, style.cornerRadius);
    } else {
        painter.drawRect(rect);
    }
}

void SelectionVisualizer::renderSelectionOutline(QPainter& painter, const QRect& rect, SelectionState state)
{
    const SelectionStyle style = getStyle(state);
    if (style.borderWidth <= 0) return;
    
    QColor borderColor = style.borderColor;
    
    // Apply animation if in progress
    if (m_currentAnimation && m_currentAnimation->state() == QPropertyAnimation::Running) {
        const SelectionStyle fromStyle = getStyle(m_animatingFromState);
        const SelectionStyle toStyle = getStyle(m_animatingToState);
        borderColor = interpolateColor(fromStyle.borderColor, toStyle.borderColor, m_animationProgress);
    }
    
    QPen pen = createSelectionPen(borderColor, style.borderWidth);
    painter.setPen(pen);
    painter.setBrush(Qt::NoBrush);
    
    if (style.cornerRadius > 0) {
        painter.drawRoundedRect(rect, style.cornerRadius, style.cornerRadius);
    } else {
        painter.drawRect(rect);
    }
}

void SelectionVisualizer::renderMultiSelection(QPainter& painter, const QList<QRect>& rects, SelectionState state)
{
    for (const QRect& rect : rects) {
        renderSelection(painter, rect, state);
    }
    
    // Add connecting lines for multi-selection if needed
    if (rects.size() > 1 && state == MultiSelected) {
        painter.save();
        QPen connectPen(SECONDARY_SELECTION_COLOR, 1, Qt::DashLine);
        painter.setPen(connectPen);
        
        for (int i = 1; i < rects.size(); ++i) {
            QPoint start = rects[i-1].center();
            QPoint end = rects[i].center();
            painter.drawLine(start, end);
        }
        
        painter.restore();
    }
}

void SelectionVisualizer::renderSelectedText(QPainter& painter, const QString& text, const QRect& rect, SelectionState state)
{
    QColor textColor = getTextColor(state);
    painter.setPen(textColor);
    painter.drawText(rect, Qt::AlignCenter, text);
}

QColor SelectionVisualizer::getTextColor(SelectionState state) const
{
    const SelectionStyle style = getStyle(state);
    return style.textColor;
}

void SelectionVisualizer::renderHoverEffect(QPainter& painter, const QRect& rect)
{
    painter.save();
    painter.setRenderHint(QPainter::Antialiasing, true);
    
    QColor hoverColor = HOVER_COLOR;
    hoverColor.setAlpha(100);
    
    QBrush brush(hoverColor);
    painter.setBrush(brush);
    painter.setPen(Qt::NoPen);
    painter.drawRoundedRect(rect, 3, 3);
    
    painter.restore();
}

void SelectionVisualizer::renderActiveEffect(QPainter& painter, const QRect& rect)
{
    painter.save();
    painter.setRenderHint(QPainter::Antialiasing, true);
    
    // Draw active glow effect
    drawSelectionGlow(painter, rect, ACTIVE_COLOR);
    
    painter.restore();
}

void SelectionVisualizer::renderFocusIndicator(QPainter& painter, const QRect& rect)
{
    painter.save();
    
    QPen focusPen(ACTIVE_COLOR, 2, Qt::DashLine);
    painter.setPen(focusPen);
    painter.setBrush(Qt::NoBrush);
    painter.drawRect(rect.adjusted(1, 1, -1, -1));
    
    painter.restore();
}

void SelectionVisualizer::renderSelectionHandles(QPainter& painter, const QRect& rect)
{
    painter.save();
    painter.setRenderHint(QPainter::Antialiasing, true);
    
    const int handleSize = 8;
    const QColor handleColor = PRIMARY_SELECTION_COLOR;
    const QColor handleBorder = QColor(255, 255, 255);
    
    // Corner handles
    QList<QPoint> handlePositions = {
        rect.topLeft(),
        rect.topRight(),
        rect.bottomLeft(),
        rect.bottomRight(),
        QPoint(rect.center().x(), rect.top()),    // Top center
        QPoint(rect.center().x(), rect.bottom()), // Bottom center
        QPoint(rect.left(), rect.center().y()),   // Left center
        QPoint(rect.right(), rect.center().y())   // Right center
    };
    
    for (const QPoint& pos : handlePositions) {
        QRect handleRect(pos.x() - handleSize/2, pos.y() - handleSize/2, handleSize, handleSize);
        
        // Draw handle
        painter.setBrush(QBrush(handleColor));
        painter.setPen(QPen(handleBorder, 1));
        painter.drawEllipse(handleRect);
    }
    
    painter.restore();
}

void SelectionVisualizer::renderSelectionBadge(QPainter& painter, const QRect& rect, const QString& text)
{
    if (text.isEmpty()) return;
    
    painter.save();
    painter.setRenderHint(QPainter::Antialiasing, true);
    
    // Position badge in top-right corner
    QFontMetrics fm(painter.font());
    QSize textSize = fm.size(Qt::TextSingleLine, text);
    QRect badgeRect(rect.right() - textSize.width() - 8, rect.top() - 2, 
                   textSize.width() + 8, textSize.height() + 4);
    
    // Draw badge background
    painter.setBrush(QBrush(ACTIVE_COLOR));
    painter.setPen(Qt::NoPen);
    painter.drawRoundedRect(badgeRect, 3, 3);
    
    // Draw badge text
    painter.setPen(QColor(0, 0, 0));
    painter.drawText(badgeRect, Qt::AlignCenter, text);
    
    painter.restore();
}

void SelectionVisualizer::renderTriStateIndicator(QPainter& painter, const QRect& rect, int state)
{
    painter.save();
    painter.setRenderHint(QPainter::Antialiasing, true);
    
    const int indicatorSize = 16;
    QRect indicatorRect(rect.left() + 4, rect.center().y() - indicatorSize/2, indicatorSize, indicatorSize);
    
    QColor indicatorColor;
    switch (state) {
        case 0: // None
            indicatorColor = Qt::transparent;
            break;
        case 1: // Partial
            indicatorColor = PARTIAL_COLOR;
            break;
        case 2: // Full
            indicatorColor = PRIMARY_SELECTION_COLOR;
            break;
    }
    
    if (indicatorColor != Qt::transparent) {
        painter.setBrush(QBrush(indicatorColor));
        painter.setPen(QPen(QColor(255, 255, 255), 1));
        
        if (state == 1) {
            // Partial - draw minus sign
            painter.drawEllipse(indicatorRect);
            painter.setPen(QPen(QColor(255, 255, 255), 2));
            int centerY = indicatorRect.center().y();
            painter.drawLine(indicatorRect.left() + 4, centerY, indicatorRect.right() - 4, centerY);
        } else {
            // Full - draw checkmark
            painter.drawEllipse(indicatorRect);
            painter.setPen(QPen(QColor(255, 255, 255), 2));
            QPoint p1(indicatorRect.left() + 4, indicatorRect.center().y());
            QPoint p2(indicatorRect.center().x(), indicatorRect.bottom() - 4);
            QPoint p3(indicatorRect.right() - 4, indicatorRect.top() + 4);
            painter.drawLine(p1, p2);
            painter.drawLine(p2, p3);
        }
    }
    
    painter.restore();
}

// Static utility methods
QColor SelectionVisualizer::adjustColorForState(const QColor& baseColor, SelectionState state)
{
    QColor adjusted = baseColor;
    
    switch (state) {
        case Hover:
            adjusted.setAlpha(adjusted.alpha() * 0.7);
            break;
        case Active:
            adjusted = adjusted.lighter(120);
            break;
        case Disabled:
            adjusted = adjusted.darker(150);
            adjusted.setAlpha(100);
            break;
        case Partial:
            adjusted.setAlpha(adjusted.alpha() * 0.6);
            break;
        default:
            break;
    }
    
    return adjusted;
}

QPen SelectionVisualizer::createSelectionPen(const QColor& color, int width)
{
    return QPen(color, width, Qt::SolidLine, Qt::SquareCap, Qt::MiterJoin);
}

QBrush SelectionVisualizer::createSelectionBrush(const QColor& color, double opacity)
{
    QColor brushColor = color;
    brushColor.setAlphaF(opacity);
    return QBrush(brushColor);
}

void SelectionVisualizer::setDevicePixelRatio(qreal ratio)
{
    m_devicePixelRatio = ratio;
}

qreal SelectionVisualizer::getDevicePixelRatio() const
{
    return m_devicePixelRatio;
}

// Slots
void SelectionVisualizer::onSelectionChanged(const QStringList& selectedItems)
{
    m_selectedItems = selectedItems;
    qCDebug(jveSelectionVisualizer, "Selection changed: %d items", selectedItems.size());
}

void SelectionVisualizer::onHoverChanged(const QString& hoveredItem)
{
    m_hoveredItem = hoveredItem;
}

void SelectionVisualizer::onActiveItemChanged(const QString& activeItem)
{
    m_activeItem = activeItem;
}

void SelectionVisualizer::onAnimationValueChanged(const QVariant& value)
{
    m_animationProgress = value.toReal();
}

void SelectionVisualizer::onAnimationFinished()
{
    emit animationCompleted();
}

// Private methods
void SelectionVisualizer::initializeDefaultStyles()
{
    setupTimelineStyle(); // Default to timeline style
}

void SelectionVisualizer::setupTimelineStyle()
{
    // Selected state
    SelectionStyle selectedStyle;
    selectedStyle.backgroundColor = QColor(PRIMARY_SELECTION_COLOR.red(), PRIMARY_SELECTION_COLOR.green(), PRIMARY_SELECTION_COLOR.blue(), 100);
    selectedStyle.borderColor = PRIMARY_SELECTION_COLOR;
    selectedStyle.textColor = QColor(255, 255, 255);
    selectedStyle.borderWidth = 2;
    selectedStyle.cornerRadius = 2;
    selectedStyle.opacity = 1.0;
    m_styles[Selected] = selectedStyle;
    
    // Hover state
    SelectionStyle hoverStyle;
    hoverStyle.backgroundColor = QColor(HOVER_COLOR.red(), HOVER_COLOR.green(), HOVER_COLOR.blue(), 50);
    hoverStyle.borderColor = HOVER_COLOR;
    hoverStyle.textColor = QColor(240, 240, 240);
    hoverStyle.borderWidth = 1;
    hoverStyle.cornerRadius = 2;
    hoverStyle.opacity = 0.8;
    m_styles[Hover] = hoverStyle;
    
    // Active state
    SelectionStyle activeStyle;
    activeStyle.backgroundColor = QColor(ACTIVE_COLOR.red(), ACTIVE_COLOR.green(), ACTIVE_COLOR.blue(), 150);
    activeStyle.borderColor = ACTIVE_COLOR;
    activeStyle.textColor = QColor(0, 0, 0);
    activeStyle.borderWidth = 3;
    activeStyle.cornerRadius = 2;
    activeStyle.opacity = 1.0;
    activeStyle.hasShadow = true;
    m_styles[Active] = activeStyle;
    
    // Multi-selected state
    SelectionStyle multiStyle;
    multiStyle.backgroundColor = QColor(SECONDARY_SELECTION_COLOR.red(), SECONDARY_SELECTION_COLOR.green(), SECONDARY_SELECTION_COLOR.blue(), 80);
    multiStyle.borderColor = SECONDARY_SELECTION_COLOR;
    multiStyle.textColor = QColor(255, 255, 255);
    multiStyle.borderWidth = 2;
    multiStyle.cornerRadius = 2;
    multiStyle.opacity = 0.9;
    m_styles[MultiSelected] = multiStyle;
    
    // Disabled state
    SelectionStyle disabledStyle;
    disabledStyle.backgroundColor = QColor(DISABLED_COLOR.red(), DISABLED_COLOR.green(), DISABLED_COLOR.blue(), 50);
    disabledStyle.borderColor = DISABLED_COLOR;
    disabledStyle.textColor = QColor(128, 128, 128);
    disabledStyle.borderWidth = 1;
    disabledStyle.cornerRadius = 2;
    disabledStyle.opacity = 0.5;
    m_styles[Disabled] = disabledStyle;
    
    // Partial state
    SelectionStyle partialStyle;
    partialStyle.backgroundColor = QColor(PARTIAL_COLOR.red(), PARTIAL_COLOR.green(), PARTIAL_COLOR.blue(), 100);
    partialStyle.borderColor = PARTIAL_COLOR;
    partialStyle.textColor = QColor(255, 255, 255);
    partialStyle.borderWidth = 1;
    partialStyle.cornerRadius = 2;
    partialStyle.opacity = 0.7;
    m_styles[Partial] = partialStyle;
}

void SelectionVisualizer::setupListStyle()
{
    // List-style selection (simpler, more subtle)
    SelectionStyle selectedStyle;
    selectedStyle.backgroundColor = QColor(PRIMARY_SELECTION_COLOR.red(), PRIMARY_SELECTION_COLOR.green(), PRIMARY_SELECTION_COLOR.blue(), 150);
    selectedStyle.borderColor = Qt::transparent;
    selectedStyle.textColor = QColor(255, 255, 255);
    selectedStyle.borderWidth = 0;
    selectedStyle.cornerRadius = 0;
    selectedStyle.opacity = 1.0;
    m_styles[Selected] = selectedStyle;
    
    // Copy for other states with adjustments
    m_styles[Hover] = selectedStyle;
    m_styles[Hover].backgroundColor.setAlpha(80);
    m_styles[Hover].textColor = QColor(240, 240, 240);
    
    m_styles[MultiSelected] = selectedStyle;
    m_styles[MultiSelected].backgroundColor = QColor(SECONDARY_SELECTION_COLOR.red(), SECONDARY_SELECTION_COLOR.green(), SECONDARY_SELECTION_COLOR.blue(), 120);
}

void SelectionVisualizer::setupPropertyStyle()
{
    // Property-style selection (subtle highlighting)
    SelectionStyle selectedStyle;
    selectedStyle.backgroundColor = QColor(PRIMARY_SELECTION_COLOR.red(), PRIMARY_SELECTION_COLOR.green(), PRIMARY_SELECTION_COLOR.blue(), 60);
    selectedStyle.borderColor = PRIMARY_SELECTION_COLOR;
    selectedStyle.textColor = QColor(255, 255, 255);
    selectedStyle.borderWidth = 1;
    selectedStyle.cornerRadius = 4;
    selectedStyle.opacity = 1.0;
    m_styles[Selected] = selectedStyle;
    
    // Similar setup for other states
    setupListStyle(); // Use list style as base and modify
}

void SelectionVisualizer::setupTreeStyle()
{
    // Tree-style selection (hierarchical highlighting)
    setupListStyle(); // Use list style as base
    
    // Add indentation-aware styling if needed
    SelectionStyle selectedStyle = m_styles[Selected];
    selectedStyle.cornerRadius = 3;
    m_styles[Selected] = selectedStyle;
}

void SelectionVisualizer::setupTabStyle()
{
    // Tab-style selection (button-like highlighting)
    SelectionStyle selectedStyle;
    selectedStyle.backgroundColor = QColor(PRIMARY_SELECTION_COLOR.red(), PRIMARY_SELECTION_COLOR.green(), PRIMARY_SELECTION_COLOR.blue(), 200);
    selectedStyle.borderColor = PRIMARY_SELECTION_COLOR.darker(120);
    selectedStyle.textColor = QColor(255, 255, 255);
    selectedStyle.borderWidth = 2;
    selectedStyle.cornerRadius = 6;
    selectedStyle.opacity = 1.0;
    selectedStyle.hasShadow = true;
    m_styles[Selected] = selectedStyle;
}

void SelectionVisualizer::startAnimation(SelectionState fromState, SelectionState toState)
{
    if (!m_animationSettings.enabled) return;
    
    if (m_currentAnimation && m_currentAnimation->state() == QPropertyAnimation::Running) {
        m_currentAnimation->stop();
    }
    
    m_animatingFromState = fromState;
    m_animatingToState = toState;
    
    m_currentAnimation->setDuration(m_animationSettings.duration);
    m_currentAnimation->setEasingCurve(m_animationSettings.curve);
    m_currentAnimation->setStartValue(0.0);
    m_currentAnimation->setEndValue(1.0);
    
    m_currentAnimation->start();
}

QColor SelectionVisualizer::interpolateColor(const QColor& from, const QColor& to, qreal factor)
{
    if (factor <= 0.0) return from;
    if (factor >= 1.0) return to;
    
    int r = from.red() + factor * (to.red() - from.red());
    int g = from.green() + factor * (to.green() - from.green());
    int b = from.blue() + factor * (to.blue() - from.blue());
    int a = from.alpha() + factor * (to.alpha() - from.alpha());
    
    return QColor(r, g, b, a);
}

void SelectionVisualizer::drawRoundedSelection(QPainter& painter, const QRect& rect, const SelectionStyle& style)
{
    if (style.cornerRadius > 0) {
        painter.drawRoundedRect(rect, style.cornerRadius, style.cornerRadius);
    } else {
        painter.drawRect(rect);
    }
}

void SelectionVisualizer::drawSelectionGlow(QPainter& painter, const QRect& rect, const QColor& color)
{
    QRadialGradient gradient(rect.center(), rect.width() / 2);
    gradient.setColorAt(0, QColor(color.red(), color.green(), color.blue(), 100));
    gradient.setColorAt(1, QColor(color.red(), color.green(), color.blue(), 0));
    
    painter.setBrush(QBrush(gradient));
    painter.setPen(Qt::NoPen);
    painter.drawEllipse(rect.adjusted(-10, -10, 10, 10));
}

void SelectionVisualizer::drawSelectionShadow(QPainter& painter, const QRect& rect, const SelectionStyle& style)
{
    if (!style.hasShadow) return;
    
    QRect shadowRect = rect.adjusted(style.shadowOffset, style.shadowOffset, style.shadowOffset, style.shadowOffset);
    painter.setBrush(QBrush(style.shadowColor));
    painter.setPen(Qt::NoPen);
    
    if (style.cornerRadius > 0) {
        painter.drawRoundedRect(shadowRect, style.cornerRadius, style.cornerRadius);
    } else {
        painter.drawRect(shadowRect);
    }
}