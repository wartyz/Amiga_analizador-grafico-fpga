--------------------------------------------------------------------------------
-- uart_rx.vhd  --  Receptor UART 8N1
--
-- Parametros genericos:
--   CLK_HZ  : frecuencia del reloj de entrada en Hz
--   BAUD    : velocidad en baudios
--
-- Interface:
--   rx         : linea serie de entrada
--   data_out   : byte recibido
--   data_valid : '1' durante un ciclo cuando data_out es valido
--
-- El modulo muestrea en el centro de cada bit para maxima inmunidad
-- al ruido. Incluye sincronizador de 2 etapas en la entrada rx.
--
-- Reutilizable: sin dependencias externas.
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity uart_rx is
    generic (
        CLK_HZ : integer := 28_328_980;
        BAUD   : integer := 2_000_000
    );
    port (
        clk        : in  std_logic;
        rst_n      : in  std_logic;
        -- Linea serie
        rx         : in  std_logic;
        -- Interface con el sistema
        data_out   : out std_logic_vector(7 downto 0);
        data_valid : out std_logic
    );
end entity uart_rx;

architecture rtl of uart_rx is

    constant BIT_TICKS  : integer := CLK_HZ / BAUD;
    constant HALF_TICKS : integer := BIT_TICKS / 2;

    -- Sincronizador de 2 etapas para rx (evita metaestabilidad)
    signal rx_s0   : std_logic := '1';
    signal rx_s1   : std_logic := '1';  -- rx estabilizado
    signal rx_prev : std_logic := '1';

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
                rx_s0      <= '1';
                rx_s1      <= '1';
                rx_prev    <= '1';
                state      <= S_IDLE;
                tick       <= 0;
                bit_idx    <= 0;
                data_valid <= '0';
                data_out   <= (others => '0');
            else
                -- Sincronizador
                rx_s0   <= rx;
                rx_s1   <= rx_s0;
                rx_prev <= rx_s1;

                data_valid <= '0';  -- pulso de 1 ciclo

                case state is

                    when S_IDLE =>
                        -- Detectar flanco de bajada = inicio de start bit
                        if rx_prev = '1' and rx_s1 = '0' then
                            tick  <= 0;
                            state <= S_START;
                        end if;

                    when S_START =>
                        -- Esperar medio bit para muestrear en el centro
                        if tick = HALF_TICKS - 1 then
                            tick <= 0;
                            -- Verificar que la linea sigue baja (start valido)
                            if rx_s1 = '0' then
                                bit_idx <= 0;
                                state   <= S_DATA;
                            else
                                state <= S_IDLE;  -- falso start, ignorar
                            end if;
                        else
                            tick <= tick + 1;
                        end if;

                    when S_DATA =>
                        -- Muestrear en el centro de cada bit (cada BIT_TICKS)
                        if tick = BIT_TICKS - 1 then
                            tick <= 0;
                            -- Shift registro: LSB primero
                            shift <= rx_s1 & shift(7 downto 1);
                            if bit_idx = 7 then
                                state <= S_STOP;
                            else
                                bit_idx <= bit_idx + 1;
                            end if;
                        else
                            tick <= tick + 1;
                        end if;

                    when S_STOP =>
                        -- Esperar bit de parada
                        if tick = BIT_TICKS - 1 then
                            tick <= 0;
                            if rx_s1 = '1' then
                                -- Stop bit valido: publicar dato
                                data_out   <= shift;
                                data_valid <= '1';
                            end if;
                            -- Si rx_s1='0' hay error de frame, descartar
                            state <= S_IDLE;
                        else
                            tick <= tick + 1;
                        end if;

                end case;
            end if;
        end if;
    end process;

end architecture rtl;
