package org.inkscape.inkscape

import android.net.Uri
import android.os.Bundle
import android.text.method.ScrollingMovementMethod
import android.util.TypedValue
import android.view.Gravity
import android.view.ViewGroup
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import java.io.File

/**
 * Inkscape Android アプリのメインアクティビティ。
 *
 * レイアウト XML は使用せず、すべてプログラムで UI を構築する。
 * Inkscape JNI ライブラリ（inkscape-jni）と連携し、SVG のオープン・情報取得・PNG エクスポートを行う。
 */
class MainActivity : AppCompatActivity() {

    // ========================================================================
    // ネイティブメソッド（Inkscape JNI とリンク）
    // ========================================================================

    /** ネイティブライブラリの初期化。0 なら成功、それ以外は失敗。 */
    external fun init(): Int
    /** Inkscape のバージョン文字列を取得。 */
    external fun getVersion(): String
    /** ネイティブリソースの解放。 */
    external fun shutdown()

    /** 指定パスの SVG ファイルを開く。成功なら true。 */
    external fun openFile(path: String): Boolean
    /** 開いているドキュメントの情報を JSON 文字列で取得。 */
    external fun getDocumentInfo(path: String): String
    /** SVG を PNG へエクスポート。成功なら true。 */
    external fun exportPng(
        inputPath: String,
        outputPath: String,
        width: Int,
        height: Int
    ): Boolean
    /** ネイティブ側が使用可能か。 */
    external fun isNativeReady(): Boolean

    companion object {
        init {
            System.loadLibrary("inkscape-jni")
        }
    }

    // ========================================================================
    // UI コンポーネント（プログラム生成。レイアウト XML は使用しない）
    // ========================================================================

    private lateinit var versionTextView: TextView
    private lateinit var openButton: Button
    private lateinit var filePathTextView: TextView
    private lateinit var docInfoTextView: TextView
    private lateinit var exportButton: Button
    private lateinit var statusTextView: TextView

    /** 現在選択中の SVG の実パス（取得不能な場合は Uri 文字列）。 */
    private var currentFilePath: String? = null

    /** SVG ファイル選択ピッカーの結果を受け取るランチャー。
     *  OpenDocument() は入力として MIME タイプの Array<String> を受け取り、
     *  出力として 選択済み Uri の Array<Uri> を返す。
     */
    private val openDocumentLauncher: ActivityResultLauncher<Array<String>> =
        registerForActivityResult(ActivityResultContracts.OpenDocument()) { result ->
            val uris = result as Array<Uri>
            val selectedUri = if (uris.isNotEmpty()) uris[0] else null
            onSvgSelected(selectedUri)
        }

    // ========================================================================
    // ライフサイクル
    // ========================================================================

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        buildUI()

        // ネイティブ初期化
        val initResult = init()
        val version = getVersion()
        versionTextView.text = "Inkscape バージョン: $version"
        statusTextView.text = if (initResult == 0) {
            "ネイティブ初期化: 成功 (init=$initResult)"
        } else {
            "ネイティブ初期化: 失敗 (init=$initResult)"
        }

        // ボタンのクリックリスナー設定
        openButton.setOnClickListener {
            // image/svg+xml のみを選択可能なファイルピッカーを起動
            openDocumentLauncher.launch(arrayOf("image/svg+xml"))
        }

        exportButton.setOnClickListener {
            onExportPngClicked()
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        shutdown()
    }

    // ========================================================================
    // UI 構築
    // ========================================================================

    /** 画面全体をプログラムで構築する。 */
    private fun buildUI() {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
            val pad = dp(16f).toInt()
            setPadding(pad, pad, pad, pad)
        }

        // --- 上部: バージョン表示 ---
        versionTextView = TextView(this).apply {
            text = "Inkscape バージョン: 読み込み中..."
            textSize = 18f
            typeface = android.graphics.Typeface.create(android.graphics.Typeface.DEFAULT, android.graphics.Typeface.BOLD)
            gravity = Gravity.CENTER
        }
        root.addView(versionTextView, wrapParams(top = 8f, bottom = 8f))

        // --- 中央: 「SVG ファイルを開く」ボタン ---
        openButton = Button(this).apply {
            text = "SVG ファイルを開く"
            textSize = 16f
        }
        root.addView(openButton, wrapParams(top = 4f, bottom = 4f, centerHorizontal = true))

        // 選択ファイルパス表示
        filePathTextView = TextView(this).apply {
            text = "選択ファイル: なし"
            textSize = 14f
            gravity = Gravity.CENTER
        }
        root.addView(filePathTextView, wrapParams(bottom = 8f))

        // --- 下部: ドキュメント情報（JSON） ---
        docInfoTextView = TextView(this).apply {
            text = "ドキュメント情報: 未取得"
            textSize = 13f
            movementMethod = ScrollingMovementMethod()
            // 長い JSON をスクロール可能に
            maxLines = 6
        }
        root.addView(docInfoTextView, fillParams(weight = 1f, top = 4f, bottom = 4f))

        // PNG エクスポートボタン
        exportButton = Button(this).apply {
            text = "PNG エクスポート"
            textSize = 16f
        }
        root.addView(exportButton, wrapParams(top = 4f, bottom = 4f, centerHorizontal = true))

        // ステータス表示
        statusTextView = TextView(this).apply {
            text = "ステータス: 初期化中..."
            textSize = 14f
            gravity = Gravity.CENTER
        }
        root.addView(statusTextView, wrapParams(bottom = 8f))

        setContentView(root)
    }

    /** 幅・高さ WRAP_CONTENT の LinearLayout.LayoutParams を生成。 */
    private fun wrapParams(
        top: Float = 0f,
        bottom: Float = 0f,
        centerHorizontal: Boolean = false
    ): LinearLayout.LayoutParams {
        val params = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT,
            ViewGroup.LayoutParams.WRAP_CONTENT
        )
        params.topMargin = dp(top).toInt()
        params.bottomMargin = dp(bottom).toInt()
        if (centerHorizontal) {
            params.gravity = Gravity.CENTER_HORIZONTAL
        }
        return params
    }

    /** 幅 MATCH_PARENT・高さ WRAP_CONTENT の LinearLayout.LayoutParams を生成。 */
    private fun fillParams(
        weight: Float = 0f,
        top: Float = 0f,
        bottom: Float = 0f
    ): LinearLayout.LayoutParams {
        val params = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT
        )
        params.weight = weight
        params.topMargin = dp(top).toInt()
        params.bottomMargin = dp(bottom).toInt()
        return params
    }

    /** dp 値をピクセルに変換。 */
    private fun dp(value: Float): Float =
        TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value, resources.displayMetrics)

    // ========================================================================
    // イベントハンドラ
    // ========================================================================

    /** ファイルピッカーで SVG が選択された際の処理。 */
    private fun onSvgSelected(uri: Uri?) {
        if (uri == null) {
            statusTextView.text = "ファイルが選択されませんでした"
            return
        }

        // 実パスを取得を試行（失敗すれば Uri 文字列を保持）
        val path = getRealPathFromUri(uri)
        currentFilePath = path
        filePathTextView.text = "選択ファイル: $path"

        if (!isNativeReady()) {
            statusTextView.text = "エラー: ネイティブが準備完了していません"
            return
        }

        if (openFile(path)) {
            statusTextView.text = "SVG ファイルを開きました"
            val json = getDocumentInfo(path)
            docInfoTextView.text = if (json.isNotEmpty()) json else "ドキュメント情報: 空"
        } else {
            statusTextView.text = "SVG ファイルを開けませんでした"
            docInfoTextView.text = "ドキュメント情報: 取得失敗"
        }
    }

    /** 「PNG エクスポート」ボタンクリック時の処理。 */
    private fun onExportPngClicked() {
        val inputPath = currentFilePath ?: run {
            statusTextView.text = "エラー: SVG ファイルが選択されていません"
            return
        }

        if (!isNativeReady()) {
            statusTextView.text = "エラー: ネイティブが準備完了していません"
            return
        }

        // 出力パスは内部ストレージ (filesDir) 下
        val outputFile = File(filesDir, "export.png")
        val outputPath = outputFile.absolutePath

        // 1024x1024 でエクスポート
        val success = exportPng(inputPath, outputPath, 1024, 1024)
        statusTextView.text = if (success) {
            "PNG エクスポート成功: $outputPath"
        } else {
            "PNG エクスポート失敗"
        }
    }

    // ========================================================================
    // URI -> 実パス 解決
    // ========================================================================

    /**
     * content:// URI から実ファイルパスを取得を試みる。
     *
     * 手順:
     *  1. DocumentFile.fromSingleUri() で File へ変換を試行
     *  2. contentResolver.openFileDescriptor() + /proc/self/fd で実パスを特定を試行
     *  3. どちらも失敗すれば Uri 文字列をそのまま返す
     *
     * Android 10+ (Scoped Storage) では content URI から直接ファイルパスが
     * 得られない場合があるため、フォールバックとして Uri 文字列を保持する。
     * JNI 側が content URI を直接扱えない場合は、ここをコピー処理に差し替える必要がある。
     */
    private fun getRealPathFromUri(uri: Uri): String {
        // openFileDescriptor + /proc/self/fd から実パス特定を試行
        contentResolver.openFileDescriptor(uri, "r")?.use { fd ->
            try {
                val link = File("/proc/self/fd/${fd.fd}")
                if (link.exists()) {
                    val canonicalPath = link.absoluteFile.canonicalPath
                    if (canonicalPath != null && canonicalPath.isNotEmpty()) {
                        return canonicalPath
                    }
                }
            } catch (e: Exception) {
                // フォールバックへ
            }
        }

        // 取得不能なら Uri 文字列をそのまま保持
        return uri.toString()
    }
}
