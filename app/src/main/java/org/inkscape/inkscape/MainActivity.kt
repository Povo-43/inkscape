package org.inkscape.inkscape

import android.os.Bundle
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity

/**
 * Inkscape のメインアクティビティ。
 *
 * ネイティブライブラリ (libinkscape.so) をロードし、初期化・バージョン取得・
 * シャットダウンを行う。ネイティブ側の実装は C++ (JNI) で行う。
 *
 * 注意: このモジュールには res/layout/activity_main.xml は存在しないため、
 * onCreate 内では setContentView(R.layout.*) ではなく、プログラム生成の
 * TextView を setContentView(View) で設定する。
 */
class MainActivity : AppCompatActivity() {

    companion object {
        // ネイティブライブラリ "inkscape-jni" (libinkscape-jni.so) を静的初期化ブロックでロード。
        // app/src/main/cpp/CMakeLists.txt で add_library(inkscape-jni SHARED ...) としてビルド
        // されている共有ライブラリに対応する。
        init {
            System.loadLibrary("inkscape-jni")
        }
    }

    // ネイティブメソッドの外部宣言 (C++ 側の JNI 関数に対応)
    external fun init(): Int
    external fun getVersion(): String
    external fun shutdown()

    // Activity 作成時にネイティブライブラリを初期化し、結果とバージョンを画面に表示
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // TextView をプログラム生成して画面に設定 (レイアウトXML未存在のため)
        val textView = TextView(this).apply {
            gravity = android.view.Gravity.CENTER
            textSize = 20f
            setPadding(24, 24, 24, 24)
        }
        setContentView(textView)

        try {
            val initResult = init()
            val version = getVersion()
            textView.text = "初期化結果: $initResult\nバージョン: $version"
        } catch (e: UnsatisfiedLinkError) {
            // ネイティブメソッドが解決できない場合などのエラー表示
            textView.text = getString(R.string.native_error) + "\n" + e.message
        } catch (e: Exception) {
            textView.text = "エラー: " + e.message
        }
    }

    // Activity 破棄時にネイティブライブラリをシャットダウン
    override fun onDestroy() {
        super.onDestroy()
        try {
            shutdown()
        } catch (e: Exception) {
            // シャットダウン時のエラーは無視して終了
        }
    }
}
