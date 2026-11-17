#!/bin/bash
set -euo pipefail

# =========================================================
# Inkscape Android 依存ライブラリクロスコンパイルスクリプト
# 最小限の依存のみビルドし、Inkscape CMake で残りをビルドさせる
#
# 使用方法: bash build-deps.sh <install_dir> <android_ndk> <api> [pixiewood_dir]
# =========================================================

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
PIXIEWOOD_ROOT="${PIXIEWOOD_DIR}/root"
PIXIEWOOD_LIB="${PIXIEWOOD_DIR}"

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
    PIXIEWOOD_INCLUDE="${PIXIEWOOD_ROOT}/include"
    
    # Find actual library locations
    GLIB_LIB=$(find "$PIXIEWOOD_DIR" -name "libglib-2.0.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_LIB")
    # glib.h is at ${PIXIEWOOD_ROOT}/include/glib-2.0/glib.h
    GLIB_INCLUDE="${PIXIEWOOD_ROOT}/include"
    
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
    
    # Copy Freetype headers from pixiewood to our include directory
    if [ -d "${PIXIEWOOD_ROOT}/include/freetype2" ]; then
        echo "--- Copying Freetype headers from pixiewood ---"
        mkdir -p "${INSTALL_DIR}/include/freetype2"
        cp -r "${PIXIEWOOD_ROOT}/include/freetype2"/* "${INSTALL_DIR}/include/freetype2/" 2>/dev/null || true
        echo "Copied Freetype headers to ${INSTALL_DIR}/include/freetype2"
    else
        echo "Warning: Freetype headers not found in pixiewood at ${PIXIEWOOD_ROOT}/include/freetype2"
        # Create a symlink to the system freetype2 if available
        if [ -d "/usr/include/freetype2" ]; then
            mkdir -p "${INSTALL_DIR}/include/freetype2"
            cp -r /usr/include/freetype2/* "${INSTALL_DIR}/include/freetype2/" 2>/dev/null || true
        fi
    fi
    
    # Create symlink for freetype2 in include (some CMake scripts expect this)
    if [ ! -e "${INSTALL_DIR}/include/freetype2" ] && [ -d "/usr/include/freetype2" ]; then
        mkdir -p "${INSTALL_DIR}/include/freetype2"
        cp -r /usr/include/freetype2/* "${INSTALL_DIR}/include/freetype2/" 2>/dev/null || true
    fi
    
    # Copy glib headers from pixiewood to our include directory
    # The subprojects are in the source directory: packaging/android-gtkmm4/subprojects/
    # PIXIEWOOD_DIR is the build dir (.pixiewood/bin-aarch64), source is PIXIEWOOD_DIR/../..
    PIXIEWOOD_SOURCE_DIR="${PIXIEWOOD_DIR}/../.."
    
    echo "--- Searching for glib headers in pixiewood ---"
    echo "PIXIEWOOD_DIR=${PIXIEWOOD_DIR}"
    echo "PIXIEWOOD_ROOT=${PIXIEWOOD_ROOT}"
    echo "PIXIEWOOD_SOURCE_DIR=${PIXIEWOOD_SOURCE_DIR}"
    ls -la "${PIXIEWOOD_SOURCE_DIR}/subprojects/glib/" 2>/dev/null || echo "glib subproject not found"
    ls -la "${PIXIEWOOD_SOURCE_DIR}/subprojects/glib/glib" 2>/dev/null || echo "glib/glib not found"
    ls -la "${PIXIEWOOD_SOURCE_DIR}/subprojects/glib/glib/glib" 2>/dev/null || echo "glib/glib/glib not found"
    ls -la "${PIXIEWOOD_ROOT}/include/" 2>/dev/null || echo "root/include not found"
    
    # The glib source is in the source directory subprojects/glib/glib/
    # The headers are in glib/glib/ directory
    if [ -d "${PIXIEWOOD_SOURCE_DIR}/subprojects/glib/glib" ]; then
        echo "--- Copying glib headers from pixiewood source directory ---"
        mkdir -p "${INSTALL_DIR}/include/glib-2.0"
        # Copy the main glib headers (they're in glib/glib/)
        cp -r "${PIXIEWOOD_SOURCE_DIR}/subprojects/glib/glib"/* "${INSTALL_DIR}/include/glib-2.0/" 2>/dev/null || true
        # Also copy the generated headers from the build directory if they exist
        if [ -d "${PIXIEWOOD_DIR}/subprojects/glib/glib/generated" ]; then
            cp -r "${PIXIEWOOD_DIR}/subprojects/glib/glib/generated"/* "${INSTALL_DIR}/include/glib-2.0/" 2>/dev/null || true
        fi
        # The glib-2.0 internal headers are in a subdirectory
        if [ -d "${PIXIEWOOD_SOURCE_DIR}/subprojects/glib/glib/glib" ]; then
            cp -r "${PIXIEWOOD_SOURCE_DIR}/subprojects/glib/glib/glib"/* "${INSTALL_DIR}/include/glib-2.0/" 2>/dev/null || true
        fi
        echo "Copied glib headers to ${INSTALL_DIR}/include/glib-2.0"
    elif [ -d "${PIXIEWOOD_ROOT}/include/glib-2.0" ]; then
        echo "--- Copying glib headers from pixiewood root ---"
        mkdir -p "${INSTALL_DIR}/include/glib-2.0"
        cp -r "${PIXIEWOOD_ROOT}/include/glib-2.0"/* "${INSTALL_DIR}/include/glib-2.0/" 2>/dev/null || true
        echo "Copied glib headers to ${INSTALL_DIR}/include/glib-2.0"
    else
        echo "Warning: glib-2.0 headers not found in pixiewood at ${PIXIEWOOD_ROOT}/include/glib-2.0 or ${PIXIEWOOD_SOURCE_DIR}/subprojects/glib/glib"
    fi
    
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
fi

# Also create libxml-2.0.pc if missing (needed by libcroco)
if [ ! -f "$INSTALL_DIR/lib/pkgconfig/libxml-2.0.pc" ]; then
    echo "--- Creating libxml-2.0.pc ---"
    
    # Find libxml2 from pixiewood
    LIBXML_LIB=$(find "$PIXIEWOOD_DIR" -name "libxml2.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_LIB")
    # libxml is at ${PIXIEWOOD_DIR}/root/include/libxml2
    LIBXML_INCLUDE="${PIXIEWOOD_ROOT}/include"
    
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
    FT_INCLUDE="${PIXIEWOOD_ROOT}/include"
    cat > "$INSTALL_DIR/lib/pkgconfig/freetype2.pc" << PCEOF
prefix=$INSTALL_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: freetype2
Description: FreeType 2 font engine
Version: 2.13.0
Requires:
Libs: -L${FT_LIB} -lfreetype
Cflags: -I${FT_INCLUDE}/freetype2
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
Requires: pango-1.0, glibmm-2.68, cairomm-1.16
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

# glibmm-2.68
if [ ! -f "$INSTALL_DIR/lib/pkgconfig/glibmm-2.68.pc" ]; then
    echo "--- Creating glibmm-2.68.pc ---"
    GLIBMM_LIB=$(find "$PIXIEWOOD_DIR" -name "libglibmm-2.68.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_LIB")
    GLIBMM_INCLUDE="${PIXIEWOOD_ROOT}/include"
    cat > "$INSTALL_DIR/lib/pkgconfig/glibmm-2.68.pc" << PCEOF
prefix=$INSTALL_DIR
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: glibmm-2.68
Description: C++ wrapper for GLib
Version: 2.80.0
Requires: glib-2.0, gobject-2.0, gio-2.0, sigc++-3.0
Libs: -L${GLIBMM_LIB} -lglibmm-2.68
Cflags: -I${GLIBMM_INCLUDE}/glibmm-2.68 -I${GLIBMM_INCLUDE}/glibmm-2.68/glibmm
PCEOF
    echo "Created glibmm-2.68.pc"
fi

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
Requires: glibmm-2.68, gio-2.0
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
Requires: gtk4, cairomm-1.16, pangomm-2.48, glibmm-2.68, giomm-2.68
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
        curl -sL "$url" -o "$SRC_DIR/${name}.tar" || {
            echo "Failed to download $name"; return 1;
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
# 2. GSL (scientific library)
# =========================================================
if [ ! -f "$INSTALL_DIR/lib/libgsl.so" ]; then
    echo "--- Building GSL ---"
    GSL_VER=2.8
    fetch gsl "https://ftp.gnu.org/gnu/gsl/gsl-$GSL_VER.tar.gz"
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
    fetch potrace "https://github.com/freetype/freetype/archive/refs/tags/VER-2-16-1.tar.gz" || true
    # potrace is included in freetype, skip standalone build
fi

echo ""
echo "=== Minimal dependency build complete ==="
ls -la $INSTALL_DIR/lib/*.so 2>/dev/null || true
