// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Android JNI entry points for Inkscape.
 *
 * このファイルは Android でのみコンパイルされ、Java/Kotlin 側の APK が
 * Inkscape ネイティブライブラリをロード・照会するための安定した JNI API を
 * 公開します。
 *
 * 設計方針:
 *   - GTK GUI は Android バックエンドを持たないため、ここで初期化しない。
 *   - Inkscape コア (glibmm/GTK/lib2geom 等) への依存を断ち切り、リンク
 *     エラーや実行時クラッシュを防ぐ。将来 GTK-on-Android が整った段階で、
 *     init() を拡張して Gtk::Application を起動すればよい。
 *   - バージョン文字列は固定値を返す。Inkscape コア側の inkscape-version.h
 *     (version_string 等) への依存は避け、リンク時に未解決シンボルが発生
 *     しないようにする。
 *   - openFile / getDocumentInfo / exportPng は現状ファイルシステム操作のみの
 *     ダミー実装。Inkscape コアリンク後、本実装に置き換える。
 */

#include <jni.h>
#include <string>
#include <fstream>
#include <sys/stat.h>
#include <android/log.h>
#include <cctype>
#include <cstdio>

// ログタグ（__android_log_print で使用）
static const char *kLogTag = "InkscapeJni";

// このモジュール固有のバージョン表示（将来 Inkscape コアから取得するよう拡張可能）
static const char *kInkscapeAndroidVersion = "1.5-dev-android";

// ネイティブライブラリの初期化状態（isNativeReady 用）
static bool gNativeInitialized = false;

// INFO レベルでログを出力するヘルパー
static void logInfo(const char *message)
{
    __android_log_print(ANDROID_LOG_INFO, kLogTag, "%s", message);
}

/**
 * Java の jstring を C++ std::string に変換する。
 *
 * jstr が NULL の場合は空文字列を返す。GetStringUTFChars 失敗時（メモリ不足等で
 * Java 側に例外が pending になっている場合）はその例外をクリアして空文字列を
 * 返し、C++ 側へ例外が漏れないようにする。
 */
static std::string jstringToString(JNIEnv *env, jstring jstr)
{
    if (env == nullptr || jstr == nullptr) {
        return std::string();
    }

    const char *utfChars = env->GetStringUTFChars(jstr, nullptr);
    if (utfChars == nullptr) {
        // GetStringUTFChars が失敗した場合、既に Java 側で OutOfMemoryError 等が
        // スローされている。C++ 例外にはならないが pending 例外をクリアしておく。
        if (env->ExceptionCheck()) {
            env->ExceptionClear();
        }
        return std::string();
    }

    std::string result(utfChars);
    env->ReleaseStringUTFChars(jstr, utfChars);
    return result;
}

/**
 * 指定パスがファイルまたはディレクトリとして存在するかを stat で確認する。
 */
static bool fileExists(const std::string &path)
{
    struct stat st;
    return stat(path.c_str(), &st) == 0;
}

/**
 * パスの拡張子が .svg または .svgz かを大文字小文字を区別せずに簡易チェックする。
 */
static bool isSvgPath(const std::string &path)
{
    std::string lower = path;
    for (char &c : lower) {
        c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    }
    if (lower.size() >= 4 && lower.compare(lower.size() - 4, 4, ".svg") == 0) {
        return true;
    }
    if (lower.size() >= 5 && lower.compare(lower.size() - 5, 5, ".svgz") == 0) {
        return true;
    }
    return false;
}

/**
 * 出力パスの親ディレクトリを再帰的に作成する（exportPng のダミー用）。
 * 親ディレクトリ指定がない場合（カレントディレクトリ）は成功とみなす。
 */
static bool makeParentDirs(const std::string &path)
{
    size_t slash = path.find_last_of("/\\");
    if (slash == std::string::npos || slash == 0) {
        return true;
    }

    std::string parent = path.substr(0, slash);
    struct stat st;
    if (stat(parent.c_str(), &st) == 0) {
        return S_ISDIR(st.st_mode);
    }

    // 親を再帰的に作成してから自分自身を作成
    if (!makeParentDirs(parent)) {
        return false;
    }
    if (mkdir(parent.c_str(), 0755) != 0) {
        // 既に存在する場合は許容（競合状態等）
        if (stat(parent.c_str(), &st) != 0 || !S_ISDIR(st.st_mode)) {
            return false;
        }
    }
    return true;
}

/**
 * JSON 文字列中でエスケープが必要な文字を置換する簡易ヘルパー。
 */
static std::string jsonEscape(const std::string &s)
{
    std::string out;
    out.reserve(s.size() + 2);
    for (char c : s) {
        switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\b': out += "\\b"; break;
            case '\f': out += "\\f"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (static_cast<unsigned char>(c) < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof(buf), "\\u%04x",
                                  static_cast<unsigned char>(c));
                    out += buf;
                } else {
                    out += c;
                }
                break;
        }
    }
    return out;
}

extern "C" {

/**
 * Called automatically when the VM loads the library via System.loadLibrary.
 */
JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved)
{
    (void)vm;
    (void)reserved;
    try {
        logInfo("JNI_OnLoad: Inkscape JNI ライブラリがロードされました");
    } catch (...) {
        // ログ出力失敗時もバージョンは返してロードを続行
    }
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
    try {
        if (gNativeInitialized) {
            logInfo("init: すでに初期化済み");
            return 0;
        }
        gNativeInitialized = true;
        logInfo("init: ネイティブライブラリを初期化しました");
        return 0; // success
    } catch (...) {
        logInfo("init: 予期しない例外が発生しました");
        if (env != nullptr && env->ExceptionCheck()) {
            env->ExceptionClear();
        }
        return -1;
    }
}

/**
 * Return the Inkscape version string to the Java side.
 */
JNIEXPORT jstring JNICALL
Java_org_inkscape_inkscape_InkscapeNative_getVersion(JNIEnv *env, jobject thiz)
{
    (void)thiz;
    try {
        logInfo("getVersion: バージョン文字列を返却します");
        return env->NewStringUTF(kInkscapeAndroidVersion);
    } catch (...) {
        logInfo("getVersion: 予期しない例外が発生しました");
        if (env != nullptr && env->ExceptionCheck()) {
            env->ExceptionClear();
        }
        return env->NewStringUTF("unknown");
    }
}

/**
 * Shut down the Inkscape native library.
 */
JNIEXPORT void JNICALL
Java_org_inkscape_inkscape_InkscapeNative_shutdown(JNIEnv *env, jobject thiz)
{
    (void)env;
    (void)thiz;
    try {
        gNativeInitialized = false;
        logInfo("shutdown: ネイティブライブラリをシャットダウンしました");
    } catch (...) {
        logInfo("shutdown: 予期しない例外が発生しました");
        if (env != nullptr && env->ExceptionCheck()) {
            env->ExceptionClear();
        }
    }
}

/**
 * SVG ファイルが開けるか確認する（現状はファイル存在チェックのみ。
 * 将来 Inkscape コアリンク後、本実装に置き換える）。
 *
 * @param path 開こうとする SVG ファイルのパス
 * @return 存在すれば JNI_TRUE、存在しなければ JNI_FALSE
 */
JNIEXPORT jboolean JNICALL
Java_org_inkscape_inkscape_InkscapeNative_openFile(JNIEnv *env, jobject thiz, jstring path)
{
    (void)thiz;
    try {
        std::string filePath = jstringToString(env, path);
        if (filePath.empty()) {
            logInfo("openFile: パスが空です");
            return JNI_FALSE;
        }

        bool exists = fileExists(filePath);
        logInfo(exists ? "openFile: ファイルが存在します"
                        : "openFile: ファイルが存在しません");
        return exists ? JNI_TRUE : JNI_FALSE;
    } catch (...) {
        logInfo("openFile: 予期しない例外が発生しました");
        if (env != nullptr && env->ExceptionCheck()) {
            env->ExceptionClear();
        }
        return JNI_FALSE;
    }
}

/**
 * SVG ファイルの情報を JSON 形式で返す（現状はファイルサイズ・存在確認のみの
 * ダミー。将来 Inkscape コアリンク後、本実装に置き換える）。
 *
 * 例: {"exists":true,"size":1234,"format":"svg","error":null}
 *
 * @param path 情報を取得したい SVG ファイルのパス
 * @return JSON 形式の情報文字列
 */
JNIEXPORT jstring JNICALL
Java_org_inkscape_inkscape_InkscapeNative_getDocumentInfo(JNIEnv *env, jobject thiz, jstring path)
{
    (void)thiz;
    try {
        std::string filePath = jstringToString(env, path);

        bool exists = false;
        long long size = 0;
        std::string format = "svg";
        std::string errorJson = "null"; // JSON の null（エラーなし）

        if (filePath.empty()) {
            exists = false;
            errorJson = "\"empty path\"";
        } else {
            struct stat st;
            exists = (stat(filePath.c_str(), &st) == 0);
            if (exists) {
                size = static_cast<long long>(st.st_size);
                if (!isSvgPath(filePath)) {
                    format = "unknown";
                }
            } else {
                errorJson = "\"file not found\"";
            }
        }

        std::string json = "{\"exists\":" + std::string(exists ? "true" : "false")
                         + ",\"size\":" + std::to_string(size)
                         + ",\"format\":\"" + jsonEscape(format) + "\""
                         + ",\"error\":" + errorJson + "}";

        logInfo("getDocumentInfo: ドキュメント情報を返却します");
        return env->NewStringUTF(json.c_str());
    } catch (...) {
        logInfo("getDocumentInfo: 予期しない例外が発生しました");
        if (env != nullptr && env->ExceptionCheck()) {
            env->ExceptionClear();
        }
        std::string json = R"({"exists":false,"size":0,"format":null,"error":"internal error"})";
        return env->NewStringUTF(json.c_str());
    }
}

/**
 * SVG を PNG にエクスポートする（現状は入力ファイル存在チェック +
 * 出力ディレクトリ作成のみのダミー。実際のレンダリングは Inkscape コア
 * リンク後に実装する）。
 *
 * @param inputPath  入力 SVG ファイルのパス
 * @param outputPath 出力先 PNG ファイルのパス
 * @param width      出力画像の幅（ピクセル）
 * @param height     出力画像の高さ（ピクセル）
 * @return 準備ができていれば JNI_TRUE、失敗すれば JNI_FALSE
 */
JNIEXPORT jboolean JNICALL
Java_org_inkscape_inkscape_InkscapeNative_exportPng(JNIEnv *env, jobject thiz,
                                                    jstring inputPath, jstring outputPath,
                                                    jint width, jint height)
{
    (void)thiz;
    (void)width;
    (void)height;
    try {
        std::string inPath = jstringToString(env, inputPath);
        std::string outPath = jstringToString(env, outputPath);

        if (inPath.empty()) {
            logInfo("exportPng: 入力パスが空です");
            return JNI_FALSE;
        }
        if (!fileExists(inPath)) {
            logInfo("exportPng: 入力ファイルが存在しません");
            return JNI_FALSE;
        }
        if (outPath.empty()) {
            logInfo("exportPng: 出力パスが空です");
            return JNI_FALSE;
        }

        // 出力ディレクトリを作成（ダミー実装）
        if (!makeParentDirs(outPath)) {
            logInfo("exportPng: 出力ディレクトリの作成に失敗しました");
            return JNI_FALSE;
        }

        logInfo("exportPng: エクスポート準備完了（ダミー実装）");
        return JNI_TRUE;
    } catch (...) {
        logInfo("exportPng: 予期しない例外が発生しました");
        if (env != nullptr && env->ExceptionCheck()) {
            env->ExceptionClear();
        }
        return JNI_FALSE;
    }
}

/**
 * ネイティブライブラリが初期化済みか返す。
 *
 * @return 初期化済みなら JNI_TRUE、そうでなければ JNI_FALSE
 */
JNIEXPORT jboolean JNICALL
Java_org_inkscape_inkscape_InkscapeNative_isNativeReady(JNIEnv *env, jobject thiz)
{
    (void)env;
    (void)thiz;
    try {
        return gNativeInitialized ? JNI_TRUE : JNI_FALSE;
    } catch (...) {
        logInfo("isNativeReady: 予期しない例外が発生しました");
        if (env != nullptr && env->ExceptionCheck()) {
            env->ExceptionClear();
        }
        return JNI_FALSE;
    }
}

} // extern "C"
