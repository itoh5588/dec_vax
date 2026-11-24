//============================================================================
//  arty_mem_mig.v - the r-vax memory port (vax_core's xm_*, VAX_EXT_MEM) on
//  the Xilinx MIG's user interface (DDR3L of the Arty S7, track B).
//
//  The core (clk, 40 MHz) and the MIG (ui_clk, 80 MHz) are not related:
//  a request is handed over by a toggle (req_t) and answered by another
//  (ack_t), each through two flip-flops; the data next to a toggle has been
//  stable for clocks when the toggle is seen, so it crosses unsynchronized
//  (set_clock_groups -asynchronous in the XDC).
//
//  The DDR3L is x16 with bursts of 8: one MIG command moves 16 bytes,
//  128 bits of app data, exactly one line of the core's cache.
//    read:  the line at adr & ~3: app_addr = {adr[22:2], 000} (MIG addresses
//           count 16-bit words); the 128 bits come back as 4 xm_rstb with
//           xm_ridx 0..3, then xm_done
//    write: one longword with byte enables: the 128 bits hold it at its
//           place, app_wdf_mask (1 = not written) keeps the other 12 bytes
//  xm_busy is high from the clock a request is taken until the clock after
//  xm_done, as on vax_sdram. xm_ready is the MIG's init_calib_complete.
//
//  SPDX-License-Identifier: BSD-2-Clause
//  Copyright (c) 2026 Akio Itoh
//============================================================================

`default_nettype none

module arty_mem_mig #(
	parameter AW = 28                     // the MIG's app_addr width
) (
	// the core's side
	input              clk,
	input              rst,
	input              xm_req,
	input              xm_we,
	input       [22:0] xm_adr,
	input       [31:0] xm_dat,
	input        [3:0] xm_sel,
	output reg         xm_done,
	output             xm_busy,
	output             xm_ready,
	output reg  [31:0] xm_rdat,
	output reg   [1:0] xm_ridx,
	output reg         xm_rstb,

	// the MIG's user interface (ui_clk)
	input              ui_clk,
	input              ui_rst,
	input              init_calib_complete,
	output reg  [AW-1:0] app_addr,
	output reg   [2:0] app_cmd,
	output reg         app_en,
	input              app_rdy,
	output reg [127:0] app_wdf_data,
	output reg  [15:0] app_wdf_mask,
	output reg         app_wdf_wren,
	output             app_wdf_end,
	input              app_wdf_rdy,
	input      [127:0] app_rd_data,
	input              app_rd_data_valid
);

	localparam [2:0] CMD_WRITE = 3'b000, CMD_READ = 3'b001;

	// ------------------------------------------------------------ core side
	reg        c_we;                    // the request, held for the UI side
	reg [22:0] c_adr;
	reg [31:0] c_dat;
	reg  [3:0] c_sel;
	reg        req_t;                   // toggles: a new request
	reg  [1:0] ack_s;                   // ack_t into clk
	reg        ack_seen;
	(* ASYNC_REG = "TRUE" *) reg [1:0] rdy_s;
	reg [127:0] u_line;                 // UI side: the line read

	localparam [2:0] C_IDLE = 3'd0, C_WAIT = 3'd1, C_OUT = 3'd2,
	                 C_DONE = 3'd3, C_GAP = 3'd4;
	reg  [2:0] cs;
	reg  [1:0] k;

	assign xm_busy  = (cs != C_IDLE);
	assign xm_ready = rdy_s[1];

	initial begin
		cs = C_IDLE; req_t = 1'b0; ack_seen = 1'b0;
		xm_done = 1'b0; xm_rstb = 1'b0; rdy_s = 2'b00; ack_s = 2'b00;
	end

	always @(posedge clk) begin
		rdy_s   <= {rdy_s[0], init_calib_complete};
		ack_s   <= {ack_s[0], ack_t};
		xm_done <= 1'b0;
		xm_rstb <= 1'b0;
		if (rst) begin
			cs       <= C_IDLE;
			ack_seen <= ack_s[1];
		end else case (cs)
		C_IDLE: if (xm_req && xm_ready) begin
			c_we  <= xm_we;
			c_adr <= xm_adr;
			c_dat <= xm_dat;
			c_sel <= xm_sel;
			req_t <= ~req_t;
			cs    <= C_WAIT;
		end
		C_WAIT: if (ack_s[1] != ack_seen) begin
			ack_seen <= ack_s[1];
			k        <= 2'd0;
			cs       <= c_we ? C_DONE : C_OUT;
		end
		C_OUT: begin                     // the line, longword by longword
			xm_rdat <= u_line[32 * k +: 32];
			xm_ridx <= k;
			xm_rstb <= 1'b1;
			k       <= k + 2'd1;
			if (k == 2'd3)
				cs <= C_DONE;
		end
		C_DONE: begin
			xm_done <= 1'b1;
			cs      <= C_GAP;
		end
		C_GAP:  cs <= C_IDLE;            // xm_req still high this clock
		default: cs <= C_IDLE;
		endcase
	end

	// ------------------------------------------------------------ UI side
	(* ASYNC_REG = "TRUE" *) reg [1:0] req_s; // req_t into ui_clk
	reg        u_seen;                  // the last request taken
	reg        ack_t;
	reg        cmd_ok, wdf_ok;

	localparam [1:0] U_IDLE = 2'd0, U_CMD = 2'd1, U_RDATA = 2'd2;
	reg  [1:0] us;

	assign app_wdf_end = app_wdf_wren;   // 4:1, BL8: one beat is the burst

	initial begin
		us = U_IDLE; ack_t = 1'b0; req_s = 2'b00; u_seen = 1'b0;
		app_en = 1'b0; app_wdf_wren = 1'b0;
	end

	always @(posedge ui_clk) begin
		req_s <= {req_s[0], req_t};
		if (ui_rst) begin
			u_seen       <= req_s[1];
			us           <= U_IDLE;
			app_en       <= 1'b0;
			app_wdf_wren <= 1'b0;
		end else case (us)
		U_IDLE: if (req_s[1] != u_seen) begin
			u_seen   <= req_s[1];
			app_addr <= {{(AW - 24){1'b0}}, c_adr[22:2], 3'b000};
			app_cmd  <= c_we ? CMD_WRITE : CMD_READ;
			app_en   <= 1'b1;
			cmd_ok   <= 1'b0;
			if (c_we) begin
				app_wdf_data <= {4{c_dat}};
				app_wdf_mask <= ~({12'd0, c_sel} << (4 * c_adr[1:0]));
				app_wdf_wren <= 1'b1;
				wdf_ok       <= 1'b0;
			end else
				wdf_ok       <= 1'b1;
			us <= U_CMD;
		end
		U_CMD: begin
			// command and write data are taken independently
			if (app_en && app_rdy) begin
				app_en <= 1'b0;
				cmd_ok <= 1'b1;
			end
			if (app_wdf_wren && app_wdf_rdy) begin
				app_wdf_wren <= 1'b0;
				wdf_ok       <= 1'b1;
			end
			if ((cmd_ok || (app_en && app_rdy)) &&
			    (wdf_ok || (app_wdf_wren && app_wdf_rdy))) begin
				if (app_cmd == CMD_WRITE) begin
					ack_t <= ~ack_t;      // a write is posted
					us    <= U_IDLE;
				end else
					us    <= U_RDATA;
			end
		end
		U_RDATA: if (app_rd_data_valid) begin
			u_line <= app_rd_data;
			ack_t  <= ~ack_t;
			us     <= U_IDLE;
		end
		default: us <= U_IDLE;
		endcase
	end

endmodule

`default_nettype wire
