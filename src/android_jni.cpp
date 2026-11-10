// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Android JNI entry points for Inkscape.
 *
 * This file is only compiled on Android. It exposes a small, stable JNI API
 * so the Java/Kotlin side of the APK can load and query the Inkscape native
 * library.
 *
 * 設計方針:
 *   - GTK GUI は Android バックエンドを持たないため、ここでは初期化しない。
 *   - Inkscape コア (glibmm/GTK/lib2geom 等) への依存を極力断ち切り、リンク
 *     エラーや実行時クラッシュを防ぐ。将来 GTK-on-Android が整った段階で、
 *     init() を拡張して Gtk::Application を起動すればよい。
 *   - バージョン文字列はここでは固定値を返す。Inkscape コア側の
 *     inkscape-version.h (version_string 等) への依存は避け、リンク時に
 *     未解決シンボルが発生しないようにする。
 */

#include <jni.h>
#include <string>

// このモジュール固有のバージョン表示（将来 Inkscape コアから取得するよう拡張可能）
static const char *kInkscapeAndroidVersion = "1.5-dev-android";

extern "C" {

/**
 * Called automatically when the VM loads the library via System.loadLibrary.
 */
JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved)
{
    (void)vm;
    (void)reserved;
    return JNI_VERSION_1_6;
}

/**
 * Initialise the Inkscape native library.
 * Call this once from Java before using any other native method.
 * @return 0 on success, non-zero on failure / already initialised.
 */
JNIEXPORT jint JNICALL
Java_org_inkscape_inkscape_InkscapeNative_init(JNIEnv *env, jobject thiz)
{
    (void)env;
    (void)thiz;
    return 0; // success
}

/**
 * Return the Inkscape version string to the Java side.
 */
JNIEXPORT jstring JNICALL
Java_org_inkscape_inkscape_InkscapeNative_getVersion(JNIEnv *env, jobject thiz)
{
    (void)thiz;
    return env->NewStringUTF(kInkscapeAndroidVersion);
}

/**
 * Shut down the Inkscape native library.
 */
JNIEXPORT void JNICALL
Java_org_inkscape_inkscape_InkscapeNative_shutdown(JNIEnv *env, jobject thiz)
{
    (void)env;
    (void)thiz;
}

} // extern "C"
