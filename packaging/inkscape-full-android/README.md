# Inkscape Full for Android

Inkscape の C++ コアを Android 向けにクロスコンパイルし、
GTK4 + gtkmm4 スタックと共に APK としてパッケージングする。

## ビルド構成

```
┌─────────────────────────────────────────────┐
│              Android APK                     │
├─────────────────────────────────────────────┤
│  libinkscape-android.so (JNI entry point)   │
├─────────────────────────────────────────────┤
│  Inkscape C++ Core                          │
│  ├── src/desktop.cpp, document.cpp, ...    │
│  ├── src/ui/ (gtkmm4 widgets)               │
│  ├── src/display/ (cairo rendering)         │
│  ├── src/svg/ (SVG parser)                  │
│  ├── src/trace/ (bitmap tracing)            │
│  └── src/extension/ (extension system)      │
├─────────────────────────────────────────────┤
│  Inkscape Dependencies                      │
│  ├── 2geom (geometry)                       │
│  ├── Boost (stacktrace, system, thread)     │
│  ├── GSL (scientific library)               │
│  ├── lcms2 (color management)               │
│  ├── libxml2, libxslt (XML/XSLT)            │
│  ├── libcroco (CSS parsing)                 │
│  ├── libdepixelize (image tracing)          │
│  ├── libadaptagrams (diagram layout)        │
│  ├── libautotrace (bitmap tracing)          │
│  ├── libuemf (WMF/EMF)                      │
│  └── potrace (bitmap tracing)               │
├─────────────────────────────────────────────┤
│  GTK4 + gtkmm4 Stack (pixiewood)            │
│  ├── gtk4 (Android backend)                 │
│  ├── glib, gobject, gio                     │
│  ├── pango, pangocairo                      │
│  ├── cairo, pixman                          │
│  ├── gdk-pixbuf                             │
│  ├── graphene                               │
│  ├── harfbuzz, freetype, fontconfig         │
│  ├── glibmm, giomm                          │
│  ├── cairomm, pangomm                       │
│  └── gtkmm (C++ bindings)                   │
├─────────────────────────────────────────────┤
│  Android NDK (bionic libc, libc++)          │
└─────────────────────────────────────────────┘
```

## ビルド方法

### GitHub Actions

`inkscape-full-android` ワークフローを手動で実行する。
タグ `inkscape-full-android-*` をプッシュするとリリースが作成される。

### 手動ビルド

```bash
# 依存ライブラリのビルド
bash packaging/inkscape-full-android/build-deps.sh \
  /tmp/inkscape-deps /opt/android-ndk-r27b 31

# Inkscape コアのビルド
cd /tmp/inkscape-build
cmake $INKSCAPE_SRC \
  -DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/android.toolchain.cmake \
  -DANDROID_ABI=arm64-v8a \
  -DANDROID_PLATFORM=android-31 \
  -DCMAKE_INSTALL_PREFIX=/tmp/inkscape-install
make -j$(nproc)
```

## パッチ

`patches/inkscape-android-compat.patch` を適用する:

```bash
cd $INKSCAPE_SRC
patch -p1 < packaging/inkscape-full-android/patches/inkscape-android-compat.patch
```

修正内容:

1. **cast.h**: clang 17 / C++20 での static_assert の誤発火を修正
2. **variant-visitor.h**: deduction guide を追加
3. **dispatch-pool.cpp**: cv.wait(stop_token) をポーリングに置換
4. **measure-tool.cpp**: std::vformat を Glib::ustring::compose に置換
5. **autotrace**: cmake_minimum_required 追加, HAVE_CONFIG_H 定義
6. **adaptagrams**: cmake_minimum_required 追加
7. **2geom**: Boost バージョン制約を削除

## 互換ヘッダー

`compat/` ディレクトリのヘッダーを `-include` フラグで先読みする:

| ヘッダー | 用途 |
|---------|------|
| android_fix.h | stdint.h 型定義 (int8_t〜uint64_t, __uint32_t 等) |
| atomic_ref_compat.h | std::atomic_ref (C++20, NDK libc++ 未対応) |
| format | std::format (C++20, NDK libc++ 未対応) |
| stop_token | std::stop_token / std::jthread (C++20, NDK libc++ 未対応) |

## 既知の制限

- `std::format` は簡易実装（位置指定 + 基本的な書式のみ）
- `std::stop_token` は簡易実装（ポーリングベース）
- Inkscape の一部機能（PDF エクスポート等）は無効化される
- NLS (gettext) は無効化
- Pythion extension システムは未対応
