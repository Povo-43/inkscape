package org.inkscape.inkscape

import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.method.ScrollingMovementMethod
import android.util.Log
import android.util.TypedValue
import android.view.GestureDetector
import android.view.Gravity
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.ViewGroup
import android.widget.Button
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import java.io.File
import java.util.concurrent.Executors
import kotlin.math.min

/**
 * Inkscape Android アプリのメインアクティビティ。
 *
 * レイアウト XML は使用せず、すべてプログラムで UI を構築する。
 * SVG の解析・ラスタライズはネイティブ側 (resvg) が行い、このアクティビティは
 * ファイル選択・プレビュー表示・ズーム/パン・PNG 書き出しを担当する。
 */
class MainActivity : AppCompatActivity() {

    // ========================================================================
    // ネイティブメソッド（libinkscape-jni.so）
    // ========================================================================

    /** ネイティブライブラリの初期化。0 なら成功。 */
    external fun init(): Int

    /** Inkscape / レンダラーのバージョン文字列。 */
    external fun getVersion(): String

    /** ネイティブリソースの解放。 */
    external fun shutdown()

    /** SVG を実際にパースして開けるか確認する。 */
    external fun openFile(path: String): Boolean

    /** SVG のドキュメント情報を JSON 文字列で取得する。 */
    external fun getDocumentInfo(path: String): String

    /** SVG を PNG ファイルへ書き出す。 */
    external fun exportPng(
        inputPath: String,
        outputPath: String,
        width: Int,
        height: Int
    ): Boolean

    /** SVG を PNG バイト列へレンダリングする（プレビュー用）。 */
    external fun renderSvgPng(path: String, width: Int, height: Int): ByteArray?

    /** SVG のバイト列を PNG バイト列へレンダリングする。 */
    external fun renderSvgDataPng(data: ByteArray, width: Int, height: Int): ByteArray?

    /** レンダラー (resvg) のバージョン。 */
    external fun getRendererVersion(): String

    /** 直近のレンダリングエラー。 */
    external fun getLastError(): String

    /** ネイティブ側が使用可能か。 */
    external fun isNativeReady(): Boolean

    companion object {
        init {
            System.loadLibrary("inkscape-jni")
        }

        /** プレビュー用の最大レンダリング幅 (px)。 */
        private const val PREVIEW_MAX_WIDTH = 2048

        /** logcat 用タグ。 */
        private const val TAG = "InkscapeApp"
    }

    // ========================================================================
    // UI コンポーネント
    // ========================================================================

    private lateinit var versionTextView: TextView
    private lateinit var imageView: ImageView
    private lateinit var infoTextView: TextView
    private lateinit var statusTextView: TextView
    private lateinit var openButton: Button
    private lateinit var exportButton: Button
    private lateinit var resetButton: Button

    /** 現在開いている SVG のローカルパス。 */
    private var currentPath: String? = null

    /** 現在のドキュメントの intrinsic サイズ。 */
    private var documentWidth = 0f
    private var documentHeight = 0f

    /** エクスポート時に選択されたサイズ（長辺 px）。 */
    private var pendingExportSize = 0

    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    // ========================================================================
    // ファイル選択ランチャー
    // ========================================================================

    /** SVG を開く。OpenDocument の結果は単一の Uri? で返る。 */
    private val openSvgLauncher =
        registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
            if (uri == null) {
                setStatus("ファイルが選択されませんでした")
            } else {
                loadSvg(uri)
            }
        }

    /** PNG の保存先を選ぶ。 */
    private val createPngLauncher =
        registerForActivityResult(ActivityResultContracts.CreateDocument("image/png")) { uri: Uri? ->
            if (uri == null) {
                setStatus("保存先が選択されませんでした")
            } else {
                exportPngTo(uri)
            }
        }

    // ========================================================================
    // ライフサイクル
    // ========================================================================

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        buildUI()

        val initResult = init()
        versionTextView.text = "Inkscape for Android  ${getVersion()}"
        setStatus(
            if (initResult == 0) {
                "ネイティブ初期化: 成功 (${getRendererVersion()})"
            } else {
                "ネイティブ初期化: 失敗 (init=$initResult)"
            }
        )

        openButton.setOnClickListener {
            openSvgLauncher.launch(arrayOf("image/svg+xml", "image/svg", "*/*"))
        }
        exportButton.setOnClickListener { showExportSizeDialog() }
        resetButton.setOnClickListener { fitToView() }

        // 他のアプリから SVG を開かれた場合
        intent?.data?.let { loadSvg(it) }
    }

    override fun onDestroy() {
        super.onDestroy()
        io.shutdownNow()
        shutdown()
    }

    // ========================================================================
    // UI 構築
    // ========================================================================

    private fun buildUI() {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
            val pad = dp(12f).toInt()
            setPadding(pad, pad, pad, pad)
        }

        versionTextView = TextView(this).apply {
            text = "Inkscape for Android"
            textSize = 16f
            gravity = Gravity.CENTER
            setTypeface(typeface, android.graphics.Typeface.BOLD)
        }
        root.addView(versionTextView, wrapParams(bottom = 6f))

        // キャンバス
        imageView = ImageView(this).apply {
            scaleType = ImageView.ScaleType.MATRIX
            setBackgroundColor(0xFF202020.toInt())
            contentDescription = "SVG プレビュー"
        }
        root.addView(
            imageView,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                0
            ).apply { weight = 1f }
        )

        // ドキュメント情報
        infoTextView = TextView(this).apply {
            text = "ドキュメント情報: なし"
            textSize = 11f
            maxLines = 4
            movementMethod = ScrollingMovementMethod()
        }
        root.addView(infoTextView, fillParams(top = 6f))

        // ステータス
        statusTextView = TextView(this).apply {
            text = "ステータス: 起動中..."
            textSize = 12f
            gravity = Gravity.CENTER
        }
        root.addView(statusTextView, fillParams(top = 4f, bottom = 4f))

        // ボタン行
        val buttons = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }

        openButton = Button(this).apply { text = "開く" }
        exportButton = Button(this).apply { text = "PNG保存" }
        resetButton = Button(this).apply { text = "全体表示" }

        for (button in listOf(openButton, exportButton, resetButton)) {
            buttons.addView(
                button,
                LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
            )
        }
        root.addView(buttons, fillParams(top = 4f))

        setContentView(root)

        setupGestures()
    }

    private fun wrapParams(
        top: Float = 0f,
        bottom: Float = 0f
    ): LinearLayout.LayoutParams {
        val params = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT
        )
        params.topMargin = dp(top).toInt()
        params.bottomMargin = dp(bottom).toInt()
        return params
    }

    private fun fillParams(
        top: Float = 0f,
        bottom: Float = 0f
    ): LinearLayout.LayoutParams {
        val params = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT
        )
        params.topMargin = dp(top).toInt()
        params.bottomMargin = dp(bottom).toInt()
        return params
    }

    private fun dp(value: Float): Float =
        TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value, resources.displayMetrics)

    // ========================================================================
    // ズーム / パン
    // ========================================================================

    private val scaleDetector by lazy {
        ScaleGestureDetector(this, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
            override fun onScale(detector: ScaleGestureDetector): Boolean {
                val matrix = Matrix(imageView.imageMatrix)
                matrix.postScale(
                    detector.scaleFactor,
                    detector.scaleFactor,
                    detector.focusX,
                    detector.focusY
                )
                imageView.imageMatrix = matrix
                return true
            }
        })
    }

    private val gestureDetector by lazy {
        GestureDetector(this, object : GestureDetector.SimpleOnGestureListener() {
            override fun onDown(e: MotionEvent): Boolean = true

            override fun onScroll(
                e1: MotionEvent?,
                e2: MotionEvent,
                distanceX: Float,
                distanceY: Float
            ): Boolean {
                if (scaleDetector.isInProgress) {
                    return true
                }
                val matrix = Matrix(imageView.imageMatrix)
                matrix.postTranslate(-distanceX, -distanceY)
                imageView.imageMatrix = matrix
                return true
            }

            override fun onDoubleTap(e: MotionEvent): Boolean {
                fitToView()
                return true
            }
        })
    }

    private fun setupGestures() {
        imageView.setOnTouchListener { _, event ->
            scaleDetector.onTouchEvent(event)
            gestureDetector.onTouchEvent(event)
            true
        }
    }

    /** 画像をビュー全体にフィットさせる。 */
    private fun fitToView() {
        val drawable = imageView.drawable ?: return
        val viewWidth = imageView.width.toFloat()
        val viewHeight = imageView.height.toFloat()
        if (viewWidth <= 0f || viewHeight <= 0f) {
            imageView.post { fitToView() }
            return
        }

        val imageWidth = drawable.intrinsicWidth.toFloat().coerceAtLeast(1f)
        val imageHeight = drawable.intrinsicHeight.toFloat().coerceAtLeast(1f)
        val scale = min(viewWidth / imageWidth, viewHeight / imageHeight)

        val matrix = Matrix()
        matrix.postScale(scale, scale)
        matrix.postTranslate(
            (viewWidth - imageWidth * scale) / 2f,
            (viewHeight - imageHeight * scale) / 2f
        )
        imageView.imageMatrix = matrix
    }

    // ========================================================================
    // SVG 読み込み
    // ========================================================================

    /**
     * content:// URI をアプリ内部のキャッシュへコピーしてからネイティブへ渡す。
     * SAF の URI はファイルパスとして直接扱えないため、コピーが必要。
     */
    private fun loadSvg(uri: Uri) {
        setStatus("読み込み中...")
        io.execute { performLoad(uri) }
    }

    /** バックグラウンドスレッドで実行される読み込み処理。 */
    private fun performLoad(uri: Uri) {
        try {
            val localFile = File(cacheDir, "current.svg")
            contentResolver.openInputStream(uri)?.use { input ->
                localFile.outputStream().use { output -> input.copyTo(output) }
            } ?: throw IllegalStateException("入力ストリームを開けません")

            val path = localFile.absolutePath
            if (!openFile(path)) {
                setStatus("SVG を開けません: ${getLastError()}")
                return
            }

            val info = getDocumentInfo(path)
            updateDocumentSize(info)

            val preview = renderSvgPng(path, PREVIEW_MAX_WIDTH, 0)
            if (preview == null) {
                setStatus("レンダリング失敗: ${getLastError()}")
                return
            }

            val bitmap = BitmapFactory.decodeByteArray(preview, 0, preview.size)
            if (bitmap == null) {
                setStatus("PNG のデコードに失敗しました")
                return
            }

            Log.i(
                TAG,
                "SVG 読み込み成功: ${preview.size} bytes, ${bitmap.width}x${bitmap.height}, info=$info"
            )

            main.post {
                currentPath = path
                imageView.setImageBitmap(bitmap)
                infoTextView.text = info
                imageView.post { fitToView() }
                statusTextView.text =
                    "読み込み完了: ${documentWidth.toInt()} x ${documentHeight.toInt()}"
            }
        } catch (t: Throwable) {
            setStatus("エラー: ${t.message}")
        }
    }

    /** getDocumentInfo の JSON から width / height を取り出す。 */
    private fun updateDocumentSize(infoJson: String) {
        documentWidth = extractJsonNumber(infoJson, "width") ?: 0f
        documentHeight = extractJsonNumber(infoJson, "height") ?: 0f
    }

    private fun extractJsonNumber(json: String, key: String): Float? {
        val regex = Regex("\"$key\"\\s*:\\s*([0-9]+(?:\\.[0-9]+)?)")
        return regex.find(json)?.groupValues?.get(1)?.toFloatOrNull()
    }

    // ========================================================================
    // PNG エクスポート
    // ========================================================================

    private fun showExportSizeDialog() {
        if (currentPath == null) {
            setStatus("先に SVG を開いてください")
            return
        }

        val labels = arrayOf("512 px", "1024 px", "2048 px", "4096 px", "元のサイズ")
        val values = intArrayOf(512, 1024, 2048, 4096, 0)

        AlertDialog.Builder(this)
            .setTitle("PNG の書き出しサイズ")
            .setItems(labels) { _, which ->
                pendingExportSize = values[which]
                createPngLauncher.launch("inkscape-export.png")
            }
            .show()
    }

    private fun exportPngTo(uri: Uri) {
        val path = currentPath ?: run {
            setStatus("先に SVG を開いてください")
            return
        }

        setStatus("PNG を書き出し中...")
        io.execute { performExport(path, uri) }
    }

    /** バックグラウンドスレッドで実行される PNG 書き出し処理。 */
    private fun performExport(path: String, uri: Uri) {
        try {
            val size = pendingExportSize
            val png = when {
                size <= 0 -> renderSvgPng(path, 0, 0)
                documentWidth >= documentHeight -> renderSvgPng(path, size, 0)
                else -> renderSvgPng(path, 0, size)
            }

            if (png == null) {
                setStatus("PNG 書き出し失敗: ${getLastError()}")
                return
            }

            contentResolver.openOutputStream(uri)?.use { output ->
                output.write(png)
                output.flush()
            } ?: throw IllegalStateException("出力ストリームを開けません")

            Log.i(TAG, "PNG 書き出し成功: ${png.size} bytes -> $uri")
            setStatus("PNG を保存しました (${png.size / 1024} KB)")
        } catch (t: Throwable) {
            setStatus("PNG 書き出しエラー: ${t.message}")
        }
    }

    // ========================================================================
    // ユーティリティ
    // ========================================================================

    private fun setStatus(message: String) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            statusTextView.text = message
        } else {
            main.post { statusTextView.text = message }
        }
    }
}
