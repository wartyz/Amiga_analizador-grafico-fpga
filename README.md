# Amiga 500 en FPGA + Analizador Gráfico en Rust

Proyecto de **Amiga 500** implementado en una **FPGA Artix-7 XC7A100T** (placa **Wukong QMTECH**) con un **analizador lógico/gráfico** en tiempo real que se visualiza en el PC mediante un programa escrito en **Rust**.

---

## 🚀 Características

- Core de **Amiga 500** en VHDL/SystemVerilog
- Analizador lógico / gráfico de alta velocidad en la FPGA
- Comunicación vía UART con el PC
- Visualizador y control en **Rust** (con interfaz gráfica)
- Soporte para ROM Kickstart mediante archivo `.coe`

## 📁 Estructura del Proyecto

```bash
Amiga_analizador-grafico-fpga/
├── fpga/                    # Todo el proyecto Vivado
│   ├── src/
│   │   ├── rtl/             # Archivos VHDL
│   │   ├── constraints/     # Archivos .xdc (pines)
│   │   ├── ip/              # IPs personalizadas
│   │   └── bd/              # Block Designs (si aplica)
│   ├── scripts/             # Scripts TCL para recrear el proyecto
│   └── vivado_project/      # Proyecto completo de Vivado
│
├── software/                # Programa en Rust para el PC
│   ├── src/
│   └── Cargo.toml
│
├── docs/                    # Documentación y recursos
│   ├── wukong/              # Manuales de la placa
│   └── images/              # Capturas de pantalla
│
└── kk/                      # Archivos .coe para ROM (Kickstart)

🛠️ Cómo compilar y ejecutar
FPGA (Vivado)
Bashcd fpga/scripts
vivado -source create_project.tcl
Luego genera el bitstream normalmente.
Placa objetivo: QMTECH Wukong Artix-7 XC7A100T (xc7a100tfgg676-3)
Software Rust (PC)
Bashcd software
cargo run --release

📡 Comunicación UART
Velocidad: 2.000.000 baudios (2 Mbps)
Formato de paquetes: (pendiente de documentar)

🔧 Hardware usado
FPGA: Artix-7 XC7A100T (Wukong Board)
Comunicación: USB-UART (CH340 o similar integrado)
