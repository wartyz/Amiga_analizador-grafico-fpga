// constants.rs  --  Constantes configurables del analizador lógico
//
// Modificar este fichero para ajustar el comportamiento de la aplicación
// sin tocar el resto del código.

// ── Comunicación serie ────────────────────────────────────────────────────────

/// Puerto serie por defecto
pub const DEFAULT_PORT: &str = "/dev/ttyUSB0";

/// Velocidad UART en baudios (debe coincidir con el VHDL: CLK_HZ/BAUD)
pub const BAUD_RATE: u32 = 2_000_000;

/// Timeout de lectura por fragmento en ms (el lector reintenta si no hay datos)
pub const SERIAL_READ_TIMEOUT_MS: u64 = 200;

/// Timeout total de la captura en segundos
pub const CAPTURE_TIMEOUT_SECS: u64 = 30;

/// Pausa en ms antes de enviar el comando ARM (da tiempo al lector a arrancar)
pub const ARM_PRE_DELAY_MS: u64 = 50;


// ── Protocolo de trama ────────────────────────────────────────────────────────

/// Magic header bytes de la trama FPGA→PC
pub const FRAME_MAGIC_HEADER: [u8; 2] = [0xA5, 0x5A];

/// Magic footer bytes
pub const FRAME_MAGIC_FOOTER: [u8; 2] = [0xDE, 0xAD];

/// Número de muestras por captura (debe coincidir con DEPTH en VHDL)
pub const N_SAMPLES_MAX: usize = 65_536;

/// Tamaño total de la trama: header(8) + datos + footer(2) + crc(1)
pub const FRAME_SIZE_MAX: usize = 8 + N_SAMPLES_MAX + 3;

/// Margen extra al leer (por si hay bytes de basura antes del header)
pub const FRAME_READ_MARGIN: usize = 64;


// ── Hardware FPGA ─────────────────────────────────────────────────────────────

/// Frecuencia de muestreo base en Hz (clk_wiz_0 en la Wukong)
pub const SAMPLE_FREQ_HZ: f64 = 28_328_980.0;

/// Número de canales del analizador
pub const N_CHANNELS: usize = 8;


// ── Interfaz gráfica ──────────────────────────────────────────────────────────

/// Tamaño inicial de la ventana (ancho, alto) en píxeles
pub const WINDOW_WIDTH:  f32 = 1280.0;
pub const WINDOW_HEIGHT: f32 = 780.0;

/// Tamaño mínimo de la ventana
pub const WINDOW_MIN_WIDTH:  f32 = 800.0;
pub const WINDOW_MIN_HEIGHT: f32 = 500.0;


// ── Waveform: zoom ────────────────────────────────────────────────────────────

/// Factor de zoom por paso de rueda del ratón hacia ADENTRO (acercar).
/// Valores recomendados: 0.5 (muy rápido) → 0.95 (muy lento)
/// Por defecto 0.85 = zoom suave y controlable.
pub const ZOOM_IN_FACTOR:  f64 = 0.85;

/// Factor de zoom por paso de rueda del ratón hacia AFUERA (alejar).
/// Debe ser 1/ZOOM_IN_FACTOR para que zoom in + zoom out = posición original.
/// Por defecto 1.0/0.85 ≈ 1.176
pub const ZOOM_OUT_FACTOR: f64 = 1.0 / ZOOM_IN_FACTOR;

/// Muestras por pixel mínimas (zoom máximo — máximo acercamiento)
/// 0.01 = puedes ver ~100 píxeles por muestra (zoom muy profundo, comparable a PulseView)
/// Para zoom aún más profundo, usar `zoom_min` en el .cfg con valor menor.
pub const ZOOM_MIN_SPP: f64 = 0.001;

/// Muestras por pixel máximas (zoom mínimo — vista más alejada)
/// Se calcula dinámicamente como n_samples / 4, pero este es el tope absoluto
pub const ZOOM_MAX_SPP: f64 = 65_536.0;


// ── Waveform: navegación ──────────────────────────────────────────────────────

/// Fracción de la ventana visible que se desplaza con cada tecla de flecha.
/// 0.125 = 1/8 de la ventana por pulsación
pub const KEY_PAN_FRACTION: f64 = 0.125;


// ── Waveform: visual ──────────────────────────────────────────────────────────

/// Altura de cada canal en píxeles
pub const CH_HEIGHT: f32 = 70.0;

/// Padding vertical dentro del canal (espacio entre borde y línea de señal)
pub const CH_PADDING: f32 = 8.0;

/// Ancho del área de etiquetas de canal (izquierda)
pub const LABEL_WIDTH: f32 = 55.0;

/// Altura de la regla de tiempo (arriba)
pub const RULER_HEIGHT: f32 = 28.0;

/// Grosor de la línea de señal en píxeles
pub const SIGNAL_STROKE_WIDTH: f32 = 1.8;

// ── Puntos de muestra ─────────────────────────────────────────────────────────

/// Tamaño en píxeles del radio del punto de muestra
pub const SAMPLE_DOT_RADIUS: f32 = 2.0;

/// Umbral de muestras_por_pixel a partir del cual los puntos dejan de mostrarse.
/// Si spp >= este valor, no se dibujan puntos (sería ruido visual).
/// 1.5 = cuando hay más de 1.5 muestras por píxel, no se muestran puntos
pub const SAMPLE_DOT_MAX_SPP: f64 = 1.5;

/// Umbral inferior para puntos grandes (zoom extremo).
/// Si spp <= este valor, se dibujan puntos al tamaño completo.
/// Entre SAMPLE_DOT_FULL_SPP y SAMPLE_DOT_MAX_SPP los puntos se hacen más pequeños.
pub const SAMPLE_DOT_FULL_SPP: f64 = 0.3;

/// Opacidad del punto (0=invisible, 255=sólido)
pub const SAMPLE_DOT_ALPHA: u8 = 220;

/// Separación mínima en píxeles entre ticks de la regla de tiempo
pub const RULER_TICK_MIN_PX: f64 = 80.0;

/// Número de subdivisiones entre ticks principales de la regla
pub const RULER_SUBDIVISIONS: f64 = 5.0;


// ── Colores ───────────────────────────────────────────────────────────────────

/// Colores de los 8 canales [R, G, B]
pub const CH_COLORS: [[u8; 3]; 8] = [
    [  0, 230, 150],  // CH0 verde-cyan
    [255, 210,  50],  // CH1 amarillo
    [100, 180, 255],  // CH2 azul claro
    [255, 100, 100],  // CH3 rojo
    [200, 120, 255],  // CH4 violeta
    [255, 160,   0],  // CH5 naranja
    [100, 255, 120],  // CH6 verde
    [255, 120, 200],  // CH7 rosa
];

/// Color de fondo principal
pub const COLOR_BG:       [u8; 3] = [ 14,  16,  22];
/// Color de fondo de paneles
pub const COLOR_PANEL_BG: [u8; 3] = [ 22,  26,  36];
/// Color de la rejilla
pub const COLOR_GRID:     [u8; 3] = [ 72,  85, 112];
/// Color de fondo de la regla de tiempo
pub const COLOR_RULER_BG: [u8; 3] = [ 28,  32,  42];
/// Color de las etiquetas de la regla
pub const COLOR_LABEL:    [u8; 3] = [170, 182, 205];
/// Color de los ticks de la regla
pub const COLOR_TICK:     [u8; 3] = [120, 135, 165];
/// Color de texto secundario/deshabilitado
pub const COLOR_DIM:      [u8; 3] = [120, 130, 150];
/// Color de acento (botones activos, estado OK)
pub const COLOR_ACCENT:   [u8; 3] = [  0, 200, 130];
/// Color cursor A
pub const COLOR_CURSOR_A: [u8; 3] = [255, 220,  50];
/// Color cursor B
pub const COLOR_CURSOR_B: [u8; 3] = [ 80, 200, 255];
/// Color canal reloj (CLK)
pub const COLOR_CLOCK_CH: [u8; 3] = [255, 220,  50];


// ── Stretch de actividad en LEDs / UI ─────────────────────────────────────────

/// Duración en ms del indicador de actividad TX en la UI
pub const TX_ACTIVITY_MS: u64 = 100;
