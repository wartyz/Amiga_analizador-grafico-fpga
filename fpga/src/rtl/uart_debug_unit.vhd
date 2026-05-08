---------------------------------------------------
-- FICHERO: ./uart_debug_unit.vhd  (CORREGIDO)
---------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- ==========================================================
-- [BLOQUE 1: ENTIDAD DE LA UNIDAD UART DEBUG UNIFICADA]
-- ==========================================================
entity uart_debug_unit is
    Port ( 
        clk      : in  std_logic;
        trigger  : in  std_logic;
        addr     : in  std_logic_vector(31 downto 0);
        data     : in  std_logic_vector(15 downto 0);
        rw       : in  std_logic;
        as       : in  std_logic;
        tx_pin   : out std_logic;
        busy_o   : out std_logic 
    );
end uart_debug_unit;

-- ==========================================================
-- [BLOQUE 2: ARQUITECTURA CON TRANSMISOR INTEGRADO]
-- ==========================================================
architecture Behavioral of uart_debug_unit is

    -- 28.000.000 / 115200 = 243 ciclos por bit
    constant BIT_TIME : integer := 246; -- 28.375MHz / 115200
    
    type state_t is (
        IDLE,
        LATCH,       -- espera 1 ciclo para que msg_to_send sea valido
        START_BIT, 
        DATA_BITS, 
        STOP_BIT, 
        NEXT_CHAR
    );
    signal state : state_t := IDLE;

    signal uart_buffer : std_logic_vector(7 downto 0);
    signal baud_cnt    : integer range 0 to BIT_TIME := 0;
    signal bit_idx     : integer range 0 to 7 := 0;
    
    -- Trama: "A:00000000 D:0000 R:0\r\n" (22 caracteres)
    type msg_array is array (0 to 21) of std_logic_vector(7 downto 0);
    signal msg_to_send : msg_array;
    signal char_idx    : integer range 0 to 22 := 0;

    -- [FIX 1] Latch del flanco de subida del trigger (un solo pulso)
    signal trigger_prev : std_logic := '0';
    signal trigger_pulse : std_logic := '0';

-- [BLOQUE 3: FUNCION HEX A ASCII]
    function to_ascii(hex : std_logic_vector(3 downto 0)) return std_logic_vector is
        variable val_int : integer;
        variable res     : std_logic_vector(7 downto 0);
    begin
        val_int := to_integer(unsigned(hex));
        if val_int < 10 then
            res := std_logic_vector(to_unsigned(val_int + 48, 8));
        else
            res := std_logic_vector(to_unsigned(val_int + 55, 8));
        end if;
        return res;
    end function;

begin

    -- [FIX 1] Detección de flanco de subida del trigger
    -- Así el trigger solo dispara UNA VEZ por acceso de bus,
    -- aunque dtack permanezca bajo varios ciclos.
    process(clk)
    begin
        if rising_edge(clk) then
            trigger_prev  <= trigger;
            trigger_pulse <= trigger and (not trigger_prev);
        end if;
    end process;

    -- [BLOQUE 4: PROCESO DE TRANSMISIÓN SERIAL]
    process(clk)
    begin
        if rising_edge(clk) then
            case state is

                when IDLE =>
                    tx_pin <= '1';
                    busy_o <= '0';
                    char_idx <= 0;
                    
                    -- [FIX 1] Usamos trigger_pulse en lugar de trigger
                    -- para que solo se lance una vez por acceso
                    if trigger_pulse = '1' then
                        -- Construcción del mensaje ASCII
                        msg_to_send(0)  <= x"41"; -- 'A'
                        msg_to_send(1)  <= x"3A"; -- ':'
                        msg_to_send(2)  <= to_ascii(addr(31 downto 28));
                        msg_to_send(3)  <= to_ascii(addr(27 downto 24));
                        msg_to_send(4)  <= to_ascii(addr(23 downto 20));
                        msg_to_send(5)  <= to_ascii(addr(19 downto 16));
                        msg_to_send(6)  <= to_ascii(addr(15 downto 12));
                        msg_to_send(7)  <= to_ascii(addr(11 downto 8));
                        msg_to_send(8)  <= to_ascii(addr(7 downto 4));
                        msg_to_send(9)  <= to_ascii(addr(3 downto 0));
                        msg_to_send(10) <= x"20"; -- ' '
                        msg_to_send(11) <= x"44"; -- 'D'
                        msg_to_send(12) <= x"3A"; -- ':'
                        msg_to_send(13) <= to_ascii(data(15 downto 12));
                        msg_to_send(14) <= to_ascii(data(11 downto 8));
                        msg_to_send(15) <= to_ascii(data(7 downto 4));
                        msg_to_send(16) <= to_ascii(data(3 downto 0));
                        msg_to_send(17) <= x"20"; -- ' '
                        msg_to_send(18) <= x"52"; -- 'R'
                        
                        if rw = '1' then 
                            msg_to_send(19) <= x"31"; -- '1'
                        else 
                            msg_to_send(19) <= x"30"; -- '0'
                        end if;
                        msg_to_send(20) <= x"0D"; -- CR
                        msg_to_send(21) <= x"0A"; -- LF
                        
                        busy_o <= '1';
                        state <= LATCH;
                    end if;

                when LATCH =>
                    -- Esperar 1 ciclo para que msg_to_send tenga valores validos
                    char_idx <= 0;
                    state <= NEXT_CHAR;

                when NEXT_CHAR =>
                    if char_idx < 22 then
                        uart_buffer <= msg_to_send(char_idx);
                        baud_cnt <= 0;
                        bit_idx <= 0;
                        state <= START_BIT;
                    else
                        state <= IDLE;
                    end if;

                when START_BIT =>
                    tx_pin <= '0';
                    if baud_cnt < BIT_TIME - 1 then
                        baud_cnt <= baud_cnt + 1;
                    else
                        baud_cnt <= 0;
                        state <= DATA_BITS;
                    end if;

                when DATA_BITS =>
                    tx_pin <= uart_buffer(bit_idx);
                    if baud_cnt < BIT_TIME - 1 then
                        baud_cnt <= baud_cnt + 1;
                    else
                        baud_cnt <= 0;
                        if bit_idx < 7 then
                            bit_idx <= bit_idx + 1;
                        else
                            state <= STOP_BIT;
                        end if;
                    end if;

                when STOP_BIT =>
                    tx_pin <= '1';
                    if baud_cnt < BIT_TIME - 1 then
                        baud_cnt <= baud_cnt + 1;
                    else
                        char_idx <= char_idx + 1;
                        state <= NEXT_CHAR;
                    end if;

            end case;
        end if;
    end process;

end Behavioral;
