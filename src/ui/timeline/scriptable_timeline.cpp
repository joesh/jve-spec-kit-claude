#include "scriptable_timeline.h"
#include <QPaintEvent>
#include <QDebug>

namespace JVE {

ScriptableTimeline::ScriptableTimeline(const std::string& widget_id, QWidget* parent)
    : QWidget(parent), widget_id_(widget_id)
{
    // Set minimum size for timeline
    setMinimumSize(400, 200);
    
    // Enable mouse tracking for interactive features
    setMouseTracking(true);
    
    qDebug() << "ScriptableTimeline created with widget_id:" << QString::fromStdString(widget_id);
}

void ScriptableTimeline::clearCommands()
{
    drawing_commands_.clear();
}

void ScriptableTimeline::addRect(int x, int y, int width, int height, const QString& color)
{
    DrawCommand cmd;
    cmd.type = DrawCommand::RECT;
    cmd.x = x;
    cmd.y = y;
    cmd.width = width;
    cmd.height = height;
    cmd.color = QColor(color);
    drawing_commands_.push_back(cmd);
}

void ScriptableTimeline::addText(int x, int y, const QString& text, const QString& color)
{
    DrawCommand cmd;
    cmd.type = DrawCommand::TEXT;
    cmd.x = x;
    cmd.y = y;
    cmd.text = text;
    cmd.color = QColor(color);
    drawing_commands_.push_back(cmd);
}

void ScriptableTimeline::addLine(int x1, int y1, int x2, int y2, const QString& color, int width)
{
    DrawCommand cmd;
    cmd.type = DrawCommand::LINE;
    cmd.x = x1;
    cmd.y = y1;
    cmd.x2 = x2;
    cmd.y2 = y2;
    cmd.color = QColor(color);
    cmd.line_width = width;
    drawing_commands_.push_back(cmd);
}

void ScriptableTimeline::renderTestTimeline()
{
    clearCommands();
    
    // Draw ruler
    addRect(0, 0, 800, 30, "#444444");
    
    // Draw time markers
    for (int i = 0; i <= 8; ++i) {
        int x = 150 + i * 100;
        addLine(x, 20, x, 30, "#cccccc", 1);
        addText(x + 2, 15, QString("%1s").arg(i), "#cccccc");
    }
    
    // Draw track headers
    addRect(0, 30, 150, 50, "#333333");
    addText(10, 55, "Video 1", "#cccccc");
    
    addRect(0, 80, 150, 50, "#333333");
    addText(10, 105, "Audio 1", "#cccccc");
    
    // Draw track areas
    addRect(150, 30, 650, 50, "#252525");
    addRect(150, 80, 650, 50, "#2a2a2a");
    
    // Draw sample clips
    addRect(250, 35, 200, 40, "#4a90e2");
    addText(255, 55, "Beach Scene", "#cccccc");
    
    addRect(350, 85, 300, 40, "#4a90e2");
    addText(355, 105, "Music Track", "#cccccc");
    
    // Draw playhead
    addLine(400, 0, 400, 130, "#ff6b6b", 2);
    addRect(395, 0, 10, 10, "#ff6b6b");
    
    update(); // Trigger repaint
}

void ScriptableTimeline::paintEvent(QPaintEvent* event)
{
    QPainter painter(this);
    painter.setRenderHint(QPainter::Antialiasing);
    
    // Fill background
    painter.fillRect(rect(), QColor(35, 35, 35));
    
    // Execute all drawing commands from Lua
    executeDrawingCommands(painter);
}

void ScriptableTimeline::executeDrawingCommands(QPainter& painter)
{
    for (const auto& cmd : drawing_commands_) {
        painter.setPen(QPen(cmd.color, cmd.line_width));
        painter.setBrush(QBrush(cmd.color));
        
        switch (cmd.type) {
            case DrawCommand::RECT:
                painter.fillRect(cmd.x, cmd.y, cmd.width, cmd.height, cmd.color);
                break;
                
            case DrawCommand::TEXT:
                painter.setPen(cmd.color);
                painter.drawText(cmd.x, cmd.y, cmd.text);
                break;
                
            case DrawCommand::LINE:
                painter.setPen(QPen(cmd.color, cmd.line_width));
                painter.drawLine(cmd.x, cmd.y, cmd.x2, cmd.y2);
                break;
        }
    }
}

} // namespace JVE