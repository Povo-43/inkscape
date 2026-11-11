# gtkmm4 on Android — Inkscape GTK4 (gtkmm) 版

このドキュメントは、`packaging/android-gtkmm4/` にある
**gtkmm4 で書き直した Inkscape for Android** について説明します。

GTK4 (C API) 版 (`packaging/android-gtk4/`) と機能はほぼ同じですが、
UI を Inkscape 本体と同じ **gtkmm4** で実装し、キャンバスと SVG 入出力は
C の実装 (`../android-gtk4/src/`) を共有しています。

## なぜ gtkmm なのか

Inkscape 本体のユーザーインターフェースは **gtkmm4** (GTK の C++
バインディング) で書かれています (`src/ui/` 以下)。
したがって「Android で Inkscape 本体を動かす」ためには、GTK4 だけでなく
次のスタックを Android NDK でクロスビルドできる必要があります。

```
gtkmm-4.0
  ├── gdkmm / gskmm
  ├── glibmm-2.68 (giomm)
  │     └── sigc++-3.0
  ├── cairomm-1.16
  │     ├── cairo
  │     └── sigc++-3.0
  ├── pangomm-2.48
  │     ├── cairomm-1.16
  │     ├── glibmm-2.68
  │     └── pangocairo (pango)
  ├── gtk4
  └── gdk-pixbuf-2.0
```

GTK4 シェル版 (`packaging/android-gtk4/`) は C の `Gtk*` API だけを使うため
これらは不要でしたが、Inkscape 本体へ進むには必須になります。

## ビルドの仕組み

`packaging/android-gtkmm4/subprojects/` に、各 C++ バインディングの
meson wrap ファイルを置いています。安定版をピン留めした
**リリース tarball** (`[wrap-file]`) を使います。これは
`gmmproc` (mm-common) によるコード生成を避けるためです。

- `sigcpp-3.0.wrap` → libsigc++ 3.8.1
- `glibmm-2.68.wrap` → glibmm 2.90.0
- `cairomm-1.16.wrap` → cairomm 1.19.1
- `pangomm-2.48.wrap` → pangomm 2.58.0
- `gtkmm-4.0.wrap` → gtkmm 4.24.0

`meson.build` では、まず `gtk4` を要求して GTK のサブプロジェクトを
構成します。GTK は内部で pango / cairo / gdk-pixbuf などをビルドし、
それらの `meson.override_dependency` を登録します。その後で
sigc++ / glibmm / cairomm / pangomm / gtkmm を構成することで、
pangomm が pango を、cairomm が cairo を再利用でき、二重ビルドを
避けられます。

### バージョンの対応関係 (重要)

GTK の `main` ブランチは開発版であり、**対応する開発版の
C++ バインディング**が必要です。

| C ライブラリ (main) | 必要なバインディング |
| --- | --- |
| GLib 2.90 系 | glibmm 2.90.0 (glib >= 2.89.4) |
| Pango 1.58 系 | pangomm 2.58.0 (pangocairo >= 1.58.0) |
| GTK 4.25 系 | gtkmm 4.24.0 (gtk4 >= 4.23.4) |

安定版の組み合わせ (glibmm 2.86 + gtkmm 4.22 など) では、GLib main で
`GDBusActionGroup` や `GEmblem` が final type に変更された影響で
生成済みヘッダが衝突し、ビルドに失敗します。

```
error: typedef redefinition with different types
       ('struct _GDBusActionGroupClass' vs 'struct GDBusActionGroupClass')
```

glibmm 2.90 ではこの変更にバージョンガードで対応しています。

### wrap の `directory` について

meson の `[wrap-file]` では、`directory` は **アーカイブのトップレベル
ディレクトリ名と一致**させる必要があります (meson はその名前の
ディレクトリを探すため)。一致しないと
`Subproject exists but has no meson.build file` になります。
サブプロジェクト名 (とオプション接頭辞) は wrap ファイル名から
決まります。たとえば `glibmm-2.68.wrap` なら
`-Dglibmm-2.68:build-documentation=false` のようになります。

### libc++_shared.so の同梱 (重要)

gtkmm / glibmm などは **共有 libc++** (`libc++_shared.so`) に依存します。
APK に同梱しないと起動時に

```
dlopen failed: library "libc++_shared.so" not found
```

でクラッシュします (GTK4 の C API だけを使う `android-gtk4` 版では
libc++ のシンボルを参照しないため不要でした)。

`.github/workflows/gtkmm4-android.yml` が NDK の `libc++_shared.so` を
`packaging/android-gtkmm4/libcxx/<abi>/` へコピーし、`meson.build` が
`install_data()` で APK の `lib/<abi>/` にインストールします。
`libcxx/` はビルド生成物なのでリポジトリには含めません。

## CI

- `.github/workflows/gtkmm4-android.yml`
  - `packaging/android-gtkmm4/**` の push、または
    `inkscape-gtkmm-android-*` タグで起動。
  - pixiewood でフルビルドし、APK に署名して artifact として保存。
  - タグ push 時は GitHub Release を作成し、APK をアップロード。
  - ccache と wrap の packagecache は `gtk4-android.yml` とキーを共有して
    GTK 本体の再コンパイルを避けています。
- `.github/workflows/gtk4-syntax.yml`
  - ホストの gtkmm ヘッダで `main.cpp` の構文・型チェックを行う。

## 現状

- gtkmm4 スタック (sigc++ / glibmm / cairomm / pangomm / gtkmm) の
  Android クロスビルドに成功。
- gtkmm4 の `Gtk::Application` + `Gtk::ApplicationWindow` による UI が
  エミュレータ上で動作することを確認済み。
- 機能は GTK4 (C API) 版と同等:
  SVG / SVGZ を開く、PNG 書き出し (1× / 2× / 4×)、ピンチズーム、
  ドラッグパン、ページにフィット、ファイルマネージャからの「開く」。

## 次の段階

1. gtkmm4 版をリリース (タグ `inkscape-gtkmm-android-*`)。
2. Inkscape コア (`src/` の SPObject ツリー、2geom、SVG 入出力) を
   Android 向けにビルドする。Boehm GC / boost / lcms2 / gsl などの
   依存が最大の難関。
3. Inkscape の `src/ui/` (gtkmm4 ウィジェット) をタッチ向けに調整して
   載せる。
