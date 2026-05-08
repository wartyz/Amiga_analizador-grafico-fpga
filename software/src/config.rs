// config.rs  --  Configuración completa del analizador lógico
//
// Lee un fichero .cfg con dos secciones:
//   1. Cabecera global (parámetros de sesión)
//   2. Canales (nombre, fuente, reloj)
//
// ┌─────────────────────────────────────────────────────────────────┐
// │  PLANTILLA  logic_analyzer.cfg                                  │
// │  Copia este bloque a un fichero vacío .cfg y edítalo           │
// ├─────────────────────────────────────────────────────────────────┤
// │                                                                 │
// │  # ── CONEXIÓN ──────────────────────────────────────────────   │
// │  puerto      /dev/ttyUSB0                                       │
// │  baud        2000000                                            │
// │                                                                 │
// │  # ── CAPTURA ───────────────────────────────────────────────   │
// │  test        false      # true = generador interno FPGA        │
// │  consola     false      # true = salida por terminal            │
// │                                                                 │
// │  # ── TRIGGER ───────────────────────────────────────────────   │
// │  trigger     manual     # manual | rising | falling             │
// │  trigger_ch  CH00       # canal de trigger (CH00..CH07)        │
// │                                                                 │
// │  # ── VISUALIZACIÓN ─────────────────────────────────────────   │
// │  zoom        0.90       # factor zoom rueda ratón (0.70-0.99)  │
// │  zoom_min    0.10       # zoom máximo acercamiento              │
// │  pan_fraction 0.125     # fracción ventana por tecla flecha     │
// │  ch_height   70.0       # altura canal en pixels                │
// │  sample_freq 28328980   # Hz (debe coincidir con VHDL)         │
// │                                                                 │
// │  # ── CANALES ───────────────────────────────────────────────   │
// │  # CHnn  nombre    fuente        reloj                          │
// │  # Fuentes: internal_N | gpio_N | probe_N | none               │
// │  CH00    CLK       internal_0    true                           │
// │  CH01    DATA      internal_1    false                          │
// │  CH02    AND_out   internal_2    false                          │
// │  CH03                            # vacío = no usado             │
// │  CH04                                                           │
// │  CH05                                                           │
// │  CH06                                                           │
// │  CH07                                                           │
// │                                                                 │
// └─────────────────────────────────────────────────────────────────┘

use std::path::{Path, PathBuf};
use std::fs;
use crate::constants::*;

// ── Trigger ───────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum TriggerMode {
    Manual,
    Rising,
    Falling,
}

impl TriggerMode {
    fn parse(s: &str) -> Self {
        match s.to_lowercase().as_str() {
            "rising"  | "subida"  | "up"   => TriggerMode::Rising,
            "falling" | "bajada"  | "down" => TriggerMode::Falling,
            _                              => TriggerMode::Manual,
        }
    }
}

// ── Fuente de canal ───────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq)]
pub enum ChannelSource {
    Gpio(u8),           // GPIO externo (ESP32/Arduino): gpio_N
    Internal(u8),       // señal interna de la FPGA: internal_N
    Probe(u8),          // pin físico PMOD: probe_N
    None,               // no usado
}

impl ChannelSource {
    fn parse(s: &str) -> Self {
        let s = s.to_lowercase();
        if s == "none" || s == "-" {
            ChannelSource::None
        } else if let Some(n) = s.strip_prefix("gpio_") {
            ChannelSource::Gpio(n.parse().unwrap_or(0))
        } else if let Some(n) = s.strip_prefix("probe_") {
            ChannelSource::Probe(n.parse().unwrap_or(0))
        } else if let Some(n) = s.strip_prefix("internal_") {
            ChannelSource::Internal(n.parse().unwrap_or(0))
        } else if s == "internal" {
            ChannelSource::Internal(0)
        } else {
            ChannelSource::None
        }
    }

    pub fn description(&self) -> String {
        match self {
            ChannelSource::Gpio(n)     => format!("GPIO {}", n),
            ChannelSource::Internal(n) => format!("Interno [{}]", n),
            ChannelSource::Probe(n)    => format!("Probe {}", n),
            ChannelSource::None        => "No usado".to_string(),
        }
    }

    pub fn is_external(&self) -> bool {
        matches!(self, ChannelSource::Gpio(_) | ChannelSource::Probe(_))
    }
}

// ── Configuración de canal ────────────────────────────────────────────────────

#[derive(Debug, Clone)]
pub struct ChannelConfig {
    pub name:     String,
    pub source:   ChannelSource,
    pub is_clock: bool,
    pub active:   bool,
}

impl ChannelConfig {
    fn default_for(idx: usize) -> Self {
        ChannelConfig {
            name:     format!("CH{}", idx),
            source:   ChannelSource::None,
            is_clock: false,
            active:   false,
        }
    }
}

// ── Configuración global de sesión ────────────────────────────────────────────

#[derive(Debug, Clone)]
pub struct SessionConfig {
    // Conexión
    pub puerto:       String,
    pub baud:         u32,

    // Captura
    pub test_mode:    bool,
    pub consola:      bool,

    // Trigger
    pub trigger:      TriggerMode,
    pub trigger_ch:   usize,        // índice 0..7

    // Visualización (sobreescriben constants.rs si se especifican)
    pub zoom_factor:  f64,
    pub zoom_min:     f64,
    pub pan_fraction: f64,
    pub ch_height:    f32,
    pub sample_freq:  f64,

    // Log
    pub log_file:     Option<String>,   // None = no logging
}

impl Default for SessionConfig {
    fn default() -> Self {
        SessionConfig {
            puerto:       DEFAULT_PORT.to_string(),
            baud:         BAUD_RATE,
            test_mode:    false,
            consola:      false,
            trigger:      TriggerMode::Manual,
            trigger_ch:   0,
            zoom_factor:  ZOOM_IN_FACTOR,
            zoom_min:     ZOOM_MIN_SPP,
            pan_fraction: KEY_PAN_FRACTION,
            ch_height:    CH_HEIGHT,
            sample_freq:  SAMPLE_FREQ_HZ,
            log_file:     None,
        }
    }
}

// ── Configuración completa ────────────────────────────────────────────────────

#[derive(Debug, Clone)]
pub struct AnalyzerConfig {
    pub session:   SessionConfig,
    pub channels:  [ChannelConfig; 8],
    pub file_path: Option<PathBuf>,
    pub errors:    Vec<String>,
}

impl Default for AnalyzerConfig {
    fn default() -> Self {
        AnalyzerConfig {
            session:   SessionConfig::default(),
            channels:  std::array::from_fn(|i| ChannelConfig {
                name:     format!("CH{}", i),
                source:   ChannelSource::None,
                is_clock: false,
                active:   true,
            }),
            file_path: None,
            errors:    Vec::new(),
        }
    }
}

impl AnalyzerConfig {

    /// Carga configuración desde fichero .cfg
    pub fn load(path: &Path) -> Self {
        let mut cfg = AnalyzerConfig {
            session:   SessionConfig::default(),
            channels:  std::array::from_fn(|i| ChannelConfig::default_for(i)),
            file_path: Some(path.to_path_buf()),
            errors:    Vec::new(),
        };

        let content = match fs::read_to_string(path) {
            Ok(c)  => c,
            Err(e) => {
                cfg.errors.push(format!("No se puede leer {}: {}", path.display(), e));
                return cfg;
            }
        };

        let mut ch_idx = 0usize;
        let mut in_channels = false;  // false=cabecera, true=canales

        for (line_num, line) in content.lines().enumerate() {
            let line_num = line_num + 1;
            let raw = line.trim();

            // Comentario puro: ignorar sin avanzar índice
            if raw.starts_with('#') { continue; }

            // Quitar comentario inline
            let raw = match raw.find('#') {
                Some(pos) => raw[..pos].trim(),
                None      => raw,
            };

            if raw.is_empty() {
                // Línea vacía en sección canales = canal no usado
                if in_channels && ch_idx < N_CHANNELS {
                    cfg.channels[ch_idx] = ChannelConfig::default_for(ch_idx);
                    ch_idx += 1;
                }
                continue;
            }

            let fields: Vec<&str> = raw.split_whitespace().collect();
            if fields.is_empty() { continue; }

            // Detectar si es línea de canal (empieza por CH seguido de dígitos)
            let is_channel_line = fields[0].to_uppercase().starts_with("CH")
                && fields[0][2..].chars().all(|c| c.is_ascii_digit());

            if is_channel_line {
                in_channels = true;

                if ch_idx >= N_CHANNELS {
                    cfg.errors.push(format!(
                        "Línea {}: más de {} canales, ignorando", line_num, N_CHANNELS));
                    continue;
                }

                if fields.len() < 2 {
                    // Solo el id CHnn → canal vacío
                    cfg.channels[ch_idx] = ChannelConfig::default_for(ch_idx);
                } else {
                    // CHnn  nombre  fuente  reloj
                    let name     = fields[1].to_string();
                    let source   = fields.get(2)
                        .map(|s| ChannelSource::parse(s))
                        .unwrap_or(ChannelSource::None);
                    let is_clock = fields.get(3)
                        .map(|s| s.to_lowercase() == "true")
                        .unwrap_or(false);

                    cfg.channels[ch_idx] = ChannelConfig {
                        name, source, is_clock, active: true,
                    };
                }
                ch_idx += 1;

            } else if !in_channels {
                // Línea de cabecera: clave  valor
                if fields.len() < 2 {
                    cfg.errors.push(format!(
                        "Línea {}: parámetro sin valor: {}", line_num, fields[0]));
                    continue;
                }
                let key = fields[0].to_lowercase();
                let val = fields[1];

                match key.as_str() {
                    "puerto"       => cfg.session.puerto = val.to_string(),
                    "baud"         => {
                        cfg.session.baud = val.parse().unwrap_or(BAUD_RATE);
                    }
                    "test"         => {
                        cfg.session.test_mode = val.to_lowercase() == "true";
                    }
                    "consola"      => {
                        cfg.session.consola = val.to_lowercase() == "true";
                    }
                    "trigger"      => {
                        cfg.session.trigger = TriggerMode::parse(val);
                    }
                    "trigger_ch"   => {
                        // Acepta CH00, CH01... o 0, 1...
                        let s = val.to_uppercase();
                        let n = if s.starts_with("CH") {
                            s[2..].parse::<usize>().unwrap_or(0)
                        } else {
                            val.parse::<usize>().unwrap_or(0)
                        };
                        cfg.session.trigger_ch = n.min(N_CHANNELS - 1);
                    }
                    "zoom"         => {
                        cfg.session.zoom_factor =
                            val.parse::<f64>().unwrap_or(ZOOM_IN_FACTOR).clamp(0.5, 0.99);
                    }
                    "zoom_min"     => {
                        cfg.session.zoom_min =
                            val.parse::<f64>().unwrap_or(ZOOM_MIN_SPP).max(0.001);
                    }
                    "pan_fraction" => {
                        cfg.session.pan_fraction =
                            val.parse::<f64>().unwrap_or(KEY_PAN_FRACTION).clamp(0.01, 0.5);
                    }
                    "ch_height"    => {
                        cfg.session.ch_height =
                            val.parse::<f32>().unwrap_or(CH_HEIGHT).clamp(30.0, 200.0);
                    }
                    "sample_freq"  => {
                        cfg.session.sample_freq =
                            val.parse::<f64>().unwrap_or(SAMPLE_FREQ_HZ);
                    }
                    "log"          => {
                        cfg.session.log_file = Some(val.to_string());
                    }
                    other => {
                        cfg.errors.push(format!(
                            "Línea {}: parámetro desconocido: {}", line_num, other));
                    }
                }
            }
        }

        // Rellenar canales restantes
        for i in ch_idx..N_CHANNELS {
            cfg.channels[i] = ChannelConfig::default_for(i);
        }

        cfg
    }

    // ── Métodos de consulta ───────────────────────────────────────────────────

    pub fn clock_channel(&self) -> Option<usize> {
        self.channels.iter().position(|c| c.is_clock && c.active)
    }

    pub fn channel_name(&self, idx: usize) -> &str {
        if idx < N_CHANNELS && self.channels[idx].active
            && !self.channels[idx].name.is_empty() {
            &self.channels[idx].name
        } else {
            "?"
        }
    }

    pub fn summary(&self) -> String {
        match &self.file_path {
            Some(p) => p.file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("config.cfg")
                .to_string(),
            None => "Config por defecto".to_string(),
        }
    }

    /// Comando de configuración del MUX para la FPGA
    /// Protocolo: [0x02][ext_mask][sel_0..sel_7][0xA5]  (11 bytes)
    pub fn mux_command(&self) -> [u8; 11] {
        let mut cmd = [0u8; 11];
        cmd[0] = 0x02;

        let mut ext_mask = 0u8;
        for ch in 0..N_CHANNELS {
            if self.channels[ch].active && self.channels[ch].source.is_external() {
                ext_mask |= 1 << ch;
            }
        }
        cmd[1] = ext_mask;

        for ch in 0..N_CHANNELS {
            cmd[2 + ch] = match self.channels[ch].source {
                ChannelSource::Internal(n) => n,
                _ => 0,
            };
        }
        cmd[10] = 0xA5;
        cmd
    }

    pub fn needs_mux_config(&self) -> bool {
        self.channels.iter().any(|c| c.active)
    }
}
