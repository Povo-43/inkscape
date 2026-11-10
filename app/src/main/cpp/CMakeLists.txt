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

# リンク対象なし。Inkscape コア (GTK/glibmm/lib2geom 等) は Android バックエンドを
# 持たないため、ここではリンクしない。スタンドアロン JNI ライブラリとして
# ビルドし、リンクエラー・実行時クラッシュを防ぐ。

# 出力ファイル名：PREFIX "" で lib プレフィックスを抑制し、
# Java 側の System.loadLibrary("inkscape-jni") に対応させる（libinkscape-jni.so）。
set_target_properties(inkscape-jni PROPERTIES
    PREFIX ""
    OUTPUT_NAME "inkscape-jni"
)

# Gradle の externalNativeBuild はこの .so を自動検出し、
# APK の lib/<ABI>/ 以下にパッケージする（jniLibs と整合）。
