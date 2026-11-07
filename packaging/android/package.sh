#! /bin/bash

set -e
shopt -s extglob

# Get directory names
SCRIPTDIR="$(dirname "$(readlink -f "$0")")"
BUILDDIR="$SCRIPTDIR/../../build"

# Enter apk staging directory.
cd ~/inkscape/packaging/src

# Copy in resources and manifest (actually link).
ln -sf "$SCRIPTDIR/res" .
ln -sf "$SCRIPTDIR/AndroidManifest.xml" .

# Copy in libs (actually link).
if [ ! -d lib ]; then
    mkdir -p lib/arm64-v8a

    "$SCRIPTDIR/copylibs.py" "$BUILDDIR/lib/libinkscape.so" -s "$BUILDDIR/lib" -o lib/arm64-v8a -l

    ln -s "$BUILDDIR/lib/libinkscape.so" lib/arm64-v8a
    ln -s "$ANDROID_HOME/ndk/$NDK_VERSION/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" lib/arm64-v8a

    # LD_PRELOAD shim (pthread_create EPERM workaround for Android 12). See
    # packaging/android/pthread_fix.c. Bundle the shim and a wrap.sh that
    # sets LD_PRELOAD before the app starts. Only honoured on debuggable builds.
    if [ -f "$SCRIPTDIR/libpthread_fix.so" ]; then
        cp "$SCRIPTDIR/libpthread_fix.so" lib/arm64-v8a
        printf '#!/system/bin/sh\nHERE="$(cd "$(dirname "$0")" && pwd)"\nexport LD_PRELOAD="$HERE/libpthread_fix.so"\nexec "$@"\n' > lib/arm64-v8a/wrap.sh
    fi
fi

# Install to temporary directory, then selectively copy in needed files.
if [ ! -d assets/share/inkscape ]; then
    DESTDIR=/tmp/ink-tmp-install cmake --install "$BUILDDIR" --prefix /

    mkdir -p assets/share/inkscape
    cp -r /tmp/ink-tmp-install/share/inkscape/@(attributes|doc|filters|icons|keys|markers|paint|palettes|screens|symbols|templates|ui) assets/share/inkscape
    rm assets/share/inkscape/doc/!(AUTHORS|TRANSLATORS|LICENSE)

    rm -rf /tmp/ink-tmp-install
fi

# Create the apk minus the core libs.
if [ ! -f ../build/incremental.apk ]; then
    find -L assets -type f -not -name afpr -exec sha256sum {} \; | sha256sum | head -c 64 > assets/afpr

    aapt package -v -f -I "$ANDROID_HOME/platforms/$PLATFORM_VERSION/android.jar" -M AndroidManifest.xml -S res -A assets -F ../build/incremental.apk
    aapt add ../build/incremental.apk classes.dex
    aapt add ../build/incremental.apk lib/arm64-v8a/!(lib2geom.so|libinkscape_base.so|libinkscape.so)
    aapt add ../build/incremental.apk lib/arm64-v8a/wrap.sh 2>/dev/null || true
fi

# Also add the core libs.
cp ../build/incremental.apk ../build/inkscape.apk
aapt add ../build/inkscape.apk lib/arm64-v8a/@(lib2geom.so|libinkscape_base.so|libinkscape.so)

# Zipalign and sign with throwaway debug key.
cd ../build

zipalign -P 16 -f -v 4 inkscape.apk inkscape.apk2
mv inkscape.apk2 inkscape.apk

echo password | apksigner sign --ks ../key.keystore --min-sdk-version 31 --out inkscape.apk2 inkscape.apk
mv inkscape.apk2 inkscape.apk
rm inkscape.apk2.idsig
