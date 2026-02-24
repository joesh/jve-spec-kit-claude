#include <QApplication>
#include <QStyleFactory>
#include <QDir>
#include <QStandardPaths>
#include <QWidget>
#include <QVBoxLayout>
#include <QLabel>
#include <QFileInfo>
#include <QFile>
#include <iostream>
#include <cstring>
#include <cstdio>

#include "simple_lua_engine.h"
#include "resource_paths.h"
#include "assert_handler.h"
#include "jve_log.h"

static void printHelp(const char* programName)
{
    std::cout << "JVE Editor - Professional Video Editor\n";
    std::cout << "Usage: " << programName << " [options] [project.jvp]\n";
    std::cout << "\n";
    std::cout << "Options:\n";
    std::cout << "  --help, -h          Show this help message and exit\n";
    std::cout << "  --version, -v       Show version information and exit\n";
    std::cout << "  --test <script>     Run a Lua test script with full C++ bindings, then exit\n";
    std::cout << "\n";
    std::cout << "Arguments:\n";
    std::cout << "  project.jvp         Path to project file (created if doesn't exist)\n";
    std::cout << "                      Default: ~/Documents/JVE Projects/Untitled Project.jvp\n";
    std::cout << "\n";
    std::cout << "Logging:\n";
    std::cout << "  JVE_LOG=<spec>      Configure logging areas and levels\n";
    std::cout << "\n";
    std::cout << "  Areas:    ticks, audio, video, timeline, commands, database, ui, media\n";
    std::cout << "  Meta:     play (= ticks+audio+video), all (= every area)\n";
    std::cout << "  Levels:   detail, event, warn, error, none\n";
    std::cout << "  Default:  all areas at warn (WARN+ERROR on, EVENT+DETAIL off)\n";
    std::cout << "\n";
    std::cout << "  Examples:\n";
    std::cout << "    JVE_LOG=play:detail              # Debug playback (per-frame data)\n";
    std::cout << "    JVE_LOG=audio:event              # Audio state transitions\n";
    std::cout << "    JVE_LOG=play:detail,commands:event\n";
    std::cout << "    JVE_LOG=all:detail               # Everything (noisy)\n";
    std::cout << "    JVE_LOG=all:none                 # Silent\n";
    std::cout << "\n";
}

static void printVersion()
{
    std::cout << "JVE Editor version 1.0.0\n";
    std::cout << "Built with Qt " << QT_VERSION_STR << "\n";
}

int main(int argc, char *argv[])
{
    // Install abort handler early to catch all assert()/abort() with stack traces
    jve_install_abort_handler();

    // Initialize unified logging (parses JVE_LOG env var)
    jve_init_log();

    // Handle --help, --version, and --test before creating QApplication
    const char* testScript = nullptr;
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--help") == 0 || std::strcmp(argv[i], "-h") == 0) {
            printHelp(argv[0]);
            return 0;
        }
        if (std::strcmp(argv[i], "--version") == 0 || std::strcmp(argv[i], "-v") == 0) {
            printVersion();
            return 0;
        }
        if (std::strcmp(argv[i], "--test") == 0) {
            if (i + 1 >= argc) {
                std::cerr << "ERROR: --test requires a script path argument\n";
                return 1;
            }
            testScript = argv[i + 1];
            ++i; // skip the script argument in further parsing
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

    // --test mode: run a Lua script with full C++ bindings, then exit
    if (testScript) {
        qputenv("JVE_TEST_MODE", "1");

        SimpleLuaEngine luaEngine;

        // Add tests/ to package.path so integration tests can require("integration.integration_test_env")
        lua_State* L = luaEngine.getLuaState();
        std::string appDir = JVE::ResourcePaths::getApplicationDirectory();
        std::string testsDir = appDir + "/tests";

        lua_getglobal(L, "package");
        lua_getfield(L, -1, "path");
        std::string currentPath = lua_isstring(L, -1) ? lua_tostring(L, -1) : "";
        lua_pop(L, 1);

        std::string newPath = testsDir + "/?.lua;" + testsDir + "/?/init.lua;" + currentPath;
        lua_pushstring(L, newPath.c_str());
        lua_setfield(L, -2, "path");
        lua_pop(L, 1); // pop package table

        // Resolve test script path (relative to appDir if not absolute)
        QString scriptPath = QString::fromLocal8Bit(testScript);
        QFileInfo scriptInfo(scriptPath);
        if (scriptInfo.isRelative()) {
            scriptInfo.setFile(QString::fromStdString(appDir), scriptPath);
        }
        scriptPath = scriptInfo.absoluteFilePath();

        if (!scriptInfo.exists()) {
            std::cerr << "ERROR: test script not found: " << scriptPath.toStdString() << "\n";
            return 1;
        }

        JVE_LOG_EVENT(Ui, "Running test script: %s", qPrintable(scriptPath));
        bool ok = luaEngine.executeFile(scriptPath);
        if (!ok) {
            std::cerr << "TEST FAILED: " << luaEngine.getLastError().toStdString() << "\n";
            return 1;
        }
        return 0;
    }

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
        JVE_LOG_ERROR(Ui, "Failed to create application data directory: %s", qPrintable(appDataDir));
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
        JVE_LOG_EVENT(Ui, "Opening project from CLI argument: %s", qPrintable(projectPath));
    } else {
        // No CLI argument — Lua handles startup (last_project_path → welcome screen)
        qunsetenv("JVE_PROJECT_PATH");
        qunsetenv("JVE_TEST_MODE");
        JVE_LOG_EVENT(Ui, "No project specified; Lua will handle startup");
    }

    // Create Lua engine for pure Lua UI
    SimpleLuaEngine luaEngine;

    // Execute Lua main window creation using ResourcePaths
    QString mainWindowScript = QString::fromStdString(JVE::ResourcePaths::getScriptPath("ui/layout.lua"));

    JVE_LOG_EVENT(Ui, "Starting Lua UI system...");

    if (!QFileInfo(mainWindowScript).exists()) {
        JVE_LOG_ERROR(Ui, "Main window script not found: %s", qPrintable(mainWindowScript));
        return -1;
    }

    // Execute Lua main window creation with real LuaJIT integration
    bool luaSuccess = luaEngine.executeFile(mainWindowScript);

    if (!luaSuccess) {
        JVE_LOG_ERROR(Ui, "Failed to execute Lua main window script: %s",
                      qPrintable(luaEngine.getLastError()));
        return -1;
    }

    // Get the main window created by Lua to keep it alive
    QWidget* mainWindow = luaEngine.getCreatedMainWindow();
    if (!mainWindow) {
        JVE_LOG_ERROR(Ui, "No main window was created by Lua script");
        return -1;
    }

    JVE_LOG_EVENT(Ui, "JVE Editor started successfully");

    int result = app.exec();

    JVE_LOG_EVENT(Ui, "JVE Editor shutdown complete");

    return result;
}
