#include <QApplication>
#include <QStyleFactory>
#include <QDir>
#include <QStandardPaths>
#include <QLoggingCategory>
#include <QWidget>
#include <QVBoxLayout>
#include <QLabel>
#include <QFileInfo>

#include "lua/simple_lua_engine.h"
#include "core/persistence/migrations.h"
#include "core/resource_paths.h"

Q_LOGGING_CATEGORY(jveMain, "jve.main")

int main(int argc, char *argv[])
{
    // Enable high DPI scaling
    QApplication::setAttribute(Qt::AA_EnableHighDpiScaling);
    QApplication::setAttribute(Qt::AA_UseHighDpiPixmaps);
    
    QApplication app(argc, argv);
    
    // Application metadata
    app.setApplicationName("JVE Editor");
    app.setApplicationVersion("1.0.0");
    app.setApplicationDisplayName("JVE Video Editor - Professional NLE");
    app.setOrganizationName("JVE Project");
    app.setOrganizationDomain("jve-editor.org");
    
    // Initialize logging
    QLoggingCategory::setFilterRules("jve.*=true");
    
    // Apply professional dark theme
    app.setStyle(QStyleFactory::create("Fusion"));
    QPalette darkPalette;
    darkPalette.setColor(QPalette::Window, QColor(30, 30, 30));
    darkPalette.setColor(QPalette::WindowText, Qt::white);
    darkPalette.setColor(QPalette::Base, QColor(25, 25, 25));
    darkPalette.setColor(QPalette::AlternateBase, QColor(35, 35, 35));
    darkPalette.setColor(QPalette::ToolTipBase, Qt::white);
    darkPalette.setColor(QPalette::ToolTipText, Qt::white);
    darkPalette.setColor(QPalette::Text, Qt::white);
    darkPalette.setColor(QPalette::Button, QColor(35, 35, 35));
    darkPalette.setColor(QPalette::ButtonText, Qt::white);
    darkPalette.setColor(QPalette::BrightText, Qt::red);
    darkPalette.setColor(QPalette::Link, QColor(42, 130, 218));
    darkPalette.setColor(QPalette::Highlight, QColor(42, 130, 218));
    darkPalette.setColor(QPalette::HighlightedText, Qt::black);
    app.setPalette(darkPalette);
    
    // Set up application data directory
    QString appDataDir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    if (!QDir().mkpath(appDataDir)) {
        qCCritical(jveMain, "Failed to create application data directory: %s", qPrintable(appDataDir));
        return -1;
    }
    
    // Initialize database migrations
    Migrations::initialize();
    
    // Create Lua engine for pure Lua UI
    SimpleLuaEngine luaEngine;
    
    // Execute Lua main window creation using ResourcePaths
    QString scriptsDir = QString::fromStdString(JVE::ResourcePaths::getScriptsDirectory());
    QString mainWindowScript = QString::fromStdString(JVE::ResourcePaths::getScriptPath("ui/correct_layout.lua"));
    
    qCInfo(jveMain, "Starting pure Lua UI system...");
    qCInfo(jveMain, "Scripts directory: %s", qPrintable(scriptsDir));
    qCInfo(jveMain, "Main window script: %s", qPrintable(mainWindowScript));
    
    if (!QFileInfo(mainWindowScript).exists()) {
        qCCritical(jveMain, "Main window script not found: %s", qPrintable(mainWindowScript));
        return -1;
    }
    
    // Execute Lua main window creation with real LuaJIT integration
    qCInfo(jveMain, "Executing Lua main window creation with LuaJIT...");
    bool luaSuccess = luaEngine.executeFile(mainWindowScript);
    
    if (!luaSuccess) {
        qCCritical(jveMain, "Failed to execute Lua main window script: %s", 
                   qPrintable(luaEngine.getLastError()));
        return -1;
    }
    
    // Get the main window created by Lua to keep it alive
    QWidget* mainWindow = luaEngine.getCreatedMainWindow();
    if (!mainWindow) {
        qCCritical(jveMain, "No main window was created by Lua script");
        return -1;
    }
    
    qCInfo(jveMain, "JVE Editor started successfully - Pure Lua UI system ready");
    qCInfo(jveMain, "Main window: %p", mainWindow);
    qCInfo(jveMain, "Qt version: %s", QT_VERSION_STR);
    qCInfo(jveMain, "Application directory: %s", qPrintable(QApplication::applicationDirPath()));
    
    int result = app.exec();
    
    qCInfo(jveMain, "JVE Editor shutdown complete");
    
    return result;
}