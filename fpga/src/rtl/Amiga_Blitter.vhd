---------------------------------------------------
-- Amiga_Blitter.vhd  VERSION 2.0 COMPLETO
-- Implementa los 4 canales A,B,C,D con LF completa
-- y First/Last word masks
--
-- BLTCON0:
--   bits 15:12 = ASHIF (shift A)
--   bit  11    = USE_A
--   bit  10    = USE_B
--   bit   9    = USE_C
--   bit   8    = USE_D
--   bits  7:0  = LF (funcion logica minterm)
--
-- BLTCON1:
--   bits 15:12 = BSHIF (shift B)
--   bit   1    = DESC  (decrement mode)
--   bit   0    = FILL  (fill mode, ignorado)
--
-- Registros:
--   DFF040 BLTCON0
--   DFF042 BLTCON1
--   DFF044 BLTAFWM  first word mask A
--   DFF046 BLTALWM  last word mask A
--   DFF048 BLTCPTH/L  source C
--   DFF04C BLTBPTH/L  source B
--   DFF050 BLTAPTH/L  source A
--   DFF054 BLTDPTH/L  dest D
--   DFF058 BLTSIZE    disparo
--   DFF060 BLTCMOD
--   DFF062 BLTBMOD
--   DFF064 BLTAMOD
--   DFF066 BLTDMOD
--   DFF070 BLTCDAT
--   DFF072 BLTBDAT
--   DFF074 BLTADAT
---------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity Amiga_Blitter is
    Port (
        clk      : in  STD_LOGIC;
        reset_n  : in  STD_LOGIC;
        cpu_addr : in  STD_LOGIC_VECTOR(15 downto 0);
        cpu_data : in  STD_LOGIC_VECTOR(15 downto 0);
        cpu_as   : in  STD_LOGIC;
        cpu_rw   : in  STD_LOGIC;
        gnt      : in  STD_LOGIC;
        dma_req  : out STD_LOGIC;
        ram_addr_r : out STD_LOGIC_VECTOR(17 downto 1);
        ram_data_r : in  STD_LOGIC_VECTOR(15 downto 0);
        ram_addr_w : out STD_LOGIC_VECTOR(17 downto 1);
        ram_data_w : out STD_LOGIC_VECTOR(15 downto 0);
        ram_we_w   : out STD_LOGIC_VECTOR(1 downto 0);
        busy     : out STD_LOGIC
    );
end Amiga_Blitter;

architecture Behavioral of Amiga_Blitter is

    -- Registros de control
    signal bltcon0 : std_logic_vector(15 downto 0) := (others => '0');
    signal bltcon1 : std_logic_vector(15 downto 0) := (others => '0');
    signal bltafwm : std_logic_vector(15 downto 0) := x"FFFF";
    signal bltalwm : std_logic_vector(15 downto 0) := x"FFFF";

    -- Punteros fuente/destino
    signal bltapt  : unsigned(23 downto 0) := (others => '0');
    signal bltbpt  : unsigned(23 downto 0) := (others => '0');
    signal bltcpt  : unsigned(23 downto 0) := (others => '0');
    signal bltdpt  : unsigned(23 downto 0) := (others => '0');

    -- Modulos
    signal bltamod : signed(15 downto 0) := (others => '0');
    signal bltbmod : signed(15 downto 0) := (others => '0');
    signal bltcmod : signed(15 downto 0) := (others => '0');
    signal bltdmod : signed(15 downto 0) := (others => '0');

    -- Datos precargados
    signal bltadat : std_logic_vector(15 downto 0) := (others => '0');
    signal bltbdat : std_logic_vector(15 downto 0) := (others => '0');
    signal bltcdat : std_logic_vector(15 downto 0) := (others => '0');

    -- Tamaño
    signal blt_h   : unsigned(9 downto 0) := (others => '0');
    signal blt_w   : unsigned(5 downto 0) := (others => '0');

    -- Contadores
    signal cur_x   : unsigned(5 downto 0) := (others => '0');
    signal cur_y   : unsigned(9 downto 0) := (others => '0');

    -- Flags de canal activo
    signal use_a   : std_logic := '0';
    signal use_b   : std_logic := '0';
    signal use_c   : std_logic := '0';
    signal use_d   : std_logic := '0';
    signal desc    : std_logic := '0';

    -- Shift registers para A y B
    signal a_hold  : std_logic_vector(15 downto 0) := (others => '0');
    signal b_hold  : std_logic_vector(15 downto 0) := (others => '0');
    signal a_shift : unsigned(3 downto 0) := (others => '0');
    signal b_shift : unsigned(3 downto 0) := (others => '0');

    -- Datos de trabajo
    signal a_data  : std_logic_vector(15 downto 0) := (others => '0');
    signal b_data  : std_logic_vector(15 downto 0) := (others => '0');
    signal c_data  : std_logic_vector(15 downto 0) := (others => '0');
    signal d_data  : std_logic_vector(15 downto 0) := (others => '0');
    signal a_masked: std_logic_vector(15 downto 0) := (others => '0');

    -- FSM
    type state_t is (
        IDLE,
        -- Ciclos de lectura DMA
        READ_C, WAIT_C,
        READ_B, WAIT_B,
        READ_A, WAIT_A,
        -- Calcular y escribir
        CALC,
        WRITE_D,
        -- Avanzar
        NEXT_WORD
    );
    signal state : state_t := IDLE;

    signal blt_active : std_logic := '0';
    signal is_first   : std_logic := '0';
    signal is_last    : std_logic := '0';

    -- Funcion logica minterm de 8 bits
    -- LF[7:0] determina D para cada combinacion de A,B,C
    function minterm(lf: std_logic_vector(7 downto 0);
                     a, b, c: std_logic) return std_logic is
        variable idx : integer;
    begin
        idx := 0;
        if a = '1' then idx := idx + 4; end if;
        if b = '1' then idx := idx + 2; end if;
        if c = '1' then idx := idx + 1; end if;
        return lf(idx);
    end function;

    -- Aplicar LF bit a bit sobre palabras de 16 bits
    function apply_lf(lf: std_logic_vector(7 downto 0);
                      a, b, c: std_logic_vector(15 downto 0))
                      return std_logic_vector is
        variable result : std_logic_vector(15 downto 0);
    begin
        for i in 0 to 15 loop
            result(i) := minterm(lf, a(i), b(i), c(i));
        end loop;
        return result;
    end function;

begin

    busy    <= blt_active;
    dma_req <= blt_active;

    use_a  <= bltcon0(11);
    use_b  <= bltcon0(10);
    use_c  <= bltcon0(9);
    use_d  <= bltcon0(8);
    desc   <= bltcon1(1);
    a_shift<= unsigned(bltcon0(15 downto 12));
    b_shift<= unsigned(bltcon1(15 downto 12));

    -- ============================================================
    -- Escritura de registros desde CPU
    -- ============================================================
    process(clk, reset_n)
    begin
        if reset_n = '0' then
            bltcon0 <= (others => '0');
            bltcon1 <= (others => '0');
            bltafwm <= x"FFFF";
            bltalwm <= x"FFFF";
            bltapt  <= (others => '0');
            bltbpt  <= (others => '0');
            bltcpt  <= (others => '0');
            bltdpt  <= (others => '0');
            bltamod <= (others => '0');
            bltbmod <= (others => '0');
            bltcmod <= (others => '0');
            bltdmod <= (others => '0');
            blt_h   <= (others => '0');
            blt_w   <= (others => '0');
            blt_active <= '0';
            state   <= IDLE;
            ram_we_w<= "00";

        elsif rising_edge(clk) then
            ram_we_w <= "00";

            -- Escritura registros CPU
            if cpu_as = '0' and cpu_rw = '0' then
                case cpu_addr(8 downto 1) is
                    -- BLTCON0/1
                    when x"20" => bltcon0 <= cpu_data;
                    when x"21" => bltcon1 <= cpu_data;
                    -- Masks
                    when x"22" => bltafwm <= cpu_data;
                    when x"23" => bltalwm <= cpu_data;
                    -- Puntero C
                    when x"24" => bltcpt(23 downto 16) <= unsigned(cpu_data(7 downto 0));
                    when x"25" => bltcpt(15 downto 0)  <= unsigned(cpu_data);
                    -- Puntero B
                    when x"26" => bltbpt(23 downto 16) <= unsigned(cpu_data(7 downto 0));
                    when x"27" => bltbpt(15 downto 0)  <= unsigned(cpu_data);
                    -- Puntero A
                    when x"28" => bltapt(23 downto 16) <= unsigned(cpu_data(7 downto 0));
                    when x"29" => bltapt(15 downto 0)  <= unsigned(cpu_data);
                    -- Puntero D
                    when x"2A" => bltdpt(23 downto 16) <= unsigned(cpu_data(7 downto 0));
                    when x"2B" => bltdpt(15 downto 0)  <= unsigned(cpu_data);
                    -- BLTSIZE: disparo
                    when x"2C" =>
                        blt_h      <= unsigned(cpu_data(15 downto 6));
                        blt_w      <= unsigned(cpu_data(5 downto 0));
                        cur_x      <= (others => '0');
                        cur_y      <= (others => '0');
                        a_hold     <= (others => '0');
                        b_hold     <= (others => '0');
                        is_first   <= '1';
                        blt_active <= '1';
                        -- Primer estado según canales activos
                        if bltcon0(9) = '1' then  -- use_c
                            state <= READ_C;
                        elsif bltcon0(10) = '1' then  -- use_b
                            state <= READ_B;
                        elsif bltcon0(11) = '1' then  -- use_a
                            state <= READ_A;
                        else
                            state <= CALC;
                        end if;
                    -- Modulos
                    when x"30" => bltcmod <= signed(cpu_data);
                    when x"31" => bltbmod <= signed(cpu_data);
                    when x"32" => bltamod <= signed(cpu_data);
                    when x"33" => bltdmod <= signed(cpu_data);
                    -- Datos precargados
                    when x"38" => bltcdat <= cpu_data;
                    when x"39" => bltbdat <= cpu_data;
                    when x"3A" => bltadat <= cpu_data;
                    when others => null;
                end case;
            end if;

            -- ============================================================
            -- FSM del Blitter
            -- ============================================================
            if blt_active = '1' then

                -- Calcular is_last
                if cur_x = blt_w - 1 then is_last <= '1'; else is_last <= '0'; end if;

                case state is

                when IDLE => null;

                -- Leer canal C
                when READ_C =>
                    if gnt = '1' then
                        ram_addr_r <= std_logic_vector(bltcpt(17 downto 1));
                        state <= WAIT_C;
                    end if;

                when WAIT_C =>
                    c_data <= ram_data_r;
                    if use_b = '1' then state <= READ_B;
                    elsif use_a = '1' then state <= READ_A;
                    else state <= CALC; end if;

                -- Leer canal B
                when READ_B =>
                    if gnt = '1' then
                        ram_addr_r <= std_logic_vector(bltbpt(17 downto 1));
                        state <= WAIT_B;
                    end if;

                when WAIT_B =>
                    -- Shift B
                    if b_shift = 0 then
                        b_data <= ram_data_r;
                    else
                        b_data <= std_logic_vector(
                            shift_right(unsigned(b_hold & ram_data_r),
                                       to_integer(b_shift))(15 downto 0));
                    end if;
                    b_hold <= ram_data_r;
                    if use_a = '1' then state <= READ_A;
                    else state <= CALC; end if;

                -- Leer canal A
                when READ_A =>
                    if gnt = '1' then
                        ram_addr_r <= std_logic_vector(bltapt(17 downto 1));
                        state <= WAIT_A;
                    end if;

                when WAIT_A =>
                    -- Shift A
                    if a_shift = 0 then
                        a_data <= ram_data_r;
                    else
                        a_data <= std_logic_vector(
                            shift_right(unsigned(a_hold & ram_data_r),
                                       to_integer(a_shift))(15 downto 0));
                    end if;
                    a_hold <= ram_data_r;
                    state <= CALC;

                -- Calcular resultado
                when CALC =>
                    -- Aplicar masks a canal A
                    if is_first = '1' and is_last = '1' then
                        a_masked <= a_data and bltafwm and bltalwm;
                    elsif is_first = '1' then
                        a_masked <= a_data and bltafwm;
                    elsif is_last = '1' then
                        a_masked <= a_data and bltalwm;
                    else
                        a_masked <= a_data;
                    end if;

                    -- Aplicar funcion logica
                    d_data <= apply_lf(bltcon0(7 downto 0),
                                      a_masked, b_data, c_data);

                    if use_d = '1' then
                        state <= WRITE_D;
                    else
                        state <= NEXT_WORD;
                    end if;

                -- Escribir canal D
                when WRITE_D =>
                    if gnt = '1' then
                        ram_addr_w <= std_logic_vector(bltdpt(17 downto 1));
                        ram_data_w <= d_data;
                        ram_we_w   <= "11";
                        state <= NEXT_WORD;
                    end if;

                -- Avanzar al siguiente word
                when NEXT_WORD =>
                    ram_we_w  <= "00";
                    is_first  <= '0';

                    -- Avanzar punteros (modo normal o DESC)
                    if desc = '0' then
                        if use_a = '1' then bltapt <= bltapt + 2; end if;
                        if use_b = '1' then bltbpt <= bltbpt + 2; end if;
                        if use_c = '1' then bltcpt <= bltcpt + 2; end if;
                        if use_d = '1' then bltdpt <= bltdpt + 2; end if;
                    else
                        if use_a = '1' then bltapt <= bltapt - 2; end if;
                        if use_b = '1' then bltbpt <= bltbpt - 2; end if;
                        if use_c = '1' then bltcpt <= bltcpt - 2; end if;
                        if use_d = '1' then bltdpt <= bltdpt - 2; end if;
                    end if;

                    cur_x <= cur_x + 1;

                    if cur_x = blt_w - 1 then
                        -- Fin de linea: aplicar modulos
                        cur_x    <= (others => '0');
                        cur_y    <= cur_y + 1;
                        is_first <= '1';
                        a_hold   <= (others => '0');
                        b_hold   <= (others => '0');

                        if desc = '0' then
                            if use_a = '1' then
                                bltapt <= bltapt + 2 + unsigned(resize(bltamod,24));
                            end if;
                            if use_b = '1' then
                                bltbpt <= bltbpt + 2 + unsigned(resize(bltbmod,24));
                            end if;
                            if use_c = '1' then
                                bltcpt <= bltcpt + 2 + unsigned(resize(bltcmod,24));
                            end if;
                            if use_d = '1' then
                                bltdpt <= bltdpt + 2 + unsigned(resize(bltdmod,24));
                            end if;
                        else
                            if use_a = '1' then
                                bltapt <= bltapt - 2 + unsigned(resize(bltamod,24));
                            end if;
                            if use_b = '1' then
                                bltbpt <= bltbpt - 2 + unsigned(resize(bltbmod,24));
                            end if;
                            if use_c = '1' then
                                bltcpt <= bltcpt - 2 + unsigned(resize(bltcmod,24));
                            end if;
                            if use_d = '1' then
                                bltdpt <= bltdpt - 2 + unsigned(resize(bltdmod,24));
                            end if;
                        end if;

                        if cur_y = blt_h - 1 then
                            -- Operacion completa
                            blt_active <= '0';
                            state      <= IDLE;
                        else
                            -- Siguiente linea
                            if use_c = '1' then state <= READ_C;
                            elsif use_b = '1' then state <= READ_B;
                            elsif use_a = '1' then state <= READ_A;
                            else state <= CALC; end if;
                        end if;
                    else
                        -- Siguiente word en misma linea
                        if use_c = '1' then state <= READ_C;
                        elsif use_b = '1' then state <= READ_B;
                        elsif use_a = '1' then state <= READ_A;
                        else state <= CALC; end if;
                    end if;

                when others => state <= IDLE;
                end case;
            end if;
        end if;
    end process;

end Behavioral;
