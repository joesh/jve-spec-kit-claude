#include <QApplication>
#include <QStyleFactory>
#include <QDir>
#include <QStandardPaths>
#include <QLoggingCategory>

#include "ui/main_window.h"
#include "ui/theme/dark_theme.h"
#include "lua/runtime/lua_runtime.h"
#include "core/persistence/migrations.h"

Q_LOGGING_CATEGORY(jveMain, "jve.main")

int main(int argc, char *argv[])
{
    QApplication app(argc, argv);
    
    // Application metadata
    app.setApplicationName("JVE Editor");
    app.setApplicationVersion("1.0.0");
    app.setApplicationDisplayName("JVE Video Editor");
    app.setOrganizationName("JVE Project");
    app.setOrganizationDomain("jve-editor.org");
    
    // Initialize logging
    QLoggingCategory::setFilterRules("jve.*=true");
    
    // Apply dark theme
    DarkTheme::apply(&app);
    
    // Initialize Lua runtime
    LuaRuntime::initialize();
    
    // Set up application data directory
    QString appDataDir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    if (!QDir().mkpath(appDataDir)) {
        qCCritical(jveMain) << "Failed to create application data directory:" << appDataDir;
        return -1;
    }
    
    // Initialize database migrations
    Migrations::initialize();
    
    // Create and show main window
    MainWindow window;
    window.show();
    
    qCInfo(jveMain) << "JVE Editor started successfully";
    
    int result = app.exec();
    
    // Cleanup
    LuaRuntime::cleanup();
    
    qCInfo(jveMain) << "JVE Editor shutdown complete";
    
    return result;
}