project('inkscape-android-gtkmm4', 'c', 'cpp',
  version: '0.1.0',
  license: 'GPL-2.0-or-later',
  meson_version: '>= 1.8.0',
  default_options: [
    'cpp_std=c++17',
    'warning_level=2',
  ],
)

# C++ バインディング (sigc++ / glibmm / cairomm / pangomm) を先に構成する。
# これにより GTK が構成される時点で、これらのサブプロジェクトが提供する
# pango / cairo などとの依存関係が一本化される (二重ビルドを避ける)。
subproject('sigcpp-3.0')
subproject('glibmm-2.68')
subproject('cairomm-1.16')
subproject('pangomm-2.48')

# GTK4 本体 (pixiewood が Android バックエンド付きでクロスビルドする)。
gtk_dep = dependency('gtk4', version: '>= 4.22.0')

# gtkmm (GTK の公式 C++ バインディング)。Inkscape 本体の UI は gtkmm4 で
# 書かれているため、Android で Inkscape を動かすにはこのスタックが必要。
gtkmm_dep = dependency('gtkmm-4.0', version: '>= 4.22.0')

executable('inkscape-android-gtkmm4',
  'src/main.cpp',
  dependencies: [gtkmm_dep, gtk_dep],
  install: true,
  android_exe_type: 'application',
)
