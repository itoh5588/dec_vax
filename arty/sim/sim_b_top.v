// SPDX-License-Identifier: BSD-2-Clause
// Copyright (c) 2026 Akio Itoh
//
// sim_b_top.v - the track B bench: arty_sys (VAX_EXT_MEM) with its memory
// on arty_mem_mig and that on the MIG user interface model. Two clocks:
// clk (the core) and ui_clk (the MIG's), driven by tb_arty.cpp at an
// unrelated ratio. The ports are arty_sys's, as on the track A bench.

`default_nettype none

module sim_b_top #(
	parameter CLK_HZ    = 40000000,
	parameter UART_CLKS = 347
) (
	input  clk,
	input  ui_clk,
	input  rst,
	input  uart_rxd,
	output uart_txd,
	output cpu_halted,
	output cpu_running
`ifdef ARTY_DZ
	,
	output dz_txd,
	input  dz_rxd
`endif
);

	wire        xm_req, xm_we, xm_done, xm_busy, xm_ready, xm_rstb;
	wire [22:0] xm_adr;
	wire [31:0] xm_dat, xm_rdat;
	wire  [3:0] xm_sel;
	wire  [1:0] xm_ridx;

	arty_sys #(.CLK_HZ(CLK_HZ), .UART_CLKS(UART_CLKS), .CACHEIDX(10)) sys (
`ifdef ARTY_SD
		.sd_cs_n    (),
		.sd_sclk    (),
		.sd_mosi    (),
		.sd_miso    (1'b1),
		.sd_initok  (),
		.sd_error   (),
		.sd_active  (),
`endif
`ifdef ARTY_BOOTROM
		.no_autoboot(1'b0),
		.reboot_req (),
`endif
`ifdef ARTY_DZ
		.dz_txd     (dz_txd),
		.dz_rxd     (dz_rxd),
`endif
		.clk        (clk),
		.rst        (rst),
		.uart_rxd   (uart_rxd),
		.uart_txd   (uart_txd),
		.cpu_halted (cpu_halted),
		.cpu_running(cpu_running),
		.ldr_active (),
		.ldr_ok     (),
		.ldr_bad    (),
		.mem_miss   (),
		.xm_req     (xm_req),
		.xm_we      (xm_we),
		.xm_adr     (xm_adr),
		.xm_dat     (xm_dat),
		.xm_sel     (xm_sel),
		.xm_done    (xm_done),
		.xm_busy    (xm_busy),
		.xm_ready   (xm_ready),
		.xm_rdat    (xm_rdat),
		.xm_ridx    (xm_ridx),
		.xm_rstb    (xm_rstb)
	);

	wire [27:0]  app_addr;
	wire [2:0]   app_cmd;
	wire         app_en, app_rdy, app_wdf_wren, app_wdf_end, app_wdf_rdy;
	wire [127:0] app_wdf_data, app_rd_data;
	wire [15:0]  app_wdf_mask;
	wire         app_rd_data_valid, calib;

	arty_mem_mig bridge (
		.clk      (clk),
		.rst      (rst),
		.xm_req   (xm_req),
		.xm_we    (xm_we),
		.xm_adr   (xm_adr),
		.xm_dat   (xm_dat),
		.xm_sel   (xm_sel),
		.xm_done  (xm_done),
		.xm_busy  (xm_busy),
		.xm_ready (xm_ready),
		.xm_rdat  (xm_rdat),
		.xm_ridx  (xm_ridx),
		.xm_rstb  (xm_rstb),
		.ui_clk   (ui_clk),
		.ui_rst   (rst),
		.init_calib_complete(calib),
		.app_addr (app_addr),
		.app_cmd  (app_cmd),
		.app_en   (app_en),
		.app_rdy  (app_rdy),
		.app_wdf_data(app_wdf_data),
		.app_wdf_mask(app_wdf_mask),
		.app_wdf_wren(app_wdf_wren),
		.app_wdf_end (app_wdf_end),
		.app_wdf_rdy (app_wdf_rdy),
		.app_rd_data (app_rd_data),
		.app_rd_data_valid(app_rd_data_valid)
	);

	mig_ui_model mig (
		.ui_clk   (ui_clk),
		.rst      (rst),
		.init_calib_complete(calib),
		.app_addr (app_addr),
		.app_cmd  (app_cmd),
		.app_en   (app_en),
		.app_rdy  (app_rdy),
		.app_wdf_data(app_wdf_data),
		.app_wdf_mask(app_wdf_mask),
		.app_wdf_wren(app_wdf_wren),
		.app_wdf_end (app_wdf_end),
		.app_wdf_rdy (app_wdf_rdy),
		.app_rd_data (app_rd_data),
		.app_rd_data_valid(app_rd_data_valid)
	);

`ifdef VAX_WATCH
	// debugging (make simb SIM_DEFS=-DVAX_WATCH): every CPU write to the
	// virtual longwords 7FFE2680-7FFE269F (the P1 queue headers VMS's
	// STARTUP hung on), with the clock, the instruction's PC, the data and
	// PCBB (the process)
	reg [63:0] w_clk;
	initial w_clk = 64'd0;
	always @(posedge sys.clk) begin
		w_clk <= w_clk + 64'd1;
		if (sys.core.cpu_stb && sys.core.cpu_write && sys.core.cpu_ack &&
		    sys.core.cpu_addr[31:5] == 27'h3FFF134)
			$display("W %0d pc %08x va %08x d %08x sz %0d pcbb %08x",
			    w_clk, sys.core.cpu.oldpc, sys.core.cpu_addr,
			    sys.core.cpu_wdata, sys.core.cpu_size,
			    sys.core.cpu.ipr_reg[16]);
	end
`endif

endmodule

`default_nettype wire
