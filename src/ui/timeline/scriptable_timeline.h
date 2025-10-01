#pragma once

#include <QWidget>
#include <QPainter>
#include <QColor>
#include <QString>
#include <vector>

namespace JVE {

/**
 * Scriptable Timeline Widget - Minimal C++ rendering surface for command-based timeline
 * 
 * This widget implements the principle: "only performance-heavy stuff in C++, everything else in scripts"
 * 
 * C++ responsibilities:
 * - Execute drawing commands efficiently in paintEvent()
 * - Provide simple interface for sending drawing commands
 * 
 * Script responsibilities (future Lua integration):
 * - All timeline logic (playhead, ruler, tracks, clips)
 * - All user interaction handling
 * - All business logic and state management
 */
class ScriptableTimeline : public QWidget
{
    Q_OBJECT

public:
    explicit ScriptableTimeline(const std::string& widget_id, QWidget* parent = nullptr);
    ~ScriptableTimeline() = default;

    // Drawing command interface (for future Lua integration)
    void clearCommands();
    void addRect(int x, int y, int width, int height, const QString& color);
    void addText(int x, int y, const QString& text, const QString& color);
    void addLine(int x1, int y1, int x2, int y2, const QString& color, int width = 1);
    
    // Test method to demonstrate command system
    void renderTestTimeline();

protected:
    void paintEvent(QPaintEvent* event) override;

private:
    // Drawing command structure
    struct DrawCommand {
        enum Type { RECT, TEXT, LINE } type;
        int x, y, width, height;
        int x2, y2; // For lines
        QString text;
        QColor color;
        int line_width = 1;
    };

    // Execute all drawing commands
    void executeDrawingCommands(QPainter& painter);

    // Drawing commands queue
    std::vector<DrawCommand> drawing_commands_;
    
    // Widget identifier for Lua integration
    std::string widget_id_;
};

} // namespace JVE