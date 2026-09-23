//! El overlay de Ojo: cursor del agente, anillo, trazos, bocadillo, subtitulos
//! y pildora de estado, encima de todo lo demas.
//!
//! La ventana es la misma receta que `ws-slide` del rice, que ya esta depurada:
//! capa transparente, siempre encima, sin foco y fuera de la barra de tareas.
//!
//!   ojo-overlay --demo          secuencia guionizada, sin ningun modelo detras
//!   ojo-overlay --prueba out\   PNG de cada escena, sin abrir ventana
//!   ojo-overlay --oculto        excluido de las grabaciones (ver abajo)
//!
//! Sobre `--oculto`: `WDA_EXCLUDEFROMCAPTURE` esconde la ventana de TODAS las
//! tuberias de captura, incluida Windows.Graphics.Capture -- que es la que usa
//! shadowplay-wgc. Hace falta para que el modelo no vea sus propias flechas en
//! la captura siguiente, pero con el puesto shadowplay tampoco graba el overlay
//! y no habria forma de revisar como se comporta. Por eso NO es el modo por
//! defecto: se activa solo durante el instante del BitBlt.

mod escena;
mod pintura;

use std::time::Instant;

use escena::{Escena, Estado, Lienzo, Trazo};
use tiny_skia::Pixmap;
use windows::core::PCWSTR;
use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, POINT, WPARAM};
use windows::Win32::Graphics::Gdi::{
    CreateCompatibleDC, CreateDIBSection, DeleteDC, DeleteObject, GetDC, GetMonitorInfoW,
    MonitorFromPoint, ReleaseDC, SelectObject, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, BLENDFUNCTION,
    DIB_RGB_COLORS, HBITMAP, MONITORINFO, MONITOR_DEFAULTTOPRIMARY, AC_SRC_ALPHA, AC_SRC_OVER,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::HiDpi::{
    SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DispatchMessageW, FindWindowW, GetCursorPos, PeekMessageW, RegisterClassW,
    SetWindowDisplayAffinity, SetWindowPos, ShowWindow, TranslateMessage, UpdateLayeredWindow,
    HWND_TOPMOST, MSG, PM_REMOVE, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE, SW_SHOWNOACTIVATE,
    ULW_ALPHA, WDA_EXCLUDEFROMCAPTURE, WDA_NONE, WNDCLASSW, WS_EX_LAYERED,
    WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_EX_TRANSPARENT, WS_POPUP,
};

/// Hay una partida de League abierta: existe la ventana del juego
/// (`RiotWindowClass`, la del proceso "League of Legends", no la del cliente).
///
/// Con ella, `WDA_EXCLUDEFROMCAPTURE` NUNCA: una ventana escondida de las
/// capturas es justo la firma que persigue un anti-cheat (Vanguard). Se
/// comprueba aqui y no solo en ojo.ps1 para que ninguna llamada se la salte.
fn hay_partida_de_lol() -> bool {
    let clase = wide("RiotWindowClass");
    unsafe { FindWindowW(PCWSTR(clase.as_ptr()), PCWSTR::null()).map(|h| !h.is_invalid()).unwrap_or(false) }
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

unsafe extern "system" fn wndproc(h: HWND, m: u32, w: WPARAM, l: LPARAM) -> LRESULT {
    DefWindowProcW(h, m, w, l)
}

struct Ventana {
    hwnd: HWND,
    x: i32,
    y: i32,
    ancho: i32,
    alto: i32,
    /// Ultima vez que se reafirmo la banda de z. Ver `reafirmar_encima`.
    ultimo_encima: std::cell::Cell<Instant>,
}

/// Monitor donde esta el raton ahora. El overlay vive en una sola pantalla:
/// cubrir las dos obligaria a un buffer de 4480x1440 y a pintar el doble de
/// pixeles en cada cuadro para nada.
fn monitor_del_raton() -> (i32, i32, i32, i32) {
    unsafe {
        let mut p = POINT::default();
        let _ = GetCursorPos(&mut p);
        let mon = MonitorFromPoint(p, MONITOR_DEFAULTTOPRIMARY);
        let mut info = MONITORINFO { cbSize: std::mem::size_of::<MONITORINFO>() as u32, ..Default::default() };
        if GetMonitorInfoW(mon, &mut info).as_bool() {
            let r = info.rcMonitor;
            return (r.left, r.top, r.right - r.left, r.bottom - r.top);
        }
        (0, 0, 1920, 1080)
    }
}

impl Ventana {
    fn crear(oculto: bool) -> Result<Self, String> {
        unsafe {
            let (x, y, ancho, alto) = monitor_del_raton();
            let hinst = GetModuleHandleW(None).map_err(|e| e.to_string())?;
            let cls = wide("ojo_overlay");
            let wc = WNDCLASSW {
                lpfnWndProc: Some(wndproc),
                hInstance: hinst.into(),
                lpszClassName: PCWSTR(cls.as_ptr()),
                ..Default::default()
            };
            RegisterClassW(&wc);
            let hwnd = CreateWindowExW(
                WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW,
                PCWSTR(cls.as_ptr()),
                PCWSTR::null(),
                WS_POPUP,
                x, y, ancho, alto,
                None, None, hinst, None,
            )
            .map_err(|e| e.to_string())?;
            let _ = SetWindowDisplayAffinity(hwnd, if oculto { WDA_EXCLUDEFROMCAPTURE } else { WDA_NONE });
            let _ = ShowWindow(hwnd, SW_SHOWNOACTIVATE);
            Ok(Self { hwnd, x, y, ancho, alto, ultimo_encima: std::cell::Cell::new(Instant::now()) })
        }
    }

    /// Vuelve a pedir la banda de "siempre encima".
    ///
    /// EL BIT NO BASTA. Es la misma leccion que ya se pago en glaze-bar (ver
    /// `crates/glaze-bar/src/main.rs`, "Re-assert TOPMOST too"): `WS_EX_TOPMOST`
    /// sobrevive, pero la POSICION en el orden z no. Alli se midio una barra con
    /// el bit puesto sentada DEBAJO de una ventana normal de Firefox despues de
    /// reiniciar explorer.
    ///
    /// Aqui el caso que importa es otro y es peor: un juego que acaba de tomar
    /// el primer plano. La ventana se creo encima una sola vez, al arrancar, y
    /// nadie lo volvia a pedir nunca. Un `SetWindowPos` idempotente lo arregla.
    ///
    /// Dos veces por segundo y no en cada cuadro: es barato, pero a 60 Hz son 60
    /// `WM_WINDOWPOSCHANGING` por segundo para nada.
    fn reafirmar_encima(&self) {
        if self.ultimo_encima.get().elapsed().as_millis() < 500 {
            return;
        }
        self.ultimo_encima.set(Instant::now());
        unsafe {
            let _ = SetWindowPos(
                self.hwnd,
                HWND_TOPMOST,
                0, 0, 0, 0,
                SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
            );
        }
    }

    /// Sube el pixmap a la pantalla. Devuelve los ms que costo.
    ///
    /// `alfa` es la opacidad de TODA la capa (0-255), para los fundidos de
    /// entrada y salida: la hace el compositor con SourceConstantAlpha, sin
    /// tocar ni un pixel del pixmap.
    fn presentar(&self, px: &Pixmap, alfa: u8) -> f64 {
        // Aqui y no en cada bucle: los tres modos (--demo, --servir, --escena)
        // pasan por presentar, asi que uno solo lo cubre todo.
        self.reafirmar_encima();
        let t = Instant::now();
        unsafe {
            let pantalla = GetDC(None);
            let memoria = CreateCompatibleDC(pantalla);
            let info = BITMAPINFO {
                bmiHeader: BITMAPINFOHEADER {
                    biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                    biWidth: self.ancho,
                    biHeight: -self.alto,
                    biPlanes: 1,
                    biBitCount: 32,
                    biCompression: BI_RGB.0,
                    ..Default::default()
                },
                ..Default::default()
            };
            let mut bits: *mut core::ffi::c_void = std::ptr::null_mut();
            if let Ok(dib) = CreateDIBSection(memoria, &info, DIB_RGB_COLORS, &mut bits, None, 0) {
                let previo = SelectObject(memoria, dib);
                if !bits.is_null() {
                    // tiny-skia da RGBA premultiplicado; UpdateLayeredWindow
                    // quiere BGRA premultiplicado. Solo hay que cruzar R y B.
                    let src = px.data();
                    let dst = std::slice::from_raw_parts_mut(bits as *mut u8, src.len());
                    for i in (0..src.len()).step_by(4) {
                        dst[i] = src[i + 2];
                        dst[i + 1] = src[i + 1];
                        dst[i + 2] = src[i];
                        dst[i + 3] = src[i + 3];
                    }
                }
                let mezcla = BLENDFUNCTION {
                    BlendOp: AC_SRC_OVER as u8,
                    BlendFlags: 0,
                    SourceConstantAlpha: alfa,
                    AlphaFormat: AC_SRC_ALPHA as u8,
                };
                let pos = POINT { x: self.x, y: self.y };
                let tam = windows::Win32::Foundation::SIZE { cx: self.ancho, cy: self.alto };
                let origen = POINT { x: 0, y: 0 };
                let _ = UpdateLayeredWindow(
                    self.hwnd, pantalla, Some(&pos), Some(&tam), memoria, Some(&origen),
                    COLORREF(0), Some(&mezcla), ULW_ALPHA,
                );
                SelectObject(memoria, previo);
                let _ = DeleteObject(dib);
            }
            let _ = DeleteDC(memoria);
            ReleaseDC(None, pantalla);
        }
        t.elapsed().as_secs_f64() * 1000.0
    }

    /// Esconde o muestra el overlay a las capturas. Se pone justo antes del
    /// BitBlt propio y se quita despues, para que shadowplay si lo grabe.
    #[allow(dead_code)]
    fn oculto_a_capturas(&self, si: bool) {
        let si = si && !hay_partida_de_lol();
        unsafe {
            let _ = SetWindowDisplayAffinity(self.hwnd, if si { WDA_EXCLUDEFROMCAPTURE } else { WDA_NONE });
        }
    }
}

fn bombear_mensajes() {
    unsafe {
        let mut m = MSG::default();
        // Con PM_REMOVE hay que despachar: un bucle Win32 que no llama a
        // DispatchMessageW deja WM_PAINT sin validar y gira sin fin. Le costo
        // el 86% de un nucleo a ws-slide.
        while PeekMessageW(&mut m, None, 0, 0, PM_REMOVE).as_bool() {
            let _ = TranslateMessage(&m);
            DispatchMessageW(&m);
        }
    }
}

/// Guion del `--demo`: (segundos desde el inicio, escena).
fn guion(t: f32) -> Escena {
    let mut e = Escena::default();
    let inicio = (0.12, 0.82);
    let destino = (0.74, 0.22);
    let control = (0.35, 0.10);

    match t {
        t if t < 1.2 => {
            e.estado = Some(Estado::Escuchando);
            e.oido = Some("...".into());
        }
        t if t < 2.4 => {
            e.estado = Some(Estado::Escuchando);
            e.oido = Some("donde exporto esto?".into());
        }
        t if t < 3.4 => {
            e.estado = Some(Estado::Mirando);
            e.oido = Some("donde exporto esto?".into());
            e.dice = Some("Déjame ver…".into());
        }
        t if t < 4.6 => {
            // El vuelo: el cursor recorre el arco y el arco se ve entero.
            let k = ((t - 3.4) / 1.2).clamp(0.0, 1.0);
            let suave = k * k * (3.0 - 2.0 * k);
            e.estado = Some(Estado::Hablando);
            e.oido = Some("donde exporto esto?".into());
            e.dice = Some("Está arriba a la derecha".into());
            e.vuelo = Some((inicio, control, destino));
            e.cursor = Some(pintura::punto_arco(inicio, control, destino, suave));
        }
        t if t < 7.0 => {
            e.estado = Some(Estado::Hablando);
            e.oido = Some("donde exporto esto?".into());
            e.dice = Some("Está arriba a la derecha, en Deliver".into());
            e.cursor = Some(destino);
            e.objetivo = Some(destino);
            e.bocadillo = Some("Deliver".into());
            e.trazos = vec![Trazo::Caja { x: 0.70, y: 0.17, w: 0.10, h: 0.06 }];
        }
        t if t < 10.0 => {
            e.estado = Some(Estado::Hablando);
            e.dice = Some("Y los pasos son estos tres".into());
            e.cursor = Some(destino);
            e.objetivo = Some(destino);
            e.trazos = vec![
                Trazo::Caja { x: 0.70, y: 0.17, w: 0.10, h: 0.06 },
                Trazo::Paso { x: 0.22, y: 0.36, n: 1 },
                Trazo::Paso { x: 0.44, y: 0.50, n: 2 },
                Trazo::Paso { x: 0.68, y: 0.64, n: 3 },
                Trazo::Flecha { x1: 0.25, y1: 0.38, x2: 0.41, y2: 0.48 },
                Trazo::Flecha { x1: 0.47, y1: 0.52, x2: 0.65, y2: 0.62 },
                Trazo::Subrayado { x: 0.20, y: 0.72, w: 0.24 },
            ];
        }
        t if t < 11.0 => {
            // Una respuesta larga: tiene que partirse en lineas y no salirse
            // de la pantalla.
            e.estado = Some(Estado::Hablando);
            e.oido = Some("¿a cuánto está el dólar hoy en Perú?".into());
            e.dice = Some("El dólar en Perú hoy está a 3.362 soles según elperu, y a 3.44 compra y 3.46 venta en las casas de cambio digitales según dolargpt. Cambia a lo largo del día, así que tómalo como referencia.".into());
        }
        _ => {
            e.estado = Some(Estado::Esperando);
            e.dice = Some("¿Le doy?".into());
            e.cursor = Some(destino);
            e.objetivo = Some(destino);
            e.trazos = vec![Trazo::Caja { x: 0.70, y: 0.17, w: 0.10, h: 0.06 }];
        }
    }
    e
}

const DURACION: f32 = 12.0;

fn prueba(dir: &str) -> Result<(), String> {
    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    let (ancho, alto) = (1920u32, 1080u32);
    let mut lienzo = Lienzo { ancho, alto, fuente: pintura::Fuente::cargar()? };
    let mut px = Pixmap::new(ancho, alto).ok_or("sin memoria para el pixmap")?;

    for (i, t) in [0.5f32, 2.0, 3.0, 4.0, 5.5, 8.0, 10.5, 11.5].iter().enumerate() {
        let e = guion(*t);
        lienzo.pintar(&mut px, &e, *t);
        let destino = format!("{dir}/escena{i}_t{:.0}.png", t * 10.0);
        px.save_png(&destino).map_err(|e| e.to_string())?;
        // Una escena en blanco casi siempre significa que la fuente no cargo o
        // que el guion devolvio Escena::default(): mejor que falle aqui.
        let vivos = px.data().iter().skip(3).step_by(4).filter(|&&a| a > 8).count();
        assert!(vivos > 500, "la escena de t={t} salio practicamente vacia ({vivos} pixeles)");
        println!("{destino}  {vivos} pixeles pintados");
    }
    println!("ok  {} escenas en {dir}", 8);
    Ok(())
}

/// Modo servidor: cada linea de stdin es una escena JSON y se pinta.
///
/// El overlay se queda como un lienzo tonto y quien orquesta puede ser
/// cualquier cosa -- ahora un script, luego un binario. Se sigue repintando
/// entre escenas porque el anillo late y la pildora respira: si solo pintara al
/// recibir, la animacion se congelaria entre mensajes.
///
/// Una linea vacia limpia la pantalla. `salir` termina.
fn servir(oculto: bool) -> Result<(), String> {
    use std::io::BufRead;
    use std::sync::{Arc, Mutex};

    let v = Ventana::crear(oculto)?;
    let mut lienzo = Lienzo {
        ancho: v.ancho as u32,
        alto: v.alto as u32,
        fuente: pintura::Fuente::cargar()?,
    };
    let mut px = Pixmap::new(v.ancho as u32, v.alto as u32).ok_or("sin memoria")?;

    let actual: Arc<Mutex<Option<Escena>>> = Arc::new(Mutex::new(None));
    let fin = Arc::new(std::sync::atomic::AtomicBool::new(false));
    {
        let actual = actual.clone();
        let fin = fin.clone();
        // Hilo aparte: leer stdin bloquea, y el bucle de pintado no puede
        // pararse o la animacion daria tirones.
        std::thread::spawn(move || {
            for linea in std::io::stdin().lock().lines() {
                let Ok(l) = linea else { break };
                // El BOM se quita a mano: `trim()` no lo toca porque U+FEFF no
                // es espacio en blanco para Rust, y basta uno al principio para
                // que serde falle con "expected value at line 1 column 1" y se
                // pierda la primera escena entera. Quien escriba en esta tuberia
                // no tiene por que saberlo.
                let l = l.trim_start_matches('\u{feff}').trim();
                if l == "salir" {
                    fin.store(true, std::sync::atomic::Ordering::Relaxed);
                    break;
                }
                if l.is_empty() {
                    *actual.lock().unwrap() = None;
                    continue;
                }
                match serde_json::from_str::<Escena>(l) {
                    Ok(e) => *actual.lock().unwrap() = Some(e),
                    Err(err) => eprintln!("escena ilegible: {err}"),
                }
            }
            fin.store(true, std::sync::atomic::Ordering::Relaxed);
        });
    }

    println!("listo {}x{} en ({},{})", v.ancho, v.alto, v.x, v.y);
    let arranque = Instant::now();
    while !fin.load(std::sync::atomic::Ordering::Relaxed) {
        bombear_mensajes();
        let e = actual.lock().unwrap().clone().unwrap_or_default();
        let t = arranque.elapsed().as_secs_f32();
        lienzo.pintar(&mut px, &e, t);
        v.presentar(&px, entrada(t));
        std::thread::sleep(std::time::Duration::from_millis(16));
    }
    // Salida con fundido: antes desaparecia de golpe. El que la cierra
    // ("salir" en la tuberia) espera hasta 3 s, asi que 150 ms caben.
    let e = actual.lock().unwrap().clone().unwrap_or_default();
    let fuera = Instant::now();
    while fuera.elapsed().as_secs_f32() < FUNDIDO {
        bombear_mensajes();
        let k = 1.0 - fuera.elapsed().as_secs_f32() / FUNDIDO;
        lienzo.pintar(&mut px, &e, arranque.elapsed().as_secs_f32());
        v.presentar(&px, (k.clamp(0.0, 1.0) * 255.0) as u8);
        std::thread::sleep(std::time::Duration::from_millis(16));
    }
    Ok(())
}

/// Fundido de entrada y salida (TODO de estetica: "los trazos aparecen y
/// desaparecen de golpe; un fundido de 150 ms se notaria mucho").
const FUNDIDO: f32 = 0.15;

/// La opacidad de la capa a los `t` segundos de abrirla.
fn entrada(t: f32) -> u8 {
    ((t / FUNDIDO).clamp(0.0, 1.0) * 255.0) as u8
}

/// Una sola escena, en pantalla hasta que alguien mate el proceso.
///
/// Existe para el hueco entre pulsar el atajo y que haya respuesta: mientras
/// hablas, `ojo.ps1` todavia no se ha lanzado, asi que no hay overlay y la
/// pantalla no dice nada. Lo primero que se pidio tras la sesion con microfono
/// fue justo eso -- "necesito un feedback visual de que me esta escuchando" --
/// y a la ALTURA DE LOS SUBTITULOS, que es donde ya estan los ojos, no en la
/// barra de arriba.
///
/// `--servir` no vale para esto: lee de stdin y al cerrarse la tuberia se
/// termina, asi que `echo ... | ojo-overlay --servir` aparece y desaparece.
///
/// Lo mata `ojo.ps1`, que ya se encarga de cerrar el overlay anterior antes de
/// abrir el suyo.
fn una_escena(json: &str, oculto: bool, segundos: f32) -> Result<(), String> {
    let e: Escena = serde_json::from_str(json.trim_start_matches('\u{feff}').trim())
        .map_err(|err| format!("escena ilegible: {err}"))?;
    let v = Ventana::crear(oculto)?;
    let mut lienzo = Lienzo {
        ancho: v.ancho as u32,
        alto: v.alto as u32,
        fuente: pintura::Fuente::cargar()?,
    };
    let mut px = Pixmap::new(v.ancho as u32, v.alto as u32).ok_or("sin memoria")?;
    // SEGURO DE VIDA. Una ventana en capa a pantalla completa repintando a
    // 60 fps compite con el modelo por la GPU, asi que una que se quede
    // colgada no es un adorno olvidado: es una fuga que ralentiza todo.
    //
    // Paso de verdad: el que la abria confiaba en que otro proceso la matara,
    // ese proceso a veces no llegaba a correr, y se acumularon. La latencia
    // del modelo subio de 2,5 s a 222 s con la GPU al 99%.
    //
    // Ahora quien la abre la cierra, y esto es el ultimo recurso por si ese
    // tambien falla.
    let arranque = Instant::now();
    loop {
        bombear_mensajes();
        let t = arranque.elapsed().as_secs_f32();
        if segundos > 0.0 && t > segundos {
            return Ok(());
        }
        lienzo.pintar(&mut px, &e, t);
        v.presentar(&px, entrada(t));
        std::thread::sleep(std::time::Duration::from_millis(16));
    }
}

fn main() -> Result<(), String> {
    unsafe {
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    }
    let args: Vec<String> = std::env::args().skip(1).collect();
    let oculto = args.iter().any(|a| a == "--oculto");
    if oculto && hay_partida_de_lol() {
        eprintln!("--oculto rechazado: hay una partida de League abierta (anti-cheat)");
    }
    let oculto = oculto && !hay_partida_de_lol();

    if let Some(i) = args.iter().position(|a| a == "--escena") {
        let j = args.get(i + 1).cloned().unwrap_or_default();
        // Por defecto 60 s: nadie habla mas de un minuto seguido, y una escena
        // que sobreviva a eso esta colgada. 0 = sin limite, solo para pruebas.
        let seg = args
            .iter()
            .position(|a| a == "--segundos")
            .and_then(|k| args.get(k + 1))
            .and_then(|v| v.parse().ok())
            .unwrap_or(60.0);
        return una_escena(&j, oculto, seg);
    }

    if let Some(i) = args.iter().position(|a| a == "--prueba") {
        let dir = args.get(i + 1).cloned().unwrap_or_else(|| "escenas".into());
        return prueba(&dir);
    }
    if args.iter().any(|a| a == "--servir") {
        return servir(oculto);
    }
    if !args.iter().any(|a| a == "--demo") {
        eprintln!("uso: ojo-overlay --demo | --servir | --prueba <dir> [--oculto]");
        return Ok(());
    }

    let v = Ventana::crear(oculto)?;
    let mut lienzo = Lienzo {
        ancho: v.ancho as u32,
        alto: v.alto as u32,
        fuente: pintura::Fuente::cargar()?,
    };
    let mut px = Pixmap::new(v.ancho as u32, v.alto as u32).ok_or("sin memoria para el pixmap")?;

    println!("overlay {}x{} en ({},{})  oculto a capturas: {oculto}", v.ancho, v.alto, v.x, v.y);
    let arranque = Instant::now();
    let mut cuadros = 0u32;
    let mut pintar_ms = Vec::new();
    let mut presentar_ms = Vec::new();

    loop {
        bombear_mensajes();
        let t = arranque.elapsed().as_secs_f32();
        if t > DURACION {
            break;
        }
        let e = guion(t);

        let tp = Instant::now();
        lienzo.pintar(&mut px, &e, t);
        pintar_ms.push(tp.elapsed().as_secs_f64() * 1000.0);
        presentar_ms.push(v.presentar(&px, 255));
        cuadros += 1;

        std::thread::sleep(std::time::Duration::from_millis(12));
    }

    let med = |v: &mut Vec<f64>| {
        v.sort_by(|a, b| a.partial_cmp(b).unwrap());
        v[v.len() / 2]
    };
    println!(
        "{}",
        serde_json::json!({
            "cuadros": cuadros,
            "fps": cuadros as f32 / DURACION,
            "pintar_mediana_ms": med(&mut pintar_ms),
            "presentar_mediana_ms": med(&mut presentar_ms),
        })
    );
    Ok(())
}
