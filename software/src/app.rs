// app.rs  --  Estado y lógica de la aplicación egui

use egui::*;
use std::sync::mpsc;
use crate::protocol::{ArmCommand, Capture, TriggerType, fmt_time, fmt_freq};
use crate::serial::FpgaSerial;
use crate::waveform::{WaveformState, show as show_waveform};
use crate::constants::*;

// Convierte [u8;3] de constants.rs a Color32 de egui
fn c(rgb: [u8;3]) -> Color32 { Color32::from_rgb(rgb[0], rgb[1], rgb[2]) }
fn dark_bg()    -> Color32 { c(COLOR_BG) }
fn panel_bg()   -> Color32 { c(COLOR_PANEL_BG) }
fn accent()     -> Color32 { c(COLOR_ACCENT) }
fn text_dim()   -> Color32 { c(COLOR_DIM) }
fn cursor_a()   -> Color32 { c(COLOR_CURSOR_A) }
fn cursor_b()   -> Color32 { c(COLOR_CURSOR_B) }

#[derive(PartialEq, Clone, Copy)]
enum TrigMode { Manual, Rising, Falling }

pub struct LogicAnalyzerApp {
    // Config serie
    port:       String,
    test_mode:  bool,
    trig_mode:  TrigMode,
    trig_ch:    usize,

    // Configuración de canales
    analyzer_config: crate::config::AnalyzerConfig,
    config_loaded:   bool,           // false hasta que se cargue un .cfg

    // Estado captura
    status:     String,
    capturing:  bool,
    capture:    Option<Capture>,
    cap_rx:     Option<mpsc::Receiver<Result<Capture, String>>>,

    // Vista de ondas
    wave_state: WaveformState,

    // Consola (deshabilitada por defecto, útil para debug)
    console_open:    bool,
    console_entries: Vec<String>,

    // Primera vez (para fit automático)
    first_capture: bool,
}

impl Default for LogicAnalyzerApp {
    fn default() -> Self {
        Self {
            port:            String::new(),
            test_mode:       false,
            trig_mode:       TrigMode::Manual,
            trig_ch:         0,
            analyzer_config: crate::config::AnalyzerConfig::default(),
            config_loaded:   false,
            status:          "Sin configuración — pulsa 📂 Config".to_string(),
            capturing:       false,
            capture:         None,
            cap_rx:          None,
            wave_state:      WaveformState::default(),
            console_open:    false,
            console_entries: Vec::new(),
            first_capture:   true,
        }
    }
}

impl LogicAnalyzerApp {
    pub fn new(cc: &eframe::CreationContext<'_>) -> Self {
        // Tema oscuro tipo osciloscopio
        let mut visuals = Visuals::dark();
        visuals.panel_fill            = dark_bg();
        visuals.window_fill           = panel_bg();
        visuals.override_text_color   = Some(Color32::from_rgb(210, 220, 235));
        visuals.widgets.noninteractive.bg_fill = panel_bg();
        visuals.widgets.inactive.bg_fill       = Color32::from_rgb(30, 35, 48);
        visuals.widgets.hovered.bg_fill        = Color32::from_rgb(40, 50, 68);
        visuals.widgets.active.bg_fill         = Color32::from_rgb(0, 160, 100);
        visuals.selection.bg_fill              = Color32::from_rgb(0, 120, 80);
        cc.egui_ctx.set_visuals(visuals);

        // Arrancar en estado vacío - sin config cargada
        Self::default()
    }

    fn arm(&mut self) {
        if self.capturing { return; }
        if !self.config_loaded {
            self.status = "⚠ Carga un fichero .cfg con el botón 📂 Config".to_string();
            self.log("⚠ No se puede capturar sin un fichero .cfg cargado".to_string());
            return;
        }

        let cmd   = ArmCommand {
            test_mode: self.test_mode,
            trig_type: match self.trig_mode {
                TrigMode::Manual  => TriggerType::Manual,
                TrigMode::Rising  => TriggerType::Rising,
                TrigMode::Falling => TriggerType::Falling,
            },
            trig_ch:   self.trig_ch as u8,
            trig_mask: 0,
            trig_val:  0,
        };
        let bytes     = cmd.to_bytes();
        let port      = self.port.clone();
        let baud      = self.analyzer_config.session.baud;
        let mux_cmd   = self.analyzer_config.mux_command();

        let (tx, rx) = mpsc::channel();
        self.cap_rx    = Some(rx);
        self.capturing = true;
        self.status    = "Capturando...".to_string();
        self.log(format!("ARM → {} @{}  MUX: ext_mask=0x{:02X}", port, baud, mux_cmd[1]));

        std::thread::spawn(move || {
            match FpgaSerial::open_with_baud(&port, baud) {
                Ok(mut f) => {
                    if let Err(e) = f.send_mux_config(&mux_cmd) {
                        let _ = tx.send(Err(e));
                        return;
                    }
                    match f.send_and_receive(&bytes) {
                        Ok(cap)  => { let _ = tx.send(Ok(cap)); }
                        Err(e)   => { let _ = tx.send(Err(e)); }
                    }
                }
                Err(e) => { let _ = tx.send(Err(e)); }
            }
        });
    }

    fn log(&mut self, msg: String) {
        self.console_entries.push(msg);
        if self.console_entries.len() > 200 {
            self.console_entries.remove(0);
        }
    }

    /// Guarda un fichero .log con análisis completo de la captura actual.
    /// Formato pensado para ser enviado por chat para diagnóstico.
    fn save_log(&self, path: &std::path::Path) -> Result<(), String> {
        use std::io::Write;
        use std::fs::File;

        let cap = self.capture.as_ref()
            .ok_or_else(|| "No hay captura para guardar".to_string())?;

        let mut f = File::create(path)
            .map_err(|e| format!("No se puede crear {}: {}", path.display(), e))?;

        let cfg = &self.analyzer_config;

        // Cabecera
        writeln!(f, "# ═══════════════════════════════════════════════════════════════").map_err(|e| e.to_string())?;
        writeln!(f, "# LOGIC ANALYZER -- Log de captura").map_err(|e| e.to_string())?;
        writeln!(f, "# ═══════════════════════════════════════════════════════════════").map_err(|e| e.to_string())?;
        writeln!(f, "# Config:        {}", cfg.summary()).map_err(|e| e.to_string())?;
        writeln!(f, "# Puerto:        {} @ {} baud", cfg.session.puerto, cfg.session.baud).map_err(|e| e.to_string())?;
        writeln!(f, "# Trigger:       {:?} en CH{:02}",
                 cfg.session.trigger, cfg.session.trigger_ch).map_err(|e| e.to_string())?;
        writeln!(f, "# Sample freq:   {} Hz", cfg.session.sample_freq).map_err(|e| e.to_string())?;
        writeln!(f, "# Muestras:      {}", cap.n_samples).map_err(|e| e.to_string())?;
        writeln!(f, "# Canales:       {}", cap.n_channels).map_err(|e| e.to_string())?;
        writeln!(f, "# Trig pos:      {}", cap.trig_pos).map_err(|e| e.to_string())?;
        writeln!(f, "# CRC OK:        {}", cap.crc_ok).map_err(|e| e.to_string())?;
        writeln!(f, "# ns/muestra:    {:.2}", cap.ns_per_sample()).map_err(|e| e.to_string())?;
        writeln!(f, "# Ventana total: {:.2} us",
                 cap.n_samples as f32 * cap.ns_per_sample() / 1000.0).map_err(|e| e.to_string())?;
        writeln!(f).map_err(|e| e.to_string())?;

        // Mapa de canales
        writeln!(f, "# ── MAPA DE CANALES ────────────────────────────────────────────").map_err(|e| e.to_string())?;
        for ch in 0..cap.n_channels.min(8) {
            let chcfg = &cfg.channels[ch];
            let clk_marker = if chcfg.is_clock { " [CLOCK]" } else { "" };
            writeln!(f, "# CH{:02}  nombre={:10}  fuente={}{}",
                     ch, chcfg.name, chcfg.source.description(), clk_marker)
                .map_err(|e| e.to_string())?;
        }
        writeln!(f).map_err(|e| e.to_string())?;

        // Estadísticas por canal
        writeln!(f, "# ── ESTADÍSTICAS POR CANAL ──────────────────────────────────────").map_err(|e| e.to_string())?;
        writeln!(f, "# CH    Nombre       %HIGH    Transiciones    Frec_aprox(Hz)").map_err(|e| e.to_string())?;
        for ch in 0..cap.n_channels.min(8) {
            let chcfg = &cfg.channels[ch];
            if !chcfg.active { continue; }

            let mut high_count = 0usize;
            let mut transitions = 0usize;
            let mut prev_bit = 2u8;
            for i in 0..cap.n_samples {
                let bit = (cap.data[i] >> ch) & 1;
                if bit == 1 { high_count += 1; }
                if prev_bit != 2 && prev_bit != bit { transitions += 1; }
                prev_bit = bit;
            }
            let pct = high_count as f64 * 100.0 / cap.n_samples as f64;
            // Frecuencia: cada flanco completo (subida+bajada) = 1 ciclo
            let cycles = transitions / 2;
            let total_time_s = cap.n_samples as f64 * cap.ns_per_sample() as f64 / 1e9;
            let freq = if total_time_s > 0.0 { cycles as f64 / total_time_s } else { 0.0 };

            writeln!(f, "# CH{:02}  {:10}  {:6.2}%  {:8}      {:>12.0}",
                     ch, chcfg.name, pct, transitions, freq)
                .map_err(|e| e.to_string())?;
        }
        writeln!(f).map_err(|e| e.to_string())?;

        // Eventos: muestras donde algún canal cambia
        writeln!(f, "# ── EVENTOS (cambios de estado) ─────────────────────────────────").map_err(|e| e.to_string())?;
        writeln!(f, "# Formato: muestra  tiempo_us  estado_binario(CH7..CH0)").map_err(|e| e.to_string())?;
        let mut prev = 0xFFu8;
        let mut events = 0usize;
        const MAX_EVENTS: usize = 500;
        for i in 0..cap.n_samples {
            if cap.data[i] != prev {
                if events < MAX_EVENTS {
                    let t_us = i as f32 * cap.ns_per_sample() / 1000.0;
                    writeln!(f, "{:6}  {:8.3}us  {:08b}", i, t_us, cap.data[i])
                        .map_err(|e| e.to_string())?;
                }
                events += 1;
                prev = cap.data[i];
            }
        }
        if events > MAX_EVENTS {
            writeln!(f, "# ... ({} eventos más omitidos, total {})",
                     events - MAX_EVENTS, events).map_err(|e| e.to_string())?;
        }
        writeln!(f).map_err(|e| e.to_string())?;

        // Volcado compacto: primeros y últimos bytes
        writeln!(f, "# ── VOLCADO RAW: primeros 64 bytes ─────────────────────────────").map_err(|e| e.to_string())?;
        for chunk_start in (0..64.min(cap.n_samples)).step_by(16) {
            write!(f, "{:04}: ", chunk_start).map_err(|e| e.to_string())?;
            for j in 0..16 {
                if chunk_start + j < cap.n_samples {
                    write!(f, "{:02X} ", cap.data[chunk_start + j]).map_err(|e| e.to_string())?;
                }
            }
            writeln!(f).map_err(|e| e.to_string())?;
        }
        writeln!(f).map_err(|e| e.to_string())?;

        if cap.n_samples > 128 {
            writeln!(f, "# ── VOLCADO RAW: últimos 64 bytes ─────────────────────────").map_err(|e| e.to_string())?;
            let start = cap.n_samples - 64;
            for chunk_start in (start..cap.n_samples).step_by(16) {
                write!(f, "{:04}: ", chunk_start).map_err(|e| e.to_string())?;
                for j in 0..16 {
                    if chunk_start + j < cap.n_samples {
                        write!(f, "{:02X} ", cap.data[chunk_start + j]).map_err(|e| e.to_string())?;
                    }
                }
                writeln!(f).map_err(|e| e.to_string())?;
            }
        }

        Ok(())
    }

    /// Guarda un fichero .csv compatible con PulseView.
    ///
    /// Formato:
    ///   - Primera línea: cabecera con nombres de canales separados por coma
    ///   - Una línea por muestra, valores 0/1 separados por coma
    ///
    /// Solo se exportan los canales activos del .cfg.
    /// PulseView abre el fichero con: File → Import → CSV
    /// Sample rate a configurar manualmente: cfg.session.sample_freq
    fn save_csv(&self, path: &std::path::Path) -> Result<(), String> {
        use std::io::{Write, BufWriter};
        use std::fs::File;

        let cap = self.capture.as_ref()
            .ok_or_else(|| "No hay captura para guardar".to_string())?;

        let f = File::create(path)
            .map_err(|e| format!("No se puede crear {}: {}", path.display(), e))?;
        let mut w = BufWriter::new(f);

        let cfg = &self.analyzer_config;

        // Cabecera: solo canales activos, con sus nombres del .cfg
        let mut active_channels: Vec<usize> = Vec::new();
        let mut header_parts: Vec<String> = Vec::new();
        for ch in 0..cap.n_channels.min(8) {
            if cfg.channels[ch].active {
                active_channels.push(ch);
                let name = if !cfg.channels[ch].name.is_empty() {
                    cfg.channels[ch].name.clone()
                } else {
                    format!("CH{}", ch)
                };
                header_parts.push(name);
            }
        }

        if active_channels.is_empty() {
            return Err("No hay canales activos en el .cfg".to_string());
        }

        // Escribir cabecera
        writeln!(w, "{}", header_parts.join(","))
            .map_err(|e| e.to_string())?;

        // Escribir una línea por muestra
        for i in 0..cap.n_samples {
            let mut row = String::with_capacity(active_channels.len() * 2);
            for (j, &ch) in active_channels.iter().enumerate() {
                if j > 0 { row.push(','); }
                let bit = (cap.data[i] >> ch) & 1;
                row.push(if bit == 1 { '1' } else { '0' });
            }
            writeln!(w, "{}", row).map_err(|e| e.to_string())?;
        }

        w.flush().map_err(|e| e.to_string())?;
        Ok(())
    }

    fn poll_capture(&mut self, ctx: &egui::Context) {
        if let Some(rx) = &self.cap_rx {
            if let Ok(result) = rx.try_recv() {
                self.capturing = false;
                self.cap_rx    = None;
                match result {
                    Ok(cap) => {
                        self.status = format!(
                            "OK  {} muestras  CRC:{}",
                            cap.n_samples,
                            if cap.crc_ok { "✓" } else { "✗ ERROR" }
                        );
                        self.log(format!("Captura OK: {} muestras", cap.n_samples));

                        self.capture = Some(cap);
                        self.first_capture = true;
                    }
                    Err(e) => {
                        self.status = format!("Error: {}", e);
                        self.log(format!("Error: {}", e));
                    }
                }
                ctx.request_repaint();
            } else if self.capturing {
                // Seguir repintando mientras captura
                ctx.request_repaint_after(std::time::Duration::from_millis(100));
            }
        }
    }

    /// Panel superior de controles
    fn show_toolbar(&mut self, ui: &mut Ui) {
        ui.horizontal(|ui| {
            ui.spacing_mut().item_spacing.x = 12.0;

            // ── Cargar fichero de configuración ───────────────────────────
            let cfg_label = RichText::new("📂 Config").size(12.0);
            if ui.button(cfg_label).clicked() {
                if let Some(path) = rfd::FileDialog::new()
                    .add_filter("Config", &["cfg", "txt"])
                    .set_title("Abrir configuración de canales")
                    .pick_file()
                {
                    let cfg = crate::config::AnalyzerConfig::load(&path);

                    // Aplicar parámetros de sesión globales
                    self.port      = cfg.session.puerto.clone();
                    self.test_mode = cfg.session.test_mode;
                    self.trig_mode = match cfg.session.trigger {
                        crate::config::TriggerMode::Manual  => TrigMode::Manual,
                        crate::config::TriggerMode::Rising  => TrigMode::Rising,
                        crate::config::TriggerMode::Falling => TrigMode::Falling,
                    };
                    self.trig_ch   = cfg.session.trigger_ch;

                    // Aplicar límite de zoom desde el .cfg
                    self.wave_state.min_spp = cfg.session.zoom_min;

                    // Aplicar reloj automáticamente si está definido
                    if let Some(clk) = cfg.clock_channel() {
                        self.wave_state.clock_ch = Some(clk);
                    } else {
                        self.wave_state.clock_ch = None;
                    }
                    // Aplicar visibilidad de canales
                    for i in 0..8 {
                        self.wave_state.ch_visible[i] = cfg.channels[i].active;
                    }
                    // Mostrar errores si los hay
                    for e in &cfg.errors {
                        self.log(format!("⚠ {}", e));
                    }
                    self.log(format!("Config cargada: {}  puerto={} baud={}",
                        cfg.summary(), cfg.session.puerto, cfg.session.baud));
                    self.status = format!("Config: {}", cfg.summary());
                    self.analyzer_config = cfg;
                    self.config_loaded   = true;
                }
            }

            // Nombre del fichero activo
            ui.label(
                RichText::new(self.analyzer_config.summary())
                    .size(11.0)
                    .color(text_dim())
                    .italics(),
            );

            // ── Guardar log de la captura actual ──────────────────────────
            if self.capture.is_some() {
                let log_label = RichText::new("💾 Log").size(12.0);
                if ui.button(log_label).clicked() {
                    if let Some(path) = rfd::FileDialog::new()
                        .add_filter("Log", &["log", "txt"])
                        .set_title("Guardar log de captura")
                        .set_file_name("captura.log")
                        .save_file()
                    {
                        match self.save_log(&path) {
                            Ok(_)  => {
                                self.log(format!("✓ Log guardado: {}", path.display()));
                                self.status = format!("Log: {}", path.display());
                            }
                            Err(e) => {
                                self.log(format!("⚠ Error guardando log: {}", e));
                            }
                        }
                    }
                }

                // ── Guardar CSV compatible con PulseView ──────────────────
                let csv_label = RichText::new("📊 CSV").size(12.0);
                if ui.button(csv_label).clicked() {
                    if let Some(path) = rfd::FileDialog::new()
                        .add_filter("CSV PulseView", &["csv"])
                        .set_title("Guardar CSV (PulseView)")
                        .set_file_name("captura.csv")
                        .save_file()
                    {
                        match self.save_csv(&path) {
                            Ok(_)  => {
                                self.log(format!("✓ CSV guardado: {}", path.display()));
                                self.status = format!("CSV: {}", path.display());
                            }
                            Err(e) => {
                                self.log(format!("⚠ Error guardando CSV: {}", e));
                            }
                        }
                    }
                }
            }

            ui.separator();

            // ── Puerto serie ──────────────────────────────────────────────
            ui.label(RichText::new("Puerto:").color(text_dim()).size(12.0));
            ui.add(TextEdit::singleline(&mut self.port)
                .desired_width(140.0)
                .font(FontId::monospace(12.0)));

            ui.separator();

            // ── Modo ──────────────────────────────────────────────────────
            ui.label(RichText::new("Modo:").color(text_dim()).size(12.0));
            ui.selectable_value(&mut self.test_mode, true,  "Test interno");
            ui.selectable_value(&mut self.test_mode, false, "Pines reales");

            ui.separator();

            // ── Trigger ───────────────────────────────────────────────────
            ui.label(RichText::new("Trigger:").color(text_dim()).size(12.0));
            ui.selectable_value(&mut self.trig_mode, TrigMode::Manual,  "Manual");
            ui.selectable_value(&mut self.trig_mode, TrigMode::Rising,  "↑ Subida");
            ui.selectable_value(&mut self.trig_mode, TrigMode::Falling, "↓ Bajada");

            if self.trig_mode != TrigMode::Manual {
                ui.label(RichText::new("CH:").color(text_dim()).size(12.0));
                ComboBox::from_id_salt("trig_ch")
                    .selected_text(format!("CH{}", self.trig_ch))
                    .width(60.0)
                    .show_ui(ui, |ui| {
                        for c in 0..8usize {
                            ui.selectable_value(&mut self.trig_ch, c, format!("CH{}", c));
                        }
                    });
            }

            ui.separator();

            // ── Botón ARM ─────────────────────────────────────────────────
            let arm_btn = if self.capturing {
                Button::new(RichText::new("⏳ Capturando...").size(13.0))
                    .fill(Color32::from_rgb(60, 50, 20))
            } else {
                Button::new(RichText::new("▶  ARM").size(13.0))
                    .fill(Color32::from_rgb(0, 90, 60))
            };

            if ui.add_enabled(!self.capturing, arm_btn).clicked() {
                self.arm();
            }

            ui.separator();

            // ── Debug console toggle ───────────────────────────────────────
            // (deshabilitada por defecto, útil para debug)
            ui.toggle_value(
                &mut self.console_open,
                RichText::new("🖥 Consola").size(11.0).color(text_dim()),
            );

            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                ui.label(
                    RichText::new(&self.status)
                        .size(11.0)
                        .color(if self.status.contains("Error") {
                            Color32::from_rgb(255, 100, 80)
                        } else {
                            accent()
                        }),
                );
            });
        });
    }

    /// Panel de ayuda rápida (zoom, cursores)
    fn show_help_bar(&self, ui: &mut Ui) {
        ui.horizontal(|ui| {
            ui.spacing_mut().item_spacing.x = 12.0;

            // Instrucciones
            ui.label(RichText::new("🖱 Scroll=zoom").size(10.5).color(text_dim()));
            ui.label(RichText::new("Alt+Drag=pan").size(10.5).color(text_dim()));
            ui.separator();

            // Estado cursores — siempre visible
            let a_txt = match self.wave_state.cursor_a {
                Some(s) => {
                    if let Some(cap) = &self.capture {
                        fmt_time(s as f32 * cap.ns_per_sample())
                    } else { "–".to_string() }
                }
                None => "–".to_string(),
            };
            let b_txt = match self.wave_state.cursor_b {
                Some(s) => {
                    if let Some(cap) = &self.capture {
                        fmt_time(s as f32 * cap.ns_per_sample())
                    } else { "–".to_string() }
                }
                None => "–".to_string(),
            };
            let a_col = if self.wave_state.cursor_a.is_some() {
                cursor_a() } else { text_dim() };
            let b_col = if self.wave_state.cursor_b.is_some() {
                cursor_b() } else { text_dim() };

            ui.label(RichText::new("A=").size(11.0).color(text_dim()));
            ui.label(RichText::new(&a_txt).size(11.0).color(a_col).strong());
            ui.label(RichText::new("B=").size(11.0).color(text_dim()));
            ui.label(RichText::new(&b_txt).size(11.0).color(b_col).strong());

            // Δt entre cursores
            if let (Some(a), Some(b), Some(cap)) = (
                self.wave_state.cursor_a,
                self.wave_state.cursor_b,
                &self.capture,
            ) {
                let dt = (b - a).abs() * cap.ns_per_sample() as f64;
                ui.separator();
                ui.label(RichText::new("Δt =").size(11.0).color(text_dim()));
                ui.label(
                    RichText::new(fmt_time(dt as f32))
                        .size(12.0)
                        .color(Color32::WHITE)
                        .strong(),
                );
                // Frecuencia correspondiente al período Δt
                if dt > 0.0 {
                    let freq = 1e9 / dt;
                    ui.label(
                        RichText::new(format!("= {}", fmt_freq(freq as f32)))
                            .size(11.0)
                            .color(text_dim()),
                    );
                }
            } else {
                ui.separator();
                ui.label(
                    RichText::new("Click izq=cursor A  |  Click der=cursor B")
                        .size(10.5)
                        .color(text_dim()),
                );
            }

            // Zoom info a la derecha
            if let Some(cap) = &self.capture {
                ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                    let ns_pp = cap.ns_per_sample() as f64 * self.wave_state.samples_per_pixel;
                    ui.label(RichText::new(
                        format!("{}/px", fmt_time(ns_pp as f32))
                    ).size(10.5).color(text_dim()));
                    ui.label(RichText::new("Zoom:").size(10.5).color(text_dim()));
                });
            }
        });
    }

    /// Panel de visibilidad de canales
    fn show_channel_controls(&mut self, ui: &mut Ui) {
        ui.horizontal(|ui| {
            ui.label(RichText::new("Canales:").color(text_dim()).size(11.0));
            for ch in 0..8 {
                let is_clock = self.wave_state.clock_ch == Some(ch);
                let ch_name = self.analyzer_config.channel_name(ch).to_string();
                let label = RichText::new(&ch_name)
                    .size(11.0)
                    .color(if is_clock {
                        Color32::from_rgb(255, 220, 50)
                    } else if self.wave_state.ch_visible[ch] {
                        crate::waveform::ch_color(ch)
                    } else {
                        text_dim()
                    });
                ui.toggle_value(&mut self.wave_state.ch_visible[ch], label);
            }

            ui.separator();

            // ── Selector canal reloj ───────────────────────────────────────
            ui.label(RichText::new("🕐 Reloj:").color(text_dim()).size(11.0));
            let clk_label = match self.wave_state.clock_ch {
                None    => "Ninguno".to_string(),
                Some(c) => format!("CH{}", c),
            };
            ComboBox::from_id_salt("clock_ch")
                .selected_text(clk_label)
                .width(80.0)
                .show_ui(ui, |ui| {
                    ui.selectable_value(
                        &mut self.wave_state.clock_ch,
                        None,
                        "Ninguno",
                    );
                    for c in 0..8usize {
                        ui.selectable_value(
                            &mut self.wave_state.clock_ch,
                            Some(c),
                            format!("CH{}", c),
                        );
                    }
                });

            // Mostrar frecuencia del reloj si está seleccionado
            if let (Some(clk), Some(cap)) = (self.wave_state.clock_ch, &self.capture) {
                let mut edges = 0usize;
                let mut prev  = (cap.data[0] >> clk) & 1;
                for &s in &cap.data[1..] {
                    let bit = (s >> clk) & 1;
                    if bit != prev { edges += 1; }
                    prev = bit;
                }
                if edges >= 2 {
                    let freq = (1e9 / cap.ns_per_sample()) /
                               (cap.data.len() as f32 / (edges as f32 / 2.0));
                    ui.label(
                        RichText::new(format!("= {}", crate::protocol::fmt_freq(freq)))
                            .size(11.0)
                            .color(Color32::from_rgb(255, 220, 50)),
                    );
                }
            }

            ui.separator();

            if ui.small_button("✕ Cursores").clicked() {
                self.wave_state.cursor_a = None;
                self.wave_state.cursor_b = None;
            }
            if ui.small_button("⊡ Fit").clicked() {
                if let Some(cap) = &self.capture {
                    self.wave_state.fit_to_width(cap.n_samples, ui.available_width() + 55.0);
                }
            }
        });
    }

    /// Consola de debug (oculta por defecto)
    fn show_console(&mut self, ui: &mut Ui) {
        if !self.console_open { return; }
        ui.separator();
        ui.label(RichText::new("Consola debug").size(11.0).color(text_dim()));
        ScrollArea::vertical()
            .max_height(120.0)
            .stick_to_bottom(true)
            .show(ui, |ui| {
                for line in &self.console_entries {
                    ui.label(RichText::new(line).monospace().size(10.0).color(text_dim()));
                }
            });
    }

    /// Estadísticas de canales
    fn show_stats(&self, ui: &mut Ui) {
        let Some(cap) = &self.capture else { return };

        ui.separator();
        ui.horizontal(|ui| {
            for ch in 0..cap.n_channels.min(8) {
                if !self.wave_state.ch_visible[ch] { continue; }
                let mut highs = 0usize;
                let mut edges = 0usize;
                let mut prev  = (cap.data[0] >> ch) & 1;
                for &s in &cap.data[1..] {
                    let bit = (s >> ch) & 1;
                    if bit == 1 { highs += 1; }
                    if bit != prev { edges += 1; }
                    prev = bit;
                }
                let pct  = 100.0 * highs as f32 / cap.data.len() as f32;
                let freq = if edges >= 2 {
                    let hz = (1e9 / cap.ns_per_sample()) /
                             (cap.data.len() as f32 / (edges as f32 / 2.0));
                    crate::protocol::fmt_freq(hz)
                } else { "DC".to_string() };

                ui.vertical(|ui| {
                    let sname = self.analyzer_config.channel_name(ch).to_string();
                    ui.label(RichText::new(&sname)
                        .size(10.0).color(crate::waveform::ch_color(ch)));
                    ui.label(RichText::new(format!("{:.0}%", pct)).size(10.0));
                    ui.label(RichText::new(freq).size(10.0).color(text_dim()));
                });
                ui.separator();
            }
        });
    }
}

impl eframe::App for LogicAnalyzerApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.poll_capture(ctx);

        // Panel superior fijo
        TopBottomPanel::top("toolbar")
            .frame(Frame::none().fill(panel_bg()).inner_margin(8.0))
            .show(ctx, |ui| {
                self.show_toolbar(ui);
            });

        // Panel inferior: controles + stats + consola
        TopBottomPanel::bottom("bottom")
            .frame(Frame::none().fill(panel_bg()).inner_margin(6.0))
            .show(ctx, |ui| {
                self.show_channel_controls(ui);
                self.show_stats(ui);
                self.show_console(ui);
                self.show_help_bar(ui);
            });

        // Panel central: formas de onda + barra deslizadora
        CentralPanel::default()
            .frame(Frame::none().fill(Color32::from_rgb(14, 16, 22)))
            .show(ctx, |ui| {
                if let Some(cap) = &self.capture.clone() {
                    // Fit automático en la primera captura
                    if self.first_capture {
                        self.wave_state.fit_to_width(cap.n_samples, ui.available_width());
                        self.first_capture = false;
                    }

                    // ── Teclas de flecha para navegar ────────────────────
                    // Desplaza 1/8 de la ventana visible por pulsación
                    let avail_w   = ui.available_width();
                    let pan_step  = self.wave_state.samples_per_pixel * (avail_w as f64 * KEY_PAN_FRACTION);
                    let max_scroll = (cap.n_samples as f64
                        - self.wave_state.samples_per_pixel * avail_w as f64)
                        .max(0.0);

                    ctx.input(|i| {
                        if i.key_pressed(egui::Key::ArrowLeft) {
                            self.wave_state.scroll_sample =
                                (self.wave_state.scroll_sample - pan_step).max(0.0);
                        }
                        if i.key_pressed(egui::Key::ArrowRight) {
                            self.wave_state.scroll_sample =
                                (self.wave_state.scroll_sample + pan_step).min(max_scroll);
                        }
                        // Re-arm también acepta Intro / Space
                        if i.key_pressed(egui::Key::Space) && !self.capturing {
                            // se podría llamar self.arm() pero es &mut conflict
                            // lo marcamos con un flag
                        }
                    });

                    // ── Formas de onda ───────────────────────────────────
                    show_waveform(ui, cap, &mut self.wave_state, &self.analyzer_config);

                    // ── Barra deslizadora horizontal ─────────────────────
                    ui.add_space(2.0);
                    ui.horizontal(|ui| {
                        // Etiqueta inicio
                        ui.label(
                            RichText::new(fmt_time(
                                self.wave_state.scroll_sample as f32
                                    * cap.ns_per_sample()
                            ))
                            .size(10.0)
                            .color(text_dim())
                            .monospace(),
                        );

                        // Slider de scroll
                        let mut scroll = self.wave_state.scroll_sample;
                        let slider = egui::Slider::new(&mut scroll, 0.0..=max_scroll)
                            .show_value(false)
                            .clamp_to_range(true);
                        let resp = ui.add_sized(
                            [ui.available_width() - 80.0, 16.0],
                            slider,
                        );
                        if resp.changed() {
                            self.wave_state.scroll_sample = scroll;
                        }

                        // Etiqueta fin
                        let end_sample = self.wave_state.scroll_sample
                            + self.wave_state.samples_per_pixel * avail_w as f64;
                        ui.label(
                            RichText::new(fmt_time(
                                end_sample as f32 * cap.ns_per_sample()
                            ))
                            .size(10.0)
                            .color(text_dim())
                            .monospace(),
                        );
                    });

                } else {
                    // Placeholder cuando no hay captura
                    ui.centered_and_justified(|ui| {
                        ui.label(
                            RichText::new(
                                if self.capturing {
                                    "⏳  Esperando datos de la FPGA..."
                                } else {
                                    "Pulsa  ▶ ARM  para iniciar la captura"
                                }
                            )
                            .size(18.0)
                            .color(text_dim()),
                        );
                    });
                }
            });
    }
}
