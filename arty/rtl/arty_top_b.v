//============================================================================
//  arty_top_b.v - Digilent Arty S7-50 top level of the r-vax port, track B:
//  32 MB of the DDR3L (MIG) as main memory, console on the USB UART, RP07
//  unit 0 on a microSD card in a Pmod MicroSD at JD (arty_sdcard.v).
//
//    CLK100MHZ -> MMCM (VCO 800 MHz) -> 40 MHz core, 160 MHz MIG system
//                                       clock, 200 MHz MIG reference clock
//    ck_rst (the RESET button, active low) or MMCM not locked -> reset;
//    the core waits for the MIG's calibration as well (mem_ready)
//
//  LEDs:  led[0] CPU running (blinks)   led[1] CPU halted (console monitor)
//         led[2] DDR3 calibrated        led[3] download in progress
//         RGB0 green: last download ACK   RGB0 red: last download NAK
//         RGB1 green: SD card initialized RGB1 red: last SD transfer failed
//         RGB1 blue: SD transfer going on
//  JC1/JC2: the DZ11's line 0 (TX out, RX in): 4.3BSD's tty00
//  SW0:   on = no boot from the boot ROM after reset (4.3BSD's /boot,
//         copied to 0 and started: power on, and 4.3BSD comes up); off
//         = boot (arty_sys, ARTY_BOOTROM); 4.3BSD's reboot resets the
//         system and so boots again, as the 8600's console does
//  SW1:   with SW0 off, on = the boot ROM boots VMS instead (VMB from
//         the ROM, the system disk the RP07 on the card, unit 0)
//
//  SPDX-License-Identifier: BSD-2-Clause
//  Copyright (c) 2026 Akio Itoh
//============================================================================

`default_nettype none

module arty_top_b (
	input         CLK100MHZ,
	input         ck_rst,               // active low
	input         uart_txd_in,
	output        uart_rxd_out,
	output  [3:0] led,
	output        led0_r,
	output        led0_g,
	output        led0_b,
	output        led1_r,
	output        led1_g,
	output        led1_b,
	input   [1:0] sw,

	// Pmod JC: the DZ11's line 0 (a USB-UART, 3.3 V)
	output        jc_txd,               // JC1
	input         jc_rxd,               // JC2

	// Pmod MicroSD at JD (SPI mode)
	output        sd_cs_n,
	output        sd_sclk,
	output        sd_mosi,
	input         sd_miso,

	// DDR3L
	inout  [15:0] ddr3_dq,
	inout   [1:0] ddr3_dqs_n,
	inout   [1:0] ddr3_dqs_p,
	output [13:0] ddr3_addr,
	output  [2:0] ddr3_ba,
	output        ddr3_ras_n,
	output        ddr3_cas_n,
	output        ddr3_we_n,
	output        ddr3_reset_n,
	output  [0:0] ddr3_ck_p,
	output  [0:0] ddr3_ck_n,
	output  [0:0] ddr3_cke,
	output  [0:0] ddr3_cs_n,
	output  [1:0] ddr3_dm,
	output  [0:0] ddr3_odt
);

	localparam CLK_HZ = 40000000;

	// ------------------------------------------------------------ clocks
	wire clk_fb, clk_fb_b, clk40_u, clk160_u, clk200_u;
	wire clk, clk_sys, clk_ref;
	wire locked;
	wire clk100;

	// R2 is in bank 34, the DDR3L's, whose clock management tile the MIG
	// takes: through a BUFG, the MMCM may sit in another one (as w11 does)
	BUFG bufg_in (.I(CLK100MHZ), .O(clk100));

	MMCME2_BASE #(
		.CLKIN1_PERIOD   (10.0),        // 100 MHz
		.DIVCLK_DIVIDE   (1),
		.CLKFBOUT_MULT_F (8.0),         // VCO 800 MHz
		.CLKOUT0_DIVIDE_F(20.0),        // 40 MHz: the core
		.CLKOUT1_DIVIDE  (5),           // 160 MHz: MIG sys_clk_i
		.CLKOUT2_DIVIDE  (4)            // 200 MHz: MIG clk_ref_i
	) mmcm (
		.CLKIN1   (clk100),
		.CLKFBIN  (clk_fb_b),
		.CLKFBOUT (clk_fb),
		.CLKFBOUTB(),
		.CLKOUT0  (clk40_u),
		.CLKOUT0B (),
		.CLKOUT1  (clk160_u),
		.CLKOUT1B (),
		.CLKOUT2  (clk200_u),
		.CLKOUT2B (),
		.CLKOUT3  (), .CLKOUT3B(),
		.CLKOUT4  (), .CLKOUT5 (), .CLKOUT6(),
		.LOCKED   (locked),
		.PWRDWN   (1'b0),
		.RST      (1'b0)
	);

	BUFG bufg_fb  (.I(clk_fb),   .O(clk_fb_b));
	BUFG bufg_clk (.I(clk40_u),  .O(clk));
	BUFG bufg_sys (.I(clk160_u), .O(clk_sys));
	BUFG bufg_ref (.I(clk200_u), .O(clk_ref));

	// ------------------------------------------------------------ resets
	// the core: the button and the lock, synchronized, held 2^16 clocks
	wire        reboot_req;
`ifndef ARTY_BOOTROM
	assign reboot_req = 1'b0;
`endif
	reg  [2:0]  rst_sync;
	reg  [15:0] rst_cnt;
	reg         rst;
	initial begin
		rst_sync = 3'b111;
		rst_cnt  = 16'd0;
		rst      = 1'b1;
	end
	always @(posedge clk) begin
		rst_sync <= {rst_sync[1:0], ~ck_rst | ~locked | reboot_req};
		if (rst_sync[2]) begin
			rst_cnt <= 16'd0;
			rst     <= 1'b1;
		end else if (rst_cnt != 16'hFFFF)
			rst_cnt <= rst_cnt + 16'd1;
		else
			rst <= 1'b0;
	end

	// the MIG: until the clocks are there (active high, asynchronous)
	wire mig_rst = ~locked;

	// ------------------------------------------------------------ UART input
	reg [1:0] rxd_sync;
	initial rxd_sync = 2'b11;
	always @(posedge clk)
		rxd_sync <= {rxd_sync[0], uart_txd_in};

	reg [1:0] jc_rxd_s;
	initial jc_rxd_s = 2'b11;
	always @(posedge clk)
		jc_rxd_s <= {jc_rxd_s[0], jc_rxd};

	reg [1:0] sw_sync, sw1_sync;
	initial sw_sync = 2'b00;
	initial sw1_sync = 2'b00;
	always @(posedge clk) begin
		sw_sync  <= {sw_sync[0], sw[0]};
		sw1_sync <= {sw1_sync[0], sw[1]};
	end

	// ------------------------------------------------------------ system
	wire halted, running, ldr_active, ldr_ok, ldr_bad, miss;
	wire sd_initok, sd_error, sd_active;
	wire        xm_req, xm_we, xm_done, xm_busy, xm_ready, xm_rstb;
	wire [22:0] xm_adr;
	wire [31:0] xm_dat, xm_rdat;
	wire  [3:0] xm_sel;
	wire  [1:0] xm_ridx;

	arty_sys #(
		.CLK_HZ   (CLK_HZ),
		.UART_CLKS(CLK_HZ / 115200),
		.CACHEIDX (10)
	) sys (
		.sd_cs_n    (sd_cs_n),
		.sd_sclk    (sd_sclk),
		.sd_mosi    (sd_mosi),
		.sd_miso    (sd_miso),
		.sd_initok  (sd_initok),
		.sd_error   (sd_error),
		.sd_active  (sd_active),
`ifdef ARTY_BOOTROM
		.no_autoboot(sw_sync[1]),
		.rom_vms(sw1_sync[1]),
		.reboot_req (reboot_req),
`endif
`ifdef ARTY_DZ
		.dz_txd     (jc_txd),
		.dz_rxd     (jc_rxd_s[1]),
`endif
		.clk        (clk),
		.rst        (rst),
		.uart_rxd   (rxd_sync[1]),
		.uart_txd   (uart_rxd_out),
		.cpu_halted (halted),
		.cpu_running(running),
		.ldr_active (ldr_active),
		.ldr_ok     (ldr_ok),
		.ldr_bad    (ldr_bad),
		.mem_miss   (miss),
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

	// ------------------------------------------------------------ memory
	wire         ui_clk, ui_rst, calib;
	wire [27:0]  app_addr;
	wire [2:0]   app_cmd;
	wire         app_en, app_rdy, app_wdf_wren, app_wdf_end, app_wdf_rdy;
	wire [127:0] app_wdf_data, app_rd_data;
	wire [15:0]  app_wdf_mask;
	wire         app_rd_data_valid, app_rd_data_end;

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
		.ui_rst   (ui_rst),
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

	mig_ddr3 mig (
		.ddr3_dq         (ddr3_dq),
		.ddr3_dqs_n      (ddr3_dqs_n),
		.ddr3_dqs_p      (ddr3_dqs_p),
		.ddr3_addr       (ddr3_addr),
		.ddr3_ba         (ddr3_ba),
		.ddr3_ras_n      (ddr3_ras_n),
		.ddr3_cas_n      (ddr3_cas_n),
		.ddr3_we_n       (ddr3_we_n),
		.ddr3_reset_n    (ddr3_reset_n),
		.ddr3_ck_p       (ddr3_ck_p),
		.ddr3_ck_n       (ddr3_ck_n),
		.ddr3_cke        (ddr3_cke),
		.ddr3_cs_n       (ddr3_cs_n),
		.ddr3_dm         (ddr3_dm),
		.ddr3_odt        (ddr3_odt),
		.sys_clk_i       (clk_sys),
		.clk_ref_i       (clk_ref),
		.app_addr        (app_addr),
		.app_cmd         (app_cmd),
		.app_en          (app_en),
		.app_wdf_data    (app_wdf_data),
		.app_wdf_end     (app_wdf_end),
		.app_wdf_mask    (app_wdf_mask),
		.app_wdf_wren    (app_wdf_wren),
		.app_rd_data     (app_rd_data),
		.app_rd_data_end (app_rd_data_end),
		.app_rd_data_valid(app_rd_data_valid),
		.app_rdy         (app_rdy),
		.app_wdf_rdy     (app_wdf_rdy),
		.app_sr_req      (1'b0),
		.app_ref_req     (1'b0),
		.app_zq_req      (1'b0),
		.app_sr_active   (),
		.app_ref_ack     (),
		.app_zq_ack      (),
		.ui_clk          (ui_clk),
		.ui_clk_sync_rst (ui_rst),
		.init_calib_complete(calib),
		.device_temp_i   (12'd0),
		.sys_rst         (mig_rst)
	);

	// ------------------------------------------------------------ LEDs
	reg [24:0] blink;
	initial blink = 25'd0;
	always @(posedge clk)
		blink <= blink + 25'd1;

	(* ASYNC_REG = "TRUE" *) reg [1:0] calib_s;
	initial calib_s = 2'b00;
	always @(posedge clk)
		calib_s <= {calib_s[0], calib};

	assign led[0] = running & blink[24];
	assign led[1] = halted;
	assign led[2] = calib_s[1];
	assign led[3] = ldr_active;

	wire dim = (blink[3:0] == 4'd0);
	assign led0_r = ldr_bad & dim;
	assign led0_g = ldr_ok  & dim;
	assign led0_b = 1'b0;
	assign led1_r = sd_error  & dim;
	assign led1_g = sd_initok & dim;
	assign led1_b = sd_active & dim;

endmodule

`default_nettype wire
