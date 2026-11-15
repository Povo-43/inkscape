# FindIntl.cmake - Cross-compile friendly version for Android
# This provides Intl::Intl target using our intl library

# Check if already found
if(Intl_FOUND)
  return()
endif()

# Try to find via pkg-config first (works with our custom .pc files)
find_package(PkgConfig QUIET)
if(PKG_CONFIG_FOUND)
  pkg_check_modules(PC_INTL QUIET intl)
  if(PC_INTL_FOUND)
    set(Intl_FOUND TRUE)
    add_library(Intl::Intl INTERFACE IMPORTED)
    set_target_properties(Intl::Intl PROPERTIES
      INTERFACE_INCLUDE_DIRECTORIES "${PC_INTL_INCLUDE_DIRS}"
      INTERFACE_LINK_LIBRARIES "${PC_INTL_LIBRARIES}"
      INTERFACE_COMPILE_OPTIONS "${PC_INTL_CFLAGS_OTHER}"
    )
    mark_as_advanced(Intl_INCLUDE_DIR Intl_LIBRARY)
    return()
  endif()
endif()

# Fallback: Find the intl library directly
set(INTL_NAMES intl)
find_library(Intl_LIBRARY
  NAMES ${INTL_NAMES}
  HINTS ${CMAKE_INSTALL_PREFIX}/lib
        ${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib
  PATH_SUFFIXES aarch64-linux-android x86_64-linux-android
)

# Find the include directory
find_path(Intl_INCLUDE_DIR libintl.h
  HINTS ${CMAKE_INSTALL_PREFIX}/include
        ${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include
)

if(Intl_LIBRARY AND Intl_INCLUDE_DIR)
  set(Intl_FOUND TRUE)
  add_library(Intl::Intl INTERFACE IMPORTED)
  set_target_properties(Intl::Intl PROPERTIES
    INTERFACE_INCLUDE_DIRECTORIES "${Intl_INCLUDE_DIR}"
    INTERFACE_LINK_LIBRARIES "${Intl_LIBRARY}"
  )
  mark_as_advanced(Intl_LIBRARY Intl_INCLUDE_DIR)
else()
  if(Intl_FIND_REQUIRED)
    message(FATAL_ERROR "Could not find Intl (libintl)")
  endif()
  set(Intl_FOUND FALSE)
endif()

mark_as_advanced(Intl_INCLUDE_DIR Intl_LIBRARY)