//! Captura de pantalla de un solo disparo, cronometrada etapa por etapa.
//!
//! Es la primera linea del presupuesto de latencia de Ojo, y se mide aislada:
//! sin modelos, sin red, sin nada que contamine el numero.
//!
//! Por que BitBlt y no Windows.Graphics.Capture, que es mas moderno: WGC abre
//! una sesion de captura y eso cuesta decenas de milisegundos en frio, que aqui
//! se pagarian enteros en cada pregunta. BitBlt lee el escritorio ya compuesto
//! sin montar nada. La contrapartida real es que no ve contenido en superposicion
//! por hardware (algunos juegos a pantalla completa) -- si eso llega a importar,
//! se anade WGC como segundo camino y se elige por ventana.
//!
//! Por que NO se reusa shadowplay-wgc, que ya captura a 60 fps: codifica a HEVC
//! por hardware directo a un anillo en RAM y no guarda fotogramas crudos, asi que
//! habria que decodificar. Y anadir trabajo a su callback de fotograma ya se midio
//! una vez: hundio el video de 55 a 21 fps.
//!
//!   ojo-captura.exe                  una captura, tiempos en JSON por stdout
//!   ojo-captura.exe --salida x.jpg   ademas escribe el JPEG
//!   ojo-captura.exe --repetir 20     20 pasadas, con mediana y p95
//!   ojo-captura.exe --demo           autocomprobacion

use std::time::Instant;

use windows::Win32::Graphics::Gdi::{
    BitBlt, CreateCompatibleDC, CreateDIBSection, DeleteDC, DeleteObject, GetDC, ReleaseDC,
    SelectObject, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, CAPTUREBLT, DIB_RGB_COLORS, HBITMAP,
    SRCCOPY,
};
use windows::Win32::UI::HiDpi::{SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2};
use windows::Win32::Graphics::Gdi::{
    GetMonitorInfoW, MonitorFromWindow, MONITORINFO, MONITOR_DEFAULTTOPRIMARY,
};
use windows::Win32::UI::WindowsAndMessaging::{
    GetForegroundWindow, GetSystemMetrics, SM_CXSCREEN, SM_CXVIRTUALSCREEN, SM_CYSCREEN,
    SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN,
};

/// Lado mayor al que se reduce antes de mandar al modelo. 1280 es lo que usa
/// clicky-windows y el mismo numero que recomiendan los modelos de vision: mas
/// resolucion multiplica los tokens sin mejorar el acierto.
const LADO_MAX: u32 = 1280;
const CALIDAD_JPEG: u8 = 80;

#[derive(Default, serde::Serialize)]
struct Tiempos {
    ancho: u32,
    alto: u32,
    ancho_reducido: u32,
    alto_reducido: u32,
    bytes_jpeg: usize,
    blit_ms: f64,
    reducir_ms: f64,
    jpeg_ms: f64,
    total_ms: f64,
}

/// Rectangulo a capturar: por defecto el monitor donde esta la ventana activa.
///
/// Capturar el escritorio virtual entero fue la primera version y la medicion la
/// descarto: aqui son 4480x1440, y al reducir el lado mayor a 1280 quedan 411 px
/// de alto. Ningun modelo de vision lee texto de interfaz con esa altura. Un
/// monitor suelto (1920x1080 o 2560x1440) baja a 1280x720 o 1280x720, que si se
/// lee, y de paso el BitBlt copia entre 2,4 y 4,5 veces menos pixeles.
fn rectangulo(todo: bool) -> (i32, i32, i32, i32) {
    unsafe {
        if todo {
            return (
                GetSystemMetrics(SM_XVIRTUALSCREEN),
                GetSystemMetrics(SM_YVIRTUALSCREEN),
                GetSystemMetrics(SM_CXVIRTUALSCREEN),
                GetSystemMetrics(SM_CYVIRTUALSCREEN),
            );
        }
        // El monitor de la ventana en primer plano, que es donde el usuario esta
        // mirando. Si no hay ventana activa, el monitor primario.
        let hwnd = GetForegroundWindow();
        let mon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTOPRIMARY);
        let mut info = MONITORINFO {
            cbSize: std::mem::size_of::<MONITORINFO>() as u32,
            ..Default::default()
        };
        if GetMonitorInfoW(mon, &mut info).as_bool() {
            let r = info.rcMonitor;
            return (r.left, r.top, r.right - r.left, r.bottom - r.top);
        }
        (0, 0, GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN))
    }
}

/// La region pedida como BGRA, de una sola pasada.
///
/// Devuelve el tiempo del BitBlt aparte: el resto de la funcion (crear el DIB,
/// copiar el buffer) se paga una vez y no en cada captura si algun dia se
/// reutiliza el DIB, asi que interesa tenerlos separados.
fn capturar(todo: bool) -> Result<(Vec<u8>, u32, u32, f64), String> {
    unsafe {
        let (x, y, w, h) = rectangulo(todo);
        if w <= 0 || h <= 0 {
            return Err(format!("region invalida: {w}x{h}"));
        }

        let pantalla = GetDC(None);
        if pantalla.is_invalid() {
            return Err("GetDC devolvio nulo".into());
        }
        let memoria = CreateCompatibleDC(pantalla);

        let info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: w,
                biHeight: -h, // negativo = de arriba abajo, como se lee despues
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };
        let mut bits: *mut core::ffi::c_void = std::ptr::null_mut();
        let dib: HBITMAP = CreateDIBSection(memoria, &info, DIB_RGB_COLORS, &mut bits, None, 0)
            .map_err(|e| format!("CreateDIBSection: {e}"))?;
        let previo = SelectObject(memoria, dib);

        // CAPTUREBLT incluye las ventanas en capa (layered). Sin el, los overlays
        // del rice no saldrian -- que para el overlay propio es justo lo que
        // queremos (lo excluimos aparte con WDA_EXCLUDEFROMCAPTURE), pero para
        // los demas no.
        let t = Instant::now();
        let ok = BitBlt(memoria, 0, 0, w, h, pantalla, x, y, SRCCOPY | CAPTUREBLT).is_ok();
        let blit_ms = t.elapsed().as_secs_f64() * 1000.0;

        let mut salida = Vec::new();
        if ok && !bits.is_null() {
            let n = (w as usize) * (h as usize) * 4;
            salida = std::slice::from_raw_parts(bits as *const u8, n).to_vec();
        }

        SelectObject(memoria, previo);
        let _ = DeleteObject(dib);
        let _ = DeleteDC(memoria);
        ReleaseDC(None, pantalla);

        if !ok {
            return Err("BitBlt fallo".into());
        }
        Ok((salida, w as u32, h as u32, blit_ms))
    }
}

/// Reduce por muestreo de vecino mas cercano y pasa BGRA a RGB de una vez.
///
/// Vecino mas cercano y no un filtro bueno a proposito: el destinatario es un
/// modelo de vision, no un ojo humano, y un remuestreo con pesos costaria
/// milisegundos del presupuesto para mejorar algo que nadie va a mirar.
fn reducir(src: &[u8], w: u32, h: u32, lado_max: u32) -> (Vec<u8>, u32, u32) {
    let mayor = w.max(h);
    let (nw, nh) = if mayor <= lado_max {
        (w, h)
    } else {
        let k = lado_max as f64 / mayor as f64;
        (((w as f64 * k) as u32).max(1), ((h as f64 * k) as u32).max(1))
    };

    let mut out = vec![0u8; (nw as usize) * (nh as usize) * 3];
    for fy in 0..nh {
        let sy = (fy as u64 * h as u64 / nh as u64) as usize;
        let fila = sy * w as usize * 4;
        for fx in 0..nw {
            let sx = (fx as u64 * w as u64 / nw as u64) as usize;
            let p = fila + sx * 4;
            let q = ((fy as usize) * nw as usize + fx as usize) * 3;
            out[q] = src[p + 2]; // BGRA -> RGB
            out[q + 1] = src[p + 1];
            out[q + 2] = src[p];
        }
    }
    (out, nw, nh)
}

/// La captura SIN reducir, como BMP de 32 bits de arriba abajo: para el OCR.
///
/// La imagen del modelo va a 1280 de lado mayor, y en un monitor de 1440p eso
/// es la mitad: una letra de 11 px queda en 5 y se lee mal (219 W por 218).
/// El OCR de Windows lee el texto exacto de la imagen entera. BMP porque no
/// hay que comprimir nada: escribirlo es copiar el bufer.
fn escribir_bmp(p: &str, bgra: &[u8], w: u32, h: u32) -> Result<(), String> {
    let datos = bgra.len() as u32;
    let mut f = Vec::with_capacity(54 + bgra.len());
    f.extend_from_slice(b"BM");
    f.extend_from_slice(&(54 + datos).to_le_bytes());
    f.extend_from_slice(&0u32.to_le_bytes());
    f.extend_from_slice(&54u32.to_le_bytes());
    f.extend_from_slice(&40u32.to_le_bytes()); // BITMAPINFOHEADER
    f.extend_from_slice(&(w as i32).to_le_bytes());
    f.extend_from_slice(&(-(h as i32)).to_le_bytes()); // negativo = de arriba abajo
    f.extend_from_slice(&1u16.to_le_bytes());
    f.extend_from_slice(&32u16.to_le_bytes());
    f.extend_from_slice(&0u32.to_le_bytes()); // BI_RGB
    f.extend_from_slice(&datos.to_le_bytes());
    f.extend_from_slice(&[0u8; 16]);
    f.extend_from_slice(bgra);
    std::fs::write(p, &f).map_err(|e| format!("no se pudo escribir {p}: {e}"))
}

fn una_pasada(salida: Option<&str>, todo: bool, nativa: Option<&str>) -> Result<Tiempos, String> {
    let t0 = Instant::now();
    let (bgra, w, h, blit_ms) = capturar(todo)?;
    if let Some(p) = nativa {
        escribir_bmp(p, &bgra, w, h)?;
    }

    let t = Instant::now();
    let (rgb, nw, nh) = reducir(&bgra, w, h, LADO_MAX);
    let reducir_ms = t.elapsed().as_secs_f64() * 1000.0;

    let t = Instant::now();
    let mut jpeg = Vec::new();
    jpeg_encoder::Encoder::new(&mut jpeg, CALIDAD_JPEG)
        .encode(&rgb, nw as u16, nh as u16, jpeg_encoder::ColorType::Rgb)
        .map_err(|e| format!("jpeg: {e}"))?;
    let jpeg_ms = t.elapsed().as_secs_f64() * 1000.0;

    if let Some(p) = salida {
        std::fs::write(p, &jpeg).map_err(|e| format!("no se pudo escribir {p}: {e}"))?;
    }

    Ok(Tiempos {
        ancho: w,
        alto: h,
        ancho_reducido: nw,
        alto_reducido: nh,
        bytes_jpeg: jpeg.len(),
        blit_ms,
        reducir_ms,
        jpeg_ms,
        total_ms: t0.elapsed().as_secs_f64() * 1000.0,
    })
}

fn percentil(v: &mut [f64], p: f64) -> f64 {
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    if v.is_empty() {
        return 0.0;
    }
    let i = ((v.len() - 1) as f64 * p).round() as usize;
    v[i]
}

fn demo() -> Result<(), String> {
    // Lo que de verdad importa comprobar: que la captura devuelve la pantalla
    // entera, que la reduccion respeta la proporcion, y que el JPEG no sale
    // vacio ni absurdamente grande.
    let t = una_pasada(None, false, None)?;
    assert!(t.ancho >= 640 && t.alto >= 480, "pantalla sospechosa: {}x{}", t.ancho, t.alto);
    assert!(
        t.ancho_reducido.max(t.alto_reducido) == LADO_MAX || t.ancho <= LADO_MAX,
        "el lado mayor deberia quedar en {LADO_MAX}, quedo en {}",
        t.ancho_reducido.max(t.alto_reducido)
    );
    let prop_orig = t.ancho as f64 / t.alto as f64;
    let prop_red = t.ancho_reducido as f64 / t.alto_reducido as f64;
    assert!(
        (prop_orig - prop_red).abs() < 0.01,
        "la proporcion cambio: {prop_orig:.3} -> {prop_red:.3}"
    );
    assert!(t.bytes_jpeg > 2_000, "JPEG sospechosamente pequeno: {} bytes", t.bytes_jpeg);
    assert!(t.bytes_jpeg < 2_000_000, "JPEG enorme: {} bytes", t.bytes_jpeg);

    // Una pantalla completamente negra casi siempre significa que el BitBlt
    // devolvio un buffer sin tocar, no que el escritorio este negro de verdad.
    let (bgra, w, h, _) = capturar(false)?;
    let paso = (bgra.len() / 4 / 5_000).max(1) * 4;
    let vivos = bgra.iter().step_by(paso).filter(|&&b| b > 8).count();
    assert!(vivos > 0, "la captura de {w}x{h} salio entera a negro");

    println!(
        "ok  {}x{} -> {}x{}  {} KB  blit {:.1} ms  reducir {:.1} ms  jpeg {:.1} ms  total {:.1} ms",
        t.ancho, t.alto, t.ancho_reducido, t.alto_reducido,
        t.bytes_jpeg / 1024, t.blit_ms, t.reducir_ms, t.jpeg_ms, t.total_ms
    );
    Ok(())
}

fn main() {
    // Sin esto Windows miente sobre el tamano de la pantalla en equipos con
    // escalado, y la captura sale recortada o estirada.
    unsafe {
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    }

    let args: Vec<String> = std::env::args().skip(1).collect();
    let arg = |k: &str| -> Option<String> {
        args.iter().position(|a| a == k).and_then(|i| args.get(i + 1)).cloned()
    };

    if args.iter().any(|a| a == "--demo") {
        if let Err(e) = demo() {
            eprintln!("FALLA: {e}");
            std::process::exit(1);
        }
        return;
    }

    let todo = args.iter().any(|a| a == "--todo");
    let salida = arg("--salida");
    let nativa = arg("--nativa");
    let repetir: usize = arg("--repetir").and_then(|v| v.parse().ok()).unwrap_or(1);

    let mut todos = Vec::new();
    for i in 0..repetir {
        // Solo la ultima pasada escribe el archivo: las demas son para el reloj.
        let ultima = i + 1 == repetir;
        let destino = if ultima { salida.as_deref() } else { None };
        match una_pasada(destino, todo, if ultima { nativa.as_deref() } else { None }) {
            Ok(t) => todos.push(t),
            Err(e) => {
                eprintln!("FALLA en la pasada {i}: {e}");
                std::process::exit(1);
            }
        }
    }

    if repetir == 1 {
        println!("{}", serde_json::to_string(&todos[0]).unwrap());
        return;
    }

    let mut tot: Vec<f64> = todos.iter().map(|t| t.total_ms).collect();
    let mut bl: Vec<f64> = todos.iter().map(|t| t.blit_ms).collect();
    let mut re: Vec<f64> = todos.iter().map(|t| t.reducir_ms).collect();
    let mut jp: Vec<f64> = todos.iter().map(|t| t.jpeg_ms).collect();
    let u = &todos[todos.len() - 1];
    println!(
        "{}",
        serde_json::json!({
            "pasadas": repetir,
            "ancho": u.ancho, "alto": u.alto,
            "reducido": format!("{}x{}", u.ancho_reducido, u.alto_reducido),
            "kb_jpeg": u.bytes_jpeg / 1024,
            "blit_mediana_ms": percentil(&mut bl, 0.5),
            "reducir_mediana_ms": percentil(&mut re, 0.5),
            "jpeg_mediana_ms": percentil(&mut jp, 0.5),
            "total_mediana_ms": percentil(&mut tot.clone(), 0.5),
            "total_p95_ms": percentil(&mut tot, 0.95),
        })
    );
}

