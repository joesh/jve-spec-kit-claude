#include "binding_macros.h"
#include "../../jve_log.h"
#include "../../timeline_renderer.h" // For lua_create_timeline_renderer
#include <chrono>
#include <sys/stat.h>      // ::stat for nanosecond mtime (POSIX)
#include <QApplication> // For QApplication::focusWidget()
#include <QDir>
#include <QFileInfo>
#include <QDateTime>
#include <QRubberBand>
#include <QCursor>
#include <QScrollArea>
#include <QScrollBar>
#include <QSplitter>
#include <QSplitterHandle>
#include <QStyle>
#include <QMetaObject>
#include <QPainter>
#include <QPixmap>
#include <QPolygon>
#include <QColor>
#include <QPen>
#include <QPainterPath>
#include <QPainterPathStroker>
#include <QThread>

#ifdef Q_OS_MAC
#include <objc/objc-runtime.h>
static id qt_nsstring_from_utf8(const char* utf8)
{
    if (!utf8) {
        return nil;
    }
    Class NSStringClass = objc_getClass("NSString");
    SEL stringWithUTF8StringSel = sel_getUid("stringWithUTF8String:");
    return ((id (*)(Class, SEL, const char*))objc_msgSend)(NSStringClass, stringWithUTF8StringSel, utf8);
}
#endif


// Performance-optimized string-to-enum map for cursor types
static const QHash<QString, Qt::CursorShape>& getCursorShapeMap() {
    static const QHash<QString, Qt::CursorShape> map = {
        {"arrow", Qt::ArrowCursor},
        {"hand", Qt::PointingHandCursor},
        {"size_horz", Qt::SizeHorCursor},
        {"size_vert", Qt::SizeVerCursor},
        {"split_h", Qt::SplitHCursor},
        {"split_v", Qt::SplitVCursor},
        {"cross", Qt::CrossCursor},
        {"ibeam", Qt::IBeamCursor},
        {"size_all", Qt::SizeAllCursor}
    };
    return map;
}

// Monotonic wall-clock seconds as a double. Use in place of os.clock() when
// measuring work that dispatches across threads — os.clock() returns process
// total CPU time (accumulating across all threads), which overcounts
// wall-clock by the parallelism factor for parallel native code.
static int lua_qt_monotonic_s(lua_State* L) {
    auto now = std::chrono::steady_clock::now().time_since_epoch();
    double seconds = std::chrono::duration<double>(now).count();
    lua_pushnumber(L, seconds);
    return 1;
}

// Process ID of the running JVE. Used by core.resolve_bridge.client to
// stamp helper-protocol correlation ids (`jve-<pid>-<unix_s>-<seq>`) and
// by core.project_open's pidlock (replaces the previous `io.popen("ps
// -o ppid= -p $$")` shellout, which cost ~5ms per pidlock op and broke
// when launched from Finder with a stripped PATH).
static int lua_qt_get_pid(lua_State* L) {
    lua_pushinteger(L, static_cast<lua_Integer>(QCoreApplication::applicationPid()));
    return 1;
}

// Sleep the calling thread for `ms` milliseconds. Replaces
// `os.execute(string.format("sleep %f", ms/1000))` in tight poll loops
// (helper_supervisor wait_for_bind), which forked /bin/sh per tick and
// broke under Finder-launched .app's stripped PATH.
static int lua_qt_thread_msleep(lua_State* L) {
    int ms = luaL_checkinteger(L, 1);
    luaL_argcheck(L, ms >= 0, 1,
        "qt_thread_msleep: ms must be non-negative");
    QThread::msleep(static_cast<unsigned long>(ms));
    return 0;
}

// Filesystem-existence check via QFileInfo. Covers regular files,
// directories, symlinks AND Unix-domain sockets — the use case driving
// this is the supervisor polling for the helper's QLocalServer socket
// inode to appear (replaces `os.execute("test -S " .. path)`).
static int lua_qt_fs_path_exists(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    luaL_argcheck(L, path[0] != '\0', 1,
        "qt_fs_path_exists: path must not be empty");
    QFileInfo fi{QString::fromUtf8(path)};
    lua_pushboolean(L, fi.exists() ? 1 : 0);
    return 1;
}

// Single-path mtime as seconds-since-epoch with sub-second resolution.
// Returns nil when the file doesn't exist (callers race the FS between
// existence checks and mtime reads — the same nil-on-missing contract
// fs_utils.file_mtime advertised when it shelled out to `stat`).
//
// Uses POSIX stat(2) directly so we get nanosecond precision (st_mtim /
// st_mtimespec). The previous implementation forked a shell, ran the
// `stat` binary, redirected to a temp file, and read it back — measured
// at ~7 ms per call, which dominated peak_cache.init_for_project for
// projects with hundreds of audio files (TSO 2026-04-29 21:42:14:
// 3.79s in stat() out of a 3.93s init_for_project for 551 files).
static int lua_qt_file_mtime(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    struct stat st;
    if (::stat(path, &st) != 0) {
        lua_pushnil(L);
        return 1;
    }
#if defined(__APPLE__)
    // macOS exposes the timespec under the BSD-historical name.
    double sec = static_cast<double>(st.st_mtimespec.tv_sec)
               + static_cast<double>(st.st_mtimespec.tv_nsec) / 1e9;
#elif defined(__linux__)
    double sec = static_cast<double>(st.st_mtim.tv_sec)
               + static_cast<double>(st.st_mtim.tv_nsec) / 1e9;
#else
    // Whole-second fallback. Production targets are macOS + Linux; this
    // branch keeps the binding compilable elsewhere without lying about
    // precision (the value is still a valid float, just floored).
    double sec = static_cast<double>(st.st_mtime);
#endif
    lua_pushnumber(L, sec);
    return 1;
}

// Bulk stat: qt_file_stat_batch({path1, path2, ...}) -> {[path] = {mtime, size}}
// Missing files are omitted from the result (so `result[path] == nil` means
// "doesn't exist"). Uses QFileInfo (Qt's native stat wrapper) — one in-process
// stat per path, no subprocess fork, no shell quoting. Intended consumer:
// the media probe disk cache, which needs (path, mtime, size) per candidate
// to decide whether a cached probe result is still fresh.
static int lua_qt_file_stat_batch(lua_State* L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    int n = static_cast<int>(lua_objlen(L, 1));
    lua_createtable(L, 0, n);  // result table
    for (int i = 1; i <= n; ++i) {
        lua_rawgeti(L, 1, i);
        if (!lua_isstring(L, -1)) { lua_pop(L, 1); continue; }
        const char* path = lua_tostring(L, -1);
        QFileInfo fi{QString::fromUtf8(path)};
        if (fi.exists() && !fi.isDir()) {
            lua_newtable(L);  // info table
            lua_pushinteger(L,
                static_cast<lua_Integer>(fi.lastModified().toSecsSinceEpoch()));
            lua_setfield(L, -2, "mtime");
            lua_pushinteger(L, static_cast<lua_Integer>(fi.size()));
            lua_setfield(L, -2, "size");
            // Stack: [arg_table, result, path, info]
            // result[path] = info — lua_settable(L,-3) uses key at -2, value at -1.
            lua_settable(L, -3);
        } else {
            lua_pop(L, 1);  // pop path; no entry for missing files
        }
    }
    return 1;
}

// Recursive mkdir using Qt's native QDir::mkpath. Replaces os.execute("mkdir -p")
// shellouts, which fail silently under Finder-launched .app bundles (stripped
// PATH) and discard exit status. Returns true on success or if the directory
// already exists; returns (nil, errmsg) on failure. Callers MUST assert on nil.
// Empty string is rejected explicitly: QDir::mkpath("") silently returns true
// (resolves to CWD), which would mask caller bugs.
static int lua_qt_fs_mkdir_p(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    if (path[0] == '\0') {
        lua_pushnil(L);
        lua_pushliteral(L, "qt_fs_mkdir_p: path must not be empty");
        return 2;
    }
    QString qpath = QString::fromUtf8(path);
    QDir dir;
    if (dir.mkpath(qpath)) {
        lua_pushboolean(L, 1);
        return 1;
    }
    // Discriminate the most actionable failure: target exists as a non-directory.
    // Other modes collapse — Qt doesn't surface errno through mkpath.
    QFileInfo fi(qpath);
    const char* reason = (fi.exists() && !fi.isDir())
        ? "path exists but is not a directory"
        : "permission denied, invalid path, or non-directory component in parent chain";
    lua_pushnil(L);
    lua_pushfstring(L, "QDir::mkpath failed for %s: %s", path, reason);
    return 2;
}

namespace {
constexpr int kBracketHeight = 20;
constexpr int kBracketBarWidth = 2;
constexpr int kBracketArmLength = 3;
constexpr int kBracketOutlineWidth = 1;
constexpr int kBracketMargin = kBracketOutlineWidth;
constexpr int kBracketShapeWidth = kBracketBarWidth + kBracketArmLength;
constexpr int kBracketShapeHeight = kBracketHeight;

QPainterPath buildBracketPath(bool facesLeft)
{
    QPainterPath path;
    path.setFillRule(Qt::WindingFill);
    const qreal verticalX = facesLeft ? kBracketArmLength : 0;
    path.addRect(verticalX, 0, kBracketBarWidth, kBracketHeight);
    if (facesLeft) {
        path.addRect(0, 0, kBracketArmLength, kBracketBarWidth);
        path.addRect(0, kBracketHeight - kBracketBarWidth, kBracketArmLength, kBracketBarWidth);
    } else {
        path.addRect(kBracketBarWidth, 0, kBracketArmLength, kBracketBarWidth);
        path.addRect(kBracketBarWidth, kBracketHeight - kBracketBarWidth, kBracketArmLength, kBracketBarWidth);
    }
    return path.simplified();
}

void paintBracketShape(QPainter& painter, const QPainterPath& path)
{
    QPainterPathStroker stroker;
    stroker.setWidth(kBracketOutlineWidth * 2);
    stroker.setJoinStyle(Qt::MiterJoin);
    stroker.setCapStyle(Qt::SquareCap);
    stroker.setMiterLimit(2.0);
    QPainterPath outline = stroker.createStroke(path);

    painter.setPen(Qt::NoPen);
    painter.setBrush(Qt::black);
    painter.drawPath(outline);

    painter.setBrush(Qt::white);
    painter.drawPath(path);
}
} // namespace

static QCursor make_trim_cursor(bool is_left_handle)
{
    const bool faces_left = is_left_handle; // Left zone should render a ] bracket.
    const int width = kBracketShapeWidth + (kBracketMargin * 2);
    const int height = kBracketShapeHeight + (kBracketMargin * 2);

    QPixmap pix(width, height);
    pix.fill(Qt::transparent);
    QPainter painter(&pix);
    painter.setRenderHint(QPainter::Antialiasing, false);

    QPainterPath path = buildBracketPath(faces_left);
    path.translate(kBracketMargin, kBracketMargin);
    paintBracketShape(painter, path);

    painter.end();
    const qreal verticalX = faces_left ? kBracketArmLength : 0;
    const int seam_x = faces_left
        ? kBracketMargin + verticalX + kBracketBarWidth
        : kBracketMargin + verticalX;
    const int seam_y = kBracketMargin + (kBracketShapeHeight / 2);
    return QCursor(pix, seam_x, seam_y);
}

static QCursor make_roll_cursor()
{
    constexpr int gap_between = kBracketArmLength;
    const int width = (kBracketShapeWidth * 2) + gap_between + (kBracketMargin * 2);
    const int height = kBracketShapeHeight + (kBracketMargin * 2);

    QPixmap pix(width, height);
    pix.fill(Qt::transparent);
    QPainter painter(&pix);
    painter.setRenderHint(QPainter::Antialiasing, false);

    QPainterPath left_path = buildBracketPath(true);
    left_path.translate(kBracketMargin, kBracketMargin);
    paintBracketShape(painter, left_path);

    QPainterPath right_path = buildBracketPath(false);
    right_path.translate(kBracketMargin + kBracketShapeWidth + gap_between, kBracketMargin);
    paintBracketShape(painter, right_path);

    painter.end();
    const int center_x = width / 2;
    const int center_y = kBracketMargin + (kBracketShapeHeight / 2);
    return QCursor(pix, center_x, center_y);
}

static const QCursor& getCustomCursor(const QString& name)
{
    static const QCursor trim_left_cursor = make_trim_cursor(true);
    static const QCursor trim_right_cursor = make_trim_cursor(false);
    static const QCursor roll_cursor = make_roll_cursor();
    if (name == "trim_left") {
        return trim_left_cursor;
    }
    if (name == "trim_right") {
        return trim_right_cursor;
    }
    if (name == "split_h") {
        return roll_cursor;
    }
    static const QCursor default_cursor(Qt::ArrowCursor);
    return default_cursor;
}

static const QHash<QString, Qt::FocusPolicy>& getFocusPolicyMap() {
    static const QHash<QString, Qt::FocusPolicy> map = {
        {"StrongFocus", Qt::StrongFocus},
        {"ClickFocus", Qt::ClickFocus},
        {"TabFocus", Qt::TabFocus},
        {"WheelFocus", Qt::WheelFocus},
        {"NoFocus", Qt::NoFocus}
    };
    return map;
}

static const QHash<QString, Qt::ScrollBarPolicy>& getScrollBarPolicyMap() {
    static const QHash<QString, Qt::ScrollBarPolicy> map = {
        {"AlwaysOff", Qt::ScrollBarAlwaysOff},
        {"AlwaysOn", Qt::ScrollBarAlwaysOn},
        {"AsNeeded", Qt::ScrollBarAsNeeded}
    };
    return map;
}

static const QHash<QString, Qt::Alignment>& getAlignmentMap() {
    static const QHash<QString, Qt::Alignment> map = {
        {"AlignBottom", Qt::AlignBottom},
        {"AlignTop", Qt::AlignTop},
        {"AlignLeft", Qt::AlignLeft},
        {"AlignRight", Qt::AlignRight},
        {"AlignCenter", Qt::AlignCenter},
        {"AlignVCenter", Qt::AlignVCenter}
        // Combined flags like AlignLeft | AlignTop would need more complex handling
    };
    return map;
}

// Widget creation
int lua_create_timeline_renderer(lua_State* L) {
    JVE::TimelineRenderer* timeline = new JVE::TimelineRenderer("timeline_widget");
    timeline->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);
    timeline->setMinimumHeight(30);
    lua_push_widget(L, timeline);
    return 1;
}

int lua_create_inspector_panel(lua_State* L) {
    StyledWidget* inspector_container = new StyledWidget();
    inspector_container->setObjectName("LuaInspectorContainer");
    inspector_container->setStyleSheet(
        "QWidget#LuaInspectorContainer { "
        "    background: #2b2b2b; "
        "    border: 1px solid #444; "
        "}"
    );
    lua_push_widget(L, inspector_container);
    return 1;
}

// QRubberBand functions
int lua_create_rubber_band(lua_State* L) {
    QWidget* parent = get_widget<QWidget>(L, 1);
    if (!parent) return luaL_error(L, "qt_create_rubber_band: parent widget required");
    QRubberBand* band = new QRubberBand(QRubberBand::Rectangle, parent);
    band->hide();
    lua_push_widget(L, band);
    return 1;
}

int lua_set_rubber_band_geometry(lua_State* L) {
    QWidget* widget = get_widget<QWidget>(L, 1);
    if (!widget) return luaL_error(L, "qt_set_rubber_band_geometry: widget required");
    int x = luaL_checkint(L, 2);
    int y = luaL_checkint(L, 3);
    int width = luaL_checkint(L, 4);
    int height = luaL_checkint(L, 5);
    widget->setGeometry(x, y, width, height);
    return 0;
}

int lua_grab_mouse(lua_State* L) {
    QWidget* widget = get_widget<QWidget>(L, 1);
    if (!widget) return luaL_error(L, "qt_grab_mouse: widget required");
    widget->grabMouse();
    return 0;
}

int lua_release_mouse(lua_State* L) {
    QWidget* widget = get_widget<QWidget>(L, 1);
    if (!widget) return luaL_error(L, "qt_release_mouse: widget required");
    widget->releaseMouse();
    return 0;
}

// Coordinate mapping functions
int lua_map_point_from(lua_State* L) {
    QWidget* target_widget = get_widget<QWidget>(L, 1);
    QWidget* source_widget = get_widget<QWidget>(L, 2);
    int x = luaL_checkint(L, 3);
    int y = luaL_checkint(L, 4);
    if (!target_widget || !source_widget) return luaL_error(L, "qt_map_point_from: both widgets required");
    QPoint mapped = target_widget->mapFrom(source_widget, QPoint(x, y));
    lua_pushinteger(L, mapped.x());
    lua_pushinteger(L, mapped.y());
    return 2;
}

int lua_map_rect_from(lua_State* L) {
    QWidget* target_widget = get_widget<QWidget>(L, 1);
    QWidget* source_widget = get_widget<QWidget>(L, 2);
    int x = luaL_checkint(L, 3);
    int y = luaL_checkint(L, 4);
    int width = luaL_checkint(L, 5);
    int height = luaL_checkint(L, 6);
    if (!target_widget || !source_widget) return luaL_error(L, "qt_map_rect_from: both widgets required");
    QPoint mapped_tl = target_widget->mapFrom(source_widget, QPoint(x, y));
    QPoint mapped_br = target_widget->mapFrom(source_widget, QPoint(x + width, y + height));
    lua_pushinteger(L, mapped_tl.x());
    lua_pushinteger(L, mapped_tl.y());
    lua_pushinteger(L, mapped_br.x() - mapped_tl.x());
    lua_pushinteger(L, mapped_br.y() - mapped_tl.y());
    return 4;
}

int lua_map_to_global(lua_State* L) {
    QWidget* widget = get_widget<QWidget>(L, 1);
    int x = luaL_checkint(L, 2);
    int y = luaL_checkint(L, 3);
    if (!widget) return luaL_error(L, "qt_map_to_global: widget required");
    QPoint global = widget->mapToGlobal(QPoint(x, y));
    lua_pushinteger(L, global.x());
    lua_pushinteger(L, global.y());
    return 2;
}

int lua_map_from_global(lua_State* L) {
    QWidget* widget = get_widget<QWidget>(L, 1);
    int x = luaL_checkint(L, 2);
    int y = luaL_checkint(L, 3);
    if (!widget) return luaL_error(L, "qt_map_from_global: widget required");
    QPoint local = widget->mapFromGlobal(QPoint(x, y));
    lua_pushinteger(L, local.x());
    lua_pushinteger(L, local.y());
    return 2;
}

// Widget styling.
//
// Uses get_widget<QWidget> (qobject_cast under the hood) NOT
// get_widget<QWidget>(...). The dead-widget guard in
// lua_to_widget catches DESTROYED QObjects (QPointer null) but not
// LIVE non-QWidget QObjects (e.g. a QTimer userdata): static_cast on a
// QTimer* succeeds blindly, then setStyleSheet dereferences a non-
// QWidget vtable → SIGSEGV. qobject_cast returns nullptr for the
// non-QWidget case so the `widget required` guard fires cleanly.
int lua_set_widget_stylesheet(lua_State* L) {
    QWidget* widget = get_widget<QWidget>(L, 1);
    const char* stylesheet = luaL_checkstring(L, 2);
    if (!widget) return luaL_error(L, "qt_set_widget_stylesheet: widget required");
    widget->setStyleSheet(QString::fromUtf8(stylesheet));
    return 0;
}

// Set widget cursor (uses optimized lookup)
int lua_set_widget_cursor(lua_State* L) {
    QWidget* widget = get_widget<QWidget>(L, 1);
    const char* cursor_type = luaL_checkstring(L, 2);
    if (!widget) return luaL_error(L, "qt_set_widget_cursor: widget required");

    QString cursor_name = QString::fromUtf8(cursor_type);
    if (cursor_name == "trim_left" || cursor_name == "trim_right" || cursor_name == "split_h") {
        widget->setCursor(getCustomCursor(cursor_name));
        return 0;
    }
    Qt::CursorShape shape = getCursorShapeMap().value(cursor_name, Qt::ArrowCursor);
    widget->setCursor(QCursor(shape));
    return 0;
}

int lua_set_window_appearance(lua_State* L)
{
    QWidget* widget = get_widget<QWidget>(L, 1);
    const char* appearance_name = luaL_optstring(L, 2, "NSAppearanceNameDarkAqua");

    if (!widget) {
        JVE_LOG_WARN(Ui, "Invalid widget in set_window_appearance");
        lua_pushboolean(L, 0);
        return 1;
    }

#ifdef Q_OS_MAC
    bool hadWindowHandle = widget->windowHandle() != nullptr;
    if (!hadWindowHandle) {
        widget->createWinId();
    }
    id nsWindow = nil;
    id cocoaView = (id)widget->winId();
    if (cocoaView) {
        nsWindow = ((id (*)(id, SEL))objc_msgSend)(cocoaView, sel_getUid("window"));
    }
    if (!nsWindow) {
        JVE_LOG_WARN(Ui, "set_window_appearance: no NSWindow for widget %s (class=%s, hadHandle=%d, winId=%p)",
            widget->objectName().toUtf8().constData(),
            widget->metaObject()->className(),
            hadWindowHandle ? 1 : 0,
            (void*)cocoaView);
        lua_pushboolean(L, 0);
        return 1;
    }
    {
        id appearanceString = qt_nsstring_from_utf8(appearance_name);
        if (!appearanceString) {
            appearanceString = qt_nsstring_from_utf8("NSAppearanceNameDarkAqua");
        }
        Class NSAppearanceClass = objc_getClass("NSAppearance");
        SEL appearanceNamedSel = sel_getUid("appearanceNamed:");
        id nsAppearance = nil;
        if (NSAppearanceClass && appearanceString) {
            nsAppearance = ((id (*)(Class, SEL, id))objc_msgSend)(NSAppearanceClass, appearanceNamedSel, appearanceString);
        }
        if (nsAppearance) {
            SEL setAppearanceSel = sel_getUid("setAppearance:");
            ((void (*)(id, SEL, id))objc_msgSend)(nsWindow, setAppearanceSel, nsAppearance);
            lua_pushboolean(L, 1);
            return 1;
        }
    }
#else
    Q_UNUSED(appearance_name);
#endif

    lua_pushboolean(L, 0);
    return 1;
}

int lua_set_focus_policy(lua_State* L) {
    QWidget* widget = get_widget<QWidget>(L, 1);
    const char* policy_str = luaL_checkstring(L, 2);
    if (!widget) return luaL_error(L, "qt_set_focus_policy: widget required");

    Qt::FocusPolicy policy = getFocusPolicyMap().value(QString::fromUtf8(policy_str), Qt::NoFocus);
    widget->setFocusPolicy(policy);
    return 0;
}

int lua_set_focus(lua_State* L) {
    QWidget* widget = get_widget<QWidget>(L, 1);
    if (!widget) return luaL_error(L, "qt_set_focus: widget required");
    // Activate the widget's window first — on macOS, setFocus() is a no-op
    // unless the widget's window is the active (key) window.
    QWidget* window = widget->window();
    if (window) {
        window->activateWindow();
    }
    widget->setFocus(Qt::OtherFocusReason);
    return 0;
}

// Returns the widget that currently has Qt keyboard focus, or nil.
int lua_get_focus_widget(lua_State* L) {
    QWidget* fw = QApplication::focusWidget();
    if (fw) {
        lua_push_widget(L, fw);
    } else {
        lua_pushnil(L);
    }
    return 1;
}

int lua_update_widget(lua_State* L) {
    QWidget* widget = get_widget<QWidget>(L, 1);
    if (!widget) return 0; // No error, just skip if invalid
    widget->updateGeometry();
    widget->update();
    return 0;
}

int lua_set_widget_property(lua_State* L) {
    QWidget* widget = get_widget<QWidget>(L, 1);
    if (!widget) return luaL_error(L, "qt_set_widget_property: widget required");
    const char* name = luaL_checkstring(L, 2);
    const char* value = luaL_checkstring(L, 3);
    widget->setProperty(name, QString::fromUtf8(value));
    widget->update();
    return 0;
}

int lua_set_tooltip(lua_State* L) {
    void* ptr = lua_to_widget(L, 1);
    const char* text = luaL_checkstring(L, 2);
    if (!ptr) return luaL_error(L, "qt_set_tooltip: widget or action required");

    QObject* obj = static_cast<QObject*>(ptr);
    QString qtext = QString::fromUtf8(text);

    if (QWidget* w = qobject_cast<QWidget*>(obj)) {
        w->setToolTip(qtext);
    } else if (QAction* a = qobject_cast<QAction*>(obj)) {
        a->setToolTip(qtext);
    } else {
        return luaL_error(L, "qt_set_tooltip: object is neither a QWidget nor a QAction");
    }
    return 0;
}

int lua_get_widget_property(lua_State* L) {
    QWidget* widget = get_widget<QWidget>(L, 1);
    if (!widget) return luaL_error(L, "qt_get_widget_property: widget required");
    const char* name = luaL_checkstring(L, 2);
    QVariant v = widget->property(name);
    if (!v.isValid()) { lua_pushnil(L); return 1; }
    lua_pushstring(L, v.toString().toUtf8().constData());
    return 1;
}

// Count direct child QWidgets. Used by focus_manager regression tests to
// prove no overlay widgets are added on focus change (overlays caused
// macOS Metal occlusion before the focusBorderColor refactor).
int lua_widget_child_widget_count(lua_State* L) {
    QWidget* widget = get_widget<QWidget>(L, 1);
    if (!widget) return luaL_error(L, "qt_widget_child_widget_count: widget required");
    int n = 0;
    for (QObject* child : widget->children()) {
        if (qobject_cast<QWidget*>(child)) ++n;
    }
    lua_pushinteger(L, n);
    return 1;
}

int lua_set_widget_contents_margins(lua_State* L) {
    QWidget* widget = get_widget<QWidget>(L, 1);
    if (!widget) return luaL_error(L, "qt_set_widget_contents_margins: widget required");
    int left = luaL_checkinteger(L, 2);
    int top = luaL_checkinteger(L, 3);
    int right = luaL_checkinteger(L, 4);
    int bottom = luaL_checkinteger(L, 5);
    widget->setContentsMargins(left, top, right, bottom);
    return 0;
}

// Scroll position functions
int lua_get_scroll_position(lua_State* L) {
    QScrollArea* sa = get_widget<QScrollArea>(L, 1);
    if (!sa) return 0;
    lua_pushinteger(L, sa->verticalScrollBar()->value());
    return 1;
}

int lua_set_scroll_position(lua_State* L) {
    QScrollArea* sa = get_widget<QScrollArea>(L, 1);
    int position = luaL_checkinteger(L, 2);
    if (!sa) return 0;
    sa->verticalScrollBar()->setValue(position);
    return 0;
}

// Scroll the area so the given widget (which must be a descendant) is visible.
// Wraps QScrollArea::ensureWidgetVisible(widget). Used by the Inspector to
// keep a focused field visible when Tab cycles past the viewport edge.
int lua_scroll_area_ensure_widget_visible(lua_State* L) {
    QScrollArea* sa = get_widget<QScrollArea>(L, 1);
    if (!sa) return luaL_error(L, "qt_scroll_area_ensure_widget_visible: scroll area required");
    QWidget* w = get_widget<QWidget>(L, 2);
    if (!w) return luaL_error(L, "qt_scroll_area_ensure_widget_visible: widget required");
    sa->ensureWidgetVisible(w);
    return 0;
}

int lua_hide_splitter_handle(lua_State* L) {
    QSplitter* splitter = get_widget<QSplitter>(L, 1);
    int index = luaL_checkinteger(L, 2);
    if (!splitter) return luaL_error(L, "qt_hide_splitter_handle: splitter required");
    QSplitterHandle* handle = splitter->handle(index);
    if (handle) {
        handle->setEnabled(false);
        handle->setVisible(false);
    }
    return 0;
}

int lua_set_splitter_stretch_factor(lua_State* L) {
    QSplitter* splitter = get_widget<QSplitter>(L, 1);
    int index = luaL_checkinteger(L, 2);
    int stretch = luaL_checkinteger(L, 3);
    if (!splitter) return luaL_error(L, "qt_set_splitter_stretch_factor: splitter required");
    splitter->setStretchFactor(index, stretch);
    return 0;
}

int lua_get_splitter_handle(lua_State* L) {
    QSplitter* splitter = get_widget<QSplitter>(L, 1);
    int index = luaL_checkinteger(L, 2);
    if (!splitter) { lua_pushnil(L); return 1; }
    QSplitterHandle* handle = splitter->handle(index);
    if (handle) {
        lua_push_widget(L, handle);
    } else {
        lua_pushnil(L);
    }
    return 1;
}

int lua_set_widget_attribute(lua_State* L) {
    QWidget* widget = get_widget<QWidget>(L, 1);
    const char* attr_name = luaL_checkstring(L, 2);
    bool value = lua_toboolean(L, 3);
    if (!widget) return luaL_error(L, "qt_set_widget_attribute: widget required");

    // Consider using a static QHash for attribute names to enum mapping if many attributes are supported
    Qt::WidgetAttribute attr;
    if (strcmp(attr_name, "WA_TransparentForMouseEvents") == 0) attr = Qt::WA_TransparentForMouseEvents;
    else if (strcmp(attr_name, "WA_Hover") == 0) attr = Qt::WA_Hover;
    else if (strcmp(attr_name, "WA_StyledBackground") == 0) attr = Qt::WA_StyledBackground;
    else if (strcmp(attr_name, "WA_TranslucentBackground") == 0) attr = Qt::WA_TranslucentBackground;
    else return luaL_error(L, "Unknown widget attribute: %s", attr_name);
    
    widget->setAttribute(attr, value);
    return 0;
}

int lua_set_object_name(lua_State* L) {
    QObject* obj = get_widget<QObject>(L, 1);
    const char* name = luaL_checkstring(L, 2);
    if (!obj) return luaL_error(L, "qt_set_object_name: object required");
    obj->setObjectName(QString::fromUtf8(name));
    return 0;
}

int lua_set_scroll_area_h_scrollbar_policy(lua_State* L) {
    QScrollArea* sa = get_widget<QScrollArea>(L, 1);
    const char* policy_str = luaL_checkstring(L, 2);
    if (!sa) return luaL_error(L, "qt_set_scroll_area_h_scrollbar_policy: scroll area required");
    
    Qt::ScrollBarPolicy policy = getScrollBarPolicyMap().value(QString::fromUtf8(policy_str), Qt::ScrollBarAsNeeded);
    sa->setHorizontalScrollBarPolicy(policy);
    return 0;
}

int lua_set_scroll_area_v_scrollbar_policy(lua_State* L) {
    QScrollArea* sa = get_widget<QScrollArea>(L, 1);
    const char* policy_str = luaL_checkstring(L, 2);
    if (!sa) return luaL_error(L, "qt_set_scroll_area_v_scrollbar_policy: scroll area required");

    Qt::ScrollBarPolicy policy = getScrollBarPolicyMap().value(QString::fromUtf8(policy_str), Qt::ScrollBarAsNeeded);
    sa->setVerticalScrollBarPolicy(policy);
    return 0;
}

int lua_set_scroll_area_alignment(lua_State* L) {
    QScrollArea* sa = get_widget<QScrollArea>(L, 1);
    const char* alignment_str = luaL_checkstring(L, 2);
    if (!sa) return luaL_error(L, "qt_set_scroll_area_alignment: scroll area required");

    // Special handling for combination alignments in QScrollArea
    Qt::Alignment alignment = Qt::AlignLeft | Qt::AlignTop; // Default if not found
    if (strcmp(alignment_str, "AlignBottom") == 0) {
        alignment = Qt::AlignLeft | Qt::AlignBottom;
    } else if (strcmp(alignment_str, "AlignTop") == 0) {
        alignment = Qt::AlignLeft | Qt::AlignTop;
    } else if (strcmp(alignment_str, "AlignVCenter") == 0) {
        alignment = Qt::AlignLeft | Qt::AlignVCenter;
    } else {
        JVE_LOG_WARN(Ui, "Unsupported scroll area alignment: %s", alignment_str);
    }
    sa->setAlignment(alignment);
    return 0;
}

int lua_set_scroll_area_widget_resizable(lua_State* L) {
    QScrollArea* sa = get_widget<QScrollArea>(L, 1);
    bool resizable = lua_toboolean(L, 2);
    if (!sa) return luaL_error(L, "qt_set_scroll_area_widget_resizable: scroll area required");
    sa->setWidgetResizable(resizable);
    return 0;
}

int lua_set_widget_size_policy(lua_State* L) {
    QWidget* widget = get_widget<QWidget>(L, 1);
    if (!widget) return luaL_error(L, "qt_set_widget_size_policy: widget required");
    
    const char* h_policy_str = luaL_checkstring(L, 2);
    const char* v_policy_str = luaL_checkstring(L, 3);
    
    auto policyFromString = [](const char* str) -> QSizePolicy::Policy {
        if (strcmp(str, "Fixed") == 0) return QSizePolicy::Fixed;
        if (strcmp(str, "Minimum") == 0) return QSizePolicy::Minimum;
        if (strcmp(str, "Maximum") == 0) return QSizePolicy::Maximum;
        if (strcmp(str, "Preferred") == 0) return QSizePolicy::Preferred;
        if (strcmp(str, "Expanding") == 0) return QSizePolicy::Expanding;
        if (strcmp(str, "MinimumExpanding") == 0) return QSizePolicy::MinimumExpanding;
        if (strcmp(str, "Ignored") == 0) return QSizePolicy::Ignored;
        return QSizePolicy::Preferred;
    };
    
    widget->setSizePolicy(policyFromString(h_policy_str), policyFromString(v_policy_str));
    return 0;
}

int lua_set_layout_stretch_factor(lua_State* L) {
    void* container_ptr = lua_to_widget(L, 1);
    QWidget* widget = get_widget<QWidget>(L, 2);
    int stretch = luaL_checkinteger(L, 3);
    
    if (QBoxLayout* box = widget_cast<QBoxLayout>(container_ptr)) {
        box->setStretchFactor(widget, stretch);
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_set_widget_alignment(lua_State* L)
{
    QWidget* widget = get_widget<QWidget>(L, 1);
    const char* alignment = lua_tostring(L, 2);

    if (widget && alignment) {
        Qt::Alignment align = Qt::AlignLeft;
        if (strcmp(alignment, "AlignRight") == 0) {
            align = Qt::AlignRight;
        } else if (strcmp(alignment, "AlignCenter") == 0) {
            align = Qt::AlignCenter;
        } else if (strcmp(alignment, "AlignLeft") == 0) {
            align = Qt::AlignLeft;
        }

        if (QLabel* label = qobject_cast<QLabel*>(widget)) {
            label->setAlignment(align);
            lua_pushboolean(L, 1);
        } else {
            JVE_LOG_WARN(Ui, "Widget type doesn't support alignment: %s", widget->metaObject()->className());
            lua_pushboolean(L, 0);
        }
    } else {
        JVE_LOG_WARN(Ui, "Invalid widget or alignment in set_widget_alignment");
        lua_pushboolean(L, 0);
    }
    return 1;
}

int qt_set_layout_alignment(lua_State* L) {
    void* container_ptr = lua_to_widget(L, 1);
    const char* align_str = luaL_checkstring(L, 2);
    
    Qt::Alignment alignment = getAlignmentMap().value(QString::fromUtf8(align_str), Qt::Alignment());
    
    if (QLayout* layout = widget_cast<QLayout>(container_ptr)) {
        layout->setAlignment(alignment);
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

int lua_scroll_area_h_scroll_by(lua_State* L) {
    QScrollArea* sa = get_widget<QScrollArea>(L, 1);
    int delta = luaL_checkinteger(L, 2);
    if (!sa) return luaL_error(L, "qt_scroll_area_h_scroll_by: scroll area required");
    QScrollBar* hbar = sa->horizontalScrollBar();
    if (hbar) {
        hbar->setValue(hbar->value() + delta);
    }
    return 0;
}

int lua_scroll_area_h_scroll_info(lua_State* L) {
    QScrollArea* sa = get_widget<QScrollArea>(L, 1);
    if (!sa) return luaL_error(L, "qt_scroll_area_h_scroll_info: scroll area required");
    QScrollBar* hbar = sa->horizontalScrollBar();
    lua_newtable(L);
    if (hbar) {
        lua_pushinteger(L, hbar->value());
        lua_setfield(L, -2, "value");
        lua_pushinteger(L, hbar->minimum());
        lua_setfield(L, -2, "min");
        lua_pushinteger(L, hbar->maximum());
        lua_setfield(L, -2, "max");
    } else {
        lua_pushinteger(L, 0);
        lua_setfield(L, -2, "value");
        lua_pushinteger(L, 0);
        lua_setfield(L, -2, "min");
        lua_pushinteger(L, 0);
        lua_setfield(L, -2, "max");
    }
    return 1;
}

int lua_set_parent(lua_State* L) {
    QWidget* child = get_widget<QWidget>(L, 1);
    QWidget* parent = nullptr;
    if (!lua_isnil(L, 2)) {
        parent = get_widget<QWidget>(L, 2);
    }

    if (child) {
        child->setParent(parent);
        lua_pushboolean(L, 1);
    } else {
        lua_pushboolean(L, 0);
    }
    return 1;
}

