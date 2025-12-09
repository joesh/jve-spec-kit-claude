#pragma once

#include <QObject>
#include <QEvent>
#include <QMouseEvent>
#include <QKeyEvent>
#include <QWheelEvent>
#include <functional>

namespace bug_reporter {

struct GestureEvent {
    QString type;              // "mouse_press", "mouse_move", "key_press", etc.
    int screen_x;              // Absolute screen coordinates
    int screen_y;
    int window_x;              // Window-relative coordinates
    int window_y;
    QString button;            // "left", "right", "middle" (for mouse)
    QString key;               // Key name (for keyboard)
    QStringList modifiers;     // "Shift", "Ctrl", "Alt", "Meta"
    int delta;                 // Wheel delta (for scroll events)
};

using GestureCallback = std::function<void(const GestureEvent&)>;

/**
 * Event filter that captures user input gestures for bug reporting.
 * Installed on QApplication to capture all events globally.
 */
class GestureLogger : public QObject {
    Q_OBJECT

public:
    explicit GestureLogger(QObject* parent = nullptr);

    // Install/remove event filter
    void install();
    void uninstall();

    // Enable/disable gesture capture
    void setEnabled(bool enabled);
    bool isEnabled() const;

    // Set callback for gesture events (called from Lua)
    void setCallback(GestureCallback callback);

protected:
    bool eventFilter(QObject* obj, QEvent* event) override;

private:
    bool m_enabled;
    GestureCallback m_callback;

    // Helper functions
    GestureEvent convertMouseEvent(QMouseEvent* event, const QString& type);
    GestureEvent convertKeyEvent(QKeyEvent* event, const QString& type);
    GestureEvent convertWheelEvent(QWheelEvent* event);
    QStringList extractModifiers(Qt::KeyboardModifiers mods);
    QString buttonToString(Qt::MouseButton button);
    QString keyToString(int key);
};

} // namespace bug_reporter
