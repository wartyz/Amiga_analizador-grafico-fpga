---------------------------------------------------
-- FICHERO: Amiga_Copper.vhd
-- VERSION: 1.1 CORREGIDA
-- CORRECCIONES:
--   [FIX-C1] wait_h_pos corregido: era ir1(14 downto 7)
--            que se solapaba con la posicion V. Correcto es
--            ir1(7 downto 1) segun especificacion Amiga:
--              IR1[15:8] = VP (Vertical Position)
--              IR1[7:1]  = HP (Horizontal Position)
--              IR1[0]    = 1  (tipo WAIT/SKIP)
--   [FIX-C2] Mascara de comparacion IR2 implementada:
--              IR2[15:8] = VM (Vertical Mask)
--              IR2[7:1]  = HM (Horizontal Mask)
--              IR2[0]    = 0=WAIT / 1=SKIP
--            Comparacion correcta:
--              (current_v AND VM) >= (VP AND VM)  &&
--              (current_h AND HM) >= (HP AND HM)
--   [FIX-C3] Instruccion SKIP implementada:
--            Si IR2(0)='1' es SKIP (no WAIT).
--            SKIP salta la siguiente instruccion si el haz
--            ya ha pasado la posicion indicada.
--   [FIX-C4] reg_addr usa ir1(8 downto 1) en lugar de
--            ir1(8 downto 0). El bit 0 de MOVE siempre es 0
--            y no forma parte del indice de registro.
--            reg_addr es ahora STD_LOGIC_VECTOR(8 downto 0)
--            con bit 0 forzado a 0 para mantener
--            compatibilidad con el bus de registros.
--
-- INSTRUCCIONES DEL COPPER (Amiga Hardware Reference Manual):
--   MOVE:  IR1(0)='0' → IR1[8:1]=reg, IR2=dato
--   WAIT:  IR1(0)='1', IR2(0)='0' → esperar posicion raster
--   SKIP:  IR1(0)='1', IR2(0)='1' → saltar si posicion pasada
--   END:   WAIT con IR1=x"FFFF", IR2=x"FFFE"
--
-- INTERFACE DE BUS:
--   cpu_addr[11:0]: offset del registro chipset ($080=COP1LCH)
--   cpu_as=0 + cpu_rw=0: escritura activa
--   gnt: grant del arbitro DMA (1=Copper puede acceder a RAM)
---------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity Amiga_Copper is
    Port (
        clk      : in  STD_LOGIC;
        reset_n  : in  STD_LOGIC;
        gnt      : in  STD_LOGIC;  -- DMA grant del arbitro
        vblank   : in  STD_LOGIC;  -- Pulso VBLANK para reinicio automatico

        dma_req  : out STD_LOGIC;  -- Solicitud de bus DMA

        -- Bus CPU (escritura de registros COP1LC, COPJMP)
        cpu_addr : in  STD_LOGIC_VECTOR(15 downto 0);
        cpu_data : in  STD_LOGIC_VECTOR(15 downto 0);
        cpu_as   : in  STD_LOGIC;
        cpu_rw   : in  STD_LOGIC;

        -- Posicion actual del haz (desde vga_sync / Agnus)
        v_cnt    : in  INTEGER;
        h_cnt    : in  INTEGER;

        -- Bus de RAM (lectura de copper list)
        ram_data : in  STD_LOGIC_VECTOR(15 downto 0);
        ram_addr : out STD_LOGIC_VECTOR(17 downto 1);

        -- Bus de registros chipset (salida MOVE)
        reg_addr : out STD_LOGIC_VECTOR(8 downto 0); -- [8:1]=indice, [0]=0
        reg_data : out STD_LOGIC_VECTOR(15 downto 0);
        reg_we   : out STD_LOGIC
    );
end Amiga_Copper;

architecture Behavioral of Amiga_Copper is

    -- Registros base de las copper lists
    signal cop1lc      : std_logic_vector(31 downto 0) := (others => '0');
    signal cop2lc      : std_logic_vector(31 downto 0) := (others => '0');
    signal cop2lc_valid: std_logic := '0';
    signal vblank_prev : std_logic := '0';

    -- Program Counter del Copper (direccion de palabra, 17 bits)
    signal pc : unsigned(17 downto 1) := (others => '0');

    -- Instruction Registers
    signal ir1 : std_logic_vector(15 downto 0) := (others => '0');
    signal ir2 : std_logic_vector(15 downto 0) := (others => '0');

    -- Posiciones WAIT/SKIP decodificadas de IR1 e IR2
    -- [FIX-C1] HP ahora en bits [7:1] de IR1
    signal wait_vp : unsigned(7 downto 0); -- Vertical Position   IR1[15:8]
    signal wait_hp : unsigned(6 downto 0); -- Horizontal Position IR1[7:1]
    signal wait_vm : unsigned(7 downto 0); -- Vertical Mask       IR2[15:8]
    signal wait_hm : unsigned(6 downto 0); -- Horizontal Mask     IR2[7:1]

    -- Posicion actual del haz (8 bits V, 7 bits H)
    signal cur_v : unsigned(7 downto 0);
    signal cur_h : unsigned(6 downto 0);

    -- Resultado de comparacion con mascara
    signal comparison_met : std_logic;

    type state_t is (
        IDLE,
        FETCH1,       -- Solicitar DMA y presentar direccion IR1
        FETCH2,       -- Leer IR1, presentar direccion IR2
        DECODE,       -- Leer IR2, decodificar instruccion
        EXECUTE_MOVE, -- Ejecutar MOVE: escribir registro chipset
        WAIT_STATE,   -- Esperar condicion de posicion raster
        SKIP_STATE,   -- Evaluar condicion SKIP (1 ciclo)
        YIELD         -- Ceder bus, volver a FETCH1
    );
    signal state : state_t := IDLE;

begin

    -- ============================================================
    -- Decodificacion de campos WAIT/SKIP (combinacional)
    -- [FIX-C1] HP corregido a bits [7:1]
    -- ============================================================
    wait_vp <= unsigned(ir1(15 downto 8));
    wait_hp <= unsigned(ir1(7  downto 1));  -- [FIX-C1] era ir1(14:7)
    wait_vm <= unsigned(ir2(15 downto 8));  -- [FIX-C2] Mascara vertical
    wait_hm <= unsigned(ir2(7  downto 1));  -- [FIX-C2] Mascara horizontal

    -- Posicion actual del haz normalizada a coordenadas Amiga
    -- v_cnt/2 para lineas entrelazadas, h_cnt/4 para ciclos de color
    cur_v <= to_unsigned(v_cnt / 2, 8);
    cur_h <= to_unsigned(h_cnt / 4, 7);

    -- ============================================================
    -- Comparador con mascara (combinacional)
    -- [FIX-C2] Mascara IR2 aplicada correctamente
    -- Condicion: (cur_v AND VM >= VP AND VM) AND
    --            (cur_h AND HM >= HP AND HM)
    -- En la practica: la comparacion se hace bit a bit
    -- con los bits enmascarados.
    -- ============================================================
    process(cur_v, cur_h, wait_vp, wait_hp, wait_vm, wait_hm)
        variable masked_cur_v  : unsigned(7 downto 0);
        variable masked_wait_v : unsigned(7 downto 0);
        variable masked_cur_h  : unsigned(6 downto 0);
        variable masked_wait_h : unsigned(6 downto 0);
    begin
        masked_cur_v  := cur_v  and wait_vm;
        masked_wait_v := wait_vp and wait_vm;
        masked_cur_h  := cur_h  and wait_hm;
        masked_wait_h := wait_hp and wait_hm;

        comparison_met <= '0';
        if masked_cur_v > masked_wait_v then
            -- Ya pasamos la linea: condicion cumplida
            comparison_met <= '1';
        elsif masked_cur_v = masked_wait_v then
            -- Misma linea: verificar posicion H
            if masked_cur_h >= masked_wait_h then
                comparison_met <= '1';
            end if;
        end if;
    end process;

    -- ============================================================
    -- Maquina de estados del Copper
    -- ============================================================
    process(clk, reset_n)
    begin
        if reset_n = '0' then
            state       <= IDLE;
            cop1lc      <= (others => '0');
            cop2lc      <= (others => '0');
            cop2lc_valid<= '0';
            vblank_prev <= '0';
            dma_req     <= '0';
            reg_we      <= '0';
            reg_addr    <= (others => '0');
            reg_data    <= (others => '0');
            ram_addr    <= (others => '0');
            ir1         <= (others => '0');
            ir2         <= (others => '0');
            pc          <= (others => '0');

        elsif rising_edge(clk) then
            reg_we <= '0'; -- Default: no escribir registros

            -- ------------------------------------------------
            -- ESCRITURA DE REGISTROS DE CONTROL DEL COPPER
            -- COP1LCH ($DFF080): parte alta del puntero
            -- COP1LCL ($DFF082): parte baja del puntero
            -- COPJMP1 ($DFF088): strobe de arranque
            -- Usamos bits [11:0] para ignorar prefijo de bus
            -- ------------------------------------------------
            if cpu_as = '0' and cpu_rw = '0' then
                if cpu_addr(11 downto 0) = x"080" then
                    cop1lc(31 downto 16) <= cpu_data;
                end if;
                if cpu_addr(11 downto 0) = x"082" then
                    cop1lc(15 downto 0) <= cpu_data;
                end if;
                if cpu_addr(11 downto 0) = x"084" then
                    cop2lc(31 downto 16) <= cpu_data;
                end if;
                if cpu_addr(11 downto 0) = x"086" then
                    cop2lc(15 downto 0) <= cpu_data;
                    cop2lc_valid <= '1';
                end if;
                if cpu_addr(11 downto 0) = x"088" then
                    pc    <= unsigned(cop1lc(17 downto 1));
                    state <= FETCH1;
                end if;
                if cpu_addr(11 downto 0) = x"08A" then
                    pc    <= unsigned(cop2lc(17 downto 1));
                    state <= FETCH1;
                end if;
            end if;

            -- ------------------------------------------------
            -- FSM PRINCIPAL
            -- ------------------------------------------------
            case state is

                when IDLE =>
                    dma_req     <= '0';
                    vblank_prev <= vblank;
                    if vblank = '1' and vblank_prev = '0' then
                        if cop2lc_valid = '1' then
                            pc <= unsigned(cop2lc(17 downto 1));
                        else
                            pc <= unsigned(cop1lc(17 downto 1));
                        end if;
                        state <= FETCH1;
                    end if;

                when FETCH1 =>
                    -- Pedir acceso al bus DMA
                    dma_req  <= '1';
                    ram_addr <= std_logic_vector(pc);
                    if gnt = '1' then
                        state <= FETCH2;
                    end if;

                when FETCH2 =>
                    -- Leer IR1, presentar direccion de IR2
                    ir1      <= ram_data;
                    pc       <= pc + 1;
                    ram_addr <= std_logic_vector(pc + 1); -- Pipeline: ya apunta a IR2
                    state    <= DECODE;

                when DECODE =>
                    -- Leer IR2, decidir tipo de instruccion
                    ir2   <= ram_data;
                    pc    <= pc + 1;  -- Ahora pc apunta a la siguiente instruccion
                    dma_req <= '0';

                    if ir1(0) = '0' then
                        -- MOVE: bit0 de IR1 = 0
                        state <= EXECUTE_MOVE;
                    else
                        -- WAIT o SKIP: bit0 de IR1 = 1
                        -- Deteccion de END: IR1=0xFFFF (WAIT con todos a 1)
                        if ir1 = x"FFFF" then
                            state <= IDLE;  -- Fin de copper list
                        -- [FIX-C3] Distinguir WAIT (IR2[0]=0) de SKIP (IR2[0]=1)
                        -- Nota: IR2 aun no esta actualizado en este ciclo
                        -- (ram_data acaba de cargarse en ir2 arriba).
                        -- Usamos ram_data directamente para la decision
                        elsif ram_data(0) = '1' then
                            state <= SKIP_STATE;  -- [FIX-C3] SKIP
                        else
                            state <= WAIT_STATE;  -- WAIT
                        end if;
                    end if;

                when EXECUTE_MOVE =>
                    -- [FIX-C4] reg_addr usa ir1[8:1], bit0 forzado a 0
                    -- El indice de registro son los bits [8:1] de IR1
                    -- (direccion word del registro chipset, offset desde $DFF000)
                    reg_addr <= ir1(8 downto 1) & '0';
                    reg_data <= ir2;
                    reg_we   <= '1';
                    state    <= YIELD;

                when WAIT_STATE =>
                    -- Esperar hasta que el haz llegue a la posicion indicada
                    dma_req <= '0';
                    if comparison_met = '1' then
                        state <= YIELD;
                    end if;

                when SKIP_STATE =>
                    -- [FIX-C3] SKIP: si el haz ya paso la posicion,
                    -- saltar la siguiente instruccion (avanzar pc 2 palabras)
                    dma_req <= '0';
                    if comparison_met = '1' then
                        -- Saltamos la siguiente instruccion (2 palabras)
                        pc <= pc + 2;
                    end if;
                    state <= YIELD;

                when YIELD =>
                    -- Ceder el bus un ciclo antes del siguiente fetch
                    dma_req <= '0';
                    state   <= FETCH1;

            end case;
        end if;
    end process;

end Behavioral;
