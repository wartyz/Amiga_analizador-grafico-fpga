--------------------------------------------------------------------------------
-- uart_tx.vhd  --  Transmisor UART 8N1
--
-- Parametros genericos:
--   CLK_HZ  : frecuencia del reloj de entrada en Hz
--   BAUD    : velocidad en baudios
--
-- Interface:
--   data_in  : byte a transmitir
--   valid    : '1' un ciclo para iniciar transmision
--   ready    : '1' cuando el modulo puede aceptar un nuevo byte
--   tx       : linea serie de salida (idle = '1')
--
-- Uso:
--   Cuando ready='1', colocar el byte en data_in y pulsar valid='1'
--   durante un ciclo de reloj. El modulo transmite automaticamente.
--   No enviar otro byte hasta que ready vuelva a '1'.
--
-- Reutilizable: sin dependencias externas.
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity uart_tx is
    generic (
        CLK_HZ : integer := 28_328_980;   -- frecuencia real del clk_wiz_0
        BAUD   : integer := 2_000_000     -- velocidad serie
    );
    port (
        clk      : in  std_logic;
        rst_n    : in  std_logic;          -- reset activo bajo
        -- Interface con el sistema
        data_in  : in  std_logic_vector(7 downto 0);
        valid    : in  std_logic;          -- pulso de 1 ciclo para enviar
        ready    : out std_logic;          -- '1' = listo para nuevo byte
        -- Linea serie
        tx       : out std_logic
    );
end entity uart_tx;

architecture rtl of uart_tx is

    constant BIT_TICKS : integer := CLK_HZ / BAUD;  -- ciclos por bit

    type state_t is (S_IDLE, S_START, S_DATA, S_STOP);
    signal state   : state_t := S_IDLE;

    signal tick    : integer range 0 to BIT_TICKS - 1 := 0;
    signal bit_idx : integer range 0 to 7 := 0;
    signal shift   : std_logic_vector(7 downto 0) := (others => '0');

begin

    process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                state   <= S_IDLE;
                tick    <= 0;
                bit_idx <= 0;
                tx      <= '1';
                ready   <= '1';
            else
                case state is

                    when S_IDLE =>
                        tx    <= '1';
                        ready <= '1';
                        if valid = '1' then
                            shift   <= data_in;
                            tick    <= 0;
                            ready   <= '0';
                            state   <= S_START;
                        end if;

                    when S_START =>
                        tx <= '0';              -- bit de inicio
                        if tick = BIT_TICKS - 1 then
                            tick    <= 0;
                            bit_idx <= 0;
                            state   <= S_DATA;
                        else
                            tick <= tick + 1;
                        end if;

                    when S_DATA =>
                        tx <= shift(bit_idx);   -- LSB primero
                        if tick = BIT_TICKS - 1 then
                            tick <= 0;
                            if bit_idx = 7 then
                                state <= S_STOP;
                            else
                                bit_idx <= bit_idx + 1;
                            end if;
                        else
                            tick <= tick + 1;
                        end if;

                    when S_STOP =>
                        tx <= '1';              -- bit de parada
                        if tick = BIT_TICKS - 1 then
                            tick  <= 0;
                            ready <= '1';
                            state <= S_IDLE;
                        else
                            tick <= tick + 1;
                        end if;

                end case;
            end if;
        end if;
    end process;

end architecture rtl;
