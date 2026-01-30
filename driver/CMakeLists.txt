cmake_minimum_required(VERSION 3.16)

project(PCPanelAudio CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Compiler flags
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wall -Wextra -Wno-invalid-offsetof -Wno-unused-parameter")

# Find macOS SDK
if(CMAKE_OSX_SYSROOT STREQUAL "")
    # Try to find SDK
    execute_process(
        COMMAND xcrun --sdk macosx --show-sdk-path
        OUTPUT_VARIABLE DETECTED_SDK_PATH
        OUTPUT_STRIP_TRAILING_WHITESPACE
    )
    if(EXISTS "${DETECTED_SDK_PATH}")
        set(CMAKE_OSX_SYSROOT "${DETECTED_SDK_PATH}")
        message(STATUS "Using macOS SDK: ${CMAKE_OSX_SYSROOT}")
    endif()
endif()

# libASPL source directory
set(LIBASPL_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../libASPL)

# libASPL sources (including pre-generated files)
set(LIBASPL_SOURCES
    ${LIBASPL_DIR}/src/Client.cpp
    ${LIBASPL_DIR}/src/Convert.cpp
    ${LIBASPL_DIR}/src/Dispatcher.cpp
    ${LIBASPL_DIR}/src/Driver.cpp
    ${LIBASPL_DIR}/src/Storage.cpp
    ${LIBASPL_DIR}/src/Strings.cpp
    ${LIBASPL_DIR}/src/Tracer.cpp
    ${LIBASPL_DIR}/src/Uid.cpp
    ${LIBASPL_DIR}/src/VolumeCurve.cpp
    ${LIBASPL_DIR}/src/Device.cpp
    ${LIBASPL_DIR}/src/Device.g.cpp
    ${LIBASPL_DIR}/src/MuteControl.cpp
    ${LIBASPL_DIR}/src/MuteControl.g.cpp
    ${LIBASPL_DIR}/src/Object.cpp
    ${LIBASPL_DIR}/src/Object.g.cpp
    ${LIBASPL_DIR}/src/Plugin.cpp
    ${LIBASPL_DIR}/src/Plugin.g.cpp
    ${LIBASPL_DIR}/src/Stream.cpp
    ${LIBASPL_DIR}/src/Stream.g.cpp
    ${LIBASPL_DIR}/src/VolumeControl.cpp
    ${LIBASPL_DIR}/src/VolumeControl.g.cpp
    ${LIBASPL_DIR}/src/Bridge.g.cpp
    ${LIBASPL_DIR}/src/Strings.g.cpp
)

# Build libASPL as a static library
add_library(ASPL STATIC ${LIBASPL_SOURCES})

target_include_directories(ASPL PUBLIC
    ${LIBASPL_DIR}/include
)

find_library(LIB_CoreFoundation CoreFoundation REQUIRED)
target_link_libraries(ASPL PUBLIC ${LIB_CoreFoundation})

# Driver bundle
set(DRIVER_NAME PCPanelAudio)
set(DRIVER_BUNDLE_ID com.pcpanel.audio.driver)

add_library(${DRIVER_NAME} MODULE
    src/Driver.cpp
)

target_include_directories(${DRIVER_NAME} PRIVATE
    ${LIBASPL_DIR}/include
)

target_link_libraries(${DRIVER_NAME}
    ASPL
    "-framework CoreFoundation"
    "-framework CoreAudio"
)

# Configure as a bundle (.driver)
set_target_properties(${DRIVER_NAME} PROPERTIES
    BUNDLE TRUE
    BUNDLE_EXTENSION "driver"
    MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in
    MACOSX_BUNDLE_BUNDLE_NAME ${DRIVER_NAME}
    MACOSX_BUNDLE_BUNDLE_VERSION "1.0.0"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "1.0.0"
    MACOSX_BUNDLE_GUI_IDENTIFIER ${DRIVER_BUNDLE_ID}
)

# Custom target to install the driver
add_custom_target(install-driver
    COMMAND ${CMAKE_COMMAND} -E echo "Installing driver to /Library/Audio/Plug-Ins/HAL/"
    COMMAND sudo cp -r ${CMAKE_CURRENT_BINARY_DIR}/${DRIVER_NAME}.driver /Library/Audio/Plug-Ins/HAL/
    COMMAND sudo launchctl kickstart -k system/com.apple.audio.coreaudiod
    DEPENDS ${DRIVER_NAME}
    COMMENT "Installing PCPanelAudio driver and restarting coreaudiod"
)
