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
    src/editor_media_platform/src/emp_asset.cpp
    src/editor_media_platform/src/emp_reader.cpp
    src/editor_media_platform/src/emp_frame.cpp
    src/editor_media_platform/src/emp_pcm_chunk.cpp
    src/editor_media_platform/src/impl/ffmpeg_context.cpp
    src/editor_media_platform/src/impl/ffmpeg_decode.cpp
    src/editor_media_platform/src/impl/ffmpeg_seek.cpp
    src/editor_media_platform/src/impl/ffmpeg_convert.cpp
    src/editor_media_platform/src/impl/ffmpeg_hwaccel.cpp
    src/editor_media_platform/src/impl/ffmpeg_resample.cpp
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
    find_library(METAL_FRAMEWORK Metal REQUIRED)
    find_library(QUARTZCORE_FRAMEWORK QuartzCore REQUIRED)

    target_link_libraries(EditorMediaPlatform
        ${VIDEOTOOLBOX_FRAMEWORK}
        ${COREMEDIA_FRAMEWORK}
        ${COREVIDEO_FRAMEWORK}
    )

    target_compile_definitions(EditorMediaPlatform PRIVATE EMP_HAS_VIDEOTOOLBOX)
endif()

# Ensure FFmpeg headers only in impl/ (enforced by code structure, not CMake)

# Source files organization
set(CORE_SOURCES
    src/resource_paths.cpp
    src/simple_lua_engine.cpp
    src/qt_bindings.cpp
    src/assert_handler.cpp

    # Bug reporter system
    src/bug_reporter/gesture_logger.cpp
    src/bug_reporter/qt_bindings_bug_reporter.cpp

    # Audio Output Platform
    src/audio_output_platform/aop.cpp

    # Scrub Stretch Engine (WSOLA time stretch)
    src/scrub_stretch_engine/sse.cpp
)

set(UI_SOURCES
    src/timeline_renderer.cpp
    src/cpu_video_surface.cpp
)

# GPU video surface (macOS only, Objective-C++ Metal)
if(APPLE)
    list(APPEND UI_SOURCES src/gpu_video_surface.mm)
    set_source_files_properties(src/gpu_video_surface.mm PROPERTIES
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
    SQLite::SQLite3
    ${LUAJIT_LIBRARIES}
    EditorMediaPlatform
)

# Metal video surface dependencies (macOS)
if(APPLE)
    target_link_libraries(JVECore
        ${METAL_FRAMEWORK}
        ${QUARTZCORE_FRAMEWORK}
        ${COREVIDEO_FRAMEWORK}
    )
    target_compile_definitions(JVECore PRIVATE EMP_HAS_VIDEOTOOLBOX)
endif()

target_include_directories(JVECore PUBLIC
    ${CMAKE_SOURCE_DIR}/src
    ${LUAJIT_INCLUDE_DIRS}
)

# Main application executable
add_executable(JVEEditor 
    src/main.cpp
)

# Enable MOC for main executable
set_target_properties(JVEEditor PROPERTIES
    AUTOMOC ON
)

target_link_libraries(JVEEditor
    JVECore
    Qt6::Core
    Qt6::Widgets
    Qt6::Sql
    Qt6::Gui
    SQLite::SQLite3
    ${LUAJIT_LIBRARIES}
)

target_include_directories(JVEEditor PUBLIC
    ${CMAKE_SOURCE_DIR}/src
    ${LUAJIT_INCLUDE_DIRS}
)

target_link_directories(JVEEditor PRIVATE
    ${LUAJIT_LIBRARY_DIRS}
)

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
# Unit tests (no unit tests currently - they would go in tests/unit/)
# Note: New timeline tests are standalone and defined below

# Standalone timeline widget test (no test_base dependency)
add_executable(test_timeline_renderer_widget
    tests/unit/test_timeline_renderer_widget.cpp
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
    tests/unit/test_qt_bindings.cpp
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

# EMP Core test (Asset, Reader, Frame, HW accel)
add_executable(test_emp_core
    tests/unit/test_emp_core.cpp
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
    tests/unit/test_video_surface.cpp
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
    tests/unit/test_sse_core.cpp
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
    tests/unit/test_sse_decimate.cpp
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

add_custom_target(lua_tests ALL
    COMMAND ${CMAKE_SOURCE_DIR}/scripts/run_lua_tests.sh
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    COMMENT "Running Lua test suite"
)

add_dependencies(lua_tests JVEEditor)
add_test(NAME lua_suite
    COMMAND ${CMAKE_SOURCE_DIR}/scripts/run_lua_tests.sh
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

