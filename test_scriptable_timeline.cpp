#include <QApplication>
#include <QMainWindow>
#include <QVBoxLayout>
#include <QWidget>
#include <QPushButton>
#include "src/ui/timeline/scriptable_timeline.h"

int main(int argc, char *argv[])
{
    QApplication app(argc, argv);
    
    QMainWindow window;
    window.setWindowTitle("Scriptable Timeline Test");
    window.resize(900, 200);
    
    QWidget* centralWidget = new QWidget();
    window.setCentralWidget(centralWidget);
    
    QVBoxLayout* layout = new QVBoxLayout(centralWidget);
    
    // Create scriptable timeline
    JVE::ScriptableTimeline* timeline = new JVE::ScriptableTimeline("test_timeline");
    timeline->setMinimumHeight(150);
    
    // Create button to trigger test rendering
    QPushButton* testButton = new QPushButton("Render Test Timeline");
    QObject::connect(testButton, &QPushButton::clicked, [timeline]() {
        timeline->renderTestTimeline();
    });
    
    layout->addWidget(testButton);
    layout->addWidget(timeline);
    
    // Render initial test timeline
    timeline->renderTestTimeline();
    
    window.show();
    
    return app.exec();
}