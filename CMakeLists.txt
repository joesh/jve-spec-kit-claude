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
    src/core/commands/command_dispatcher.cpp
    
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
    src/ui/selection/selection_manager.cpp
    src/ui/timeline/timeline_panel.cpp
    src/ui/timeline/scriptable_timeline.cpp
    # src/ui/inspector/inspector_panel.cpp  # Deprecated
    # src/ui/media/media_browser_panel.cpp  # Missing
    # src/ui/project/project_panel.cpp  # Missing
    # src/ui/main/main_window.cpp  # Missing
    src/ui/input/keyboard_shortcuts.cpp
    src/ui/common/context_menu_manager.cpp
    src/ui/common/ui_command_bridge.cpp
    src/ui/common/selection_visualizer.cpp
    src/ui/common/drag_drop_manager.cpp
    src/ui/common/ui_state_manager.cpp
    src/ui/common/theme_manager.cpp
    src/ui/common/performance_monitor.cpp
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

# Test for scriptable timeline
add_executable(test_scriptable_timeline
    test_scriptable_timeline.cpp
)

target_link_libraries(test_scriptable_timeline
    JVECore
    Qt6::Core
    Qt6::Widgets
    Qt6::Gui
)

set_target_properties(test_scriptable_timeline PROPERTIES
    AUTOMOC ON
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin
)

target_include_directories(test_scriptable_timeline PUBLIC
    ${CMAKE_SOURCE_DIR}/src
)

# Testing
enable_testing()

# Enable automatic MOC, UIC and RCC processing
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTOUIC ON)
set(CMAKE_AUTORCC ON)

# Contract tests
file(GLOB CONTRACT_TEST_SOURCES tests/contract/*.cpp)
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
    )
    add_test(NAME ${test_name} COMMAND ${test_name})
endforeach()

# Integration tests (require UI library - not yet available)
# file(GLOB INTEGRATION_TEST_SOURCES tests/integration/*.cpp)

# Unit tests
file(GLOB UNIT_TEST_SOURCES tests/unit/*.cpp)
foreach(test_source ${UNIT_TEST_SOURCES})
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
    )
    add_test(NAME ${test_name} COMMAND ${test_name})
endforeach()

# Installation (not applicable for M1 Foundation tests)

# Package configuration
set(CPACK_PACKAGE_NAME "JVE-Editor")
set(CPACK_PACKAGE_VERSION_MAJOR ${PROJECT_VERSION_MAJOR})
set(CPACK_PACKAGE_VERSION_MINOR ${PROJECT_VERSION_MINOR})
set(CPACK_PACKAGE_VERSION_PATCH ${PROJECT_VERSION_PATCH})
set(CPACK_PACKAGE_DESCRIPTION_SUMMARY ${PROJECT_DESCRIPTION})

include(CPack)