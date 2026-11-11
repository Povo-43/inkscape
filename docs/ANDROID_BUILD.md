# Inkscape for Android - ビルド手順・使い方・内部構成

Inkscape の Android 移植プロジェクトです。GTK4 の GUI 部分は Android では動作しませんが、
SVG の解析・ラスタライズをネイティブ実装 (resvg) で行い、Android 上で実際に
SVG を表示・PNG 書き出しできるアプリとしてビルドします。

---

## 1. 概要

### 1.1 できること

| 機能 | 状態 |
|------|------|
| SVG ファイルを開く (SAF / 他アプリからの共有) | 動作 |
| SVG のプレビュー表示 | 動作 |
| ピンチズーム / ドラッグパン / ダブルタップで全体表示 | 動作 |
| ドキュメント情報の表示 (サイズ・要素数・テキスト有無など) | 動作 |
| PNG 書き出し (512 / 1024 / 2048 / 4096 px / 元サイズ) | 動作 |
| GTK4 GUI (Inkscape の編集画面) | 未対応 |
| 編集・保存 (SVG の編集) | 未対応 |

### 1.2 レンダリングエンジン

SVG の解析と描画には [resvg](https://github.com/linebender/resvg) (純 Rust 実装の
SVG レンダラー) を使用しています。

- `usvg` が SVG / SVGZ / CSS / テキスト / グラデーション / フィルタ / マスク /
  クリップパス / パターン / 埋め込みラスタ画像を解析
- `tiny-skia` がアンチエイリアス付きでラスタライズ
- `fontdb` が `/system/fonts` のフォントを読み込み、`sans-serif` などの
  総称ファミリーも解決

Inkscape 本体のコア (GTK4 / gtkmm4 / glibmm / lib2geom) は Android バックエンドを
持たないためリンクしていません。元の Inkscape C++ コードは一切変更せず、
Android 固有のコードのみを追加しています。

### 1.3 検証済みの内容

- Android 13 (x86_64) エミュレータ上で APK をインストールし、以下を確認
  - ネイティブライブラリのロードと初期化
  - `testfiles/sample.svg` の解析 (200x200 / 5 要素 / テキスト検出) と描画
  - 実際の Inkscape ドキュメント `share/tutorials/tutorial-basic.svg`
    (2,883 要素、グラデーション・パターン・テキストを含む) の描画
  - Android 上でネイティブレンダラー単体を実行し、同じ SVG を PNG 化
- リポジトリ同梱の Inkscape SVG **3,351 ファイルすべて**をレンダリングし、
  失敗 0 件であることを確認 (アイコン、チュートリアル全言語版、
  グラデーション / フィルタ / パターン / クリップ / マスクを含む)
- テキストは Android の `/system/fonts` を利用して描画

### 1.4 アーキテクチャ

```
MainActivity.kt (Kotlin)
  │  external fun (JNI)
  ▼
libinkscape-jni.so (src/android_jni.cpp)
  │  C ABI
  ▼
libinkscape_svg_renderer.a (app/src/main/rust/svg-renderer, resvg)
```

- Kotlin: ファイル選択、プレビュー、ズーム/パン、PNG 保存、UI
- C++ (`src/android_jni.cpp`): JNI 境界、ファイル I/O、エラー処理
- Rust: SVG の解析と PNG へのラスタライズ (C ABI のみ公開)

---

## 2. ビルド要件

| 項目 | バージョン |
|------|-----------|
| Android SDK | API 35 |
| Android build-tools | 34.0.0 |
| Android NDK | 26.3.11579264 |
| CMake | 3.22.1 (NDK 同梱) |
| JDK | 17 以上 (21 でも可) |
| Gradle | 8.10.2 (wrapper 同梱) |
| Rust | stable (1.80 以上を推奨) |

### 2.1 Rust の準備

```bash
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
```

Gradle の `cargoBuild*` タスクが自動的に 3 ABI 向けにクロスコンパイルします。
`cargo` は `~/.cargo/bin/cargo` を優先して使用します。

### 2.2 環境変数

- `ANDROID_HOME` または `local.properties` の `sdk.dir` に Android SDK を設定
- NDK は `$ANDROID_HOME/ndk/26.3.11579264` に配置 (Gradle が `ndkVersion` で参照)

---

## 3. ローカルビルド

```bash
./gradlew :app:assembleDebug
```

成果物: `app/build/outputs/apk/debug/app-debug.apk`

ビルドの流れ:

1. `cargoBuild<ABI>` が Rust レンダラーを静的ライブラリへビルド
   (`app/build/rust/<ABI>/libinkscape_svg_renderer.a`)
2. CMake が `src/android_jni.cpp` と静的ライブラリをリンクして
   `libinkscape-jni.so` を生成
3. Gradle が 3 ABI 分を APK に同梱

Rust 部分だけをテストする場合:

```bash
cd app/src/main/rust/svg-renderer
cargo run --release --example render -- ../../../../../testfiles/sample.svg /tmp/out.png 512 512
```

### 3.1 リリースビルド

```bash
./gradlew :app:assembleRelease
```

`RELEASE_STORE_FILE` / `RELEASE_STORE_PASSWORD` / `RELEASE_KEY_ALIAS` /
`RELEASE_KEY_PASSWORD` が設定されていればリリース署名、未設定ならデバッグ署名になります。

---

## 4. APK のインストール

```bash
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

複数デバイス接続時は `adb -s <シリアル> install ...` を使用します。

---

## 5. アプリの使い方

1. **開く**: ファイルピッカーから SVG (`.svg` / `.svgz`) を選択します。
   他のアプリの「共有 / 開く」から起動することもできます。
   選択したファイルはアプリのキャッシュへコピーされ、ネイティブ側で解析されます。
2. **プレビュー**: 最大幅 2048 px でレンダリングした結果を表示します。
   - ピンチ: ズーム
   - ドラッグ: パン
   - ダブルタップ: 全体表示に戻す
3. **PNG保存**: 書き出しサイズを選択し、保存先を指定します。
4. **全体表示**: 画像を画面にフィットさせます。
5. 画面下部にドキュメント情報 (幅・高さ・要素数・テキスト有無・エラー) を表示します。

---

## 6. リリースフロー (GitHub Actions)

`.github/workflows/release-apk.yml` が以下を自動実行します。

1. `inkscape-android-*` タグの push、または Release の公開、または手動実行で起動
2. Rust ツールチェーン + Android ターゲットをセットアップ
3. Rust レンダラーのホスト向けスモークテスト
4. `./gradlew :app:assembleDebug` で APK をビルド (Rust は Gradle が自動ビルド)
5. GitHub REST API でリリースを作成 (未作成時)
6. GitHub Uploads API (`curl`) で APK をアセットとしてアップロード

### 6.1 リリース署名

| シークレット | 説明 |
|-------------|------|
| `RELEASE_STORE_FILE` | キーストアファイルのパス |
| `RELEASE_STORE_PASSWORD` | キーストアのパスワード |
| `RELEASE_KEY_ALIAS` | 鍵のエイリアス |
| `RELEASE_KEY_PASSWORD` | 鍵のパスワード |

---

## 7. 制限事項

| 項目 | 状況 |
|------|------|
| GTK4 GUI | 未対応。GTK4 に Android バックエンドが存在しないため |
| 編集機能 | 未対応。表示・PNG 書き出しのみ |
| Inkscape 固有機能 | 未対応 (拡張機能、フィルタエディタ、パス操作など) |
| 署名 | 既定はデバッグ署名 |
| 一部 SVG 機能 | resvg が未対応の機能 (SMIL アニメーション、一部の CSS) は描画されません |
| 外部参照画像 | SVG 内の相対パスで参照される外部画像は解決できません (data URI の埋め込み画像は表示されます) |

---

## 8. トラブルシューティング

- **`SVG レンダラーの静的ライブラリが見つかりません`**
  `cargoBuild*` が失敗しています。`rustup target list --installed` で Android
  ターゲットを確認し、`cargo build --release --target aarch64-linux-android` を
  手動実行してエラーを確認してください。
- **テキストが表示されない**
  `/system/fonts` にフォントがあるか確認してください。総称ファミリー
  (`sans-serif` 等) は利用可能なフォントへ自動的に割り当てられます。
- **メモリ不足**
  4096 px の書き出しは端末によっては失敗します。512〜2048 px を試してください。
