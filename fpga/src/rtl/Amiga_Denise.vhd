---------------------------------------------------
-- FICHERO COMPLETO: Amiga_Denise.vhd
-- RESOLUCION: Decodificación directa a 0x01XX
---------------------------------------------------

-- ==========================================================
-- [BLOQUE 1: LIBRERIAS Y ENTIDAD]
-- ==========================================================
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity Amiga_Denise is
    Port ( 
        clk_7m      : in  STD_LOGIC;
        reset_n     : in  STD_LOGIC;
        addr        : in  STD_LOGIC_VECTOR(15 downto 0);
        data_in     : in  STD_LOGIC_VECTOR(15 downto 0);
        sel_chipset : in  STD_LOGIC;
        we          : in  STD_LOGIC;
        h_cnt       : in  INTEGER;
        v_cnt       : in  INTEGER;
        vram_addr   : out STD_LOGIC_VECTOR(16 downto 0);
        vram_data   : in  STD_LOGIC_VECTOR(15 downto 0);
        red         : out STD_LOGIC_VECTOR(7 downto 0);
        green       : out STD_LOGIC_VECTOR(7 downto 0);
        blue        : out STD_LOGIC_VECTOR(7 downto 0)
    );
end Amiga_Denise;

architecture Behavioral of Amiga_Denise is

-- ==========================================================
-- [BLOQUE 2: SEÑALES INTERNAS Y REGISTROS]
-- ==========================================================
    signal bpl1pth : std_logic_vector(15 downto 0) := (others => '0');
    signal bpl1ptl : std_logic_vector(15 downto 0) := (others => '0');
    signal bpl2pth : std_logic_vector(15 downto 0) := (others => '0');
    signal bpl2ptl : std_logic_vector(15 downto 0) := (others => '0');
    signal bpl3pth : std_logic_vector(15 downto 0) := (others => '0');
    signal bpl3ptl : std_logic_vector(15 downto 0) := (others => '0');
    signal bpl4pth : std_logic_vector(15 downto 0) := (others => '0');
    signal bpl4ptl : std_logic_vector(15 downto 0) := (others => '0');

    signal bplcon0 : std_logic_vector(15 downto 0) := (others => '0');

    type palette_t is array (0 to 15) of std_logic_vector(11 downto 0);
    signal palette_ram : palette_t := (others => x"000");

    signal fp1 : unsigned(18 downto 0) := (others => '0');
    signal fp2 : unsigned(18 downto 0) := (others => '0');
    signal fp3 : unsigned(18 downto 0) := (others => '0');
    signal fp4 : unsigned(18 downto 0) := (others => '0');

    signal next1 : std_logic_vector(15 downto 0) := (others => '0');
    signal next2 : std_logic_vector(15 downto 0) := (others => '0');
    signal next3 : std_logic_vector(15 downto 0) := (others => '0');
    signal next4 : std_logic_vector(15 downto 0) := (others => '0');
    
    signal sh1 : std_logic_vector(15 downto 0) := (others => '0');
    signal sh2 : std_logic_vector(15 downto 0) := (others => '0');
    signal sh3 : std_logic_vector(15 downto 0) := (others => '0');
    signal sh4 : std_logic_vector(15 downto 0) := (others => '0');

    signal tick_cnt  : unsigned(1 downto 0) := "00";
    signal ena_pixel : std_logic := '0';

    signal fetch_phase  : integer range 0 to 6 := 0;
    signal pix_in_block : integer range 0 to 15 := 0;

begin

-- ==========================================================
-- [BLOQUE 3: ESCRITURA DE REGISTROS CHIPSET]
-- ==========================================================
    process(clk_7m)
        variable color_idx : integer range 0 to 15;
    begin
        if rising_edge(clk_7m) then
            if sel_chipset = '1' and we = '1' then
                
                -- [FIX-A] Usar addr(8 downto 1) como offset
                -- Acepta tanto 0x0100 (tester) como 0xF100 (sistema real)
                -- addr(8:1) para BPLCON0: 0x100>>1=0x80
                -- addr(8:1) para BPL1PTH: 0x110>>1=0x88
                -- addr(8:1) para COLOR00:  0x180>>1=0xC0
                case addr(8 downto 1) is
                    when x"80" =>  -- BPLCON0
                        bplcon0 <= data_in;
                    when x"88" =>  -- BPL1PTH
                        bpl1pth <= data_in;
                    when x"89" =>  -- BPL1PTL
                        bpl1ptl <= data_in;
                    when x"8A" =>  -- BPL2PTH
                        bpl2pth <= data_in;
                    when x"8B" =>  -- BPL2PTL
                        bpl2ptl <= data_in;
                    when x"8C" =>  -- BPL3PTH
                        bpl3pth <= data_in;
                    when x"8D" =>  -- BPL3PTL
                        bpl3ptl <= data_in;
                    when x"8E" =>  -- BPL4PTH
                        bpl4pth <= data_in;
                    when x"8F" =>  -- BPL4PTL
                        bpl4ptl <= data_in;
                    when others =>
                        -- COLOR00-COLOR15: offset 0xC0-0xCF
                        -- addr(8:1) para COLOR00=0x180>>1=0xC0
                        if addr(8 downto 5) = "1100" then
                            color_idx := to_integer(unsigned(addr(4 downto 1)));
                            palette_ram(color_idx) <= data_in(11 downto 0);
                        end if;
                end case;
            end if;
        end if;
    end process;

-- ==========================================================
-- [BLOQUE 4: GENERADOR DE ENABLE DE PÍXEL]
-- ==========================================================
    process(clk_7m)
    begin
        if rising_edge(clk_7m) then
            tick_cnt <= tick_cnt + 1;
            if tick_cnt = "11" then
                ena_pixel <= '1';
            else
                ena_pixel <= '0';
            end if;
        end if;
    end process;

-- ==========================================================
-- [BLOQUE 5: PIPELINE DE FETCH Y SALIDA]
-- ==========================================================
    process(clk_7m)
        variable pv : std_logic_vector(3 downto 0);
        variable co : std_logic_vector(11 downto 0);
        variable planes_enabled : integer range 0 to 4;
        variable vfp1 : unsigned(18 downto 0);
        variable vfp2 : unsigned(18 downto 0);
        variable vfp3 : unsigned(18 downto 0);
        variable vfp4 : unsigned(18 downto 0);
    begin
        if rising_edge(clk_7m) then
            if reset_n = '0' then
                fp1 <= (others => '0');
                fp2 <= (others => '0');
                fp3 <= (others => '0');
                fp4 <= (others => '0');
                sh1 <= (others => '0');
                sh2 <= (others => '0');
                sh3 <= (others => '0');
                sh4 <= (others => '0');
                next1 <= (others => '0');
                next2 <= (others => '0');
                next3 <= (others => '0');
                next4 <= (others => '0');
                fetch_phase <= 0;
                pix_in_block <= 0;
                red   <= (others => '0');
                green <= (others => '0');
                blue  <= (others => '0');
                vram_addr <= (others => '0');

            elsif ena_pixel = '1' then

                planes_enabled := to_integer(unsigned(bplcon0(14 downto 12)));
                if planes_enabled > 4 then
                    planes_enabled := 4;
                end if;

                if h_cnt = 0 then
                    vfp1 := unsigned(bpl1pth(2 downto 0)) & unsigned(bpl1ptl);
                    vfp2 := unsigned(bpl2pth(2 downto 0)) & unsigned(bpl2ptl);
                    vfp3 := unsigned(bpl3pth(2 downto 0)) & unsigned(bpl3ptl);
                    vfp4 := unsigned(bpl4pth(2 downto 0)) & unsigned(bpl4ptl);

                    fp1 <= vfp1;
                    fp2 <= vfp2;
                    fp3 <= vfp3;
                    fp4 <= vfp4;

                    fetch_phase <= 0;
                    pix_in_block <= 0;

                    sh1 <= (others => '0');
                    sh2 <= (others => '0');
                    sh3 <= (others => '0');
                    sh4 <= (others => '0');

                    vram_addr <= std_logic_vector(vfp1(16 downto 0));
                end if;

                -- Pipeline con latencia BRAM: addr en fase N, dato disponible en fase N+1
                case fetch_phase is
                    when 0 =>
                        -- vram_addr ya apunta a fp1, esperar dato
                        fetch_phase <= 1;
                    when 1 =>
                        -- dato de fp1 disponible
                        next1 <= vram_data;
                        vram_addr <= std_logic_vector(fp2(16 downto 0));
                        fetch_phase <= 2;
                    when 2 =>
                        next2 <= vram_data;
                        vram_addr <= std_logic_vector(fp3(16 downto 0));
                        fetch_phase <= 3;
                    when 3 =>
                        next3 <= vram_data;
                        vram_addr <= std_logic_vector(fp4(16 downto 0));
                        fetch_phase <= 4;
                    when 4 =>
                        next4 <= vram_data;
                        fetch_phase <= 5;
                    when 5 =>
                        sh1 <= next1;
                        sh2 <= next2;
                        sh3 <= next3;
                        sh4 <= next4;
                        fp1 <= fp1 + 1;
                        fp2 <= fp2 + 1;
                        fp3 <= fp3 + 1;
                        fp4 <= fp4 + 1;
                        fetch_phase <= 6;
                    when others =>
                        null;
                end case;

                if h_cnt < 640 and v_cnt < 480 then
                    pv := "0000";

                    if planes_enabled >= 1 then pv(0) := sh1(15); end if;
                    if planes_enabled >= 2 then pv(1) := sh2(15); end if;
                    if planes_enabled >= 3 then pv(2) := sh3(15); end if;
                    if planes_enabled >= 4 then pv(3) := sh4(15); end if;

                    co := palette_ram(to_integer(unsigned(pv)));

                    red   <= co(11 downto 8) & co(11 downto 8);
                    green <= co(7 downto 4)  & co(7 downto 4);
                    blue  <= co(3 downto 0)  & co(3 downto 0);

                    if fetch_phase /= 4 then
                        sh1 <= sh1(14 downto 0) & '0';
                        sh2 <= sh2(14 downto 0) & '0';
                        sh3 <= sh3(14 downto 0) & '0';
                        sh4 <= sh4(14 downto 0) & '0';
                    end if;
                else
                    red   <= (others => '0');
                    green <= (others => '0');
                    blue  <= (others => '0');
                end if;

                if pix_in_block = 15 then
                    pix_in_block <= 0;
                    vram_addr <= std_logic_vector(fp1(16 downto 0));
                    fetch_phase <= 0;
                else
                    pix_in_block <= pix_in_block + 1;
                end if;

            end if;
        end if;
    end process;

end Behavioral;