#include "gesture_logger.h"
#include <QApplication>
#include <QWidget>

namespace bug_reporter {

GestureLogger::GestureLogger(QObject* parent)
    : QObject(parent)
    , m_enabled(true)
    , m_callback(nullptr)
{
}

void GestureLogger::install() {
    qApp->installEventFilter(this);
}

void GestureLogger::uninstall() {
    qApp->removeEventFilter(this);
}

void GestureLogger::setEnabled(bool enabled) {
    m_enabled = enabled;
}

bool GestureLogger::isEnabled() const {
    return m_enabled;
}

void GestureLogger::setCallback(GestureCallback callback) {
    m_callback = callback;
}

bool GestureLogger::eventFilter(QObject* obj, QEvent* event) {
    if (!m_enabled || !m_callback) {
        return QObject::eventFilter(obj, event);
    }

    GestureEvent gesture;
    bool shouldLog = false;

    switch (event->type()) {
        case QEvent::MouseButtonPress:
            gesture = convertMouseEvent(static_cast<QMouseEvent*>(event), "mouse_press");
            shouldLog = true;
            break;

        case QEvent::MouseButtonRelease:
            gesture = convertMouseEvent(static_cast<QMouseEvent*>(event), "mouse_release");
            shouldLog = true;
            break;

        case QEvent::MouseMove:
            // Only log mouse moves during drag (button pressed)
            if (static_cast<QMouseEvent*>(event)->buttons() != Qt::NoButton) {
                gesture = convertMouseEvent(static_cast<QMouseEvent*>(event), "mouse_drag");
                shouldLog = true;
            }
            break;

        case QEvent::KeyPress:
            gesture = convertKeyEvent(static_cast<QKeyEvent*>(event), "key_press");
            shouldLog = true;
            break;

        case QEvent::KeyRelease:
            gesture = convertKeyEvent(static_cast<QKeyEvent*>(event), "key_release");
            shouldLog = true;
            break;

        case QEvent::Wheel:
            gesture = convertWheelEvent(static_cast<QWheelEvent*>(event));
            shouldLog = true;
            break;

        default:
            // Ignore other event types
            break;
    }

    if (shouldLog) {
        m_callback(gesture);
    }

    // Don't intercept events, just observe
    return QObject::eventFilter(obj, event);
}

GestureEvent GestureLogger::convertMouseEvent(QMouseEvent* event, const QString& type) {
    GestureEvent gesture;
    gesture.type = type;
    gesture.screen_x = event->globalPosition().toPoint().x();
    gesture.screen_y = event->globalPosition().toPoint().y();
    gesture.window_x = event->position().toPoint().x();
    gesture.window_y = event->position().toPoint().y();
    gesture.button = buttonToString(event->button());
    gesture.modifiers = extractModifiers(event->modifiers());
    gesture.delta = 0;
    return gesture;
}

GestureEvent GestureLogger::convertKeyEvent(QKeyEvent* event, const QString& type) {
    GestureEvent gesture;
    gesture.type = type;
    gesture.screen_x = 0;
    gesture.screen_y = 0;
    gesture.window_x = 0;
    gesture.window_y = 0;
    gesture.key = keyToString(event->key());
    gesture.modifiers = extractModifiers(event->modifiers());
    gesture.delta = 0;
    return gesture;
}

GestureEvent GestureLogger::convertWheelEvent(QWheelEvent* event) {
    GestureEvent gesture;
    gesture.type = "wheel_scroll";
    gesture.screen_x = event->globalPosition().toPoint().x();
    gesture.screen_y = event->globalPosition().toPoint().y();
    gesture.window_x = event->position().toPoint().x();
    gesture.window_y = event->position().toPoint().y();
    gesture.modifiers = extractModifiers(event->modifiers());
    gesture.delta = event->angleDelta().y();
    return gesture;
}

QStringList GestureLogger::extractModifiers(Qt::KeyboardModifiers mods) {
    QStringList result;
    if (mods & Qt::ShiftModifier) result << "Shift";
    if (mods & Qt::ControlModifier) result << "Ctrl";
    if (mods & Qt::AltModifier) result << "Alt";
    if (mods & Qt::MetaModifier) result << "Meta";
    return result;
}

QString GestureLogger::buttonToString(Qt::MouseButton button) {
    switch (button) {
        case Qt::LeftButton: return "left";
        case Qt::RightButton: return "right";
        case Qt::MiddleButton: return "middle";
        default: return "unknown";
    }
}

QString GestureLogger::keyToString(int key) {
    // Handle common keys
    switch (key) {
        case Qt::Key_Return: return "Return";
        case Qt::Key_Enter: return "Enter";
        case Qt::Key_Escape: return "Escape";
        case Qt::Key_Tab: return "Tab";
        case Qt::Key_Backspace: return "Backspace";
        case Qt::Key_Delete: return "Delete";
        case Qt::Key_Space: return "Space";
        case Qt::Key_Left: return "Left";
        case Qt::Key_Right: return "Right";
        case Qt::Key_Up: return "Up";
        case Qt::Key_Down: return "Down";
        default:
            // For printable characters, convert to string
            if (key >= 0x20 && key <= 0x7E) {
                return QString(QChar(key));
            }
            return QString("Key_%1").arg(key);
    }
}

} // namespace bug_reporter
