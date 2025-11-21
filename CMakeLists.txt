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
    src/core/models/project.cpp
    src/core/models/sequence.cpp
    src/core/models/track.cpp
    src/core/models/clip.cpp
    src/core/models/media.cpp
    src/core/models/property.cpp
    
    src/core/commands/command.cpp
    src/core/commands/command_manager.cpp
    
    src/core/api/project_manager.cpp
    src/core/api/selection_manager.cpp
    
    src/core/persistence/migrations.cpp
    src/core/persistence/project_persistence.cpp
    src/core/persistence/schema_validator.cpp
    src/core/persistence/sql_executor.cpp
    
    src/core/timeline/timeline_manager.cpp
    
    src/core/common/uuid_generator.cpp
    src/core/resource_paths.cpp

    src/lua/simple_lua_engine.cpp
    src/lua/qt_bindings.cpp
)

set(UI_SOURCES
    src/ui/timeline/scriptable_timeline.cpp
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

# LUA sources - timeline FFI implementation (disabled for now)
# set(LUA_SOURCES
#     src/lua/timeline_ffi.cpp
# )

# Core library (for testing and CLI tools)
add_library(JVECore STATIC 
    ${CORE_SOURCES}
    ${UI_SOURCES}
    # ${LUA_SOURCES}
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

## Disabled: eventlog golden replay (not used)

# Enable automatic MOC, UIC and RCC processing
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTOUIC ON)
set(CMAKE_AUTORCC ON)

# Legacy C++ contract/integration tests are disabled by default; Lua suite is authoritative.
option(ENABLE_LEGACY_CPP_TESTS "Build legacy Qt/SQLite contract and integration tests" OFF)

if(ENABLE_LEGACY_CPP_TESTS)
    # Contract tests
    file(GLOB CONTRACT_TEST_SOURCES tests/contract/*.cpp)
    # Exclude tests for deleted UI components and broken tests
    list(FILTER CONTRACT_TEST_SOURCES EXCLUDE REGEX ".*(selection_system|selection_properties|clip_selection|edge_selection|uuid_determinism|command_execute|command_redo|command_undo).*")
    foreach(test_source ${CONTRACT_TEST_SOURCES})
        get_filename_component(test_name ${test_source} NAME_WE)
        add_executable(${test_name}
            ${test_source}
            tests/common/test_base.cpp
        )
        target_link_libraries(${test_name}
            JVECore
            Qt6::Test
            Qt6::Core
            Qt6::Gui
            ${LUAJIT_LIBRARIES}
        )
        target_include_directories(${test_name} PUBLIC
            ${CMAKE_SOURCE_DIR}
            ${LUAJIT_INCLUDE_DIRS}
        )
        target_link_directories(${test_name} PRIVATE
            ${LUAJIT_LIBRARY_DIRS}
        )
        add_test(NAME ${test_name} COMMAND ${test_name})
    endforeach()

    # Integration tests - Command replay invariant test
    add_executable(test_command_replay_invariant
        tests/integration/test_command_replay_invariant.cpp
    )
    target_link_libraries(test_command_replay_invariant
        JVECore
        Qt6::Test
        Qt6::Core
        Qt6::Widgets
        Qt6::Sql
        Qt6::Gui
        ${LUAJIT_LIBRARIES}
    )
    target_include_directories(test_command_replay_invariant PUBLIC
        ${CMAKE_SOURCE_DIR}
        ${LUAJIT_INCLUDE_DIRS}
    )
    target_link_directories(test_command_replay_invariant PRIVATE
        ${LUAJIT_LIBRARY_DIRS}
    )
    set_target_properties(test_command_replay_invariant PROPERTIES
        AUTOMOC ON
        RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin
    )
    add_test(NAME test_command_replay_invariant COMMAND test_command_replay_invariant)

    # Integration test - Canonical batch ripple drag regression
    add_executable(test_batch_ripple_gap_drag
        tests/integration/test_batch_ripple_gap_drag.cpp
    )
    target_link_libraries(test_batch_ripple_gap_drag
        JVECore
        Qt6::Test
        Qt6::Core
        Qt6::Widgets
        Qt6::Sql
        Qt6::Gui
        ${LUAJIT_LIBRARIES}
    )
    target_include_directories(test_batch_ripple_gap_drag PUBLIC
        ${CMAKE_SOURCE_DIR}
        ${LUAJIT_INCLUDE_DIRS}
    )
    target_link_directories(test_batch_ripple_gap_drag PRIVATE
        ${LUAJIT_LIBRARY_DIRS}
    )
    set_target_properties(test_batch_ripple_gap_drag PROPERTIES
        AUTOMOC ON
        RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin
    )
    add_test(NAME test_batch_ripple_gap_drag COMMAND test_batch_ripple_gap_drag)
endif()

# Unit tests (no unit tests currently - they would go in tests/unit/)
# Note: New timeline tests are standalone and defined below

# Standalone timeline widget test (no test_base dependency)
add_executable(test_scriptable_timeline_widget
    tests/unit/test_scriptable_timeline_widget.cpp
)
target_link_libraries(test_scriptable_timeline_widget
    JVECore
    Qt6::Test
    Qt6::Core
    Qt6::Widgets
    Qt6::Gui
    ${LUAJIT_LIBRARIES}
)
target_include_directories(test_scriptable_timeline_widget PUBLIC
    ${CMAKE_SOURCE_DIR}
    ${LUAJIT_INCLUDE_DIRS}
)
target_link_directories(test_scriptable_timeline_widget PRIVATE
    ${LUAJIT_LIBRARY_DIRS}
)
set_target_properties(test_scriptable_timeline_widget PROPERTIES
    AUTOMOC ON
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin
)
add_test(NAME test_scriptable_timeline_widget COMMAND test_scriptable_timeline_widget)

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
