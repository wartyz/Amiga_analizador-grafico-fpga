---------------------------------------------------
-- FICHERO COMPLETO: Amiga_CIA.vhd
-- VERSION: 1.2 CORREGIDA
-- CORRECCIONES APLICADAS:
--   [FIX-C1] TOD corregido: tod_10th cuenta 0..9 y lleva
--            a tod_sec, tod_sec lleva a tod_min (0..59),
--            tod_min lleva a tod_hr. Antes wrapeaba a 256
--            y nunca incrementaba los registros superiores.
--   [FIX-C2] ICR read: clear ahora borra todos los bits
--            de icr_data, no solo bits [6:0].
--            El comportamiento de re-latch en underflow
--            simultaneo se mantiene (correcto en hardware
--            real: el nuevo underflow gana al clear porque
--            es la ultima asignacion VHDL del ciclo).
--   [FIX-C3] irq_out e ICR IR-bit extendidos a todos los
--            bits utiles [6:0] en lugar de solo [4:0].
--            Bits 5 (SP) y 6 (FLAG) ahora contribuyen al IRQ.
--   [FIX-C4] Documentacion de mapa de registros completa.
---------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- =========================================================================
-- AMIGA CIA 8520 - VERSION OCS CORREGIDA
--
-- MAPA DE REGISTROS (addr bits [11:8]):
--   x"0" PRA    - Port A data register
--   x"1" PRB    - Port B data register
--   x"2" DDRA   - Port A data direction (0=input, 1=output)
--   x"3" DDRB   - Port B data direction
--   x"4" TALO   - Timer A low byte (latch write / counter read)
--   x"5" TAHI   - Timer A high byte
--   x"6" TBLO   - Timer B low byte
--   x"7" TBHI   - Timer B high byte
--   x"8" TOD 10TH - Time of day 1/10 seconds (0-9)
--   x"9" TOD SEC  - Time of day seconds (0-59 BCD)
--   x"A" TOD MIN  - Time of day minutes (0-59 BCD)
--   x"B" TOD HR   - Time of day hours (0-11 BCD)
--   x"C" SDR    - Serial data register (no implementado)
--   x"D" ICR    - Interrupt control register (Set/Clear mask / read data)
--   x"E" CRA    - Control register A (Timer A)
--   x"F" CRB    - Control register B (Timer B)
--
-- CRA bits: [0]=START, [3]=RUNMODE(1=oneshot), [4]=LOAD, [6:5]=INMODE
-- CRB bits: [0]=START, [3]=RUNMODE, [4]=LOAD, [6:5]=INMODE(00=phi2,10=TA)
-- ICR bits escritura: [7]=SET/CLEAR, [4:0]=mask bits (TA,TB,ALRM,SP,FLG)
-- ICR bits lectura:   [7]=IR(any), [6:5]=FLG/SP, [4:0]=TA,TB,ALRM,SP,FLG
-- =========================================================================

entity Amiga_CIA is
    Port (
        clk         : in  STD_LOGIC;
        reset_n     : in  STD_LOGIC;

        addr        : in  STD_LOGIC_VECTOR(11 downto 0);
        data_in     : in  STD_LOGIC_VECTOR(7 downto 0);
        data_out    : out STD_LOGIC_VECTOR(7 downto 0);

        cs          : in  STD_LOGIC;
        rw          : in  STD_LOGIC;

        is_cia_a    : in  STD_LOGIC;
        irq_out     : out STD_LOGIC
    );
end Amiga_CIA;

architecture Behavioral of Amiga_CIA is

    -- Puertos y direccion
    signal pra  : std_logic_vector(7 downto 0) := (others => '1');
    signal prb  : std_logic_vector(7 downto 0) := (others => '1');
    signal ddra : std_logic_vector(7 downto 0) := (others => '0');
    signal ddrb : std_logic_vector(7 downto 0) := (others => '0');

    -- Registros de control
    signal cra  : std_logic_vector(7 downto 0) := (others => '0');
    signal crb  : std_logic_vector(7 downto 0) := (others => '0');

    -- Registros de interrupcion
    signal icr_mask : std_logic_vector(6 downto 0) := (others => '0');
    signal icr_data : std_logic_vector(6 downto 0) := (others => '0');

    -- Timers: latch (valor de recarga) y contador activo
    signal ta_latch   : unsigned(15 downto 0) := (others => '1');
    signal tb_latch   : unsigned(15 downto 0) := (others => '1');
    signal ta_counter : unsigned(15 downto 0) := (others => '1');
    signal tb_counter : unsigned(15 downto 0) := (others => '1');

    -- TOD: Time Of Day (BCD simplificado, cuenta en binario)
    -- [FIX-C1] Ahora lleva correctamente entre registros
    signal tod_10th : unsigned(3 downto 0) := (others => '0'); -- 0..9
    signal tod_sec  : unsigned(7 downto 0) := (others => '0'); -- 0..59 (BCD)
    signal tod_min  : unsigned(7 downto 0) := (others => '0'); -- 0..59 (BCD)
    signal tod_hr   : unsigned(7 downto 0) := (others => '0'); -- 0..11 (BCD)

    -- Generadores de tiempo base
    signal e_clock_div  : integer range 0 to 39 := 0;
    signal e_clock_tick : std_logic := '0';

    -- TOD tick: 50Hz para PAL (28MHz / 560000 = 50Hz)
    signal tod_div  : integer range 0 to 559999 := 0;
    signal tod_tick : std_logic := '0';

    -- Funcion auxiliar: incremento BCD de 2 digitos (00..59)
    -- Devuelve el siguiente valor BCD de un byte (digitos 0..59)
    function bcd_inc59(val : unsigned(7 downto 0)) return unsigned is
        variable lo : unsigned(3 downto 0);
        variable hi : unsigned(3 downto 0);
        variable res: unsigned(7 downto 0);
    begin
        lo := val(3 downto 0);
        hi := val(7 downto 4);
        if lo = 9 then
            lo := "0000";
            if hi = 5 then
                hi := "0000"; -- wrap 59→00
            else
                hi := hi + 1;
            end if;
        else
            lo := lo + 1;
        end if;
        res := hi & lo;
        return res;
    end function;

begin

-- ==========================================================
-- [BLOQUE 3: GENERADORES DE TIEMPO BASE]
-- e_clock: 28MHz / 40 = 700kHz (~E-clock del 68000)
-- tod_tick: 50Hz para PAL
-- ==========================================================
    process(clk, reset_n)
    begin
        if reset_n = '0' then
            e_clock_div  <= 0;
            e_clock_tick <= '0';
            tod_div      <= 0;
            tod_tick     <= '0';

        elsif rising_edge(clk) then
            -- E-clock tick cada 40 ciclos
            e_clock_tick <= '0';
            if e_clock_div = 39 then
                e_clock_div  <= 0;
                e_clock_tick <= '1';
            else
                e_clock_div <= e_clock_div + 1;
            end if;

            -- TOD tick cada 560000 ciclos (50Hz PAL)
            tod_tick <= '0';
            if tod_div = 559999 then
                tod_div  <= 0;
                tod_tick <= '1';
            else
                tod_div <= tod_div + 1;
            end if;
        end if;
    end process;

-- ==========================================================
-- [BLOQUE 4: TOD - TIME OF DAY]
-- [FIX-C1] Cadena de carries correcta: 10ths→sec→min→hr
-- Cuenta en BCD simplificado (binario para 10ths, BCD para
-- sec/min/hr para compatibilidad con software Amiga).
-- ==========================================================
    process(clk, reset_n)
    begin
        if reset_n = '0' then
            tod_10th <= (others => '0');
            tod_sec  <= (others => '0');
            tod_min  <= (others => '0');
            tod_hr   <= (others => '0');

        elsif rising_edge(clk) then
            if tod_tick = '1' then
                if tod_10th = 9 then
                    -- Carry: decimas → segundos
                    tod_10th <= (others => '0');
                    tod_sec  <= bcd_inc59(tod_sec);
                    -- Carry: segundos → minutos
                    if tod_sec = x"59" then
                        tod_sec <= (others => '0');
                        tod_min <= bcd_inc59(tod_min);
                        -- Carry: minutos → horas
                        if tod_min = x"59" then
                            tod_min <= (others => '0');
                            -- Horas: wrap en 12 (formato 12h)
                            if tod_hr = x"11" then
                                tod_hr <= (others => '0');
                            else
                                tod_hr <= bcd_inc59(tod_hr);
                            end if;
                        end if;
                    end if;
                else
                    tod_10th <= tod_10th + 1;
                end if;
            end if;
        end if;
    end process;

-- ==========================================================
-- [BLOQUE 5: TIMERS Y LOGICA DE REGISTROS DEL BUS]
-- ==========================================================
    process(clk, reset_n)
        variable ta_underflow : std_logic;
        variable tb_underflow : std_logic;
    begin
        if reset_n = '0' then
            pra       <= (others => '1');
            prb       <= (others => '1');
            ddra      <= (others => '0');
            ddrb      <= (others => '0');
            cra       <= (others => '0');
            crb       <= (others => '0');
            icr_mask  <= (others => '0');
            icr_data  <= (others => '0');
            ta_latch  <= (others => '1');
            tb_latch  <= (others => '1');
            ta_counter<= (others => '1');
            tb_counter<= (others => '1');
            data_out  <= (others => '1');

        elsif rising_edge(clk) then

            ta_underflow := '0';
            tb_underflow := '0';

            -- ------------------------------------------------
            -- TIMER A: decrementa en cada e_clock_tick
            -- ------------------------------------------------
            if e_clock_tick = '1' then
                if cra(0) = '1' then  -- START bit
                    if ta_counter = 0 then
                        ta_counter   <= ta_latch;
                        ta_underflow := '1';
                        icr_data(0)  <= '1';          -- TA interrupt flag
                        if cra(3) = '1' then          -- RUNMODE: one-shot
                            cra(0) <= '0';            -- parar timer
                        end if;
                    else
                        ta_counter <= ta_counter - 1;
                    end if;
                end if;

                -- ------------------------------------------------
                -- TIMER B: puede contar phi2 o underflows de TA
                -- CRB[6:5]: 00=phi2, 10=TA underflow
                -- ------------------------------------------------
                if crb(0) = '1' then
                    if (crb(6 downto 5) = "00") or
                       (crb(6 downto 5) = "10" and ta_underflow = '1') then
                        if tb_counter = 0 then
                            tb_counter   <= tb_latch;
                            tb_underflow := '1';
                            icr_data(1)  <= '1';      -- TB interrupt flag
                            if crb(3) = '1' then      -- RUNMODE: one-shot
                                crb(0) <= '0';
                            end if;
                        else
                            tb_counter <= tb_counter - 1;
                        end if;
                    end if;
                end if;
            end if;

            -- ------------------------------------------------
            -- BUS: lectura y escritura de registros
            -- ------------------------------------------------
            if cs = '1' then
                if rw = '1' then
                    -- LECTURA
                    case addr(11 downto 8) is
                        when x"0" =>
                            -- CIA-A PRA: bits[1:0] = /OVL y /LED
                            -- bits[7:2] siempre 1 (no conectados)
                            if is_cia_a = '1' then
                                data_out <= "111111" & pra(1 downto 0);
                            else
                                data_out <= pra;
                            end if;
                        when x"1" => data_out <= prb;
                        when x"2" => data_out <= ddra;
                        when x"3" => data_out <= ddrb;
                        when x"4" => data_out <= std_logic_vector(ta_counter(7 downto 0));
                        when x"5" => data_out <= std_logic_vector(ta_counter(15 downto 8));
                        when x"6" => data_out <= std_logic_vector(tb_counter(7 downto 0));
                        when x"7" => data_out <= std_logic_vector(tb_counter(15 downto 8));
                        when x"8" => data_out <= "0000" & std_logic_vector(tod_10th);
                        when x"9" => data_out <= std_logic_vector(tod_sec);
                        when x"A" => data_out <= std_logic_vector(tod_min);
                        when x"B" => data_out <= std_logic_vector(tod_hr);
                        when x"C" => data_out <= x"00"; -- SDR no implementado

                        when x"D" =>
                            -- ICR READ: devuelve icr_data con IR bit generado
                            -- IR (bit 7) = 1 si algun bit habilitado esta activo
                            -- [FIX-C3] Usar todos los bits [6:0]
                            if (icr_data and icr_mask) /= "0000000" then
                                data_out <= '1' & icr_data;  -- IR=1
                            else
                                data_out <= '0' & icr_data;  -- IR=0
                            end if;
                            -- Clear-on-read: limpiar icr_data
                            -- [FIX-C2] Limpiar TODOS los bits
                            icr_data <= (others => '0');
                            -- Re-latch si hay underflow simultaneo
                            -- (ultima asignacion VHDL gana = correcto)
                            if ta_underflow = '1' then icr_data(0) <= '1'; end if;
                            if tb_underflow = '1' then icr_data(1) <= '1'; end if;

                        when x"E" => data_out <= cra;
                        when x"F" => data_out <= crb;
                        when others => data_out <= x"FF";
                    end case;

                else
                    -- ESCRITURA
                    case addr(11 downto 8) is
                        when x"0" => pra  <= data_in;
                        when x"1" => prb  <= data_in;
                        when x"2" => ddra <= data_in;
                        when x"3" => ddrb <= data_in;

                        when x"4" =>  -- TALO: latch bajo de Timer A
                            ta_latch(7 downto 0) <= unsigned(data_in);

                        when x"5" =>  -- TAHI: latch alto de Timer A
                            ta_latch(15 downto 8) <= unsigned(data_in);
                            -- Si timer parado: carga inmediata del contador
                            if cra(0) = '0' then
                                ta_counter(15 downto 8) <= unsigned(data_in);
                                ta_counter(7 downto 0)  <= ta_latch(7 downto 0);
                            end if;

                        when x"6" =>  -- TBLO: latch bajo de Timer B
                            tb_latch(7 downto 0) <= unsigned(data_in);

                        when x"7" =>  -- TBHI: latch alto de Timer B
                            tb_latch(15 downto 8) <= unsigned(data_in);
                            if crb(0) = '0' then
                                tb_counter(15 downto 8) <= unsigned(data_in);
                                tb_counter(7 downto 0)  <= tb_latch(7 downto 0);
                            end if;

                        when x"D" =>  -- ICR: escritura de mascara
                            -- bit7=1: SET los bits indicados en [6:0]
                            -- bit7=0: CLEAR los bits indicados en [6:0]
                            -- [FIX-C3] Usar todos los bits [6:0]
                            if data_in(7) = '1' then
                                icr_mask <= icr_mask or  data_in(6 downto 0);
                            else
                                icr_mask <= icr_mask and not data_in(6 downto 0);
                            end if;

                        when x"E" =>  -- CRA: control de Timer A
                            cra <= data_in;
                            -- bit4=LOAD: fuerza carga inmediata del latch
                            if data_in(4) = '1' then
                                ta_counter <= ta_latch;
                            end if;

                        when x"F" =>  -- CRB: control de Timer B
                            crb <= data_in;
                            if data_in(4) = '1' then
                                tb_counter <= tb_latch;
                            end if;

                        when others => null;
                    end case;
                end if;

            else
                -- Bus no seleccionado: salida en alta impedancia simulada
                data_out <= (others => '1');
            end if;

        end if;
    end process;

-- ==========================================================
-- [BLOQUE 6: IRQ COMBINACIONAL HACIA PAULA]
-- [FIX-C3] Usar todos los bits [6:0], no solo [4:0]
-- IRQ activo (alto) cuando algun bit de icr_data
-- con su correspondiente bit de icr_mask esta activo.
-- ==========================================================
    irq_out <= '1' when (icr_data and icr_mask) /= "0000000" else '0';

end Behavioral;
