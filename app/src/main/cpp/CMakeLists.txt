cmake_minimum_required(VERSION 3.22.1)

# app/src/main/cpp/CMakeLists.txt
# Inkscape for Android — JNI ラッパーモジュール用 CMake 設定

project(inkscape-android-jni LANGUAGES C CXX)

# C++17 を有効化
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# ---------------------------------------------------------------------------
# 注意: ANDROID_ABI, ANDROID_PLATFORM, ANDROID_STL, ANDROID_TOOLCHAIN などの
# Android ツールチェーン変数は Gradle (externalNativeBuild) が自動で設定する
# ため、ここでは上書きしない。（CMAKE_SYSTEM_NAME=Android 等は設定済み前提）
# ---------------------------------------------------------------------------

# JNI ラッパー実装ソース。
# この CMakeLists.txt は app/src/main/cpp/ に配置されるため、
# リポジトリトップレベルの src/android_jni.cpp は 4 つ上のディレクトリにある。
add_library(inkscape-jni SHARED
    ../../../../src/android_jni.cpp
)

# ヘッダインクルードパス：リポジトリトップレベルの src/
target_include_directories(inkscape-jni PRIVATE
    ../../../../src
)

# ---------------------------------------------------------------------------
# SVG レンダラー (Rust / resvg) の静的ライブラリを取り込む。
#
# Rust 側は Gradle の cargoBuild* タスクが ABI ごとにビルドし、
#   <buildDir>/rust/<ABI>/libinkscape_svg_renderer.a
# に配置する。INKSCAPE_RUST_LIB_DIR は app/build.gradle から渡される。
# ---------------------------------------------------------------------------
if(NOT DEFINED INKSCAPE_RUST_LIB_DIR)
    # Gradle 経由でない場合のフォールバック（事前ビルド済みライブラリ）
    set(INKSCAPE_RUST_LIB_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../rust/prebuilt")
endif()

set(RUST_RENDERER_LIB
    "${INKSCAPE_RUST_LIB_DIR}/${ANDROID_ABI}/libinkscape_svg_renderer.a")

if(EXISTS "${RUST_RENDERER_LIB}")
    add_library(inkscape_svg_renderer STATIC IMPORTED)
    set_target_properties(inkscape_svg_renderer PROPERTIES
        IMPORTED_LOCATION "${RUST_RENDERER_LIB}")
    message(STATUS "SVG renderer: ${RUST_RENDERER_LIB}")
else()
    message(FATAL_ERROR
        "SVG レンダラーの静的ライブラリが見つかりません: ${RUST_RENDERER_LIB}\n"
        "Gradle の cargoBuild タスクを先に実行してください "
        "(例: ./gradlew :app:assembleDebug)。")
endif()

# Android システムライブラリにリンク（__android_log_print 等のため）。
target_link_libraries(inkscape-jni
    inkscape_svg_renderer
    log
    android
    dl
    m
)

# ---- 将来の inkscape_base リンクに備えた準備 ----
# Inkscape コア（GTK4 + glibmm 等）の Android バックエンドが整備され、
# inkscape_base ライブラリをリンク可能になったら、下記のコメントを有効化する。
# target_link_libraries(inkscape-jni inkscape_base)
#
# 現時点では GTK4/glibmm 等の依存が Android NDK 向けに整備されていないため、
# SVG の解析・描画は resvg ベースのレンダラーで行う。

# 出力ファイル名：PREFIX "" で lib プレフィックスを抑制し、
# Java 側の System.loadLibrary("inkscape-jni") に対応させる（libinkscape-jni.so）。
set_target_properties(inkscape-jni PROPERTIES
    PREFIX ""
    OUTPUT_NAME "inkscape-jni"
)

# Gradle の externalNativeBuild はこの .so を自動検出し、
# APK の lib/<ABI>/ 以下にパッケージする（jniLibs と整合）。
