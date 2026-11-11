project('inkscape-android-gtkmm4', 'c', 'cpp',
  version: '0.4.0',
  license: 'GPL-2.0-or-later',
  meson_version: '>= 1.8.0',
  default_options: [
    'cpp_std=c++17',
    'warning_level=2',
  ],
)

fs = import('fs')

# GTK4 本体 (pixiewood が Android バックエンド付きでクロスビルドする)。
# これを最初に構成することで、GTK が内部でビルドする pango / cairo /
# gdk-pixbuf の dependency override が登録され、後から構成する
# pangomm / cairomm / gtkmm がそれらを再利用できる (二重ビルドの回避)。
gtk_dep = dependency('gtk4', version: '>= 4.22.0')

# GTK の公式 C++ バインディング (gtkmm) とその依存スタック。
# Inkscape 本体の UI は gtkmm4 で書かれているため、Android で Inkscape を
# 動かすにはこれらが必要になる。すべてピン留めしたリリース tarball を
# meson wrap で取得する。
#
# バージョンは GTK main (4.25 系) / GLib main (2.90 系) / Pango main
# (1.58 系) と整合する系列を選んでいる。C 側のライブラリが開発版で
# あるため、対応する開発版のバインディング (glibmm 2.90, pangomm 2.58,
# gtkmm 4.24) を使う必要がある。
subproject('sigcpp-3.0')
subproject('glibmm-2.68')
subproject('cairomm-1.16')
subproject('pangomm-2.48')

gtkmm_dep = dependency('gtkmm-4.0', version: '>= 4.24.0')

# キャンバスと SVG 入出力の C 実装は GTK4 (C API) 版と共有する。
shared_src = '../android-gtk4/src'

inkscape_sources = files(
  'src/main.cpp',
  shared_src / 'ink-canvas.cpp',
  shared_src / 'ink-document.cpp',
)

executable('inkscape-android-gtkmm4',
  inkscape_sources,
  include_directories: include_directories('src', shared_src),
  dependencies: [gtkmm_dep, gtk_dep],
  install: true,
  android_exe_type: 'application',
)

# C++ の標準ライブラリ (libc++_shared.so) を APK に同梱する。
# gtkmm などが共有 libc++ に依存するため、これがないと起動時に
# `library "libc++_shared.so" not found` でクラッシュする。
# 実体はワークフローのステップで NDK から libcxx/<abi>/ にコピーされる。
cxx_shared_abi = host_machine.cpu_family() == 'aarch64' ? 'arm64-v8a' : 'x86_64'
cxx_shared = 'libcxx' / cxx_shared_abi / 'libc++_shared.so'

if fs.exists(cxx_shared)
  install_data(cxx_shared, install_dir: get_option('libdir'))
else
  warning('libc++_shared.so が見つかりません (libcxx/' + cxx_shared_abi + '/)。APK が起動時にクラッシュします。')
endif
