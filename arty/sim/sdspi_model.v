// SPDX-License-Identifier: BSD-2-Clause
// Copyright (c) 2026 Akio Itoh
//
// sdspi_model.v - sdspi_ctl and sdspi_phy for the Verilator bench (the real
// ones are VHDL): the same ports, the card replaced by the bench's disk
// image through DPI (sd_rd_byte, sd_wr_byte in tb_arty.cpp). Timing is
// made up: init takes INIT_CLK clocks, a block starts after LAT clocks and
// moves a 16-bit word every WCLK clocks. HC is set (block addressing).

`default_nettype none

module sdspi_ctl #(
	parameter SLOWDIV  = 99,
	parameter INIT_CLK = 4000,
	parameter LAT      = 400,
	parameter WCLK     = 16
) (
	input             CLK,
	input             RESET,
	input             CE_MSEC,
	input       [2:0] OP,
	input             GO,
	input      [31:0] LBA,
	input      [15:0] NBLK,
	input             HOLD,
	input             ABORT,
	input       [7:0] FASTDIV,
	output reg        BUSY,
	output reg        INITOK,
	output            V2,
	output            HC,
	output reg  [7:0] ERR,
	output      [7:0] R1,
	output      [7:0] TOKEN,
	output     [31:0] RESP,
	output reg        BUF_WE,
	output reg  [7:0] BUF_ADDR,
	output reg [15:0] BUF_DI,
	output reg  [7:0] WBUF_ADDR,
	input      [15:0] WBUF_DATA,
	output            O_CS_N,
	output      [7:0] PHY_DIV,
	output            PHY_START,
	output      [7:0] PHY_TXD,
	input       [7:0] PHY_RXD,
	input             PHY_DONE
);

	import "DPI-C" function int sd_rd_byte(input int lba, input int i);
	import "DPI-C" function void sd_wr_byte(input int lba, input int i, input int v);

	assign V2 = 1'b1; assign HC = 1'b1;
	assign R1 = 8'd0; assign TOKEN = 8'd0; assign RESP = 32'd0;
	assign O_CS_N = !BUSY; assign PHY_DIV = 8'd0; assign PHY_START = 1'b0;
	assign PHY_TXD = 8'hFF;

	reg  [2:0] op;
	reg [31:0] lba, t;
	reg  [8:0] w;                       // word 0..256
	reg        wphase;
	integer    lo, hi;

	initial begin
		BUSY = 1'b0; INITOK = 1'b0; ERR = 8'd0; BUF_WE = 1'b0;
	end

	always @(posedge CLK) begin
		BUF_WE <= 1'b0;
		if (RESET) begin
			BUSY   <= 1'b0;
			INITOK <= 1'b0;
		end else if (!BUSY) begin
			if (GO) begin
				op     <= OP;
				lba    <= LBA;
				t      <= (OP == 3'b001) ? INIT_CLK : LAT;
				w      <= 9'd0;
				wphase <= 1'b0;
				ERR    <= 8'd0;
				BUSY   <= 1'b1;
			end
		end else if (t != 0)
			t <= t - 1;
		else case (op)
		3'b001: begin                   // init
			INITOK <= 1'b1;
			BUSY   <= 1'b0;
		end
		3'b100: begin                   // read a block
			if (w == 9'd256)
				BUSY <= 1'b0;
			else begin
				lo = sd_rd_byte(lba, 2 * w);
				hi = sd_rd_byte(lba, 2 * w + 1);
				BUF_DI   <= {hi[7:0], lo[7:0]};
				BUF_ADDR <= w[7:0];
				BUF_WE   <= 1'b1;
				w        <= w + 9'd1;
				t        <= WCLK;
			end
		end
		3'b110: begin                   // write a block: WBUF word by word
			if (w == 9'd256)
				BUSY <= 1'b0;
			else if (!wphase) begin
				WBUF_ADDR <= w[7:0];
				wphase    <= 1'b1;
			end else begin
				sd_wr_byte(lba, 2 * w, {24'd0, WBUF_DATA[7:0]});
				sd_wr_byte(lba, 2 * w + 1, {24'd0, WBUF_DATA[15:8]});
				wphase <= 1'b0;
				w      <= w + 9'd1;
				t      <= WCLK;
			end
		end
		default: begin
			ERR  <= 8'd11;
			BUSY <= 1'b0;
		end
		endcase
	end

endmodule

module sdspi_phy (
	input        CLK,
	input        RESET,
	input  [7:0] DIV,
	input        START,
	input  [7:0] TXD,
	output [7:0] RXD,
	output       DONE,
	output       BUSY,
	output       O_SCLK,
	output       O_MOSI,
	input        I_MISO
);
	assign RXD = 8'hFF; assign DONE = 1'b0; assign BUSY = 1'b0;
	assign O_SCLK = 1'b0; assign O_MOSI = 1'b1;
endmodule

`default_nettype wire
