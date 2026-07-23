// Verilog wrapper around sid_top.sv so VHDL can instantiate it as a component.
// Quartus 13.1 cannot directly reference an SV module from VHDL via entity work.*
// but it CAN bind a VHDL component to a plain Verilog module by name.

module sid_top_wrap (
	input         reset,
	input         clk,
	input         ce_1m,

	input  [1:0]  cs,
	input         we,
	input  [4:0]  addr,
	input  [7:0]  data_in,
	output [7:0]  data_out,

	input  [12:0] fc_offset_l,
	input  [7:0]  pot_x_l,
	input  [7:0]  pot_y_l,
	input  [17:0] ext_in_l,
	output [17:0] audio_l,

	input  [12:0] fc_offset_r,
	input  [7:0]  pot_x_r,
	input  [7:0]  pot_y_r,
	input  [17:0] ext_in_r,
	output [17:0] audio_r,

	input  [1:0]  filter_en,
	input  [1:0]  mode,
	input  [3:0]  cfg,

	input         ld_clk,
	input  [11:0] ld_addr,
	input  [15:0] ld_data,
	input         ld_wr
);

sid_top #(
	.MULTI_FILTERS(1),
	.DUAL(1)
) sid_top_inst (
	.reset      (reset),
	.clk        (clk),
	.ce_1m      (ce_1m),

	.cs         (cs),
	.we         (we),
	.addr       (addr),
	.data_in    (data_in),
	.data_out   (data_out),

	.fc_offset_l(fc_offset_l),
	.pot_x_l    (pot_x_l),
	.pot_y_l    (pot_y_l),
	.ext_in_l   (ext_in_l),
	.audio_l    (audio_l),

	.fc_offset_r(fc_offset_r),
	.pot_x_r    (pot_x_r),
	.pot_y_r    (pot_y_r),
	.ext_in_r   (ext_in_r),
	.audio_r    (audio_r),

	.filter_en  (filter_en),
	.mode       (mode),
	.cfg        (cfg),

	.ld_clk     (ld_clk),
	.ld_addr    (ld_addr),
	.ld_data    (ld_data),
	.ld_wr      (ld_wr)
);

endmodule
