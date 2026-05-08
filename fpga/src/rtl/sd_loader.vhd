---------------------------------------------------
-- sd_loader.vhd  TEST MINIMO
-- Solo escribe patron fijo en BRAM ROM
-- Sin SD, sin reset complejo
-- Para verificar que la escritura en BRAM funciona
---------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity sd_loader is
    Port (
        clk_i        : in  std_logic;
        rst_i        : in  std_logic;
        cpu_reset_o  : out std_logic;
        rom_wr_addr_o: out std_logic_vector(16 downto 0);
        rom_wr_data_o: out std_logic_vector(15 downto 0);
        rom_wr_en_o  : out std_logic_vector(0 downto 0);
        sd_miso_i    : in  std_logic;
        sd_mosi_o    : out std_logic;
        sd_sck_o     : out std_logic;
        sd_cs_n_o    : out std_logic;
        dbg_state_o  : out std_logic_vector(2 downto 0)
    );
end sd_loader;

architecture Behavioral of sd_loader is

    signal cnt      : integer range 0 to 15 := 0;
    signal done     : std_logic := '0';
    signal wait_cnt : integer range 0 to 1000 := 0;

    -- Patron KS 1.3 primeras 8 words
    type rom8_t is array(0 to 7) of std_logic_vector(15 downto 0);
    constant KS_PATTERN : rom8_t := (
        x"1114", x"4EF9", x"00FC", x"00D2",
        x"0000", x"FFFF", x"0022", x"0005"
    );

begin

    sd_mosi_o   <= '1';
    sd_sck_o    <= '0';
    sd_cs_n_o   <= '1';
    cpu_reset_o <= not done;
    dbg_state_o <= "111" when done = '1' else "001";

    process(clk_i)
    begin
        if rising_edge(clk_i) then
            rom_wr_en_o <= "0";

            if rst_i = '1' then
                cnt      <= 0;
                done     <= '0';
                wait_cnt <= 0;
            elsif done = '0' then
                if wait_cnt < 100 then
                    -- Esperar 100 ciclos antes de escribir
                    wait_cnt <= wait_cnt + 1;
                elsif cnt < 8 then
                    -- Escribir palabra
                    rom_wr_addr_o <= std_logic_vector(to_unsigned(cnt, 17));
                    rom_wr_data_o <= KS_PATTERN(cnt);
                    rom_wr_en_o   <= "1";
                    cnt           <= cnt + 1;
                else
                    done <= '1';
                end if;
            end if;
        end if;
    end process;

end Behavioral;
