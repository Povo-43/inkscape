project('inkscape-android-gtk4', 'c', 'cpp',
  version: '0.3.0',
  license: 'GPL-2.0-or-later',
  meson_version: '>= 1.8.0',
  default_options: [
    'cpp_std=c++17',
    'warning_level=2',
  ],
)

# GTK4 は Android バックエンド (GTK 4.22 以降で GtkSvg も利用可能) を備える。
# pixiewood (gtk-android-builder) が subprojects/ に GTK を展開し、
# クロスコンパイル済みの gtk4 を提供する。
gtk_dep = dependency('gtk4', version: '>= 4.22.0')

inkscape_sources = files(
  'src/main.cpp',
  'src/ink-canvas.cpp',
  'src/ink-document.cpp',
)

# Android では android_exe_type: 'application' を指定すると、
# meson が JNI から呼び出し可能な共有ライブラリとしてビルドする。
executable('inkscape-android-gtk4',
  inkscape_sources,
  include_directories: include_directories('src'),
  dependencies: [gtk_dep],
  install: true,
  android_exe_type: 'application',
)

# ホスト (デスクトップ GTK4) では、SVG の読み込みと PNG 書き出しを
# 自動テストする。Android では実行しない。
if host_machine.system() != 'android'
  render_test = executable('render-test',
    'tests/render-test.cpp',
    'src/ink-document.cpp',
    include_directories: include_directories('src'),
    dependencies: [gtk_dep],
  )

  test('render-test',
    render_test,
    args: [
      join_paths(meson.current_source_dir(), 'tests', 'sample.svg'),
      join_paths(meson.current_build_dir(), 'render-test.png'),
    ],
    timeout: 120,
  )
endif
