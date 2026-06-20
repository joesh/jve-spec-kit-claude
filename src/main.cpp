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

#ifdef __APPLE__
#include <objc/objc-runtime.h>
#endif

#include <cerrno>
#include <sys/resource.h>
#ifdef __APPLE__
#include <sys/syslimits.h>
#endif

#include "simple_lua_engine.h"
#include "resource_paths.h"
#include "assert_handler.h"
#include "jve_log.h"
#include "debug_terminal.h"
#include "lua/qt_bindings/codec_probe_worker.h"

static void printHelp(const char* programName)
{
    std::cout << "JVE Editor - Professional Video Editor\n";
    std::cout << "Usage: " << programName << " [options] [project.jvp]\n";
    std::cout << "\n";
    std::cout << "Options:\n";
    std::cout << "  --help, -h          Show this help message and exit\n";
    std::cout << "  --version, -v       Show version information and exit\n";
    std::cout << "  --test <script>     Run a Lua test script with full C++ bindings, then exit\n";
    std::cout << "  --control-socket <path>\n";
    std::cout << "                      Open a Lua REPL on the given Unix socket path\n";
    std::cout << "                      for debugging + integration tests. DO NOT enable\n";
    std::cout << "                      in production — gives full Lua-state access.\n";
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

// Raise NOFILE soft limit toward the hard cap. macOS default soft
// limit is 256, which large projects overrun via QFileSystemWatcher
// kqueue FDs + FFmpeg handles + transient probes. The Lua media_status
// layer already watches dirs (not files) to keep its usage bounded;
// this widens the headroom for everything else.
static void raiseFileDescriptorLimit()
{
    struct rlimit rl;
    if (getrlimit(RLIMIT_NOFILE, &rl) != 0) {
        JVE_LOG_WARN(Ui, "getrlimit(NOFILE) failed: %s", std::strerror(errno));
        return;
    }

    rlim_t want = rl.rlim_max;
#ifdef __APPLE__
    // macOS caps effective RLIMIT_NOFILE at OPEN_MAX even when
    // rlim_max is RLIM_INFINITY. Clamp explicitly.
    if (want == RLIM_INFINITY || want > static_cast<rlim_t>(OPEN_MAX)) {
        want = static_cast<rlim_t>(OPEN_MAX);
    }
#endif
    if (rl.rlim_cur >= want) return;

    rl.rlim_cur = want;
    if (setrlimit(RLIMIT_NOFILE, &rl) != 0) {
        JVE_LOG_WARN(Ui, "setrlimit(NOFILE, %llu) failed: %s",
                     static_cast<unsigned long long>(want),
                     std::strerror(errno));
    }
}

// Prepend the source tests/ tree to the Lua package.path so a --test script can
// require("synthetic.integration.integration_test_env"), require("import_schema"), etc.
// The tests root is derived from the script's own location by walking up to the
// ancestor directory named "tests" — robust to bundle (.app) vs bare-binary
// layout (under the bundle the app dir is Contents/Resources, where tests/ is
// never bundled, so appDir + "/tests" would point at a nonexistent dir).
// No-op for scripts outside any tests/ tree (e.g. an ad-hoc debug script) — they
// simply can't require test-tree modules.
static void addTestsTreeToPackagePath(lua_State* L, const QFileInfo& scriptInfo)
{
    QDir testsDir = scriptInfo.absoluteDir();
    while (testsDir.dirName() != "tests" && testsDir.cdUp()) {}
    if (testsDir.dirName() != "tests") return;

    const std::string root = testsDir.absolutePath().toStdString();

    lua_getglobal(L, "package");
    lua_getfield(L, -1, "path");
    const std::string currentPath = lua_isstring(L, -1) ? lua_tostring(L, -1) : "";
    lua_pop(L, 1);

    const std::string newPath = root + "/?.lua;" + root + "/?/init.lua;" + currentPath;
    lua_pushstring(L, newPath.c_str());
    lua_setfield(L, -2, "path");
    lua_pop(L, 1); // pop package table
}

int main(int argc, char *argv[])
{
    // Install abort handler early to catch all assert()/abort() with stack traces
    jve_install_abort_handler();

    // Initialize unified logging (parses JVE_LOG env var)
    jve_init_log();

    raiseFileDescriptorLimit();

    // Single argv scan: parse flags AND the project path here so the
    // truth lives in one place. The project-path branch later in main()
    // just reads what this loop assigned. Adding a new flag means
    // touching only this loop.
    const char* testScript = nullptr;
    const char* controlSocketPath = nullptr;
    const char* projectArg = nullptr;
    auto consumeValue = [&](int& i, const char* name) -> const char* {
        if (i + 1 >= argc) {
            std::cerr << "ERROR: " << name << " requires a value argument\n";
            std::exit(1);
        }
        return argv[++i];
    };
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
            testScript = consumeValue(i, "--test");
            continue;
        }
        if (std::strcmp(argv[i], "--control-socket") == 0) {
            controlSocketPath = consumeValue(i, "--control-socket");
            continue;
        }
        if (std::strncmp(argv[i], "--control-socket=", 17) == 0) {
            controlSocketPath = argv[i] + 17;
            continue;
        }
        if (std::strncmp(argv[i], "--", 2) == 0) {
            continue;  // unknown flag — Qt or other consumer
        }
        if (!projectArg) projectArg = argv[i];
    }

    // Note: High DPI scaling is enabled by default in Qt 6
    // Qt::AA_EnableHighDpiScaling and Qt::AA_UseHighDpiPixmaps are deprecated

    QApplication app(argc, argv);

    // Force dark mode on macOS — set on NSApp so all windows (including dialogs) inherit.
    // Also promote to a Regular (foreground, activatable) app and activate.
    // The .app bundle + Info.plist gives macOS the metadata to grant
    // foreground privileges, but direct-binary invocation from a terminal
    // session bypasses LaunchServices, so the process stays at the default
    // (Prohibited/Accessory) policy. setActivationPolicy:Regular + explicit
    // activateIgnoringOtherApps is what makes the windowserver route
    // synthetic keystrokes (osascript, smoke runner) to JVE's windows —
    // without it, ghostty / Terminal stays frontmost and L3 keypress
    // smokes route their X press to the wrong app.
#ifdef Q_OS_MAC
    {
        id nsApp = ((id (*)(Class, SEL))objc_msgSend)(objc_getClass("NSApplication"), sel_getUid("sharedApplication"));
        if (nsApp) {
            Class NSAppearanceClass = objc_getClass("NSAppearance");
            id darkName = ((id (*)(Class, SEL, const char*))objc_msgSend)(
                objc_getClass("NSString"), sel_getUid("stringWithUTF8String:"), "NSAppearanceNameDarkAqua");
            if (NSAppearanceClass && darkName) {
                id appearance = ((id (*)(Class, SEL, id))objc_msgSend)(
                    NSAppearanceClass, sel_getUid("appearanceNamed:"), darkName);
                if (appearance) {
                    ((void (*)(id, SEL, id))objc_msgSend)(nsApp, sel_getUid("setAppearance:"), appearance);
                }
            }
            // NSApplicationActivationPolicyRegular = 0
            ((void (*)(id, SEL, long))objc_msgSend)(
                nsApp, sel_getUid("setActivationPolicy:"), 0);
            ((void (*)(id, SEL, BOOL))objc_msgSend)(
                nsApp, sel_getUid("activateIgnoringOtherApps:"), YES);
        }
    }
#endif

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
        jve_set_lua_state(luaEngine.getLuaState());
        jve_set_global_lua_state(luaEngine.getLuaState());

        lua_State* L = luaEngine.getLuaState();
        std::string appDir = JVE::ResourcePaths::getApplicationDirectory();

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

        addTestsTreeToPackagePath(L, scriptInfo);

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
    // Tooltip tracks the active theme — it's a colour in darkPalette, so it
    // follows the dark-mode setting like every other role here. Dark box +
    // white text (both were white before — invisible white-on-white, every
    // tooltip rendered blank). When a light theme lands, give it its own
    // palette with a light ToolTipBase / dark ToolTipText.
    darkPalette.setColor(QPalette::ToolTipBase, QColor(20, 20, 20));
    darkPalette.setColor(QPalette::ToolTipText, Qt::white);
    darkPalette.setColor(QPalette::Text, Qt::white);
    darkPalette.setColor(QPalette::Button, QColor(35, 35, 35));
    darkPalette.setColor(QPalette::ButtonText, Qt::white);
    darkPalette.setColor(QPalette::BrightText, Qt::red);
    darkPalette.setColor(QPalette::Link, QColor(42, 130, 218));
    darkPalette.setColor(QPalette::Highlight, QColor(42, 130, 218));
    darkPalette.setColor(QPalette::HighlightedText, Qt::white);
    // Disabled state must be visually distinct on dark backgrounds
    darkPalette.setColor(QPalette::Disabled, QPalette::ButtonText, QColor(70, 70, 70));
    darkPalette.setColor(QPalette::Disabled, QPalette::WindowText, QColor(70, 70, 70));
    darkPalette.setColor(QPalette::Disabled, QPalette::Text, QColor(70, 70, 70));
    darkPalette.setColor(QPalette::Disabled, QPalette::Button, QColor(28, 28, 28));
    app.setPalette(darkPalette);

    // Stylesheet reinforces disabled button appearance (Fusion palette alone
    // doesn't always render disabled buttons distinctly on dark backgrounds).
    // Target both standalone buttons and buttons inside QDialogButtonBox.
    app.setStyleSheet(
        "QPushButton:disabled { color: #666666; background-color: #1e1e1e; }"
        // Tooltip: no border, larger font. Colours come from the dark palette
        // (ToolTipBase/Text); a stylesheet is the only way to drop QToolTip's
        // default 1px border and bump the font.
        "QToolTip { border: none; color: #ffffff; background-color: #141414;"
        " font-size: 13px; padding: 1px 4px; }"
    );

    // Set up application data directory
    QString appDataDir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    if (!QDir().mkpath(appDataDir)) {
        JVE_LOG_ERROR(Ui, "Failed to create application data directory: %s", qPrintable(appDataDir));
        return -1;
    }

    // projectArg was set in the single argv scan at the top of main().
    QString projectPath;
    if (projectArg) {
        projectPath = QString::fromLocal8Bit(projectArg);
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
    jve_set_lua_state(luaEngine.getLuaState());
    jve_set_global_lua_state(luaEngine.getLuaState());

    // Execute Lua main window creation using ResourcePaths
    QString mainWindowScript = QString::fromStdString(JVE::ResourcePaths::getScriptPath("ui/layout.lua"));

    JVE_LOG_EVENT(Ui, "Starting Lua UI system...");

    if (!QFileInfo(mainWindowScript).exists()) {
        JVE_LOG_ERROR(Ui, "Main window script not found: %s", qPrintable(mainWindowScript));
        return -1;
    }

    // Optional Lua REPL debug terminal — start BEFORE running the main
    // Lua script so it's available even on the welcome screen / when no
    // project is open. CLI flag-gated; never on by default. Same Lua
    // state as the main window. Single client at a time.
    DebugTerminal* debug_terminal = nullptr;
    if (controlSocketPath) {
        debug_terminal = new DebugTerminal(
            QString::fromLocal8Bit(controlSocketPath),
            luaEngine.getLuaState(),
            &app);
        if (!debug_terminal->start()) {
            JVE_LOG_ERROR(Ui, "Debug terminal failed to start; continuing without it");
            delete debug_terminal;
            debug_terminal = nullptr;
        }
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

    // Shutdown hook: run Lua cleanup before Qt objects are destroyed.
    // aboutToQuit fires before widget destruction — safe to call Lua,
    // cancel background threads, flush DB, etc.
    QObject::connect(&app, &QCoreApplication::aboutToQuit, [&luaEngine]() {
        JVE_LOG_EVENT(Ui, "aboutToQuit: running Lua shutdown");

        // Cancel background probe worker before Lua/Qt teardown.
        jve_cancel_codec_probe_worker();

        lua_State* L = luaEngine.getLuaState();
        lua_getglobal(L, "__jve_shutdown");
        if (lua_isfunction(L, -1)) {
            if (lua_pcall(L, 0, 0, 0) != LUA_OK) {
                JVE_LOG_ERROR(Ui, "Lua shutdown error: %s", lua_tostring(L, -1));
                lua_pop(L, 1);
            }
        } else {
            lua_pop(L, 1);
        }
    });

    int result = app.exec();

    JVE_LOG_EVENT(Ui, "JVE Editor shutdown complete");

    return result;
}
