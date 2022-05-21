module acia (
	// cpu register interface
	input clk,
	input E,
	input reset,
	input rxtxclk,
	input rxtxclk_sel, // 500kHz/2MHz
	input [7:0] din,
	input sel,
	input rs,
	input rw,
	output reg [7:0] dout,
	output irq,

	output tx,
	input rx,

	// parallel data out strobe to io controller
	output dout_strobe
);

parameter TX_DELAY = 8'd16; // delay from writing to the TDR to really write the data from the buffer to the shift register

reg E_d;
always @(posedge clk) E_d <= E;
wire clk_en = ~E_d & E;

assign dout_strobe = clk_en && sel && ~rw && rs;

// the control register
reg [7:0] serial_cr;
reg [7:0] serial_status_s1, serial_status_s2; // synced to clk

assign irq = serial_status_s1[7];

// ---------------- CPU read interface ------------

always @(sel, rw, rs, serial_status_s2, serial_rx_data) begin
	dout = 8'h00;

	if(sel && rw) begin
		if(~rs) dout = serial_status_s2;
		if( rs) dout = serial_rx_data;
	end
end

// ------------------------------ serial UART ---------------------------------
wire serial_irq = ~&serial_cr[1:0] &&
                 ((serial_cr[7] && serial_rx_data_available) ||    // rx irq
                 ((serial_cr[6:5] == 2'b01) && serial_tx_empty));  // tx irq

wire [7:0] serial_status = { serial_irq, 1'b0 /* parity err */, serial_rx_overrun, serial_rx_frame_error,
                             2'b00 /* CTS & DCD */, serial_tx_empty, serial_rx_data_available };

always @(posedge clk) begin
	// synchronizers
	serial_status_s1 <= serial_status;
	serial_status_s2 <= serial_status_s1;
end

// implemented bitrates:
// - 500kHz/64 = 7812.5 bps (ST iKBD)
// - 500kHz/16 = 31250 bps  (ST MIDI)
// only 8N1 framing

// 32MHz/4096 = 7812.5Hz
reg [7:0] serial_clk;
always @(posedge clk)
	serial_clk <= serial_clk + 1'd1;

wire [7:0] serial_clk_cnt = rxtxclk_sel ? {serial_clk[5:0], 2'b00} : serial_clk;
// 16 times serial clock
wire serial_clk_en = (serial_cr[1:0] == 2'b01 && serial_clk_cnt[5:0] == 6'd0) || // 31250 bps
                     (serial_cr[1:0] == 2'b10 && serial_clk_cnt[7:0] == 8'd0);   // 7812.5 bps

// --------------------------- serial receiver -----------------------------
reg [7:0] serial_rx_cnt;         // bit + sub-bit counter
reg [7:0] serial_rx_shift_reg;   // shift register used during reception
reg [7:0] serial_rx_data;
reg [3:0] serial_rx_filter;      // filter to reduce noise
reg serial_rx_frame_error;
reg serial_rx_overrun;
reg serial_rx_data_available;
reg serial_rx_state;
reg serial_in_filtered;
reg serial_data_read;
reg [2:0] serial_data_read_s;

always @(posedge rxtxclk) begin

	serial_data_read_s <= {serial_data_read_s[1:0], serial_data_read};
	serial_rx_filter <= { serial_rx_filter[2:0], rx};

	// serial input must be stable for 3 cycles after the synchronization stage
	// to change state
	if(serial_rx_filter[3:1] == 3'b000) serial_in_filtered <= 1'b0;
	if(serial_rx_filter[3:1] == 3'b111) serial_in_filtered <= 1'b1;

	// serial acia master reset
	if(serial_cr[1:0] == 2'b11) begin
		serial_rx_cnt <= 8'd0;
		serial_rx_data_available <= 1'b0;
		serial_rx_filter <= 4'b1111;
		serial_rx_overrun <= 1'b0;
		serial_rx_frame_error <= 1'b0;
		serial_rx_state <= 1'b0;
	end else begin

		if(serial_clk_en) begin
			// receiver not running
			if(serial_rx_cnt == 8'd0) begin
				if (!serial_rx_state) begin
					// returned to idle state after the stop bit?
					if(serial_in_filtered == 1'b1) serial_rx_state <= 1'b1;
				end	else begin
					// seeing start bit?
					if(serial_in_filtered == 1'b0) begin
						// expecing 10 bits starting half a bit time from now
						serial_rx_cnt <= { 4'd9, 4'd7 };
						serial_rx_state <= 1'b0;
					end
				end
			end else begin
				// receiver is running
				serial_rx_cnt <= serial_rx_cnt - 8'd1;

				// received a bit
				if(serial_rx_cnt[3:0] == 4'd0) begin
					// in the middle of the bit -> shift new bit into msb
					serial_rx_shift_reg <= { serial_in_filtered, serial_rx_shift_reg[7:1] };
				end

				// receiving last (stop) bit
				if(serial_rx_cnt[7:0] == 8'd1) begin
					if(serial_in_filtered == 1'b1) begin
						if (serial_rx_data_available)
							// previous data still not read? report overrun
							serial_rx_overrun <= 1'b1;
						else
							// copy data into rx register 
							serial_rx_data <= serial_rx_shift_reg;  // pure data w/o start and stop bits
						serial_rx_data_available <= 1'b1;
						serial_rx_frame_error <= 1'b0;
					end else
						// report frame error via status register
						serial_rx_frame_error <= 1'b1;
				end
			end
		end

		if (^serial_data_read_s[1:0]) begin
			// read on serial data register
			serial_rx_data_available <= 1'b0;   // read on serial data clears rx status
			serial_rx_overrun <= 1'b0;
		end

	end
end

always @(posedge clk) begin
	if(reset)
		serial_data_read <= 1'b0;
	else if(clk_en && sel && rw && rs)
		// read on serial data register
		serial_data_read <= ~serial_data_read;
end

// --------------------------- serial transmitter -----------------------------
assign tx = serial_tx_shift_reg[0];
reg serial_tx_empty;
reg [7:0] serial_tx_cnt;
reg [7:0] serial_tx_data;
reg serial_tx_data_valid;
reg [2:0] serial_tx_data_valid_s;
reg serial_tx_new_data;
reg [9:0] serial_tx_shift_reg;
reg [7:0] serial_tx_data_dly;
always @(posedge rxtxclk) begin

	serial_tx_data_valid_s <= {serial_tx_data_valid_s[1:0], serial_tx_data_valid};
	if (serial_tx_data_dly != 0) serial_tx_data_dly <= serial_tx_data_dly - 1'd1;

	if (serial_cr[1:0] == 2'b11) begin
		serial_tx_cnt <= 8'd0;
		serial_tx_empty <= 1'b1;
		serial_tx_shift_reg <= 10'b1111111111;
		serial_tx_new_data <= 1'b0;
	end else begin
		// 16 times serial clock
		if(serial_clk_en) begin
			if(serial_tx_cnt == 0) begin
				// start transmission if a byte is in the buffer
				if (serial_tx_new_data && serial_tx_data_dly == 0) begin
					serial_tx_shift_reg <= { 1'b1, serial_tx_data, 1'b0 };  // 8N1, lsb first
					serial_tx_cnt <= { 4'd9, 4'hf };   // 10 bits to go
					serial_tx_new_data <= 1'b0;
					serial_tx_empty <= 1'b1;
				end
			end else begin
				if(serial_tx_cnt[3:0] == 4'h0) begin
					// shift down one bit, fill with 1 bits
					serial_tx_shift_reg <= { 1'b1, serial_tx_shift_reg[9:1] };
				end
				// decrease transmit counter
				serial_tx_cnt <= serial_tx_cnt - 8'd1;
			end
		end

		if (^serial_tx_data_valid_s[2:1]) begin
			// data written to DTR
			serial_tx_data_dly <= TX_DELAY;
			serial_tx_empty <= 1'b0;
			serial_tx_new_data <= 1'b1;
		end
	end

end

always @(posedge clk) begin

	if(reset) begin
		serial_tx_data_valid <= 1'b0;
		serial_cr <= 8'h03;
	end else if(clk_en && sel && ~rw) begin

		// write to serial control register
		if(~rs) begin
			serial_cr <= din;
			if (din[1:0] == 2'b11) begin
				serial_tx_data_valid <= 1'b0;
			end
		end

		// write to serial data register
		if(rs) begin
			serial_tx_data <= din;
			serial_tx_data_valid <= ~serial_tx_data_valid;
		end
	end
end

endmodule
