// protocol.rs

use crate::constants::{N_SAMPLES_MAX, FRAME_SIZE_MAX, SAMPLE_FREQ_HZ};

// Re-export con nombres antiguos para compatibilidad
pub use crate::constants::N_SAMPLES_MAX as N_SAMPLES;
pub use crate::constants::FRAME_SIZE_MAX as FRAME_SIZE;

#[derive(Debug, Clone, Copy)]
pub enum TriggerType {
    Manual  = 0,
    Rising  = 1,
    Falling = 2,
    Pattern = 3,
}

#[derive(Debug, Clone)]
pub struct ArmCommand {
    pub test_mode: bool,
    pub trig_type: TriggerType,
    pub trig_ch:   u8,
    pub trig_mask: u8,
    pub trig_val:  u8,
}

impl ArmCommand {
    pub fn new_test() -> Self {
        ArmCommand { test_mode: true, trig_type: TriggerType::Manual,
                     trig_ch: 0, trig_mask: 0, trig_val: 0 }
    }
    pub fn to_bytes(&self) -> [u8; 9] {
        [0x01, self.test_mode as u8, self.trig_type as u8,
         self.trig_ch, self.trig_mask, self.trig_val, 0x00, 0x00, 0xA5]
    }
}

#[derive(Debug, Clone)]
pub struct Capture {
    pub n_channels: usize,
    pub sample_div: u8,
    pub n_samples:  usize,
    pub trig_pos:   usize,
    pub data:       Vec<u8>,
    pub crc_ok:     bool,
}

impl Capture {
    pub fn from_bytes(buf: &[u8]) -> Option<Self> {
        let start = buf.windows(2).position(|w| w == [0xA5, 0x5A])?;
        let buf   = &buf[start..];
        if buf.len() < 8 { return None; }
        let n_channels = buf[2] as usize;
        let sample_div = buf[3];
        let n_samples  = { let r = u16::from_le_bytes([buf[4],buf[5]]) as usize;
                           if r == 0 { 65536 } else { r } };
        let trig_pos   = u16::from_le_bytes([buf[6],buf[7]]) as usize;
        let data_end   = 8 + n_samples;
        if buf.len() < data_end + 3 { return None; }
        if buf[data_end] != 0xDE || buf[data_end+1] != 0xAD { return None; }
        let data     = buf[8..data_end].to_vec();
        let crc_calc = data.iter().fold(0u8, |a,&b| a^b);
        Some(Capture { n_channels, sample_div, n_samples, trig_pos,
                       crc_ok: crc_calc == buf[data_end+2], data })
    }

    pub fn print_waveform(&self, cols: usize, resolution: usize) {
        let res    = resolution.max(1);
        let n_show = (self.n_samples / res).min(cols);
        let ns_per = res as f32 * self.ns_per_sample();
        let tick   = 20usize;
        let margin = "         "; // 9 chars = mismo ancho que "  CH0    "

        println!();

        // ── Etiquetas de tiempo ────────────────────────────────────────────
        // Construir como array de chars para alineacion perfecta.
        // Cada etiqueta empieza exactamente en la columna col=0,tick,2*tick...
        // El ┬ de la regla estara en esa misma columna → alineacion garantizada.
        let mut label_buf = vec![' '; n_show];
        let mut c = 0usize;
        while c < n_show {
            let t = fmt_time(c as f32 * ns_per);
            for (i, ch) in t.chars().enumerate() {
                if c + i < n_show {
                    label_buf[c + i] = ch;
                }
            }
            c += tick;
        }
        let label_str: String = label_buf.into_iter().collect();
        println!("{}{}", margin, label_str);

        // ── Regla de escala ────────────────────────────────────────────────
        // ┬ exactamente en col=0,tick,2*tick... = mismas posiciones que labels
        print!("{}", margin);
        for col in 0..n_show {
            print!("{}", if col % tick == 0 { '┬' } else { '─' });
        }
        println!();

        // ── Canales: 2 filas por canal ─────────────────────────────────────
        for ch in 0..self.n_channels.min(8) {
            // Valor mayoritario por columna
            let vals: Vec<u8> = (0..n_show).map(|c| {
                let s    = (c * res).min(self.n_samples - 1);
                let e    = (s + res).min(self.n_samples);
                let ones = (s..e).filter(|&i| (self.data[i] >> ch) & 1 == 1).count();
                if ones * 2 >= (e - s) { 1 } else { 0 }
            }).collect();

            // Fila alta: HIGH='─'  LOW=' '  subida='┌'  bajada='┐'
            print!("  CH{:<5}│", ch);
            for col in 0..n_show {
                let cur  = vals[col];
                let prev = if col > 0 { vals[col-1] } else { cur };
                let c = match (prev, cur) {
                    (0, 1) => '┌',
                    (1, 0) => '┐',
                    (_, 1) => '─',
                    _      => ' ',
                };
                print!("{}", c);
            }
            println!("│");

            // Fila baja: LOW='─'  HIGH=' '  subida='┘'  bajada='└'
            print!("         │");
            for col in 0..n_show {
                let cur  = vals[col];
                let prev = if col > 0 { vals[col-1] } else { cur };
                let c = match (prev, cur) {
                    (0, 1) => '┘',
                    (1, 0) => '└',
                    (_, 0) => '─',
                    _      => ' ',
                };
                print!("{}", c);
            }
            println!("│");

            // Separador entre canales (linea en blanco)
            if ch < self.n_channels.min(8) - 1 {
                print!("         │");
                for _ in 0..n_show { print!(" "); }
                println!("│");
            }
        }

        // Borde inferior
        print!("         └");
        for _ in 0..n_show { print!("─"); }
        println!("┘");

        println!();
        println!("  Resolucion: {} muestras/col  |  Ventana: {}  |  CRC:{}",
            res,
            fmt_time(n_show as f32 * ns_per),
            if self.crc_ok { "OK✓" } else { "ERR✗" });
    }

    pub fn print_stats(&self) {
        println!("\n    CH   Alto(%)   Flancos    Frecuencia");
        println!("  {}", "─".repeat(42));
        for ch in 0..self.n_channels.min(8) {
            let mut highs = 0usize;
            let mut edges = 0usize;
            let mut prev  = (self.data[0] >> ch) & 1;
            for &s in &self.data[1..] {
                let bit = (s >> ch) & 1;
                if bit == 1 { highs += 1; }
                if bit != prev { edges += 1; }
                prev = bit;
            }
            let pct  = 100.0 * highs as f32 / self.data.len() as f32;
            let freq = if edges >= 2 {
                fmt_freq((1e9 / self.ns_per_sample()) /
                    (self.data.len() as f32 / (edges as f32 / 2.0)))
            } else { "0 Hz".to_string() };
            println!("  CH{:<3}  {:>7.1}%  {:>7}    {:>10}",
                ch, pct, edges, freq);
        }
        println!();
    }

    pub fn ns_per_sample(&self) -> f32 {
        // ns = 1e9 / (sample_freq / divisor)
        let freq = SAMPLE_FREQ_HZ / (1u32 << self.sample_div) as f64;
        (1e9 / freq) as f32
    }
}

pub fn fmt_time(ns: f32) -> String {
    if ns < 1000.0           { format!("{:.0}ns", ns) }
    else if ns < 1_000_000.0 { format!("{:.1}us", ns / 1000.0) }
    else                     { format!("{:.2}ms", ns / 1_000_000.0) }
}

pub fn fmt_freq(hz: f32) -> String {
    if hz >= 1e6      { format!("{:.3} MHz", hz / 1e6) }
    else if hz >= 1e3 { format!("{:.1} kHz", hz / 1e3) }
    else              { format!("{:.0} Hz",  hz) }
}
