# AmigaW3.xdc - PASO 4 (con SD card)

# RELOJ
set_property PACKAGE_PIN M21 [get_ports sys_clk_50M]
set_property IOSTANDARD LVCMOS33 [get_ports sys_clk_50M]
create_clock -period 20.000 -name sys_clk_pin -waveform {0.000 10.000} -add [get_ports sys_clk_50M]

# RESET
set_property PACKAGE_PIN W18 [get_ports rst_n_i]
set_property IOSTANDARD LVCMOS33 [get_ports rst_n_i]
set_property PULLTYPE PULLUP [get_ports rst_n_i]

# UART TX
set_property PACKAGE_PIN E3 [get_ports uart_tx_o]
set_property IOSTANDARD LVCMOS33 [get_ports uart_tx_o]

# LEDS
set_property PACKAGE_PIN W21  [get_ports {leds[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {leds[0]}]
set_property PACKAGE_PIN U22  [get_ports {leds[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {leds[1]}]
set_property PACKAGE_PIN V23  [get_ports {leds[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {leds[2]}]
set_property PACKAGE_PIN AB24 [get_ports {leds[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {leds[3]}]
set_property PACKAGE_PIN AA24 [get_ports {leds[4]}]
set_property IOSTANDARD LVCMOS33 [get_ports {leds[4]}]
set_property PACKAGE_PIN V24  [get_ports {leds[5]}]
set_property IOSTANDARD LVCMOS33 [get_ports {leds[5]}]
set_property PACKAGE_PIN AB26 [get_ports {leds[6]}]
set_property IOSTANDARD LVCMOS33 [get_ports {leds[6]}]
set_property PACKAGE_PIN Y25  [get_ports {leds[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports {leds[7]}]

# HDMI
set_property PACKAGE_PIN E1 [get_ports {hdmi_tx_p[0]}]
set_property PACKAGE_PIN D1 [get_ports {hdmi_tx_n[0]}]
set_property IOSTANDARD TMDS_33 [get_ports {hdmi_tx_p[0]}]
set_property IOSTANDARD TMDS_33 [get_ports {hdmi_tx_n[0]}]
set_property PACKAGE_PIN F2 [get_ports {hdmi_tx_p[1]}]
set_property PACKAGE_PIN E2 [get_ports {hdmi_tx_n[1]}]
set_property IOSTANDARD TMDS_33 [get_ports {hdmi_tx_p[1]}]
set_property IOSTANDARD TMDS_33 [get_ports {hdmi_tx_n[1]}]
set_property PACKAGE_PIN G2 [get_ports {hdmi_tx_p[2]}]
set_property PACKAGE_PIN G1 [get_ports {hdmi_tx_n[2]}]
set_property IOSTANDARD TMDS_33 [get_ports {hdmi_tx_p[2]}]
set_property IOSTANDARD TMDS_33 [get_ports {hdmi_tx_n[2]}]
set_property PACKAGE_PIN D4 [get_ports {hdmi_tx_p[3]}]
set_property PACKAGE_PIN C4 [get_ports {hdmi_tx_n[3]}]
set_property IOSTANDARD TMDS_33 [get_ports {hdmi_tx_p[3]}]
set_property IOSTANDARD TMDS_33 [get_ports {hdmi_tx_n[3]}]

# SCK = CLK = L4
# CS = DAT3 = J6
# CD = N6

# AJUSTES
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
################################################################################
## Pines para el segundo UART (analizador lógico)
## Conectado al PL2303 externo
################################################################################

## UART 2 -- analizador (PMOD J13)
## ana_uart_tx (FPGA → PL2303 RXD) -- pin P23 del PMOD J13
set_property PACKAGE_PIN  P23      [get_ports ana_uart_tx]
set_property IOSTANDARD   LVCMOS33 [get_ports ana_uart_tx]

## ana_uart_rx (PL2303 TXD → FPGA) -- pin R23 del PMOD J13
set_property PACKAGE_PIN  R23      [get_ports ana_uart_rx]
set_property IOSTANDARD   LVCMOS33 [get_ports ana_uart_rx]
set_property PULLTYPE     PULLUP   [get_ports ana_uart_rx]

set_false_path -from [get_ports ana_uart_rx]
set_false_path -to   [get_ports ana_uart_tx]