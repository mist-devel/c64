library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

entity reu is
port (
	clock           : in  std_logic;
	reset           : in  std_logic;
	enable          : in  std_logic := '1';
	rommask         : in  std_logic_vector(4 downto 0) := "11111";

	-- expansion port
	phi             : in  std_logic;
	ba              : in  std_logic;
	iof             : in  std_logic;
	dma_n           : out std_logic;
	addr            : in  std_logic_vector(15 downto 0);
	rnw             : in  std_logic;
	irq_n           : out std_logic;
	din             : in  std_logic_vector( 7 downto 0);
	dout            : out std_logic_vector( 7 downto 0);
	oe              : out std_logic; -- dout output enable
	addr_out        : out std_logic_vector(15 downto 0);
	rnw_out         : out std_logic;

	-- REU RAM interface
	ram_addr    : out std_logic_vector(23 downto 0);
	ram_ce      : out std_logic;
	ram_we      : out std_logic;
	ram_di      : in  std_logic_vector( 7 downto 0);
	ram_do      : out std_logic_vector( 7 downto 0)
);
end reu;

architecture rtl of reu is
	type state_t is (idle, read_reu, write_c64, write_c64_do, read_c64, read_c64_do, write_reu, finished);
	signal state: state_t;

	signal phi_d: std_logic;
	signal phi_rise: std_logic;
	signal phi_fall: std_logic;
	signal phi_cnt: unsigned(3 downto 0);
	signal reu_cs: std_logic;
	signal ba_reg: std_logic;
	signal ba_reg2: std_logic;

	signal load: std_logic;
	signal ff00: std_logic;
	signal transfer_type: std_logic_vector(1 downto 0);
	signal c64_addr: std_logic_vector(15 downto 0);
	signal reu_addr: std_logic_vector(23 downto 0);
	signal transfer_len: std_logic_vector(15 downto 0);
	signal c64_start_addr: std_logic_vector(15 downto 0);
	signal reu_start_addr: std_logic_vector(23 downto 0);
	signal transfer_len_base: std_logic_vector(15 downto 0);

	signal reu_data: std_logic_vector(7 downto 0);
	signal c64_data: std_logic_vector(7 downto 0);
	signal reg_dout: std_logic_vector(7 downto 0);
	signal mem_dout: std_logic_vector(7 downto 0);

	signal ier: std_logic_vector(2 downto 0);
	signal address_ctrl: std_logic_vector(1 downto 0);
	signal unused: std_logic_vector(2 downto 0);

	signal execute: std_logic;
	signal transfer_end: std_logic;
	signal verify_error: std_logic;
	signal irq: std_logic;

begin
	dout <= mem_dout when state /= idle else reg_dout;
	irq <= enable and ier(2) and ((ier(1) and transfer_end) or (ier(0) and verify_error));
	irq_n <= not irq;

	process(clock) begin
		if rising_edge(clock) then
			phi_d <= phi;
			if (phi_rise = '1' or phi_fall = '1') then
				phi_cnt <= x"1";
			else
				phi_cnt <= phi_cnt + 1;
			end if;
		end if;
	end process;

	phi_rise <= phi and not phi_d;
	phi_fall <= not phi and phi_d;

	reu_cs <= '1' when phi = '1' and iof = '1' and enable = '1' and state = idle else '0';

	-- to make some timing tests (and Treu Love) happy
	process(clock) begin
		if rising_edge(clock) then
			if phi = '0' and phi_cnt = 1 then
				ba_reg <= ba;
				ba_reg2 <= ba_reg;
			end if;
			if ba = '1' then
				ba_reg <= '1';
				ba_reg2 <= '1';
			end if;
		end if;
	end process;

	-- main process
	process(clock, reset) begin
		if reset = '1' then
			ff00 <= '1';
			load <= '0';
			c64_start_addr <= x"0000";
			reu_start_addr <= x"000000";
			transfer_len_base <= x"FFFF";
			c64_addr <= x"0000";
			reu_addr <= x"000000";
			transfer_len <= x"FFFF";
			ier <= "000";
			address_ctrl <= "00";
			unused <= "000";
			state <= idle;
			dma_n <= '1';
			ram_ce <= '0';
			verify_error <= '0';
			transfer_end <= '0';
			execute <= '0';
		elsif rising_edge(clock) then
			if reu_cs = '1' and rnw = '0' and addr(4) = '0' then
				case addr(3 downto 0) is
					when x"1" =>
						execute <= din(7);
						load <= din(5);
						ff00 <= din(4);
						transfer_type <= din(1 downto 0);
						unused <= din(6)&din(3 downto 2);
					when x"2" =>
						c64_start_addr( 7 downto  0) <= din;
						c64_addr <= c64_start_addr(15 downto 8) & din;
					when x"3" =>
						c64_start_addr(15 downto  8) <= din;
						c64_addr <= din & c64_start_addr(7 downto  0);
					when x"4" =>
						reu_start_addr( 7 downto  0) <= din;
						reu_addr(15 downto  0) <= reu_start_addr(15 downto 8) & din;
					when x"5" =>
						reu_start_addr(15 downto  8) <= din;
						reu_addr(15 downto  0) <= din & reu_start_addr(7 downto 0);
					when x"6" =>
						reu_start_addr(23 downto 16) <= din and rommask&"111";
						reu_addr(23 downto 16) <= din and rommask&"111";
					when x"7" =>
						transfer_len_base( 7 downto  0) <= din;
						transfer_len <= transfer_len_base(15 downto 8) & din;
					when x"8" =>
						transfer_len_base(15 downto  8) <= din;
						transfer_len <= din & transfer_len_base(7 downto 0);
					when x"9" => ier <= din(7 downto 5);
					when x"A" => address_ctrl <= din(7 downto 6);
					when others => null;
				end case;
			end if;

			-- status register read clears interrupt flags
			if reu_cs = '1' and rnw = '1' and addr(4 downto 0) = '0'&x"0" and phi_cnt = 15 then
				transfer_end <= '0';
				verify_error <= '0';
			end if;

			case state is
				when idle =>
					if phi = '1' and phi_cnt = 15 and execute = '1' and
					   (ff00 = '1' or addr = x"ff00")
					then
						execute <= '0';
						dma_n <= '0';
						if transfer_type = "00" then
							state <= read_c64;
						else
							state <= read_reu;
						end if;
					end if;

				when read_reu =>
					ram_addr <= reu_addr and (rommask & "111" & x"FFFF");
					ram_we <= '0';
					if phi = '0' and phi_cnt = 7 then
						ram_ce <= '1';
					end if;
					if phi = '0' and phi_cnt = 10 then
						ram_ce <= '0';
					end if;
					if phi = '0' and phi_cnt = 11 then
						reu_data <= ram_di;
						if address_ctrl(0) = '0' and transfer_type /= "10" then
							reu_addr <= std_logic_vector(unsigned(reu_addr) + 1) and (rommask & "111" & x"FFFF");
						end if;
						if transfer_type(1) = '1' then -- swap, verify
							state <= read_c64;
						else
							state <= write_c64;
						end if;
					end if;

				when write_c64 =>
					if phi = '0' then
						if ba_reg2 = '1' then
							state <= write_c64_do;
						end if;
					end if;

				when write_c64_do =>
					mem_dout <= reu_data;
					addr_out <= c64_addr;
					rnw_out <= '0';
					if phi = '1' and phi_cnt = 15 then
						rnw_out <= '1';
						if address_ctrl(1) = '0' then
							c64_addr <= std_logic_vector(unsigned(c64_addr) + 1);
						end if;
						if transfer_len = x"0001" then
							state <= finished;
						else
							transfer_len <= std_logic_vector(unsigned(transfer_len) - 1);
							state <= read_reu;
						end if;
					end if;

				when read_c64 =>
					rnw_out <= '1';
					if phi = '0' then
						if ba_reg2 = '1' then
							state <= read_c64_do;
						end if;
					end if;

				when read_c64_do =>
					addr_out <= c64_addr;
					rnw_out <= '1';
					if phi = '1' and phi_cnt = 15 then
						c64_data <= din;
						if address_ctrl(1) = '0' and transfer_type /= "10" then
							c64_addr <= std_logic_vector(unsigned(c64_addr) + 1);
						end if;
						if transfer_type = "11" then -- verify
							if transfer_len = x"0001" then
								state <= finished;
							else
								transfer_len <= std_logic_vector(unsigned(transfer_len) - 1);
								state <= read_reu;
							end if;
							if reu_data /= din then
								verify_error <= '1';
								state <= finished;
							end if;
						else
							state <= write_reu;
						end if;
					end if;

				when write_reu =>
					ram_addr <= reu_addr and (rommask & "111" & x"FFFF");
					ram_we <= '1';
					ram_do <= c64_data;
					if phi = '0' and phi_cnt = 7 then
						ram_ce <= '1';
					end if;
					if phi = '0' and phi_cnt = 10 then
						ram_ce <= '0';
					end if;
					if phi = '0' and phi_cnt = 11 then
						if address_ctrl(0) = '0' then
							reu_addr <= std_logic_vector(unsigned(reu_addr) + 1) and (rommask & "111" & x"FFFF");
						end if;
						if transfer_type = "10" then -- swap
							state <= write_c64;
						elsif transfer_len = x"0001" then
							state <= finished;
						else
							transfer_len <= std_logic_vector(unsigned(transfer_len) - 1);
							state <= read_c64;
						end if;
					end if;

				when finished =>
					if phi = '0' and phi_cnt = 0 and ba = '1' then
						dma_n <= '1';
						ff00 <= '1';
						if not (verify_error = '1' and transfer_len /= x"0001") then
							transfer_end <= '1';
							if load = '1' then
								c64_addr <= c64_start_addr;
								reu_addr <= reu_start_addr and (rommask & "111" & x"FFFF");
								transfer_len <= transfer_len_base;
							end if;
						end if;
						state <= idle;
					end if;
			end case;
		end if;
	end process;

	process(addr, transfer_end, verify_error, execute, load, ff00,
	        transfer_type, c64_addr, reu_addr, transfer_len, ier, address_ctrl, unused, rommask, irq)
	begin
		case addr(4 downto 0) is
			when '0'&x"0" => reg_dout <= irq&transfer_end&verify_error&'1'&x"0";
			when '0'&x"1" => reg_dout <= execute&unused(2)&load&ff00&unused(1 downto 0)&transfer_type;
			when '0'&x"2" => reg_dout <= c64_addr( 7 downto  0);
			when '0'&x"3" => reg_dout <= c64_addr(15 downto  8);
			when '0'&x"4" => reg_dout <= reu_addr( 7 downto  0);
			when '0'&x"5" => reg_dout <= reu_addr(15 downto  8);
			when '0'&x"6" => reg_dout <= reu_addr(23 downto 16) or not (rommask & "111");
			when '0'&x"7" => reg_dout <= transfer_len( 7 downto  0);
			when '0'&x"8" => reg_dout <= transfer_len(15 downto  8);
			when '0'&x"9" => reg_dout <= ier&"11111";
			when '0'&x"A" => reg_dout <= address_ctrl&"111111";
			when others => reg_dout <= x"FF";
		end case;
	end process;

	oe <= '1' when (reu_cs = '1' and rnw = '1') or state = write_c64_do else '0';

end rtl;
