// ----------------------------------------------------------------------------
// SID DAC - reDIP-SID
// Quartus 13.1 / Cyclone III compatibility:
//   - logic -> wire/reg
//   - always_comb -> assign / always @(*)
//   - Unpacked arrays [N] kept (Q13.1 supports them in generate/always)
// ----------------------------------------------------------------------------

`default_nettype none

module sid_dac #(
    parameter  BITS       = 12,
    parameter  _2R_DIV_R  = 2.20,
    parameter  TERM       = 0
)(
    input  wire [BITS-1:0] vin,
    output wire [BITS-1:0] vout
);
    localparam SCALEBITS  = 4;
    localparam MSB        = BITS+SCALEBITS-1;

    reg [MSB:0] bitval[BITS];
    reg [MSB:0] bitsum[BITS];

    generate
        genvar i;
        for (i = 0; i < BITS; i = i+1) begin : init
            always @(*) begin
                bitsum[i] =
                    (i == 0 ? (1 << (SCALEBITS - 1)) : bitsum[i-1]) +
                    (vin[i] ? bitval[i] : 1'd0);
            end
        end
    endgenerate

    assign vout = bitsum[BITS-1][MSB-:BITS];

    initial begin
        if (_2R_DIV_R == 2.20 && TERM == 0 && SCALEBITS == 4) begin
            case (BITS)
              12: begin
                    bitval[0]  = 'h21;
                    bitval[1]  = 'h30;
                    bitval[2]  = 'h55;
                    bitval[3]  = 'ha0;
                    bitval[4]  = 'h135;
                    bitval[5]  = 'h256;
                    bitval[6]  = 'h486;
                    bitval[7]  = 'h8c6;
                    bitval[8]  = 'h1102;
                    bitval[9]  = 'h20f8;
                    bitval[10] = 'h3fec;
                    bitval[11] = 'h7bed;
                  end
               8: begin
                    bitval[0]  = 'h1d;
                    bitval[1]  = 'h2a;
                    bitval[2]  = 'h4b;
                    bitval[3]  = 'h8d;
                    bitval[4]  = 'h110;
                    bitval[5]  = 'h20e;
                    bitval[6]  = 'h3fb;
                    bitval[7]  = 'h7b8;
                  end
              11: begin
                    bitval[0]  = 'h20;
                    bitval[1]  = 'h2f;
                    bitval[2]  = 'h52;
                    bitval[3]  = 'h9c;
                    bitval[4]  = 'h12b;
                    bitval[5]  = 'h243;
                    bitval[6]  = 'h463;
                    bitval[7]  = 'h880;
                    bitval[8]  = 'h107b;
                    bitval[9]  = 'h1ff4;
                    bitval[10] = 'h3df3;
                  end
            endcase
        end
    end
endmodule
