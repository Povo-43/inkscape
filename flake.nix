{
  description = "Local dev shell with GTK and build tools";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };

        pythonPackages = pkgs.python3.withPackages (ps: with ps; [
          lxml
          pyyaml
          pip
          cython
          cssselect
          numpy
          pyserial
          tinycss2
          webencodings
        ]);
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [

            adwaita-icon-theme
            bc
            blas
            boehmgc
            boost
            cairomm
            dejavu_fonts
            double-conversion
            doxygen
            gcovr
            glib
            glibmm
            gsl
            gspell
            gtest
            gtk3
            gtk4
            gtkmm3
            gtkmm4
            gtksourceview4
            gtksourceview5
            imagemagick
            intltool
            jemalloc
            lapack
            lcms2
            libcdr
            libepoxy
            libpng
            librevenge
            libsigcxx
            libspelling
            libvisio
            libwmf
            libwpg
            libxml2
            libxslt
            meson
            pango
            pangomm
            poppler
            poppler
            potrace
            readline
            scour
            wget

            # build
            cmake
            ninja
            git
            ccache
            clang-tools
            pkg-config

            #editors
            neovim

            pythonPackages
          ];

          shellHook = ''
            echo "✅ Dev shell ready."
          '';
        };
      });
}
