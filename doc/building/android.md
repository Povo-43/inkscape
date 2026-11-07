[Developer documentation](../readme.md) / [Compiling Inkscape](./readme.md) /

# Compiling Inkscape for Android

Inkscape runs on Android by way of the [GTK Android backend][gtk-android] (introduced
in GTK 4.18 via [MR !7555][gtk-mr]). GTK requests a blank `Surface` from Android and
renders into it with OpenGL ES; the native code is shipped as `libinkscape.so` and
loaded by the `org.gtk.android` runtime classes declared in `AndroidManifest.xml`.

This target is **experimental**. The upstream CI job (`inkscape:android` in
`.gitlab-ci.yml`) is `when: manual` with `allow_failure: true`, single-architecture
(arm64-v8a), and requires Android 12 (API 31) or higher. This document describes how
to reproduce the build locally.

> **Status note (2026-08):** the resulting APK builds and installs, but currently
> crashes on launch with `error 'Operation not permitted' during 'pthread_create'`
> (see [Known issues](#known-issues)). The build pipeline itself is functional and
> reproducible — that is what this page documents.

## Prerequisites

You need on the host:

- **Docker** — the entire cross-compilation toolchain (GNOME-for-Android sysroot,
  NDK, `aapt`/`zipalign`/`apksigner`) lives inside a CI Docker image. It is **not**
  in this repository.
- **`adb`** — to install the APK onto a device/emulator.
- An **Android device or emulator** with ABI `arm64-v8a` and **API ≥ 31**, with USB
  debugging enabled (`adb devices` must list it).

No Android SDK or NDK needs to be installed on the host directly — all of that is
provided inside the Docker image.

## 1. Pull the CI Docker image

The pinned image (matches `.gitlab-ci.yml:inkscape:android`) contains the sysroot
and build tools:

```bash
docker pull registry.gitlab.com/inkscape/infra/inkscape-ci-android/master@sha256:12e0806cf33a495f4d6c088f2e53630ca5b835d1aaabb836641b94533d00c914
```

Its interior (for reference):

| Path inside image | Contents |
|---|---|
| `/home/user/inkscape/deps/conan_toolchain.cmake` | Conan-generated CMake toolchain file for `aarch64-linux-android` |
| `/home/user/inkscape/packaging/{src,build,key.keystore}` | Staging dirs + the throwaway debug signing key used by `package.sh` |
| `$ANDROID_HOME` (`/usr/lib/android-sdk`) | Android SDK with `aapt`, `zipalign`, `apksigner`, platform `android-36` |
| `$NDK_VERSION` (`28.1.13356709`) | Android NDK r28 (clang 19, libc++) |
| `$PLATFORM_VERSION` (`android-36`) | Platform jar used by `aapt` |

The environment variables `$ANDROID_HOME`, `$NDK_VERSION`, and `$PLATFORM_VERSION`
are pre-set in the image and consumed by `packaging/android/package.sh`.

## 2. Configure the build

Run CMake inside the container, mounting the source tree at `/workspace`. The
container runs as a non-root user (`uid 1001`); set `--user 1000:1000` and
`-e HOME=/home/user` so that the mounted build directory is writable by you while
the toolchain (owned by `uid 1001`) remains readable.

> **Note on `ccache`:** the CI command enables ccache, but as a non-root user the
> container cannot write to the ccache directory under `/home/user`. Either disable
> ccache with `-DCCACHE_DISABLE=1` (simplest, used below) or point `CCACHE_DIR` at
> a writable location.

The Inkscape source uses two C++20 features that the libc++ shipped with the
Android NDK does not enable by default: `std::atomic_ref` (used in
`src/util/statics.h`) and `std::jthread`/`std::stop_token` (used in
`src/display/dispatch-pool.{h,cpp}`). These are supplied by a small force-included
header and a feature-test macro — see [the libc++ caveat](#libc-c20-caveat) below
for the full explanation. From the repository root:

```bash
IMG="registry.gitlab.com/inkscape/infra/inkscape-ci-android/master@sha256:12e0806cf33a495f4d6c088f2e53630ca5b835d1aaabb836641b94533d00c914"

docker run --rm --user 1000:1000 -e HOME=/home/user -e CCACHE_DISABLE=1 \
  -v "$PWD:/workspace" -w /workspace \
  "$IMG" bash -c '
    git config --global --add safe.directory "*"
    mkdir -p build && cd build
    cmake .. -GNinja \
      -DCMAKE_TOOLCHAIN_FILE=$HOME/inkscape/deps/conan_toolchain.cmake \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_FLAGS=-g0 \
      -DCMAKE_CXX_FLAGS="-g0 -include /workspace/packaging/android/atomic_ref_polyfill.h -D_LIBCPP_ENABLE_EXPERIMENTAL" \
      -DCMAKE_SHARED_LINKER_FLAGS=-s \
      -DWITH_INTERNAL_2GEOM=ON -DBUILD_TESTING=OFF -DWITH_GNU_READLINE=OFF
  '
```

On Android, `src/CMakeLists.txt` automatically builds `inkscape` as a shared
library (`libinkscape.so`) rather than an executable, because the GTK runtime loads
it via `System.loadLibrary`.

## 3. Compile

```bash
docker run --rm --user 1000:1000 -e HOME=/home/user -e CCACHE_DISABLE=1 \
  -v "$PWD:/workspace" -w /workspace/build \
  "$IMG" ninja
```

A full build produces ~1275 object files and three shared libraries under
`build/lib/`:

```
build/lib/lib2geom.so          (~1.0 MB)
build/lib/libinkscape_base.so  (~33  MB)
build/lib/libinkscape.so       (~44  KB)   ← loaded by the GTK Android runtime
build/lib/libinkview.so        (~30  KB)
```

Verify the result is an ARM64 Android binary:

```bash
file build/lib/libinkscape.so
# ELF 64-bit LSB shared object, ARM aarch64, ... for Android 31, built by NDK r28b, stripped
```

## 4. Package the APK

`packaging/android/package.sh` does the packaging. It resolves the transitive
`.so` dependency closure of `libinkscape.so` (via `copylibs.py`), stages the
`share/inkscape/` data assets, runs `aapt`/`zipalign`/`apksigner`, and writes the
APK to `~/inkscape/packaging/build/inkscape.apk` **inside the container**. Copy it
out to the host before the container exits:

```bash
docker run --rm --user 1000:1000 -e HOME=/home/user -e CCACHE_DISABLE=1 \
  -v "$PWD:/workspace" -w /workspace \
  "$IMG" bash -c '
    git config --global --add safe.directory "*"
    # Make the staging idempotent across re-runs:
    rm -rf ~/inkscape/packaging/src/lib ~/inkscape/packaging/src/assets \
           ~/inkscape/packaging/build/incremental.apk ~/inkscape/packaging/build/inkscape.apk 2>/dev/null
    bash packaging/android/package.sh
    cp ~/inkscape/packaging/build/inkscape.apk /workspace/inkscape.apk
  '
```

This yields `./inkscape.apk` (~40 MB), signed with the throwaway debug key already
present in the image. Inspect it with:

```bash
docker run --rm --user 1000:1000 -e HOME=/home/user -v "$PWD:/workspace" "$IMG" \
  aapt dump badging /workspace/inkscape.apk | head
```

## 5. Install and launch

```bash
adb install -r inkscape.apk
adb shell am start -n org.inkscape.inkscape/org.gtk.android.ToplevelActivity
```

Capture a screenshot and logs with:

```bash
adb shell screencap -p /sdcard/ink.png && adb pull /sdcard/ink.png
adb logcat -d | grep -iE "inkscape|gtk|fatal|signal"
```

## libc++ C++20 caveat

The Android NDK's libc++ deliberately leaves several C++20 features disabled, and
the Inkscape source relies on two of them. The build flags above work around both
without modifying Inkscape source:

1. **`std::atomic_ref`** — not present in `<atomic>` at all in NDK r27/r28 (the
   `__cpp_lib_atomic_ref` feature-test macro is declared but commented out).
   `packaging/android/atomic_ref_polyfill.h` defines a minimal `std::atomic_ref<T>`
   on top of the `__atomic_*` compiler builtins (which are always available). It is
   force-included via `-include`.

2. **`std::jthread` / `std::stop_token`** — present in the headers but disabled by
   `_LIBCPP_HAS_NO_EXPERIMENTAL_STOP_TOKEN`, which libc++ defines unless
   `_LIBCPP_ENABLE_EXPERIMENTAL` is set. Adding
   `-D_LIBCPP_ENABLE_EXPERIMENTAL` to `CMAKE_CXX_FLAGS` re-enables them.

Both of these landed in Inkscape after the Android packaging was added, so the
upstream manual CI job has been silently broken (it never blocked because of
`allow_failure: true`). A clean upstream fix is to bake these two flags into the CI
job's `cmake` line in `.gitlab-ci.yml`, or to add an `#ifdef __ANDROID__` fallback
in `src/util/statics.h`.

## Known issues

### App crashes on launch: `pthread_create` denied

On Android 12+ the built APK installs but immediately crashes during startup with:

```
F libc    : Fatal signal 5 (SIGTRAP), code -6 (SI_TKILL)
F DEBUG   : Abort message: 'file .../glib/gthread-posix.c: line 774
            (g_system_thread_new): error "Operation not permitted" during "pthread_create"'
```

GLib's thread-spawning path is being refused by the OS. This is a runtime/platform
issue in the GLib+GTK-on-Android stack, not a build problem — the libraries link
and load fine. Investigating it is the next step toward a usable Android build.

## Files in `packaging/android/`

| File | Purpose |
|---|---|
| `package.sh` | Main packaging script (staging → `aapt` → `zipalign` → `apksigner`) |
| `copylibs.py` | Walks the ELF `DT_NEEDED` closure and bundles transitive `.so` deps |
| `AndroidManifest.xml`, `res/` | Manifest + launcher icon / theme resources copied into the APK |
| `atomic_ref_polyfill.h` | Force-included polyfill for `std::atomic_ref` (see caveat above) |
| `genicons.py` | Manual one-off script to regenerate `res/mipmap-*/ic_launcher.png` |
| `README.md` | Short description of each file |

## Problems

☎ _If you can't solve your issue with the information above, please [ask in the chat](https://chat.inkscape.org/channel/team_devel) or [report a bug](https://inkscape.org/report)_.

## See also
- [Compiling Inkscape on Linux](linux.md)
- GTK Android backend: [MR !7555][gtk-mr] · [GNOME Discourse overview][gtk-android]

[gtk-android]: https://discourse.gnome.org/t/what-versions-of-android-does-the-gtk4-demo-support/28598
[gtk-mr]: https://gitlab.gnome.org/GNOME/gtk/-/merge_requests/7555
