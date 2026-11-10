# Proguard rules for Inkscape Android.
# Add project specific ProGuard rules here.
# By default, the flags in this file are appended to flags specified
# in /opt/android-sdk/build-tools/34.0.0/proguard/default.proguard.txt
# (or equivalent) and can be used to control what gets optimized and how.

# Keep native method names (JNI) from being obfuscated.
-keepclasseswithmembers class org.inkscape.inkscape.InkscapeNative {
    <methods>;
}

-keep class org.inkscape.inkscape.MainActivity { *; }
