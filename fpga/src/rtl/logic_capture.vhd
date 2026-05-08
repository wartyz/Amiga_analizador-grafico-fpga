--------------------------------------------------------------------------------
-- logic_capture.vhd  --  Capturador logico reutilizable
--
-- Todo corre en clk_sample (85 MHz). Sin CDC.
--
-- Genericos:
--   N_CH   : canales (8, escalable a 16/32)
--   DEPTH  : muestras del buffer (65536)
--   CLK_HZ : frecuencia del reloj
--
-- trig_type: 00=manual 01=rising 10=falling 11=pattern
--------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity logic_capture is
    generic (
        N_CH   : integer := 8;
        DEPTH  : integer := 65536;
        CLK_HZ : integer := 85_000_000
    );
    port (
        clk_sample   : in  std_logic;
        rst_n        : in  std_logic;
        probes       : in  std_logic_vector(N_CH-1 downto 0);
        -- Control
        arm          : in  std_logic;
        test_mode    : in  std_logic;
        trig_type    : in  std_logic_vector(1 downto 0);
        trig_ch      : in  integer range 0 to 31;
        trig_mask    : in  std_logic_vector(N_CH-1 downto 0);
        trig_val     : in  std_logic_vector(N_CH-1 downto 0);
        -- Estado
        capture_done : out std_logic;
        busy         : out std_logic;
        -- Lectura BRAM
        rd_en        : in  std_logic;
        rd_addr      : in  unsigned(15 downto 0);
        rd_data      : out std_logic_vector(N_CH-1 downto 0)
    );
end entity logic_capture;

architecture rtl of logic_capture is

    type bram_t is array (0 to DEPTH-1) of std_logic_vector(N_CH-1 downto 0);
    signal bram : bram_t;

    type state_t is (S_IDLE, S_ARMED, S_CAPTURING, S_DONE);
    signal state : state_t := S_IDLE;

    signal wr_addr : unsigned(15 downto 0) := (others => '0');
    signal wr_en   : std_logic := '0';
    signal wr_data : std_logic_vector(N_CH-1 downto 0);

    -- Generador de test: contador binario
    signal test_cnt : unsigned(N_CH-1 downto 0) := (others => '0');
    signal sample   : std_logic_vector(N_CH-1 downto 0);
    signal prev     : std_logic_vector(N_CH-1 downto 0) := (others => '0');
    signal trig_hit : std_logic;

    -- Detector de flanco de arm (evita capturar multiples veces si arm dura varios ciclos)
    signal arm_prev : std_logic := '0';
    signal arm_rise : std_logic;

begin

    -- Generador test
    process(clk_sample)
    begin
        if rising_edge(clk_sample) then
            test_cnt <= test_cnt + 1;
        end if;
    end process;

    sample   <= std_logic_vector(test_cnt) when test_mode = '1' else probes;
    arm_rise <= arm and (not arm_prev);

    -- Trigger
    process(sample, prev, trig_type, trig_ch, trig_mask, trig_val)
        variable b_now  : std_logic;
        variable b_prev : std_logic;
    begin
        b_now  := sample(trig_ch mod N_CH);
        b_prev := prev(trig_ch mod N_CH);
        case trig_type is
            when "00"   => trig_hit <= '1';
            when "01"   => trig_hit <= (not b_prev) and b_now;
            when "10"   => trig_hit <= b_prev and (not b_now);
            when others =>
                if (sample and trig_mask) = (trig_val and trig_mask) then
                    trig_hit <= '1';
                else
                    trig_hit <= '0';
                end if;
        end case;
    end process;

    -- FSM
    process(clk_sample)
    begin
        if rising_edge(clk_sample) then
            if rst_n = '0' then
                state        <= S_IDLE;
                wr_addr      <= (others => '0');
                wr_en        <= '0';
                capture_done <= '0';
                busy         <= '0';
                prev         <= (others => '0');
                arm_prev     <= '0';
            else
                arm_prev <= arm;
                prev     <= sample;
                wr_en    <= '0';

                case state is
                    when S_IDLE =>
                        capture_done <= '0';
                        busy         <= '0';
                        wr_addr      <= (others => '0');
                        if arm_rise = '1' then
                            state <= S_ARMED;
                            busy  <= '1';
                        end if;

                    when S_ARMED =>
                        if trig_hit = '1' then
                            state   <= S_CAPTURING;
                            wr_en   <= '1';
                            wr_data <= sample;
                            wr_addr <= (others => '0');
                        end if;

                    when S_CAPTURING =>
                        wr_en   <= '1';
                        wr_data <= sample;
                        if wr_addr = DEPTH - 1 then
                            wr_en        <= '0';
                            state        <= S_DONE;
                            capture_done <= '1';
                            busy         <= '0';
                        else
                            wr_addr <= wr_addr + 1;
                        end if;

                    when S_DONE =>
                        capture_done <= '1';
                        if arm_rise = '1' then
                            capture_done <= '0';
                            state        <= S_ARMED;
                            busy         <= '1';
                            wr_addr      <= (others => '0');
                        end if;
                end case;
            end if;
        end if;
    end process;

    -- BRAM dual-port simple (1 ciclo de latencia en lectura)
    process(clk_sample)
    begin
        if rising_edge(clk_sample) then
            if wr_en = '1' then
                bram(to_integer(wr_addr)) <= wr_data;
            end if;
            if rd_en = '1' then
                rd_data <= bram(to_integer(rd_addr));
            end if;
        end if;
    end process;

end architecture rtl;
