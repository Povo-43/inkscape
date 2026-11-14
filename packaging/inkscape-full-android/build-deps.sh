#!/bin/bash
set -euo pipefail

# =========================================================
# Inkscape Android 依存ライブラリクロスコンパイルスクリプト
# Android NDK r27b で x86_64 / arm64 向けに依存ライブラリをビルドする
#
# 使用方法: bash build-deps.sh <install_dir> <android_ndk>
# =========================================================

INSTALL_DIR=${1:-/tmp/inkscape-deps-install}
NDK_HOME=${2:-/opt/android-ndk-r27b}
API=${3:-31}

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

# C++ 標準ライブラリ
export CXXSTDLIB=-lc++_shared
# compat ヘッダーを強制インクルードして C++20 機能を提供
export COMPAT_INCLUDES="-include $INSTALL_DIR/include/android_fix.h -include $INSTALL_DIR/include/atomic_ref_compat.h -include $INSTALL_DIR/include/format -include $INSTALL_DIR/include/stop_token"
export CXXFLAGS="-DANDROID -fPIC -I$INSTALL_DIR/include -std=c++20 $COMPAT_INCLUDES"
export CFLAGS="-DANDROID -fPIC -I$INSTALL_DIR/include"
export LDFLAGS="-L$INSTALL_DIR/lib"

echo "=== Inkscape Android Dependencies Build ==="
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

build_meson() {
    local name=$1 dir=$2
    shift 2
    echo "--- Building $name (meson) ---"
    cd $BUILD_DIR
    meson setup $BUILD_DIR/$name $SRC_DIR/$dir \
        --prefix=$INSTALL_DIR \
        --buildtype=release \
        -Ddefault_library=shared \
        "$@" 2>&1 | tail -5
    ninja -C $BUILD_DIR/$name -j$JOBS 2>&1 | tail -5
    ninja -C $BUILD_DIR/$name install 2>&1 | tail -5
}

build_cmake() {
    local name=$1 dir=$2
    shift 2
    echo "--- Building $name (cmake) ---"
    mkdir -p $BUILD_DIR/$name
    cd $BUILD_DIR/$name
    # dir が絶対パスの場合はそのまま、相対パスの場合は SRC_DIR から
    local src_path="$dir"
    if [[ "$dir" != /* ]]; then
        src_path="$SRC_DIR/$dir"
    fi
    cmake "$src_path" \
        -DCMAKE_TOOLCHAIN_FILE=$NDK_HOME/build/cmake/android.toolchain.cmake \
        -DANDROID_ABI=$TARGET_ARCH \
        -DANDROID_PLATFORM=android-$API \
        -DCMAKE_INSTALL_PREFIX=$INSTALL_DIR \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=ON \
        -DCMAKE_C_FLAGS="$CFLAGS" \
        -DCMAKE_CXX_FLAGS="$CXXFLAGS" \
        "$@" 2>&1 | tail -5
    make -j$JOBS 2>&1 | tail -5
    make install 2>&1 | tail -5
}

build_autotools() {
    local name=$1 dir=$2
    shift 2
    echo "--- Building $name (autotools) ---"
    cd $SRC_DIR/$dir
    ./configure --host=$TRIPLE --prefix=$INSTALL_DIR --disable-static --enable-shared \
        CC=$CC CXX=$CXX CFLAGS="$CFLAGS" CXXFLAGS="$CXXFLAGS" LDFLAGS="$LDFLAGS" \
        "$@" 2>&1 | tail -5
    make -j$JOBS 2>&1 | tail -5
    make install 2>&1 | tail -5
}

# =========================================================
# 1. 2geom (geometry library) - critical for Inkscape
# =========================================================
if [ ! -f "$INSTALL_DIR/lib/lib2geom.so" ]; then
    # Use in-tree 2geom (submodule) - GITHUB_WORKSPACE から参照
    INKSCAPE_SRC=${INKSCAPE_SRC:-$GITHUB_WORKSPACE}
    if [ -d "$INKSCAPE_SRC/src/3rdparty/2geom" ]; then
        echo "--- Building 2geom (from in-tree source) ---"
        build_cmake 2geom "$INKSCAPE_SRC/src/3rdparty/2geom" \
            -D2GEOM_TESTING=OFF \
            -D2GEOM_BUILD_SHARED=ON
    else
        echo "ERROR: 2geom source not found at $INKSCAPE_SRC/src/3rdparty/2geom"
        exit 1
    fi
fi

# =========================================================
# 2. Boost (headers + stacktrace, system, thread)
# =========================================================
if [ ! -f "$INSTALL_DIR/lib/libboost_stacktrace_noop.so" ]; then
    echo "--- Building Boost ---"
    BOOST_VER=1.86.0
    fetch boost "https://archives.boost.io/release/$BOOST_VER/source/boost_${BOOST_VER//./_}.tar.gz"

    BOOST_DIR=$(find $SRC_DIR -maxdepth 1 -name "boost_*" -type d | head -1)
    if [ -n "$BOOST_DIR" ]; then
        # Copy headers
        mkdir -p $INSTALL_DIR/include/boost
        cp -r $BOOST_DIR/boost/* $INSTALL_DIR/include/boost/

        # Build libraries manually (avoid b2 complexities)
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

        echo "Building boost_filesystem..."
        $CXX $CXXFLAGS -shared -fPIC \
            $BOOST_DIR/libs/filesystem/src/operations.cpp \
            $BOOST_DIR/libs/filesystem/src/path.cpp \
            $BOOST_DIR/libs/filesystem/src/codecvt_error_category.cpp \
            $BOOST_DIR/libs/filesystem/src/directory.cpp \
            $BOOST_DIR/libs/filesystem/src/exception.cpp \
            $BOOST_DIR/libs/filesystem/src/path_traits.cpp \
            $BOOST_DIR/libs/filesystem/src/portability.cpp \
            $BOOST_DIR/libs/filesystem/src/unique_path.cpp \
            $BOOST_DIR/libs/filesystem/src/utf8_codecvt_facet.cpp \
            -o $INSTALL_DIR/lib/libboost_filesystem.so \
            $LDFLAGS -Wl,--allow-shlib-undefined -I$BOOST_DIR

        # Symlinks
        ln -sf libboost_stacktrace_noop.so $INSTALL_DIR/lib/libboost_stacktrace_basic.so
        ln -sf libboost_stacktrace_noop.so $INSTALL_DIR/lib/libboost_stacktrace_addr2line.so

        # pkg-config
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
# 3. GSL (scientific library)
# =========================================================
if [ ! -f "$INSTALL_DIR/lib/libgsl.so" ]; then
    echo "--- Building GSL ---"
    GSL_VER=2.8
    fetch gsl "https://ftp.gnu.org/gnu/gsl/gsl-$GSL_VER.tar.gz"
    build_autotools gsl "gsl-$GSL_VER" --without-external-blas || {
        # Fallback: use cmake
        build_cmake gsl "gsl-$GSL_VER"
    }
fi

# =========================================================
# 4. double-conversion
# =========================================================
if [ ! -f "$INSTALL_DIR/lib/libdouble-conversion.so" ]; then
    echo "--- Building double-conversion ---"
    DC_VER=3.3.0
    fetch double-conversion "https://github.com/google/double-conversion/archive/refs/tags/v$DC_VER.tar.gz"
    build_cmake double-conversion "double-conversion-$DC_VER"
fi

# =========================================================
# 5. libcroco (CSS parsing)
# =========================================================
if [ ! -f "$INSTALL_DIR/lib/libcroco-0.6.so" ]; then
    echo "--- Building libcroco ---"
    if [ ! -d "$SRC_DIR/libcroco" ]; then
        git clone --depth 1 https://gitlab.com/inkscape/libcroco.git $SRC_DIR/libcroco
    fi
    build_autotools libcroco "libcroco"
fi

# =========================================================
# 6. libdepixelize
# =========================================================
if [ ! -f "$INSTALL_DIR/lib/libdepixelize.so" ]; then
    echo "--- Building libdepixelize ---"
    if [ ! -d "$SRC_DIR/libdepixelize" ]; then
        git clone --depth 1 https://gitlab.com/inkscape/devel/libdepixelize.git $SRC_DIR/libdepixelize
    fi
    build_cmake libdepixelize "libdepixelize" \
        -D2Geom_DIR="$INSTALL_DIR/lib/cmake/2geom"
fi

# =========================================================
# 7. libadaptagrams
# =========================================================
echo "--- Building libadaptagrams ---"
# adaptagrams is usually built as part of Inkscape's 3rdparty

# =========================================================
# 8. libuemf
# =========================================================
if [ ! -f "$INSTALL_DIR/lib/libuemf.so" ]; then
    echo "--- Building libuemf ---"
    if [ ! -d "$SRC_DIR/libuemf" ]; then
        git clone --depth 1 https://gitlab.com/inkscape/devel/libuemf.git $SRC_DIR/libuemf
    fi
    build_cmake libuemf "libuemf"
fi

echo ""
echo "=== Dependency build complete ==="
ls -la $INSTALL_DIR/lib/*.so
