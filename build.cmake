#!/usr/bin/env -S cmake -P

# Run from source dir by doing `cmake -P build.cmake`
#
# This cross-platform script automates the process of creating a build directory and
# compiling Inkscape. Despite being written in the CMake language, you should think
# of this file as like a shell script or batch file rather than as part of the CMake
# project tree. As always, the project tree starts in the top-level CMakeLists.txt.

# This script is *inspired* on MuseScore's build.cmake script
# (GNU GPL v3) -> Licensing issues?

# TODO:
# - Require XCode, Xcode command line tools and HomeBrew in MacOS
# - Check for any other dependencies

#####################################
# SETUP WORK                        #
#####################################

string(STIMESTAMP SCRIPT_START_TIMESTAMP "%s" UTC)

if(NOT DEFINED CMAKE_SCRIPT_MODE_FILE)
    file(RELATIVE_PATH SCRIPT_PATH "${CMAKE_BINARY_DIR}" "${CMAKE_CURRENT_LIST_FILE}")
    message(FATAL_ERROR
        "This file is a script. You should run it with:\n"
        "  \$ cmake -P ${SCRIPT_PATH} [args...]\n"
        "Don't try to use it in other CMake files with include().\n"
        "See https://cmake.org/cmake/help/latest/manual/cmake.1.html#run-a-script"
    )
endif()

cmake_minimum_required(VERSION 3.24.0) # should match version in CMakeLists.txt

# CMake arguments up to '-P' (ignore these)
set(i "1")
while(i LESS "${CMAKE_ARGC}")
    if("${CMAKE_ARGV${i}}" STREQUAL "-P")
        math(EXPR i "${i} + 1") # ignore '-P' option
        break() # done with CMake arguments
    endif()
    math(EXPR i "${i} + 1") # next argument
endwhile()

# Script arguments (store these for later processing)
# By convention, SCRIPT_ARG[0] is the name of the script
set(SCRIPT_ARGS "") # empty argument list
while(i LESS "${CMAKE_ARGC}")
    list(APPEND SCRIPT_ARGS "${CMAKE_ARGV${i}}")
    math(EXPR i "${i} + 1") # next argument
endwhile()

# load custom CMake functions and macros
include("${CMAKE_CURRENT_LIST_DIR}/CMakeScripts/GetUtilsFunctions.cmake") # "fn__" namespace


# Set the name of the build folder (just the folder name, not the full path)
function(build_folder
    VAR_NAME # Name of variable to store build folder name
)
    # Windows has a 260 character limit on file paths, so the build folder
    # name must be abbreviated to prevent build files exceeding this limit.
    # The limit applies to the *entire* path, not just individual components.
    # Abbreviation is not essential on other platforms but is still welcome.
    if(WIN32)
        set(PLATFORM "Win")
    elseif(APPLE)
        set(PLATFORM "Mac")
    else()
        set(PLATFORM "${CMAKE_HOST_SYSTEM_NAME}")
    endif()
    set(GEN_SHORT "${GENERATOR}")
    string(REGEX REPLACE ".*Visual Studio ([0-9]+).*" "VS\\1" GEN_SHORT "${GEN_SHORT}")
    string(REGEX REPLACE ".*MinGW.*" "MinGW" GEN_SHORT "${GEN_SHORT}")
    string(REGEX REPLACE ".*Makefile.*" "Make" GEN_SHORT "${GEN_SHORT}")
    set(BUILD_FOLDER "${PLATFORM}-${GEN_SHORT}-${BUILD_TYPE}")
    string(REGEX REPLACE "[ /\\]" "" BUILD_FOLDER "${BUILD_FOLDER}") # remove spaces and slashes
    set("${VAR_NAME}" "${BUILD_FOLDER}" PARENT_SCOPE)
endfunction()

# Default values for independent build variables
set(SOURCE_PATH "${CMAKE_CURRENT_LIST_DIR}") # Directory of this script
set(ALL_BUILDS_PATH "${SOURCE_PATH}/builds") # Where all build folders will be created

# CPUS
cmake_host_system_information(RESULT CPUS QUERY NUMBER_OF_LOGICAL_CORES)
if(NOT "${CPUS}" GREATER "0")
    include(ProcessorCount)
    ProcessorCount(CPUS)
endif()

# Overrides
# Use this file to replace build variable defaults with your own values.
# E.g. set your own GENERATOR, BUILD_TYPE, BUILD_FOLDER, or CPUS.
if(EXISTS "${SOURCE_PATH}/build_overrides.cmake")
    message(STATUS "Including personal build overrides")
    include("${SOURCE_PATH}/build_overrides.cmake")
endif()


# Process script arguments
set(i "1")
list(LENGTH SCRIPT_ARGS nargs)
while(i LESS "${nargs}")
    list(GET SCRIPT_ARGS "${i}" ARG)
    if("${ARG}" STREQUAL "clean")
        set(ARG_CLEAN "TRUE")
    elseif("${ARG}" STREQUAL "configure")
        set(ARG_CONFIGURE "TRUE")
    elseif("${ARG}" STREQUAL "build")
        set(ARG_CONFIGURE "TRUE")
        set(ARG_BUILD "TRUE")
    elseif("${ARG}" STREQUAL "install")
        set(ARG_CONFIGURE "TRUE")
        set(ARG_BUILD "TRUE")
        set(ARG_INSTALL "TRUE")
    elseif("${ARG}" STREQUAL "run")
        set(ARG_RUN "TRUE")
    else()
        # Other arguments are used by certain subprocesses in build steps
        if(ARG_RUN)
            list(APPEND RUN_ARGS "${ARG}") # args after "run" belong to Run step
        else()
            list(APPEND CONFIGURE_ARGS "${ARG}") # all other args belong to Configure step
        endif()
    endif()
    math(EXPR i "${i} + 1") # next argument
endwhile()

# Default if no build steps given as arguments
if(NOT (ARG_CLEAN OR ARG_CONFIGURE OR ARG_BUILD OR ARG_INSTALL OR ARG_RUN))
    set(ARG_CONFIGURE "TRUE")
    set(ARG_BUILD "TRUE")
    set(ARG_INSTALL "TRUE")
endif()

# Default values for build variables that depend on other build variables.
# These will only be set here if they were not already defined elsewhere,
# e.g. by script arguments or in build_overrides.cmake.

fn__get_option(GENERATOR -G ${CONFIGURE_ARGS})
fn__set_default(GENERATOR "Ninja")

fn__get_option(BUILD_TYPE -DCMAKE_BUILD_TYPE ${CONFIGURE_ARGS})
fn__set_default(BUILD_TYPE "Debug")

if(NOT DEFINED BUILD_FOLDER)
    build_folder(BUILD_FOLDER)
endif()
set(BUILD_PATH "${ALL_BUILDS_PATH}/${BUILD_FOLDER}")

fn__get_option(INSTALL_PATH -DCMAKE_INSTALL_PREFIX ${CONFIGURE_ARGS})
fn__set_default(INSTALL_PATH "install") # relative to BUILD_PATH

# APP_EXECUTABLE (path relative to INSTALL_PATH)
if(WIN32)
    fn__set_default(APP_EXECUTABLE "bin/inkscape.exe")
elseif(APPLE)
    fn__set_default(APP_EXECUTABLE "ae.app/Contents/MacOS/...") # TODO ???
else()
    fn__set_default(APP_EXECUTABLE "bin/inkscape")
endif()

# make paths absolute if they are not already
get_filename_component(BUILD_PATH "${BUILD_PATH}" ABSOLUTE BASE_DIR "${SOURCE_PATH}")
get_filename_component(INSTALL_PATH "${INSTALL_PATH}" ABSOLUTE BASE_DIR "${BUILD_PATH}")
get_filename_component(APP_EXECUTABLE "${APP_EXECUTABLE}" ABSOLUTE BASE_DIR "${INSTALL_PATH}")

message(STATUS "SOURCE_PATH:       ${SOURCE_PATH}")
message(STATUS "BUILD_PATH:        ${BUILD_PATH}")
message(STATUS "INSTALL_PATH:      ${INSTALL_PATH}")
message(STATUS "APP_EXECUTABLE:    ${APP_EXECUTABLE}")
message(STATUS "CPUS: ${CPUS}")
message(STATUS "GENERATOR: ${GENERATOR}")
message(STATUS "BUILD_TYPE: ${BUILD_TYPE}")

list(APPEND CONFIGURE_ARGS "-G" "${GENERATOR}")
list(APPEND CONFIGURE_ARGS "-DCMAKE_INSTALL_PREFIX=${INSTALL_PATH}")
list(APPEND CONFIGURE_ARGS "-DCMAKE_BUILD_TYPE=${BUILD_TYPE}")
list(APPEND CONFIGURE_ARGS "-DBUILD_SHARED_LIBS=OFF")
list(APPEND CONFIGURE_ARGS "-DWITH_INTERNAL_2GEOM=ON")
list(APPEND CONFIGURE_ARGS "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON")

############################
# ACTUAL BUILD STARTS HERE #
############################

# Dependencies - gets required dependencies per-platform
# We only ever do this once. What's done here is based on
# Inkscape's dev documentation.
if(ARG_DEPS)
    if (WIN32)
        # Download Inkscape dependencies
        # Windows instructions: https://gitlab.com/inkscape/inkscape/-/blob/master/doc/building/windows.md
        file(DOWNLOAD
             "https://gitlab.com/inkscape/inkscape/-/archive/master/inkscape-master.zip?path=buildtools"
             "inkscape-master.zip"
             STATUS DOWNLOAD_SUCCESS
        )
        if (NOT DOWNLOAD_SUCCESS)
            message(ERROR "Couldn't download Inkscape dependencies")
        endif()

        # Extract file
        file(ARCHIVE
             "UNZIP"
             "inkscape-master.zip"
             "inkscape-master"
             STATUS UNZIP_SUCCESS
        )
        if (NOT UNZIP_SUCCESS)
            message(ERROR "Couldn't extract Inkscape dependencies")
        endif()

        # Finally, run batch script to get the deps
        execute_process(
            COMMAND "inkscape-master/inkscape-master-buildtools/buildtools/windows-deps-clickHere.bat"
            RESULT_VARIABLE DEPS_RES_CODE
        )

        if (DEPS_RES_CODE NOT EQUAL 0)
            message(ERROR "Fetching inkscape dependencies failed with code ${DEPS_RES_CODE}"
                          "See output above for details.")
        endif()
    elseif (UNIX AND APPLE)
        # MacOS instructions: https://gitlab.com/inkscape/inkscape/-/blob/master/doc/building/mac.md
        execute_process(
            COMMAND "brew install
                     adwaita-icon-theme
                     bdw-gc
                     boost
                     cairomm
                     ccache
                     cmake
                     double-conversion
                     gettext
                     gsl
                     gtkmm4
                     gtksourceview5
                     icu4c
                     imagemagick
                     intltool
                     lcms2
                     libxslt
                     ninja
                     pkg-config
                     poppler
                     potrace"
        )
    elseif (UNIX AND NOT APPLE)
        # Linux instructions: https://gitlab.com/inkscape/inkscape/-/blob/master/doc/building/linux.md
        file(DOWNLOAD
             "https://gitlab.com/inkscape/inkscape-ci-docker/-/raw/master/install_dependencies.sh"
             "install_dependencies.sh"
             STATUS DOWNLOAD_SUCCESS
        )
        if (NOT DOWNLOAD_SUCCESS)
            message(ERROR "Couldn't download Inkscape dependencies")
        endif()

        execute_process(
            COMMAND "bash install_dependencies.sh --recommended"
            RESULT_VARIABLE DEPS_RES_CODE
        )
        if (DEPS_RES_CODE NOT EQUAL 0)
            message(ERROR "Fetching inkscape dependencies failed with code ${DEPS_RES_CODE}"
                          "See output above for details.")
        endif()
    else()
        message(ERROR "Machine type not supported by this buildscript yet")
    endif()

    message(STATUS "Got Inkscape dependencies succesfully!")
endif() 

# Clean - delete an existing build directory.
#
# We usually avoid this because performing a clean build takes much longer
# than an incremental build, but it is occasionally necessary. If you
# encounter errors during a build then you should try doing a clean build.

if(ARG_CLEAN)
    message("\n~~~~ Actualizing Clean step ~~~~\n")
    message("Deleting ${BUILD_PATH}")
    file(REMOVE_RECURSE "${BUILD_PATH}")
endif()


# Configure - generate build system for the native build tool.
#
# We only do this explicitly on the very first build. On subsequent builds
# the native build tool will redo the configuration if any CMake files were
# edited. You can force this to happen by deleting CMakeCache.txt.

if(ARG_CONFIGURE AND NOT EXISTS "${BUILD_PATH}/CMakeCache.txt")
    message("\n~~~~ Actualizing Configure step ~~~~\n")
    file(MAKE_DIRECTORY "${BUILD_PATH}")
    fn__command_string(ARGS_STR ${CONFIGURE_ARGS})
    message("CONFIGURE_ARGS: ${ARGS_STR}")
    execute_process(
        # List of CMake arguments in CONFIGURE_ARGS variable. It must be unquoted here.
        COMMAND cmake -S "${SOURCE_PATH}" -B . ${CONFIGURE_ARGS}
        WORKING_DIRECTORY "${BUILD_PATH}"
        RESULT_VARIABLE EXIT_STATUS
    )
    if(NOT "${EXIT_STATUS}" EQUAL "0")
        file(REMOVE "${BUILD_PATH}/CMakeCache.txt") # need to configure again next time
        message(FATAL_ERROR "Configure step failed with status ${EXIT_STATUS}. See output above for details.")
    endif()
endif()

# Build - compile code with the native build tool.
#
# We always do this. We can rely on the native build tool to be efficient and
# only (re)compile source files that have been edited since the last build.

if(ARG_BUILD)
    message("\n~~~~ Actualizing Build step ~~~~\n")
    execute_process(
        COMMAND cmake --build . --config "${BUILD_TYPE}" --parallel "${CPUS}"
        WORKING_DIRECTORY "${BUILD_PATH}"
        RESULT_VARIABLE EXIT_STATUS
    )
    if(NOT "${EXIT_STATUS}" EQUAL "0")
        message(FATAL_ERROR "Build step failed with status ${EXIT_STATUS}. See output above for details.")
    endif()
endif()

# Install - move compiled files to destination folders.
#
# Again, we always do this and rely on the tool itself to be efficient and
# only install files that have changed since last time.

if(ARG_INSTALL)
    message("\n~~~~ Actualizing Install step ~~~~\n")
    execute_process(
        COMMAND cmake --install . --config "${BUILD_TYPE}"
        WORKING_DIRECTORY "${BUILD_PATH}"
        RESULT_VARIABLE EXIT_STATUS
    )
    if(NOT "${EXIT_STATUS}" EQUAL "0")
        message(FATAL_ERROR "Install step failed with status ${EXIT_STATUS}. See output above for details.")
    endif()
endif()

# Run - attempt to run the compiled program within the installation folder.
#
# The working directory is unchanged. Use build_override.cmake to set the
# CMake variable RUN_ARGS to contain a list of arguments to pass to executable
# on the command line. In addition, script arguments after "run" will be
# appended to this list, but note that certain arguments cannot be passed this
# way (e.g. --help, --version) because they cancel CMake script processing.

if(ARG_RUN)
    message("\n~~~~ Actualizing Run step ~~~~\n")
    if(WIN32)
        set(CMD "cmd.exe" "/c") # allow CMake to launch a GUI application
    else()
        set(CMD "") # not an issue on other platforms
    endif()
    fn__command_string(ARGS_STR ${RUN_ARGS})
    message("RUN_ARGS: ${ARGS_STR}")
    execute_process(
        # List of arguments in RUN_ARGS variable. It must be unquoted here.
        COMMAND ${CMD} "${APP_EXECUTABLE}" ${RUN_ARGS}
        RESULT_VARIABLE EXIT_STATUS
    )
    if(NOT "${EXIT_STATUS}" EQUAL "0")
        message(FATAL_ERROR "Run step failed with status ${EXIT_STATUS}. See output above for details.")
    endif()
endif()

# Package - create installer archive for distribution to end users.
# TODO

string(TIMESTAMP SCRIPT_END_TIMESTAMP "%s" UTC)
math(EXPR SCRIPT_ELAPSED_TIME "${SCRIPT_END_TIMESTAMP} - ${SCRIPT_START_TIMESTAMP}")
math(EXPR SCRIPT_ELAPSED_MINS "${SCRIPT_ELAPSED_TIME} / 60")
math(EXPR SCRIPT_ELAPSED_SECS "${SCRIPT_ELAPSED_TIME} % 60")
list(GET SCRIPT_ARGS "0" SCRIPT_NAME)
message("\n${SCRIPT_NAME}: Complete after ${SCRIPT_ELAPSED_MINS} minutes and ${SCRIPT_ELAPSED_SECS} seconds")
