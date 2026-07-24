// ----------------------------------------------------------------------------
// SID filter - reDIP-SID, ported to Quartus 13.1 / Verilog-2001
// ----------------------------------------------------------------------------

module sid_filter
(
	input               clk,
	input         [2:0] state,
	input               mode,

	input        [15:0] F0,
	input         [7:0] Res_Filt,
	input         [7:0] Mode_Vol,
	input signed [21:0] voice1,
	input signed [21:0] voice2,
	input signed [21:0] voice3,
	input signed [21:0] ext_in,

	output       [17:0] audio
);

// MIXER_DC_6581 = (-1 << 20) / 18 = -58254
localparam signed [23:0] MIXER_DC_6581 = -24'sd58254;

// Clamp to 16 bits
function signed [15:0] clamp;
	input signed [16:0] x;
	clamp = (x[16] ^ x[15]) ? {x[16], {15{x[15]}}} : x[15:0];
endfunction

// Clamp to 18 bits
function signed [17:0] clamp18;
	input signed [18:0] x;
	clamp18 = (x[18] ^ x[17]) ? {x[18], {17{x[17]}}} : x[17:0];
endfunction

// Compression constants
localparam [15:0]        COMP_KNEE = 16'd3000;
localparam [4:0]         COMP_HG   = 5'd6;
localparam signed [16:0] DC_LP     = -17'sd3840;

// compress: soft-knee for 6581 mixer
function signed [15:0] compress;
	input signed [15:0] x;
	reg [15:0] ax;
	reg [15:0] over;
	reg [20:0] prod;
	reg [15:0] comp;
	begin
		ax   = x[15] ? (16'd0 - x[15:0]) : x[15:0];
		over = ax - COMP_KNEE;
		prod = {5'b0, over} * {16'b0, COMP_HG};  // 21-bit product
		comp = COMP_KNEE + prod[19:4];             // >>4, low 16 bits
		compress = (ax <= COMP_KNEE) ? x : (x[15] ? $signed(16'd0 - comp) : $signed(comp));
	end
endfunction

// 1/Q lookup (ROM via function - Q13.1 safe)
function [10:0] q_lsl10_lookup;
	input [4:0] idx;
	case (idx)
		5'd0:  q_lsl10_lookup = 11'd1448; 5'd1:  q_lsl10_lookup = 11'd1324;
		5'd2:  q_lsl10_lookup = 11'd1219; 5'd3:  q_lsl10_lookup = 11'd1129;
		5'd4:  q_lsl10_lookup = 11'd1052; 5'd5:  q_lsl10_lookup = 11'd984;
		5'd6:  q_lsl10_lookup = 11'd925;  5'd7:  q_lsl10_lookup = 11'd872;
		5'd8:  q_lsl10_lookup = 11'd826;  5'd9:  q_lsl10_lookup = 11'd783;
		5'd10: q_lsl10_lookup = 11'd745;  5'd11: q_lsl10_lookup = 11'd711;
		5'd12: q_lsl10_lookup = 11'd679;  5'd13: q_lsl10_lookup = 11'd651;
		5'd14: q_lsl10_lookup = 11'd624;  5'd15: q_lsl10_lookup = 11'd600;
		5'd16: q_lsl10_lookup = 11'd1448; 5'd17: q_lsl10_lookup = 11'd1328;
		5'd18: q_lsl10_lookup = 11'd1218; 5'd19: q_lsl10_lookup = 11'd1117;
		5'd20: q_lsl10_lookup = 11'd1024; 5'd21: q_lsl10_lookup = 11'd939;
		5'd22: q_lsl10_lookup = 11'd861;  5'd23: q_lsl10_lookup = 11'd790;
		5'd24: q_lsl10_lookup = 11'd724;  5'd25: q_lsl10_lookup = 11'd664;
		5'd26: q_lsl10_lookup = 11'd609;  5'd27: q_lsl10_lookup = 11'd558;
		5'd28: q_lsl10_lookup = 11'd512;  5'd29: q_lsl10_lookup = 11'd470;
		5'd30: q_lsl10_lookup = 11'd431;  default: q_lsl10_lookup = 11'd395;
	endcase
endfunction

// MAC: o = c +- (a * b)
reg signed  [33:0] c;
reg                s;
reg signed  [15:0] a;
reg signed  [17:0] b;
wire signed [33:0] m = a * b;
wire signed [33:0] o = s ? (c - m) : (c + m);

// SVF state registers (two SIDs share time-multiplexed filter)
reg signed [17:0] vlp, vlp2;
reg signed [17:0] vbp, vbp2;
reg signed [17:0] vhp, vhp2;

// Combinatorial next-state
wire signed [18:0] dv       = $signed({o[33], o[33], o[33:17]});  // 19'(o>>>17)
wire signed [17:0] vlp_next = clamp18(vlp + dv);
wire signed [17:0] vbp_next = clamp18(vbp + dv);
wire signed [17:0] vhp_next = clamp18($signed(o[10 +: 19]));

// Filtered tap mix
reg signed [16:0] tmix;
reg signed [16:0] tmix_s;
reg signed [16:0] center;
reg signed [16:0] center_s;
reg signed [15:0] tmix_c;
reg signed [15:0] tmix_c_r;

// Intermediate wires for compress pipeline
wire signed [16:0] tmix_minus_center = $signed(tmix_s) - $signed(center_s);
wire signed [15:0] tmix_clamped      = clamp(tmix_minus_center);
wire signed [15:0] tmix_compressed   = compress(tmix_clamped);
wire signed [16:0] tmix_recentered   = $signed({tmix_compressed[15], tmix_compressed}) + $signed(center_s);

always @(*) begin
	// Filtered tap mix (>>2 from 18-bit state back to 16-bit signal scale)
	tmix = ($signed({vlp2[17],     vlp2[17:2]})     & {17{Mode_Vol[4]}}) +
	       ($signed({vbp2[17],     vbp2[17:2]})     & {17{Mode_Vol[5]}}) +
	       ($signed({vhp_next[17], vhp_next[17:2]}) & {17{Mode_Vol[6]}});

	center = (!mode && Mode_Vol[4]) ? DC_LP : 17'sd0;

	tmix_c = mode ? clamp(tmix_s) : clamp(tmix_recentered);
end

// Filter state machine
always @(posedge clk) begin
	reg [10:0] _1_Q_lsl10;
	reg signed [17:0] vi;
	reg signed [15:0] vd;
	// 24-bit sign-extend intermediates for voice mixing
	reg signed [23:0] v1e, v2e, v3e, ve_ext;
	reg signed [23:0] vi_sum, vd_sum;

	case (state)
		3'd2: begin
			_1_Q_lsl10 <= q_lsl10_lookup({mode, Res_Filt[7:4]});

			// Sign-extend voices from 22 to 24 bits
			v1e   = {{2{voice1[21]}}, voice1};
			v2e   = {{2{voice2[21]}}, voice2};
			v3e   = {{2{voice3[21]}}, voice3};
			ve_ext= {{2{ext_in[21]}}, ext_in};

			// Filter input mux: sum selected voices, >>5 to 18 bits
			vi_sum = (Res_Filt[0] ? v1e    : 24'sd0) +
			         (Res_Filt[1] ? v2e    : 24'sd0) +
			         (Res_Filt[2] ? v3e    : 24'sd0) +
			         (Res_Filt[3] ? ve_ext : 24'sd0);
			vi <= $signed(vi_sum[23:5]);  // arithmetic >>5, keep 18 bits [23:5]

			// Direct path mux: sum unfiltered voices, >>7 to 16 bits
			vd_sum = (mode              ? 24'sd0 : $signed(MIXER_DC_6581)) +
			         (Res_Filt[0]       ? 24'sd0 : v1e) +
			         (Res_Filt[1]       ? 24'sd0 : v2e) +
			         ((Res_Filt[2] | Mode_Vol[7]) ? 24'sd0 : v3e) +
			         (Res_Filt[3]       ? 24'sd0 : ve_ext);
			vd <= $signed(vd_sum[22:7]);  // arithmetic >>7: bits[22:7] of 24-bit signed sum = 16 bits

			// vlp = vlp - w0*vbp
			c <= 34'sd0;
			s <= 1;
			a <= $signed(F0);
			b <= vbp;
		end
		3'd3: begin
			{vlp, vlp2} <= {vlp2, vlp_next};
			c <= 34'sd0;
			s <= 1;
			b <= vhp;
		end
		3'd4: begin
			{vbp, vbp2} <= {vbp2, vbp_next};
			c <= -(($signed({vlp2, 10'b0}) + $signed({vi,  10'b0})));
			s <= 0;
			a <= $signed({5'b0, _1_Q_lsl10});
			b <= vbp_next;
		end
		3'd5: begin
			{vhp, vhp2} <= {vhp2, vhp_next};
			tmix_s   <= tmix;
			center_s <= center;
		end
		3'd6: begin
			tmix_c_r <= tmix_c;
		end
		3'd7: begin
			c <= 34'sd0;
			s <= 0;
			a <= $signed({12'b0, Mode_Vol[3:0]});
			b <= clamp($signed({vd[15], vd}) + $signed({tmix_c_r[15], tmix_c_r}));
		end
	endcase
end

assign audio = o[19:2];

endmodule
