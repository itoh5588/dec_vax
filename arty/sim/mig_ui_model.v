// SPDX-License-Identifier: BSD-2-Clause
// Copyright (c) 2026 Akio Itoh
//
// mig_ui_model.v - the Xilinx MIG's user interface as the track B bench
// needs it (not a model of the MIG or of DDR3): 32 MB of 128-bit lines;
// app_addr counts 16-bit words (16 bytes a command, as x16 with BL8); a
// read comes back RLAT clocks later; a write takes the 16 bytes under
// app_wdf_mask (1 = not written). app_rdy and app_wdf_rdy drop now and
// then, so that the bridge waits. init_calib_complete comes after CALIB
// clocks.

`default_nettype none

module mig_ui_model #(
	parameter AW    = 28,
	parameter RLAT  = 20,
	parameter CALIB = 200
) (
	input              ui_clk,
	input              rst,
	output reg         init_calib_complete,
	input     [AW-1:0] app_addr,
	input        [2:0] app_cmd,
	input              app_en,
	output             app_rdy,
	input      [127:0] app_wdf_data,
	input       [15:0] app_wdf_mask,
	input              app_wdf_wren,
	input              app_wdf_end,
	output             app_wdf_rdy,
	output reg [127:0] app_rd_data,
	output reg         app_rd_data_valid
);

	reg [127:0] mem [0:(1 << 21) - 1];      // 32 MB
	reg  [15:0] cnt;
	reg   [7:0] lfsr;
	reg  [20:0] rd_line;
	reg   [7:0] rd_wait;
	reg         rd_pend;
	integer     i;

	initial begin
		init_calib_complete = 1'b0;
		cnt = 0; lfsr = 8'h5A; rd_pend = 1'b0; app_rd_data_valid = 1'b0;
	end

	// busy now and then: 1 clock in 8, by a little LFSR
	assign app_rdy     = init_calib_complete && (lfsr[2:0] != 3'd0);
	assign app_wdf_rdy = init_calib_complete && (lfsr[5:3] != 3'd0);

	wire [20:0] line = app_addr[23:3];

	always @(posedge ui_clk) begin
		lfsr <= {lfsr[6:0], lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3]};
		app_rd_data_valid <= 1'b0;
		if (rst) begin
			cnt <= 0;
			init_calib_complete <= 1'b0;
			rd_pend <= 1'b0;
		end else begin
			if (cnt != CALIB)
				cnt <= cnt + 1;
			else
				init_calib_complete <= 1'b1;
			if (app_wdf_wren && app_wdf_rdy) begin
				// the bridge gives the data no later than the command
				for (i = 0; i < 16; i = i + 1)
					if (!app_wdf_mask[i])
						mem[line][8*i +: 8] <= app_wdf_data[8*i +: 8];
			end
			if (app_en && app_rdy && app_cmd == 3'b001) begin
				rd_line <= line;
				rd_wait <= RLAT;
				rd_pend <= 1'b1;
			end
			if (rd_pend) begin
				if (rd_wait == 0) begin
					app_rd_data       <= mem[rd_line];
					app_rd_data_valid <= 1'b1;
					rd_pend           <= 1'b0;
				end else
					rd_wait <= rd_wait - 1;
			end
		end
	end

endmodule

`default_nettype wire
