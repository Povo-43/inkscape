# Inkscape for Android — GTK4 ネイティブ版

このドキュメントは、Android 上で **GTK4 ウィジェットをそのまま動かす**
Inkscape の実験的ビルドについて説明します。

これまでの Android 版 (`packaging/android/`、Kotlin + Android View +
resvg レンダラー) とは別系統です。GTK4 版は GTK の Android バックエンド
(GTK 4.22 以降) を使うため、デスクトップ版 Inkscape と同じ GTK4 の
UI 技術の上に築くことができます。

## 現在の状態

- GTK 4.22+ (wrap は `gitlab.gnome.org/GNOME/gtk.git` の `main`) を
  Android NDK でクロスコンパイルし、APK として動作するところまで確認済み。
- アプリは GTK4 の `GtkApplication` + `GtkApplicationWindow` +
  `GtkHeaderBar` で構成され、SVG の表示には GTK 4.22 で追加された
  **`GtkSvg`** (`GdkPaintable` 実装) を使用。
  librsvg や resvg を追加でリンクする必要がない。
- キャンバスは独自の `InkCanvas` ウィジェット:
  - 1 本指 / マウスドラッグでパン
  - ピンチでズーム (フォーカルポイント維持)
  - ダブルタップで「ページにフィット」と 100% を切り替え
  - Ctrl+ホイールでズーム
  - ズームプリセット: 50% / 100% / 200% / ページフィット / ページ幅フィット
  - 回転: 時計回り (Ctrl+]) / 反時計回り (Ctrl+[) / リセット
  - 反転: 水平 / 垂直 / リセット
- アクション名は Inkscape 本体 (`src/actions/actions-canvas-transform.cpp`)
  と互揣: `app.canvas-zoom-*` / `app.canvas-rotate-*` / `app.canvas-flip-*`
  (GTK4 `GAction` を使用)。
- Android のドキュメントピッカー (`GtkFileDialog` → `GtkFileChooserNative`
  → `ACTION_OPEN_DOCUMENT` / `ACTION_CREATE_DOCUMENT`) で SVG を開き、
  PNG を書き出せる。`.svgz` (gzip) にも対応。
- ファイルマネージャなどから `image/svg+xml` を「Inkscape GTK4 で開く」
  ことができる (`G_APPLICATION_HANDLES_OPEN` + ACTION_VIEW インテント)。
- PNG 書き出し時に倍率 (1× / 2× / 4×) を選べる。出力は最大 8192px に
  制限される。
- PNG 書き出しは `GdkPaintable` を `GtkSnapshot` 経由で
  `GskRenderNode` にし、`gsk_render_node_draw()` で cairo イメージ
  サーフェスへ描画している (GL レンダラーがなくても動作する)。
- ホスト (デスクトップ GTK4) では `tests/render-test.cpp` が SVG /
  SVGZ の読み込みと PNG 書き出しを自動検証する (CI の
  `gtk4-syntax.yml`、xvfb 上で実行)。

スクリーンショット (Android 13 x86_64 エミュレータ):

```
+----------------------------------+
|           Inkscape GTK4          |  <- GtkHeaderBar
+----------------------------------+
|                                  |
|      (SVG を GtkSvg で描画)       |  <- InkCanvas
|                                  |
+----------------------------------+
| welcome.svg · 420 × 320 px ...   |  <- ステータス
| [開く][-][fit][+][書き出し]       |  <- ツールバー
+----------------------------------+
```

## ビルド

ビルドには [pixiewood (gtk-android-builder)](https://github.com/sp1ritCS/gtk-android-builder)
を使います。GTK / GLib / harfbuzz / fontconfig / pango などを meson
subproject としてクロスコンパイルし、Android の Gradle プロジェクトを
生成します。

```sh
# 依存 (Debian/Ubuntu)
sudo apt-get install build-essential ccache glslc gobject-introspection \
  gir1.2-appstream-1.0 libglib2.0-dev libglib2.0-dev-bin libglib-perl \
  libglib-object-introspection-perl libipc-run-perl libjson-perl \
  libset-scalar-perl libxml-libxml-perl libxml-libxslt-perl libxml2-utils \
  sassc gettext desktop-file-utils apksigner

# pixiewood と mini-studio
git clone https://github.com/sp1ritCS/gtk-android-builder.git pixiewood
git clone https://github.com/sp1ritCS/mini-studio.git mini
export PATH="$PWD/pixiewood:$PATH"

pip install meson ninja

cd packaging/android-gtk4
pixiewood prepare --release --android-studio=../../mini \
  --sdk="$ANDROID_HOME" pixiewood.xml
pixiewood generate
pixiewood build
```

生成される APK:

```
packaging/android-gtk4/.pixiewood/android/app/build/outputs/apk/release/
  app-arm64-v8a-release-unsigned.apk
  app-x86_64-release-unsigned.apk
  app-universal-release-unsigned.apk
```

pixiewood の Gradle は release APK を署名しないため、CI では
`zipalign` + `apksigner` で署名してから artifact にしている。
`RELEASE_KEYSTORE_BASE64` などのシークレットを設定するとリリース鍵を、
未設定ならデバッグ鍵を使う。

## CI

- `.github/workflows/gtk4-android.yml`
  - `master` への `packaging/android-gtk4/**` の push、または
    `inkscape-gtk4-android-*` タグで起動。
  - ccache と wrap の packagecache をキャッシュし、GTK 本体の
    再コンパイルを短縮。
  - タグ push 時は追加で GitHub Release を作成し、APK をアップロード。
- `.github/workflows/gtk4-syntax.yml`
  - pixiewood の長いビルドを待たずに、ホストの GTK4 ヘッダで
    数分でコンパイル/リンクチェックする。

## 既知の制約

- GTK4 の Android バックエンドは **実験的**。GL レンダラーは未対応で、
  ソフトウェア (cairo) 描画になる。`GdkAndroidDisplay.init_egl failed`
  という警告はこれが理由で、動作には影響しない。
- Android 8 以前は非対応 (`minSdk 31`)。
- ファイルピッカーは `GtkFileChooserNative` 経由。端末に
  `ACTION_CREATE_DOCUMENT` を横取りするアプリがあると保存先選択が
  失敗することがある (エミュレータで確認)。
- `GtkSvg` は GTK の SVG レンダラーであり、Inkscape の編集機能
  (ノード編集・LPE・拡張機能など) はまだ含まれない。

## Inkscape 本体への道筋

最終目標は Inkscape 本体 (gtkmm4 ベースの UI) を Android で動かすこと。
段階的な計画:

1. **GTK4 シェル (現在)** — GTK4 + GtkSvg で SVG の表示・ズーム・
   PNG 書き出し。Android バックエンドの検証。
2. **gtkmm4 スタックのクロスビルド (完了)** — libsigc++ / glibmm /
   cairomm / pangomm / gtkmm を meson wrap で追加し、UI を gtkmm4 で
   書き直した。これは `packaging/android-gtkmm4/` に実装されており、
   `inkscape-gtkmm-android-*` タグでリリースされる。
   詳細は [`docs/GTKMM4_ANDROID.md`](GTKMM4_ANDROID.md) を参照。
   こちら (C API 版) は軽量なフォールバックとして維持する。
3. **Inkscape コアの統合** — Inkscape の `src/` 以下 (SPObject ツリー、
   2geom、livarot、SVG 入出力) を Android 向けにビルドし、GTK4 の
   キャンバスから利用する。Inkscape は CMake ビルドで依存も多い
   (Boehm GC、boost、gsl、lcms2 など) ため、ここが最大の難所。
4. **Inkscape UI の移植** — `src/ui/` の gtkmm4 ウィジェットを
   タッチ向けに調整し、デスクトップ版と同じ操作系を提供する。

## ファイル構成

```
packaging/android-gtk4/
  meson.build                 GTK4 アプリ本体の meson 定義
  pixiewood.xml               pixiewood 用マニフェスト (依存・ABI・configure options)
  data/
    org.inkscape.AndroidGtk4.metainfo.xml   app id / バージョン
    icon.svg                                アプリアイコン
  src/
    main.cpp                  GtkApplication、ヘッダーバー、ツールバー、アクション
    ink-canvas.{h,cpp}        SVG を表示するキャンバスウィジェット (パン/ズーム)
    ink-document.{h,cpp}      SVG の読み込み (svgz 対応) と PNG 書き出し
```

## 元の Inkscape コードとの関係

GTK4 版は `packaging/android-gtk4/` 以下に完全に分離されており、
Inkscape 本体の C++ コード (`src/` など) には一切手を加えていない。
これにより、上流 Inkscape の更新をそのまま追従できる。
