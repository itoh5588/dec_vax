//============================================================================
//  arty_sdcard.v - RP07 unit 0 of r-vax on an SD card (Pmod MicroSD, track
//  B): vax_core's block device port (dk_*, MiSTer's hps_io interface) on
//  sdspi_ctl/sdspi_phy (SPI mode).
//
//  The card holds the RP07 image raw, from block LBA_OFS on. After reset
//  the card is initialized (op_init, retried every 0.5 s until it answers)
//  and unit 0 is "mounted" (img_mounted with img_size = IMG_BYTES), as
//  MiSTer's Main does when an image is chosen. Unit 1 stays empty.
//
//  The transfers as hps_io makes them (see the fork's sim/hpsdisk.h):
//    read  (dk_rd): dk_ack, then the 512 bytes as dk_buff_wr pulses with
//                   dk_buff_addr/dk_buff_dout, then dk_ack low
//    write (dk_wr): dk_ack, then the 512 bytes read from the core at
//                   dk_buff_addr (dk_buff_din0, two clocks after the
//                   address), then dk_ack low once the card has them
//  sdspi_ctl gives and takes 16-bit little-endian words: a word read is
//  two bytes for the core; for a write the 512 bytes are first copied
//  into a buffer sdspi_ctl reads word by word.
//
//  SPDX-License-Identifier: BSD-2-Clause
//  Copyright (c) 2026 Akio Itoh
//============================================================================

`default_nettype none

module arty_sdcard #(
	parameter CLK_HZ    = 40000000,
	parameter SLOWDIV   = 59,           // init SCLK: CLK_HZ / 2(SLOWDIV+1), < 400 kHz
	parameter FASTDIV   = 2,            // then: CLK_HZ / 2(FASTDIV+1)
	parameter [63:0] IMG_BYTES = 64'd516096000,   // a full RP07
	parameter [31:0] LBA_OFS   = 32'd0
) (
	input             clk,
	input             rst,

	// vax_core's block device port
	input      [31:0] dk_lba0,
	input       [1:0] dk_rd,
	input       [1:0] dk_wr,
	output reg  [1:0] dk_ack,
	output reg  [8:0] dk_buff_addr,
	output reg  [7:0] dk_buff_dout,
	output reg        dk_buff_wr,
	input       [7:0] dk_buff_din0,
	output reg  [1:0] img_mounted,
	output            img_readonly,
	output     [63:0] img_size,

	// the card
	output            sd_cs_n,
	output            sd_sclk,
	output            sd_mosi,
	input             sd_miso,

	// status
	output            sd_initok,
	output reg        sd_error,         // the last transfer failed
	output            sd_active
);

	assign img_readonly = 1'b0;
	assign img_size     = IMG_BYTES;

	// ------------------------------------------------------------ 1 ms
	localparam integer MSDIV = CLK_HZ / 1000;
	reg [31:0] msc;
	reg        ce_msec;
	always @(posedge clk) begin
		ce_msec <= 1'b0;
		if (msc == MSDIV - 1) begin
			msc     <= 0;
			ce_msec <= 1'b1;
		end else
			msc <= msc + 1;
	end

	// ------------------------------------------------------------ sdspi
	localparam [2:0] OP_INIT = 3'b001, OP_READ = 3'b100, OP_WRITE = 3'b110;

	reg   [2:0] op;
	reg         go;
	reg  [31:0] lba;
	wire        busy, initok, v2, hc;
	wire  [7:0] err, r1, token;
	wire [31:0] resp;
	wire        buf_we;
	wire  [7:0] buf_addr, wbuf_addr;
	wire [15:0] buf_di, wbuf_data;
	wire  [7:0] phy_div, phy_txd, phy_rxd;
	wire        phy_start, phy_done, phy_busy;

	sdspi_ctl #(.SLOWDIV(SLOWDIV)) ctl (
		.CLK      (clk),
		.RESET    (rst),
		.CE_MSEC  (ce_msec),
		.OP       (op),
		.GO       (go),
		.LBA      (lba),
		.NBLK     (16'd1),
		.HOLD     (1'b0),
		.ABORT    (1'b0),
		.FASTDIV  (FASTDIV[7:0]),
		.BUSY     (busy),
		.INITOK   (initok),
		.V2       (v2),
		.HC       (hc),
		.ERR      (err),
		.R1       (r1),
		.TOKEN    (token),
		.RESP     (resp),
		.BUF_WE   (buf_we),
		.BUF_ADDR (buf_addr),
		.BUF_DI   (buf_di),
		.WBUF_ADDR(wbuf_addr),
		.WBUF_DATA(wbuf_data),
		.O_CS_N   (sd_cs_n),
		.PHY_DIV  (phy_div),
		.PHY_START(phy_start),
		.PHY_TXD  (phy_txd),
		.PHY_RXD  (phy_rxd),
		.PHY_DONE (phy_done)
	);

	sdspi_phy phy (
		.CLK      (clk),
		.RESET    (rst),
		.DIV      (phy_div),
		.START    (phy_start),
		.TXD      (phy_txd),
		.RXD      (phy_rxd),
		.DONE     (phy_done),
		.BUSY     (phy_busy),
		.O_SCLK   (sd_sclk),
		.O_MOSI   (sd_mosi),
		.I_MISO   (sd_miso)
	);

	assign sd_initok = initok;

	// the block to write, bytes; sdspi_ctl reads it as words (async)
	(* ram_style = "distributed" *)
	reg [7:0] wb [0:511];
	assign wbuf_data = {wb[{wbuf_addr, 1'b1}], wb[{wbuf_addr, 1'b0}]};

	// ------------------------------------------------------------ control
	localparam [3:0] S_START = 4'd0, S_INIT = 4'd1, S_MOUNT = 4'd2,
	                 S_IDLE  = 4'd3, S_RD   = 4'd4, S_RDHI  = 4'd5,
	                 S_WCOPY = 4'd6, S_WR   = 4'd7, S_END   = 4'd8,
	                 S_RETRY = 4'd9;

	reg  [3:0] st, after;
	reg        started;                 // BUSY has been seen high
	reg  [9:0] i;                       // byte of a write copy
	reg  [1:0] wt;
	reg  [9:0] ms;                      // milliseconds to wait
	reg  [7:0] hi;                      // the high byte of a word read

	assign sd_active = (st == S_RD || st == S_RDHI || st == S_WCOPY || st == S_WR);

	initial begin
		st = S_START; go = 1'b0; dk_ack = 2'b00; dk_buff_wr = 1'b0;
		img_mounted = 2'b00; sd_error = 1'b0; ms = 10'd0;
	end

	always @(posedge clk) begin
		go          <= 1'b0;
		dk_buff_wr  <= 1'b0;
		img_mounted <= 2'b00;
		if (ce_msec && ms != 0)
			ms <= ms - 10'd1;
		if (go)
			started <= 1'b0;
		else if (busy)
			started <= 1'b1;

		if (rst) begin
			st     <= S_START;
			dk_ack <= 2'b00;
			ms     <= 10'd5;
		end else case (st)
		S_START: if (ms == 0) begin          // a few ms after reset
			op      <= OP_INIT;
			go      <= 1'b1;
			started <= 1'b0;
			st      <= S_INIT;
		end
		S_INIT: if (started && !busy) begin
			if (initok)
				st <= S_MOUNT;
			else begin
				ms <= 10'd500;               // no card (yet): again
				st <= S_START;
			end
		end
		S_MOUNT: begin
			img_mounted <= 2'b01;
			st          <= S_IDLE;
		end
		S_IDLE: if (dk_rd[0]) begin
			lba     <= dk_lba0 + LBA_OFS;
			op      <= OP_READ;
			go      <= 1'b1;
			started <= 1'b0;
			dk_ack  <= 2'b01;
			st      <= S_RD;
		end else if (dk_wr[0]) begin
			lba          <= dk_lba0 + LBA_OFS;
			dk_ack       <= 2'b01;
			dk_buff_addr <= 9'd0;
			i            <= 10'd0;
			wt           <= 2'd2;
			st           <= S_WCOPY;
		end
		S_RD: begin                          // a word: its low byte now
			if (buf_we) begin
				dk_buff_addr <= {buf_addr, 1'b0};
				dk_buff_dout <= buf_di[7:0];
				dk_buff_wr   <= 1'b1;
				hi           <= buf_di[15:8];
				st           <= S_RDHI;
			end else if (started && !busy) begin
				sd_error <= (err != 8'd0);
				st       <= S_END;
			end
		end
		S_RDHI: begin                        // and the high byte
			dk_buff_addr <= {dk_buff_addr[8:1], 1'b1};
			dk_buff_dout <= hi;
			dk_buff_wr   <= 1'b1;
			st           <= S_RD;
		end
		S_WCOPY: begin                       // the core's block into wb
			if (wt != 0)
				wt <= wt - 2'd1;
			else begin
				wb[i[8:0]] <= dk_buff_din0;
				if (i == 10'd511) begin
					op      <= OP_WRITE;
					go      <= 1'b1;
					started <= 1'b0;
					st      <= S_WR;
				end else begin
					i            <= i + 10'd1;
					dk_buff_addr <= i[8:0] + 9'd1;
					wt           <= 2'd2;
				end
			end
		end
		S_WR: if (started && !busy) begin
			sd_error <= (err != 8'd0);
			st       <= S_END;
		end
		S_END: begin                         // ack low; wait for rd/wr low
			dk_ack <= 2'b00;
			if (!dk_rd[0] && !dk_wr[0])
				st <= S_IDLE;
		end
		default: st <= S_START;
		endcase
	end

endmodule

`default_nettype wire
