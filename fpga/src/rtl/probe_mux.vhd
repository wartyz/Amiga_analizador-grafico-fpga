--------------------------------------------------------------------------------
-- probe_mux.vhd  --  Multiplexor de sondas controlado por registro
--
-- Para cada canal N del analizador, selecciona entre:
--   - Señal externa: pmod_pins(N)
--   - Señal interna: internal_signals(sel[N])
--
-- El registro de configuración se carga por UART antes del ARM.
-- Rust calcula la configuración a partir del fichero .cfg y la envía.
--
-- Protocolo de configuración (comando 0x02):
--   [0x02]           opcode CONFIGURE
--   [ext_mask]       1 byte: bit N=1 → canal N usa señal externa
--   [sel_0]          1 byte: índice de señal interna para canal 0
--   [sel_1]          1 byte: índice de señal interna para canal 1
--   ...              (N_CH bytes de selección)
--   [0xA5]           confirmación fin de comando
--
-- Genericos:
--   N_CH      : número de canales (8)
--   N_INT     : número de señales internas disponibles (hasta 16)
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity probe_mux is
    generic (
        N_CH  : integer := 8;
        N_INT : integer := 16
    );
    port (
        clk             : in  std_logic;
        rst_n           : in  std_logic;

        -- Señales externas (pines físicos PMOD)
        pmod_pins       : in  std_logic_vector(N_CH-1 downto 0);

        -- Señales internas del DUT (array numerado)
        internal_signals: in  std_logic_vector(N_INT-1 downto 0);

        -- Registro de configuración (escrito por UART via top)
        ext_mask        : in  std_logic_vector(N_CH-1 downto 0);
        -- ext_mask(N)=1 → canal N usa pmod_pins(N)
        -- ext_mask(N)=0 → canal N usa internal_signals(sel_N)
        sel             : in  std_logic_vector(N_CH*4-1 downto 0);
        -- sel[N*4+3:N*4] = índice (0..15) de señal interna para canal N

        -- Salida al logic_capture
        probes          : out std_logic_vector(N_CH-1 downto 0)
    );
end entity probe_mux;

architecture rtl of probe_mux is
begin

    process(pmod_pins, internal_signals, ext_mask, sel)
        variable idx : integer range 0 to N_INT-1;
    begin
        for ch in 0 to N_CH-1 loop
            if ext_mask(ch) = '1' then
                -- Canal externo: conectar pin físico
                probes(ch) <= pmod_pins(ch);
            else
                -- Canal interno: seleccionar señal interna por índice
                idx := to_integer(unsigned(sel(ch*4+3 downto ch*4)));
                if idx < N_INT then
                    probes(ch) <= internal_signals(idx);
                else
                    probes(ch) <= '0';
                end if;
            end if;
        end loop;
    end process;

end architecture rtl;
