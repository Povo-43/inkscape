// 開発用の動作確認ツール: SVG を PNG にレンダリングする。
// 使い方: cargo run --example render -- <input.svg> <output.png> [width] [height]
use std::ffi::CStr;
use std::os::raw::c_char;

use inkscape_svg_renderer::*;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: render <input.svg> <output.png> [width] [height]");
        std::process::exit(2);
    }
    let input = std::fs::read(&args[1]).expect("input read failed");
    let width: u32 = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(0);
    let height: u32 = args.get(4).and_then(|s| s.parse().ok()).unwrap_or(0);

    unsafe {
        let info_ptr = inkscape_svg_info(input.as_ptr(), input.len());
        if !info_ptr.is_null() {
            println!("info: {}", CStr::from_ptr(info_ptr).to_string_lossy());
            inkscape_free_string(info_ptr);
        }

        let mut out_len: usize = 0;
        let ptr = inkscape_render_png(input.as_ptr(), input.len(), width, height, &mut out_len);
        if ptr.is_null() {
            let err = inkscape_last_error();
            let msg = if err.is_null() {
                "unknown".to_string()
            } else {
                let s = CStr::from_ptr(err).to_string_lossy().into_owned();
                inkscape_free_string(err);
                s
            };
            eprintln!("render failed: {msg}");
            std::process::exit(1);
        }
        let bytes = std::slice::from_raw_parts(ptr, out_len);
        std::fs::write(&args[2], bytes).expect("write failed");
        println!("wrote {} ({} bytes)", args[2], out_len);
        inkscape_free(ptr, out_len);

        let v: *const c_char = inkscape_renderer_version();
        println!("engine: {}", CStr::from_ptr(v).to_string_lossy());
    }
}
