// SPDX-License-Identifier: MPL-2.0
/*
 * Android 向け SVG レンダリングエンジン (C ABI)
 *
 * Inkscape のコア (GTK4/glibmm/lib2geom) は Android バックエンドを持たないため、
 * Android アプリでは resvg (純 Rust の高品質 SVG レンダラー) を用いて
 * SVG の解析・ラスタライズを行う。
 *
 * このクレートは staticlib としてビルドされ、C++ 側 (android_jni.cpp) から
 * 直接リンクされる。公開 API は C ABI のみで、Rust の型は外部へ漏らさない。
 *
 * 返却するバッファはすべて Rust のアロケータで確保されるため、
 * 呼び出し側は必ず inkscape_free / inkscape_free_string で解放すること。
 */

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Arc, Mutex, OnceLock};

use resvg::tiny_skia;
use resvg::usvg;
use resvg::usvg::fontdb;

/// フォントデータベースは初回のみ構築し、以降は共有する。
static FONTDB: OnceLock<Arc<fontdb::Database>> = OnceLock::new();

/// 直近のエラーメッセージ。スレッドをまたぐ可能性があるため Mutex で保護。
static LAST_ERROR: Mutex<Option<String>> = Mutex::new(None);

fn set_error(msg: impl Into<String>) {
    if let Ok(mut guard) = LAST_ERROR.lock() {
        *guard = Some(msg.into());
    }
}

fn clear_error() {
    if let Ok(mut guard) = LAST_ERROR.lock() {
        *guard = None;
    }
}

/// Android のシステムフォントを読み込んだフォント DB を返す。
///
/// fontdb の load_system_fonts() は Android のパスを知らないため、
/// /system/fonts 以下を自前で走査する。
fn font_db() -> Arc<fontdb::Database> {
    FONTDB
        .get_or_init(|| {
            let mut db = fontdb::Database::new();

            for dir in [
                "/system/fonts",
                "/system/font",
                "/product/fonts",
                "/vendor/fonts",
                "/system_ext/fonts",
            ] {
                let Ok(entries) = std::fs::read_dir(dir) else {
                    continue;
                };
                for entry in entries.flatten() {
                    let path = entry.path();
                    let Some(ext) = path.extension().and_then(|s| s.to_str()) else {
                        continue;
                    };
                    let ext = ext.to_ascii_lowercase();
                    if matches!(ext.as_str(), "ttf" | "ttc" | "otf" | "otc") {
                        let _ = db.load_font_file(&path);
                    }
                }
            }

            // フォールバック: ホスト環境 (テスト時) のシステムフォント
            db.load_system_fonts();

            // 総称フォントファミリー (sans-serif / serif / monospace) を実フォントに
            // 割り当てる。未設定だと usvg は該当テキストを丸ごと破棄してしまう。
            configure_generic_families(&mut db);

            Arc::new(db)
        })
        .clone()
}

/// fontdb の総称ファミリー設定を行う。
///
/// Android には Roboto / Noto Sans CJK などが入っている。存在する中で
/// 最も一般的なものを総称ファミリーへ割り当てる。
fn configure_generic_families(db: &mut fontdb::Database) {
    let available: Vec<String> = db
        .faces()
        .filter_map(|face| face.families.first().map(|(name, _)| name.clone()))
        .collect();

    let pick = |candidates: &[&str]| -> Option<String> {
        candidates
            .iter()
            .find(|cand| available.iter().any(|name| name.eq_ignore_ascii_case(cand)))
            .map(|s| (*s).to_string())
    };

    // 見つからなければ最初のフォントを総称ファミリーとして使う
    let any = available.first().cloned();

    if let Some(name) = pick(&[
        "Roboto",
        "Noto Sans",
        "Droid Sans",
        "DejaVu Sans",
        "Liberation Sans",
        "Arial",
        "Noto Sans CJK JP",
    ])
    .or_else(|| any.clone())
    {
        db.set_sans_serif_family(name);
    }

    if let Some(name) = pick(&[
        "Noto Serif",
        "DejaVu Serif",
        "Liberation Serif",
        "Times New Roman",
        "Droid Serif",
    ])
    .or_else(|| any.clone())
    {
        db.set_serif_family(name);
    }

    if let Some(name) = pick(&[
        "Roboto Mono",
        "Noto Sans Mono",
        "Droid Sans Mono",
        "DejaVu Sans Mono",
        "Liberation Mono",
        "Courier New",
    ])
    .or_else(|| any)
    {
        db.set_monospace_family(name);
    }
}

fn usvg_options() -> usvg::Options<'static> {
    let mut opt = usvg::Options::default();
    opt.fontdb = font_db();
    opt.dpi = 96.0;
    // Android ではカレントディレクトリ基準の相対参照は解決できないため無効化。
    opt.resources_dir = None;
    opt
}

/// 生ポインタからスライスを作る。NULL / 長さ 0 はエラー。
unsafe fn input_slice<'a>(data: *const u8, len: usize) -> Result<&'a [u8], String> {
    if data.is_null() {
        return Err("SVG データが NULL です".to_string());
    }
    if len == 0 {
        return Err("SVG データが空です".to_string());
    }
    Ok(std::slice::from_raw_parts(data, len))
}

/// Vec<u8> を呼び出し側が解放できる生ポインタへ変換する。
fn into_raw_bytes(mut bytes: Vec<u8>) -> (*mut u8, usize) {
    bytes.shrink_to_fit();
    let boxed = bytes.into_boxed_slice();
    let len = boxed.len();
    let ptr = Box::into_raw(boxed) as *mut u8;
    (ptr, len)
}

/// `inkscape_render_png` が確保したバッファを解放する。
///
/// # Safety
/// ptr は inkscape_render_png が返したポインタ、len はその out_len であること。
#[no_mangle]
pub unsafe extern "C" fn inkscape_free(ptr: *mut u8, len: usize) {
    if ptr.is_null() || len == 0 {
        return;
    }
    let slice = std::slice::from_raw_parts_mut(ptr, len);
    drop(Box::from_raw(slice as *mut [u8]));
}

/// `inkscape_svg_info` / `inkscape_last_error` が返した文字列を解放する。
///
/// # Safety
/// ptr は上記関数が返したポインタであること。
#[no_mangle]
pub unsafe extern "C" fn inkscape_free_string(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }
    drop(CString::from_raw(ptr));
}

/// レンダラーのバージョン文字列 (静的領域)。解放不要。
#[no_mangle]
pub extern "C" fn inkscape_renderer_version() -> *const c_char {
    // NUL 終端を含む静的バイト列
    concat!("resvg ", env!("CARGO_PKG_VERSION"), "\0").as_ptr() as *const c_char
}

/// 直近のエラー内容を返す。エラーがなければ空文字列。解放には inkscape_free_string を使う。
#[no_mangle]
pub extern "C" fn inkscape_last_error() -> *mut c_char {
    let msg = LAST_ERROR
        .lock()
        .ok()
        .and_then(|guard| guard.clone())
        .unwrap_or_default();
    CString::new(msg)
        .unwrap_or_else(|_| CString::new("unknown error").unwrap())
        .into_raw()
}

/// SVG を PNG にラスタライズする。
///
/// * `data` / `len` : SVG (または SVGZ) のバイト列
/// * `width` / `height` : 出力サイズ (px)。0 を指定すると SVG の intrinsic size を使う。
///   アスペクト比は維持され、余白は透明になる。
/// * `out_len` : 成功時に PNG バイト長が書き込まれる
///
/// 戻り値: PNG バイト列へのポインタ。失敗時は NULL。
/// 解放には `inkscape_free(ptr, out_len)` を使う。
///
/// # Safety
/// data は len バイト以上有効、out_len は書き込み可能であること。
#[no_mangle]
pub unsafe extern "C" fn inkscape_render_png(
    data: *const u8,
    len: usize,
    width: u32,
    height: u32,
    out_len: *mut usize,
) -> *mut u8 {
    if out_len.is_null() {
        set_error("out_len が NULL です");
        return std::ptr::null_mut();
    }
    *out_len = 0;
    clear_error();

    let result = catch_unwind(AssertUnwindSafe(|| -> Result<Vec<u8>, String> {
        let svg = input_slice(data, len)?;

        let tree = usvg::Tree::from_data(svg, &usvg_options())
            .map_err(|e| format!("SVG の解析に失敗しました: {e}"))?;

        let size = tree.size();
        let svg_w = size.width();
        let svg_h = size.height();
        if !(svg_w.is_finite() && svg_h.is_finite()) || svg_w <= 0.0 || svg_h <= 0.0 {
            return Err("SVG のサイズが不正です".to_string());
        }

        // 出力サイズの決定:
        //   (0, 0)     -> SVG の intrinsic size
        //   (w, 0)     -> 幅を w に固定し、高さはアスペクト比から算出
        //   (0, h)     -> 高さを h に固定し、幅はアスペクト比から算出
        //   (w, h)     -> そのまま（アスペクト比は維持してフィット）
        let (out_w, out_h) = match (width, height) {
            (0, 0) => (
                (svg_w.ceil() as u32).clamp(1, 16384),
                (svg_h.ceil() as u32).clamp(1, 16384),
            ),
            (w, 0) => {
                let w = w.clamp(1, 16384);
                let h = ((svg_h / svg_w) * w as f32).round() as u32;
                (w, h.clamp(1, 16384))
            }
            (0, h) => {
                let h = h.clamp(1, 16384);
                let w = ((svg_w / svg_h) * h as f32).round() as u32;
                (w.clamp(1, 16384), h)
            }
            (w, h) => (w.clamp(1, 16384), h.clamp(1, 16384)),
        };

        // アスペクト比を維持してフィットさせる
        let scale = (out_w as f32 / svg_w).min(out_h as f32 / svg_h);

        let mut pixmap = tiny_skia::Pixmap::new(out_w, out_h)
            .ok_or_else(|| format!("{out_w}x{out_h} の描画バッファを確保できません"))?;

        resvg::render(
            &tree,
            tiny_skia::Transform::from_scale(scale, scale),
            &mut pixmap.as_mut(),
        );

        pixmap
            .encode_png()
            .map_err(|e| format!("PNG エンコードに失敗しました: {e}"))
    }));

    match result {
        Ok(Ok(png)) => {
            let (ptr, n) = into_raw_bytes(png);
            *out_len = n;
            ptr
        }
        Ok(Err(msg)) => {
            set_error(msg);
            std::ptr::null_mut()
        }
        Err(_) => {
            set_error("レンダリング中に内部エラーが発生しました");
            std::ptr::null_mut()
        }
    }
}

/// SVG のドキュメント情報を JSON 文字列で返す。
///
/// 例: {"width":200.0,"height":200.0,"viewBox":"0 0 200 200","elements":12}
/// 失敗時は NULL。解放には `inkscape_free_string` を使う。
///
/// # Safety
/// data は len バイト以上有効であること。
#[no_mangle]
pub unsafe extern "C" fn inkscape_svg_info(data: *const u8, len: usize) -> *mut c_char {
    clear_error();

    let result = catch_unwind(AssertUnwindSafe(|| -> Result<String, String> {
        let svg = input_slice(data, len)?;
        let tree = usvg::Tree::from_data(svg, &usvg_options())
            .map_err(|e| format!("SVG の解析に失敗しました: {e}"))?;

        let size = tree.size();
        let elements = count_group(tree.root());

        Ok(format!(
            "{{\"width\":{:.3},\"height\":{:.3},\"elements\":{},\"hasText\":{},\"hasDefs\":{}}}",
            size.width(),
            size.height(),
            elements,
            tree.has_text_nodes(),
            tree.has_defs_nodes()
        ))
    }));

    match result {
        Ok(Ok(json)) => CString::new(json)
            .map(|c| c.into_raw())
            .unwrap_or(std::ptr::null_mut()),
        Ok(Err(msg)) => {
            set_error(msg);
            std::ptr::null_mut()
        }
        Err(_) => {
            set_error("解析中に内部エラーが発生しました");
            std::ptr::null_mut()
        }
    }
}

/// ツリー内の描画ノード数を数える (ドキュメント情報表示用)。
fn count_group(group: &usvg::Group) -> usize {
    group.children().iter().map(count_nodes).sum()
}

fn count_nodes(node: &usvg::Node) -> usize {
    match node {
        usvg::Node::Group(group) => 1 + count_group(group),
        _ => 1,
    }
}

/// C 文字列を Rust の &str に変換するユーティリティ (将来の拡張用)。
///
/// # Safety
/// ptr は NUL 終端された有効な C 文字列であること。
#[no_mangle]
pub unsafe extern "C" fn inkscape_debug_cstr_len(ptr: *const c_char) -> usize {
    if ptr.is_null() {
        return 0;
    }
    CStr::from_ptr(ptr).to_bytes().len()
}
