//! Todo lo que se dibuja: paleta, texto y las primitivas de la escena.
//!
//! Separado de la ventana a proposito: aqui no hay nada de Windows, asi que
//! `--prueba` puede generar PNG y comprobarlos sin abrir ninguna ventana.

use tiny_skia::{
    Color, FillRule, LineCap, LineJoin, Paint, PathBuilder, Pixmap, PixmapPaint, Rect, Stroke,
    Transform,
};

// Paleta de `rice-common::theme`, copiada en vez de importada para no arrastrar
// el crate entero (y sus features de egui) a un binario que no usa egui.
pub const FONDO: [u8; 3] = [26, 22, 19];
pub const SUPERFICIE: [u8; 3] = [40, 33, 28];
pub const TEXTO: [u8; 3] = [233, 224, 214];
pub const SUBTEXTO: [u8; 3] = [170, 154, 140];
pub const ACENTO: [u8; 3] = [224, 163, 92];
pub const ACENTO_OK: [u8; 3] = [169, 181, 106];
pub const ACENTO_AVISO: [u8; 3] = [208, 135, 112];

pub fn col(c: [u8; 3], a: f32) -> Color {
    Color::from_rgba8(c[0], c[1], c[2], (a.clamp(0.0, 1.0) * 255.0) as u8)
}

fn relleno(c: Color) -> Paint<'static> {
    let mut p = Paint::default();
    p.set_color(c);
    p.anti_alias = true;
    p
}

fn trazo(ancho: f32) -> Stroke {
    Stroke { width: ancho, line_cap: LineCap::Round, line_join: LineJoin::Round, ..Default::default() }
}

/// Rectangulo redondeado. tiny-skia no trae uno, y hace falta en casi todo:
/// panel de subtitulos, bocadillo y pildora de estado.
pub fn rect_redondo(px: &mut Pixmap, x: f32, y: f32, w: f32, h: f32, r: f32, c: Color) {
    let r = r.min(w / 2.0).min(h / 2.0);
    let mut b = PathBuilder::new();
    b.move_to(x + r, y);
    b.line_to(x + w - r, y);
    b.quad_to(x + w, y, x + w, y + r);
    b.line_to(x + w, y + h - r);
    b.quad_to(x + w, y + h, x + w - r, y + h);
    b.line_to(x + r, y + h);
    b.quad_to(x, y + h, x, y + h - r);
    b.line_to(x, y + r);
    b.quad_to(x, y, x + r, y);
    b.close();
    if let Some(p) = b.finish() {
        px.fill_path(&p, &relleno(c), FillRule::Winding, Transform::identity(), None);
    }
}

pub fn circulo(px: &mut Pixmap, cx: f32, cy: f32, r: f32, c: Color) {
    if let Some(p) = PathBuilder::from_circle(cx, cy, r) {
        px.fill_path(&p, &relleno(c), FillRule::Winding, Transform::identity(), None);
    }
}

pub fn anillo(px: &mut Pixmap, cx: f32, cy: f32, r: f32, grosor: f32, c: Color) {
    if let Some(p) = PathBuilder::from_circle(cx, cy, r) {
        px.stroke_path(&p, &relleno(c), &trazo(grosor), Transform::identity(), None);
    }
}

pub fn linea(px: &mut Pixmap, x1: f32, y1: f32, x2: f32, y2: f32, ancho: f32, c: Color) {
    let mut b = PathBuilder::new();
    b.move_to(x1, y1);
    b.line_to(x2, y2);
    if let Some(p) = b.finish() {
        px.stroke_path(&p, &relleno(c), &trazo(ancho), Transform::identity(), None);
    }
}

pub fn caja(px: &mut Pixmap, x: f32, y: f32, w: f32, h: f32, ancho: f32, c: Color) {
    if let Some(r) = Rect::from_xywh(x, y, w, h) {
        let p = PathBuilder::from_rect(r);
        px.stroke_path(&p, &relleno(c), &trazo(ancho), Transform::identity(), None);
    }
}

/// Curva bezier cuadratica, que es el arco de vuelo del cursor.
pub fn arco(px: &mut Pixmap, x1: f32, y1: f32, cx: f32, cy: f32, x2: f32, y2: f32, ancho: f32, c: Color) {
    let mut b = PathBuilder::new();
    b.move_to(x1, y1);
    b.quad_to(cx, cy, x2, y2);
    if let Some(p) = b.finish() {
        px.stroke_path(&p, &relleno(c), &trazo(ancho), Transform::identity(), None);
    }
}

/// Punto sobre una bezier cuadratica, para saber donde va el cursor en cada t.
pub fn punto_arco(p0: (f32, f32), c: (f32, f32), p1: (f32, f32), t: f32) -> (f32, f32) {
    let u = 1.0 - t;
    (
        u * u * p0.0 + 2.0 * u * t * c.0 + t * t * p1.0,
        u * u * p0.1 + 2.0 * u * t * c.1 + t * t * p1.1,
    )
}

/// Halo: circulos concentricos cada vez mas transparentes.
///
/// tiny-skia no tiene desenfoque, y meter uno de verdad costaria un filtro
/// separable sobre todo el buffer en cada cuadro. Cuatro circulos dan el mismo
/// efecto a esta escala por una fraccion del coste.
///
/// Mas corto y mas tenue que antes (x0,9 y no x1,6; sin el +0,02 fijo): cada
/// circulo sumaba su 0,02 y los cuatro juntos dejaban un manchon marron que le
/// quitaba contraste al anillo ambar (TODO de estetica).
pub fn halo(px: &mut Pixmap, cx: f32, cy: f32, r: f32, c: [u8; 3], a: f32) {
    for i in (1..=4).rev() {
        let k = i as f32 / 4.0;
        circulo(px, cx, cy, r * (1.0 + k * 0.9), col(c, a * 0.07 * (1.0 - k)));
    }
}

/// Una linea con un contorno oscuro debajo: el ambar solo, sobre una ventana
/// blanca, pierde casi todo el contraste (TODO de estetica, "sin modo claro").
pub fn linea_con_borde(px: &mut Pixmap, x1: f32, y1: f32, x2: f32, y2: f32, ancho: f32, c: Color) {
    linea(px, x1, y1, x2, y2, ancho + 2.5, col(FONDO, 0.55));
    linea(px, x1, y1, x2, y2, ancho, c);
}

/// El cursor del agente: una flecha propia, nunca la del sistema.
///
/// Que no se parezca al cursor real es deliberado: si se parecieran, en modo
/// agente no se sabria cual se esta moviendo.
pub fn cursor_agente(px: &mut Pixmap, x: f32, y: f32, escala: f32, a: f32) {
    halo(px, x, y, 9.0 * escala, ACENTO, a);
    let pts = [(0.0, 0.0), (0.0, 17.0), (4.6, 13.0), (7.6, 19.6), (10.6, 18.2), (7.6, 11.8), (13.2, 11.4)];
    let mut b = PathBuilder::new();
    b.move_to(x + pts[0].0 * escala, y + pts[0].1 * escala);
    for p in &pts[1..] {
        b.line_to(x + p.0 * escala, y + p.1 * escala);
    }
    b.close();
    if let Some(p) = b.finish() {
        // Contorno oscuro primero: sobre fondo claro la flecha ambar sola
        // desaparece.
        px.stroke_path(&p, &relleno(col(FONDO, a * 0.85)), &trazo(3.0 * escala), Transform::identity(), None);
        px.fill_path(&p, &relleno(col(ACENTO, a)), FillRule::Winding, Transform::identity(), None);
    }
}

// ---------------------------------------------------------------- texto

pub struct Fuente {
    fuente: fontdue::Font,
    cache: std::collections::HashMap<(char, u32), (fontdue::Metrics, Vec<u8>)>,
}

impl Fuente {
    /// Carga la Nerd Font del rice; si no esta, Segoe UI.
    pub fn cargar() -> Result<Self, String> {
        let perfil = std::env::var("USERPROFILE").unwrap_or_default();
        let rutas = [
            r"C:\Windows\Fonts\JetBrainsMonoNerdFont-Regular.ttf".to_string(),
            format!(r"{perfil}\AppData\Local\Microsoft\Windows\Fonts\JetBrainsMonoNerdFont-Regular.ttf"),
            r"C:\Windows\Fonts\segoeui.ttf".to_string(),
        ];
        for r in rutas {
            if let Ok(bytes) = std::fs::read(&r) {
                let f = fontdue::Font::from_bytes(bytes, fontdue::FontSettings::default())
                    .map_err(|e| format!("{r}: {e}"))?;
                return Ok(Self { fuente: f, cache: std::collections::HashMap::new() });
            }
        }
        Err("no se encontro ninguna fuente".into())
    }

    fn glifo(&mut self, c: char, tam: f32) -> &(fontdue::Metrics, Vec<u8>) {
        let clave = (c, (tam * 10.0) as u32);
        if !self.cache.contains_key(&clave) {
            self.cache.insert(clave, self.fuente.rasterize(c, tam));
        }
        &self.cache[&clave]
    }

    pub fn ancho(&mut self, texto: &str, tam: f32) -> f32 {
        texto.chars().map(|c| self.glifo(c, tam).0.advance_width).sum()
    }

    /// Parte el texto en lineas que quepan en `max` px, por palabras. Una frase
    /// larga se salia del ancho de la pantalla (TODO de estetica).
    pub fn partir(&mut self, texto: &str, tam: f32, max: f32) -> Vec<String> {
        let mut lineas = Vec::new();
        let mut actual = String::new();
        for palabra in texto.split_whitespace() {
            let prueba = if actual.is_empty() { palabra.to_string() } else { format!("{actual} {palabra}") };
            if !actual.is_empty() && self.ancho(&prueba, tam) > max {
                lineas.push(std::mem::take(&mut actual));
                actual = palabra.to_string();
            } else {
                actual = prueba;
            }
        }
        if !actual.is_empty() {
            lineas.push(actual);
        }
        lineas
    }

    /// Dibuja el texto y devuelve el ancho pintado.
    pub fn dibujar(&mut self, px: &mut Pixmap, texto: &str, x: f32, y: f32, tam: f32, c: [u8; 3], a: f32) -> f32 {
        let (pw, ph) = (px.width() as i32, px.height() as i32);
        let mut cx = x;
        for ch in texto.chars() {
            let (m, mapa) = self.glifo(ch, tam).clone();
            let gx = cx + m.xmin as f32;
            let gy = y - m.height as f32 - m.ymin as f32;
            for fy in 0..m.height {
                for fx in 0..m.width {
                    let cob = mapa[fy * m.width + fx];
                    if cob == 0 {
                        continue;
                    }
                    let dx = (gx as i32) + fx as i32;
                    let dy = (gy as i32) + fy as i32;
                    if dx < 0 || dy < 0 || dx >= pw || dy >= ph {
                        continue;
                    }
                    // Mezcla manual: rasterizar cada glifo como path costaria
                    // mucho mas, y fontdue ya da la cobertura lista.
                    let alfa = (cob as f32 / 255.0) * a;
                    let i = (dy as usize * pw as usize + dx as usize) * 4;
                    let d = px.data_mut();
                    for k in 0..3 {
                        let src = c[k] as f32 * alfa;
                        d[i + k] = (src + d[i + k] as f32 * (1.0 - alfa)) as u8;
                    }
                    d[i + 3] = ((alfa + d[i + 3] as f32 / 255.0 * (1.0 - alfa)) * 255.0) as u8;
                }
            }
            cx += m.advance_width;
        }
        cx - x
    }
}

pub fn pegar(destino: &mut Pixmap, origen: &Pixmap, x: f32, y: f32) {
    destino.draw_pixmap(
        x as i32,
        y as i32,
        origen.as_ref(),
        &PixmapPaint::default(),
        Transform::identity(),
        None,
    );
}
