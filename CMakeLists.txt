cmake_minimum_required(VERSION 3.22)

# Project definition
project(JVEEditor 
    VERSION 1.0.0 
    DESCRIPTION "Hackable Script-Forward Video Editor"
    LANGUAGES CXX
)

# C++ standard
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Build configuration
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Debug CACHE STRING "Build type" FORCE)
endif()

# Output directories
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)

# Find required packages
find_package(Qt6 REQUIRED COMPONENTS
    Core
    Widgets
    Sql
    Test
    Gui
    Multimedia
    Network    # QLocalServer for debug_terminal
)

# Find SQLite (usually comes with Qt6::Sql)
find_package(SQLite3 REQUIRED)
find_package(OpenSSL REQUIRED COMPONENTS Crypto)
find_package(nlohmann_json REQUIRED)

# LuaJIT for scripting
find_package(PkgConfig REQUIRED)
pkg_check_modules(LUAJIT REQUIRED luajit)

# FFmpeg for Editor Media Platform
pkg_check_modules(FFMPEG REQUIRED
    libavformat
    libavcodec
    libavutil
    libswscale
    libswresample
)

# Zstandard for decompressing Resolve DRP FieldsBlob payloads (synced clips)
pkg_check_modules(ZSTD REQUIRED libzstd)

# Compiler flags
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wall -Wextra -Wpedantic")
set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} -g -O0 -DDEBUG")
set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} -O3 -DNDEBUG")

# Include directories
include_directories(
    ${CMAKE_SOURCE_DIR}/src
    ${CMAKE_SOURCE_DIR}/include
)

# ============================================================================
# Editor Media Platform (EMP) Library - FFmpeg-backed video decoding
# ============================================================================
set(EMP_SOURCES
    src/editor_media_platform/src/emp_media_file.cpp
    src/editor_media_platform/src/emp_reader.cpp
    src/editor_media_platform/src/emp_timeline_media_buffer.cpp
    src/editor_media_platform/src/emp_frame.cpp
    src/editor_media_platform/src/emp_pcm_chunk.cpp
    src/editor_media_platform/src/impl/ffmpeg_context.cpp
    src/editor_media_platform/src/impl/ffmpeg_decode.cpp
    src/editor_media_platform/src/impl/ffmpeg_seek.cpp
    src/editor_media_platform/src/impl/ffmpeg_convert.cpp
    src/editor_media_platform/src/impl/ffmpeg_hwaccel.cpp
    src/editor_media_platform/src/impl/ffmpeg_resample.cpp
    src/editor_media_platform/src/impl/qtrle_decode.cpp
    src/editor_media_platform/src/impl/braw_decode.cpp
    src/editor_media_platform/src/impl/braw_dispatch.cpp
    src/editor_media_platform/src/emp_peak_file.cpp
    src/editor_media_platform/src/emp_peak_generator.cpp
    src/editor_media_platform/src/emp_cdl.cpp
    src/editor_media_platform/src/emp_lut3d.cpp
)

add_library(EditorMediaPlatform STATIC ${EMP_SOURCES})

target_include_directories(EditorMediaPlatform
    PUBLIC
        ${CMAKE_SOURCE_DIR}/src/editor_media_platform/include
    PRIVATE
        ${CMAKE_SOURCE_DIR}/src/editor_media_platform/src
        ${FFMPEG_INCLUDE_DIRS}
)

target_link_libraries(EditorMediaPlatform
    ${FFMPEG_LIBRARIES}
)

target_link_directories(EditorMediaPlatform PUBLIC
    ${FFMPEG_LIBRARY_DIRS}
)

# Hardware acceleration support (macOS VideoToolbox)
if(APPLE)
    find_library(VIDEOTOOLBOX_FRAMEWORK VideoToolbox REQUIRED)
    find_library(COREMEDIA_FRAMEWORK CoreMedia REQUIRED)
    find_library(COREVIDEO_FRAMEWORK CoreVideo REQUIRED)
    find_library(COREAUDIO_FRAMEWORK CoreAudio REQUIRED)  # For device latency query
    find_library(METAL_FRAMEWORK Metal REQUIRED)
    find_library(QUARTZCORE_FRAMEWORK QuartzCore REQUIRED)
    find_library(ACCELERATE_FRAMEWORK Accelerate REQUIRED)  # vImage for YUV→RGB
    find_library(APPLICATIONSERVICES_FRAMEWORK ApplicationServices REQUIRED)  # CGEventPost for synthetic input (binding/smoke tests)

    target_link_libraries(EditorMediaPlatform
        ${VIDEOTOOLBOX_FRAMEWORK}
        ${COREMEDIA_FRAMEWORK}
        ${COREVIDEO_FRAMEWORK}
        ${ACCELERATE_FRAMEWORK}
    )

    target_compile_definitions(EditorMediaPlatform PRIVATE EMP_HAS_VIDEOTOOLBOX)

    # Blackmagic RAW SDK (optional — runtime-loaded via dispatch)
    set(BRAW_SDK_INCLUDE "/Applications/Blackmagic RAW/Blackmagic RAW SDK/Mac/Include")
    if(EXISTS "${BRAW_SDK_INCLUDE}/BlackmagicRawAPI.h")
        target_include_directories(EditorMediaPlatform PRIVATE "${BRAW_SDK_INCLUDE}")
        target_compile_definitions(EditorMediaPlatform PRIVATE EMP_HAS_BRAW)
        message(STATUS "Blackmagic RAW SDK found at ${BRAW_SDK_INCLUDE}")
    else()
        message(STATUS "Blackmagic RAW SDK not found — BRAW decode disabled")
    endif()
endif()

# Ensure FFmpeg headers only in impl/ (enforced by code structure, not CMake)

# Source files organization
set(CORE_SOURCES
    src/resource_paths.cpp
    src/simple_lua_engine.cpp
    src/qt_bindings.cpp
    src/assert_handler.cpp
    src/jve_log.cpp
    src/jve_lua_callback.cpp
    src/debug_terminal.cpp

    # Bug reporter system
    src/bug_reporter/gesture_logger.cpp
    src/bug_reporter/qt_bindings_bug_reporter.cpp

    # Audio Output Platform
    src/audio_output_platform/aop.cpp

    # Scrub Stretch Engine (WSOLA time stretch)
    src/scrub_stretch_engine/sse.cpp

    # Background codec probe worker
    src/lua/qt_bindings/codec_probe_worker.cpp
)

set(UI_SOURCES
    src/timeline_renderer.cpp
    src/cpu_video_surface.cpp
)

# GPU video surface and playback controller (macOS only, Objective-C++ Metal)
if(APPLE)
    list(APPEND UI_SOURCES src/gpu_video_surface.mm)
    list(APPEND UI_SOURCES src/playback_controller.mm)
    set_source_files_properties(src/gpu_video_surface.mm PROPERTIES
        COMPILE_FLAGS "-x objective-c++"
    )
    set_source_files_properties(src/playback_controller.mm PROPERTIES
        COMPILE_FLAGS "-x objective-c++"
    )
endif()

# Core library (for testing and CLI tools)
add_library(JVECore STATIC
    ${CORE_SOURCES}
    ${UI_SOURCES}
)

# Enable MOC for JVECore library
set_target_properties(JVECore PROPERTIES
    AUTOMOC ON
)

target_link_libraries(JVECore
    Qt6::Core
    Qt6::Widgets
    Qt6::Sql
    Qt6::Gui
    Qt6::Multimedia
    Qt6::Network    # QLocalServer/QLocalSocket for debug_terminal.cpp
    SQLite::SQLite3
    ${LUAJIT_LIBRARIES}
    ${ZSTD_LIBRARIES}
    EditorMediaPlatform
)

target_link_directories(JVECore PUBLIC ${ZSTD_LIBRARY_DIRS})

# Metal video surface + audio latency dependencies (macOS)
if(APPLE)
    target_link_libraries(JVECore
        ${METAL_FRAMEWORK}
        ${QUARTZCORE_FRAMEWORK}
        ${COREVIDEO_FRAMEWORK}
        ${COREAUDIO_FRAMEWORK}
        ${APPLICATIONSERVICES_FRAMEWORK}  # CGEventPost (input_bindings.cpp)
    )
    target_compile_definitions(JVECore PRIVATE EMP_HAS_VIDEOTOOLBOX)
endif()

target_include_directories(JVECore PUBLIC
    ${CMAKE_SOURCE_DIR}/src
    ${LUAJIT_INCLUDE_DIRS}
    ${ZSTD_INCLUDE_DIRS}
)

# Main application executable
add_executable(jve
    src/main.cpp
)

# Enable MOC for main executable. On macOS we also bundle as a proper
# .app so the windowserver grants it frontmost-app status — raw binaries
# can't be foregrounded via System Events (the .app + Info.plist is
# what tells macOS "this is a real foreground app"), which blocks every
# osascript-driven keystroke test in the smoke suite.
set_target_properties(jve PROPERTIES
    AUTOMOC ON
    MACOSX_BUNDLE TRUE
    MACOSX_BUNDLE_BUNDLE_NAME "jve"
    MACOSX_BUNDLE_GUI_IDENTIFIER "net.shapiro.jve"
    MACOSX_BUNDLE_BUNDLE_VERSION "0.1.0"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "0.1.0"
)

target_link_libraries(jve
    JVECore
    Qt6::Core
    Qt6::Widgets
    Qt6::Sql
    Qt6::Gui
    SQLite::SQLite3
    ${LUAJIT_LIBRARIES}
)

target_include_directories(jve PUBLIC
    ${CMAKE_SOURCE_DIR}/src
    ${LUAJIT_INCLUDE_DIRS}
)

target_link_directories(jve PRIVATE
    ${LUAJIT_LIBRARY_DIRS}
)

# Bundle runtime trees into jve.app/Contents/Resources so the .app is
# self-contained for deployment (e.g. VM smoke runs). Layout in the
# bundle mirrors the repo (src/lua, keymaps, resources) so existing
# Lua resolvers (path_utils.resolve_repo_root, ResourcePaths) keep
# working unchanged — they just see the bundle as the "repo root."
# rsync (not cp) so incremental rebuilds only ship what changed.
# Locate lxp.so (LuaExpat C module) at configure time so the bundle
# rsync below can include it. lxp is required by core/menu_system.lua;
# all other Lua module deps are vendored as pure Lua in src/lua/.
# Search luarocks-local + homebrew + /usr/local locations; fail-fast
# if missing rather than producing a broken bundle.
find_file(LXP_SO lxp.so
    PATHS
        $ENV{HOME}/.luarocks/lib/lua/5.1
        /opt/homebrew/lib/lua/5.1
        /usr/local/lib/lua/5.1
    NO_DEFAULT_PATH
)
if(NOT LXP_SO)
    message(FATAL_ERROR
        "lxp.so (LuaExpat C module) not found. Install with:\n"
        "  luarocks --local install luaexpat")
endif()
message(STATUS "LuaExpat C module: ${LXP_SO}")

# lxp.so links against libexpat.1.dylib at a hardcoded brew path
# (/opt/homebrew/opt/expat/lib/...); bundle the dylib too and rewrite
# the link so the .app runs on hosts without brew (e.g. VM guests).
find_file(LIBEXPAT_DYLIB libexpat.1.dylib
    PATHS
        /opt/homebrew/opt/expat/lib
        /usr/local/opt/expat/lib
    NO_DEFAULT_PATH
)
if(NOT LIBEXPAT_DYLIB)
    message(FATAL_ERROR
        "libexpat.1.dylib not found. Install with:\n"
        "  brew install expat")
endif()
message(STATUS "libexpat: ${LIBEXPAT_DYLIB}")

# POST_BUILD bundling — runs only when jve is freshly linked. This is
# the right phase for the lxp / libexpat dylib work: install_name_tool
# rewrites + ad-hoc codesign only matter when the .app binary itself
# is fresh (the dylibs become stable artifacts of the bundle). For
# Lua-only edits the linker doesn't run, so we ALSO need an always-
# fires rsync target below — see bundle_runtime_tree.
add_custom_command(TARGET jve POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory "$<TARGET_FILE_DIR:jve>/../Resources/lua_modules"
    COMMAND ${CMAKE_COMMAND} -E make_directory "$<TARGET_FILE_DIR:jve>/../Frameworks"
    # Lua C modules + Frameworks/libexpat. Always-copy (not
    # copy_if_different) so each build starts with a virgin file —
    # this makes the install_name_tool sequence deterministic and
    # avoids the "rpath already exists" error that would otherwise
    # force a silent `|| true` (an NSF-violating fallback).
    COMMAND ${CMAKE_COMMAND} -E copy
        "${LXP_SO}"
        "$<TARGET_FILE_DIR:jve>/../Resources/lua_modules/lxp.so"
    COMMAND ${CMAKE_COMMAND} -E copy
        "${LIBEXPAT_DYLIB}"
        "$<TARGET_FILE_DIR:jve>/../Frameworks/libexpat.1.dylib"
    COMMAND chmod u+w
        "$<TARGET_FILE_DIR:jve>/../Frameworks/libexpat.1.dylib"
        "$<TARGET_FILE_DIR:jve>/../Resources/lua_modules/lxp.so"
    COMMAND install_name_tool -id "@rpath/libexpat.1.dylib"
        "$<TARGET_FILE_DIR:jve>/../Frameworks/libexpat.1.dylib"
    COMMAND install_name_tool -change
        "/opt/homebrew/opt/expat/lib/libexpat.1.dylib"
        "@rpath/libexpat.1.dylib"
        "$<TARGET_FILE_DIR:jve>/../Resources/lua_modules/lxp.so"
    COMMAND install_name_tool -add_rpath "@loader_path/../../Frameworks"
        "$<TARGET_FILE_DIR:jve>/../Resources/lua_modules/lxp.so"
    # Re-sign ad-hoc — install_name_tool invalidates the original
    # brew signatures, and macOS 15+ SIGKILLs the process on first
    # dyld load when ANY page in the process is unsigned. Without
    # this, jve crashes with CODESIGNING/Invalid Page (typically
    # taking down a sibling Qt plugin like libqsvgicon).
    COMMAND codesign --force --sign - --timestamp=none
        "$<TARGET_FILE_DIR:jve>/../Frameworks/libexpat.1.dylib"
    COMMAND codesign --force --sign - --timestamp=none
        "$<TARGET_FILE_DIR:jve>/../Resources/lua_modules/lxp.so"
    WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
    COMMENT "Bundling lua_modules + Frameworks/libexpat into jve.app"
    VERBATIM
)

# Always-fires runtime-tree bundling: ship src/lua + keymaps + resources
# + menus.xml into Contents/Resources on every `make jve`. Without this,
# Lua-only edits (no C++ recompile → no link → no POST_BUILD) would not
# reach the bundled .app, and a developer iterating on Lua against the
# bundled app would silently run stale code.
#
# JVE_BUNDLE_LUA selects how the runtime trees reach Contents/Resources:
#   copy     (default) — rsync. Bundle is self-contained, portable to
#              a VM / another machine without the repo. ~50ms incremental.
#   symlink            — symlink each runtime tree into the bundle.
#              Live Lua edits visible to the running .app immediately
#              (after Lua module reload / app restart) with no build
#              step. Bundle is NOT portable: copying it elsewhere yields
#              dangling symlinks. Use for local dev only.
set(JVE_BUNDLE_LUA "copy" CACHE STRING
    "How to bundle src/lua + keymaps + resources into jve.app: 'copy' (portable) or 'symlink' (dev)")
set_property(CACHE JVE_BUNDLE_LUA PROPERTY STRINGS copy symlink)
if(NOT (JVE_BUNDLE_LUA STREQUAL "copy" OR JVE_BUNDLE_LUA STREQUAL "symlink"))
    message(FATAL_ERROR
        "Invalid JVE_BUNDLE_LUA='${JVE_BUNDLE_LUA}'. Must be 'copy' or 'symlink'.")
endif()

if(JVE_BUNDLE_LUA STREQUAL "symlink")
    # ln -sfn handles the idempotent re-symlink. The initial conversion
    # from a copy-mode bundle requires removing the existing directory
    # (ln -sfn refuses to replace a directory with a symlink).
    add_custom_target(bundle_runtime_tree ALL
        COMMAND ${CMAKE_COMMAND} -E make_directory "$<TARGET_FILE_DIR:jve>/../Resources/src"
        COMMAND sh -c "rm -rf '$<TARGET_FILE_DIR:jve>/../Resources/src/lua' && ln -sfn '${CMAKE_SOURCE_DIR}/src/lua' '$<TARGET_FILE_DIR:jve>/../Resources/src/lua'"
        COMMAND sh -c "rm -rf '$<TARGET_FILE_DIR:jve>/../Resources/keymaps' && ln -sfn '${CMAKE_SOURCE_DIR}/keymaps' '$<TARGET_FILE_DIR:jve>/../Resources/keymaps'"
        COMMAND sh -c "rm -rf '$<TARGET_FILE_DIR:jve>/../Resources/resources' && ln -sfn '${CMAKE_SOURCE_DIR}/resources' '$<TARGET_FILE_DIR:jve>/../Resources/resources'"
        COMMAND sh -c "rm -rf '$<TARGET_FILE_DIR:jve>/../Resources/tools' && ln -sfn '${CMAKE_SOURCE_DIR}/tools' '$<TARGET_FILE_DIR:jve>/../Resources/tools'"
        COMMAND sh -c "rm -f  '$<TARGET_FILE_DIR:jve>/../Resources/menus.xml' && ln -sfn '${CMAKE_SOURCE_DIR}/menus.xml' '$<TARGET_FILE_DIR:jve>/../Resources/menus.xml'"
        WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
        COMMENT "Symlinking src/lua + keymaps + resources + tools + menus.xml into jve.app (JVE_BUNDLE_LUA=symlink)"
        VERBATIM
    )
else()
    # rsync incremental copy. -R preserves the leading path component
    # (src/lua, not just lua) so path_utils.resolve_repo_root keeps
    # working. --delete removes stale entries left by previous builds.
    add_custom_target(bundle_runtime_tree ALL
        COMMAND rsync -aR --delete
            src/lua keymaps resources tools menus.xml
            "$<TARGET_FILE_DIR:jve>/../Resources/"
        WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
        COMMENT "Bundling src/lua + keymaps + resources + tools + menus.xml into jve.app (JVE_BUNDLE_LUA=copy)"
        VERBATIM
    )
endif()
# Order: jve must be linked first (so Contents/MacOS exists for
# $<TARGET_FILE_DIR:jve> to resolve), then bundle into Resources.
add_dependencies(bundle_runtime_tree jve)

# Testing
enable_testing()

# Configure CTest to use tests/temp instead of Testing/
set(CMAKE_CTEST_COMMAND "${CMAKE_CTEST_COMMAND}")
set(CTEST_BINARY_DIRECTORY "${CMAKE_SOURCE_DIR}/tests/temp")

## Disabled: eventlog golden replay (not used)

# Enable automatic MOC, UIC and RCC processing
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTOUIC ON)
set(CMAKE_AUTORCC ON)

# C++/Qt tests (on by default)
# Unit tests (no unit tests currently - they would go in tests/synthetic/unit/)
# Note: New timeline tests are standalone and defined below

# Standalone timeline widget test (no test_base dependency)
add_executable(test_timeline_renderer_widget
    tests/synthetic/unit/test_timeline_renderer_widget.cpp
)
target_link_libraries(test_timeline_renderer_widget
    JVECore
    Qt6::Test
    Qt6::Core
    Qt6::Widgets
    Qt6::Gui
    ${LUAJIT_LIBRARIES}
)
target_include_directories(test_timeline_renderer_widget PUBLIC
    ${CMAKE_SOURCE_DIR}
    ${LUAJIT_INCLUDE_DIRS}
)
target_link_directories(test_timeline_renderer_widget PRIVATE
    ${LUAJIT_LIBRARY_DIRS}
)
set_target_properties(test_timeline_renderer_widget PROPERTIES
    AUTOMOC ON
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin
)
add_test(NAME test_timeline_renderer_widget COMMAND test_timeline_renderer_widget)

# Standalone Qt bindings test (no test_base dependency)
add_executable(test_qt_bindings
    tests/synthetic/unit/test_qt_bindings.cpp
)
target_link_libraries(test_qt_bindings
    JVECore
    Qt6::Test
    Qt6::Core
    Qt6::Widgets
    Qt6::Gui
    ${LUAJIT_LIBRARIES}
)
target_include_directories(test_qt_bindings PUBLIC
    ${CMAKE_SOURCE_DIR}
    ${LUAJIT_INCLUDE_DIRS}
)
target_link_directories(test_qt_bindings PRIVATE
    ${LUAJIT_LIBRARY_DIRS}
)
set_target_properties(test_qt_bindings PROPERTIES
    AUTOMOC ON
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin
)
add_test(NAME test_qt_bindings COMMAND test_qt_bindings)

# EMP Core test (MediaFile, Reader, Frame, HW accel)
add_executable(test_emp_core
    tests/synthetic/unit/test_emp_core.cpp
)
target_link_libraries(test_emp_core
    JVECore
    EditorMediaPlatform
    Qt6::Test
    Qt6::Core
    Qt6::Widgets
    Qt6::Gui
    ${LUAJIT_LIBRARIES}
)
target_include_directories(test_emp_core PUBLIC
    ${CMAKE_SOURCE_DIR}
    ${CMAKE_SOURCE_DIR}/src/editor_media_platform/include
    ${LUAJIT_INCLUDE_DIRS}
)
target_link_directories(test_emp_core PRIVATE
    ${LUAJIT_LIBRARY_DIRS}
)
set_target_properties(test_emp_core PROPERTIES
    AUTOMOC ON
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin
)
if(APPLE)
    target_compile_definitions(test_emp_core PRIVATE EMP_HAS_VIDEOTOOLBOX)
endif()
add_test(NAME test_emp_core COMMAND test_emp_core)

# Video Surface test (VideoSurfaceWidget, MetalVideoSurface)
add_executable(test_video_surface
    tests/synthetic/unit/test_video_surface.cpp
)
target_link_libraries(test_video_surface
    JVECore
    EditorMediaPlatform
    Qt6::Test
    Qt6::Core
    Qt6::Widgets
    Qt6::Gui
    ${LUAJIT_LIBRARIES}
)
target_include_directories(test_video_surface PUBLIC
    ${CMAKE_SOURCE_DIR}
    ${CMAKE_SOURCE_DIR}/src
    ${CMAKE_SOURCE_DIR}/src/editor_media_platform/include
    ${LUAJIT_INCLUDE_DIRS}
)
target_link_directories(test_video_surface PRIVATE
    ${LUAJIT_LIBRARY_DIRS}
)
set_target_properties(test_video_surface PROPERTIES
    AUTOMOC ON
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin
)
if(APPLE)
    target_compile_definitions(test_video_surface PRIVATE EMP_HAS_VIDEOTOOLBOX)
endif()
add_test(NAME test_video_surface COMMAND test_video_surface)

# SSE Core test (Scrub Stretch Engine)
add_executable(test_sse_core
    tests/synthetic/unit/test_sse_core.cpp
)
target_link_libraries(test_sse_core
    JVECore
    Qt6::Test
    Qt6::Core
    ${LUAJIT_LIBRARIES}
)
target_include_directories(test_sse_core PUBLIC
    ${CMAKE_SOURCE_DIR}
    ${CMAKE_SOURCE_DIR}/src
    ${LUAJIT_INCLUDE_DIRS}
)
target_link_directories(test_sse_core PRIVATE
    ${LUAJIT_LIBRARY_DIRS}
)
set_target_properties(test_sse_core PROPERTIES
    AUTOMOC ON
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin
)
add_test(NAME test_sse_core COMMAND test_sse_core)

# SSE Decimate test (>4x speeds)
add_executable(test_sse_decimate
    tests/synthetic/unit/test_sse_decimate.cpp
)
target_link_libraries(test_sse_decimate
    JVECore
    Qt6::Test
    Qt6::Core
    ${LUAJIT_LIBRARIES}
)
target_include_directories(test_sse_decimate PUBLIC
    ${CMAKE_SOURCE_DIR}
    ${CMAKE_SOURCE_DIR}/src
    ${LUAJIT_INCLUDE_DIRS}
)
target_link_directories(test_sse_decimate PRIVATE
    ${LUAJIT_LIBRARY_DIRS}
)
set_target_properties(test_sse_decimate PROPERTIES
    AUTOMOC ON
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin
)
add_test(NAME test_sse_decimate COMMAND test_sse_decimate)

# SSE Pitch test (WSOLA pitch preservation)
add_executable(test_sse_pitch
    tests/synthetic/unit/test_sse_pitch.cpp
)
target_link_libraries(test_sse_pitch
    JVECore
    Qt6::Test
    Qt6::Core
    ${LUAJIT_LIBRARIES}
)
target_include_directories(test_sse_pitch PUBLIC
    ${CMAKE_SOURCE_DIR}
    ${CMAKE_SOURCE_DIR}/src
    ${LUAJIT_INCLUDE_DIRS}
)
target_link_directories(test_sse_pitch PRIVATE
    ${LUAJIT_LIBRARY_DIRS}
)
set_target_properties(test_sse_pitch PROPERTIES
    AUTOMOC ON
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin
)
add_test(NAME test_sse_pitch COMMAND test_sse_pitch)

# PlaybackClock (A/V sync clock) test
add_executable(test_playback_clock
    tests/synthetic/unit/test_playback_clock.cpp
)
target_link_libraries(test_playback_clock
    JVECore
    Qt6::Test
    Qt6::Core
    ${LUAJIT_LIBRARIES}
)
target_include_directories(test_playback_clock PUBLIC
    ${CMAKE_SOURCE_DIR}
    ${CMAKE_SOURCE_DIR}/src
    ${LUAJIT_INCLUDE_DIRS}
)
target_link_directories(test_playback_clock PRIVATE
    ${LUAJIT_LIBRARY_DIRS}
)
set_target_properties(test_playback_clock PROPERTIES
    AUTOMOC ON
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin
)
add_test(NAME test_playback_clock COMMAND test_playback_clock)

# TMB READER_WARM proximity picker — pure picker over PreBufferJob vector
add_executable(test_tmb_warm_picker
    tests/synthetic/unit/test_tmb_warm_picker.cpp
    src/assert_handler.cpp
)
target_link_libraries(test_tmb_warm_picker
    EditorMediaPlatform
    Qt6::Test
    Qt6::Core
    ${LUAJIT_LIBRARIES}
)
target_include_directories(test_tmb_warm_picker PUBLIC
    ${CMAKE_SOURCE_DIR}
    ${CMAKE_SOURCE_DIR}/src/editor_media_platform/include
    ${LUAJIT_INCLUDE_DIRS}
)
target_link_directories(test_tmb_warm_picker PRIVATE
    ${LUAJIT_LIBRARY_DIRS}
)
set_target_properties(test_tmb_warm_picker PROPERTIES
    AUTOMOC ON
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin
)
add_test(NAME test_tmb_warm_picker COMMAND test_tmb_warm_picker)

# Video-track visibility filter (mute/solo composite) — pure header function
add_executable(test_video_track_filter
    tests/synthetic/unit/test_video_track_filter.cpp
)
target_link_libraries(test_video_track_filter
    JVECore
    Qt6::Test
    Qt6::Core
    ${LUAJIT_LIBRARIES}
)
target_include_directories(test_video_track_filter PUBLIC
    ${CMAKE_SOURCE_DIR}
    ${CMAKE_SOURCE_DIR}/src
    ${LUAJIT_INCLUDE_DIRS}
)
target_link_directories(test_video_track_filter PRIVATE
    ${LUAJIT_LIBRARY_DIRS}
)
set_target_properties(test_video_track_filter PROPERTIES
    AUTOMOC ON
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin
)
add_test(NAME test_video_track_filter COMMAND test_video_track_filter)

# TMB (TimelineMediaBuffer) test
add_executable(test_tmb
    tests/synthetic/unit/test_timeline_media_buffer.cpp
)
target_link_libraries(test_tmb
    JVECore
    EditorMediaPlatform
    Qt6::Test
    Qt6::Core
    Qt6::Widgets
    Qt6::Gui
    ${LUAJIT_LIBRARIES}
)
target_include_directories(test_tmb PUBLIC
    ${CMAKE_SOURCE_DIR}
    ${CMAKE_SOURCE_DIR}/src/editor_media_platform/include
    ${LUAJIT_INCLUDE_DIRS}
)
target_link_directories(test_tmb PRIVATE
    ${LUAJIT_LIBRARY_DIRS}
)
set_target_properties(test_tmb PROPERTIES
    AUTOMOC ON
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin
)
add_test(NAME test_tmb COMMAND test_tmb)

# Test targets:
#   - Depend on jve (executable rebuilt if C++ changed — correctness).
#   - Do NOT depend on each other via add_dependencies: custom targets have
#     no stamp and re-run unconditionally, so chaining (binding_tests →
#     lua_tests → jve) caused Lua tests to run 3× per `make` (~60s
#     wasted). Each layer now runs exactly once.
#   - Fail-fast ordering across layers is NOT guaranteed by make -j — if
#     that matters for a workflow, invoke targets sequentially or use ctest.

add_custom_target(lua_tests
    COMMAND ${CMAKE_SOURCE_DIR}/scripts/run_lua_tests.sh
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    COMMENT "Running Lua test suite"
)
add_dependencies(lua_tests jve)
add_test(NAME lua_suite
    COMMAND ${CMAKE_SOURCE_DIR}/scripts/run_lua_tests.sh
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
)

# Resolve-helper Python unit tests — offline-pure (fakes only, no
# Resolve/VM/jve), <1s. No jve dependency: nothing in them touches the
# binary, so they run even while the C++ build is broken.
add_custom_target(helper_tests
    COMMAND ${CMAKE_SOURCE_DIR}/scripts/run_helper_tests.sh
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    COMMENT "Running resolve-helper Python unit tests"
)
add_test(NAME helper_suite
    COMMAND ${CMAKE_SOURCE_DIR}/scripts/run_helper_tests.sh
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
)

add_custom_target(binding_tests
    COMMAND ${CMAKE_COMMAND} -E env "JVE_BINARY=$<TARGET_FILE:jve>"
            ${CMAKE_SOURCE_DIR}/scripts/run_binding_tests.sh
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    COMMENT "Running binding tests (Lua tests requiring C++ bindings)"
)
add_dependencies(binding_tests jve)
add_test(NAME binding_suite
    COMMAND ${CMAKE_COMMAND} -E env "JVE_BINARY=$<TARGET_FILE:jve>"
            ${CMAKE_SOURCE_DIR}/scripts/run_binding_tests.sh
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
)

add_custom_target(integration_tests
    COMMAND ${CMAKE_COMMAND} -E env "JVE_BINARY=$<TARGET_FILE:jve>"
            ${CMAKE_SOURCE_DIR}/tests/run_integration_tests.sh
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    COMMENT "Running integration tests (real C++ EMP bindings)"
)
add_dependencies(integration_tests jve)
add_test(NAME integration_suite
    COMMAND ${CMAKE_COMMAND} -E env "JVE_BINARY=$<TARGET_FILE:jve>"
            ${CMAKE_SOURCE_DIR}/tests/run_integration_tests.sh
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
)

# Standalone Lua timeline logic test (no test_base dependency)
# Installation (not applicable for M1 Foundation tests)

# Package configuration
set(CPACK_PACKAGE_NAME "JVE-Editor")
set(CPACK_PACKAGE_VERSION_MAJOR ${PROJECT_VERSION_MAJOR})
set(CPACK_PACKAGE_VERSION_MINOR ${PROJECT_VERSION_MINOR})
set(CPACK_PACKAGE_VERSION_PATCH ${PROJECT_VERSION_PATCH})
set(CPACK_PACKAGE_DESCRIPTION_SUMMARY ${PROJECT_DESCRIPTION})

include(CPack)

# ---- Navigation indexes (ctags + JSON) ----
#
# Generates:
#   - ${CMAKE_SOURCE_DIR}/tags
#   - docs/symbol-index/symbols.json
#   - docs/symbol-index/commands.json
#
# Usage:
#   cmake --build <build_dir> --target nav-index
#
# Notes:
# - Not wired into default builds to avoid slowing incremental compiles.
# - If tools are missing, targets print a message and exit successfully (non-fatal).

find_program(CTAGS_EXE ctags)
find_program(PYTHON3_EXE python3)

set(SYMBOL_INDEX_DIR "${CMAKE_SOURCE_DIR}/docs/symbol-index")
set(TAGS_FILE "${CMAKE_SOURCE_DIR}/tags")
set(SYMBOLS_JSON "${SYMBOL_INDEX_DIR}/symbols.json")
set(COMMANDS_JSON "${SYMBOL_INDEX_DIR}/commands.json")

add_custom_target(nav-index
    COMMENT "Generate navigation indexes: tags, symbols.json, commands.json"
)

add_custom_target(tags
    COMMAND ${CMAKE_COMMAND} -E make_directory "${SYMBOL_INDEX_DIR}"
    COMMAND ${CMAKE_COMMAND} -E echo "Generating ctags: ${TAGS_FILE}"
    COMMAND ${CMAKE_COMMAND} -E env
            sh -c "if [ -z \"${CTAGS_EXE}\" ]; then echo \"ctags not found (install universal-ctags)\"; exit 0; fi; \
                   \"${CTAGS_EXE}\" -R \
                     --quiet \
                     --languages=Lua,C,C++,Python \
                     --exclude=.git --exclude=build --exclude=CMakeFiles \
                     -f \"${TAGS_FILE}\" \"${CMAKE_SOURCE_DIR}\""
    WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
    VERBATIM
)

add_custom_target(symbol-index
    COMMAND ${CMAKE_COMMAND} -E make_directory "${SYMBOL_INDEX_DIR}"
    COMMAND ${CMAKE_COMMAND} -E env
            sh -c "if [ -z \"${PYTHON3_EXE}\" ]; then echo \"python3 not found\"; exit 0; fi; \
                   if [ ! -f \"${CMAKE_SOURCE_DIR}/tools/symbol_index_from_tags.py\" ]; then \
                     echo \"Missing tools/symbol_index_from_tags.py\"; exit 0; fi; \
                   if [ ! -f \"${TAGS_FILE}\" ]; then echo \"Missing ${TAGS_FILE} (run target: tags)\"; exit 0; fi; \
                   \"${PYTHON3_EXE}\" \"${CMAKE_SOURCE_DIR}/tools/symbol_index_from_tags.py\" \"${TAGS_FILE}\" \"${SYMBOLS_JSON}\""
    WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
    VERBATIM
)

add_custom_target(commands-index
    COMMAND ${CMAKE_COMMAND} -E make_directory "${SYMBOL_INDEX_DIR}"
    COMMAND ${CMAKE_COMMAND} -E env
            sh -c "if [ -z \"${PYTHON3_EXE}\" ]; then echo \"python3 not found\"; exit 0; fi; \
                   if [ ! -f \"${CMAKE_SOURCE_DIR}/tools/command_index.py\" ]; then \
                     echo \"Missing tools/command_index.py\"; exit 0; fi; \
                   \"${PYTHON3_EXE}\" \"${CMAKE_SOURCE_DIR}/tools/command_index.py\" \"${COMMANDS_JSON}\""
    WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
    VERBATIM
)

add_dependencies(symbol-index tags)
add_dependencies(nav-index tags symbol-index commands-index)

