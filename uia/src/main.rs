//! Los controles reales de la ventana activa, con sus rectangulos exactos.
//!
//! Por que esto existe: pedirle coordenadas a un modelo de vision da 52,7% de
//! acierto en ScreenSpot-Pro, y aqui se midio el sintoma -- describe bien pero
//! senala regular. UI Automation NO adivina: devuelve el rectangulo exacto que
//! el propio sistema usa para dibujar y para el lector de pantalla.
//!
//! Es el camino de UFO2, el agente de escritorio de Microsoft: controles de UIA
//! como fuente principal y vision solo para rellenar lo que UIA no ve.
//!
//! Limites reales, y por eso la vision no se tira a la basura:
//! - Juegos, Electron mal configurado y ventanas dibujadas a mano no exponen
//!   nada util.
//! - El rectangulo puede contener puntos NO pulsables si el control tiene forma
//!   irregular o esta tapado por otro.
//!
//!   ojo-uia                 controles de la ventana activa, JSON
//!   ojo-uia --todos         sin filtrar por tipo interactivo
//!   ojo-uia --max 40        cuantos devolver como maximo
//!   ojo-uia --ventana pila  la ventana cuyo titulo contenga eso, no la activa
//!   ojo-uia --demo          autocomprobacion

use serde::Serialize;
use windows::core::{BSTR, VARIANT};
use windows::Win32::Foundation::{BOOL, HWND, LPARAM, RECT};
use windows::Win32::Graphics::Dwm::{DwmGetWindowAttribute, DWMWA_CLOAKED};
use windows::Win32::Graphics::Gdi::{GetMonitorInfoW, MonitorFromWindow, MONITORINFO, MONITOR_DEFAULTTOPRIMARY};
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CLSCTX_INPROC_SERVER, COINIT_APARTMENTTHREADED,
};
use windows::Win32::UI::Accessibility::{
    CUIAutomation, IUIAutomation, IUIAutomationElement, TreeScope_Descendants,
    UIA_ControlTypePropertyId, UIA_ButtonControlTypeId,
    UIA_CheckBoxControlTypeId, UIA_ComboBoxControlTypeId, UIA_EditControlTypeId,
    UIA_HyperlinkControlTypeId, UIA_ListItemControlTypeId, UIA_MenuItemControlTypeId,
    UIA_RadioButtonControlTypeId, UIA_SliderControlTypeId, UIA_TabItemControlTypeId,
    UIA_TextControlTypeId, UIA_TreeItemControlTypeId, UIA_CONTROLTYPE_ID,
};
use windows::Win32::UI::HiDpi::{SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2};
use windows::Win32::UI::WindowsAndMessaging::{
    EnumWindows, GetForegroundWindow, GetWindowRect, GetWindowTextW, IsWindowVisible,
};

/// Tipos que vale la pena ofrecerle al modelo. Un arbol de UIA trae cientos de
/// paneles y grupos que no se pueden pulsar y solo gastan contexto.
const INTERACTIVOS: &[UIA_CONTROLTYPE_ID] = &[
    UIA_ButtonControlTypeId,
    UIA_CheckBoxControlTypeId,
    UIA_ComboBoxControlTypeId,
    UIA_EditControlTypeId,
    UIA_HyperlinkControlTypeId,
    UIA_ListItemControlTypeId,
    UIA_MenuItemControlTypeId,
    UIA_RadioButtonControlTypeId,
    UIA_SliderControlTypeId,
    UIA_TabItemControlTypeId,
    UIA_TreeItemControlTypeId,
    // TEXTO NO ESTA AQUI a proposito. Se probo incluirlo y en Hearthstone Deck
    // Tracker los 60 huecos se los comieron etiquetas de un caracter ("1", "3",
    // "0") de la tabla de estadisticas: ruido que tapa los botones de verdad.
    // Con --todos sigue saliendo.
];

fn nombre_tipo(t: UIA_CONTROLTYPE_ID) -> &'static str {
    match t {
        t if t == UIA_ButtonControlTypeId => "boton",
        t if t == UIA_CheckBoxControlTypeId => "casilla",
        t if t == UIA_ComboBoxControlTypeId => "desplegable",
        t if t == UIA_EditControlTypeId => "campo",
        t if t == UIA_HyperlinkControlTypeId => "enlace",
        t if t == UIA_ListItemControlTypeId => "item",
        t if t == UIA_MenuItemControlTypeId => "menu",
        t if t == UIA_RadioButtonControlTypeId => "opcion",
        t if t == UIA_SliderControlTypeId => "deslizador",
        t if t == UIA_TabItemControlTypeId => "pestana",
        t if t == UIA_TreeItemControlTypeId => "rama",
        t if t == UIA_TextControlTypeId => "texto",
        _ => "otro",
    }
}

#[derive(Serialize, Clone, Debug)]
pub struct Control {
    pub n: usize,
    pub nombre: String,
    pub tipo: &'static str,
    /// Centro normalizado al monitor: lo que el overlay y el modelo entienden.
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
    /// Centro en pixeles fisicos, que es lo que hace falta para pulsar.
    pub px: i32,
    pub py: i32,
}

#[derive(Serialize)]
struct Salida {
    ventana: String,
    monitor: [i32; 4],
    encontrados: usize,
    ms: u128,
    controles: Vec<Control>,
}

/// Buscar por titulo existe para PROBAR: la ventana activa mientras corre esto
/// es siempre la consola, y una consola no expone controles. El orquestador usa
/// la activa; las mediciones necesitan apuntar a otra cosa.
struct Busqueda {
    aguja: String,
    hallado: HWND,
    /// Area de la mejor candidata hasta ahora. Ver `visita`.
    area: i64,
}

/// IsWindowVisible NO basta en Windows 11. GlazeWM esconde los espacios de
/// trabajo *ocultando por DWM*, no moviendo ni minimizando: la ventana sigue
/// diciendo que es visible, conserva sus coordenadas y UIA devuelve rectangulos
/// perfectamente plausibles... de algo que no se esta dibujando.
///
/// Costo una imagen de comparacion entera: los rectangulos de Firefox cayeron
/// encima de la captura de otra aplicacion y parecian correctos. Lo mismo pasa
/// con los escritorios virtuales y con las UWP suspendidas.
unsafe fn oculta_por_dwm(h: HWND) -> bool {
    let mut c: u32 = 0;
    DwmGetWindowAttribute(
        h,
        DWMWA_CLOAKED,
        &mut c as *mut _ as *mut _,
        std::mem::size_of::<u32>() as u32,
    )
    .is_ok()
        && c != 0
}

unsafe extern "system" fn visita(h: HWND, lp: LPARAM) -> BOOL {
    let b = &mut *(lp.0 as *mut Busqueda);
    if !IsWindowVisible(h).as_bool() || oculta_por_dwm(h) {
        return true.into();
    }
    let mut buf = [0u16; 512];
    let n = GetWindowTextW(h, &mut buf);
    if n == 0 {
        return true.into();
    }
    let t = String::from_utf16_lossy(&buf[..n as usize]).to_lowercase();
    if !t.contains(&b.aguja) {
        return true.into();
    }
    // LA MAS GRANDE, no la primera.
    //
    // Una aplicacion puede tener varias ventanas visibles cuyo titulo case:
    // "discord" engancho "Discord Overlay" -- una ventana auxiliar con CINCO
    // controles -- en vez de la real, que tiene 144. La medicion salio 0 de 4 y
    // parecia que el modelo no sabia elegir; lo que pasaba es que no habia de
    // donde elegir.
    //
    // El area separa la ventana de la aplicacion de sus satelites sin tener que
    // mantener una lista de nombres raros.
    let mut r = RECT::default();
    if GetWindowRect(h, &mut r).is_ok() {
        let area = (r.right - r.left) as i64 * (r.bottom - r.top) as i64;
        if area > b.area {
            b.area = area;
            b.hallado = h;
        }
    }
    true.into() // seguir: hay que verlas todas para saber cual es la mayor
}

fn busca_ventana(aguja: &str) -> Option<HWND> {
    let mut b = Busqueda { aguja: aguja.to_lowercase(), hallado: HWND::default(), area: 0 };
    unsafe {
        let _ = EnumWindows(Some(visita), LPARAM(&mut b as *mut _ as isize));
    }
    (!b.hallado.0.is_null()).then_some(b.hallado)
}

/// Hearthstone Deck Tracker (WPF) pone la geometria del icono como nombre del
/// boton: "M240.125,160L400.125,320 80.125,320 240.125,160z". Es basura para el
/// modelo y ocupa un hueco de los 40. Se corta lo largo y casi todo simbolos;
/// un "100%" o un "2026" cortos se salvan porque a veces son la etiqueta buena.
fn basura(s: &str) -> bool {
    if s.chars().count() <= 12 {
        return false;
    }
    let letras = s.chars().filter(|c| c.is_alphabetic()).count();
    letras * 2 < s.chars().count()
}

fn texto(b: windows::core::Result<BSTR>) -> String {
    b.map(|s| s.to_string()).unwrap_or_default().trim().to_string()
}

fn recoger(max: usize, todos: bool, ventana: Option<&str>) -> Result<Salida, String> {
    let t0 = std::time::Instant::now();
    unsafe {
        // APARTMENTTHREADED y no MULTITHREADED: UIA es un componente COM de
        // apartamento y con MTA cada llamada cruza un marshaller, que multiplica
        // el coste de enumerar cientos de elementos.
        let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
        let auto: IUIAutomation = CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER)
            .map_err(|e| format!("no se pudo crear UIAutomation: {e}"))?;

        let hwnd: HWND = match ventana {
            Some(t) => busca_ventana(t).ok_or_else(|| format!("ninguna ventana visible con '{t}' en el titulo"))?,
            None => GetForegroundWindow(),
        };
        if hwnd.0.is_null() {
            return Err("no hay ventana en primer plano".into());
        }

        let mut info = MONITORINFO { cbSize: std::mem::size_of::<MONITORINFO>() as u32, ..Default::default() };
        let mon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTOPRIMARY);
        let _ = GetMonitorInfoW(mon, &mut info);
        let m = info.rcMonitor;
        let (mx, my) = (m.left as f32, m.top as f32);
        let (mw, mh) = ((m.right - m.left) as f32, (m.bottom - m.top) as f32);

        let raiz: IUIAutomationElement = auto
            .ElementFromHandle(hwnd)
            .map_err(|e| format!("ElementFromHandle: {e}"))?;
        let ventana = texto(raiz.CurrentName());

        // Filtrar DENTRO de UIA y no en Rust. Con una condicion cierta vuelven
        // cientos de elementos y cada propiedad que se lee de ellos es un viaje
        // COM al proceso de la aplicacion. Con la condicion por tipo el arbol se
        // recorre del otro lado y solo cruzan los que valen.
        //
        // Se probo tambien la peticion de cache (FindAllBuildCache + Cached*),
        // que en teoria agrupa los viajes en uno: medida en Firefox salio PEOR,
        // 1.330 ms contra 952. Obliga a materializar las propiedades de todo el
        // arbol, y el camino perezoso descarta antes de leer nada. Descartada
        // con numeros, no por gusto.
        let cond = if todos {
            auto.CreateTrueCondition().map_err(|e| e.to_string())?
        } else {
            // Se pliega de dos en dos en vez de CreateOrConditionFromArray,
            // que pide un SAFEARRAY crudo y no merece el codigo por 11 tipos.
            let mut it = INTERACTIVOS.iter().map(|t| {
                auto.CreatePropertyCondition(UIA_ControlTypePropertyId, &VARIANT::from(t.0))
            });
            let mut c = it.next().unwrap().map_err(|e| e.to_string())?;
            for sig in it {
                c = auto
                    .CreateOrCondition(&c, &sig.map_err(|e| e.to_string())?)
                    .map_err(|e| e.to_string())?;
            }
            c
        };

        let todos_el = raiz
            .FindAll(TreeScope_Descendants, &cond)
            .map_err(|e| format!("FindAll: {e}"))?;
        let n = todos_el.Length().unwrap_or(0);

        let mut out: Vec<Control> = Vec::new();
        for i in 0..n {
            let Ok(el) = todos_el.GetElement(i) else { continue };
            // Fuera de pantalla: existe en el arbol pero no se ve, asi que
            // senalarlo seria mentir.
            if el.CurrentIsOffscreen().map(|b| b.as_bool()).unwrap_or(false) {
                continue;
            }
            let tipo = el.CurrentControlType().unwrap_or_default();
            if !todos && !INTERACTIVOS.contains(&tipo) {
                continue;
            }
            let Ok(r) = el.CurrentBoundingRectangle() else { continue };
            let (w, h) = ((r.right - r.left) as f32, (r.bottom - r.top) as f32);
            if w < 6.0 || h < 6.0 {
                continue;
            }
            // Un control que ocupa casi todo no sirve para senalar: es el panel
            // contenedor, no el objetivo.
            if w > mw * 0.9 && h > mh * 0.9 {
                continue;
            }
            let nombre = texto(el.CurrentName());
            if nombre.is_empty() || basura(&nombre) {
                continue;
            }
            out.push(Control {
                n: 0,
                nombre: nombre.chars().take(60).collect(),
                tipo: nombre_tipo(tipo),
                x: ((r.left as f32 - mx) + w / 2.0) / mw,
                y: ((r.top as f32 - my) + h / 2.0) / mh,
                w: w / mw,
                h: h / mh,
                px: r.left + (w / 2.0) as i32,
                py: r.top + (h / 2.0) as i32,
            });
        }

        // Sin ordenar por area, y con los nombres repetidos fuera.
        //
        // La primera version ponia los pequenos primero, con la idea de que los
        // grandes son contenedores. Medido en Discord, eso empujaba el cuadro de
        // busqueda -- ancho, y por tanto "grande" -- al puesto 68, fuera del
        // corte de 40: el modelo se quedaba sin el y volvia a adivinar. En
        // Firefox pasaba lo mismo con cinco "Close tab" identicos comiendose los
        // primeros huecos.
        //
        // El orden del arbol es el de la propia aplicacion y va con la
        // disposicion visual. Quitar duplicados libera los huecos que hacian
        // falta.
        let mut vistos = std::collections::HashSet::new();
        out.retain(|c| vistos.insert((c.nombre.clone(), c.tipo)));

        // Y DESPUES los pequenos primero. Tres ordenes probados en Discord,
        // contando cuantos de los cuatro objetivos de prueba entran en 40:
        //
        //   orden del arbol   1/4   solo la busqueda
        //   orden por alto    2/4   Mute y Deafen, en los puestos 39 y 40
        //   orden por AREA    3/4   Mute, Deafen y User Settings
        //
        // El alto parecia mejor idea -- un cuadro de busqueda es ancho y bajo,
        // y por area parece un contenedor -- pero medido arrastra decenas de
        // cosas finas y empuja fuera lo que importa. Se queda el area.
        //
        // Lo que NO entra en 40 sigue siendo alcanzable: el enganche de
        // `ojo.ps1` mira los 300, no solo los que van en el prompt.
        out.sort_by(|a, b| (a.w * a.h).partial_cmp(&(b.w * b.h)).unwrap());
        out.truncate(max);
        for (i, c) in out.iter_mut().enumerate() {
            c.n = i + 1;
        }

        Ok(Salida {
            ventana,
            monitor: [m.left, m.top, m.right - m.left, m.bottom - m.top],
            encontrados: out.len(),
            ms: t0.elapsed().as_millis(),
            controles: out,
        })
    }
}

fn demo(ventana: Option<&str>) -> Result<(), String> {
    let s = recoger(60, false, ventana)?;
    // Sin controles puede ser legitimo (un juego, una ventana dibujada a mano),
    // pero en un escritorio normal significa que UIA no arranco.
    assert!(!s.ventana.is_empty() || s.encontrados > 0, "ni nombre de ventana ni controles: UIA no respondio");
    for c in &s.controles {
        assert!((0.0..=1.0).contains(&c.x) && (0.0..=1.0).contains(&c.y),
            "control '{}' fuera del monitor: ({}, {})", c.nombre, c.x, c.y);
        assert!(c.w > 0.0 && c.h > 0.0, "control '{}' sin tamano", c.nombre);
        assert!(!basura(&c.nombre), "se colo un nombre basura: '{}'", c.nombre);
    }
    assert!(basura("M240.125,160L400.125,320 80.125,320 240.125,160z"), "el filtro de basura no filtra");
    assert!(!basura("Close tab") && !basura("100%"), "el filtro de basura se come nombres buenos");
    println!("ok  ventana '{}'  {} controles en {} ms", s.ventana, s.encontrados, s.ms);
    for c in s.controles.iter().take(8) {
        println!("  {:>2}. [{}] {}  ({:.3}, {:.3})", c.n, c.tipo, c.nombre, c.x, c.y);
    }
    Ok(())
}

fn main() {
    unsafe {
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    }
    let args: Vec<String> = std::env::args().skip(1).collect();
    let ventana = args
        .iter()
        .position(|a| a == "--ventana")
        .and_then(|i| args.get(i + 1))
        .map(|s| s.as_str());
    if args.iter().any(|a| a == "--demo") {
        if let Err(e) = demo(ventana) {
            eprintln!("FALLA: {e}");
            std::process::exit(1);
        }
        return;
    }
    let max = args
        .iter()
        .position(|a| a == "--max")
        .and_then(|i| args.get(i + 1))
        .and_then(|v| v.parse().ok())
        .unwrap_or(50);
    match recoger(max, args.iter().any(|a| a == "--todos"), ventana) {
        Ok(s) => println!("{}", serde_json::to_string(&s).unwrap()),
        Err(e) => {
            eprintln!("FALLA: {e}");
            std::process::exit(1);
        }
    }
}





