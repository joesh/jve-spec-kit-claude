#include <QApplication>
#include <QStyleFactory>
#include <QDir>
#include <QStandardPaths>
#include <QLoggingCategory>
#include <QWidget>
#include <QVBoxLayout>
#include <QLabel>
#include <QFileInfo>
#include <QProcessEnvironment>
#include <QFile>
#include <iostream>
#include <cstring>

#include "simple_lua_engine.h"
#include "resource_paths.h"

Q_LOGGING_CATEGORY(jveMain, "jve.main")

static void printHelp(const char* programName)
{
    std::cout << "JVE Editor - Professional Video Editor\n";
    std::cout << "Usage: " << programName << " [options] [project.jvp]\n";
    std::cout << "\n";
    std::cout << "Options:\n";
    std::cout << "  --help, -h          Show this help message and exit\n";
    std::cout << "  --version, -v       Show version information and exit\n";
    std::cout << "\n";
    std::cout << "Arguments:\n";
    std::cout << "  project.jvp         Path to project file (created if doesn't exist)\n";
    std::cout << "                      Default: ~/Documents/JVE Projects/Untitled Project.jvp\n";
    std::cout << "\n";
    std::cout << "Debug Environment Variables:\n";
    std::cout << "  JVE_DEBUG_STARTUP=1\n";
    std::cout << "      Enable verbose Qt logging during startup.\n";
    std::cout << "      Shows debug/info messages from all jve.* logging categories.\n";
    std::cout << "\n";
    std::cout << "  JVE_DEBUG_PLAYHEAD=1\n";
    std::cout << "      Log playhead rendering dimensions to diagnose ruler/timeline alignment.\n";
    std::cout << "      Shows width values used for time-to-pixel calculations.\n";
    std::cout << "\n";
    std::cout << "  JVE_DEBUG_FOCUS=1\n";
    std::cout << "      Log focus management events (focus changes, widget tracking).\n";
    std::cout << "\n";
    std::cout << "  JVE_DEBUG_COMMAND_PERF=1\n";
    std::cout << "      Log command execution performance timings.\n";
    std::cout << "\n";
    std::cout << "  JVE_DEBUG_SNAPPING=1\n";
    std::cout << "      Log magnetic snapping calculations during edge dragging.\n";
    std::cout << "\n";
    std::cout << "  JVE_DEBUG_EDGE_PREVIEW=1\n";
    std::cout << "      Log edge preview calculations during trim/ripple operations.\n";
    std::cout << "\n";
    std::cout << "  JVE_DEBUG_RIPPLE_DELETE_SELECTION=1\n";
    std::cout << "      Log ripple delete selection command details.\n";
    std::cout << "\n";
    std::cout << "Example:\n";
    std::cout << "  JVE_DEBUG_PLAYHEAD=1 " << programName << " myproject.jvp\n";
    std::cout << "\n";
}

static void printVersion()
{
    std::cout << "JVE Editor version 1.0.0\n";
    std::cout << "Built with Qt " << QT_VERSION_STR << "\n";
}

static void configureLogging()
{
    if (qEnvironmentVariableIsSet("QT_LOGGING_RULES")) {
        return;
    }

    const bool debugStartup = qEnvironmentVariableIsSet("JVE_DEBUG_STARTUP")
        && qgetenv("JVE_DEBUG_STARTUP") == QByteArrayLiteral("1");

    if (debugStartup) {
        QLoggingCategory::setFilterRules(
            "jve.*.debug=true\n"
            "jve.*.info=true\n"
            "jve.*.warning=true\n"
            "jve.*.critical=true\n"
        );
        return;
    }

    QLoggingCategory::setFilterRules(
        "jve.*.debug=false\n"
        "jve.*.info=false\n"
        "jve.*.warning=true\n"
        "jve.*.critical=true\n"
    );
}

int main(int argc, char *argv[])
{
    // Handle --help and --version before creating QApplication
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--help") == 0 || std::strcmp(argv[i], "-h") == 0) {
            printHelp(argv[0]);
            return 0;
        }
        if (std::strcmp(argv[i], "--version") == 0 || std::strcmp(argv[i], "-v") == 0) {
            printVersion();
            return 0;
        }
    }

    // Note: High DPI scaling is enabled by default in Qt 6
    // Qt::AA_EnableHighDpiScaling and Qt::AA_UseHighDpiPixmaps are deprecated

    QApplication app(argc, argv);
    
    // Application metadata
    app.setApplicationName("JVE Editor");
    app.setApplicationVersion("1.0.0");
    app.setApplicationDisplayName("JVE Video Editor - Professional NLE");
    app.setOrganizationName("JVE Project");
    app.setOrganizationDomain("jve-editor.org");
    
    // Initialize logging (quiet by default; opt-in via JVE_DEBUG_STARTUP=1).
    configureLogging();
    
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
    
    // Determine project path (.jvp file)
    QString projectPath;
    if (argc > 1) {
        projectPath = QString::fromLocal8Bit(argv[1]);
        if (!projectPath.endsWith(".jvp", Qt::CaseInsensitive)) {
            projectPath += ".jvp";
        }

        QFileInfo projectInfo(projectPath);
        if (projectInfo.isRelative()) {
            projectInfo.setFile(QDir::current(), projectPath);
        }
        projectPath = projectInfo.absoluteFilePath();

        QDir projectDir = projectInfo.dir();
        if (!projectDir.exists()) {
            projectDir.mkpath(".");
        }

        qputenv("JVE_PROJECT_PATH", projectPath.toUtf8());
        qunsetenv("JVE_TEST_MODE");
        qCInfo(jveMain, "Opening project from CLI argument: %s", qPrintable(projectPath));
    } else {
        const QString defaultDir = QDir(QDir::homePath()).filePath("Documents/JVE Projects");
        QDir().mkpath(defaultDir);
        projectPath = QDir(defaultDir).filePath("Untitled Project.jvp");
        qputenv("JVE_PROJECT_PATH", projectPath.toUtf8());
        qunsetenv("JVE_TEST_MODE");
        qCInfo(jveMain, "Opening default project: %s", qPrintable(projectPath));
    }

    // Create Lua engine for pure Lua UI
    SimpleLuaEngine luaEngine;
    
    // Execute Lua main window creation using ResourcePaths
    QString scriptsDir = QString::fromStdString(JVE::ResourcePaths::getScriptsDirectory());
    QString mainWindowScript = QString::fromStdString(JVE::ResourcePaths::getScriptPath("ui/layout.lua"));
    
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
    qCInfo(jveMain, "Main window: %p", static_cast<void*>(mainWindow));
    qCInfo(jveMain, "Qt version: %s", QT_VERSION_STR);
    qCInfo(jveMain, "Application directory: %s", qPrintable(QApplication::applicationDirPath()));
    
    int result = app.exec();
    
    qCInfo(jveMain, "JVE Editor shutdown complete");
    
    return result;
}
