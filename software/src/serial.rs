/*// serial.rs  --  Comunicación serie con la FPGA
//
// Lee la cabecera primero para determinar n_samples dinámicamente,
// luego lee la cantidad exacta de bytes restantes.
// Funciona con cualquier proyecto VHDL independientemente de DEPTH.

use std::time::{Duration, Instant};
use std::thread;
use serialport::SerialPort;
use crate::constants::*;
use crate::protocol::Capture;

pub struct FpgaSerial {
    port:     Box<dyn SerialPort>,
    baud:     u32,
}

impl FpgaSerial {
    /// Abre el puerto con el baudrate especificado en el .cfg
    pub fn open(port_name: &str) -> Result<Self, String> {
        Self::open_with_baud(port_name, BAUD_RATE)
    }

    pub fn open_with_baud(port_name: &str, baud: u32) -> Result<Self, String> {
        let port = serialport::new(port_name, baud)
            .data_bits(serialport::DataBits::Eight)
            .stop_bits(serialport::StopBits::One)
            .parity(serialport::Parity::None)
            .flow_control(serialport::FlowControl::None)
            .timeout(Duration::from_millis(SERIAL_READ_TIMEOUT_MS))
            .open()
            .map_err(|e| format!("No se puede abrir {} a {}: {}", port_name, baud, e))?;

        Ok(FpgaSerial { port, baud })
    }

    /// Envía la configuración del MUX antes del ARM
    pub fn send_mux_config(&mut self, cmd: &[u8; 11]) -> Result<(), String> {
        self.port.write_all(cmd)
            .map_err(|e| format!("Error enviando config MUX: {}", e))?;
        std::thread::sleep(std::time::Duration::from_millis(10));
        Ok(())
    }

    /// Envía comando ARM y recibe la trama, leyendo dinámicamente
    /// la cantidad de muestras según indique la cabecera.
    pub fn send_and_receive(&mut self, cmd_bytes: &[u8; 9]) -> Result<Capture, String> {
        // Limpiar buffer de entrada
        self.port.clear(serialport::ClearBuffer::All)
            .map_err(|e| format!("Error flush: {}", e))?;

        // Clonar para hilo lector
        let mut reader = self.port.try_clone()
            .map_err(|e| format!("Error clonando puerto: {}", e))?;

        // Canal para recibir el resultado del lector
        let (tx_chan, rx_chan) = std::sync::mpsc::channel();

        // Hilo lector: lee primero la cabecera (8 bytes), decodifica n_samples,
        // luego lee n_samples + 3 bytes (datos + DE AD CRC)
        let reader_thread = thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(CAPTURE_TIMEOUT_SECS);
            let mut buf  = Vec::with_capacity(FRAME_SIZE_MAX);
            let mut tmp  = [0u8; 4096];
            let mut needed: Option<usize> = None;
            let mut last_pct = 0usize;

            loop {
                if Instant::now() > deadline {
                    let _ = tx_chan.send(Err(format!(
                        "Timeout: {}/{} bytes recibidos",
                        buf.len(),
                        needed.unwrap_or(0)
                    )));
                    return;
                }

                match reader.read(&mut tmp) {
                    Ok(n) if n > 0 => {
                        buf.extend_from_slice(&tmp[..n]);

                        // Si aún no sabemos n_samples, intentar decodificar la cabecera
                        if needed.is_none() && buf.len() >= 8 {
                            // Buscar el header A5 5A
                            if let Some(start) = buf.windows(2).position(|w| w == [0xA5, 0x5A]) {
                                if buf.len() >= start + 8 {
                                    // Decodificar n_samples de los bytes 4 y 5
                                    let n_low  = buf[start + 4];
                                    let n_high = buf[start + 5];
                                    let n_samples_raw = u16::from_le_bytes([n_low, n_high]) as usize;
                                    let n_samples = if n_samples_raw == 0 { 65536 } else { n_samples_raw };

                                    // Total = posición del header + 8 cabecera + n_samples + 3 footer
                                    let total = start + 8 + n_samples + 3;
                                    needed = Some(total);
                                    println!("\r  Cabecera detectada: {} muestras (total {} bytes)",
                                        n_samples, total);
                                }
                            }
                        }

                        // Mostrar progreso si ya conocemos el tamaño
                        if let Some(target) = needed {
                            let pct = (buf.len() * 100 / target).min(100);
                            if pct / 2 > last_pct / 2 {
                                print!("\r  Recibido: {}% ({}/{} bytes)     ",
                                    pct, buf.len(), target);
                                use std::io::Write;
                                std::io::stdout().flush().ok();
                                last_pct = pct;
                            }
                            if buf.len() >= target {
                                println!("\r  Recibidos: {} bytes OK              ", buf.len());
                                let _ = tx_chan.send(Ok(buf));
                                return;
                            }
                        }
                    }
                    Ok(_) => {}
                    Err(e) if e.kind() == std::io::ErrorKind::TimedOut => {}
                    Err(e) => {
                        let _ = tx_chan.send(Err(format!("Error lectura: {}", e)));
                        return;
                    }
                }
            }
        });

        // Pausa para que el hilo lector arranque
        thread::sleep(Duration::from_millis(ARM_PRE_DELAY_MS));

        // Enviar comando ARM
        println!("  Enviando: {:02X?} ({} baud)", cmd_bytes, self.baud);
        self.port.write_all(cmd_bytes)
            .map_err(|e| format!("Error escritura: {}", e))?;

        // Esperar resultado
        let data = rx_chan.recv_timeout(Duration::from_secs(CAPTURE_TIMEOUT_SECS + 5))
            .map_err(|_| "Timeout global esperando hilo lector".to_string())??;

        // Asegurar que el hilo terminó
        let _ = reader_thread.join();

        // Diagnóstico: primeros bytes
        let preview: Vec<String> = data.iter().take(12)
            .map(|b| format!("{:02X}", b)).collect();
        println!("  Inicio trama: [{}]", preview.join(" "));

        Capture::from_bytes(&data)
            .ok_or_else(|| format!(
                "Trama inválida ({} bytes). Inicio: [{}]",
                data.len(), preview.join(" ")))
    }
}
*/

// serial.rs  --  Comunicación serie con la FPGA
//
// Lee la cabecera primero para determinar n_samples dinámicamente,
// luego lee la cantidad exacta de bytes restantes.
// Funciona con cualquier proyecto VHDL independientemente de DEPTH.

use std::time::{Duration, Instant};
use std::thread;
use serialport::SerialPort;
use crate::constants::*;
use crate::protocol::Capture;

pub struct FpgaSerial {
    port: Box<dyn SerialPort>,
    baud: u32,
}

impl FpgaSerial {
    /// Abre el puerto con el baudrate especificado en el .cfg
    pub fn open(port_name: &str) -> Result<Self, String> {
        Self::open_with_baud(port_name, BAUD_RATE)
    }

    pub fn open_with_baud(port_name: &str, baud: u32) -> Result<Self, String> {
        let port = serialport::new(port_name, baud)
            .data_bits(serialport::DataBits::Eight)
            .stop_bits(serialport::StopBits::One)
            .parity(serialport::Parity::None)
            .flow_control(serialport::FlowControl::None)
            .timeout(Duration::from_millis(SERIAL_READ_TIMEOUT_MS))
            .open()
            .map_err(|e| format!("No se puede abrir {} a {}: {}", port_name, baud, e))?;

        Ok(FpgaSerial { port, baud })
    }

    /// Envía la configuración del MUX antes del ARM
    pub fn send_mux_config(&mut self, cmd: &[u8; 11]) -> Result<(), String> {
        println!("  MUX cfg: {:02X?} ({} baud)", cmd, self.baud);
        self.port.write_all(cmd)
            .map_err(|e| format!("Error enviando config MUX: {}", e))?;
        std::thread::sleep(std::time::Duration::from_millis(10));
        Ok(())
    }

    /// Envía comando ARM y recibe la trama, leyendo dinámicamente
    /// la cantidad de muestras según indique la cabecera.
    pub fn send_and_receive(&mut self, cmd_bytes: &[u8; 9]) -> Result<Capture, String> {
        // Limpiar buffer de entrada
        self.port.clear(serialport::ClearBuffer::All)
            .map_err(|e| format!("Error flush: {}", e))?;

        // Clonar para hilo lector
        let mut reader = self.port.try_clone()
            .map_err(|e| format!("Error clonando puerto: {}", e))?;

        // Canal para recibir el resultado del lector
        let (tx_chan, rx_chan) = std::sync::mpsc::channel();

        // Hilo lector: lee primero la cabecera (8 bytes), decodifica n_samples,
        // luego lee n_samples + 3 bytes (datos + DE AD CRC)
        let reader_thread = thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(CAPTURE_TIMEOUT_SECS);
            let mut buf = Vec::with_capacity(FRAME_SIZE_MAX);
            let mut tmp = [0u8; 4096];
            let mut needed: Option<usize> = None;
            let mut last_pct = 0usize;

            loop {
                if Instant::now() > deadline {
                    let _ = tx_chan.send(Err(format!(
                        "Timeout: {}/{} bytes recibidos",
                        buf.len(),
                        needed.unwrap_or(0)
                    )));
                    return;
                }

                match reader.read(&mut tmp) {
                    Ok(n) if n > 0 => {
                        buf.extend_from_slice(&tmp[..n]);

                        // Si aún no sabemos n_samples, intentar decodificar la cabecera
                        if needed.is_none() && buf.len() >= 8 {
                            // Buscar el header A5 5A
                            if let Some(start) = buf.windows(2).position(|w| w == [0xA5, 0x5A]) {
                                if buf.len() >= start + 8 {
                                    // Decodificar n_samples de los bytes 4 y 5
                                    let n_low = buf[start + 4];
                                    let n_high = buf[start + 5];
                                    let n_samples_raw = u16::from_le_bytes([n_low, n_high]) as usize;
                                    let n_samples = if n_samples_raw == 0 { 65536 } else { n_samples_raw };

                                    // Total = posición del header + 8 cabecera + n_samples + 3 footer
                                    let total = start + 8 + n_samples + 3;
                                    needed = Some(total);
                                    println!("\r  Cabecera detectada: {} muestras (total {} bytes)",
                                             n_samples, total);
                                }
                            }
                        }

                        // Mostrar progreso si ya conocemos el tamaño
                        if let Some(target) = needed {
                            let pct = (buf.len() * 100 / target).min(100);
                            if pct / 2 > last_pct / 2 {
                                print!("\r  Recibido: {}% ({}/{} bytes)     ",
                                       pct, buf.len(), target);
                                use std::io::Write;
                                std::io::stdout().flush().ok();
                                last_pct = pct;
                            }
                            if buf.len() >= target {
                                println!("\r  Recibidos: {} bytes OK              ", buf.len());
                                let _ = tx_chan.send(Ok(buf));
                                return;
                            }
                        }
                    }
                    Ok(_) => {}
                    Err(e) if e.kind() == std::io::ErrorKind::TimedOut => {}
                    Err(e) => {
                        let _ = tx_chan.send(Err(format!("Error lectura: {}", e)));
                        return;
                    }
                }
            }
        });

        // Pausa para que el hilo lector arranque
        thread::sleep(Duration::from_millis(ARM_PRE_DELAY_MS));

        // Enviar comando ARM
        println!("  Enviando: {:02X?} ({} baud)", cmd_bytes, self.baud);
        self.port.write_all(cmd_bytes)
            .map_err(|e| format!("Error escritura: {}", e))?;

        // Esperar resultado
        let data = rx_chan.recv_timeout(Duration::from_secs(CAPTURE_TIMEOUT_SECS + 5))
            .map_err(|_| "Timeout global esperando hilo lector".to_string())??;

        // Asegurar que el hilo terminó
        let _ = reader_thread.join();

        // Diagnóstico: primeros bytes
        let preview: Vec<String> = data.iter().take(12)
            .map(|b| format!("{:02X}", b)).collect();
        println!("  Inicio trama: [{}]", preview.join(" "));

        Capture::from_bytes(&data)
            .ok_or_else(|| format!(
                "Trama inválida ({} bytes). Inicio: [{}]",
                data.len(), preview.join(" ")))
    }
}
