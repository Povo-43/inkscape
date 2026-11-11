# Inkscape for Android — GTK 描画転送パイプライン 設計書

**対象**: GTK3 (gtkmm) ベース Inkscape を Android NDK 上で動作させるための描画転送パイプライン  
**作成**: Android NDK/JNI + GTK レンダリング専門サブエージェント  
**ステータス**: 設計書 (実装コードはまだ書かない)  
**日本語**

---

## 1. 概要と目的

Android 端末上で Inkscape の GTK GUI をヘッドレスなしで動作させる。GTK の描画を X11/Wayland などのネイティブウィンドウシステムを経由せず、**メモリ上 (cairo image surface / GdkPixbuf) にレンダリングし、Android の Bitmap へ転送 → View に表示**するパイプラインを構築する。

Inkscape 側の GUI コードは極力変更せず、GTK のメインループ・ウィジェット・入力処理を維持したまま、Android 側で「画として出す」だけの薄い層を設ける方針とする。

---

## 2. 前提・制約・リスク

| 項目 | 内容 |
|------|------|
| GTK バックエンド | 本リポジトリに GTK Android バックエンドは存在しない。Android には X11/Wayland ディスプレイサーバーがないため、GTK が要求する GDK ディスプレイ (`gdk_display_get_default()`) が初期化できない。 |
| 本設計の前提 | 「GTK をメモリ上 (offscreen) にレンダリングできる」ことを前提とする。具体的には、GTK3 の `GtkOffscreenWindow`（GTK 3.22+）または同等のオフスクリーン描画経路を使い、cairo image surface を取得できるビルド済み GTK Android ライブラリが別途用意されることを仮定する。 |
| スレッド安全性 | GTK+/GDK は基本的に「GTK オブジェクトを生成したスレッド」からしか安全に呼べない (GTK3 は GDK スレッド安全化済みだが、ウィジェット操作は単一スレッド推奨)。すべての GTK 呼び出しは**専用 GTK スレッド**に集約する。 |
| リンク | gtkmm / glibmm / cairo / gdk 等は Android 向けにクロスコンパイルされたプリビルドライブラリ (またはソースからのビルド) が必要。CMake で `find_library` / `pkg-config` により解決する。 |
| 入力イベント |  Android のタッチイベントを GTK の `GdkEvent` に変換し `gtk_main_do_event()` 相当で配送する必要がある。 |

### 2.1 未解決オープンイシュー (実装前の確認事項)
1. **GDK Android バックエンドの有無**: GTK3 に Android 向け GDK バックエンドは公式に存在しない。`GtkOffscreenWindow` が動作するには GDK ディスプレイが必要。代替として、ソフトウェアレンダリング専用の GDK バックエンドを自前で追加するか、ヘッドレス GDK 上で `GtkOffscreenWindow` を使う検討が必要。
2. **gtkmm の Android 対応**: gtkmm/glibmm の C++ バインディングを Android NDK (clang, c++_shared) でビルド可能か確認が必要。
3. **リソースパス**: Inkscape のアイコン・テンプレート・locale 等は Android アプリの `assets/` に配置し、ネイティブ側から `AAssetManager` 経由で読み出す必要がある (本設計ではパス文字列を JNI で渡す)。

---

## 3. 全体アーキテクチャ

```
+---------------------------------------------------------------+
|                     Java / Kotlin (Android Framework)        |
|  +---------------------+     JNI     +----------------------+ |
|  | MainActivity        |<----------->| InkscapeNative.kt   | |
|  |                     |  (native)   | (external fun ... ) | |
|  |  +---------------+  |             +----------------------+ |
|  |  | InkscapeView  |  |                          |        |
|  |  | (TextureView/ |  |                          v        |
|  |  |  SurfaceView) |  |             +----------------------+ |
|  |  +-------+------+  |             | libinkscape-jni.so   | |
|  |          |         |             | (android_jni.cpp)    | |
|  |   Choreographer   |             +----------+-----------+ |
|  +-------+------------+                        |            |
|          | (毎フレーム render 呼び出し)         v            v
|          |                    +----------------------+      |
|          |                    |   GTK スレッド        |      |
|          |                    |  (pthread_create)   |      |
|          |                    |  gtk_init()         |      |
|          |                    |  GtkOffscreenWindow |      |
|          |                    |  gtk_main() ループ   |      |
|          |                    +----------+----------+      |
|          |                                   |              |
|          |         カイロ surface / ピクセルバッファ (共有, mutex保護) |
|          |                                   |              |
|          v                                   v              |
|  Android Bitmap (ARGB_8888) <=============> ピクセルコピー   |
+---------------------------------------------------------------+
```

### 3.1 スレッド構成

| スレッド | 役割 | 主な処理 |
|---------|------|---------|
| **メイン (UI) スレッド** | Android Activity/View のライフサイクル・入力受け取り | タッチイベントを JNI (`gtkInjectTouchEvent`) 経由でネイティブへ転送、View への描画指示 |
| **GTK スレッド** (pthread) | GTK メインループの所有・実行 | `gtk_init`、`GtkOffscreenWindow` 生成、`gtk_main()`、`g_idle_add` によるオフスクリーンレンダリング |
| **レンダースレッド** (Choreographer) | Android 側の毎フレーム表示 | `gtkRenderFrame(bitmap)` を呼び出し、GTK 側からピクセルを受け取り View に描画 |

### 3.2 同期モデル (推奨)

すべての GTK 呼び出しは **GTK スレッド** 上で行い、レンダースレッドは「描画完了を待つ」だけにする。

1. レンダースレッド → `gtkRenderFrame(bitmap)` を呼ぶ
2. JNI 側で `render_requested` フラグを立て、条件変数で GTK スレッドを起床
3. GTK スレッドが `gtk_main_iteration()` 的な 1 イテレーションを回し、オフスクリーンウィンドウを cairo surface に描画 → `frame_ready` を設定して条件変数を通知
4. JNI 側で待ち合わせを解除し、mutex 保護下で cairo surface のピクセルを Android Bitmap にコピー
5. レンダースレッドが Bitmap を View に描画し、次の Choreographer フレームへ

これにより GTK 呼び出しが複数スレッドから並行実行されるリスクを排除する。

---

## 4. オフスクリーンレンダリング (GTK → メモリ)

### 4.1 レンダリング経路

```
GtkOffscreenWindow (GtkWindow サブクラス, ネイティブウィンドウ未作成)
        |
        v
gtk_widget_draw() / gdk_cairo_draw() によりウィジェット全体を描画
        |
        v
gtk_offscreen_window_get_surface() → cairo_surface_t* (CAIRO_FORMAT_ARGB32)
        |
        v  (ストライド/バイトオーダー考慮のピクセルコピー)
Android Bitmap (Bitmap.Config.ARGB_8888) ← AndroidBitmap_lockPixels / memcpy
        |
        v
TextureView / SurfaceView に表示
```

### 4.2 ピクセルフォーマットと転送

- **cairo 側**: `CAIRO_FORMAT_ARGB32` (32bit, ストライドは `cairo_image_surface_get_stride()` で取得)。バイトオーダーはリトルエンディアン (Android デバイスのほとんどが ARM little endian)。
- **Android 側**: `Bitmap.Config.ARGB_8888`。`AndroidBitmap_getInfo()` で幅・高さ・ストライドを取得し、`AndroidBitmap_lockPixels()` でポインタを得る。
- **転送**: 行単位で `memcpy(dst_row, src_row, width * 4)`。cairo のストライドと Android Bitmap のストライドが異なる場合は行ごとにコピー (2D memcpy)。完全に一致すれば `memcpy` 一括。

> GdkPixbuf 経由の代替: `gtk_offscreen_window_get_pixbuf()` → `gdk_pixbuf_read_pixel()` でも取得可能。ただし cairo surface 経由の方がピクセルポインタへの直接アクセスが容易で転送コストが低いため、本設計では cairo image surface を採用する。

---

## 5. JNI インターフェース設計

Java/Kotlin 側クラス: `org.inkscape.inkscape.InkscapeNative`  
パッケージ名: `org_inkscape_inkscape`  
JNI シグナル名例: `Java_org_inkscape_inkscape_InkscapeNative_gtkInit`

現状の `init` / `getVersion` / `shutdown` は残し、GTK 系メソッドを追加する。

### 5.1 関数一覧

| # | Kotlin 外部宣言 | JNI シグナル名 | 概要 |
|---|----------------|---------------|------|
| 1 | `external fun init(): Int` | `Java_org_inkscape_inkscape_InkscapeNative_init` | 既存。ネイティブライブラリ初期化 (現状はスタブ) |
| 2 | `external fun getVersion(): String` | `..._getVersion` | 既存。バージョン文字列 |
| 3 | `external fun shutdown()` | `..._shutdown` | 既存。終了処理 |
| 4 | `external fun gtkInit(width: Int, height: Int, resourcePath: String): Int` | `..._gtkInit` | GTK + オフスクリーンウィンドウ初期化、GTK スレッド起動 |
| 5 | `external fun gtkRenderFrame(bitmap: android.graphics.Bitmap): Boolean` | `..._gtkRenderFrame` | 1 フレーム描画。GTK メインループ 1 イテレーション + ピクセル転送 |
| 6 | `external fun gtkGetSurfaceWidth(): Int` | `..._gtkGetSurfaceWidth` | オフスクリーンサーフェス幅 |
| 7 | `external fun gtkGetSurfaceHeight(): Int` | `..._gtkGetSurfaceHeight` | オフスクリーンサーフェス高さ |
| 8 | `external fun gtkInjectTouchEvent(action: Int, pointerId: Int, x: Float, y: Float, eventTime: Long): Boolean` | `..._gtkInjectTouchEvent` | タッチイベントを GTK 側へ注入 |
| 9 | `external fun gtkInjectKeyEvent(action: Int, keyCode: Int, metaState: Int): Boolean` | `..._gtkInjectKeyEvent` | キーイベントを GTK 側へ注入 |
| 10 | `external fun gtkShutdown()` | `..._gtkShutdown` | GTK メインループ停止、GTK スレッド終了、リソース解放 |

### 5.2 シグネチャ詳細 (C++)

```cpp
// --- src/android_jni.cpp に追加 ---

/**
 * GTK を初期化し、オフスクリーンウィンドウを作成して GTK スレッドを起動する。
 *
 * @param width        初期描画サイズ幅 (px)
 * @param height       初期描画サイズ高さ (px)
 * @param resourcePath Inkscape リソース (アイコン/テンプレート等) の Android assets ベースパス
 * @return 0 成功 / 非ゼロ 失敗 (二重初期化など)
 */
JNIEXPORT jint JNICALL
Java_org_inkscape_inkscape_InkscapeNative_gtkInit(
    JNIEnv *env, jobject thiz,
    jint width, jint height, jstring resourcePath);

/**
 * 1 フレーム描画を行い、オフスクリーンサーフェスのピクセルを指定 Bitmap に転送する。
 *
 * @param bitmap 転送先 Bitmap。ARGB_8888、サイズは gtkGetSurfaceWidth/Height と一致していること。
 * @return 転送成功で true。未初期化やサイズ不一致で false。
 */
JNIEXPORT jboolean JNICALL
Java_org_inkscape_inkscape_InkscapeNative_gtkRenderFrame(
    JNIEnv *env, jobject thiz, jobject bitmap);

/**
 * オフスクリーンサーフェス幅を返す。
 */
JNIEXPORT jint JNICALL
Java_org_inkscape_inkscape_InkscapeNative_gtkGetSurfaceWidth(JNIEnv *env, jobject thiz);

/**
 * オフスクリーンサーフェス高さを返す。
 */
JNIEXPORT jint JNICALL
Java_org_inkscape_inkscape_InkscapeNative_gtkGetSurfaceHeight(JNIEnv *env, jobject thiz);

/**
 * Android のタッチイベントを GTK 側へ注入する。
 *
 * @param action     MotionEvent アクション (0=DOWN, 1=UP, 2=MOVE, 6=POINTER_UP 等)
 * @param pointerId  ポインタ ID
 * @param x, y       タッチ座標 (ビュー座標系、ピクセル)
 * @param eventTime  イベント発生時刻 (uptimeMillis)
 * @return 注入成功で true
 */
JNIEXPORT jboolean JNICALL
Java_org_inkscape_inkscape_InkscapeNative_gtkInjectTouchEvent(
    JNIEnv *env, jobject thiz,
    jint action, jint pointerId, jfloat x, jfloat y, jlong eventTime);

/**
 * キーイベントを GTK 側へ注入する。
 *
 * @param action    KeyEvent アクション (0=DOWN, 1=UP)
 * @param keyCode   キーコード
 * @param metaState メタ状態 (Shift/Ctrl 等)
 * @return 注入成功で true
 */
JNIEXPORT jboolean JNICALL
Java_org_inkscape_inkscape_InkscapeNative_gtkInjectKeyEvent(
    JNIEnv *env, jobject thiz,
    jint action, jint keyCode, jint metaState);

/**
 * GTK をシャットダウンし、GTK スレッドを終了してリソースを解放する。
 */
JNIEXPORT void JNICALL
Java_org_inkscape_inkscape_InkscapeNative_gtkShutdown(JNIEnv *env, jobject thiz);
```

### 5.3 JNI 側の内部状態 (概念的)

```cpp
// グローバル状態 (mutex 保護)
struct GtkAndroidBridge {
    std::mutex mutex;
    std::condition_variable render_cv;   // GTKスレッド → レンダースレッド通知用
    std::condition_variable frame_cv;    // レンダースレッド → GTKスレッド通知用
    bool render_requested = false;
    bool frame_ready = false;
    bool gtk_running = false;

    GtkWidget *offscreen_window = nullptr; // GtkOffscreenWindow
    cairo_surface_t *surface = nullptr;
    int surface_width = 0;
    int surface_height = 0;

    // 入力イベントキュー (GTKスレッドが消費)
    std::queue<InjectedEvent> input_queue;
};
```

`GtkOffscreenWindow` / `cairo_surface_t` へのアクセスはすべて GTK スレッド上で行い、レンダースレッドは `gtkRenderFrame` 内で「要求 → 待ち → コピー」のみを行う。

---

## 6. Android 側の View 設計

### 6.1 推奨: TextureView + OpenGL ES (テクスチャアップロード)

| 項目 | 内容 |
|------|------|
| クラス | `org.inkscape.inkscape.InkscapeView` (TextureView サブクラス) |
| 描画方式 | Choreographer ベースのレンダースレッド → `gtkRenderFrame(bitmap)` でピクセル転送 → `glTexSubImage2D` でテクスチャ更新 → `TextureView` に描画 |
| 利点 | 通常の View として変形・アルファ・アニメーションが使える、他の Android UI と合成しやすい、ハードウェアアクセラレーション対応 |
| 欠点 | OpenGL ES コンテキストとテクスチャ管理が必要、毎フレームテクスチャアップロードが発生 |

**実装イメージ:**
- `InkscapeView` は `TextureView.SurfaceTextureListener` を実装し、GLES コンテキストを保持
- レンダースレッドは `Choreographer.getInstance().postFrameCallback()` で毎フレーム起動
- 各フレーム: `gtkRenderFrame(mBitmap)` → `glBindTexture` / `glTexSubImage2D(GL_TEXTURE_2D, ..., mBitmapPixels)` → 描画コマンド → `requestRender()` / `invalidate()`

### 6.2 代替: SurfaceView + Canvas.drawBitmap (単純版)

| 項目 | 内容 |
|------|------|
| クラス | `org.inkscape.inkscape.InkscapeView` (SurfaceView サブクラス) |
| 描画方式 | SurfaceView の `lockCanvas()` → `canvas.drawBitmap(mBitmap, 0, 0, paint)` → `unlockCanvasAndPost()` |
| 利点 | OpenGL 不要、実装が単純、ピクセル転送が最短経路 |
| 欠点 | 独立したウィンドウ (z-order 扱い) で他ビューとの合成が難しい、変形・アルファが効きにくい、タッチ座標変換が必要 |

### 6.3 設計決定

最初のマイルストーンでは **SurfaceView + Canvas.drawBitmap** を採用し、実装コストとデバッグ容易性を優先する。パフォーマンスや UI 合成が課題になった段階で **TextureView + GLES** へ移行する。インターフェース (`gtkRenderFrame(bitmap)`) は共通なので View 実装のみ差し替え可能にする。

### 6.4 Kotlin 側クラス構成 (ファイルパス)

- `app/src/main/java/org/inkscape/inkscape/InkscapeNative.kt` — JNI `external fun` 宣言と `System.loadLibrary("inkscape-jni")`
- `app/src/main/java/org/inkscape/inkscape/InkscapeView.kt` — View (TextureView/SurfaceView) と Choreographer レンダーループ
- `app/src/main/java/org/inkscape/inkscape/MainActivity.kt` — 既存。`setContentView(InkscapeView(this))` に変更し、ライフサイクルで `gtkInit`/`gtkShutdown` を呼ぶ

**MainActivity.kt の変更イメージ (設計のみ):**

```kotlin
class MainActivity : AppCompatActivity() {
    companion object { init { System.loadLibrary("inkscape-jni") } }
    external fun init(): Int
    external fun getVersion(): String
    external fun shutdown()
    external fun gtkInit(width: Int, height: Int, resourcePath: String): Int
    external fun gtkRenderFrame(bitmap: Bitmap): Boolean
    external fun gtkGetSurfaceWidth(): Int
    external fun gtkGetSurfaceHeight(): Int
    external fun gtkInjectTouchEvent(action: Int, pointerId: Int, x: Float, y: Float, eventTime: Long): Boolean
    external fun gtkShutdown()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val view = InkscapeView(this)
        setContentView(view)

        val w = gtkGetSurfaceWidth()
        val h = gtkGetSurfaceHeight()
        val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        view.setBitmap(bitmap)

        gtkInit(w, h, /* resourcePath */ "")   // GTK スレッド起動
        view.startRenderLoop()                  // Choreographer 開始 → 毎フレーム gtkRenderFrame(bitmap)
    }

    override fun onDestroy() {
        super.onDestroy()
        gtkShutdown()
    }
}
```

---

## 7. メインループとスレッド設計 (詳細)

### 7.1 GTK スレッド (`gtkInit` 内で `pthread_create`)

```text
gtkThreadEntry(arg):
    gtk_init(&argc, &argv)                 // GTK 初期化 (GDK ディスプレイ確保は GTK Android ビルドに依存)
    offscreen_window = gtk_offscreen_window_new()
    gtk_widget_set_size_request(offscreen_window, width, height)
    // Inkscape のメインウィジェット (Gtk::Application / InkscapeWindow) を offscreen_window にadd
    gtk_widget_show_all(offscreen_window)

    // 描画用アイドルハンドラ (GTKメインループ内で毎回呼ばれる)
    g_idle_add(drawIdleHandler, nullptr)   // render_requested 時だけ surface へ描画

    gtk_main()                             // ブロック。GTKスレッド専有
```

`drawIdleHandler`:
- `render_requested` が false なら `G_SOURCE_REMOVE` せず false を返して次を待つ (または idle を使わず条件変数待ちにする)
- true なら `gtk_widget_draw(offscreen_window, cr)` / `gtk_offscreen_window_get_surface()` で surface を最新化、`frame_ready = true`、`render_requested = false`、条件変数通知

### 7.2 レンダースレッド (`gtkRenderFrame` の呼び出し元)

Android の `Choreographer` コールバック内で `gtkRenderFrame(bitmap)` を呼び出す。JNI 側の処理:

1. `mutex.lock()`
2. `render_requested = true`; GTK スレッド向け条件変数を `notify_one`
3. `frame_cv.wait()` で GTK スレッドが描画完了するまで待機 (タイムアウト付き、例: 100ms)
4. `frame_ready = false` をクリア
5. cairo surface のストライド/データポインタを取得
6. `AndroidBitmap_lockPixels(bitmap, &addr)` → 行単位 memcpy → `AndroidBitmap_unlockPixels(bitmap)`
7. `mutex.unlock()`; `JNI_TRUE` を返す

### 7.3 入力イベントの流れ

```
Java UIスレッド (InkscapeView.onTouchEvent)
      |
      v  JNI: gtkInjectTouchEvent(action, pointerId, x, y, eventTime)
      |
      v  [mutex保護の input_queue に enqueue] + GTKスレッド起床通知
      |
      v  GTKスレッド (idle / メインループ) が dequeue
      |
      v  GdkEventTouch / GdkEventButton を合成 → gtk_main_do_event(&event)
      |
      v  GTK ウィジェットのシグナルハンドラ (ボタン押下/ドラッグ等) が実行
      |
      v  次の gtkRenderFrame で画面に反映
```

`gtk_main_do_event()` は GTK 内部 API 的な扱いになるため、代替として `GtkEventController` / `GtkGesture` に合成イベントを送るラッパーを用意するか、GDK イベントを `gdk_event_new()` で作成し `gtk_main_do_event()` に渡す方針とする (詳細は実装時に検討)。

---

## 8. CMake 変更案

### 8.1 `app/src/main/cpp/CMakeLists.txt` (メイン変更箇所)

現状: `inkscape-jni` は `android_jni.cpp` のみをスタンドアロンビルドし、GTK 等をリンクしない。

変更後: GTK/GDK/cairo ヘッダをインクルードパスに追加し、gtkmm/glibmm/cairo/gdk および Android システムライブラリ (`android`, `jnigraphics`, `log`) にリンクする。

```cmake
cmake_minimum_required(VERSION 3.22.1)
project(inkscape-android-jni LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# --- ソース: JNI ラッパー + GTK ブリッジ (新規ファイル) ----------------------
add_library(inkscape-jni SHARED
    ../../../../src/android_jni.cpp
    ../../../../src/android_gtk_bridge.cpp   # 新規: GTKオフスクリーンブリッジ
)

# --- インクルードパス --------------------------------------------------------
target_include_directories(inkscape-jni PRIVATE
    ../../../../src                       # inkscape ソースルート
    ../../../../src/android               # 新規: Android 固有ヘッダ配置想定
)

# --- GTK / glibmm / cairo リンク ---------------------------------------------
# NOTE: Android 向け GTK バックエンドは本リポジトリに含まれないため、
#       事前にクロスコンパイル済みの gtkmm/glibmm/cairo/gdk ライブラリを
#       CMAKE_PREFIX_PATH / ANDROID_PREBUILT_GTK_ROOT で指定すること。
find_package(PkgConfig QUIET)
if(PkgConfig_FOUND AND NOT ANDROID)
    # ホストビルド時のみ pkg-config を使う。Android クロスコンパイル時は
    # find_library で個別に解決する。
    pkg_check_modules(GTKMM REQUIRED gtkmm-3.0)
    pkg_check_modules(GLIBMM REQUIRED glibmm-2.4)
    pkg_check_modules(CAIRO REQUIRED cairo)
    pkg_check_modules(GDK REQUIRED gdk-3.0)
    target_include_directories(inkscape-jni PRIVATE ${GTKMM_INCLUDE_DIRS} ${GLIBMM_INCLUDE_DIRS} ${CAIRO_INCLUDE_DIRS} ${GDK_INCLUDE_DIRS})
    target_link_libraries(inkscape-jni PRIVATE ${GTKMM_LIBRARIES} ${GLIBMM_LIBRARIES} ${CAIRO_LIBRARIES} ${GDK_LIBRARIES})
else()
    # Android クロスコンパイル: 事前ビルド済みライブラリを直接指定
    # 例: -DANDROID_GTK_ROOT=/path/to/gtk-android/arm64-v8a
    if(DEFINED ANDROID_GTK_ROOT)
        set(GTK_ROOT "${ANDROID_GTK_ROOT}")
        target_include_directories(inkscape-jni PRIVATE
            "${GTK_ROOT}/include/gtkmm-3.0"
            "${GTK_ROOT}/include/glibmm-2.4"
            "${GTK_ROOT}/include/cairo"
            "${GTK_ROOT}/include/gdk-3.0"
            "${GTK_ROOT}/include/pango-1.0"
            "${GTK_ROOT}/include/glib-2.0"
            "${GTK_ROOT}/lib/glib-2.0/include"
            "${GTK_ROOT}/lib/gtkmm-3.0/include"
        )
        find_library(GTKMM_LIB gtkmm-3.0 PATHS "${GTK_ROOT}/lib" NO_DEFAULT_PATH)
        find_library(GLIBMM_LIB glibmm-2.4 PATHS "${GTK_ROOT}/lib" NO_DEFAULT_PATH)
        find_library(CAIRO_LIB cairo PATHS "${GTK_ROOT}/lib" NO_DEFAULT_PATH)
        find_library(GDK_LIB gdk-3.0 PATHS "${GTK_ROOT}/lib" NO_DEFAULT_PATH)
        find_library(GDKMM_LIB gdkmm-3.0 PATHS "${GTK_ROOT}/lib" NO_DEFAULT_PATH)
        find_library(GLIB_LIB glib-2.0 PATHS "${GTK_ROOT}/lib" NO_DEFAULT_PATH)
        target_link_libraries(inkscape-jni PRIVATE
            ${GTKMM_LIB} ${GLIBMM_LIB} ${CAIRO_LIB} ${GDK_LIB} ${GDKMM_LIB} ${GLIB_LIB}
        )
    endif()
endif()

# --- Android システムライブラリ ----------------------------------------------
# AndroidBitmap_lockPixels 等は libjnigraphics、ログは liblog、
# ネイティブウィンドウ/スレッドは libandroid / liblog をリンク。
target_link_libraries(inkscape-jni PRIVATE
    android
    jnigraphics
    log
)

# --- 出力名 ------------------------------------------------------------------
set_target_properties(inkscape-jni PROPERTIES
    PREFIX ""
    OUTPUT_NAME "inkscape-jni"
)
```

### 8.2 ルート `CMakeLists.txt` と `src/CMakeLists.txt` との整合

- `src/CMakeLists.txt` は `ANDROID` 時に `inkscape` / `inkview` を SHARED ビルドする分岐を既に持つ (303-312 行)。GTK 有効化時は `WITH_GTK` オプション等で `inkscape_base` に gtkmm リンクを追加する必要があるが、本パイプラインの第一段階では **`app/src/main/cpp/CMakeLists.txt` の `inkscape-jni` だけを GTK リンク対象とし、ルート `src/` の Inkscape コアとはリンクしない** 方針とする (リンク依存を最小化し、ビルド成功を優先)。
- 将来、Inkscape コア (`inkscape_base`) を GTK Android にリンクする場合は、`src/CMakeLists.txt` の `target_link_libraries(inkscape_base ...)` に gtkmm を追加し、`android_jni.cpp` から `InkscapeApplication` / `InkscapeWindow` を生成するよう拡張する。

### 8.3 `app/build.gradle` の変更点 (任意)

NDK r26 の明示指定と、`jnigraphics` 利用のための `ndk` ブロック確認:

```gradle
android {
    ndkVersion '26.1.10909125'   // NDK r26 (任意: Gradle が自動選択する場合は不要)
    ndk {
        abiFilters 'armeabi-v7a', 'arm64-v8a', 'x86_64'
    }
    externalNativeBuild {
        cmake {
            cppFlags '-std=c++17 -frtti -fexceptions'
            arguments '-DANDROID_STL=c++_shared',
                      '-DANDROID_GTK_ROOT=/path/to/gtk-android/${ANDROID_ABI}'
        }
    }
}
```

`minSdk 31` (Android 12) は `GtkOffscreenWindow` / cairo / AndroidBitmap API すべて利用可能な範囲。

---

## 9. データフローとシーケンス (毎フレーム)

```
1. Choreographer (レンダースレッド)
   └─► gtkRenderFrame(bitmap)  [JNI]
        ├─ mutex.lock()
        ├─ render_requested = true → GTKスレッド起床
        ├─ wait(frame_cv, timeout)  ← GTKスレッドが描画完了まで
        ├─ cairo surface ピクセル → AndroidBitmap_lockPixels(bitmap) → memcpy → unlockPixels
        ├─ mutex.unlock()
        └─ return true
   └─► Canvas.drawBitmap(bitmap) / glTexSubImage2D  で View に表示
   └─► postFrameCallback() で次のフレームへ

2. 入力イベント (非同期)
   ユーザータッチ → InkscapeView.onTouchEvent → gtkInjectTouchEvent(...) [JNI]
        └─ input_queue.enqueue() + GTKスレッド起床
   GTKスレッド (idle/メインループ) → dequeue → GdkEvent合成 → gtk_main_do_event()
        └─ Inkscape ウィジェットが反応 → 次フレームの gtkRenderFrame で画面反映
```

---

## 10. 新規・変更ファイル一覧

| ファイル | 種別 | 内容 |
|----------|------|------|
| `src/android_jni.cpp` | 変更 | JNI 関数を `gtkInit`/`gtkRenderFrame`/`gtkGetSurfaceWidth/Height`/`gtkInjectTouchEvent`/`gtkInjectKeyEvent`/`gtkShutdown` に拡張 |
| `src/android/android_gtk_bridge.cpp/.h` | 新規 | GTK スレッド管理、`GtkOffscreenWindow`/`cairo_surface_t` ラップ、入力キュー、`gtkRenderFrame` 実体 |
| `src/android/android_surface.cpp/.h` | 新規 | AndroidBitmap ロック/アンロックと cairo surface → Bitmap ピクセルコピー |
| `app/src/main/cpp/CMakeLists.txt` | 変更 | GTK/GDK/cairo リンク、`jnigraphics`/`android`/`log` リンク、新規ソース追加 |
| `app/build.gradle` | 変更 | NDK r26 指定、`ANDROID_GTK_ROOT` 引数 (任意) |
| `app/src/main/java/org/inkscape/inkscape/InkscapeNative.kt` | 新規 | JNI `external fun` 宣言、`System.loadLibrary` |
| `app/src/main/java/org/inkscape/inkscape/InkscapeView.kt` | 新規 | TextureView/SurfaceView + Choreographer レンダーループ |
| `app/src/main/java/org/inkscape/inkscape/MainActivity.kt` | 変更 | `InkscapeView` を `setContentView`、`gtkInit`/`gtkShutdown` 呼び出し |

---

## 11. 実装後の検証項目 (実装コードはまだ書かない)

1. `gtkInit` 後に `gtkGetSurfaceWidth/Height` が期待値を返すか。
2. `gtkRenderFrame` で取得した Bitmap が空白/破損せず、Inkscape 描画内容が正しく表示されるか。
3. 60fps 近くで毎フレーム転送でき、ピクセルコピーがボトルネックにならないか (ストライド不一致時の行コピー効率)。
4. タッチイベントが GTK ウィジェットに届き、Inkscape 側で選択・ドラッグ等が動作するか。
5. GTK スレッド終了時 (`gtkShutdown`) にクラッシュやデッドロックが発生しないか。
6. メモリリーク (cairo surface、GtkWidget、グローバル参照 `jobject` の `DeleteGlobalRef` 漏れ) がないか。

---

以上が「描画転送パイプライン」の設計書です。実装フェーズに入る際は、まず `src/android_jni.cpp` と `app/src/main/cpp/CMakeLists.txt` の変更から着手し、GTK Android 用プリビルドライブラリの入手 (またはオフスクリーン GDK バックエンドの自作) を並行して進めることを推奨します。
