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

# Find or build LuaJIT
find_package(PkgConfig REQUIRED)
pkg_check_modules(LUAJIT REQUIRED luajit)

# Compiler flags
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wall -Wextra -Wpedantic")
set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} -g -O0 -DDEBUG")
set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} -O3 -DNDEBUG")

# Include directories
include_directories(
    ${CMAKE_SOURCE_DIR}/src
    ${LUAJIT_INCLUDE_DIRS}
)

# Source files organization
set(CORE_SOURCES
    src/core/models/project.cpp
    src/core/models/sequence.cpp
    src/core/models/track.cpp
    src/core/models/clip.cpp
    src/core/models/media.cpp
    src/core/models/property.cpp
    src/core/models/command.cpp
    src/core/models/snapshot.cpp
    src/core/models/validation.cpp
    
    src/core/commands/dispatcher.cpp
    src/core/commands/registry.cpp
    src/core/commands/replay.cpp
    src/core/commands/create_clip.cpp
    src/core/commands/delete_clip.cpp
    src/core/commands/split_clip.cpp
    src/core/commands/ripple_delete.cpp
    src/core/commands/ripple_trim.cpp
    src/core/commands/roll_edit.cpp
    src/core/commands/undo_manager.cpp
    src/core/commands/property_undo.cpp
    
    src/core/persistence/atomic_save.cpp
    src/core/persistence/project_loader.cpp
    src/core/persistence/command_log.cpp
    src/core/persistence/migrations.cpp
)

set(UI_SOURCES
    src/ui/main_window.cpp
    src/ui/theme/dark_theme.cpp
    
    src/ui/panels/project_browser.cpp
    src/ui/panels/timeline.cpp
    src/ui/panels/inspector.cpp
    src/ui/panels/viewer.cpp
    src/ui/panels/inspector_binding.cpp
    
    src/ui/selection/selection_manager.cpp
    src/ui/selection/multi_selection.cpp
    
    src/ui/timeline/edge_selection.cpp
    src/ui/timeline/playhead_controller.cpp
    src/ui/timeline/renderer.cpp
    
    src/ui/input/shortcuts.cpp
)

set(LUA_SOURCES
    src/lua/runtime/lua_runtime.cpp
    src/lua/api/bindings.cpp
)

set(CLI_SOURCES
    src/cli/jve_validate.cpp
    src/cli/jve_dump.cpp
    src/cli/jve_replay.cpp
    src/cli/main.cpp
)

# Core library (for testing and CLI tools)
add_library(JVECore STATIC 
    ${CORE_SOURCES} 
    ${LUA_SOURCES}
)

target_link_libraries(JVECore
    Qt6::Core
    Qt6::Sql
    SQLite::SQLite3
    ${LUAJIT_LIBRARIES}
)

target_include_directories(JVECore PUBLIC
    ${CMAKE_SOURCE_DIR}/src
)

# UI library
add_library(JVEUI STATIC 
    ${UI_SOURCES}
)

target_link_libraries(JVEUI
    JVECore
    Qt6::Core
    Qt6::Widgets
    Qt6::Gui
)

# Main application
add_executable(jve-editor
    src/main.cpp
)

target_link_libraries(jve-editor
    JVECore
    JVEUI
    Qt6::Core
    Qt6::Widgets
    Qt6::Gui
)

# CLI tools
add_executable(jve-cli
    ${CLI_SOURCES}
)

target_link_libraries(jve-cli
    JVECore
    Qt6::Core
)

# Testing
enable_testing()

# Contract tests
file(GLOB CONTRACT_TEST_SOURCES tests/contract/*.cpp)
foreach(test_source ${CONTRACT_TEST_SOURCES})
    get_filename_component(test_name ${test_source} NAME_WE)
    add_executable(${test_name} ${test_source})
    target_link_libraries(${test_name}
        JVECore
        Qt6::Test
        Qt6::Core
    )
    add_test(NAME ${test_name} COMMAND ${test_name})
endforeach()

# Integration tests
file(GLOB INTEGRATION_TEST_SOURCES tests/integration/*.cpp)
foreach(test_source ${INTEGRATION_TEST_SOURCES})
    get_filename_component(test_name ${test_source} NAME_WE)
    add_executable(${test_name} ${test_source})
    target_link_libraries(${test_name}
        JVECore
        JVEUI
        Qt6::Test
        Qt6::Core
        Qt6::Widgets
    )
    add_test(NAME ${test_name} COMMAND ${test_name})
endforeach()

# Unit tests
file(GLOB UNIT_TEST_SOURCES tests/unit/*.cpp)
foreach(test_source ${UNIT_TEST_SOURCES})
    get_filename_component(test_name ${test_source} NAME_WE)
    add_executable(${test_name} ${test_source})
    target_link_libraries(${test_name}
        JVECore
        Qt6::Test
        Qt6::Core
    )
    add_test(NAME ${test_name} COMMAND ${test_name})
endforeach()

# Installation
install(TARGETS jve-editor jve-cli
    RUNTIME DESTINATION bin
)

install(FILES ${CMAKE_SOURCE_DIR}/src/lua/scripts/panel_behaviors.lua
    DESTINATION share/jve-editor/scripts
)

# Package configuration
set(CPACK_PACKAGE_NAME "JVE-Editor")
set(CPACK_PACKAGE_VERSION_MAJOR ${PROJECT_VERSION_MAJOR})
set(CPACK_PACKAGE_VERSION_MINOR ${PROJECT_VERSION_MINOR})
set(CPACK_PACKAGE_VERSION_PATCH ${PROJECT_VERSION_PATCH})
set(CPACK_PACKAGE_DESCRIPTION_SUMMARY ${PROJECT_DESCRIPTION})

include(CPack)