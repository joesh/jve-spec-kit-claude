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
)

# Find SQLite (usually comes with Qt6::Sql)
find_package(SQLite3 REQUIRED)
find_package(OpenSSL REQUIRED COMPONENTS Crypto)
find_package(nlohmann_json REQUIRED)

# LuaJIT for scripting
find_package(PkgConfig REQUIRED)
pkg_check_modules(LUAJIT REQUIRED luajit)

# Compiler flags
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wall -Wextra -Wpedantic")
set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} -g -O0 -DDEBUG")
set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} -O3 -DNDEBUG")

# Include directories
include_directories(
    ${CMAKE_SOURCE_DIR}/src
    ${CMAKE_SOURCE_DIR}/include
)

# Source files organization
set(CORE_SOURCES
    src/resource_paths.cpp
    src/simple_lua_engine.cpp
    src/qt_bindings.cpp

    # Bug reporter system
    src/bug_reporter/gesture_logger.cpp
    src/bug_reporter/qt_bindings_bug_reporter.cpp
)

set(UI_SOURCES
    src/timeline_renderer.cpp
    # Removed C++ UI implementations that violate architecture (should be Lua):
    # src/ui/keyboard_customization_dialog.cpp  (MOVED TO LUA - src/lua/ui/)
    # src/ui/selection/selection_manager.cpp
    # src/ui/timeline/timeline_panel.cpp
    # src/ui/input/keyboard_shortcuts.cpp
    # src/ui/common/context_menu_manager.cpp
    # src/ui/common/ui_command_bridge.cpp
    # src/ui/common/selection_visualizer.cpp
    # src/ui/common/drag_drop_manager.cpp
    # src/ui/common/ui_state_manager.cpp
    # src/ui/common/theme_manager.cpp
    # src/ui/common/performance_monitor.cpp
)

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
    SQLite::SQLite3
    ${LUAJIT_LIBRARIES}
)

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

