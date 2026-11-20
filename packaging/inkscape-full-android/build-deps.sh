#!/bin/bash
set -euo pipefail

# =========================================================
# Inkscape Android 依存ライブラリクロスコンパイルスクリプト
# 最小限の依存のみビルドし、Inkscape CMake で残りをビルドさせる
#
# 使用方法: bash build-deps.sh <install_dir> <android_ndk> <api> [pixiewood_dir]
# =========================================================

echo "DEBUG: build-deps.sh started with args: $@"
echo "DEBUG: INSTALL_DIR will be ${1:-/tmp/inkscape-deps-install}"

INSTALL_DIR=${1:-/tmp/inkscape-deps-install}
NDK_HOME=${2:-/opt/android-ndk-r27b}
API=${3:-31}
PIXIEWOOD_DIR=${4:-}

# ターゲットアーキテクチャ（デフォルト: arm64）
TARGET_ARCH=${TARGET_ARCH:-aarch64}
if [ "$TARGET_ARCH" = "aarch64" ]; then
    TRIPLE=aarch64-linux-android
elif [ "$TARGET_ARCH" = "x86_64" ]; then
    TRIPLE=x86_64-linux-android
fi

CC=$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/${TRIPLE}${API}-clang
CXX=$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/${TRIPLE}${API}-clang++
AR=$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-ar
STRIP=$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip
JOBS=$(nproc)

BUILD_DIR=$(mktemp -d)
SRC_DIR=$(mktemp -d)
mkdir -p $INSTALL_DIR/lib/pkgconfig $INSTALL_DIR/include

# Fix PIXIEWOOD paths - headers are in root/, libs are in bin-ARCH/
# PIXIEWOOD_DIR is the build directory (e.g., gtk4-stack-download/.pixiewood/bin-aarch64)
# PIXIEWOOD_ROOT is the install directory (e.g., gtk4-stack-download/.pixiewood/root)
# PIXIEWOOD_SOURCE_DIR is the source directory from downloaded artifact
# The artifact is downloaded with flat structure at gtk4-stack-download/ with subprojects/ at root
PIXIEWOOD_ROOT="${PIXIEWOOD_DIR%/bin-aarch64}/root"
PIXIEWOOD_LIB="${PIXIEWOOD_DIR}"
PIXIEWOOD_SOURCE_DIR="${GITHUB_WORKSPACE}/gtk4-stack-download"

# If no PIXIEWOOD_DIR provided, fall back to workspace paths
if [ -z "$PIXIEWOOD_DIR" ]; then
    PIXIEWOOD_ROOT="${GITHUB_WORKSPACE}/.pixiewood/root"
    PIXIEWOOD_DIR="${GITHUB_WORKSPACE}/.pixiewood/bin-aarch64"
    # The source directory is at the pixiewood root in the downloaded artifact
    PIXIEWOOD_SOURCE_DIR="${GITHUB_WORKSPACE}/gtk4-stack-download"
fi

# Global PKG_CONFIG_PATH for all builds - IMPORTANT: INSTALL_DIR FIRST so our .pc files take precedence
export PKG_CONFIG_PATH="${INSTALL_DIR}/lib/pkgconfig:${PIXIEWOOD_DIR}/meson-private:${PIXIEWOOD_DIR}"
# PKG_CONFIG_LIBDIR tells pkg-config to ONLY look in cross-compile directories - IMPORTANT: INSTALL_DIR FIRST
export PKG_CONFIG_LIBDIR="${INSTALL_DIR}/lib/pkgconfig:${PIXIEWOOD_DIR}/meson-private:${PIXIEWOOD_DIR}"

# Do NOT copy pixiewood pkg-config files - they have wrong paths
# We create all required .pc files ourselves with correct paths
echo "--- Skipping pixiewood pkg-config files (will create our own) ---"

# If no .pc files were found, create minimal .pc files for critical dependencies
# This is needed because pixiewood may not install .pc files
if [ ! -f "$INSTALL_DIR/lib/pkgconfig/glib-2.0.pc" ]; then
    echo "--- Creating minimal .pc files for cross-compile dependencies ---"
    
    # Get library paths from pixiewood build output
    PIXIEWOOD_LIB="$PIXIEWOOD_DIR"
    
    # Find actual library locations
    GLIB_LIB=$(find "$PIXIEWOOD_DIR" -name "libglib-2.0.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_LIB")
    # glib headers are copied to INSTALL_DIR/include/glib-2.0/
    GLIB_INCLUDE="${INSTALL_DIR}/include"
    
    cat > "$INSTALL_DIR/lib/pkgconfig/glib-2.0.pc" << PCEOF
prefix=$INSTALL_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: GLib
Description: Core application library
Version: 2.90.0
Requires:
Libs: -L${GLIB_LIB} -lglib-2.0
Cflags: -I${GLIB_INCLUDE}/glib-2.0 -I${GLIB_INCLUDE}/glib-2.0/include
PCEOF
    

    # Copy Freetype headers - use system headers as primary source (standard for cross-compile)
    # The pixiewood build directory only has generated config headers, not the main freetype headers
    # Use system freetype2 headers for compilation, link against pixiewood-built library
    echo "--- Copying Freetype headers (using system headers for cross-compile) ---"
    if [ -d "/usr/include/freetype2" ]; then
        echo "--- Copying Freetype headers from system (for cross-compile) ---"
        mkdir -p "${INSTALL_DIR}/include/freetype2"
        cp -r /usr/include/freetype2/* "${INSTALL_DIR}/include/freetype2/" 2>/dev/null || true
        echo "Copied system freetype2 headers"
    else
        echo "Warning: system freetype2 headers not found"
    fi

    # Also copy generated config headers from pixiewood build directory
    echo "--- Copying generated Freetype config headers from pixiewood build directory ---"
    mkdir -p "${INSTALL_DIR}/include/freetype2"
    if [ -f "${PIXIEWOOD_DIR}/subprojects/freetype/ftconfig.h" ]; then
        cp -f "${PIXIEWOOD_DIR}/subprojects/freetype/ftconfig.h" "${INSTALL_DIR}/include/freetype2/" 2>/dev/null || true
    fi
    if [ -f "${PIXIEWOOD_DIR}/subprojects/freetype/ftmodule.h" ]; then
        cp -f "${PIXIEWOOD_DIR}/subprojects/freetype/ftmodule.h" "${INSTALL_DIR}/include/freetype2/" 2>/dev/null || true
    fi
    if [ -f "${PIXIEWOOD_DIR}/subprojects/freetype/ftoption.h" ]; then
        cp -f "${PIXIEWOOD_DIR}/subprojects/freetype/ftoption.h" "${INSTALL_DIR}/include/freetype2/" 2>/dev/null || true
    fi
    echo "Copied generated Freetype config headers"

    # Create symlink for freetype2 in include (some CMake scripts expect this)
    if [ ! -e "${INSTALL_DIR}/include/freetype2" ] && [ -d "/usr/include/freetype2" ]; then
        mkdir -p "${INSTALL_DIR}/include/freetype2"
        cp -r /usr/include/freetype2/* "${INSTALL_DIR}/include/freetype2/" 2>/dev/null || true
    fi

    # Also copy libpng headers (png.h)
    echo "--- Copying libpng headers ---"
    echo "DEBUG: PIXIEWOOD_SOURCE_DIR=${PIXIEWOOD_SOURCE_DIR}"
    echo "DEBUG: PIXIEWOOD_DIR=${PIXIEWOOD_DIR}"
    echo "DEBUG: Checking libpng source directory..."
    ls -la "${PIXIEWOOD_SOURCE_DIR}/subprojects/libpng-1.6.49/" 2>/dev/null | head -20 || echo "libpng-1.6.49 source not found"
    echo "DEBUG: Checking libpng build directory..."
    ls -la "${PIXIEWOOD_DIR}/subprojects/libpng-1.6.49/" 2>/dev/null | head -20 || echo "libpng-1.6.49 build not found"
    
    # Try to find and copy libpng headers from any available location
    # We need png.h and pngconf.h - these are only in the SOURCE directory, not build dir
    LIBPNG_HEADERS_COPIED=false
    
    # Try source directory first (where png.h and pngconf.h actually are)
    if [ -d "${PIXIEWOOD_SOURCE_DIR}/subprojects/libpng-1.6.49" ] && [ -f "${PIXIEWOOD_SOURCE_DIR}/subprojects/libpng-1.6.49/png.h" ]; then
        echo "--- Copying libpng headers from pixiewood source directory ---"
        mkdir -p "${INSTALL_DIR}/include/libpng16"
        cp -f "${PIXIEWOOD_SOURCE_DIR}/subprojects/libpng-1.6.49/png.h" "${INSTALL_DIR}/include/libpng16/" 2>/dev/null || true
        cp -f "${PIXIEWOOD_SOURCE_DIR}/subprojects/libpng-1.6.49/pngconf.h" "${INSTALL_DIR}/include/libpng16/" 2>/dev/null || true
        cp -f "${PIXIEWOOD_SOURCE_DIR}/subprojects/libpng-1.6.49/pnglibconf.h" "${INSTALL_DIR}/include/libpng16/" 2>/dev/null || true
        LIBPNG_HEADERS_COPIED=true
        echo "Copied libpng headers from pixiewood source directory"
    fi
    
    # Also try build directory for generated pnglibconf.h
    if [ -d "${PIXIEWOOD_DIR}/subprojects/libpng-1.6.49" ] && [ -f "${PIXIEWOOD_DIR}/subprojects/libpng-1.6.49/pnglibconf.h" ]; then
        if [ "$LIBPNG_HEADERS_COPIED" = false ]; then
            echo "--- Copying generated pnglibconf.h from pixiewood build directory ---"
            mkdir -p "${INSTALL_DIR}/include/libpng16"
        else
            echo "--- Also copying generated pnglibconf.h from pixiewood build directory ---"
        fi
        cp -f "${PIXIEWOOD_DIR}/subprojects/libpng-1.6.49/pnglibconf.h" "${INSTALL_DIR}/include/libpng16/" 2>/dev/null || true
        # DO NOT set LIBPNG_HEADERS_COPIED=true here - we only have pnglibconf.h, not png.h/pngconf.h
    fi
    
    # Try install directory
    if [ -d "${PIXIEWOOD_ROOT}/include" ] && [ -f "${PIXIEWOOD_ROOT}/include/png.h" ]; then
        echo "--- Copying libpng headers from pixiewood install directory ---"
        cp -f "${PIXIEWOOD_ROOT}/include/png.h" "${INSTALL_DIR}/include/" 2>/dev/null || true
        cp -f "${PIXIEWOOD_ROOT}/include/pngconf.h" "${INSTALL_DIR}/include/" 2>/dev/null || true
        cp -f "${PIXIEWOOD_ROOT}/include/pnglibconf.h" "${INSTALL_DIR}/include/" 2>/dev/null || true
        LIBPNG_HEADERS_COPIED=true
        echo "Copied libpng headers from pixiewood install directory"
    fi
    
    # If no headers were copied from pixiewood (png.h and pngconf.h not found), fall back to system headers
    if [ "$LIBPNG_HEADERS_COPIED" = false ]; then
        echo "Warning: libpng headers (png.h, pngconf.h) not found in pixiewood, using system headers (fallback)"
        if [ -f "/usr/include/png.h" ]; then
            echo "--- Copying libpng headers from system (fallback) ---"
            mkdir -p "${INSTALL_DIR}/include/libpng16"
            cp -f /usr/include/png.h "${INSTALL_DIR}/include/libpng16/" 2>/dev/null || true
            cp -f /usr/include/pngconf.h "${INSTALL_DIR}/include/libpng16/" 2>/dev/null || true
            # Also copy to standard include path
            cp -f /usr/include/png.h "${INSTALL_DIR}/include/" 2>/dev/null || true
            cp -f /usr/include/pngconf.h "${INSTALL_DIR}/include/" 2>/dev/null || true
            # Create symlink for standard include path
            mkdir -p "${INSTALL_DIR}/include"
            ln -sf libpng16/png.h "${INSTALL_DIR}/include/png.h" 2>/dev/null || true
            ln -sf libpng16/pngconf.h "${INSTALL_DIR}/include/pngconf.h" 2>/dev/null || true
            # pnglibconf.h might not exist on system, generate a minimal one
            if [ ! -f "${INSTALL_DIR}/include/libpng16/pnglibconf.h" ]; then
                cat > "${INSTALL_DIR}/include/libpng16/pnglibconf.h" << 'EOF'
/* pnglibconf.h - Generated for cross-compile fallback */
#ifndef PNGLCONF_H
#define PNGLCONF_H
#define PNG_BUILD_GRAYSCALE_PALETTE_SUPPORTED
#define PNG_MAX_GAMMA_8 11
#define PNG_MAX_GAMMA_16 11
#endif
EOF
            fi
            ln -sf libpng16/pnglibconf.h "${INSTALL_DIR}/include/pnglibconf.h" 2>/dev/null || true
            echo "Copied system libpng headers as fallback"
        fi
    fi
    
    # Create symlinks for standard include path (if headers were copied from pixiewood)
    if [ "$LIBPNG_HEADERS_COPIED" = true ] && [ -f "${INSTALL_DIR}/include/libpng16/png.h" ]; then
        mkdir -p "${INSTALL_DIR}/include"
        ln -sf libpng16/png.h "${INSTALL_DIR}/include/png.h" 2>/dev/null || true
        ln -sf libpng16/pngconf.h "${INSTALL_DIR}/include/pngconf.h" 2>/dev/null || true
        ln -sf libpng16/pnglibconf.h "${INSTALL_DIR}/include/pnglibconf.h" 2>/dev/null || true
    fi
    
    # Create symlink for freetype2 in include (some CMake scripts expect this)
    if [ ! -e "${INSTALL_DIR}/include/freetype2" ] && [ -d "/usr/include/freetype2" ]; then
        mkdir -p "${INSTALL_DIR}/include/freetype2"
        cp -r /usr/include/freetype2/* "${INSTALL_DIR}/include/freetype2/" 2>/dev/null || true
    fi
    
    # Also copy libjpeg-turbo headers (jpeglib.h, jerror.h, etc.)
    echo "--- Copying libjpeg-turbo headers ---"
    LIBJPEG_HEADERS_COPIED=false
    # Try build directory first (has generated jconfig.h in build subdirectory)
    if [ -d "${PIXIEWOOD_DIR}/subprojects/libjpeg-turbo-3.1.1" ]; then
        echo "--- Copying libjpeg-turbo headers from pixiewood build directory ---"
        mkdir -p "${INSTALL_DIR}/include/libjpeg-turbo-3.1.1"
        # Search for jconfig.h in build subdirectories
        find "${PIXIEWOOD_DIR}/subprojects/libjpeg-turbo-3.1.1" -name "jconfig.h" 2>/dev/null | head -1 | while read jconfig; do
            cp -f "$jconfig" "${INSTALL_DIR}/include/libjpeg-turbo-3.1.1/" 2>/dev/null || true
            echo "Copied generated jconfig.h from $(dirname $jconfig)"
        done
        # Check if actual headers exist in build directory
        if [ -f "${PIXIEWOOD_DIR}/subprojects/libjpeg-turbo-3.1.1/jpeglib.h" ]; then
            cp -r "${PIXIEWOOD_DIR}/subprojects/libjpeg-turbo-3.1.1"/*.h "${INSTALL_DIR}/include/libjpeg-turbo-3.1.1/" 2>/dev/null || true
            LIBJPEG_HEADERS_COPIED=true
            echo "Copied libjpeg-turbo headers from pixiewood build directory"
        else
            echo "Warning: libjpeg-turbo headers (jpeglib.h) not found in build directory"
        fi
    fi
    
    # Also check source directory for libjpeg-turbo headers (has jpeglib.h, jerror.h, jmorecfg.h)
    if [ -d "${PIXIEWOOD_SOURCE_DIR}/subprojects/libjpeg-turbo-3.1.1" ] && [ -f "${PIXIEWOOD_SOURCE_DIR}/subprojects/libjpeg-turbo-3.1.1/jpeglib.h" ]; then
        echo "--- Copying libjpeg-turbo headers from pixiewood source directory ---"
        mkdir -p "${INSTALL_DIR}/include/libjpeg-turbo-3.1.1"
        cp -f "${PIXIEWOOD_SOURCE_DIR}/subprojects/libjpeg-turbo-3.1.1/jpeglib.h" "${INSTALL_DIR}/include/libjpeg-turbo-3.1.1/" 2>/dev/null || true
        cp -f "${PIXIEWOOD_SOURCE_DIR}/subprojects/libjpeg-turbo-3.1.1/jerror.h" "${INSTALL_DIR}/include/libjpeg-turbo-3.1.1/" 2>/dev/null || true
        cp -f "${PIXIEWOOD_SOURCE_DIR}/subprojects/libjpeg-turbo-3.1.1/jmorecfg.h" "${INSTALL_DIR}/include/libjpeg-turbo-3.1.1/" 2>/dev/null || true
        LIBJPEG_HEADERS_COPIED=true
        echo "Copied libjpeg-turbo headers from pixiewood source directory"
    fi
    
    # If neither build nor source directory has headers, try system fallback
    if [ "$LIBJPEG_HEADERS_COPIED" = false ]; then
        if [ -f "/usr/include/jpeglib.h" ]; then
            echo "--- Copying libjpeg headers from system (fallback) ---"
            mkdir -p "${INSTALL_DIR}/include/libjpeg-turbo-3.1.1"
            cp -f /usr/include/jpeglib.h "${INSTALL_DIR}/include/libjpeg-turbo-3.1.1/" 2>/dev/null || true
            cp -f /usr/include/jerror.h "${INSTALL_DIR}/include/libjpeg-turbo-3.1.1/" 2>/dev/null || true
            cp -f /usr/include/jmorecfg.h "${INSTALL_DIR}/include/libjpeg-turbo-3.1.1/" 2>/dev/null || true
            # Also search for jconfig.h in pixiewood build directory (it's generated in build subdirectory)
            find "${PIXIEWOOD_DIR}/subprojects/libjpeg-turbo-3.1.1" -name "jconfig.h" 2>/dev/null | head -1 > /tmp/jconfig_found.txt 2>/dev/null || true
            while read jconfig; do
                [ -z "$jconfig" ] && continue
                cp -f "$jconfig" "${INSTALL_DIR}/include/libjpeg-turbo-3.1.1/" 2>/dev/null || true
                echo "Also copied generated jconfig.h from $(dirname $jconfig)"
            done < /tmp/jconfig_found.txt
            rm -f /tmp/jconfig_found.txt
            LIBJPEG_HEADERS_COPIED=true
            echo "Copied system libjpeg headers as fallback"
        else
            echo "Warning: system libjpeg headers not found, will try to download libjpeg-turbo source"
            # Download libjpeg-turbo source for headers
            mkdir -p /tmp/libjpeg-source
            cd /tmp/libjpeg-source
            if [ ! -f "libjpeg-turbo-3.1.1.tar.gz" ]; then
                wget -q --timeout=30 --tries=3 --retry-connrefused --waitretry=5 \
                    "https://github.com/libjpeg-turbo/libjpeg-turbo/archive/refs/tags/3.1.1.tar.gz" -O libjpeg-turbo-3.1.1.tar.gz || \
                echo "Failed to download libjpeg-turbo source"
            fi
            tar -xzf libjpeg-turbo-3.1.1.tar.gz 2>/dev/null || true
            if [ -d "libjpeg-turbo-3.1.1" ] && [ -f "libjpeg-turbo-3.1.1/jpeglib.h" ]; then
                echo "--- Copying libjpeg-turbo headers from downloaded source ---"
                mkdir -p "${INSTALL_DIR}/include/libjpeg-turbo-3.1.1"
                cp -f libjpeg-turbo-3.1.1/jpeglib.h "${INSTALL_DIR}/include/libjpeg-turbo-3.1.1/" 2>/dev/null || true
                cp -f libjpeg-turbo-3.1.1/jerror.h "${INSTALL_DIR}/include/libjpeg-turbo-3.1.1/" 2>/dev/null || true
                cp -f libjpeg-turbo-3.1.1/jmorecfg.h "${INSTALL_DIR}/include/libjpeg-turbo-3.1.1/" 2>/dev/null || true
                # jconfig.h is generated, create a minimal one
                cat > "${INSTALL_DIR}/include/libjpeg-turbo-3.1.1/jconfig.h" << 'JCONFIGEOF'
/* jconfig.h - minimal for Android cross-compile */
#define HAVE_PROTOTYPES 1
#define HAVE_UNSIGNED_CHAR 1
#define HAVE_UNSIGNED_SHORT 1
#define HAVE_UNSIGNED_LONG 1
#define HAVE_STDDEF_H 1
#define HAVE_STDLIB_H 1
#define NEED_BSD_STRINGS 0
#define NEED_SYS_TYPES_H 1
#define NEED_FAR_POINTERS 0
#define NEED_SHORT_EXTERNAL_NAMES 0
#define INCOMPLETE_TYPES_BROKEN 0
#define JPEG_INTERNALS 1
#define MAX_SAMPLES_PER_PIXEL 16
#define RIGHT_SHIFT_IS_UNSIGNED 1
#define INLINE inline
#define RIGHT_SHIFT(x,shft) ((x) >> (shft))
#define MEMZERO(target,size) memset((void *)(target),0,(size))
#define MEMCOPY(dest,src,size) memcpy((void *)(dest),(const void *)(src),(size))
JCONFIGEOF
                LIBJPEG_HEADERS_COPIED=true
                echo "Copied libjpeg-turbo headers from downloaded source"
            fi
        fi
    fi
    
    # Create symlink for standard include path
    if [ "$LIBJPEG_HEADERS_COPIED" = true ] && [ -f "${INSTALL_DIR}/include/libjpeg-turbo-3.1.1/jpeglib.h" ]; then
        mkdir -p "${INSTALL_DIR}/include"
        ln -sf libjpeg-turbo-3.1.1/jpeglib.h "${INSTALL_DIR}/include/jpeglib.h" 2>/dev/null || true
        ln -sf libjpeg-turbo-3.1.1/jerror.h "${INSTALL_DIR}/include/jerror.h" 2>/dev/null || true
        ln -sf libjpeg-turbo-3.1.1/jmorecfg.h "${INSTALL_DIR}/include/jmorecfg.h" 2>/dev/null || true
    elif [ "$LIBJPEG_HEADERS_COPIED" = false ]; then
        echo "Warning: libjpeg headers not found anywhere"
    fi
    
    # Also copy libtiff headers (tiff.h, tiffconf.h, etc.)
    echo "--- Copying libtiff headers ---"
    LIBTIFF_HEADERS_COPIED=false
    # Try build directory first - search more broadly for tiffio.h
    echo "DEBUG: Searching for tiffio.h in pixiewood build directory..."
    find "${PIXIEWOOD_DIR}" -name "tiffio.h" 2>/dev/null | head -5 || echo "tiffio.h not found in pixiewood build directory"
    if [ -d "${PIXIEWOOD_DIR}/subprojects/tiff-4.7.0/libtiff" ]; then
        echo "--- Copying libtiff headers from pixiewood build directory ---"
        echo "DEBUG: Checking build directory for tiffio.h"
        ls -la "${PIXIEWOOD_DIR}/subprojects/tiff-4.7.0/libtiff/" 2>/dev/null | head -10 || echo "build libtiff directory empty"
        mkdir -p "${INSTALL_DIR}/include/tiff-4.7.0/libtiff"
        # Check if actual headers exist in build directory
        if [ -f "${PIXIEWOOD_DIR}/subprojects/tiff-4.7.0/libtiff/tiffio.h" ]; then
            cp -r "${PIXIEWOOD_DIR}/subprojects/tiff-4.7.0/libtiff"/*.h "${INSTALL_DIR}/include/tiff-4.7.0/libtiff/" 2>/dev/null || true
            # Also copy tiffvers.h if it exists in build directory
            if [ -f "${PIXIEWOOD_DIR}/subprojects/tiff-4.7.0/libtiff/tiffvers.h" ]; then
                cp -f "${PIXIEWOOD_DIR}/subprojects/tiff-4.7.0/libtiff/tiffvers.h" "${INSTALL_DIR}/include/tiff-4.7.0/libtiff/" 2>/dev/null || true
                echo "Copied tiffvers.h from pixiewood build directory"
            fi
            # Also check current directory for tiffvers.h (generated during build)
            if [ -f "tiffvers.h" ]; then
                cp -f "tiffvers.h" "${INSTALL_DIR}/include/tiff-4.7.0/libtiff/" 2>/dev/null || true
                echo "Copied tiffvers.h from current directory"
            fi
            # Search more broadly for tiffvers.h in pixiewood build directory
            TIFFVERS_H=$(find "${PIXIEWOOD_DIR}" -name "tiffvers.h" 2>/dev/null | head -1)
            if [ -n "$TIFFVERS_H" ]; then
                echo "Found tiffvers.h at $TIFFVERS_H"
                cp -f "$TIFFVERS_H" "${INSTALL_DIR}/include/tiff-4.7.0/libtiff/" 2>/dev/null || true
                echo "Copied tiffvers.h from $TIFFVERS_H to ${INSTALL_DIR}/include/tiff-4.7.0/libtiff/"
            fi
            fi
            LIBTIFF_HEADERS_COPIED=true
            echo "Copied libtiff headers from pixiewood build directory"
            # Also copy tiffvers.h if it exists in build directory
            if [ -f "${PIXIEWOOD_DIR}/subprojects/tiff-4.7.0/libtiff/tiffvers.h" ] && [ ! -f "${INSTALL_DIR}/include/tiff-4.7.0/libtiff/tiffvers.h" ]; then
                cp -f "${PIXIEWOOD_DIR}/subprojects/tiff-4.7.0/libtiff/tiffvers.h" "${INSTALL_DIR}/include/tiff-4.7.0/libtiff/" 2>/dev/null || true
                echo "Copied tiffvers.h from pixiewood build directory"
            fi
        else
            echo "Warning: libtiff headers (tiffio.h) not found in build directory"
            # Search for tiffio.h in subdirectories of tiff build
            find "${PIXIEWOOD_DIR}/subprojects/tiff-4.7.0" -name "tiffio.h" 2>/dev/null | head -5 | while read tiffio; do
                cp -f "$tiffio" "${INSTALL_DIR}/include/tiff-4.7.0/libtiff/" 2>/dev/null || true
                echo "Copied tiffio.h from $(dirname $tiffio)"
            done
        fi
    fi
    
    # Also check source directory for libtiff headers - the tiff source is in the artifact
    echo "DEBUG: Checking source directory for tiff - checking multiple paths"
    ls -la "${PIXIEWOOD_SOURCE_DIR}/subprojects/tiff-4.7.0/" 2>/dev/null | head -20 || echo "source tiff-4.7.0 not found at standard path"
    ls -la "${PIXIEWOOD_SOURCE_DIR}/subprojects/tiff-4.7.0/libtiff/" 2>/dev/null | head -10 || echo "source libtiff directory not found at standard path"
    
    # Try the correct source paths
    TIFF_SOURCE_PATHS=(
        "${PIXIEWOOD_SOURCE_DIR}/subprojects/tiff-4.7.0"
        "${PIXIEWOOD_SOURCE_DIR}/subprojects/tiff-4.7.0/libtiff"
    )
    
    for src_path in "${TIFF_SOURCE_PATHS[@]}"; do
        if [ -d "$src_path" ] && [ -f "$src_path/tiffio.h" ]; then
            if [ "$LIBTIFF_HEADERS_COPIED" = false ]; then
                echo "--- Copying libtiff headers from pixiewood source directory ($src_path) ---"
                mkdir -p "${INSTALL_DIR}/include/tiff-4.7.0/libtiff"
            else
                echo "--- Also copying libtiff headers from pixiewood source directory ($src_path) ---"
            fi
            cp -f "$src_path/tiffio.h" "${INSTALL_DIR}/include/tiff-4.7.0/libtiff/" 2>/dev/null || true
            cp -f "$src_path/tiff.h" "${INSTALL_DIR}/include/tiff-4.7.0/libtiff/" 2>/dev/null || true
            cp -f "$src_path/tiffconf.h" "${INSTALL_DIR}/include/tiff-4.7.0/libtiff/" 2>/dev/null || true
            LIBTIFF_HEADERS_COPIED=true
            echo "Copied libtiff headers from pixiewood source directory ($src_path)"
            # Also copy tiffvers.h if it exists in source directory
            if [ -f "$src_path/tiffvers.h" ] && [ ! -f "${INSTALL_DIR}/include/tiff-4.7.0/libtiff/tiffvers.h" ]; then
                cp -f "$src_path/tiffvers.h" "${INSTALL_DIR}/include/tiff-4.7.0/libtiff/" 2>/dev/null || true
                echo "Copied tiffvers.h from pixiewood source directory ($src_path)"
            fi
            break
        fi
    done
    
    # After source directory checks, copy tiffvers.h if generated
    if [ -f "${PIXIEWOOD_SOURCE_DIR}/subprojects/tiff-4.7.0/libtiff/tiffvers.h" ] && [ ! -f "${INSTALL_DIR}/include/tiff-4.7.0/libtiff/tiffvers.h" ]; then
        cp -f "${PIXIEWOOD_SOURCE_DIR}/subprojects/tiff-4.7.0/libtiff/tiffvers.h" "${INSTALL_DIR}/include/tiff-4.7.0/libtiff/" 2>/dev/null || true
        echo "Copied tiffvers.h from pixiewood source directory"
    elif [ -f "${PIXIEWOOD_SOURCE_DIR}/subprojects/tiff-4.7.0/tiffvers.h" ] && [ ! -f "${INSTALL_DIR}/include/tiff-4.7.0/libtiff/tiffvers.h" ]; then
        cp -f "${PIXIEWOOD_SOURCE_DIR}/subprojects/tiff-4.7.0/tiffvers.h" "${INSTALL_DIR}/include/tiff-4.7.0/libtiff/" 2>/dev/null || true
        echo "Copied tiffvers.h from pixiewood source directory (root)"
    fi
    
    # If still not found, download libtiff source directly
    if [ "$LIBTIFF_HEADERS_COPIED" = false ]; then
        echo "--- Downloading libtiff source directly for headers ---"
        mkdir -p /tmp/libtiff-source
        cd /tmp/libtiff-source
        if [ ! -f "tiff-4.7.0.tar.gz" ]; then
            # Try multiple mirrors with retries
            wget -q --timeout=30 --tries=3 --retry-connrefused --waitretry=5 \
                "https://download.osgeo.org/libtiff/tiff-4.7.0.tar.gz" -O tiff-4.7.0.tar.gz || \
            wget -q --timeout=30 --tries=3 --retry-connrefused --waitretry=5 \
                "https://github.com/libtiff/libtiff/releases/download/v4.7.0/tiff-4.7.0.tar.gz" -O tiff-4.7.0.tar.gz || \
            wget -q --timeout=30 --tries=3 --retry-connrefused --waitretry=5 \
                "https://mirrors.ocf.berkeley.edu/libtiff/tiff-4.7.0.tar.gz" -O tiff-4.7.0.tar.gz || \
            echo "Failed to download libtiff source from all mirrors"
        fi
        tar -xzf tiff-4.7.0.tar.gz 2>/dev/null || true
        if [ -d "tiff-4.7.0" ] && [ -f "tiff-4.7.0/libtiff/tiffio.h" ]; then
            echo "--- Copying libtiff headers from downloaded source ---"
            mkdir -p "${INSTALL_DIR}/include/tiff-4.7.0/libtiff"
            # Copy all headers from libtiff directory
            echo "DEBUG: Copying headers from tiff-4.7.0/libtiff/"
            ls -la tiff-4.7.0/libtiff/*.h 2>/dev/null | head -20 || echo "No .h files found in libtiff"
            cp -f tiff-4.7.0/libtiff/*.h "${INSTALL_DIR}/include/tiff-4.7.0/libtiff/" 2>/dev/null || true
            echo "DEBUG: Checking if tiffio.h was copied..."
            ls -la "${INSTALL_DIR}/include/tiff-4.7.0/libtiff/tiffio.h" 2>/dev/null | head -5 || echo "tiffio.h not found in install dir"
            # Also check for tiffconf.h.in or similar generated headers
            if [ -f "tiff-4.7.0/libtiff/tiffconf.h.in" ]; then
                cp -f tiff-4.7.0/libtiff/tiffconf.h.in "${INSTALL_DIR}/include/tiff-4.7.0/libtiff/tiffconf.h" 2>/dev/null || true
                echo "Copied tiffconf.h.in as tiffconf.h"
            fi
            # Also check port directory for config headers
            if [ -f "tiff-4.7.0/port/tiffconf.h" ]; then
                cp -f tiff-4.7.0/port/tiffconf.h "${INSTALL_DIR}/include/tiff-4.7.0/libtiff/" 2>/dev/null || true
            fi
            # Ensure tiffconf.h has all required definitions for Android cross-compile
            echo "Ensuring tiffconf.h has required definitions for Android cross-compile..."
            TIFFCONF_FILE="${INSTALL_DIR}/include/tiff-4.7.0/libtiff/tiffconf.h"
            echo "DEBUG: TIFFCONF_FILE=$TIFFCONF_FILE"
            echo "DEBUG: TIFFCONF_FILE exists: $(test -f "$TIFFCONF_FILE" && echo yes || echo no)"
            # Always ensure TIFF_SSIZE_T is properly defined by creating a clean fallback
            # (overwrite any downloaded tiffconf.h which may have #undef TIFF_SSIZE_T)
            echo "--- Creating clean tiffconf.h with TIFF_SSIZE_T ---"
            cat > "$TIFFCONF_FILE" << 'EOF'
/* tiffconf.h - minimal fallback for Android cross-compile */
#ifndef _TIFFCONF_
#define _TIFFCONF_
#define HAVE_FCNTL_H 1
#define HAVE_IEEEFP 1
#define HAVE_MMAP 1
#define HAVE_SEARCH_H 1
#define HAVE_STRING_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_UNISTD_H 1
#define HOST_FILLORDER FILLORDER_LSB2MSB
#define SIZEOF_FLOAT 4
#define SIZEOF_INT 4
#define SIZEOF_LONG 8
#define SIZEOF_SHORT 2
#define SIZEOF_VOIDP 8
/* Define missing types for Android cross-compile */
#define TIFF_SSIZE_T ssize_t
#define TIFF_UINT64_T uint64_t
#define TIFF_INT64_T int64_t
#endif
EOF
            echo "Created clean tiffconf.h with TIFF_SSIZE_T"
            echo "DEBUG: Content of tiffconf.h:"
            cat "$TIFFCONF_FILE" | head -30
            if [ ! -f "$TIFFCONF_FILE" ]; then
                echo "--- Creating minimal tiffconf.h fallback ---"
                cat > "$TIFFCONF_FILE" << 'EOF'
/* tiffconf.h - minimal fallback for Android cross-compile */
#ifndef _TIFFCONF_
#define _TIFFCONF_
#define HAVE_FCNTL_H 1
#define HAVE_IEEEFP 1
#define HAVE_MMAP 1
#define HAVE_SEARCH_H 1
#define HAVE_STRING_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_UNISTD_H 1
#define HOST_FILLORDER FILLORDER_LSB2MSB
#define SIZEOF_FLOAT 4
#define SIZEOF_INT 4
#define SIZEOF_LONG 8
#define SIZEOF_SHORT 2
#define SIZEOF_VOIDP 8
/* Define missing types for Android cross-compile */
#define TIFF_SSIZE_T ssize_t
#define TIFF_UINT64_T uint64_t
#define TIFF_INT64_T int64_t
#endif
EOF
                echo "Created minimal tiffconf.h fallback"
            else
                echo "DEBUG: tiffconf.h exists, checking for TIFF_SSIZE_T..."
                if ! grep -q "TIFF_SSIZE_T" "$TIFFCONF_FILE" 2>/dev/null; then
                    echo "Adding missing TIFF_SSIZE_T definition to tiffconf.h..."
                    cat >> "$TIFFCONF_FILE" << 'EOF'

/* Added for Android cross-compile */
#define TIFF_SSIZE_T ssize_t
#define TIFF_UINT64_T uint64_t
#define TIFF_INT64_T int64_t
EOF
                    echo "Added missing type definitions to tiffconf.h"
                else
                    echo "DEBUG: TIFF_SSIZE_T already defined in tiffconf.h"
                fi
            fi
            LIBTIFF_HEADERS_COPIED=true
            echo "Copied libtiff headers from downloaded source"
        # Also copy tiffvers.h if it was generated during download/extract
        if [ -f "tiffvers.h" ] && [ ! -f "${INSTALL_DIR}/include/tiff-4.7.0/libtiff/tiffvers.h" ]; then
            cp -f "tiffvers.h" "${INSTALL_DIR}/include/tiff-4.7.0/libtiff/" 2>/dev/null || true
            echo "Copied tiffvers.h from downloaded source directory"
        fi
        fi
    else
        echo "Failed to download or extract libtiff source"
    fi
    
    # If neither build nor source directory has headers, search more broadly in pixiewood build
    if [ "$LIBTIFF_HEADERS_COPIED" = false ]; then
        echo "--- Searching for tiff headers in pixiewood build tree ---"
        # Use a temp file to store results since while loop runs in subshell
        find "${PIXIEWOOD_DIR}" -name "tiffio.h" -o -name "tiff.h" -o -name "tiffconf.h" 2>/dev/null | head -10 > /tmp/tiff_headers.txt
        while read hdr; do
            [ -z "$hdr" ] && continue
            echo "DEBUG: Found header $hdr"
            cp -f "$hdr" "${INSTALL_DIR}/include/tiff-4.7.0/libtiff/" 2>/dev/null || true
            echo "Copied $(basename $hdr) from $(dirname $hdr)"
        done < /tmp/tiff_headers.txt
        if [ -f "${INSTALL_DIR}/include/tiff-4.7.0/libtiff/tiffio.h" ]; then
            LIBTIFF_HEADERS_COPIED=true
            echo "Copied libtiff headers from pixiewood build tree"
        fi
        rm -f /tmp/tiff_headers.txt
    fi
    
    # If neither build nor source directory has headers, try system fallback
    echo "DEBUG: LIBTIFF_HEADERS_COPIED=$LIBTIFF_HEADERS_COPIED"
    echo "DEBUG: Checking if /usr/include/tiffio.h exists..."
    ls -la /usr/include/tiffio.h 2>/dev/null | head -5 || echo "tiffio.h not found at /usr/include/tiffio.h"
    ls -la /usr/include/tiff/tiffio.h 2>/dev/null | head -5 || echo "tiffio.h not found at /usr/include/tiff/tiffio.h"
    ls -la /usr/include/tiff/ 2>/dev/null | head -10 || echo "tiff directory not found at /usr/include/tiff/"
    # Also check for libtiff directory which is where libtiff5-dev puts headers
    ls -la /usr/include/tiff/ 2>/dev/null | head -10 || echo "tiff directory not found at /usr/include/tiff/"
    # Also check for tiff headers in /usr/include/tiff5 or similar
    ls -la /usr/include/tiff5/ 2>/dev/null | head -10 || echo "tiff5 directory not found at /usr/include/tiff5/"
    # Search for tiffio.h anywhere in /usr/include
    echo "DEBUG: Searching for tiffio.h in /usr/include..."
    find /usr/include -name "tiffio.h" 2>/dev/null | head -5 || echo "tiffio.h not found anywhere in /usr/include"
    # Check both locations for tiffio.h
    TIFF_IO_FOUND=false
    TIFF_INCLUDE_PATH=""
    if [ -f "/usr/include/tiffio.h" ]; then
        TIFF_IO_FOUND=true
        TIFF_INCLUDE_PATH="/usr/include"
    elif [ -f "/usr/include/tiff/tiffio.h" ]; then
        TIFF_IO_FOUND=true
        TIFF_INCLUDE_PATH="/usr/include/tiff"
    elif [ -f "/usr/include/tiff.h" ]; then
        TIFF_IO_FOUND=true
        TIFF_INCLUDE_PATH="/usr/include"
    fi
    
    if [ "$LIBTIFF_HEADERS_COPIED" = false ] && [ "$TIFF_IO_FOUND" = true ]; then
        echo "--- Copying libtiff headers from system (fallback) ---"
        echo "DEBUG: Checking system tiff headers..."
        ls -la ${TIFF_INCLUDE_PATH}/tiff*.h 2>/dev/null | head -10 || echo "tiff headers not found in ${TIFF_INCLUDE_PATH}/"
        ls -la ${TIFF_INCLUDE_PATH}/tiff*/tiffio.h 2>/dev/null | head -10 || echo "tiffio.h not found in tiff subdir"
        echo "DEBUG: tiffio.h found at ${TIFF_INCLUDE_PATH}/tiffio.h"
        mkdir -p "${INSTALL_DIR}/include/tiff-4.7.0/libtiff"
        cp -f ${TIFF_INCLUDE_PATH}/tiff.h "${INSTALL_DIR}/include/tiff-4.7.0/libtiff/" 2>/dev/null || true
        cp -f ${TIFF_INCLUDE_PATH}/tiffconf.h "${INSTALL_DIR}/include/tiff-4.7.0/libtiff/" 2>/dev/null || true
        cp -f ${TIFF_INCLUDE_PATH}/tiffio.h "${INSTALL_DIR}/include/tiff-4.7.0/libtiff/" 2>/dev/null || true
        # Also copy to standard include path
        mkdir -p "${INSTALL_DIR}/include"
        cp -f /usr/include/tiff.h "${INSTALL_DIR}/include/" 2>/dev/null || true
        cp -f /usr/include/tiffconf.h "${INSTALL_DIR}/include/" 2>/dev/null || true
        cp -f /usr/include/tiffio.h "${INSTALL_DIR}/include/" 2>/dev/null || true
        LIBTIFF_HEADERS_COPIED=true
        echo "Copied system libtiff headers as fallback"
    fi
    
    # Ensure tiffconf.h fallback exists before creating symlinks
    if [ ! -f "${INSTALL_DIR}/include/tiff-4.7.0/libtiff/tiffconf.h" ]; then
        echo "Creating minimal tiffconf.h fallback"
        mkdir -p "${INSTALL_DIR}/include/tiff-4.7.0/libtiff"
        cat > "${INSTALL_DIR}/include/tiff-4.7.0/libtiff/tiffconf.h" << 'EOF'
/* tiffconf.h - minimal fallback for Android cross-compile */
#ifndef _TIFFCONF_
#define _TIFFCONF_
#define HAVE_FCNTL_H 1
#define HAVE_IEEEFP 1
#define HAVE_MMAP 1
#define HAVE_SEARCH_H 1
#define HAVE_STRING_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_UNISTD_H 1
#define HOST_FILLORDER FILLORDER_LSB2MSB
#define SIZEOF_FLOAT 4
#define SIZEOF_INT 4
#define SIZEOF_LONG 8
#define SIZEOF_SHORT 2
#define SIZEOF_VOIDP 8
/* Define missing types for Android cross-compile */
#define TIFF_SSIZE_T ssize_t
#define TIFF_UINT64_T uint64_t
#define TIFF_INT64_T int64_t
#endif
EOF
        echo "Created minimal tiffconf.h fallback"
    fi
    
    # Create symlinks for standard include path
    if [ "$LIBTIFF_HEADERS_COPIED" = true ] && [ -f "${INSTALL_DIR}/include/tiff-4.7.0/libtiff/tiff.h" ]; then
        mkdir -p "${INSTALL_DIR}/include"
        # Create symlinks so that all tiff headers are accessible from the include root
        ln -sf tiff-4.7.0/libtiff/tiff.h "${INSTALL_DIR}/include/tiff.h" 2>/dev/null || true
        ln -sf tiff-4.7.0/libtiff/tiffconf.h "${INSTALL_DIR}/include/tiffconf.h" 2>/dev/null || true
        ln -sf tiff-4.7.0/libtiff/tiffio.h "${INSTALL_DIR}/include/tiffio.h" 2>/dev/null || true
        # Also ensure tiffconf.h exists in libtiff directory for #include "tiffconf.h" to work
        if [ ! -f "${INSTALL_DIR}/include/tiff-4.7.0/libtiff/tiffconf.h" ]; then
            echo "--- Creating tiffconf.h fallback in libtiff directory ---"
            mkdir -p "${INSTALL_DIR}/include/tiff-4.7.0/libtiff"
            cat > "${INSTALL_DIR}/include/tiff-4.7.0/libtiff/tiffconf.h" << 'EOF'
/* tiffconf.h - minimal fallback for Android cross-compile */
#ifndef _TIFFCONF_
#define _TIFFCONF_
#define HAVE_FCNTL_H 1
#define HAVE_IEEEFP 1
#define HAVE_MMAP 1
#define HAVE_SEARCH_H 1
#define HAVE_STRING_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_UNISTD_H 1
#define HOST_FILLORDER FILLORDER_LSB2MSB
#define SIZEOF_FLOAT 4
#define SIZEOF_INT 4
#define SIZEOF_LONG 8
#define SIZEOF_SHORT 2
#define SIZEOF_VOIDP 8
/* Define missing types for Android cross-compile */
#define TIFF_SSIZE_T ssize_t
#define TIFF_UINT64_T uint64_t
#define TIFF_INT64_T int64_t
#endif
EOF
            echo "Created minimal tiffconf.h fallback in libtiff directory"
        fi
        cp -f "${INSTALL_DIR}/include/tiff-4.7.0/libtiff/tiffconf.h" "${INSTALL_DIR}/include/tiff-4.7.0/libtiff/tiffconf.h" 2>/dev/null || true
    elif [ "$LIBTIFF_HEADERS_COPIED" = false ]; then
        echo "Warning: libtiff headers not found anywhere"
    fi
    
    # Final check: ensure tiffvers.h is copied (generated during source checks)
    if [ -f "tiffvers.h" ] && [ ! -f "${INSTALL_DIR}/include/tiff-4.7.0/libtiff/tiffvers.h" ]; then
        echo "--- Copying tiffvers.h from current directory (generated during build) ---"
        cp -f "tiffvers.h" "${INSTALL_DIR}/include/tiff-4.7.0/libtiff/" 2>/dev/null || true
        echo "Copied tiffvers.h from current directory"
    fi
    
    # Create symlink for freetype2 in include (some CMake scripts expect this)
    echo "--- Searching for glib headers ---"
    echo "PIXIEWOOD_DIR=${PIXIEWOOD_DIR}"
    echo "PIXIEWOOD_ROOT=${PIXIEWOOD_ROOT}"
    echo "PIXIEWOOD_SOURCE_DIR=${PIXIEWOOD_SOURCE_DIR}"
    
    # First try: pixiewood build directory (bin-aarch64/subprojects/glib/glib/)
    if [ -d "${PIXIEWOOD_DIR}/subprojects/glib/glib" ]; then
        echo "--- Copying glib headers from pixiewood build directory ---"
        echo "DEBUG: Checking ${PIXIEWOOD_DIR}/subprojects/glib/glib/"
        ls -la "${PIXIEWOOD_DIR}/subprojects/glib/glib/" 2>/dev/null | head -20 || echo "Directory not found"
        mkdir -p "${INSTALL_DIR}/include/glib-2.0"
        # Copy main glib headers (glib.h, gobject.h, glibconfig.h, etc.)
        cp -r "${PIXIEWOOD_DIR}/subprojects/glib/glib"/* "${INSTALL_DIR}/include/glib-2.0/" 2>/dev/null || true
        # Also copy generated headers if they exist
        if [ -d "${PIXIEWOOD_DIR}/subprojects/glib/glib/generated" ]; then
            cp -r "${PIXIEWOOD_DIR}/subprojects/glib/glib/generated"/* "${INSTALL_DIR}/include/glib-2.0/" 2>/dev/null || true
        fi
        # The glibconfig.h is already in the main glib build directory, not in a nested glib/ subdirectory
        # Copy it to the glib subdirectory for CMake to find it
        mkdir -p "${INSTALL_DIR}/include/glib-2.0/glib"
        if [ -f "${PIXIEWOOD_DIR}/subprojects/glib/glib/glibconfig.h" ]; then
            cp "${PIXIEWOOD_DIR}/subprojects/glib/glib/glibconfig.h" "${INSTALL_DIR}/include/glib-2.0/glib/" 2>/dev/null || true
        fi
        echo "Copied glib headers from build directory to ${INSTALL_DIR}/include/glib-2.0"
    fi
    # Also copy from pixiewood install directory (root/include/glib-2.0/) - this has glib.h!
    if [ -d "${PIXIEWOOD_ROOT}/include/glib-2.0" ]; then
        echo "--- Copying glib headers from pixiewood install directory ---"
        echo "DEBUG: Checking ${PIXIEWOOD_ROOT}/include/glib-2.0/"
        ls -la "${PIXIEWOOD_ROOT}/include/glib-2.0/" 2>/dev/null | head -20 || echo "Directory not found"
        mkdir -p "${INSTALL_DIR}/include/glib-2.0"
        cp -r "${PIXIEWOOD_ROOT}/include/glib-2.0"/* "${INSTALL_DIR}/include/glib-2.0/" 2>/dev/null || true
        # Also copy the glib subdirectory (where glibconfig.h is)
        echo "DEBUG: Checking ${PIXIEWOOD_ROOT}/include/glib-2.0/glib/"
        ls -la "${PIXIEWOOD_ROOT}/include/glib-2.0/glib/" 2>/dev/null | head -20 || echo "Directory not found"
        if [ -d "${PIXIEWOOD_ROOT}/include/glib-2.0/glib" ]; then
            mkdir -p "${INSTALL_DIR}/include/glib-2.0/glib"
            cp -r "${PIXIEWOOD_ROOT}/include/glib-2.0/glib"/* "${INSTALL_DIR}/include/glib-2.0/glib/" 2>/dev/null || true
        fi
        # Also check if glibconfig.h is at the top level of include/glib-2.0/
        if [ -f "${PIXIEWOOD_ROOT}/include/glib-2.0/glibconfig.h" ]; then
            mkdir -p "${INSTALL_DIR}/include/glib-2.0/glib"
            cp "${PIXIEWOOD_ROOT}/include/glib-2.0/glibconfig.h" "${INSTALL_DIR}/include/glib-2.0/glib/" 2>/dev/null || true
        fi
        echo "Copied glib headers from install directory to ${INSTALL_DIR}/include/glib-2.0"
    fi
    # Copy glibmm headers from pixiewood install directory
    # The pixiewood build uses glibmm project name 2.68 but version 2.90
    # Headers are installed to glibmm-2.68 (project name) not 2.90
    echo "DEBUG: Checking PIXIEWOOD_ROOT for glibmm: ${PIXIEWOOD_ROOT}/include/glibmm-2.68/"
    ls -la "${PIXIEWOOD_ROOT}/include/glibmm-2.68/" 2>/dev/null | head -20 || echo "Directory not found in install (2.68)"
    echo "DEBUG: Checking PIXIEWOOD_ROOT for glibmm: ${PIXIEWOOD_ROOT}/include/glibmm-2.90/"
    ls -la "${PIXIEWOOD_ROOT}/include/glibmm-2.90/" 2>/dev/null | head -20 || echo "Directory not found in install (2.90)"
    if [ -d "${PIXIEWOOD_ROOT}/include/glibmm-2.68" ]; then
        echo "--- Copying glibmm headers from pixiewood install directory (2.68) ---"
        echo "DEBUG: Checking ${PIXIEWOOD_ROOT}/include/glibmm-2.68/"
        ls -la "${PIXIEWOOD_ROOT}/include/glibmm-2.68/" 2>/dev/null | head -20 || echo "Directory not found"
        mkdir -p "${INSTALL_DIR}/include/glibmm-2.90"
        cp -r "${PIXIEWOOD_ROOT}/include/glibmm-2.68"/* "${INSTALL_DIR}/include/glibmm-2.90/" 2>/dev/null || true
        # Also copy the generated headers
        if [ -d "${PIXIEWOOD_ROOT}/include/glibmm-2.68/glibmm" ]; then
            mkdir -p "${INSTALL_DIR}/include/glibmm-2.90/glibmm"
            cp -r "${PIXIEWOOD_ROOT}/include/glibmm-2.68/glibmm"/* "${INSTALL_DIR}/include/glibmm-2.90/glibmm/" 2>/dev/null || true
        fi
        echo "Copied glibmm headers to ${INSTALL_DIR}/include/glibmm-2.90"
    elif [ -d "${PIXIEWOOD_ROOT}/include/glibmm-2.90" ]; then
        echo "--- Copying glibmm headers from pixiewood install directory (2.90) ---"
        echo "DEBUG: Checking ${PIXIEWOOD_ROOT}/include/glibmm-2.90/"
        ls -la "${PIXIEWOOD_ROOT}/include/glibmm-2.90/" 2>/dev/null | head -20 || echo "Directory not found"
        mkdir -p "${INSTALL_DIR}/include/glibmm-2.90"
        cp -r "${PIXIEWOOD_ROOT}/include/glibmm-2.90"/* "${INSTALL_DIR}/include/glibmm-2.90/" 2>/dev/null || true
        # Also copy the generated headers
        if [ -d "${PIXIEWOOD_ROOT}/include/glibmm-2.90/glibmm" ]; then
            mkdir -p "${INSTALL_DIR}/include/glibmm-2.90/glibmm"
            cp -r "${PIXIEWOOD_ROOT}/include/glibmm-2.90/glibmm"/* "${INSTALL_DIR}/include/glibmm-2.90/glibmm/" 2>/dev/null || true
        fi
        echo "Copied glibmm headers to ${INSTALL_DIR}/include/glibmm-2.90"
    else
        echo "DEBUG: Checking PIXIEWOOD_DIR for glibmm: ${PIXIEWOOD_DIR}/subprojects/glibmm-2.68/glibmm/"
        ls -la "${PIXIEWOOD_DIR}/subprojects/glibmm-2.68/glibmm/" 2>/dev/null | head -20 || echo "Directory not found in build"
        if [ -d "${PIXIEWOOD_DIR}/subprojects/glibmm-2.68/glibmm" ]; then
            echo "--- Copying glibmm headers from pixiewood build directory ---"
            mkdir -p "${INSTALL_DIR}/include/glibmm-2.90"
            cp -r "${PIXIEWOOD_DIR}/subprojects/glibmm-2.68/glibmm"/* "${INSTALL_DIR}/include/glibmm-2.90/" 2>/dev/null || true
            echo "Copied glibmm headers from build directory to ${INSTALL_DIR}/include/glibmm-2.90"
        else
            echo "Warning: glibmm headers not found in any location"
        fi
    fi
    
    # Copy glibmm headers from pixiewood build directory (where meson builds them)
    # The pixiewood build uses project name glibmm-2.68 but version 2.90.0
    # Headers are in subprojects/glibmm-2.68/glibmm/ (not glib/glibmm/)
    echo "DEBUG: Checking for glibmm headers in build directory..."
    # Search broadly for glibmm in build directory
    find "${PIXIEWOOD_DIR}" -maxdepth 3 -type d -name "*glibmm*" 2>/dev/null | head -20
    if [ -d "${PIXIEWOOD_DIR}/subprojects/glibmm-2.68/glibmm" ]; then
        echo "--- Copying glibmm headers from pixiewood build directory ---"
        # Copy to glibmm-2.90/glibmm/ to match .pc file expectations
        mkdir -p "${INSTALL_DIR}/include/glibmm-2.90/glibmm"
        cp -r "${PIXIEWOOD_DIR}/subprojects/glibmm-2.68/glibmm"/* "${INSTALL_DIR}/include/glibmm-2.90/glibmm/" 2>/dev/null || true
        echo "Copied glibmm headers from build directory to ${INSTALL_DIR}/include/glibmm-2.90/glibmm"
        ls -la "${INSTALL_DIR}/include/glibmm-2.90/glibmm/" | head -20 || echo "Directory not found or empty"
    else
        echo "Warning: glibmm headers not found in build directory"
    fi
    
    # Also check BUILD directory for glibmm headers (generated during pixiewood build)
    echo "DEBUG: Checking build directory for glibmm headers..."
    echo "DEBUG: PIXIEWOOD_DIR=${PIXIEWOOD_DIR}"
    # Search for glibmm headers in build directory - they are generated during build
    # Generated headers may be deep in meson build directories (like libglibmm-2.68.so.p/.._.._untracked_glib_glibmm_)
    find "${PIXIEWOOD_DIR}" -maxdepth 6 -type f -name "ustring.h" 2>/dev/null | head -10
    find "${PIXIEWOOD_DIR}" -maxdepth 6 -type f -name "refptr.h" 2>/dev/null | head -10
    find "${PIXIEWOOD_DIR}" -maxdepth 6 -type f -name "unicode.h" 2>/dev/null | head -10
    
    GLIBMM_BUILD_FOUND=false
    # Try multiple possible build directory structures - headers are generated in build subdirectories
    # We iterate through ALL paths and copy from each, not stopping at the first match
    for build_path in \
        "${PIXIEWOOD_DIR}/subprojects/glibmm-2.90.0/glib/glibmm" \
        "${PIXIEWOOD_DIR}/subprojects/glibmm-2.90.0/glibmm" \
        "${PIXIEWOOD_DIR}/subprojects/glibmm-2.68/glib/glibmm" \
        "${PIXIEWOOD_DIR}/subprojects/glibmm-2.68/glibmm" \
        "${PIXIEWOOD_DIR}/subprojects/glibmm-2.90.0/gio/giomm" \
        "${PIXIEWOOD_DIR}/subprojects/glibmm-2.90.0/glibmm_generate_extra_defs" \
        "${PIXIEWOOD_DIR}/subprojects/glibmm-2.68/glibmm_generate_extra_defs" \
        "${PIXIEWOOD_DIR}/subprojects/glibmm-2.90.0/glib/glibmm/libglibmm-2.68.so.p" \
        "${PIXIEWOOD_DIR}/subprojects/glibmm-2.90.0/glib/glibmm/libglibmm-2.68.so.p/.._.._untracked_glib_glibmm" \
        "${PIXIEWOOD_DIR}/subprojects/glibmm-2.90.0/glibmm/libglibmm-2.68.so.p" \
        "${PIXIEWOOD_DIR}/subprojects/glibmm-2.90.0/glibmm/libglibmm-2.68.so.p/.._.._untracked_glib_glibmm"; do
        if [ -d "$build_path" ]; then
            echo "--- Copying glibmm headers from pixiewood build directory ($build_path) ---"
            mkdir -p "${INSTALL_DIR}/include/glibmm-2.90/glibmm"
            cp -r "$build_path"/* "${INSTALL_DIR}/include/glibmm-2.90/glibmm/" 2>/dev/null || true
            echo "Copied glibmm headers from build directory to ${INSTALL_DIR}/include/glibmm-2.90/glibmm"
            ls -la "${INSTALL_DIR}/include/glibmm-2.90/glibmm/" | head -20 || echo "Directory not found or empty"
        fi
    done
    
    # Also try to find generated headers in meson build directories (deep paths with untracked_)
    echo "--- Searching for generated glibmm headers in meson build directories ---"
    find "${PIXIEWOOD_DIR}" -maxdepth 7 -type f \( -name "ustring.h" -o -name "refptr.h" -o -name "unicode.h" \) -path "*glibmm*" 2>/dev/null | while read hdr; do
        echo "Found generated header: $hdr"
        mkdir -p "${INSTALL_DIR}/include/glibmm-2.90/glibmm"
        cp -f "$hdr" "${INSTALL_DIR}/include/glibmm-2.90/glibmm/" 2>/dev/null || true
    done
    
    # Verify we have the headers
    if [ ! -f "${INSTALL_DIR}/include/glibmm-2.90/glibmm/ustring.h" ]; then
        echo "Warning: glibmm/ustring.h still not found after build directory search"
        # Try broader search with deeper depth
        find "${PIXIEWOOD_DIR}" -maxdepth 7 -type f \( -name "ustring.h" -o -name "refptr.h" -o -name "unicode.h" \) 2>/dev/null | head -10
    fi
    
    # Also copy generated glibmm headers (unicode.h, etc.) from build directory
    # These are generated during pixiewood build and not in source directory
    echo "DEBUG: Searching for unicode.h in build directory..."
    echo "DEBUG: PIXIEWOOD_DIR=${PIXIEWOOD_DIR}"
    # Search broadly for unicode.h in build directory
    find "${PIXIEWOOD_DIR}" -name "unicode.h" 2>/dev/null | head -10
    UNICODE_H=$(find "${PIXIEWOOD_DIR}" -name "unicode.h" -path "*glibmm*" 2>/dev/null | head -1)
    if [ -n "$UNICODE_H" ]; then
        echo "--- Copying generated unicode.h from $UNICODE_H ---"
        mkdir -p "${INSTALL_DIR}/include/glibmm-2.90/glibmm"
        cp -f "$UNICODE_H" "${INSTALL_DIR}/include/glibmm-2.90/glibmm/" 2>/dev/null || true
        echo "Copied unicode.h from $UNICODE_H"
    else
        echo "WARNING: unicode.h not found in build directory, creating minimal fallback..."
        # Create minimal unicode.h fallback
        mkdir -p "${INSTALL_DIR}/include/glibmm-2.90/glibmm"
        cat > "${INSTALL_DIR}/include/glibmm-2.90/glibmm/unicode.h" << 'UNICODE_EOF'
/* unicode.h - minimal fallback for Android cross-compile */
#ifndef GLIBMM_UNICODE_H
#define GLIBMM_UNICODE_H

#include <glibmmconfig.h>

/* Minimal Unicode support for glibmm */
namespace Glib {

// Unicode character type
typedef gunichar unichar;

// Basic Unicode functions (minimal implementations)
inline bool unichar_isalnum(gunichar c) { return g_unichar_isalnum(c); }
inline bool unichar_isalpha(gunichar c) { return g_unichar_isalpha(c); }
inline bool unichar_iscntrl(gunichar c) { return g_unichar_iscntrl(c); }
inline bool unichar_isdigit(gunichar c) { return g_unichar_isdigit(c); }
inline bool unichar_isgraph(gunichar c) { return g_unichar_isgraph(c); }
inline bool unichar_islower(gunichar c) { return g_unichar_islower(c); }
inline bool unichar_isprint(gunichar c) { return g_unichar_isprint(c); }
inline bool unichar_isspace(gunichar c) { return g_unichar_isspace(c); }
inline bool unichar_isupper(gunichar c) { return g_unichar_isupper(c); }
inline bool unichar_isxdigit(gunichar c) { return g_unichar_isxdigit(c); }

inline gunichar unichar_tolower(gunichar c) { return g_unichar_tolower(c); }
inline gunichar unichar_toupper(gunichar c) { return g_unichar_toupper(c); }
inline gunichar unichar_totitle(gunichar c) { return g_unichar_totitle(c); }

} // namespace Glib

#endif /* GLIBMM_UNICODE_H */
UNICODE_EOF
        echo "Created minimal unicode.h fallback"
    fi
    
    # Also copy glibmmconfig.h if it exists in build directory
    if [ -f "${PIXIEWOOD_DIR}/subprojects/glibmm-2.68/glibmmconfig.h" ]; then
        mkdir -p "${INSTALL_DIR}/include/glibmm-2.90/glibmm"
        cp "${PIXIEWOOD_DIR}/subprojects/glibmm-2.68/glibmmconfig.h" "${INSTALL_DIR}/include/glibmm-2.90/glibmm/" 2>/dev/null || true
        echo "Copied glibmmconfig.h"
    elif [ -f "${PIXIEWOOD_DIR}/subprojects/glibmm-2.68/glibmm/glibmmconfig.h" ]; then
        mkdir -p "${INSTALL_DIR}/include/glibmm-2.90/glibmm"
        cp "${PIXIEWOOD_DIR}/subprojects/glibmm-2.68/glibmm/glibmmconfig.h" "${INSTALL_DIR}/include/glibmm-2.90/glibmm/" 2>/dev/null || true
        echo "Copied glibmmconfig.h"
    fi
    
    # Copy libxml2 headers from pixiewood install directory
    if [ -d "${PIXIEWOOD_ROOT}/include/libxml2" ]; then
        echo "--- Copying libxml2 headers from pixiewood install directory ---"
        echo "DEBUG: Checking ${PIXIEWOOD_ROOT}/include/libxml2/"
        ls -la "${PIXIEWOOD_ROOT}/include/libxml2/" 2>/dev/null | head -20 || echo "Directory not found"
        mkdir -p "${INSTALL_DIR}/include/libxml2"
        cp -r "${PIXIEWOOD_ROOT}/include/libxml2"/* "${INSTALL_DIR}/include/libxml2/" 2>/dev/null || true
        echo "Copied libxml2 headers to ${INSTALL_DIR}/include/libxml2"
    elif [ -d "${PIXIEWOOD_DIR}/subprojects/libxml2-2.12.6/include" ]; then
        echo "--- Copying libxml2 headers from pixiewood build directory ---"
        mkdir -p "${INSTALL_DIR}/include/libxml2"
        cp -r "${PIXIEWOOD_DIR}/subprojects/libxml2-2.12.6/include"/* "${INSTALL_DIR}/include/libxml2/" 2>/dev/null || true
        echo "Copied libxml2 headers from build directory to ${INSTALL_DIR}/include/libxml2"
    elif [ -d "/usr/include/libxml2" ]; then
        echo "--- Copying libxml2 headers from system (fallback) ---"
        mkdir -p "${INSTALL_DIR}/include/libxml2"
        cp -r /usr/include/libxml2/* "${INSTALL_DIR}/include/libxml2/" 2>/dev/null || true
        echo "Copied system libxml2 headers as fallback"
    else
        echo "Warning: libxml2 headers not found in any location"
    fi
    # Also ensure libxml2 headers exist by copying from system if not already copied
    if [ ! -f "${INSTALL_DIR}/include/libxml2/tree.h" ] && [ -d "/usr/include/libxml2" ]; then
        echo "--- Ensuring libxml2 headers from system ---"
        mkdir -p "${INSTALL_DIR}/include/libxml2"
        cp -r /usr/include/libxml2/* "${INSTALL_DIR}/include/libxml2/" 2>/dev/null || true
        echo "Copied system libxml2 headers as final fallback"
    fi
    
    # Copy ICU headers from pixiewood install directory
    if [ -d "${PIXIEWOOD_ROOT}/include/unicode" ]; then
        echo "--- Copying ICU headers from pixiewood install directory ---"
        echo "DEBUG: Checking ${PIXIEWOOD_ROOT}/include/unicode/"
        ls -la "${PIXIEWOOD_ROOT}/include/unicode/" 2>/dev/null | head -20 || echo "Directory not found"
        mkdir -p "${INSTALL_DIR}/include/unicode"
        cp -r "${PIXIEWOOD_ROOT}/include/unicode"/* "${INSTALL_DIR}/include/unicode/" 2>/dev/null || true
        echo "Copied ICU headers to ${INSTALL_DIR}/include/unicode"
    elif [ -d "${PIXIEWOOD_DIR}/subprojects/icu-75.1/source/common" ]; then
        echo "--- Copying ICU headers from pixiewood build directory ---"
        mkdir -p "${INSTALL_DIR}/include/unicode"
        cp -r "${PIXIEWOOD_DIR}/subprojects/icu-75.1/source/common/unicode"/* "${INSTALL_DIR}/include/unicode/" 2>/dev/null || true
        cp -r "${PIXIEWOOD_DIR}/subprojects/icu-75.1/source/i18n/unicode"/* "${INSTALL_DIR}/include/unicode/" 2>/dev/null || true
        echo "Copied ICU headers from build directory to ${INSTALL_DIR}/include/unicode"
    elif [ -d "/usr/include/unicode" ]; then
        echo "--- Copying ICU headers from system (fallback) ---"
        mkdir -p "${INSTALL_DIR}/include/unicode"
        cp -r /usr/include/unicode/* "${INSTALL_DIR}/include/unicode/" 2>/dev/null || true
        echo "Copied system ICU headers as fallback"
    else
        echo "Warning: ICU headers not found in any location"
    fi
    
    # Copy libintl headers from pixiewood install directory
    echo "DEBUG: Searching for libintl.h in pixiewood..."
    find "${PIXIEWOOD_ROOT}/include" -name "libintl.h" 2>/dev/null | head -5 || echo "Not in root/include"
    find "${PIXIEWOOD_DIR}" -name "libintl.h" 2>/dev/null | head -5 || echo "Not in build dir"
    if [ -f "${PIXIEWOOD_ROOT}/include/libintl.h" ]; then
        echo "--- Copying libintl.h from pixiewood install directory ---"
        cp -f "${PIXIEWOOD_ROOT}/include/libintl.h" "${INSTALL_DIR}/include/" 2>/dev/null || true
        echo "Copied libintl.h to ${INSTALL_DIR}/include/"
    elif [ -f "${PIXIEWOOD_DIR}/subprojects/gettext-0.22.5/gettext-runtime/intl/libintl.h" ]; then
        echo "--- Copying libintl.h from pixiewood build directory ---"
        cp -f "${PIXIEWOOD_DIR}/subprojects/gettext-0.22.5/gettext-runtime/intl/libintl.h" "${INSTALL_DIR}/include/" 2>/dev/null || true
        echo "Copied libintl.h from build directory to ${INSTALL_DIR}/include/"
    elif [ -f "/usr/include/libintl.h" ]; then
        echo "--- Copying libintl.h from system (fallback) ---"
        # System libintl.h has glibc-specific macros, create a minimal one instead
        echo "Creating minimal libintl.h for Android cross-compile..."
        cat > "${INSTALL_DIR}/include/libintl.h" << 'INTLEOF'
/* libintl.h - minimal for Android cross-compile */
#ifndef _LIBINTL_H
#define _LIBINTL_H 1

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifndef __THROW
#define __THROW
#endif

extern char *gettext (const char *__msgid) __THROW;
extern char *dgettext (const char *__domainname, const char *__msgid) __THROW;
extern char *dcgettext (const char *__domainname, const char *__msgid, int __category) __THROW;
extern char *ngettext (const char *__msgid1, const char *__msgid2, unsigned long int __n) __THROW;
extern char *dngettext (const char *__domainname, const char *__msgid1, const char *__msgid2, unsigned long int __n) __THROW;
extern char *dcngettext (const char *__domainname, const char *__msgid1, const char *__msgid2, unsigned long int __n, int __category) __THROW;
extern char *textdomain (const char *__domainname) __THROW;
extern char *bindtextdomain (const char *__domainname, const char *__dirname) __THROW;
extern char *bind_textdomain_codeset (const char *__domainname, const char *__codeset) __THROW;

#ifdef __cplusplus
}
#endif

#endif /* _LIBINTL_H */
INTLEOF
        echo "Created minimal libintl.h for Android"
    fi
    
    # Third try: system glib headers (fallback for cross-compile) - only if neither above worked
    if [ ! -f "${INSTALL_DIR}/include/glib-2.0/glib.h" ] && [ -d "/usr/include/glib-2.0" ]; then
        echo "--- Copying glib headers from system (fallback) ---"
        echo "DEBUG: Checking /usr/include/glib-2.0/"
        ls -la /usr/include/glib-2.0/ 2>/dev/null | head -20 || echo "Directory not found"
        mkdir -p "${INSTALL_DIR}/include/glib-2.0"
        cp -r /usr/include/glib-2.0/* "${INSTALL_DIR}/include/glib-2.0/" 2>/dev/null || true
        # Also copy the glibconfig.h from the build directory
        echo "DEBUG: Checking /usr/lib/aarch64-linux-gnu/glib-2.0/include/"
        ls -la /usr/lib/aarch64-linux-gnu/glib-2.0/include/ 2>/dev/null | head -20 || echo "Directory not found"
        if [ -d "/usr/lib/aarch64-linux-gnu/glib-2.0/include" ]; then
            mkdir -p "${INSTALL_DIR}/include/glib-2.0/glib"
            cp -r /usr/lib/aarch64-linux-gnu/glib-2.0/include/* "${INSTALL_DIR}/include/glib-2.0/glib/" 2>/dev/null || true
        elif [ -d "/usr/lib/x86_64-linux-gnu/glib-2.0/include" ]; then
            mkdir -p "${INSTALL_DIR}/include/glib-2.0/glib"
            cp -r /usr/lib/x86_64-linux-gnu/glib-2.0/include/* "${INSTALL_DIR}/include/glib-2.0/glib/" 2>/dev/null || true
        fi
        # Also check if glibconfig.h is at the top level of /usr/include/glib-2.0/
        if [ -f "/usr/include/glib-2.0/glibconfig.h" ]; then
            mkdir -p "${INSTALL_DIR}/include/glib-2.0/glib"
            cp /usr/include/glib-2.0/glibconfig.h "${INSTALL_DIR}/include/glib-2.0/glib/" 2>/dev/null || true
        fi
        echo "Copied system glib headers to ${INSTALL_DIR}/include/glib-2.0 (fallback)"
    elif [ ! -f "${INSTALL_DIR}/include/glib-2.0/glib.h" ]; then
        echo "Warning: glib-2.0 headers not found in any location"
    fi
    
    # Copy all required libraries from pixiewood build directory to android-install/lib/
    echo "--- Copying all libraries from pixiewood ---"
    mkdir -p "${INSTALL_DIR}/lib"
    
    # First, copy from the installed location (root/lib/arm64-v8a/)
    # This is where pixiewood installs the built libraries
    echo "--- Copying libraries from pixiewood install directory ---"
    echo "DEBUG: PIXIEWOOD_ROOT=${PIXIEWOOD_ROOT}"
    echo "DEBUG: Checking ${PIXIEWOOD_ROOT}/lib/arm64-v8a/"
    ls -la "${PIXIEWOOD_ROOT}/" 2>/dev/null | head -20 || echo "PIXIEWOOD_ROOT not found"
    ls -la "${PIXIEWOOD_ROOT}/lib/" 2>/dev/null | head -20 || echo "lib directory not found"
    ls -la "${PIXIEWOOD_ROOT}/lib/arm64-v8a/" 2>/dev/null || echo "arm64-v8a directory not found"
    if [ -d "${PIXIEWOOD_ROOT}/lib/arm64-v8a" ]; then
        echo "Found arm64-v8a directory, copying .so files..."
        cp -f "${PIXIEWOOD_ROOT}/lib/arm64-v8a"/*.so "${INSTALL_DIR}/lib/" 2>/dev/null || true
        cp -f "${PIXIEWOOD_ROOT}/lib/arm64-v8a"/*.so.* "${INSTALL_DIR}/lib/" 2>/dev/null || true
        echo "Copied libraries from pixiewood root/arm64-v8a"
        ls -la "${INSTALL_DIR}/lib/" | head -30
    elif [ -d "${PIXIEWOOD_ROOT}/lib" ]; then
        echo "DEBUG: Checking ${PIXIEWOOD_ROOT}/lib/"
        ls -la "${PIXIEWOOD_ROOT}/lib/" 2>/dev/null | head -20 || echo "lib directory not found"
        cp -f "${PIXIEWOOD_ROOT}/lib"/*.so "${INSTALL_DIR}/lib/" 2>/dev/null || true
        cp -f "${PIXIEWOOD_ROOT}/lib"/*.so.* "${INSTALL_DIR}/lib/" 2>/dev/null || true
        echo "Copied libraries from pixiewood root"
        ls -la "${INSTALL_DIR}/lib/" | head -30
    else
        echo "WARNING: Neither ${PIXIEWOOD_ROOT}/lib/arm64-v8a nor ${PIXIEWOOD_ROOT}/lib exists!"
    fi
    
    # Also try the build directory for glib libraries (they may be in subprojects build dir)
    echo "--- Checking pixiewood build directory for glib libraries ---"
    if [ -d "${PIXIEWOOD_DIR}/subprojects/glib/glib" ]; then
        ls -la "${PIXIEWOOD_DIR}/subprojects/glib/glib/" | head -20
        cp -f "${PIXIEWOOD_DIR}/subprojects/glib/glib"/*.so "${INSTALL_DIR}/lib/" 2>/dev/null || true
        cp -f "${PIXIEWOOD_DIR}/subprojects/glib/glib"/*.so.* "${INSTALL_DIR}/lib/" 2>/dev/null || true
        echo "Copied glib libraries from build directory"
        ls -la "${INSTALL_DIR}/lib/" | head -30
    fi
    
    # Also try gobject, gio, gmodule, gthread
    for glib_lib in "glib/gobject" "glib/gio" "glib/gmodule" "glib/gthread"; do
        if [ -d "${PIXIEWOOD_DIR}/subprojects/${glib_lib}" ]; then
            cp -f "${PIXIEWOOD_DIR}/subprojects/${glib_lib}"/*.so "${INSTALL_DIR}/lib/" 2>/dev/null || true
            cp -f "${PIXIEWOOD_DIR}/subprojects/${glib_lib}"/*.so.* "${INSTALL_DIR}/lib/" 2>/dev/null || true
            echo "Copied ${glib_lib} libraries from build directory"
        fi
    done
    
    # Also try the Android app's merged native libs (where the final APK libs are)
    ANDROID_LIBS="${GITHUB_WORKSPACE}/.pixiewood/bin-aarch64/../../android/app/build/intermediates/merged_native_libs/release/mergeReleaseNativeLibs/out/lib/arm64-v8a"
    if [ -d "${ANDROID_LIBS}" ]; then
        echo "--- Copying libraries from Android app merged native libs ---"
        cp -f "${ANDROID_LIBS}"/*.so "${INSTALL_DIR}/lib/" 2>/dev/null || true
        cp -f "${ANDROID_LIBS}"/*.so.* "${INSTALL_DIR}/lib/" 2>/dev/null || true
        echo "Copied libraries from Android app merged native libs"
    fi
    
    # Also copy from the build directory's subprojects for libraries not installed
    # These are libraries like libpng, libjpeg, libtiff that may not be installed to root/
    echo "--- Copying additional libraries from pixiewood build directory ---"
    BUILD_LIB_DIRS=(
        "libpng-1.6.49"
        "libjpeg"
        "tiff-4.7.0/libtiff"
        "fribidi"
        "zlib"
    )
    for lib_dir in "${BUILD_LIB_DIRS[@]}"; do
        if [ -d "${PIXIEWOOD_DIR}/subprojects/${lib_dir}" ]; then
            echo "Copying libraries from ${lib_dir}..."
            # Copy from main directory
            cp -f "${PIXIEWOOD_DIR}/subprojects/${lib_dir}"/*.so "${INSTALL_DIR}/lib/" 2>/dev/null || true
            cp -f "${PIXIEWOOD_DIR}/subprojects/${lib_dir}"/*.so.* "${INSTALL_DIR}/lib/" 2>/dev/null || true
            # Copy from build subdirectories (like libpng16.so.p for libpng)
            find "${PIXIEWOOD_DIR}/subprojects/${lib_dir}" -name "*.so" -o -name "*.so.*" 2>/dev/null | while read libfile; do
                cp -f "$libfile" "${INSTALL_DIR}/lib/" 2>/dev/null || true
            done
            echo "Copied libraries from ${lib_dir}"
        fi
    done
    # Create symlink for libpng.so -> libpng16.so (Inkscape looks for libpng.so)
    if [ -f "${INSTALL_DIR}/lib/libpng16.so" ] && [ ! -f "${INSTALL_DIR}/lib/libpng.so" ]; then
        ln -sf libpng16.so "${INSTALL_DIR}/lib/libpng.so"
        echo "Created symlink libpng.so -> libpng16.so"
    fi
    # Also create symlink for libjpeg if needed
    if [ -f "${INSTALL_DIR}/lib/libjpeg.so.8" ] && [ ! -f "${INSTALL_DIR}/lib/libjpeg.so" ]; then
        ln -sf libjpeg.so.8 "${INSTALL_DIR}/lib/libjpeg.so"
        echo "Created symlink libjpeg.so -> libjpeg.so.8"
    fi
    # Also create symlink for libtiff if needed
    if [ -f "${INSTALL_DIR}/lib/libtiff.so.6" ] && [ ! -f "${INSTALL_DIR}/lib/libtiff.so" ]; then
        ln -sf libtiff.so.6 "${INSTALL_DIR}/lib/libtiff.so"
        echo "Created symlink libtiff.so -> libtiff.so.6"
    fi
    # Also create symlink for libz if needed (zlib)
    echo "DEBUG: Checking for libz.so.1 before symlink"
    ls -la "${INSTALL_DIR}/lib/libz.so"* 2>/dev/null || echo "libz not found in install dir"
    if [ -f "${INSTALL_DIR}/lib/libz.so.1" ] && [ ! -f "${INSTALL_DIR}/lib/libz.so" ]; then
        ln -sf libz.so.1 "${INSTALL_DIR}/lib/libz.so"
        echo "Created symlink libz.so -> libz.so.1"
    else
        echo "WARNING: libz.so.1 not found in install dir, cannot create symlink"
    fi
    
    # If libz is still missing, try to copy from pixiewood build directory
    if [ ! -f "${INSTALL_DIR}/lib/libz.so.1" ] && [ -f "${PIXIEWOOD_DIR}/subprojects/zlib/libz.so" ]; then
        echo "--- Copying libz from pixiewood build directory ---"
        cp -f "${PIXIEWOOD_DIR}/subprojects/zlib/libz.so"* "${INSTALL_DIR}/lib/" 2>/dev/null || true
        echo "Copied libz from pixiewood build directory"
    elif [ ! -f "${INSTALL_DIR}/lib/libz.so.1" ] && [ -f "${PIXIEWOOD_ROOT}/lib/libz.so.1" ]; then
        echo "--- Copying libz from pixiewood install directory ---"
        cp -f "${PIXIEWOOD_ROOT}/lib/libz.so"* "${INSTALL_DIR}/lib/" 2>/dev/null || true
        echo "Copied libz from pixiewood install directory"
    fi
    
    # Also try to copy from system (host) libraries - pixiewood may use host zlib
    if [ ! -f "${INSTALL_DIR}/lib/libz.so.1" ] && [ -f "/usr/lib/aarch64-linux-gnu/libz.so.1" ]; then
        echo "--- Copying libz from system (host) ---"
        cp -f /usr/lib/aarch64-linux-gnu/libz.so* "${INSTALL_DIR}/lib/" 2>/dev/null || true
        echo "Copied libz from system"
    elif [ ! -f "${INSTALL_DIR}/lib/libz.so.1" ] && [ -f "/usr/lib/x86_64-linux-gnu/libz.so.1" ]; then
        echo "--- Copying libz from system (x86_64) ---"
        cp -f /usr/lib/x86_64-linux-gnu/libz.so* "${INSTALL_DIR}/lib/" 2>/dev/null || true
        echo "Copied libz from system (x86_64)"
    fi
    
    # Now try to create symlink again
    if [ -f "${INSTALL_DIR}/lib/libz.so.1" ] && [ ! -f "${INSTALL_DIR}/lib/libz.so" ]; then
        ln -sf libz.so.1 "${INSTALL_DIR}/lib/libz.so"
        echo "Created symlink libz.so -> libz.so.1"
    fi
    
    # Fallback to system libraries (host libraries - for linking only)
    # Only use if pixiewood didn't provide them
    if [ ! -f "${INSTALL_DIR}/lib/libglib-2.0.so" ] && [ -f "/usr/lib/aarch64-linux-gnu/libglib-2.0.so" ]; then
        echo "--- Using system libraries as fallback ---"
        cp -f /usr/lib/aarch64-linux-gnu/libglib-2.0.so* "${INSTALL_DIR}/lib/" 2>/dev/null || true
        cp -f /usr/lib/aarch64-linux-gnu/libgobject-2.0.so* "${INSTALL_DIR}/lib/" 2>/dev/null || true
        cp -f /usr/lib/aarch64-linux-gnu/libgthread-2.0.so* "${INSTALL_DIR}/lib/" 2>/dev/null || true
        cp -f /usr/lib/aarch64-linux-gnu/libgmodule-2.0.so* "${INSTALL_DIR}/lib/" 2>/dev/null || true
        cp -f /usr/lib/aarch64-linux-gnu/libgio-2.0.so* "${INSTALL_DIR}/lib/" 2>/dev/null || true
        cp -f /usr/lib/aarch64-linux-gnu/libpng.so* "${INSTALL_DIR}/lib/" 2>/dev/null || true
        cp -f /usr/lib/aarch64-linux-gnu/libjpeg.so* "${INSTALL_DIR}/lib/" 2>/dev/null || true
        cp -f /usr/lib/aarch64-linux-gnu/libtiff.so* "${INSTALL_DIR}/lib/" 2>/dev/null || true
        cp -f /usr/lib/aarch64-linux-gnu/libfreetype.so* "${INSTALL_DIR}/lib/" 2>/dev/null || true
        cp -f /usr/lib/aarch64-linux-gnu/libfontconfig.so* "${INSTALL_DIR}/lib/" 2>/dev/null || true
        cp -f /usr/lib/aarch64-linux-gnu/libharfbuzz.so* "${INSTALL_DIR}/lib/" 2>/dev/null || true
        cp -f /usr/lib/aarch64-linux-gnu/libharfbuzz-cairo.so* "${INSTALL_DIR}/lib/" 2>/dev/null || true
        cp -f /usr/lib/aarch64-linux-gnu/libpango-1.0.so* "${INSTALL_DIR}/lib/" 2>/dev/null || true
        cp -f /usr/lib/aarch64-linux-gnu/libpangoft2-1.0.so* "${INSTALL_DIR}/lib/" 2>/dev/null || true
        cp -f /usr/lib/aarch64-linux-gnu/libpangocairo-1.0.so* "${INSTALL_DIR}/lib/" 2>/dev/null || true
        cp -f /usr/lib/aarch64-linux-gnu/libcairo.so* "${INSTALL_DIR}/lib/" 2>/dev/null || true
        cp -f /usr/lib/aarch64-linux-gnu/libcairo-gobject.so* "${INSTALL_DIR}/lib/" 2>/dev/null || true
        cp -f /usr/lib/aarch64-linux-gnu/libharfbuzz.so* "${INSTALL_DIR}/lib/" 2>/dev/null || true
        cp -f /usr/lib/aarch64-linux-gnu/libfribidi.so* "${INSTALL_DIR}/lib/" 2>/dev/null || true
        cp -f /usr/lib/aarch64-linux-gnu/libepoxy.so* "${INSTALL_DIR}/lib/" 2>/dev/null || true
        cp -f /usr/lib/aarch64-linux-gnu/libpixman-1.so* "${INSTALL_DIR}/lib/" 2>/dev/null || true
        cp -f /usr/lib/aarch64-linux-gnu/libtiff.so* "${INSTALL_DIR}/lib/" 2>/dev/null || true
        echo "Copied system libraries as fallback"
    fi
    
    echo "=== Library copy complete ==="
    ls -la "${INSTALL_DIR}/lib/" | head -50
    
    cat > "$INSTALL_DIR/lib/pkgconfig/gobject-2.0.pc" << PCEOF
prefix=$INSTALL_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: GObject
Description: Object/type system for GLib
Version: 2.90.0
Requires: glib-2.0
Libs: -L${GLIB_LIB} -lgobject-2.0
Cflags: -I${GLIB_INCLUDE}/glib-2.0 -I${GLIB_INCLUDE}/glib-2.0/include
PCEOF
    
    cat > "$INSTALL_DIR/lib/pkgconfig/gio-2.0.pc" << PCEOF
prefix=$INSTALL_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: GIO
Description: I/O abstraction library
Version: 2.90.0
Requires: glib-2.0, gobject-2.0
Libs: -L${GLIB_LIB} -lgio-2.0
Cflags: -I${GLIB_INCLUDE}/glib-2.0 -I${GLIB_INCLUDE}/glib-2.0/include
PCEOF
    
    cat > "$INSTALL_DIR/lib/pkgconfig/gmodule-2.0.pc" << PCEOF
prefix=$INSTALL_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: GModule
Description: Dynamic module loading for GLib
Version: 2.90.0
Requires: glib-2.0
Libs: -L${GLIB_LIB} -lgmodule-2.0
Cflags: -I${GLIB_INCLUDE}/glib-2.0 -I${GLIB_INCLUDE}/glib-2.0/include
PCEOF
    
    cat > "$INSTALL_DIR/lib/pkgconfig/gthread-2.0.pc" << PCEOF
prefix=$INSTALL_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: GThread
Description: Thread support for GLib
Version: 2.90.0
Requires: glib-2.0
Libs: -L${GLIB_LIB} -lgthread-2.0
Cflags: -I${GLIB_INCLUDE}/glib-2.0 -I${GLIB_INCLUDE}/glib-2.0/include
PCEOF
    
    echo "Created minimal .pc files for GLib/GObject/GIO/GModule/GThread"

# Also create libxml-2.0.pc if missing (needed by libcroco)
if [ ! -f "$INSTALL_DIR/lib/pkgconfig/libxml-2.0.pc" ]; then
    echo "--- Creating libxml-2.0.pc ---"
    
    # Find libxml2 from pixiewood
    LIBXML_LIB=$(find "$PIXIEWOOD_DIR" -name "libxml2.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_LIB")
    # libxml headers are copied to INSTALL_DIR/include/libxml2
    LIBXML_INCLUDE="${INSTALL_DIR}/include"
    
    cat > "$INSTALL_DIR/lib/pkgconfig/libxml-2.0.pc" << PCEOF
prefix=$INSTALL_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: libxml2
Description: XML parsing library
Version: 2.12.6
Requires:
Libs: -L${LIBXML_LIB} -lxml2
Cflags: -I${LIBXML_INCLUDE}/libxml2
PCEOF
    
    echo "Created libxml-2.0.pc"
fi

# Create missing .pc files for pixiewood libraries (not installed by pixiewood)
# These are required by Inkscape CMake

# cairo
if [ ! -f "$INSTALL_DIR/lib/pkgconfig/cairo.pc" ]; then
    echo "--- Creating cairo.pc ---"
    CAIRO_LIB=$(find "$PIXIEWOOD_DIR" -name "libcairo.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_LIB")
    CAIRO_INCLUDE="${PIXIEWOOD_ROOT}/include"
    cat > "$INSTALL_DIR/lib/pkgconfig/cairo.pc" << PCEOF
prefix=$INSTALL_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: cairo
Description: Vector graphics library
Version: 1.18.0
Requires:
Libs: -L${CAIRO_LIB} -lcairo
Cflags: -I${CAIRO_INCLUDE}/cairo
PCEOF
    echo "Created cairo.pc"
fi

# cairo-gobject
if [ ! -f "$INSTALL_DIR/lib/pkgconfig/cairo-gobject.pc" ]; then
    echo "--- Creating cairo-gobject.pc ---"
    CAIRO_GOBJECT_LIB=$(find "$PIXIEWOOD_DIR" -name "libcairo-gobject.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_LIB")
    CAIRO_INCLUDE="${PIXIEWOOD_ROOT}/include"
    cat > "$INSTALL_DIR/lib/pkgconfig/cairo-gobject.pc" << PCEOF
prefix=$INSTALL_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: cairo-gobject
Description: Cairo GObject bindings
Version: 1.18.0
Requires: cairo
Libs: -L${CAIRO_GOBJECT_LIB} -lcairo-gobject
Cflags: -I${CAIRO_INCLUDE}/cairo
PCEOF
    echo "Created cairo-gobject.pc"
fi

# freetype2
if [ ! -f "$INSTALL_DIR/lib/pkgconfig/freetype2.pc" ]; then
    echo "--- Creating freetype2.pc ---"
    FT_LIB=$(find "$PIXIEWOOD_DIR" -name "libfreetype.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_LIB")
    cat > "$INSTALL_DIR/lib/pkgconfig/freetype2.pc" << 'PCEOF'
prefix=${INSTALL_DIR}
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: freetype2
Description: FreeType 2 font engine
Version: 2.13.0
Requires:
Libs: -L${FT_LIB} -lfreetype
Cflags: -I${includedir}/freetype2
PCEOF
    echo "Created freetype2.pc"
fi

# pango-1.0
if [ ! -f "$INSTALL_DIR/lib/pkgconfig/pango-1.0.pc" ]; then
    echo "--- Creating pango-1.0.pc ---"
    PANGO_LIB=$(find "$PIXIEWOOD_DIR" -name "libpango-1.0.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_LIB")
    PANGO_INCLUDE="${PIXIEWOOD_ROOT}/include"
    cat > "$INSTALL_DIR/lib/pkgconfig/pango-1.0.pc" << PCEOF
prefix=$INSTALL_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: Pango
Description: Text layout and rendering
Version: 1.58.0
Requires: glib-2.0, gobject-2.0, gio-2.0, gmodule-2.0, freetype2, fontconfig
Libs: -L${PANGO_LIB} -lpango-1.0
Cflags: -I${PANGO_INCLUDE}/pango-1.0
PCEOF
    echo "Created pango-1.0.pc"
fi

# harfbuzz
if [ ! -f "$INSTALL_DIR/lib/pkgconfig/harfbuzz.pc" ]; then
    echo "--- Creating harfbuzz.pc ---"
    HB_LIB=$(find "$PIXIEWOOD_DIR" -name "libharfbuzz.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_LIB")
    HB_INCLUDE="${PIXIEWOOD_ROOT}/include"
    cat > "$INSTALL_DIR/lib/pkgconfig/harfbuzz.pc" << PCEOF
prefix=$INSTALL_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: harfbuzz
Description: OpenType text shaping engine
Version: 8.0.0
Requires:
Libs: -L${HB_LIB} -lharfbuzz
Cflags: -I${HB_INCLUDE}/harfbuzz
PCEOF
    echo "Created harfbuzz.pc"
fi

# pangocairo
if [ ! -f "$INSTALL_DIR/lib/pkgconfig/pangocairo.pc" ]; then
    echo "--- Creating pangocairo.pc ---"
    PANGO_LIB=$(find "$PIXIEWOOD_DIR" -name "libpangocairo-1.0.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_LIB")
    PANGO_INCLUDE="${PIXIEWOOD_ROOT}/include"
    cat > "$INSTALL_DIR/lib/pkgconfig/pangocairo.pc" << PCEOF
prefix=$INSTALL_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: PangoCairo
Description: Cairo rendering for Pango
Version: 1.58.0
Requires: pango-1.0, cairo
Libs: -L${PANGO_LIB} -lpangocairo-1.0
Cflags: -I${PANGO_INCLUDE}/pango-1.0
PCEOF
    echo "Created pangocairo.pc"
fi

# pangoft2
if [ ! -f "$INSTALL_DIR/lib/pkgconfig/pangoft2.pc" ]; then
    echo "--- Creating pangoft2.pc ---"
    PANGO_LIB=$(find "$PIXIEWOOD_DIR" -name "libpangoft2-1.0.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_LIB")
    PANGO_INCLUDE="${PIXIEWOOD_ROOT}/include"
    cat > "$INSTALL_DIR/lib/pkgconfig/pangoft2.pc" << PCEOF
prefix=$INSTALL_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: PangoFT2
Description: FreeType2 backend for Pango
Version: 1.58.0
Requires: pango-1.0, freetype2
Libs: -L${PANGO_LIB} -lpangoft2-1.0
Cflags: -I${PANGO_INCLUDE}/pango-1.0
PCEOF
    echo "Created pangoft2.pc"
fi

# fontconfig
if [ ! -f "$INSTALL_DIR/lib/pkgconfig/fontconfig.pc" ]; then
    echo "--- Creating fontconfig.pc ---"
    FC_LIB=$(find "$PIXIEWOOD_DIR" -name "libfontconfig.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_LIB")
    FC_INCLUDE="${PIXIEWOOD_ROOT}/include"
    cat > "$INSTALL_DIR/lib/pkgconfig/fontconfig.pc" << PCEOF
prefix=$INSTALL_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: fontconfig
Description: Font configuration and customization library
Version: 2.14.2
Requires:
Libs: -L${FC_LIB} -lfontconfig
Cflags: -I${FC_INCLUDE}/fontconfig
PCEOF
    echo "Created fontconfig.pc"
fi

# bdw-gc (Boehm GC)
if [ ! -f "$INSTALL_DIR/lib/pkgconfig/bdw-gc.pc" ]; then
    echo "--- Creating bdw-gc.pc ---"
    GC_LIB=$(find "$PIXIEWOOD_DIR" -name "libgc.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_LIB")
    GC_INCLUDE="${PIXIEWOOD_ROOT}/include"
    cat > "$INSTALL_DIR/lib/pkgconfig/bdw-gc.pc" << PCEOF
prefix=$INSTALL_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: bdw-gc
Description: Boehm-Demers-Weiser conservative garbage collector
Version: 8.2.4
Requires:
Libs: -L${GC_LIB} -lgc
Cflags: -I${GC_INCLUDE}
PCEOF
    echo "Created bdw-gc.pc"
fi

# harfbuzz-cairo
if [ ! -f "$INSTALL_DIR/lib/pkgconfig/harfbuzz-cairo.pc" ]; then
    echo "--- Creating harfbuzz-cairo.pc ---"
    HB_LIB=$(find "$PIXIEWOOD_DIR" -name "libharfbuzz.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_LIB")
    HB_INCLUDE="${PIXIEWOOD_ROOT}/include"
    cat > "$INSTALL_DIR/lib/pkgconfig/harfbuzz-cairo.pc" << PCEOF
prefix=$INSTALL_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: harfbuzz-cairo
Description: HarfBuzz Cairo integration
Version: 8.0.0
Requires: harfbuzz, cairo
Libs: -L${HB_LIB} -lharfbuzz-cairo
Cflags: -I${HB_INCLUDE}
PCEOF
    echo "Created harfbuzz-cairo.pc"
fi

# icu-uc
if [ ! -f "$INSTALL_DIR/lib/pkgconfig/icu-uc.pc" ]; then
    echo "--- Creating icu-uc.pc ---"
    ICU_LIB=$(find "$PIXIEWOOD_DIR" -name "libicuuc.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_LIB")
    ICU_INCLUDE="${PIXIEWOOD_ROOT}/include"
    cat > "$INSTALL_DIR/lib/pkgconfig/icu-uc.pc" << PCEOF
prefix=$INSTALL_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: icu-uc
Description: ICU Unicode support
Version: 75.1
Requires:
Libs: -L${ICU_LIB} -licuuc
Cflags: -I${ICU_INCLUDE}/unicode
PCEOF
    echo "Created icu-uc.pc"
fi

# icu-i18n
if [ ! -f "$INSTALL_DIR/lib/pkgconfig/icu-i18n.pc" ]; then
    echo "--- Creating icu-i18n.pc ---"
    ICU_LIB=$(find "$PIXIEWOOD_DIR" -name "libicui18n.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_LIB")
    ICU_INCLUDE="${PIXIEWOOD_ROOT}/include"
    cat > "$INSTALL_DIR/lib/pkgconfig/icu-i18n.pc" << PCEOF
prefix=$INSTALL_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: icu-i18n
Description: ICU Internationalization support
Version: 75.1
Requires: icu-uc
Libs: -L${ICU_LIB} -licui18n
Cflags: -I${ICU_INCLUDE}/unicode
PCEOF
    echo "Created icu-i18n.pc"
fi

# intl (libintl)
if [ ! -f "$INSTALL_DIR/lib/pkgconfig/intl.pc" ]; then
    echo "--- Creating intl.pc ---"
    INTL_LIB=$(find "$PIXIEWOOD_DIR" -name "libintl.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_LIB")
    INTL_INCLUDE="${PIXIEWOOD_ROOT}/include"
    cat > "$INSTALL_DIR/lib/pkgconfig/intl.pc" << PCEOF
prefix=$INSTALL_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: intl
Description: GNU gettext internationalization library
Version: 0.22.4
Requires:
Libs: -L${INTL_LIB} -lintl
Cflags: -I${INTL_INCLUDE}
PCEOF
    echo "Created intl.pc"
fi

# icu-uc
if [ ! -f "$INSTALL_DIR/lib/pkgconfig/icu-uc.pc" ]; then
    echo "--- Creating icu-uc.pc ---"
    ICU_LIB=$(find "$PIXIEWOOD_DIR" -name "libicuuc.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_LIB")
    ICU_INCLUDE="${PIXIEWOOD_ROOT}/include"
    cat > "$INSTALL_DIR/lib/pkgconfig/icu-uc.pc" << PCEOF
prefix=$INSTALL_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: icu-uc
Description: ICU Unicode support
Version: 75.1
Requires:
Libs: -L${ICU_LIB} -licuuc
Cflags: -I${ICU_INCLUDE}/unicode
PCEOF
    echo "Created icu-uc.pc"
fi

# icu-i18n
if [ ! -f "$INSTALL_DIR/lib/pkgconfig/icu-i18n.pc" ]; then
    echo "--- Creating icu-i18n.pc ---"
    ICU_LIB=$(find "$PIXIEWOOD_DIR" -name "libicui18n.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_LIB")
    ICU_INCLUDE="${PIXIEWOOD_ROOT}/include"
    cat > "$INSTALL_DIR/lib/pkgconfig/icu-i18n.pc" << PCEOF
prefix=$INSTALL_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: icu-i18n
Description: ICU Internationalization support
Version: 75.1
Requires: icu-uc
Libs: -L${ICU_LIB} -licui18n
Cflags: -I${ICU_INCLUDE}/unicode
PCEOF
    echo "Created icu-i18n.pc"
fi

# libpng
if [ ! -f "$INSTALL_DIR/lib/pkgconfig/libpng.pc" ]; then
    echo "--- Creating libpng.pc ---"
    PNG_LIB=$(find "$PIXIEWOOD_DIR" -name "libpng.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_LIB")
    PNG_INCLUDE="${PIXIEWOOD_ROOT}/include"
    cat > "$INSTALL_DIR/lib/pkgconfig/libpng.pc" << PCEOF
prefix=$INSTALL_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: libpng
Description: PNG image format library
Version: 1.6.43
Requires: zlib
Libs: -L${PNG_LIB} -lpng
Cflags: -I${PNG_INCLUDE}
PCEOF
    echo "Created libpng.pc"
fi

# zlib
if [ ! -f "$INSTALL_DIR/lib/pkgconfig/zlib.pc" ]; then
    echo "--- Creating zlib.pc ---"
    ZLIB_LIB=$(find "$PIXIEWOOD_DIR" -name "libz.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_LIB")
    ZLIB_INCLUDE="${PIXIEWOOD_ROOT}/include"
    cat > "$INSTALL_DIR/lib/pkgconfig/zlib.pc" << PCEOF
prefix=$INSTALL_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: zlib
Description: zlib compression library
Version: 1.3
Requires:
Libs: -L${ZLIB_LIB} -lz
Cflags: -I${ZLIB_INCLUDE}
PCEOF
    echo "Created zlib.pc"
fi

# jpeg
if [ ! -f "$INSTALL_DIR/lib/pkgconfig/libjpeg.pc" ]; then
    echo "--- Creating libjpeg.pc ---"
    JPEG_LIB=$(find "$PIXIEWOOD_DIR" -name "libjpeg.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_LIB")
    JPEG_INCLUDE="${PIXIEWOOD_ROOT}/include"
    cat > "$INSTALL_DIR/lib/pkgconfig/libjpeg.pc" << PCEOF
prefix=$INSTALL_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: libjpeg
Description: JPEG image format library
Version: 9e
Requires:
Libs: -L${JPEG_LIB} -ljpeg
Cflags: -I${JPEG_INCLUDE}
PCEOF
    echo "Created libjpeg.pc"
fi

# intl (libintl)
if [ ! -f "$INSTALL_DIR/lib/pkgconfig/intl.pc" ]; then
    echo "--- Creating intl.pc ---"
    INTL_LIB=$(find "$PIXIEWOOD_DIR" -name "libintl.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_LIB")
    INTL_INCLUDE="${PIXIEWOOD_ROOT}/include"
    cat > "$INSTALL_DIR/lib/pkgconfig/intl.pc" << PCEOF
prefix=$INSTALL_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: intl
Description: GNU gettext internationalization library
Version: 0.22.4
Requires:
Libs: -L${INTL_LIB} -lintl
Cflags: -I${INTL_INCLUDE}
PCEOF
    echo "Created intl.pc"
fi

# cairomm-1.16
if [ ! -f "$INSTALL_DIR/lib/pkgconfig/cairomm-1.16.pc" ]; then
    echo "--- Creating cairomm-1.16.pc ---"
    CAIROMM_LIB=$(find "$PIXIEWOOD_DIR" -name "libcairomm-1.16.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_LIB")
    CAIROMM_INCLUDE="${PIXIEWOOD_ROOT}/include"
    cat > "$INSTALL_DIR/lib/pkgconfig/cairomm-1.16.pc" << PCEOF
prefix=$INSTALL_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: cairomm-1.16
Description: C++ wrapper for cairo
Version: 1.18.0
Requires: cairo, sigc++-3.0
Libs: -L${CAIROMM_LIB} -lcairomm-1.16
Cflags: -I${CAIROMM_INCLUDE}/cairomm-1.16 -I${CAIROMM_INCLUDE}/cairomm-1.16/cairomm
PCEOF
    echo "Created cairomm-1.16.pc"
fi

# pangomm-2.48
if [ ! -f "$INSTALL_DIR/lib/pkgconfig/pangomm-2.48.pc" ]; then
    echo "--- Creating pangomm-2.48.pc ---"
    PANGOMM_LIB=$(find "$PIXIEWOOD_DIR" -name "libpangomm-2.48.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_LIB")
    PANGOMM_INCLUDE="${PIXIEWOOD_ROOT}/include"
    cat > "$INSTALL_DIR/lib/pkgconfig/pangomm-2.48.pc" << PCEOF
prefix=$INSTALL_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: pangomm-2.48
Description: C++ wrapper for Pango
Version: 2.54.0
Requires: pango-1.0, glibmm-2.90, cairomm-1.16
Libs: -L${PANGOMM_LIB} -lpangomm-2.48
Cflags: -I${PANGOMM_INCLUDE}/pangomm-2.48 -I${PANGOMM_INCLUDE}/pangomm-2.48/pangomm
PCEOF
    echo "Created pangomm-2.48.pc"
fi

# gdk-pixbuf-2.0
if [ ! -f "$INSTALL_DIR/lib/pkgconfig/gdk-pixbuf-2.0.pc" ]; then
    echo "--- Creating gdk-pixbuf-2.0.pc ---"
    GDKPIXBUF_LIB=$(find "$PIXIEWOOD_DIR" -name "libgdk_pixbuf-2.0.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_LIB")
    GDKPIXBUF_INCLUDE="${PIXIEWOOD_ROOT}/include"
    cat > "$INSTALL_DIR/lib/pkgconfig/gdk-pixbuf-2.0.pc" << PCEOF
prefix=$INSTALL_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: gdk-pixbuf-2.0
Description: Image loading library for GTK+
Version: 2.42.10
Requires: glib-2.0, gobject-2.0, gio-2.0, gmodule-2.0
Libs: -L${GDKPIXBUF_LIB} -lgdk_pixbuf-2.0
Cflags: -I${GDKPIXBUF_INCLUDE}/gdk-pixbuf-2.0
PCEOF
    echo "Created gdk-pixbuf-2.0.pc"
fi

# graphene-1.0
if [ ! -f "$INSTALL_DIR/lib/pkgconfig/graphene-1.0.pc" ]; then
    echo "--- Creating graphene-1.0.pc ---"
    GRAPHENE_LIB=$(find "$PIXIEWOOD_DIR" -name "libgraphene-1.0.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_LIB")
    GRAPHENE_INCLUDE="${PIXIEWOOD_ROOT}/include"
    cat > "$INSTALL_DIR/lib/pkgconfig/graphene-1.0.pc" << PCEOF
prefix=$INSTALL_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: graphene-1.0
Description: Thin layer of graphic data types
Version: 1.10.8
Requires: gobject-2.0, glib-2.0, gio-2.0
Libs: -L${GRAPHENE_LIB} -lgraphene-1.0
Cflags: -I${GRAPHENE_INCLUDE}/graphene-1.0
PCEOF
    echo "Created graphene-1.0.pc"
fi

# sigc++-3.0
if [ ! -f "$INSTALL_DIR/lib/pkgconfig/sigc++-3.0.pc" ]; then
    echo "--- Creating sigc++-3.0.pc ---"
    SIGC_LIB=$(find "$PIXIEWOOD_DIR" -name "libsigc-3.0.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_LIB")
    SIGC_INCLUDE="${PIXIEWOOD_ROOT}/include"
    cat > "$INSTALL_DIR/lib/pkgconfig/sigc++-3.0.pc" << PCEOF
prefix=$INSTALL_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: sigc++-3.0
Description: Typesafe callback framework for C++
Version: 3.6.0
Requires:
Libs: -L${SIGC_LIB} -lsigc-3.0
Cflags: -I${SIGC_INCLUDE}/sigc++-3.0 -I${SIGC_INCLUDE}/sigc++-3.0/sigc++
PCEOF
    echo "Created sigc++-3.0.pc"
fi

# glibmm .pc files
echo "DEBUG: Reached .pc file creation section for glibmm..."
echo "DEBUG: INSTALL_DIR=$INSTALL_DIR"
echo "DEBUG: PIXIEWOOD_DIR=$PIXIEWOOD_DIR"
echo "DEBUG: Checking if $INSTALL_DIR/lib/pkgconfig/ directory exists..."
ls -la "$INSTALL_DIR/lib/pkgconfig/" 2>/dev/null || echo "Directory does not exist, creating..."
mkdir -p "$INSTALL_DIR/lib/pkgconfig/"
echo "DEBUG: Checking if $INSTALL_DIR/lib/pkgconfig/glibmm-2.68.pc exists..."
ls -la "$INSTALL_DIR/lib/pkgconfig/glibmm-2.68.pc" 2>/dev/null || echo "File does not exist"
if [ ! -f "$INSTALL_DIR/lib/pkgconfig/glibmm-2.68.pc" ]; then
    echo "--- Creating glibmm-2.68.pc ---"
    # Library is libglibmm-2.68.so (project name) but we create a 2.68 .pc file for CMake compatibility
    # CMake pkg_check_modules looks for glibmm-2.68
    GLIBMM_LIB=$(find "$PIXIEWOOD_DIR" -name "libglibmm-2.68.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_LIB")
    GLIBMM_INCLUDE="${INSTALL_DIR}/include"
    echo "DEBUG: Writing to $INSTALL_DIR/lib/pkgconfig/glibmm-2.68.pc"
    cat > "$INSTALL_DIR/lib/pkgconfig/glibmm-2.68.pc" << PCEOF
prefix=${INSTALL_DIR}
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: glibmm-2.68
Description: C++ wrapper for GLib
Version: 2.68.0
Requires: glib-2.0, gobject-2.0, gio-2.0, sigc++-3.0
Libs: -L${GLIBMM_LIB} -lglibmm-2.68
Cflags: -I${GLIBMM_INCLUDE}/glibmm-2.90
PCEOF
    echo "Created glibmm-2.68.pc"
    ls -la "$INSTALL_DIR/lib/pkgconfig/glibmm-2.68.pc" || echo "File creation failed"
else
    echo "DEBUG: glibmm-2.68.pc already exists"
fi

# Also create 2.90 version for other packages
if [ ! -f "$INSTALL_DIR/lib/pkgconfig/glibmm-2.90.pc" ]; then
    echo "--- Creating glibmm-2.90.pc ---"
    # Library is libglibmm-2.68.so (project name) but we create a 2.90 .pc file for other packages
    GLIBMM_LIB=$(find "$PIXIEWOOD_DIR" -name "libglibmm-2.68.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_LIB")
    GLIBMM_INCLUDE="${INSTALL_DIR}/include"
    cat > "$INSTALL_DIR/lib/pkgconfig/glibmm-2.90.pc" << PCEOF
prefix=$INSTALL_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: glibmm-2.90
Description: C++ wrapper for GLib
Version: 2.90.0
Requires: glib-2.0, gobject-2.0, gio-2.0, sigc++-3.0
Libs: -L${GLIBMM_LIB} -lglibmm-2.68
Cflags: -I${GLIBMM_INCLUDE}/glibmm-2.90
PCEOF
    echo "Created glibmm-2.90.pc"
    ls -la "$INSTALL_DIR/lib/pkgconfig/glibmm-2.90.pc" || echo "File creation failed"
else
    echo "DEBUG: glibmm-2.90.pc already exists"
fi

echo "DEBUG: Finished creating glibmm .pc files. Checking final state..."
ls -la "$INSTALL_DIR/lib/pkgconfig/glibmm*.pc" 2>/dev/null || echo "No glibmm .pc files found"

# gtk4
if [ ! -f "$INSTALL_DIR/lib/pkgconfig/gtk4.pc" ]; then
    echo "--- Creating gtk4.pc ---"
    GTK4_LIB=$(find "$PIXIEWOOD_DIR" -name "libgtk-4.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_LIB")
    GTK4_INCLUDE="${PIXIEWOOD_ROOT}/include"
    cat > "$INSTALL_DIR/lib/pkgconfig/gtk4.pc" << PCEOF
prefix=$INSTALL_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: gtk4
Description: GTK4 UI toolkit
Version: 4.14.0
Requires: glib-2.0, gobject-2.0, gio-2.0, gmodule-2.0, pango-1.0, cairo, gdk-pixbuf-2.0, graphene-1.0
Libs: -L${GTK4_LIB} -lgtk-4
Cflags: -I${GTK4_INCLUDE}/gtk-4.0
PCEOF
    echo "Created gtk4.pc"
fi

# giomm-2.68
if [ ! -f "$INSTALL_DIR/lib/pkgconfig/giomm-2.68.pc" ]; then
    echo "--- Creating giomm-2.68.pc ---"
    GIOMM_LIB=$(find "$PIXIEWOOD_DIR" -name "libgiomm-2.68.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_LIB")
    GIOMM_INCLUDE="${PIXIEWOOD_ROOT}/include"
    cat > "$INSTALL_DIR/lib/pkgconfig/giomm-2.68.pc" << PCEOF
prefix=$INSTALL_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: giomm-2.68
Description: C++ wrapper for GIO
Version: 2.80.0
Requires: glibmm-2.90, gio-2.0
Libs: -L${GIOMM_LIB} -lgiomm-2.68
Cflags: -I${GIOMM_INCLUDE}/giomm-2.68 -I${GIOMM_INCLUDE}/giomm-2.68/giomm
PCEOF
    echo "Created giomm-2.68.pc"
fi

# gtkmm-4.0
if [ ! -f "$INSTALL_DIR/lib/pkgconfig/gtkmm-4.0.pc" ]; then
    echo "--- Creating gtkmm-4.0.pc ---"
    GTKMM_LIB=$(find "$PIXIEWOOD_DIR" -name "libgtkmm-4.0.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_LIB")
    GTKMM_INCLUDE="${PIXIEWOOD_ROOT}/include"
    cat > "$INSTALL_DIR/lib/pkgconfig/gtkmm-4.0.pc" << PCEOF
prefix=$INSTALL_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: gtkmm-4.0
Description: C++ wrapper for GTK4
Version: 4.14.0
Requires: gtk4, cairomm-1.16, pangomm-2.48, glibmm-2.90, giomm-2.68
Libs: -L${GTKMM_LIB} -lgtkmm-4.0
Cflags: -I${GTKMM_INCLUDE}/gtkmm-4.0 -I${GTKMM_INCLUDE}/gtkmm-4.0/gtkmm
PCEOF
    echo "Created gtkmm-4.0.pc"
fi

# libspelling-1
if [ ! -f "$INSTALL_DIR/lib/pkgconfig/libspelling-1.pc" ]; then
    echo "--- Creating libspelling-1.pc ---"
    SPELL_LIB=$(find "$PIXIEWOOD_DIR" -name "libspelling-1.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_LIB")
    SPELL_INCLUDE="${PIXIEWOOD_ROOT}/include"
    cat > "$INSTALL_DIR/lib/pkgconfig/libspelling-1.pc" << PCEOF
prefix=$INSTALL_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: libspelling-1
Description: Spelling library for GTK
Version: 0.1.0
Requires: glib-2.0, gobject-2.0, gio-2.0, enchant-2
Libs: -L${SPELL_LIB} -lspelling-1
Cflags: -I${SPELL_INCLUDE}/libspelling-1
PCEOF
    echo "Created libspelling-1.pc"
fi

# gtksourceview-5
if [ ! -f "$INSTALL_DIR/lib/pkgconfig/gtksourceview-5.pc" ]; then
    echo "--- Creating gtksourceview-5.pc ---"
    GSV_LIB=$(find "$PIXIEWOOD_DIR" -name "libgtksourceview-5.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_LIB")
    GSV_INCLUDE="${PIXIEWOOD_ROOT}/include"
    cat > "$INSTALL_DIR/lib/pkgconfig/gtksourceview-5.pc" << PCEOF
prefix=$INSTALL_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: gtksourceview-5
Description: Source code editing widget for GTK
Version: 5.12.0
Requires: gtk4, libxml-2.0
Libs: -L${GSV_LIB} -lgtksourceview-5
Cflags: -I${GSV_INCLUDE}/gtksourceview-5
PCEOF
    echo "Created gtksourceview-5.pc"
fi

# enchant-2 (required by libspelling)
if [ ! -f "$INSTALL_DIR/lib/pkgconfig/enchant-2.pc" ]; then
    echo "--- Creating enchant-2.pc ---"
    ENCHANT_LIB=$(find "$PIXIEWOOD_DIR" -name "libenchant-2.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_LIB")
    ENCHANT_INCLUDE="${PIXIEWOOD_ROOT}/include"
    cat > "$INSTALL_DIR/lib/pkgconfig/enchant-2.pc" << PCEOF
prefix=$INSTALL_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: enchant-2
Description: Generic spell checking library
Version: 2.6.0
Requires: glib-2.0, gmodule-2.0
Libs: -L${ENCHANT_LIB} -lenchant-2
Cflags: -I${ENCHANT_INCLUDE}/enchant-2
PCEOF
    echo "Created enchant-2.pc"
fi

# Also create libxml-2.0.pc if missing (needed by libcroco)
export CXXSTDLIB=-lc++_shared

# Boost - create config file
if [ ! -f "$INSTALL_DIR/lib/cmake/Boost-1.19.0/BoostConfig.cmake" ]; then
    echo "--- Creating BoostConfig.cmake ---"
    mkdir -p "$INSTALL_DIR/lib/cmake/Boost-1.19.0"
    BOOST_LIB=$(find "$PIXIEWOOD_DIR" -name "libboost_system.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_LIB")
    BOOST_INCLUDE="${PIXIEWOOD_ROOT}/include"
    cat > "$INSTALL_DIR/lib/cmake/Boost-1.19.0/BoostConfig.cmake" << PCEOF
# Boost CMake configuration for Android cross-compile
# Use absolute path for Android cross-compile
set(_IMPORT_PREFIX "/home/runner/work/inkscape/inkscape/android-install")
set(Boost_VERSION_STRING "1.19.0")
set(Boost_INCLUDE_DIRS "\${_IMPORT_PREFIX}/include")
set(Boost_LIBRARY_DIRS "\${_IMPORT_PREFIX}/lib")
set(Boost_FOUND TRUE)

# Create imported targets for required components
foreach(comp system thread filesystem program_options regex date_time atomic chrono headers)
    if(NOT TARGET Boost::\${comp})
        add_library(Boost::\${comp} INTERFACE IMPORTED)
        set_target_properties(Boost::\${comp} PROPERTIES
            INTERFACE_INCLUDE_DIRECTORIES "\${_IMPORT_PREFIX}/include"
        )
        if(NOT "\${comp}" STREQUAL "headers")
            set_target_properties(Boost::\${comp} PROPERTIES
                INTERFACE_LINK_LIBRARIES "boost_\${comp}"
            )
        endif()
    endif()
endforeach()

# Provide find_package compatibility
set(Boost_LIBRARIES "")
set(Boost_INCLUDE_DIR "\${_IMPORT_PREFIX}/include")
PCEOF
    echo "Created BoostConfig.cmake"
fi

# BoostConfigVersion.cmake - required for version checking
if [ ! -f "$INSTALL_DIR/lib/cmake/Boost-1.19.0/BoostConfigVersion.cmake" ]; then
    echo "--- Creating BoostConfigVersion.cmake ---"
    cat > "$INSTALL_DIR/lib/cmake/Boost-1.19.0/BoostConfigVersion.cmake" << 'PCEOF'
set(PACKAGE_VERSION "1.19.0")

# Check whether the requested version is compatible
if("${PACKAGE_VERSION}" VERSION_LESS "${PACKAGE_FIND_VERSION}")
    set(PACKAGE_VERSION_COMPATIBLE FALSE)
else()
    set(PACKAGE_VERSION_COMPATIBLE TRUE)
    if("${PACKAGE_VERSION}" VERSION_EQUAL "${PACKAGE_FIND_VERSION}")
        set(PACKAGE_VERSION_EXACT TRUE)
    endif()
endif()
PCEOF
    echo "Created BoostConfigVersion.cmake"
fi

# libxslt
if [ ! -f "$INSTALL_DIR/lib/pkgconfig/libxslt.pc" ]; then
    echo "--- Creating libxslt.pc ---"
    XSLT_LIB=$(find "$PIXIEWOOD_DIR" -name "libxslt.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_LIB")
    XSLT_INCLUDE="${PIXIEWOOD_ROOT}/include"
    cat > "$INSTALL_DIR/lib/pkgconfig/libxslt.pc" << PCEOF
prefix=$INSTALL_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: libxslt
Description: XSLT processing library
Version: 1.1.38
Requires: libxml-2.0
Libs: -L${XSLT_LIB} -lxslt
Cflags: -I${XSLT_INCLUDE}/libxslt
PCEOF
    echo "Created libxslt.pc"
fi

# libxml-2.0 (update to include libxml2 for libxslt)
# Already created earlier

# epoxy
if [ ! -f "$INSTALL_DIR/lib/pkgconfig/epoxy.pc" ]; then
    echo "--- Creating epoxy.pc ---"
    EPOXY_LIB=$(find "$PIXIEWOOD_DIR" -name "libepoxy.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_LIB")
    EPOXY_INCLUDE="${PIXIEWOOD_ROOT}/include"
    cat > "$INSTALL_DIR/lib/pkgconfig/epoxy.pc" << PCEOF
prefix=$INSTALL_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: epoxy
Description: OpenGL function pointer management library
Version: 1.5.10
Requires:
Libs: -L${EPOXY_LIB} -lepoxy
Cflags: -I${EPOXY_INCLUDE}
PCEOF
    echo "Created epoxy.pc"
fi

# tiff
if [ ! -f "$INSTALL_DIR/lib/pkgconfig/libtiff.pc" ]; then
    echo "--- Creating libtiff.pc ---"
    TIFF_LIB=$(find "$PIXIEWOOD_DIR" -name "libtiff.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_LIB")
    TIFF_INCLUDE="${PIXIEWOOD_ROOT}/include"
    cat > "$INSTALL_DIR/lib/pkgconfig/libtiff.pc" << PCEOF
prefix=$INSTALL_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: libtiff
Description: TIFF image format library
Version: 4.6.0
Requires: zlib, libjpeg
Libs: -L${TIFF_LIB} -ltiff
Cflags: -I${TIFF_INCLUDE}
PCEOF
    echo "Created libtiff.pc"
fi
# compat ヘッダーはグローバルに強制インクルードしない（NDK ヘッダーと競合するため）
# 必要な箇所で個別にインクルードする
export CXXFLAGS="-DANDROID -fPIC -I$INSTALL_DIR/include -std=c++20"
export CFLAGS="-DANDROID -fPIC -I$INSTALL_DIR/include"
export LDFLAGS="-L$INSTALL_DIR/lib"

echo "=== Inkscape Android Minimal Dependencies Build ==="
echo "Install: $INSTALL_DIR"
echo "Target: $TRIPLE (API $API)"
echo "Jobs: $JOBS"
echo ""

# =========================================================
# Helper functions
# =========================================================
fetch() {
    local name=$1 url=$2
    if [ ! -d "$SRC_DIR/$name" ]; then
        echo "--- Downloading $name ---"
        # Use longer timeout and retry
        curl -sL --connect-timeout 30 --max-time 300 --retry 3 --retry-delay 5 "$url" -o "$SRC_DIR/${name}.tar" || {
            echo "Failed to download $name from $url"; return 1;
        }
        cd $SRC_DIR
        tar xf "${name}.tar" || tar xjf "${name}.tar" || tar xzf "${name}.tar"
        rm -f "${name}.tar"
    fi
}

build_cmake() {
    local name=$1 dir=$2
    shift 2
    echo "--- Building $name (cmake) ---"
    mkdir -p $BUILD_DIR/$name
    cd $BUILD_DIR/$name
    local src_path="$dir"
    if [[ "$dir" != /* ]]; then
        src_path="$SRC_DIR/$dir"
    fi
    # Set PKG_CONFIG_LIBDIR and PKG_CONFIG_PATH for cross-compile pkg-config
    export PKG_CONFIG_LIBDIR="${PIXIEWOOD_DIR}/meson-private:${PIXIEWOOD_DIR}:${INSTALL_DIR}/lib/pkgconfig"
    export PKG_CONFIG_PATH="${PIXIEWOOD_DIR}/meson-private:${PIXIEWOOD_DIR}:${INSTALL_DIR}/lib/pkgconfig"
    export PKG_CONFIG=/usr/bin/pkg-config
    echo "PKG_CONFIG_LIBDIR=$PKG_CONFIG_LIBDIR"
    /usr/bin/pkg-config --list-all 2>/dev/null | grep -E "glib|croco" | head -5 || true
    cmake "$src_path" \
        -G Ninja \
        -DCMAKE_MAKE_PROGRAM=/usr/local/bin/ninja \
        -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_CXX_COMPILER="$CXX" \
        -DCMAKE_AR="$AR" \
        -DCMAKE_STRIP="$STRIP" \
        -DCMAKE_INSTALL_PREFIX=$INSTALL_DIR \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=ON \
        -DCMAKE_C_FLAGS="$CFLAGS" \
        -DCMAKE_CXX_FLAGS="$CXXFLAGS" \
        -DPKG_CONFIG_EXECUTABLE=/usr/bin/pkg-config \
        -DPKG_CONFIG_PATH="${PIXIEWOOD_DIR}/meson-private:${PIXIEWOOD_DIR}:${INSTALL_DIR}/lib/pkgconfig" \
        "$@" 2>&1 | tail -20
    /usr/local/bin/ninja -j$JOBS 2>&1 | tail -20
    /usr/local/bin/ninja install 2>&1 | tail -20
}

# =========================================================
# 1. Boost (headers + minimal libs)
# =========================================================
if [ ! -f "$INSTALL_DIR/lib/libboost_stacktrace_noop.so" ]; then
    echo "--- Building Boost ---"
    BOOST_VER=1.86.0
    fetch boost "https://archives.boost.io/release/$BOOST_VER/source/boost_${BOOST_VER//./_}.tar.gz"

    BOOST_DIR=$(find $SRC_DIR -maxdepth 1 -name "boost_*" -type d | head -1)
    if [ -n "$BOOST_DIR" ]; then
        mkdir -p $INSTALL_DIR/include/boost
        cp -r $BOOST_DIR/boost/* $INSTALL_DIR/include/boost/
        mkdir -p $INSTALL_DIR/lib

        echo "Building boost_stacktrace (noop backend)..."
        $CXX $CXXFLAGS -shared -fPIC \
            $BOOST_DIR/libs/stacktrace/src/noop.cpp \
            -o $INSTALL_DIR/lib/libboost_stacktrace_noop.so \
            $LDFLAGS -Wl,--allow-shlib-undefined

        echo "Building boost_system..."
        $CXX $CXXFLAGS -shared -fPIC \
            $BOOST_DIR/libs/system/src/error_code.cpp \
            -o $INSTALL_DIR/lib/libboost_system.so \
            $LDFLAGS -Wl,--allow-shlib-undefined

        echo "Building boost_thread..."
        $CXX $CXXFLAGS -shared -fPIC \
            $BOOST_DIR/libs/thread/src/pthread/thread.cpp \
            $BOOST_DIR/libs/thread/src/pthread/once.cpp \
            $BOOST_DIR/libs/thread/src/future.cpp \
            -o $INSTALL_DIR/lib/libboost_thread.so \
            $LDFLAGS -Wl,--allow-shlib-undefined -I$BOOST_DIR

        echo "Building boost_chrono..."
        $CXX $CXXFLAGS -shared -fPIC \
            $BOOST_DIR/libs/chrono/src/chrono.cpp \
            $BOOST_DIR/libs/chrono/src/process_cpu_clocks.cpp \
            $BOOST_DIR/libs/chrono/src/thread_clock.cpp \
            -o $INSTALL_DIR/lib/libboost_chrono.so \
            $LDFLAGS -Wl,--allow-shlib-undefined -I$BOOST_DIR

        ln -sf libboost_stacktrace_noop.so $INSTALL_DIR/lib/libboost_stacktrace_basic.so
        ln -sf libboost_stacktrace_noop.so $INSTALL_DIR/lib/libboost_stacktrace_addr2line.so

        cat > $INSTALL_DIR/lib/pkgconfig/boost.pc << PC
prefix=$INSTALL_DIR
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: boost
Description: Boost C++ Libraries
Version: $BOOST_VER
Libs: -L\${libdir} -lboost_system -lboost_filesystem -lboost_thread -lboost_chrono -lboost_stacktrace_noop
Cflags: -I\${includedir}
PC
    fi
fi

# =========================================================
# Ensure glibmm headers are available (use artifact's source)
# =========================================================
if [ ! -d "${INSTALL_DIR}/include/glibmm-2.90/glibmm" ] || [ ! -f "${INSTALL_DIR}/include/glibmm-2.90/glibmm/ustring.h" ]; then
    echo "--- Copying glibmm headers from pixiewood artifact source ---"
    mkdir -p "${INSTALL_DIR}/include/glibmm-2.90/glibmm"
    # Debug: check what's in the artifact source
    echo "DEBUG: Checking artifact source for glibmm..."
    if [ -d "${PIXIEWOOD_SOURCE_DIR}/subprojects/glibmm-2.90.0" ]; then
        echo "DEBUG: Contents of glibmm-2.90.0:"
        ls -la "${PIXIEWOOD_SOURCE_DIR}/subprojects/glibmm-2.90.0/" 2>/dev/null | head -30
    fi
    if [ -d "${PIXIEWOOD_SOURCE_DIR}/subprojects/glibmm-2.90.0/glibmm" ]; then
        echo "DEBUG: Contents of glibmm-2.90.0/glibmm:"
        ls -la "${PIXIEWOOD_SOURCE_DIR}/subprojects/glibmm-2.90.0/glibmm/" 2>/dev/null | head -30
    fi
    # Try multiple possible source directory structures - headers are in glibmm/ subdirectory
    GLIBMM_COPIED=false
    for src_path in \
        "${PIXIEWOOD_SOURCE_DIR}/subprojects/glibmm-2.90.0/glibmm" \
        "${PIXIEWOOD_SOURCE_DIR}/subprojects/glibmm-2.90.0/glibmm/src/glibmm" \
        "${PIXIEWOOD_SOURCE_DIR}/subprojects/glibmm-2.90.0/glibmm/src" \
        "${PIXIEWOOD_SOURCE_DIR}/subprojects/glibmm-2.68/glibmm" \
        "${PIXIEWOOD_SOURCE_DIR}/subprojects/glibmm-2.68/glibmm/src/glibmm" \
        "${PIXIEWOOD_SOURCE_DIR}/subprojects/glibmm-2.68/glibmm/src" \
        "${PIXIEWOOD_SOURCE_DIR}/subprojects/glibmm/glibmm" \
        "${PIXIEWOOD_SOURCE_DIR}/subprojects/glibmm/glibmm/src/glibmm" \
        "${PIXIEWOOD_SOURCE_DIR}/subprojects/glibmm/glibmm/src"; do
        if [ -d "$src_path" ] && [ "$GLIBMM_COPIED" = false ]; then
            cp -r "$src_path"/* "${INSTALL_DIR}/include/glibmm-2.90/glibmm/" 2>/dev/null || true
            echo "Copied glibmm headers from pixiewood artifact source ($src_path) to ${INSTALL_DIR}/include/glibmm-2.90/glibmm"
            GLIBMM_COPIED=true
        fi
    done
    if [ "$GLIBMM_COPIED" = false ]; then
        echo "Warning: glibmm headers not found in any artifact source location"
        echo "--- Searching more broadly in artifact source ---"
        find "${PIXIEWOOD_SOURCE_DIR}" -maxdepth 4 -type d -name "*glibmm*" 2>/dev/null | head -20
        # Try to find headers in any glibmm directory
        find "${PIXIEWOOD_SOURCE_DIR}" -maxdepth 4 -type f -name "ustring.h" 2>/dev/null | head -5
    fi
    ls -la "${INSTALL_DIR}/include/glibmm-2.90/glibmm/" | head -20 || echo "Directory not found or empty"
    
    # Also copy glibmmconfig.h from build directory or create minimal one
    if [ -f "${PIXIEWOOD_DIR}/subprojects/glibmm-2.68/glib/glibmm/glibmmconfig.h" ]; then
        cp "${PIXIEWOOD_DIR}/subprojects/glibmm-2.68/glib/glibmm/glibmmconfig.h" "${INSTALL_DIR}/include/glibmm-2.90/glibmm/" 2>/dev/null || true
        echo "Copied glibmmconfig.h from build directory"
    elif [ -f "${PIXIEWOOD_DIR}/subprojects/glibmm-2.68/glibmm/glibmmconfig.h" ]; then
        mkdir -p "${INSTALL_DIR}/include/glibmm-2.90/glibmm"
        cp "${PIXIEWOOD_DIR}/subprojects/glibmm-2.68/glibmm/glibmmconfig.h" "${INSTALL_DIR}/include/glibmm-2.90/glibmm/" 2>/dev/null || true
        echo "Copied glibmmconfig.h from build directory"
    else
        echo "--- Creating minimal glibmmconfig.h ---"
        mkdir -p "${INSTALL_DIR}/include/glibmm-2.90/glibmm"
        cat > "${INSTALL_DIR}/include/glibmm-2.90/glibmm/glibmmconfig.h" << 'GLIBMM_CONFIG_EOF'
/* glibmmconfig.h - minimal config for Android cross-compile */
#ifndef GLIBMM_CONFIG_H
#define GLIBMM_CONFIG_H

/* Define platform-specific macros */
#define GLIBMM_DISABLE_DEPRECATED

/* For Android NDK */
#define GLIBMM_DISABLE_DEPRECATED_WARNINGS

#endif /* GLIBMM_CONFIG_H */
GLIBMM_CONFIG_EOF
        echo "Created minimal glibmmconfig.h"
fi

fi

# =========================================================
# 2. GSL (scientific library)
# =========================================================
if [ ! -f "$INSTALL_DIR/lib/libgsl.so" ]; then
    echo "--- Building GSL ---"
    GSL_VER=2.8
    fetch gsl "https://ftp.gnu.org/gnu/gsl/gsl-$GSL_VER.tar.gz" || fetch gsl "https://mirror.ibcp.fr/pub/gnu/gsl/gsl-$GSL_VER.tar.gz" || fetch gsl "https://ftpmirror.gnu.org/gsl/gsl-$GSL_VER.tar.gz"
    cd $BUILD_DIR
    mkdir -p gsl-build
    cd gsl-build
    $SRC_DIR/gsl-$GSL_VER/configure --host=$TRIPLE --prefix=$INSTALL_DIR --disable-static --enable-shared \
        CC=$CC CXX=$CXX CFLAGS="$CFLAGS" CXXFLAGS="$CXXFLAGS" LDFLAGS="$LDFLAGS" 2>&1 | tail -10
    make -j$JOBS 2>&1 | tail -10
    make install 2>&1 | tail -10
fi

# =========================================================
# 3. double-conversion
# =========================================================
if [ ! -f "$INSTALL_DIR/lib/libdouble-conversion.so" ]; then
    echo "--- Building double-conversion ---"
    DC_VER=3.3.0
    fetch double-conversion "https://github.com/google/double-conversion/archive/refs/tags/v$DC_VER.tar.gz"
    build_cmake double-conversion "double-conversion-$DC_VER"
fi

# =========================================================
# 4. libcroco (CSS parsing) - SKIP: let Inkscape CMake build it as subproject
# =========================================================
# libcroco is in Inkscape's src/3rdparty/libcroco as a git submodule.
# Inkscape's CMake will build it automatically as part of the main build.
# We just need the .pc files for glib/gobject/gio/gmodule/gthread/libxml2
# which we create above.
echo "--- Skipping libcroco (built by Inkscape CMake) ---"

# =========================================================
# 5. lcms2 (color management) - use autotools
# =========================================================
if [ ! -f "$INSTALL_DIR/lib/liblcms2.so" ]; then
    echo "--- Building lcms2 (autotools) ---"
    LCMS_VER=2.16
    fetch lcms2 "https://github.com/mm2/Little-CMS/archive/refs/tags/lcms$LCMS_VER.tar.gz"
    LCMS_DIR="$SRC_DIR/Little-CMS-lcms2.16"
    if [ -d "$LCMS_DIR" ]; then
        echo "--- Building lcms2 (autotools) ---"
        cd $LCMS_DIR
        ./configure --host=$TRIPLE --prefix=$INSTALL_DIR --disable-static --enable-shared \
            CC=$CC CXX=$CXX CFLAGS="$CFLAGS" CXXFLAGS="$CXXFLAGS" LDFLAGS="$LDFLAGS" 2>&1 | tail -10
        make -j$JOBS 2>&1 | tail -10
        make install 2>&1 | tail -10
    else
        echo "ERROR: lcms2 source not found at $LCMS_DIR"
        exit 1
    fi
fi

# =========================================================
# 6. potrace
# =========================================================
if [ ! -f "$INSTALL_DIR/lib/libpotrace.so" ]; then
    echo "--- Building potrace ---"
    POTRACE_VER=1.16
    # Download potrace source from sourceforge (official source)
    fetch potrace "https://potrace.sourceforge.net/download/1.16/potrace-1.16.tar.gz" || true
    # potrace is included in freetype, skip standalone build for now
fi

echo ""
echo "=== Minimal dependency build complete ==="
ls -la $INSTALL_DIR/lib/*.so 2>/dev/null || true
