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

# Global PKG_CONFIG_PATH for all builds
export PKG_CONFIG_PATH="${PIXIEWOOD_DIR}/meson-private:${PIXIEWOOD_DIR}:${INSTALL_DIR}/lib/pkgconfig"
# PKG_CONFIG_LIBDIR tells pkg-config to ONLY look in cross-compile directories
export PKG_CONFIG_LIBDIR="${PIXIEWOOD_DIR}/meson-private:${PIXIEWOOD_DIR}:${INSTALL_DIR}/lib/pkgconfig"

# Copy pixiewood pkg-config files FIRST, before any dependency builds
if [ -n "$PIXIEWOOD_DIR" ] && [ -d "$PIXIEWOOD_DIR" ]; then
    echo "--- Copying pixiewood pkg-config files ---"
    echo "Searching for .pc files in $PIXIEWOOD_DIR"
    find "$PIXIEWOOD_DIR" -name "*.pc" -exec echo "Found: {}" \; -exec cp {} $INSTALL_DIR/lib/pkgconfig/ \; 2>/dev/null || true
    echo "Installed .pc files:"
    ls -la $INSTALL_DIR/lib/pkgconfig/ | head -20
fi

# If no .pc files were found, create minimal .pc files for critical dependencies
# This is needed because pixiewood may not install .pc files
if [ ! -f "$INSTALL_DIR/lib/pkgconfig/glib-2.0.pc" ]; then
    echo "--- Creating minimal .pc files for cross-compile dependencies ---"
    
    # Get library paths from pixiewood build output
    PIXIEWOOD_LIB="$PIXIEWOOD_DIR"
    PIXIEWOOD_INCLUDE="$PIXIEWOOD_DIR/../root/include"
    
    # Find actual library locations
    GLIB_LIB=$(find "$PIXIEWOOD_DIR" -name "libglib-2.0.so" 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_LIB")
    GLIB_INCLUDE=$(find "$PIXIEWOOD_DIR/../root" -name "glib.h" 2>/dev/null | head -1 | xargs dirname 2>/dev/null | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_INCLUDE")
    
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
    LIBXML_INCLUDE=$(find "$PIXIEWOOD_DIR/../root" -name "libxml" -type d 2>/dev/null | head -1 | xargs dirname 2>/dev/null || echo "$PIXIEWOOD_INCLUDE")
    
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

# C++ 標準ライブラリ
export CXXSTDLIB=-lc++_shared
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
# 4. libcroco (CSS parsing) - use CMake from gitlab.com/inkscape/libcroco
# =========================================================
if [ ! -f "$INSTALL_DIR/lib/libcroco-0.6.so" ]; then
    echo "--- Building libcroco ---"
    if [ ! -d "$SRC_DIR/libcroco" ]; then
        git clone --depth 1 https://gitlab.com/inkscape/libcroco.git $SRC_DIR/libcroco
    fi
    cd $BUILD_DIR
    mkdir -p libcroco-build
    cd libcroco-build
    
    # Set cross-compile pkg-config environment directly
    # PKG_CONFIG_PATH is already set globally with pixiewood .pc files
    # PKG_CONFIG_LIBDIR tells pkg-config to ONLY look in cross-compile dirs
    export PKG_CONFIG_LIBDIR="${PKG_CONFIG_PATH}"
    export PKG_CONFIG_PATH="${PKG_CONFIG_PATH}"
    echo "Using host pkg-config with cross-compile PKG_CONFIG_LIBDIR: $PKG_CONFIG_LIBDIR"
    echo "PKG_CONFIG_PATH=$PKG_CONFIG_PATH"
    /usr/bin/pkg-config --list-all 2>/dev/null | grep -E "glib|croco" | head -5 || true
    export PKG_CONFIG=/usr/bin/pkg-config
    
    cmake "$SRC_DIR/libcroco" \
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
        2>&1 | tail -20
    /usr/local/bin/ninja -j$JOBS 2>&1 | tail -20
    /usr/local/bin/ninja install 2>&1 | tail -20
fi

# =========================================================
# 5. lcms2 (color management)
# =========================================================
if [ ! -f "$INSTALL_DIR/lib/liblcms2.so" ]; then
    echo "--- Building lcms2 ---"
    LCMS_VER=2.16
    fetch lcms2 "https://github.com/mm2/Little-CMS/archive/refs/tags/lcms$LCMS_VER.tar.gz"
    build_cmake lcms2 "Little-CMS-lcms$LCMS_VER"
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
