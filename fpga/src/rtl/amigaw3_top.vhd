-------------------------------------------------
-- amigaw3_top.vhd  PASO 4 + ANALIZADOR LOGICO
--
-- Añade un analizador lógico en paralelo al sistema Amiga existente.
-- El sistema Amiga sigue funcionando exactamente igual.
-- El analizador usa un segundo UART (PL2303 conectado al PMOD J13).
--
-- Cambios respecto al original:
--   1. Nuevos puertos: ana_uart_tx, ana_uart_rx (al CP2102/PL2303)
--   2. Bus internal_signals(15:0) con 16 señales del Amiga sondadas
--   3. Instancias: probe_mux + logic_capture + uart_tx/rx (analizador)
--   4. FSM del protocolo de captura
--
-- Reloj: comparte clk_28m del AmigaW3 (28.375 MHz)
-- Baud:  921600 (PL2303 antiguo, máximo seguro)
-------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity amigaw3_top is
    Port (
        sys_clk_50M : in  std_logic;
        rst_n_i     : in  std_logic;
        uart_tx_o   : out std_logic;          -- UART 1: spy AmigaW3 (existente)
        leds        : out std_logic_vector(7 downto 0);
        hdmi_tx_p   : out std_logic_vector(3 downto 0);
        hdmi_tx_n   : out std_logic_vector(3 downto 0);
        -- UART 2: analizador logico (NUEVO)
        ana_uart_tx : out std_logic;          -- a RXD del PL2303
        ana_uart_rx : in  std_logic           -- a TXD del PL2303
    );
end amigaw3_top;

architecture Behavioral of amigaw3_top is

    -- Relojes
    signal clk_28m    : std_logic;
    signal clk_141m   : std_logic;
    signal pll_locked : std_logic;

    -- ... (todas las señales del top original sin cambios) ...

    -- Phi enables
    signal phi_cnt : unsigned(1 downto 0) := "00";
    signal en_phi1 : std_logic := '0';
    signal en_phi2 : std_logic := '0';

    signal system_ready : std_logic := '0';
    signal reset_cnt    : integer range 0 to 5000000 := 0;

    -- Bus CPU
    signal cpu_addr    : std_logic_vector(31 downto 0);
    signal cpu_as      : std_logic;
    signal cpu_uds     : std_logic;
    signal cpu_lds     : std_logic;
    signal cpu_rw      : std_logic;
    signal cpu_dtack   : std_logic := '1';
    signal cpu_data_in : std_logic_vector(15 downto 0);
    signal cpu_data_out: std_logic_vector(15 downto 0);
    signal cpu_halt    : std_logic;
    signal cpu_fc      : std_logic_vector(2 downto 0);
    signal cpu_vpa     : std_logic;

    signal rom_data    : std_logic_vector(15 downto 0);
    signal sel_rom     : std_logic;

    signal ram_data    : std_logic_vector(15 downto 0);
    signal sel_ram     : std_logic;
    signal ram_we      : std_logic_vector(1 downto 0);

    signal sel_ciaa    : std_logic;
    signal ciaa_data   : std_logic_vector(7 downto 0);
    signal ciab_data   : std_logic_vector(7 downto 0);
    signal ciab_irq    : std_logic;
    signal sel_ciab    : std_logic;
    signal ciaa_irq    : std_logic;

    signal sel_chipset : std_logic;
    signal intena      : std_logic_vector(14 downto 0) := (others => '0');
    signal intreq      : std_logic_vector(14 downto 0) := (others => '0');
    signal dmacon      : std_logic_vector(14 downto 0) := (others => '0');

    signal h_cnt      : integer range 0 to 1023 := 0;
    signal v_cnt      : integer range 0 to 1023 := 0;

    signal blt_dma_req : std_logic := '0';
    signal blt_gnt     : std_logic := '0';
    signal blt_busy    : std_logic := '0';
    signal blt_ram_addr_r : std_logic_vector(17 downto 1);
    signal blt_ram_addr_w : std_logic_vector(17 downto 1);
    signal blt_ram_data_w : std_logic_vector(15 downto 0);
    signal blt_ram_we_w   : std_logic_vector(1 downto 0);

    signal cop_dma_req : std_logic := '0';
    signal cop_gnt     : std_logic := '0';
    signal cop_ram_addr: std_logic_vector(17 downto 1);
    signal cop_reg_addr: std_logic_vector(8 downto 0);
    signal cop_reg_data: std_logic_vector(15 downto 0);
    signal cop_reg_we  : std_logic := '0';

    signal ram_addr_mux : std_logic_vector(17 downto 1);

    signal denise_r   : std_logic_vector(7 downto 0);
    signal denise_g   : std_logic_vector(7 downto 0);
    signal denise_b   : std_logic_vector(7 downto 0);
    signal vram_addr  : std_logic_vector(16 downto 0);
    signal vram_data  : std_logic_vector(15 downto 0);
    signal chipset_we : std_logic;
    signal chipset_addr : std_logic_vector(15 downto 0);
    signal chipset_data : std_logic_vector(15 downto 0);
    signal chipset_we2  : std_logic;
    signal vid_red    : std_logic_vector(7 downto 0) := (others => '0');
    signal vid_green  : std_logic_vector(7 downto 0) := (others => '0');
    signal vid_blue   : std_logic_vector(7 downto 0) := (others => '0');
    signal vid_hsync  : std_logic := '1';
    signal vid_vsync  : std_logic := '1';
    signal vid_blank  : std_logic := '1';

    signal beam_cnt    : integer range 0 to 283296 := 0;
    signal v_pos       : integer range 0 to 311 := 0;
    signal h_pos       : integer range 0 to 226 := 0;
    signal vblank      : std_logic := '0';
    signal vblank_pulse: std_logic := '0';
    signal vposr_reg   : std_logic_vector(15 downto 0) := (others => '0');
    signal vhposr_reg  : std_logic_vector(15 downto 0) := (others => '0');

    signal overlay     : std_logic := '1';
    signal bus_state   : integer range 0 to 3 := 0;
    signal bus_state_prev : integer range 0 to 3 := 0;

    signal uart_trigger : std_logic := '0';
    signal uart_rw      : std_logic := '1';
    signal uart_final_rw: std_logic;
    signal uart_tx_int  : std_logic := '1';
    signal uart_data    : std_logic_vector(15 downto 0) := (others => '0');
    signal uart_addr    : std_logic_vector(31 downto 0) := (others => '0');
    signal cop_trigger  : std_logic := '0';
    signal cop_uart_addr: std_logic_vector(31 downto 0) := (others => '0');
    signal cop_uart_data: std_logic_vector(15 downto 0) := (others => '0');
    signal uart_final_trigger : std_logic := '0';
    signal uart_final_addr    : std_logic_vector(31 downto 0) := (others => '0');
    signal uart_final_data    : std_logic_vector(15 downto 0) := (others => '0');
    signal counter      : unsigned(24 downto 0) := (others => '0');

    -- =================================================================
    -- ANALIZADOR LOGICO -- nuevas señales
    -- =================================================================
    constant CLK_HZ_ANA : integer := 28_375_000;     -- frecuencia exacta clk_28m
    --constant BAUD   : integer := 2_000_000;        -- max seguro PL2303 antiguo
    constant BAUD   : integer := 921_600;        -- FIXED: PL2303 máximo seguro
    constant THROTTLE : integer := 500;          -- evita desborde buffer Linux
    constant N_INT      : integer := 16;
    constant N_CH_ANA   : integer := 8;

    -- ╔════════════════════════════════════════════════════════════╗
    -- ║  CONSTANTE DE TEST - poner false para modo normal          ║
    -- ║  true  = envia byte 'A' cada 0.5s por UART2 (test rapido) ║
    -- ║  false = comportamiento normal (FSM responde a comandos)   ║
    -- ╚════════════════════════════════════════════════════════════╝
    constant TEST_UART  : boolean := false;
    constant TEST_PERIOD: integer := 14_187_500;  -- 0.5s a 28.375 MHz


    signal internal_signals : std_logic_vector(N_INT-1 downto 0);
    signal probes       : std_logic_vector(N_CH_ANA-1 downto 0);
    signal dummy_pmod  : std_logic_vector(N_CH_ANA-1 downto 0) := (others => '0');

    -- MUX configuration registers (escritos por comando 0x02 vía UART2)
    signal mux_ext_mask : std_logic_vector(N_CH_ANA-1 downto 0)   := (others => '0');
    signal mux_sel      : std_logic_vector(N_CH_ANA*4-1 downto 0) := (others => '0');

    -- UART2 signals
    signal rx_byte  : std_logic_vector(7 downto 0);
    signal rx_valid : std_logic;
    signal tx_byte  : std_logic_vector(7 downto 0) := (others => '0');
    signal tx_valid : std_logic := '0';
    signal tx_ready : std_logic;

    -- Logic capture interface
    signal cap_arm    : std_logic := '0';
    signal cap_test   : std_logic := '0';
    signal cap_ttype  : std_logic_vector(1 downto 0) := "00";
    signal cap_tch    : integer range 0 to 31 := 0;
    signal cap_tmask  : std_logic_vector(7 downto 0) := (others => '0');
    signal cap_tval   : std_logic_vector(7 downto 0) := (others => '0');
    signal cap_done   : std_logic;
    signal cap_busy   : std_logic;
    signal cap_rd_en  : std_logic := '0';
    signal cap_rd_addr: unsigned(15 downto 0) := (others => '0');
    signal cap_rd_data: std_logic_vector(7 downto 0);

    -- Diagnostico: stretch de rx_valid para verlo en LED
    constant RX_STRETCH : integer := 14_000_000;  -- 0.5s a 28 MHz
    signal rx_act     : integer range 0 to RX_STRETCH := 0;

    -- FSM del protocolo del analizador
    type fsm_t is (
        ST_IDLE,
        ST_CFG_MASK, ST_CFG_SEL,
        ST_RX, ST_ARM, ST_WAIT_IDLE, ST_WAIT_DONE,
        ST_H0, ST_H1, ST_H2, ST_H3, ST_H4, ST_H5, ST_H6, ST_H7,
        ST_PRELOAD, ST_SETTLE, ST_WAIT, ST_DATA,
        ST_F0, ST_F1, ST_CRC, ST_DONE
    );
    signal fsm    : fsm_t := ST_IDLE;
    signal next_fsm    : fsm_t := ST_IDLE;
    signal rx_idx : integer range 0 to 15 := 0;
    signal tx_cnt : unsigned(15 downto 0) := (others => '0');
    signal crc    : std_logic_vector(7 downto 0) := (others => '0');
    signal throttle_cnt  : integer range 0 to THROTTLE := 0;
    signal bus_state_v: std_logic_vector(1 downto 0);

begin

    -- =================================================
    -- RELOJES (sin cambios)
    -- =================================================
    inst_clocks : entity work.clk_wiz_0
    port map (
        clk_in1  => sys_clk_50M,
        reset    => not rst_n_i,
        clk_out1 => clk_28m,
        clk_out2 => clk_141m,
        locked   => pll_locked
    );

    -- =================================================
    -- PHI ENABLES (sin cambios)
    -- =================================================
    process(clk_28m)
    begin
        if rising_edge(clk_28m) then
            phi_cnt <= phi_cnt + 1;
            en_phi1 <= '0';
            en_phi2 <= '0';
            if phi_cnt = "00" then en_phi1 <= '1'; end if;
            if phi_cnt = "10" then en_phi2 <= '1'; end if;
            counter <= counter + 1;
        end if;
    end process;

    -- =================================================
    -- RESET (sin cambios)
    -- =================================================
    process(clk_28m, rst_n_i)
    begin
        if rst_n_i = '0' then
            reset_cnt    <= 0;
            system_ready <= '0';
            overlay      <= '1';
            bus_state_prev <= 0;
        elsif rising_edge(clk_28m) then
            if reset_cnt < 5000000 then
                reset_cnt    <= reset_cnt + 1;
                system_ready <= '0';
            else
                system_ready <= '1';
            end if;
            -- Track previous bus_state para detectar flanco de entrada a 3
            bus_state_prev <= bus_state;
            -- Bajar overlay SOLO en la TRANSICION a bus_state=3 (entrada al estado),
            -- no mientras estamos continuamente en bus_state=3
            if bus_state = 3 and bus_state_prev /= 3 and
               cpu_rw = '0' and
               cpu_addr(23 downto 12) = x"BFE" then
                overlay <= '0';
            end if;
        end if;
    end process;

    -- =================================================
    -- DECODIFICADOR DIRECCIONES (sin cambios)
    -- =================================================
    sel_ram <= '1' when cpu_addr(23 downto 18) = "000000" and
                        (overlay = '0' or cpu_rw = '0') else '0';
    sel_rom <= '1' when cpu_addr(23 downto 18) = "111111" else
               '1' when overlay = '1' and cpu_rw = '1' and
                        cpu_addr(23 downto 18) = "000000" else '0';
    ram_we(1) <= '1' when sel_ram='1' and cpu_rw='0' and
                          cpu_uds='0' and bus_state=3 else '0';
    ram_we(0) <= '1' when sel_ram='1' and cpu_rw='0' and
                          cpu_lds='0' and bus_state=3 else '0';
--    sel_ciaa    <= '1' when cpu_addr(23 downto 21) = "101" and cpu_addr(12) = '0' else '0';
--    sel_ciab    <= '1' when cpu_addr(23 downto 21) = "101" and cpu_addr(13) = '0' else '0';

    sel_ciaa <= '1' when cpu_addr(23 downto 13) = "10111111110" else '0'; -- 0xBFE***   FIX Posible Overlap CIA-A/CIA-B
    sel_ciab <= '1' when cpu_addr(23 downto 13) = "10111111101" else '0'; -- 0xBFD***  FIX Posible Overlap CIA-A/CIA-B
    
    sel_chipset <= '1' when cpu_addr(23 downto 16) = x"DF"  else '0';

    cop_gnt <= '1' when bus_state = 0 and cpu_as = '1' and blt_dma_req = '0' else '0';
    blt_gnt <= '1' when bus_state = 0 and cpu_as = '1' and cop_dma_req = '0' else '0';

    ram_addr_mux <= cop_ram_addr   when cop_gnt = '1' and cop_dma_req = '1' else
                    blt_ram_addr_r when blt_gnt = '1' and blt_dma_req = '1' else
                    cpu_addr(17 downto 1);

    chipset_we   <= '1' when sel_chipset = '1' and cpu_rw = '0' and bus_state = 3 else '0';
    chipset_addr <= x"F" & "000" & cop_reg_addr when cop_reg_we = '1' else cpu_addr(15 downto 0);
    chipset_data <= cop_reg_data when cop_reg_we = '1' else cpu_data_out;
    chipset_we2  <= cop_reg_we or chipset_we;

    cpu_vpa <= '0' when cpu_fc = "111" else '0' when sel_ciaa = '1' else '1';

    -- (resto del top original sin cambios -- bus state machine, mux datos,
    --  ROM, sd_loader, beam counter, video, intena/intreq, CIA-A,
    --  RAM, CPU, UART spy, denise, blitter, copper, HDMI, leds)
    -- ↓↓↓ todo igual al original ↓↓↓

    process(clk_28m, system_ready)
    begin
        if system_ready = '0' then
            bus_state <= 0; cpu_dtack <= '1';
        elsif rising_edge(clk_28m) then
            uart_trigger <= '0';
            if en_phi1 = '1' then
                case bus_state is
                    when 0 =>
                        cpu_dtack <= '1';
                        if cpu_as = '0' and cpu_fc /= "111" then bus_state <= 1; end if;
                    when 1 => bus_state <= 2;
                    when 2 =>
                        cpu_dtack <= '0';
                        if cpu_rw = '0' and cpu_addr(23 downto 14) = "0000000000" then
                            uart_trigger <= '1';
                            uart_addr    <= cpu_addr;
                            uart_data    <= cpu_data_out;
                            uart_rw      <= cpu_rw;       -- LATCHEAR rw
                        end if;
                        bus_state <= 3;
                    when 3 =>
                        cpu_dtack <= '0';
                        if cpu_as = '1' then cpu_dtack <= '1'; bus_state <= 0; end if;
                    when others => bus_state <= 0;
                end case;
            end if;
        end if;
    end process;

    cpu_data_in <= rom_data          when sel_rom     = '1' else
                   ram_data          when sel_ram     = '1' else
                   x"FF" & ciaa_data when sel_ciaa   = '1' else
                   ciab_data & x"FF" when sel_ciab   = '1' else
                   blt_busy & dmacon when sel_chipset = '1' and cpu_addr(8 downto 1) = x"01" else
                   '0' & intena      when sel_chipset = '1' and cpu_addr(8 downto 1) = x"0E" else
                   '0' & intreq      when sel_chipset = '1' and cpu_addr(8 downto 1) = x"0F" else
                   vposr_reg         when sel_chipset = '1' and cpu_addr(8 downto 1) = x"02" else
                   vhposr_reg        when sel_chipset = '1' and cpu_addr(8 downto 1) = x"03" else
                   x"0000"           when sel_chipset = '1' else
                   x"FFFF";

    inst_rom : entity work.rom_kickstart
        port map (clka=>clk_28m, addra=>cpu_addr(17 downto 1), douta=>rom_data);

    process(clk_28m, rst_n_i)
    begin
        if rst_n_i = '0' then
            h_pos <= 0; v_pos <= 0; vblank <= '0';
        elsif rising_edge(clk_28m) then
            if en_phi1 = '1' then
                if h_pos = 226 then
                    h_pos <= 0;
                    if v_pos = 311 then v_pos <= 0; else v_pos <= v_pos + 1; end if;
                else h_pos <= h_pos + 1; end if;
                if v_pos < 26 then vblank <= '1'; else vblank <= '0'; end if;
                if v_pos = 0 and h_pos = 0 then vblank_pulse <= '1';
                else                              vblank_pulse <= '0'; end if;
                vposr_reg  <= "0000000" & std_logic_vector(to_unsigned(v_pos, 9));
                vhposr_reg <= std_logic_vector(to_unsigned(v_pos mod 256, 8)) &
                              std_logic_vector(to_unsigned(h_pos, 8));
            end if;
        end if;
    end process;

    process(clk_28m)
    begin
        if rising_edge(clk_28m) then
            if h_cnt < 887 then h_cnt <= h_cnt + 1;
            else h_cnt <= 0;
                if v_cnt < 523 then v_cnt <= v_cnt + 1; else v_cnt <= 0; end if;
            end if;
        end if;
    end process;

    process(clk_28m)
    begin
        if rising_edge(clk_28m) then
            if h_cnt >= 186 and h_cnt < 210 then vid_hsync <= '0'; else vid_hsync <= '1'; end if;
            if v_cnt >= 476 and v_cnt < 478 then vid_vsync <= '0'; else vid_vsync <= '1'; end if;
            if h_cnt < 640 and v_cnt < 480 then
                vid_blank <= '0';
                vid_red <= denise_r; vid_green <= denise_g; vid_blue <= denise_b;
            else
                vid_blank <= '1';
                vid_red <= (others=>'0'); vid_green <= (others=>'0'); vid_blue <= (others=>'0');
            end if;
        end if;
    end process;

    process(clk_28m, rst_n_i)
    begin
        if rst_n_i = '0' then
            intena <= (others => '0'); intreq <= (others => '0'); dmacon <= (others => '0');
        elsif rising_edge(clk_28m) then
            if vblank_pulse = '1' then intreq(5) <= '1'; end if;
           -- if ciab_irq    = '1' then intreq(13) <= '1'; end if;  -- CIA-B → level 6
            if ciab_irq    = '1' then intreq(6) <= '1'; end if;  --FIX  INT6 correcto
            if chipset_we2 = '1' then
                case cpu_addr(8 downto 1) is
                    when x"4B" =>
                        if cpu_data_out(15)='1' then dmacon <= dmacon or  cpu_data_out(14 downto 0);
                        else                         dmacon <= dmacon and not cpu_data_out(14 downto 0); end if;
                    when x"4D" =>
                        if cpu_data_out(15)='1' then intena <= intena or  cpu_data_out(14 downto 0);
                        else                         intena <= intena and not cpu_data_out(14 downto 0); end if;
                    when x"4E" =>
                        if cpu_data_out(15)='1' then intreq <= intreq or  cpu_data_out(14 downto 0);
                        else                         intreq <= intreq and not cpu_data_out(14 downto 0); end if;
                    when others => null;
                end case;
            end if;
        end if;
    end process;

    inst_ciaa : entity work.Amiga_CIA
        port map (clk=>clk_28m, reset_n=>system_ready,
                  addr=>cpu_addr(11 downto 0),
                  data_in=>cpu_data_out(7 downto 0), data_out=>ciaa_data,
                  cs=>sel_ciaa, rw=>cpu_rw, is_cia_a=>'1', irq_out=>ciaa_irq);

    -- CIA-B (chip 8520) - byte alto del bus, dirección 0xBFD000
    inst_ciab : entity work.Amiga_CIA
        port map (clk=>clk_28m, reset_n=>system_ready,
                  addr=>cpu_addr(11 downto 0),
                  data_in=>cpu_data_out(15 downto 8), data_out=>ciab_data,
                  cs=>sel_ciab, rw=>cpu_rw, is_cia_a=>'0', irq_out=>ciab_irq);

    inst_ram : entity work.ram_chip
        port map (clka=>clk_28m, wea=>ram_we, addra=>ram_addr_mux,
                  dina=>cpu_data_out, douta=>ram_data,
                  clkb=>clk_28m, web=>blt_ram_we_w,
                  addrb=>blt_ram_addr_w when blt_busy='1' else vram_addr,
                  dinb=>blt_ram_data_w, doutb=>vram_data);

    inst_cpu : entity work.FX68K_Wrapper
        port map (CLK=>clk_28m, EN_PHI1=>en_phi1, EN_PHI2=>en_phi2,
                  RESET_IN=>system_ready,
                  AS_OUT=>cpu_as, RW_OUT=>cpu_rw,
                  UDS_OUT=>cpu_uds, LDS_OUT=>cpu_lds,
                  DTACK_IN=>cpu_dtack, VPA_IN=>cpu_vpa, BERR_IN=>'1',
                  FC_OUT=>cpu_fc,
--                  IPL_IN=>"001" when (intreq(13)='1' and intena(13)='1' and intena(14)='1') else  -- level 6 (CIA-B / external INT6)
--                          "100" when (intreq(5)='1' and intena(5)='1' and intena(14)='1') else   -- level 3 (vblank)
--                          "101" when (ciaa_irq='1' and intena(14)='1') else                      -- level 2 (CIA-A)
--                          "111",
                   -- FIX   Actualizar IPL_IN IPL_IN  
                   IPL_IN=>"001" when (intreq(6)='1' and intena(6)='1' and intena(14)='1') else  -- level 6 (CIA-B)
                          "100" when (intreq(5)='1' and intena(5)='1' and intena(14)='1') else   -- level 3 (vblank)
                           "011" when (intreq(3)='1' and intena(3)='1' and intena(14)='1') else -- level 2 (CIA-A) "111",
                           "111",
                  HALT_OUT=>cpu_halt,
                  ADDR_OUT=>cpu_addr, DATA_IN=>cpu_data_in, DATA_OUT=>cpu_data_out);

    process(clk_28m)
    begin
        if rising_edge(clk_28m) then
            cop_trigger <= '0';
            if cop_reg_we = '1' then
                cop_trigger   <= '1';
                cop_uart_addr <= x"00DFF0" & cop_reg_addr(7 downto 0);
                cop_uart_data <= cop_reg_data;
            end if;
        end if;
    end process;

    uart_final_trigger <= uart_trigger or cop_trigger;
    uart_final_addr    <= cop_uart_addr when cop_trigger = '1' else uart_addr;
    uart_final_data    <= cop_uart_data when cop_trigger = '1' else uart_data;
    uart_final_rw      <= '0' when cop_trigger = '1' else uart_rw;  -- '0' para Copper writes
    uart_tx_o          <= uart_tx_int;

    inst_uart : entity work.uart_debug_unit
        port map (clk=>clk_28m, trigger=>uart_final_trigger,
                  addr=>uart_final_addr, data=>uart_final_data,
                  rw=>uart_final_rw, as=>cpu_as, tx_pin=>uart_tx_int, busy_o=>open);

    inst_denise : entity work.Amiga_Denise
        port map (clk_7m=>clk_28m, reset_n=>system_ready,
                  addr=>chipset_addr, data_in=>chipset_data, sel_chipset=>'1',
                  we=>chipset_we2, h_cnt=>h_cnt, v_cnt=>v_cnt,
                  vram_addr=>vram_addr, vram_data=>vram_data,
                  red=>denise_r, green=>denise_g, blue=>denise_b);

    inst_blitter : entity work.Amiga_Blitter
        port map (clk=>clk_28m, reset_n=>system_ready,
                  cpu_addr=>cpu_addr(15 downto 0), cpu_data=>cpu_data_out,
                  cpu_as=>cpu_as, cpu_rw=>cpu_rw, gnt=>blt_gnt, dma_req=>blt_dma_req,
                  ram_addr_r=>blt_ram_addr_r, ram_data_r=>ram_data,
                  ram_addr_w=>blt_ram_addr_w, ram_data_w=>blt_ram_data_w,
                  ram_we_w=>blt_ram_we_w, busy=>blt_busy);

    inst_copper : entity work.Amiga_Copper
        port map (clk=>clk_28m, reset_n=>system_ready, gnt=>cop_gnt,
                  vblank=>vblank_pulse, dma_req=>cop_dma_req,
                  cpu_addr=>cpu_addr(15 downto 0), cpu_data=>cpu_data_out,
                  cpu_as=>cpu_as, cpu_rw=>cpu_rw, v_cnt=>v_cnt, h_cnt=>h_cnt,
                  ram_data=>ram_data, ram_addr=>cop_ram_addr,
                  reg_addr=>cop_reg_addr, reg_data=>cop_reg_data, reg_we=>cop_reg_we);

    video_out_inst : entity work.video_subsystem
        port map (pixel_clk=>clk_28m, serial_clk=>clk_141m, reset_n=>pll_locked,
                  red_in=>vid_red, green_in=>vid_green, blue_in=>vid_blue,
                  hsync_in=>vid_hsync, vsync_in=>vid_vsync, blank_in=>vid_blank,
                  hdmi_tx_p=>hdmi_tx_p, hdmi_tx_n=>hdmi_tx_n);

    -- LEDs: DIAGNOSTICO FSM ANALIZADOR
    leds(0) <= counter(24);                              -- heartbeat
    leds(1) <= '1' when rx_act > 0 else '0';             -- byte UART2 recibido
    leds(2) <= '1' when fsm /= ST_IDLE else '0';         -- FSM activo (no en IDLE)
    leds(3) <= '1' when fsm = ST_CFG_MASK or fsm = ST_CFG_SEL else '0';  -- recibiendo MUX
    leds(4) <= '1' when fsm = ST_RX else '0';            -- recibiendo ARM
    leds(5) <= cap_busy;                                 -- captura en curso
    leds(6) <= '1' when fsm = ST_DATA else '0';          -- enviando datos
    leds(7) <= pll_locked;                               -- PLL OK

    -- =================================================================
    -- ANALIZADOR LOGICO -- todo el bloque nuevo a partir de aqui
    -- =================================================================

    -- Bus de señales internas (16 disponibles -- ver tabla en .cfg)
    --   internal_0  = en_phi1            (clock effective de la CPU)
    --   internal_1  = system_ready       (sale del reset?)
    --   internal_2  = cpu_as             (Address Strobe activo bajo)
    --   internal_3  = cpu_rw             (1=read, 0=write)
    --   internal_4  = cpu_dtack          (1=no listo, 0=listo)
    --   internal_5  = bus_state(0)       (LSB FSM bus)
    --   internal_6  = bus_state(1)       (MSB FSM bus)
    --   internal_7  = sel_rom            (acceso a Kickstart)
    --   internal_8  = sel_ram            (acceso a Chip RAM)
    --   internal_9  = sel_ciaa           (acceso a CIA-A)
    --   internal_10 = overlay            (overlay activo)
    --   internal_11 = vblank_pulse       (referencia temporal)
    --   internal_12 = cpu_halt           (CPU colgada)
    --   internal_13 = ciaa_irq           (CIA genera IRQ)
    --   internal_14 = ram_we(0)          (escritura byte bajo RAM)
    --   internal_15 = ram_we(1)          (escritura byte alto RAM)
    bus_state_v <= std_logic_vector(to_unsigned(bus_state, 2));
    internal_signals(0)  <= en_phi1;
    internal_signals(1)  <= system_ready;
    internal_signals(2)  <= cpu_as;
    internal_signals(3)  <= cpu_rw;
    internal_signals(4)  <= cpu_dtack;
    internal_signals(5)  <= bus_state_v(0);
    internal_signals(6)  <= bus_state_v(1);
    internal_signals(7)  <= sel_rom;
    internal_signals(8)  <= sel_ram;
    internal_signals(9)  <= sel_ciaa;
    internal_signals(10) <= overlay;
    internal_signals(11) <= cpu_addr(20);    -- A20 (region 1MB)
    internal_signals(12) <= cpu_addr(22);    -- A22
    internal_signals(13) <= cpu_addr(23);    -- A23 (region 16MB high)
    internal_signals(14) <= ram_we(0);
    internal_signals(15) <= ram_we(1);

    -- UART2 para el analizador
--    inst_ana_uart_tx : entity work.uart_tx
--        generic map (CLK_HZ => CLK_HZ_ANA, BAUD => BAUD)
--        port map (clk=>clk_28m, rst_n=>pll_locked,
--                  data_in=>tx_byte, valid=>tx_valid,
--                  ready=>tx_ready, tx=>ana_uart_tx);
                  
     inst_ana_uart_tx : entity work.uart_tx
        generic map (CLK_HZ => CLK_HZ_ANA, BAUD => BAUD)
        port map (clk=>clk_28m, rst_n=>system_ready,
                  data_in=>tx_byte, valid=>tx_valid,
                  ready=>tx_ready, tx=>ana_uart_tx);

--    inst_ana_uart_rx : entity work.uart_rx
--        generic map (CLK_HZ => CLK_HZ_ANA, BAUD => BAUD)
--        port map (clk=>clk_28m, rst_n=>pll_locked,
--                  rx=>ana_uart_rx,
--                  data_out=>rx_byte, data_valid=>rx_valid);
 inst_ana_uart_rx : entity work.uart_rx
        generic map (CLK_HZ => CLK_HZ_ANA, BAUD => BAUD)
        port map (clk=>clk_28m, rst_n=>system_ready,
                  rx=>ana_uart_rx,
                  data_out=>rx_byte, data_valid=>rx_valid);

    -- MUX configurable por UART2
--    inst_ana_mux : entity work.probe_mux
--        generic map (N_CH => N_CH_ANA, N_INT => N_INT)
--        port map (clk=>clk_28m, rst_n=>pll_locked,
--                  pmod_pins => dummy_pmod,     -- sin pines externos por ahora
--                  internal_signals => internal_signals,
--                  ext_mask => mux_ext_mask, sel => mux_sel,
--                  probes => probes);

    inst_ana_mux : entity work.probe_mux
        generic map (N_CH => N_CH_ANA, N_INT => N_INT)
        port map (clk=>clk_28m, rst_n=>system_ready,
                  pmod_pins => dummy_pmod,     -- sin pines externos por ahora
                  internal_signals => internal_signals,
                  ext_mask => mux_ext_mask, sel => mux_sel,
                  probes => probes);

    -- Capturador
    inst_ana_capture : entity work.logic_capture
        generic map (N_CH => N_CH_ANA, DEPTH => 8192, CLK_HZ => CLK_HZ_ANA)
        --port map (clk_sample=>clk_28m, rst_n=>pll_locked,
        port map (clk_sample=>clk_28m, rst_n=>system_ready, -- FIX SINCRONIZAR Reset Signal Mismatch en UART  
                  probes=>probes,
                  arm=>cap_arm, test_mode=>cap_test,
                  trig_type=>cap_ttype, trig_ch=>cap_tch,
                  trig_mask=>cap_tmask, trig_val=>cap_tval,
                  capture_done=>cap_done, busy=>cap_busy,
                  rd_en=>cap_rd_en, rd_addr=>cap_rd_addr, rd_data=>cap_rd_data);

    -- Diagnostico: alarga rx_valid para ser visible en LED
    process(clk_28m)
    begin
        if rising_edge(clk_28m) then
            if rx_valid = '1' then
                rx_act <= RX_STRETCH;
            elsif rx_act > 0 then
                rx_act <= rx_act - 1;
            end if;
        end if;
    end process;

    -- FSM protocolo analizador (idéntica a top_analisis.vhd)
    -- Si TEST_UART=true se ignora la FSM y se envía 'A' continuo
    process(clk_28m)
        variable test_cnt : integer range 0 to TEST_PERIOD := 0;
    begin
        if rising_edge(clk_28m) then
            tx_valid <= '0';
            cap_arm      <= '0';
            cap_rd_en    <= '0';

         if TEST_UART then
            -- ── TEST ECO: cada byte recibido se reenvía ─────────────
            -- Verifica RX y TX juntos. Si funciona → problema en FSM.
            if rx_valid = '1' and tx_ready = '1' then
                tx_byte  <= rx_byte;
                tx_valid <= '1';
            end if;
         else
            -- ── FSM normal ─────────────────────────────────────────
            case fsm is
                when ST_IDLE =>
                    if rx_valid = '1' then
                        case rx_byte is
                            when x"02" => rx_idx<=0; fsm<=ST_CFG_MASK;
                            when x"01" => rx_idx<=0; fsm<=ST_RX;
                            when others => null;
                        end case;
                    end if;

                when ST_CFG_MASK =>
                    if rx_valid = '1' then
                        mux_ext_mask <= rx_byte;
                        rx_idx   <= 0;
                        fsm      <= ST_CFG_SEL;
                    end if;

                when ST_CFG_SEL =>
                    if rx_valid = '1' then
                        if rx_byte = x"A5" then
                            fsm <= ST_IDLE;
                        elsif rx_idx < N_CH_ANA then
                            mux_sel(rx_idx*4+3 downto rx_idx*4) <= rx_byte(3 downto 0);
                            rx_idx <= rx_idx + 1;
                        end if;
                    end if;

                when ST_RX =>
                    if rx_valid = '1' then
                        case rx_idx is
                            when 0 => cap_test  <= rx_byte(0);
                            when 1 => cap_ttype <= rx_byte(1 downto 0);
                            when 2 => cap_tch   <= to_integer(unsigned(rx_byte(4 downto 0)));
                            when 3 => cap_tmask <= rx_byte;
                            when 4 => cap_tval  <= rx_byte;
                            when others => null;
                        end case;
--                        if rx_idx = 7 then
--                            if rx_byte = x"A5" then fsm <= ST_ARM;
--                            else                        fsm <= ST_IDLE; end if;
--                            rx_idx <= 0;
--                        else rx_idx <= rx_idx + 1; end if;
                       if rx_idx = 7 then
                            rx_idx <= 0;  -- FIXED: limpiar SIEMPRE
                            if rx_byte = x"A5" then fsm <= ST_ARM;
                            else                    fsm <= ST_IDLE; end if;
                        else rx_idx <= rx_idx + 1; end if;
                    end if;

                when ST_ARM =>
                    cap_arm   <= '1';
                    crc   <= (others => '0');
                    tx_cnt<= (others => '0');
                    fsm   <= ST_WAIT_IDLE;

                when ST_WAIT_IDLE =>
                    if cap_done = '0' then fsm <= ST_WAIT_DONE; end if;

                when ST_WAIT_DONE =>
                    if cap_done = '1' then fsm <= ST_H0; end if;

                when ST_H0 => if tx_ready='1' then tx_byte<=x"A5"; tx_valid<='1';
                                throttle_cnt<=THROTTLE; next_fsm<=ST_H1; fsm<=ST_WAIT; end if;
                when ST_H1 => if tx_ready='1' then tx_byte<=x"5A"; tx_valid<='1';
                                throttle_cnt<=THROTTLE; next_fsm<=ST_H2; fsm<=ST_WAIT; end if;
                when ST_H2 => if tx_ready='1' then tx_byte<=x"08"; tx_valid<='1';
                                throttle_cnt<=THROTTLE; next_fsm<=ST_H3; fsm<=ST_WAIT; end if;
                when ST_H3 => if tx_ready='1' then tx_byte<=x"00"; tx_valid<='1';
                                throttle_cnt<=THROTTLE; next_fsm<=ST_H4; fsm<=ST_WAIT; end if;
                when ST_H4 => if tx_ready='1' then tx_byte<=x"00"; tx_valid<='1';
                                throttle_cnt<=THROTTLE; next_fsm<=ST_H5; fsm<=ST_WAIT; end if;
                when ST_H5 => if tx_ready='1' then tx_byte<=x"20"; tx_valid<='1';
                                throttle_cnt<=THROTTLE; next_fsm<=ST_H6; fsm<=ST_WAIT; end if;
                when ST_H6 => if tx_ready='1' then tx_byte<=x"00"; tx_valid<='1';
                                throttle_cnt<=THROTTLE; next_fsm<=ST_H7; fsm<=ST_WAIT; end if;
                when ST_H7 => if tx_ready='1' then tx_byte<=x"00"; tx_valid<='1';
                                cap_rd_en<='1'; cap_rd_addr<=(others=>'0');
                                throttle_cnt<=THROTTLE; next_fsm<=ST_PRELOAD; fsm<=ST_WAIT; end if;

                --when ST_PRELOAD => fsm <= ST_SETTLE;
                when ST_PRELOAD => 
                    cap_rd_en <= '1';  -- FIXED: pre-lectura para compensar latencia BRAM
                    cap_rd_addr <= (others => '0');  -- FIXED: inicio garantizado
                    fsm <= ST_SETTLE;
                when ST_SETTLE  => tx_cnt<=(others=>'0'); fsm<=ST_DATA;

                when ST_DATA =>
                    if tx_ready='1' then
                        tx_byte <= cap_rd_data; tx_valid <= '1';
                        crc <= crc xor cap_rd_data;
                        if tx_cnt = 8191 then next_fsm <= ST_F0;
                        else cap_rd_en <= '1'; cap_rd_addr <= tx_cnt + 1; next_fsm <= ST_DATA; end if;
                        tx_cnt <= tx_cnt + 1;
                        throttle_cnt <= THROTTLE; fsm <= ST_WAIT;
                    end if;

                when ST_WAIT =>
                    if throttle_cnt = 0 then fsm <= next_fsm;
                    else throttle_cnt <= throttle_cnt - 1; end if;

                when ST_F0 => if tx_ready='1' then tx_byte<=x"DE"; tx_valid<='1';
                                throttle_cnt<=THROTTLE; next_fsm<=ST_F1; fsm<=ST_WAIT; end if;
                when ST_F1 => if tx_ready='1' then tx_byte<=x"AD"; tx_valid<='1';
                                throttle_cnt<=THROTTLE; next_fsm<=ST_CRC; fsm<=ST_WAIT; end if;
                when ST_CRC => if tx_ready='1' then tx_byte<=crc; tx_valid<='1';
                                 throttle_cnt<=THROTTLE; next_fsm<=ST_DONE; fsm<=ST_WAIT; end if;

                when ST_DONE =>
                    if tx_ready='1' then fsm <= ST_IDLE; end if;
                when others => fsm <= ST_IDLE;  -- FIXED: estado seguro
            end case;
         end if;  -- TEST_UART
        end if;
    end process;

end Behavioral;
