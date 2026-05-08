// main.rs  --  Analizador lógico FPGA
//
// Sin argumentos. Sin parámetros del ejecutable.
// Toda la configuración va en un fichero .cfg que se carga
// desde la GUI con el botón "📂 Config".
//
// Al arrancar la aplicación está en estado "sin configuración" hasta
// que el usuario carga un .cfg. Al intentar capturar sin .cfg,
// la GUI avisa con un mensaje claro.

mod protocol;
mod serial;
mod waveform;
mod app;
mod constants;
mod config;

fn main() {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_inner_size([constants::WINDOW_WIDTH, constants::WINDOW_HEIGHT])
            .with_min_inner_size([constants::WINDOW_MIN_WIDTH, constants::WINDOW_MIN_HEIGHT])
            .with_title("Logic Analyzer — FPGA Wukong"),
        ..Default::default()
    };

    eframe::run_native(
        "Logic Analyzer",
        options,
        Box::new(|cc| Ok(Box::new(app::LogicAnalyzerApp::new(cc)))),
    ).unwrap();
}
