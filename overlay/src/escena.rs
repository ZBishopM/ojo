//! Que hay en pantalla en un instante dado, y como se pinta.
//!
//! Las coordenadas de las primitivas son NORMALIZADAS (0..1) a proposito: aqui
//! hay dos monitores de resoluciones distintas (1920x1080 y 2560x1440) y la
//! misma respuesta del modelo tiene que valer en los dos.

use serde::{Deserialize, Serialize};
use tiny_skia::Pixmap;

use crate::pintura::*;

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Estado {
    Escuchando,
    Mirando,
    Hablando,
    Actuando,
    Esperando,
}

impl Estado {
    fn texto(self) -> &'static str {
        match self {
            Estado::Escuchando => "escuchando",
            Estado::Mirando => "mirando",
            Estado::Hablando => "hablando",
            Estado::Actuando => "actuando",
            Estado::Esperando => "confirma con Ctrl+Win",
        }
    }
    fn color(self) -> [u8; 3] {
        match self {
            Estado::Escuchando => ACENTO_OK,
            Estado::Mirando => ACENTO,
            Estado::Hablando => TEXTO,
            Estado::Actuando | Estado::Esperando => ACENTO_AVISO,
        }
    }
}

/// Una marca sobre la pantalla. Coordenadas normalizadas.
#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(tag = "tipo", rename_all = "lowercase")]
pub enum Trazo {
    Caja { x: f32, y: f32, w: f32, h: f32 },
    Flecha { x1: f32, y1: f32, x2: f32, y2: f32 },
    Linea { puntos: Vec<(f32, f32)> },
    Subrayado { x: f32, y: f32, w: f32 },
    Paso { x: f32, y: f32, n: u32 },
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
pub struct Escena {
    pub estado: Option<Estado>,
    /// Donde esta el cursor del agente ahora mismo, normalizado.
    pub cursor: Option<(f32, f32)>,
    /// Anillo pulsante sobre el objetivo.
    pub objetivo: Option<(f32, f32)>,
    /// Etiqueta corta pegada al puntero.
    pub bocadillo: Option<String>,
    /// Lo que entendio de la pregunta, en gris encima de los subtitulos.
    pub oido: Option<String>,
    /// Lo que esta diciendo.
    pub dice: Option<String>,
    #[serde(default)]
    pub trazos: Vec<Trazo>,
    /// Arco de vuelo a medio recorrer: origen, control y destino normalizados.
    pub vuelo: Option<((f32, f32), (f32, f32), (f32, f32))>,
}

pub struct Lienzo {
    pub ancho: u32,
    pub alto: u32,
    pub fuente: Fuente,
}

impl Lienzo {
    fn ax(&self, x: f32) -> f32 {
        x * self.ancho as f32
    }
    fn ay(&self, y: f32) -> f32 {
        y * self.alto as f32
    }

    /// Pinta la escena entera. `fase` avanza 0..1 sin parar y mueve lo que late.
    pub fn pintar(&mut self, px: &mut Pixmap, e: &Escena, fase: f32) {
        px.fill(tiny_skia::Color::TRANSPARENT);

        for t in &e.trazos {
            self.trazo(px, t);
        }
        if let Some((p0, c, p1)) = e.vuelo {
            arco(
                px,
                self.ax(p0.0), self.ay(p0.1),
                self.ax(c.0), self.ay(c.1),
                self.ax(p1.0), self.ay(p1.1),
                2.0,
                col(ACENTO, 0.28),
            );
        }
        if let Some((x, y)) = e.objetivo {
            self.anillo_pulsante(px, self.ax(x), self.ay(y), fase);
        }
        if let (Some((cx, cy)), Some(texto)) = (e.cursor, e.bocadillo.as_ref()) {
            self.bocadillo(px, self.ax(cx), self.ay(cy), texto);
        }
        if let Some((x, y)) = e.cursor {
            cursor_agente(px, self.ax(x), self.ay(y), 1.6, 1.0);
        }
        if e.oido.is_some() || e.dice.is_some() {
            self.subtitulos(px, e.oido.as_deref(), e.dice.as_deref());
        }
        if let Some(s) = e.estado {
            self.pildora(px, s, fase);
        }
    }

    /// Dos anillos desfasados: uno crece y se desvanece, el otro queda fijo.
    /// Solo el que crece daria un parpadeo con el objetivo desapareciendo.
    fn anillo_pulsante(&self, px: &mut Pixmap, x: f32, y: f32, fase: f32) {
        // Radio 24 y no 16: el cursor se dibuja encima con la punta en el
        // centro, y con 16 el anillo quedaba tapado por la propia flecha.
        anillo(px, x, y, 24.0, 2.0, col(ACENTO, 0.85));
        let t = fase % 1.0;
        anillo(px, x, y, 24.0 + t * 30.0, 2.5 * (1.0 - t), col(ACENTO, 0.55 * (1.0 - t)));
        circulo(px, x, y, 3.5, col(ACENTO, 0.9));
    }

    fn bocadillo(&mut self, px: &mut Pixmap, cx: f32, cy: f32, texto: &str) {
        let tam = 15.0;
        let w = self.fuente.ancho(texto, tam) + 22.0;
        let h = 30.0;
        // Separado 54 px y bajado 34: con 26 y a la misma altura el bocadillo
        // se montaba encima del cursor y del anillo, y la linea conectora no se
        // veia porque medía cero.
        let x = if cx + 54.0 + w < self.ancho as f32 { cx + 54.0 } else { cx - 54.0 - w };
        let y = (cy + 34.0).clamp(4.0, self.alto as f32 - h - 4.0);
        let borde = if x > cx { x } else { x + w };
        linea(px, cx + 6.0, cy + 10.0, borde, y + h / 2.0, 1.5, col(ACENTO, 0.55));
        rect_redondo(px, x, y, w, h, 8.0, col(FONDO, 0.92));
        rect_redondo(px, x, y, w, 2.0, 1.0, col(ACENTO, 0.9));
        self.fuente.dibujar(px, texto, x + 11.0, y + 20.0, tam, TEXTO, 1.0);
    }

    /// Panel fijo abajo al centro: lo que oyo arriba en gris, lo que dice abajo.
    fn subtitulos(&mut self, px: &mut Pixmap, oido: Option<&str>, dice: Option<&str>) {
        let tam_d = 22.0;
        let tam_o = 14.0;
        let w_d = dice.map(|s| self.fuente.ancho(s, tam_d)).unwrap_or(0.0);
        let w_o = oido.map(|s| self.fuente.ancho(s, tam_o)).unwrap_or(0.0);
        let w = w_d.max(w_o) + 40.0;
        let h = if oido.is_some() && dice.is_some() { 74.0 } else { 50.0 };
        let x = (self.ancho as f32 - w) / 2.0;
        let y = self.alto as f32 - h - 64.0;

        rect_redondo(px, x, y, w, h, 12.0, col(FONDO, 0.90));
        rect_redondo(px, x, y + h - 2.0, w, 2.0, 1.0, col(ACENTO, 0.75));

        let mut cy = y + 26.0;
        if let Some(o) = oido {
            self.fuente.dibujar(px, o, x + (w - w_o) / 2.0, cy, tam_o, SUBTEXTO, 0.95);
            cy += 30.0;
        }
        if let Some(d) = dice {
            self.fuente.dibujar(px, d, x + (w - w_d) / 2.0, cy + 6.0, tam_d, TEXTO, 1.0);
        }
    }

    fn pildora(&mut self, px: &mut Pixmap, s: Estado, fase: f32) {
        let tam = 14.0;
        let t = s.texto();
        let w = self.fuente.ancho(t, tam) + 40.0;
        let (x, y, h) = (24.0, 24.0, 28.0);
        rect_redondo(px, x, y, w, h, 14.0, col(SUPERFICIE, 0.92));
        // El punto late solo mientras trabaja; parado significa que espera.
        let a = match s {
            Estado::Esperando => 1.0,
            _ => 0.55 + 0.45 * (fase * std::f32::consts::TAU).sin().abs(),
        };
        circulo(px, x + 16.0, y + h / 2.0, 5.0, col(s.color(), a));
        self.fuente.dibujar(px, t, x + 28.0, y + 19.0, tam, TEXTO, 0.95);
    }

    fn trazo(&mut self, px: &mut Pixmap, t: &Trazo) {
        match *t {
            Trazo::Caja { x, y, w, h } => {
                // 2,0 y no 3,0: "el recuadro naranja me parecio muy grueso",
                // dicho tras la primera sesion con microfono. Es el unico
                // trazo que rodea contenido que hay que poder LEER, asi que un
                // borde gordo tapa justo lo que senala. El halo exterior baja
                // a 0,8 para que los dos sigan leyendose como un solo borde.
                caja(px, self.ax(x), self.ay(y), self.ax(w), self.ay(h), 2.0, col(ACENTO, 0.95));
                caja(px, self.ax(x) - 2.0, self.ay(y) - 2.0, self.ax(w) + 4.0, self.ay(h) + 4.0, 0.8, col(ACENTO, 0.28));
            }
            Trazo::Flecha { x1, y1, x2, y2 } => {
                let (ax1, ay1, ax2, ay2) = (self.ax(x1), self.ay(y1), self.ax(x2), self.ay(y2));
                linea(px, ax1, ay1, ax2, ay2, 3.0, col(ACENTO, 0.95));
                let (dx, dy) = (ax2 - ax1, ay2 - ay1);
                let n = (dx * dx + dy * dy).sqrt().max(1.0);
                let (ux, uy) = (dx / n, dy / n);
                let p = 15.0;
                linea(px, ax2, ay2, ax2 - p * (ux * 0.87 - uy * 0.5), ay2 - p * (uy * 0.87 + ux * 0.5), 3.0, col(ACENTO, 0.95));
                linea(px, ax2, ay2, ax2 - p * (ux * 0.87 + uy * 0.5), ay2 - p * (uy * 0.87 - ux * 0.5), 3.0, col(ACENTO, 0.95));
            }
            Trazo::Linea { ref puntos } => {
                for par in puntos.windows(2) {
                    linea(px, self.ax(par[0].0), self.ay(par[0].1), self.ax(par[1].0), self.ay(par[1].1), 3.0, col(ACENTO, 0.9));
                }
            }
            Trazo::Subrayado { x, y, w } => {
                linea(px, self.ax(x), self.ay(y), self.ax(x + w), self.ay(y), 3.5, col(ACENTO_OK, 0.95));
            }
            Trazo::Paso { x, y, n } => {
                let (cx, cy) = (self.ax(x), self.ay(y));
                circulo(px, cx, cy, 15.0, col(ACENTO, 0.95));
                circulo(px, cx, cy, 15.0, col(ACENTO, 0.95));
                let s = n.to_string();
                let w = self.fuente.ancho(&s, 17.0);
                self.fuente.dibujar(px, &s, cx - w / 2.0, cy + 6.0, 17.0, FONDO, 1.0);
            }
        }
    }
}
