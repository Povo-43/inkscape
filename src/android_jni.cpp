// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Android JNI entry points for Inkscape.
 *
 * このファイルは Android でのみコンパイルされ、Java/Kotlin 側の APK が
 * Inkscape ネイティブライブラリをロード・操作するための安定した JNI API を
 * 公開します。
 *
 * 設計方針:
 *   - Inkscape の GUI コア (GTK4/gtkmm4/glibmm) は Android バックエンドを
 *     持たないため、GUI はここでは初期化しない。将来 GTK-on-Android が
 *     整った段階で init() を拡張する。
 *   - SVG の解析・ラスタライズには resvg (純 Rust 実装の SVG レンダラー) を
 *     静的リンクして使用する。Rust 側は C ABI のみを公開する
 *     (app/src/main/rust/svg-renderer)。
 *   - 元の Inkscape C++ コードには一切手を加えない。Android 固有コードは
 *     このファイルと Rust クレート、Gradle/CMake 設定のみ。
 */

#include <jni.h>

#include <android/log.h>

#include <cctype>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <sys/stat.h>
#include <vector>

// ---------------------------------------------------------------------------
// Rust レンダラー (app/src/main/rust/svg-renderer) が公開する C ABI
// ---------------------------------------------------------------------------
extern "C" {
/// レンダラーのバージョン文字列 (静的領域、解放不要)
const char *inkscape_renderer_version(void);

/// SVG バイト列を PNG にラスタライズする。失敗時は NULL。
unsigned char *inkscape_render_png(const unsigned char *data, size_t len,
                                   unsigned int width, unsigned int height,
                                   size_t *out_len);

/// SVG のドキュメント情報を JSON 文字列で返す。失敗時は NULL。
char *inkscape_svg_info(const unsigned char *data, size_t len);

/// 直近のエラー文字列を返す (要 inkscape_free_string)。
char *inkscape_last_error(void);

/// inkscape_render_png が確保したバッファを解放する。
void inkscape_free(unsigned char *ptr, size_t len);

/// Rust 側が確保した文字列を解放する。
void inkscape_free_string(char *ptr);
}

// ログタグ（__android_log_print で使用）
static const char *kLogTag = "InkscapeJni";

// このモジュール固有のバージョン表示
static const char *kInkscapeAndroidVersion = "1.5-dev-android";

// ネイティブライブラリの初期化状態（isNativeReady 用）
static bool gNativeInitialized = false;

// INFO レベルでログを出力するヘルパー
static void logInfo(const char *message)
{
    __android_log_print(ANDROID_LOG_INFO, kLogTag, "%s", message);
}

static void logError(const std::string &message)
{
    __android_log_print(ANDROID_LOG_ERROR, kLogTag, "%s", message.c_str());
}

/**
 * Java の jstring を C++ std::string に変換する。
 */
static std::string jstringToString(JNIEnv *env, jstring jstr)
{
    if (env == nullptr || jstr == nullptr) {
        return std::string();
    }

    const char *utfChars = env->GetStringUTFChars(jstr, nullptr);
    if (utfChars == nullptr) {
        if (env->ExceptionCheck()) {
            env->ExceptionClear();
        }
        return std::string();
    }

    std::string result(utfChars);
    env->ReleaseStringUTFChars(jstr, utfChars);
    return result;
}

/// 指定パスがファイルまたはディレクトリとして存在するかを stat で確認する。
static bool fileExists(const std::string &path)
{
    struct stat st;
    return stat(path.c_str(), &st) == 0;
}

/// パスの拡張子が .svg / .svgz かを大文字小文字を区別せずに判定する。
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

/// 出力パスの親ディレクトリを再帰的に作成する。
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

    if (!makeParentDirs(parent)) {
        return false;
    }
    if (mkdir(parent.c_str(), 0755) != 0) {
        if (stat(parent.c_str(), &st) != 0 || !S_ISDIR(st.st_mode)) {
            return false;
        }
    }
    return true;
}

/// JSON 文字列中でエスケープが必要な文字を置換する簡易ヘルパー。
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
        }
    }
    return out;
}

/// ファイルをバイナリで読み込む。成功時 true。
static bool readFileBinary(const std::string &path, std::vector<unsigned char> &out)
{
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        return false;
    }
    in.seekg(0, std::ios::end);
    std::streamoff size = in.tellg();
    if (size < 0) {
        return false;
    }
    in.seekg(0, std::ios::beg);
    out.resize(static_cast<size_t>(size));
    if (size > 0) {
        in.read(reinterpret_cast<char *>(out.data()), size);
        if (!in) {
            return false;
        }
    }
    return true;
}

/// ファイルへバイナリで書き込む。成功時 true。
static bool writeFileBinary(const std::string &path, const unsigned char *data, size_t len)
{
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    if (!out) {
        return false;
    }
    if (len > 0) {
        out.write(reinterpret_cast<const char *>(data),
                  static_cast<std::streamsize>(len));
    }
    out.flush();
    return static_cast<bool>(out);
}

/// Rust 側の直近エラーを取り出して解放する。
static std::string takeRendererError()
{
    char *err = inkscape_last_error();
    if (err == nullptr) {
        return std::string("unknown renderer error");
    }
    std::string message(err);
    inkscape_free_string(err);
    return message;
}

/// Rust の PNG バッファを Java の byte[] にコピーする。
static jbyteArray pngToByteArray(JNIEnv *env, unsigned char *png, size_t len)
{
    if (png == nullptr || len == 0) {
        if (png != nullptr) {
            inkscape_free(png, len);
        }
        return nullptr;
    }

    if (len > static_cast<size_t>(INT32_MAX)) {
        inkscape_free(png, len);
        logError("PNG が大きすぎます");
        return nullptr;
    }

    jbyteArray result = env->NewByteArray(static_cast<jsize>(len));
    if (result != nullptr) {
        env->SetByteArrayRegion(result, 0, static_cast<jsize>(len),
                                reinterpret_cast<const jbyte *>(png));
    }
    inkscape_free(png, len);
    return result;
}

/// 指定 SVG を PNG バイト列へレンダリングする。失敗時 NULL。
static unsigned char *renderSvgBytes(const std::vector<unsigned char> &svg,
                                     int width, int height, size_t &outLen)
{
    outLen = 0;
    unsigned int w = width > 0 ? static_cast<unsigned int>(width) : 0u;
    unsigned int h = height > 0 ? static_cast<unsigned int>(height) : 0u;
    return inkscape_render_png(svg.data(), svg.size(), w, h, &outLen);
}

// ===========================================================================
// JNI 実装
// ===========================================================================

extern "C" {

/**
 * ネイティブライブラリを初期化する。
 *
 * @return 0 で成功、非 0 で失敗。
 */
JNIEXPORT jint JNICALL
Java_org_inkscape_inkscape_MainActivity_init(JNIEnv *env, jobject thiz)
{
    (void)thiz;
    try {
        if (gNativeInitialized) {
            return 0;
        }
        gNativeInitialized = true;
        __android_log_print(ANDROID_LOG_INFO, kLogTag,
                            "init: SVG レンダラー %s を初期化しました",
                            inkscape_renderer_version());
        return 0;
    } catch (...) {
        if (env != nullptr && env->ExceptionCheck()) {
            env->ExceptionClear();
        }
        return -1;
    }
}

/**
 * Inkscape / レンダラーのバージョン文字列を返す。
 */
JNIEXPORT jstring JNICALL
Java_org_inkscape_inkscape_MainActivity_getVersion(JNIEnv *env, jobject thiz)
{
    (void)thiz;
    try {
        std::string version = std::string(kInkscapeAndroidVersion) + " (" +
                              inkscape_renderer_version() + ")";
        return env->NewStringUTF(version.c_str());
    } catch (...) {
        if (env != nullptr && env->ExceptionCheck()) {
            env->ExceptionClear();
        }
        return env->NewStringUTF("unknown");
    }
}

/**
 * ネイティブリソースを解放する。
 */
JNIEXPORT void JNICALL
Java_org_inkscape_inkscape_MainActivity_shutdown(JNIEnv *env, jobject thiz)
{
    (void)env;
    (void)thiz;
    try {
        gNativeInitialized = false;
        logInfo("shutdown: ネイティブライブラリをシャットダウンしました");
    } catch (...) {
        if (env != nullptr && env->ExceptionCheck()) {
            env->ExceptionClear();
        }
    }
}

/**
 * SVG ファイルを開けるか確認する。実際にパースして検証する。
 */
JNIEXPORT jboolean JNICALL
Java_org_inkscape_inkscape_MainActivity_openFile(JNIEnv *env, jobject thiz, jstring path)
{
    (void)thiz;
    try {
        std::string filePath = jstringToString(env, path);
        if (filePath.empty() || !fileExists(filePath)) {
            logError("openFile: ファイルが存在しません: " + filePath);
            return JNI_FALSE;
        }

        std::vector<unsigned char> data;
        if (!readFileBinary(filePath, data) || data.empty()) {
            logError("openFile: ファイルを読み込めません: " + filePath);
            return JNI_FALSE;
        }

        char *info = inkscape_svg_info(data.data(), data.size());
        if (info == nullptr) {
            logError("openFile: SVG の解析に失敗しました: " + takeRendererError());
            return JNI_FALSE;
        }
        inkscape_free_string(info);
        return JNI_TRUE;
    } catch (...) {
        if (env != nullptr && env->ExceptionCheck()) {
            env->ExceptionClear();
        }
        return JNI_FALSE;
    }
}

/**
 * SVG のドキュメント情報を JSON で返す。
 *
 * 例:
 * {"exists":true,"path":"...","size":1234,"format":"svg",
 *  "renderer":"resvg 0.1.0",
 *  "document":{"width":200.0,"height":200.0,"elements":5,...},"error":null}
 */
JNIEXPORT jstring JNICALL
Java_org_inkscape_inkscape_MainActivity_getDocumentInfo(JNIEnv *env, jobject thiz,
                                                          jstring path)
{
    (void)thiz;
    try {
        std::string filePath = jstringToString(env, path);
        std::string json;

        if (filePath.empty() || !fileExists(filePath)) {
            json = "{\"exists\":false,\"path\":\"" + jsonEscape(filePath) +
                   "\",\"size\":0,\"format\":null,\"renderer\":\"" +
                   jsonEscape(inkscape_renderer_version()) +
                   "\",\"document\":null,\"error\":\"file not found\"}";
            return env->NewStringUTF(json.c_str());
        }

        struct stat st;
        long long size = 0;
        if (stat(filePath.c_str(), &st) == 0) {
            size = static_cast<long long>(st.st_size);
        }

        std::vector<unsigned char> data;
        if (!readFileBinary(filePath, data) || data.empty()) {
            json = "{\"exists\":true,\"path\":\"" + jsonEscape(filePath) +
                   "\",\"size\":" + std::to_string(size) +
                   ",\"format\":null,\"renderer\":\"" +
                   jsonEscape(inkscape_renderer_version()) +
                   "\",\"document\":null,\"error\":\"read failed\"}";
            return env->NewStringUTF(json.c_str());
        }

        char *info = inkscape_svg_info(data.data(), data.size());
        if (info == nullptr) {
            std::string err = takeRendererError();
            json = "{\"exists\":true,\"path\":\"" + jsonEscape(filePath) +
                   "\",\"size\":" + std::to_string(size) +
                   ",\"format\":null,\"renderer\":\"" +
                   jsonEscape(inkscape_renderer_version()) +
                   "\",\"document\":null,\"error\":\"" + jsonEscape(err) + "\"}";
            return env->NewStringUTF(json.c_str());
        }

        std::string document(info);
        inkscape_free_string(info);

        json = "{\"exists\":true,\"path\":\"" + jsonEscape(filePath) +
               "\",\"size\":" + std::to_string(size) +
               ",\"format\":\"" + (isSvgPath(filePath) ? "svg" : "unknown") +
               "\",\"renderer\":\"" + jsonEscape(inkscape_renderer_version()) +
               "\",\"document\":" + document + ",\"error\":null}";
        return env->NewStringUTF(json.c_str());
    } catch (...) {
        if (env != nullptr && env->ExceptionCheck()) {
            env->ExceptionClear();
        }
        return env->NewStringUTF(
            "{\"exists\":false,\"document\":null,\"error\":\"internal error\"}");
    }
}

/**
 * SVG を PNG にエクスポートする。
 *
 * @param inputPath  入力 SVG パス
 * @param outputPath 出力 PNG パス
 * @param width      出力幅 (0 で元サイズ)
 * @param height     出力高さ (0 で元サイズ)
 * @return 成功時 JNI_TRUE
 */
JNIEXPORT jboolean JNICALL
Java_org_inkscape_inkscape_MainActivity_exportPng(JNIEnv *env, jobject thiz,
                                                    jstring inputPath, jstring outputPath,
                                                    jint width, jint height)
{
    (void)thiz;
    try {
        std::string inPath = jstringToString(env, inputPath);
        std::string outPath = jstringToString(env, outputPath);

        if (inPath.empty() || outPath.empty()) {
            logError("exportPng: パスが空です");
            return JNI_FALSE;
        }
        if (!fileExists(inPath)) {
            logError("exportPng: 入力ファイルが存在しません: " + inPath);
            return JNI_FALSE;
        }

        std::vector<unsigned char> svg;
        if (!readFileBinary(inPath, svg) || svg.empty()) {
            logError("exportPng: 入力ファイルを読み込めません");
            return JNI_FALSE;
        }

        size_t pngLen = 0;
        unsigned char *png = renderSvgBytes(svg, width, height, pngLen);
        if (png == nullptr) {
            logError("exportPng: レンダリング失敗: " + takeRendererError());
            return JNI_FALSE;
        }

        if (!makeParentDirs(outPath)) {
            logError("exportPng: 出力ディレクトリを作成できません: " + outPath);
            inkscape_free(png, pngLen);
            return JNI_FALSE;
        }

        bool ok = writeFileBinary(outPath, png, pngLen);
        inkscape_free(png, pngLen);

        if (!ok) {
            logError("exportPng: 出力ファイルに書き込めません: " + outPath);
            return JNI_FALSE;
        }

        __android_log_print(ANDROID_LOG_INFO, kLogTag,
                            "exportPng: %s -> %s (%zu bytes)", inPath.c_str(),
                            outPath.c_str(), pngLen);
        return JNI_TRUE;
    } catch (...) {
        if (env != nullptr && env->ExceptionCheck()) {
            env->ExceptionClear();
        }
        return JNI_FALSE;
    }
}

/**
 * SVG ファイルを PNG バイト列にレンダリングして返す。
 * プレビュー表示用。失敗時は null。
 *
 * @param path   入力 SVG パス
 * @param width  出力幅 (0 で元サイズ)
 * @param height 出力高さ (0 で元サイズ)
 */
JNIEXPORT jbyteArray JNICALL
Java_org_inkscape_inkscape_MainActivity_renderSvgPng(JNIEnv *env, jobject thiz,
                                                       jstring path, jint width, jint height)
{
    (void)thiz;
    try {
        std::string filePath = jstringToString(env, path);
        if (filePath.empty() || !fileExists(filePath)) {
            logError("renderSvgPng: ファイルが存在しません: " + filePath);
            return nullptr;
        }

        std::vector<unsigned char> svg;
        if (!readFileBinary(filePath, svg) || svg.empty()) {
            logError("renderSvgPng: ファイルを読み込めません");
            return nullptr;
        }

        size_t pngLen = 0;
        unsigned char *png = renderSvgBytes(svg, width, height, pngLen);
        if (png == nullptr) {
            logError("renderSvgPng: レンダリング失敗: " + takeRendererError());
            return nullptr;
        }
        return pngToByteArray(env, png, pngLen);
    } catch (...) {
        if (env != nullptr && env->ExceptionCheck()) {
            env->ExceptionClear();
        }
        return nullptr;
    }
}

/**
 * SVG のバイト列 (content:// URI から読み込んだデータ等) を PNG に
 * レンダリングして返す。
 */
JNIEXPORT jbyteArray JNICALL
Java_org_inkscape_inkscape_MainActivity_renderSvgDataPng(JNIEnv *env, jobject thiz,
                                                           jbyteArray data, jint width,
                                                           jint height)
{
    (void)thiz;
    try {
        if (data == nullptr) {
            return nullptr;
        }
        jsize len = env->GetArrayLength(data);
        if (len <= 0) {
            return nullptr;
        }

        std::vector<unsigned char> svg(static_cast<size_t>(len));
        env->GetByteArrayRegion(data, 0, len,
                                reinterpret_cast<jbyte *>(svg.data()));

        size_t pngLen = 0;
        unsigned char *png = renderSvgBytes(svg, width, height, pngLen);
        if (png == nullptr) {
            logError("renderSvgDataPng: レンダリング失敗: " + takeRendererError());
            return nullptr;
        }
        return pngToByteArray(env, png, pngLen);
    } catch (...) {
        if (env != nullptr && env->ExceptionCheck()) {
            env->ExceptionClear();
        }
        return nullptr;
    }
}

/**
 * レンダラー (resvg) のバージョン文字列を返す。
 */
JNIEXPORT jstring JNICALL
Java_org_inkscape_inkscape_MainActivity_getRendererVersion(JNIEnv *env, jobject thiz)
{
    (void)thiz;
    try {
        return env->NewStringUTF(inkscape_renderer_version());
    } catch (...) {
        if (env != nullptr && env->ExceptionCheck()) {
            env->ExceptionClear();
        }
        return env->NewStringUTF("unknown");
    }
}

/**
 * 直近のレンダリングエラーを返す。
 */
JNIEXPORT jstring JNICALL
Java_org_inkscape_inkscape_MainActivity_getLastError(JNIEnv *env, jobject thiz)
{
    (void)thiz;
    try {
        std::string message = takeRendererError();
        return env->NewStringUTF(message.c_str());
    } catch (...) {
        if (env != nullptr && env->ExceptionCheck()) {
            env->ExceptionClear();
        }
        return env->NewStringUTF("unknown");
    }
}

/**
 * ネイティブライブラリが初期化済みか返す。
 */
JNIEXPORT jboolean JNICALL
Java_org_inkscape_inkscape_MainActivity_isNativeReady(JNIEnv *env, jobject thiz)
{
    (void)env;
    (void)thiz;
    try {
        return gNativeInitialized ? JNI_TRUE : JNI_FALSE;
    } catch (...) {
        if (env != nullptr && env->ExceptionCheck()) {
            env->ExceptionClear();
        }
        return JNI_FALSE;
    }
}

} // extern "C"
