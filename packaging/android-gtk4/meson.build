project('inkscape-android-gtk4', 'c', 'cpp',
  version: '0.1.0',
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

# Android では android_exe_type: 'application' を指定すると、
# meson が JNI から呼び出し可能な共有ライブラリとしてビルドする。
executable('inkscape-android-gtk4',
  'src/main.cpp',
  dependencies: [gtk_dep],
  install: true,
  android_exe_type: 'application',
)
