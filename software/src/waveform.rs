// waveform.rs  --  Widget de formas de onda para el analizador lógico
//
// Renderiza señales digitales con egui Painter.
// Soporta zoom, scroll, y dos cursores de medición.

use egui::*;
use crate::protocol::{Capture, fmt_time};
use crate::constants::*;

// ── Color32 derivados de constants.rs ────────────────────────────────────────
// Los arrays [u8;3] de constants.rs se convierten aquí a Color32 de egui.
fn c(rgb: [u8; 3]) -> Color32 { Color32::from_rgb(rgb[0], rgb[1], rgb[2]) }

fn bg_color()     -> Color32 { c(COLOR_BG) }
fn grid_color()   -> Color32 { c(COLOR_GRID) }
fn ruler_color()  -> Color32 { c(COLOR_RULER_BG) }
fn label_color()  -> Color32 { c(COLOR_LABEL) }
fn tick_color()   -> Color32 { c(COLOR_TICK) }
fn cursor_a_col() -> Color32 { c(COLOR_CURSOR_A) }
fn cursor_b_col() -> Color32 { c(COLOR_CURSOR_B) }
fn ch_color_egui(ch: usize) -> Color32 { c(CH_COLORS[ch.min(7)]) }




/// Estado de la vista de formas de onda
#[derive(Clone)]
pub struct WaveformState {
    pub samples_per_pixel: f64,
    pub scroll_sample:     f64,
    pub cursor_a:          Option<f64>,
    pub cursor_b:          Option<f64>,
    pub ch_visible:        [bool; 8],
    pub clock_ch:          Option<usize>,  // canal de reloj de referencia (None = sin reloj)
    pub min_spp:           f64,            // límite de zoom máximo (configurable desde .cfg)
}

impl Default for WaveformState {
    fn default() -> Self {
        Self {
            samples_per_pixel: 256.0,
            scroll_sample:     0.0,
            cursor_a:          None,
            cursor_b:          None,
            ch_visible:        [true; 8],
            clock_ch:          None,
            min_spp:           ZOOM_MIN_SPP,
        }
    }
}

impl WaveformState {
    /// Inicializa el zoom para mostrar toda la captura en el ancho disponible
    pub fn fit_to_width(&mut self, n_samples: usize, width: f32) {
        let w = (width - LABEL_WIDTH).max(1.0);
        self.samples_per_pixel = n_samples as f64 / w as f64;
        self.scroll_sample = 0.0;
    }

    /// Aplica zoom centrado en un pixel x del área de formas de onda
    pub fn zoom_at(&mut self, x: f32, factor: f64, n_samples: usize, width: f32) {
        let sample_at_cursor = self.scroll_sample + x as f64 * self.samples_per_pixel;
        self.samples_per_pixel = (self.samples_per_pixel * factor)
            .clamp(self.min_spp, n_samples as f64 / 4.0);
        self.scroll_sample = sample_at_cursor - x as f64 * self.samples_per_pixel;
        self.clamp(n_samples, width);
    }

    /// Desplaza el scroll en pixels
    pub fn pan(&mut self, dx: f32, n_samples: usize, width: f32) {
        self.scroll_sample -= dx as f64 * self.samples_per_pixel;
        self.clamp(n_samples, width);
    }

    fn clamp(&mut self, n_samples: usize, width: f32) {
        let wave_w = (width - LABEL_WIDTH).max(1.0) as f64;
        let max_scroll = (n_samples as f64 - wave_w * self.samples_per_pixel).max(0.0);
        self.scroll_sample = self.scroll_sample.clamp(0.0, max_scroll);
    }

    /// Convierte pixel x (relativo al área de ondas) a muestra
    pub fn px_to_sample(&self, x: f32) -> f64 {
        self.scroll_sample + x as f64 * self.samples_per_pixel
    }

    /// Convierte muestra a pixel x (relativo al área de ondas)
    pub fn sample_to_px(&self, sample: f64) -> f32 {
        ((sample - self.scroll_sample) / self.samples_per_pixel) as f32
    }
}

/// Dibuja el widget completo de formas de onda.
/// Devuelve true si hubo interacción que requiere repintar.
pub fn show(
    ui:      &mut Ui,
    capture: &Capture,
    state:   &mut WaveformState,
    config:  &crate::config::AnalyzerConfig,
) -> bool {
    let n_ch      = capture.n_channels.min(8);
    let visible   = (0..n_ch).filter(|&c| state.ch_visible[c]).count();
    let total_h   = RULER_HEIGHT + visible as f32 * CH_HEIGHT;
    let avail_w   = ui.available_width();

    let (rect, response) = ui.allocate_exact_size(
        vec2(avail_w, total_h),
        Sense::click_and_drag(),
    );

    let painter   = ui.painter_at(rect);
    let wave_rect = Rect::from_min_size(
        rect.min + vec2(LABEL_WIDTH, RULER_HEIGHT),
        vec2(avail_w - LABEL_WIDTH, total_h - RULER_HEIGHT),
    );
    let wave_w    = wave_rect.width();

    // ── Fondo ─────────────────────────────────────────────────────────────
    painter.rect_filled(rect, 0.0, bg_color());
    painter.rect_filled(
        Rect::from_min_size(rect.min, vec2(avail_w, RULER_HEIGHT)),
        0.0, ruler_color(),
    );

    // ── Interacción: zoom con scroll ───────────────────────────────────────
    let mut changed = false;
    let scroll = ui.input(|i| i.smooth_scroll_delta);
    if response.hovered() && scroll.y != 0.0 {
        // Posición del ratón relativa al área de ondas
        if let Some(mp) = response.hover_pos() {
            let mx = (mp.x - wave_rect.left()).clamp(0.0, wave_w);
            let factor = if scroll.y > 0.0 { ZOOM_IN_FACTOR } else { ZOOM_OUT_FACTOR };
            state.zoom_at(mx, factor, capture.n_samples, avail_w);
            changed = true;
        }
    }

    // ── Interacción: arrastrar para pan ───────────────────────────────────
    if response.dragged_by(PointerButton::Middle)
        || (response.dragged_by(PointerButton::Primary)
            && ui.input(|i| i.modifiers.alt))
    {
        state.pan(response.drag_delta().x, capture.n_samples, avail_w);
        changed = true;
    }

    // ── Interacción: cursores ──────────────────────────────────────────────
    if let Some(mp) = response.interact_pointer_pos() {
        if wave_rect.contains(mp) {
            let mx = mp.x - wave_rect.left();
            let sample = state.px_to_sample(mx);
            if response.clicked_by(PointerButton::Primary) {
                state.cursor_a = Some(sample.clamp(0.0, capture.n_samples as f64 - 1.0));
                changed = true;
            }
            if response.clicked_by(PointerButton::Secondary) {
                state.cursor_b = Some(sample.clamp(0.0, capture.n_samples as f64 - 1.0));
                changed = true;
            }
        }
    }

    // ── Marcas de transición del CH0 (líneas en flancos de señal) ─────────
    // Dibuja líneas verticales muy sutiles en cada transición del canal más
    // rápido visible. Permite contar períodos directamente.
    {
        let ref_ch = (0..n_ch).find(|&c| state.ch_visible[c]).unwrap_or(0);
        let trans_color = Color32::from_rgba_premultiplied(90, 110, 150, 80);
        let mut prev_val: Option<u8> = None;
        for px in 0..wave_w as usize {
            let s0 = (state.scroll_sample + px as f64 * state.samples_per_pixel) as usize;
            let s1 = (state.scroll_sample + (px+1) as f64 * state.samples_per_pixel) as usize;
            let s0 = s0.min(capture.n_samples.saturating_sub(1));
            let s1 = s1.min(capture.n_samples);
            if s0 >= s1 { break; }
            let ones = (s0..s1).filter(|&i| (capture.data[i] >> ref_ch) & 1 == 1).count();
            let val  = if ones * 2 >= (s1 - s0) { 1u8 } else { 0u8 };
            if let Some(pv) = prev_val {
                if pv != val {
                    let x = wave_rect.left() + px as f32;
                    painter.line_segment(
                        [pos2(x, wave_rect.min.y), pos2(x, wave_rect.max.y)],
                        Stroke::new(1.0, trans_color),
                    );
                }
            }
            prev_val = Some(val);
        }
    }

    // ── Regla de tiempo ───────────────────────────────────────────────────
    let ns_per_px     = capture.ns_per_sample() as f64 * state.samples_per_pixel;
    let tick_ns       = nice_interval(ns_per_px, 80.0);
    let tick_px       = (tick_ns / ns_per_px) as f32;
    let offset_ns     = state.scroll_sample * capture.ns_per_sample() as f64;
    let first_tick_ns = (offset_ns / tick_ns).ceil() * tick_ns;
    let first_tick_x  = wave_rect.left() + ((first_tick_ns - offset_ns) / ns_per_px) as f32;

    // Rejilla secundaria (subdivisiones entre ticks principales)
    let sub_tick_ns = tick_ns / 5.0;
    let sub_tick_px = (sub_tick_ns / ns_per_px) as f32;
    if sub_tick_px > 4.0 {
        let first_sub_ns = (offset_ns / sub_tick_ns).ceil() * sub_tick_ns;
        let mut sub_x = wave_rect.left() + ((first_sub_ns - offset_ns) / ns_per_px) as f32;
        while sub_x <= wave_rect.right() {
            // Solo dibujar si no coincide con un tick principal
            let is_main = ((sub_x - first_tick_x).rem_euclid(tick_px)) < 2.0;
            if !is_main {
                painter.line_segment(
                    [pos2(sub_x, wave_rect.min.y), pos2(sub_x, wave_rect.max.y)],
                    Stroke::new(1.0, Color32::from_rgb(35, 42, 58)),
                );
            }
            sub_x += sub_tick_px;
        }
    }

    let mut tick_x = first_tick_x;
    while tick_x <= wave_rect.right() {
        let t_ns = offset_ns + (tick_x - wave_rect.left()) as f64 * ns_per_px;
        // Línea de tick
        painter.line_segment(
            [pos2(tick_x, rect.min.y + 4.0), pos2(tick_x, rect.min.y + RULER_HEIGHT)],
            Stroke::new(1.0, tick_color()),
        );
        // Etiqueta
        painter.text(
            pos2(tick_x + 3.0, rect.min.y + 6.0),
            Align2::LEFT_TOP,
            fmt_time(t_ns as f32),
            FontId::monospace(10.0),
            label_color(),
        );
        // Línea de rejilla vertical — más visible, estilo punteado
        painter.line_segment(
            [pos2(tick_x, wave_rect.min.y), pos2(tick_x, wave_rect.max.y)],
            Stroke::new(1.2, grid_color()),
        );
        tick_x += tick_px;
    }

    // ── Canales ───────────────────────────────────────────────────────────
    let mut ch_y = wave_rect.min.y;
    for ch in 0..n_ch {
        if !state.ch_visible[ch] { continue; }

        let ch_rect = Rect::from_min_size(
            pos2(rect.min.x, ch_y),
            vec2(avail_w, CH_HEIGHT),
        );
        let w_rect = Rect::from_min_size(
            pos2(wave_rect.min.x, ch_y),
            vec2(wave_w, CH_HEIGHT),
        );

        // Fondo alternado suave
        if ch % 2 == 1 {
            painter.rect_filled(ch_rect, 0.0, Color32::from_rgb(22, 24, 32));
        }

        // Separador horizontal
        painter.line_segment(
            [pos2(rect.min.x, ch_y), pos2(rect.max.x, ch_y)],
            Stroke::new(1.0, grid_color()),
        );

        // Etiqueta del canal — usa nombre del fichero de config
        let color    = ch_color_egui(ch);
        let is_clock = state.clock_ch == Some(ch);
        let ch_name  = config.channel_name(ch);
        let lbl_text = if is_clock {
            format!("⏲ {}", ch_name)
        } else {
            ch_name.to_string()
        };
        let lbl_col  = if is_clock { Color32::from_rgb(255, 220, 50) } else { color };
        painter.text(
            pos2(rect.min.x + 4.0, ch_y + CH_HEIGHT / 2.0 - 7.0),
            Align2::LEFT_CENTER,
            lbl_text,
            FontId::monospace(12.0),
            lbl_col,
        );

        // Forma de onda
        draw_channel(
            &painter,
            &capture.data,
            ch,
            w_rect,
            state.scroll_sample,
            state.samples_per_pixel,
            color,
        );

        // Puntos de muestra: marca cada muestra capturada en su posición.
        // Solo se dibujan cuando el zoom permite verlos sin saturar.
        // Adaptativo según samples_per_pixel.
        draw_sample_dots(
            &painter,
            &capture.data,
            ch,
            w_rect,
            state.scroll_sample,
            state.samples_per_pixel,
            color,
            capture.n_samples,
        );

        ch_y += CH_HEIGHT;
    }

    // Borde derecho e inferior
    painter.line_segment(
        [pos2(wave_rect.left(), wave_rect.top()), pos2(wave_rect.left(), wave_rect.bottom())],
        Stroke::new(1.0, grid_color()),
    );

    // ── Cursores ──────────────────────────────────────────────────────────
    draw_cursor(&painter, state.cursor_a, cursor_a_col(), "A", wave_rect, state);
    draw_cursor(&painter, state.cursor_b, cursor_b_col(), "B", wave_rect, state);

    // ── Medición Δt entre cursores ────────────────────────────────────────
    if let (Some(a), Some(b)) = (state.cursor_a, state.cursor_b) {
        let dt_ns = (b - a).abs() * capture.ns_per_sample() as f64;
        let msg = format!("Δt = {}  |  A={} B={}",
            fmt_time(dt_ns as f32),
            fmt_time((a * capture.ns_per_sample() as f64) as f32),
            fmt_time((b * capture.ns_per_sample() as f64) as f32),
        );
        painter.text(
            pos2(wave_rect.left() + 6.0, rect.max.y - 16.0),
            Align2::LEFT_BOTTOM,
            msg,
            FontId::monospace(11.0),
            Color32::WHITE,
        );
    }

    changed
}

/// Dibuja un canal como forma de onda digital (líneas rectas con transiciones)
fn draw_channel(
    painter:    &Painter,
    data:       &[u8],
    ch:         usize,
    rect:       Rect,
    scroll:     f64,
    spp:        f64,       // samples per pixel
    color:      Color32,
) {
    let n      = data.len();
    let width  = rect.width() as usize;
    let y_high = rect.min.y + CH_PADDING;
    let y_low  = rect.max.y - CH_PADDING;

    if width == 0 || n == 0 { return; }

    // Calcular valor por pixel (mayoria de muestras en ese pixel)
    let val_at = |px: usize| -> u8 {
        let s0 = (scroll + px as f64 * spp) as usize;
        let s1 = (scroll + (px + 1) as f64 * spp) as usize;
        let s0 = s0.min(n - 1);
        let s1 = s1.min(n);
        if s0 >= s1 { return (data[s0] >> ch) & 1; }
        let ones = (s0..s1).filter(|&i| (data[i] >> ch) & 1 == 1).count();
        if ones * 2 >= (s1 - s0) { 1 } else { 0 }
    };

    // Construir polilínea con transiciones en ángulo recto
    let mut pts: Vec<Pos2> = Vec::with_capacity(width * 2);
    let first_val = val_at(0);
    let mut prev_y = if first_val == 1 { y_high } else { y_low };
    pts.push(pos2(rect.min.x, prev_y));

    for px in 1..width {
        let v   = val_at(px);
        let y   = if v == 1 { y_high } else { y_low };
        let x   = rect.min.x + px as f32;

        if (y - prev_y).abs() > 0.5 {
            // Transición: esquina en ángulo recto
            pts.push(pos2(x, prev_y));
            pts.push(pos2(x, y));
        }
        prev_y = y;
    }
    pts.push(pos2(rect.max.x, prev_y));

    if pts.len() >= 2 {
        painter.add(Shape::line(pts, Stroke::new(SIGNAL_STROKE_WIDTH, color)));
    }
}

/// Dibuja un cursor vertical con etiqueta
fn draw_cursor(
    painter: &Painter,
    cursor:  Option<f64>,
    color:   Color32,
    label:   &str,
    rect:    Rect,
    state:   &WaveformState,
) {
    let Some(sample) = cursor else { return };
    let x = rect.left() + state.sample_to_px(sample);
    if x < rect.left() || x > rect.right() { return; }

    painter.line_segment(
        [pos2(x, rect.top()), pos2(x, rect.bottom())],
        Stroke::new(1.5, color),
    );
    painter.text(
        pos2(x + 3.0, rect.top() + 3.0),
        Align2::LEFT_TOP,
        label,
        FontId::monospace(10.0),
        color,
    );
}

/// Calcula un intervalo de tiempo "bonito" dado el mínimo en ns
fn nice_interval(ns_per_px: f64, min_px: f64) -> f64 {
    let min_ns = ns_per_px * min_px;
    let mag    = 10f64.powf(min_ns.log10().floor());
    for &f in &[1.0f64, 2.0, 5.0, 10.0] {
        if mag * f >= min_ns { return mag * f; }
    }
    mag * 10.0
}

/// Dibuja un punto pequeño en cada muestra capturada, sobre la onda.
///
/// El tamaño del punto se adapta al zoom:
///   - spp <= SAMPLE_DOT_FULL_SPP : tamaño completo (zoom muy alto)
///   - spp en (FULL_SPP, MAX_SPP) : tamaño decreciente
///   - spp >= SAMPLE_DOT_MAX_SPP  : no se dibuja (sería ruido visual)
fn draw_sample_dots(
    painter: &Painter,
    data:    &[u8],
    ch:      usize,
    rect:    Rect,
    scroll:  f64,
    spp:     f64,
    color:   Color32,
    n:       usize,
) {
    // No dibujar puntos si el zoom es demasiado bajo
    if spp >= SAMPLE_DOT_MAX_SPP { return; }

    // Tamaño adaptativo del radio del punto
    let radius = if spp <= SAMPLE_DOT_FULL_SPP {
        SAMPLE_DOT_RADIUS
    } else {
        // Interpolación lineal: full_spp → radio máximo, max_spp → radio mínimo
        let t = ((spp - SAMPLE_DOT_FULL_SPP) /
                 (SAMPLE_DOT_MAX_SPP - SAMPLE_DOT_FULL_SPP)) as f32;
        SAMPLE_DOT_RADIUS * (1.0 - t * 0.7).max(0.3)
    };

    let y_high = rect.min.y + CH_PADDING;
    let y_low  = rect.max.y - CH_PADDING;

    // Color con transparencia
    let dot_color = Color32::from_rgba_premultiplied(
        color.r(), color.g(), color.b(), SAMPLE_DOT_ALPHA,
    );

    // Solo dibuja muestras dentro del área visible
    let s_start = scroll as usize;
    let s_end   = ((scroll + rect.width() as f64 * spp) as usize + 1).min(n);

    for i in s_start..s_end {
        let px = rect.left() + ((i as f64 - scroll) / spp) as f32;
        if px < rect.left() || px > rect.right() { continue; }

        let val = (data[i] >> ch) & 1;
        let py  = if val == 1 { y_high } else { y_low };

        painter.circle_filled(pos2(px, py), radius, dot_color);
    }
}

/// Devuelve el color de un canal (usado también en app.rs)
pub fn ch_color(ch: usize) -> Color32 {
    c(CH_COLORS[ch.min(7)])
}
