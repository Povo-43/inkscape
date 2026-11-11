project('inkscape-android-gtkmm4', 'c', 'cpp',
  version: '0.1.0',
  license: 'GPL-2.0-or-later',
  meson_version: '>= 1.8.0',
  default_options: [
    'cpp_std=c++17',
    'warning_level=2',
  ],
)

# GTK4 本体 (pixiewood が Android バックエンド付きでクロスビルドする)。
# これを最初に構成することで、GTK が内部でビルドする pango / cairo /
# gdk-pixbuf の dependency override が登録され、後から構成する
# pangomm / cairomm / gtkmm がそれらを再利用できる (二重ビルドの回避)。
gtk_dep = dependency('gtk4', version: '>= 4.22.0')

# GTK の公式 C++ バインディング (gtkmm) とその依存スタック。
# Inkscape 本体の UI は gtkmm4 で書かれているため、Android で Inkscape を
# 動かすにはこれらが必要になる。すべてピン留めしたリリース tarball を
# meson wrap で取得する (git master ではなく安定版)。
subproject('sigcpp-3.0')
subproject('glibmm-2.68')
subproject('cairomm-1.16')
subproject('pangomm-2.48')

gtkmm_dep = dependency('gtkmm-4.0', version: '>= 4.22.0')

executable('inkscape-android-gtkmm4',
  'src/main.cpp',
  dependencies: [gtkmm_dep, gtk_dep],
  install: true,
  android_exe_type: 'application',
)
