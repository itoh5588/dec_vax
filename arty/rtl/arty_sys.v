//============================================================================
//  arty_sys.v - the r-vax system of the Arty S7 port, below the pins.
//
//    vax_core      r-vax CPU, MMU, cache, SBI side (the fork's, unchanged),
//                  with arty_mem_bram.v as its memory
//    console       the CPU's internal console line <-> the USB UART
//    loader        program download over the same UART (frame below)
//    autostart     types "FR<addr><CR>G" into the console monitor after a
//                  load, as vax_system.v does on MiSTer
//    boot ROM      (ARTY_BOOTROM) a program in block RAM, copied to memory
//                  at 0 after reset and started at 2 with R10 = R11 = 0:
//                  4.3BSD's /boot, which then boots hp(0,0)vmunix by
//                  itself. It waits for the memory and, with ARTY_SD, for
//                  the card; no_autoboot high (a switch) leaves it out.
//    reboot        (ARTY_BOOTROM) the VAX 8600 console's reboot: 4.3BSD's
//                  reboot writes TXDB_BOOT (F02h; on the line, 02h) and
//                  halts. 02h out of the CPU and a halt within a second
//                  ask for a reset (reboot_req), and so for the boot ROM
//                  again. A plain halt (halt, or a halt in a panic without
//                  reboot) stays in the console monitor.
//
//  UART: 8N1 at CLK_HZ / UART_CLKS baud (115200 on the board). Everything
//  received goes to the console, except:
//    - Ctrl+P (10h): halts the CPU (the VAX 8600 console's halt key);
//    - STX (02h): starts a download frame. The frame, little endian:
//
//        02 "VXLD" load(4) start(4) len(4) data(len) crc32(4)
//
//      crc32 as zlib.crc32 over data. The CPU is held in reset from the
//      magic on; the data goes to memory at load, byte by byte. At the end
//      the loader answers 06h (ACK) or 15h (NAK: bad CRC, or the frame
//      stopped for LDR_TIMEOUT). On ACK with start != FFFFFFFF, autostart
//      sets the PC to start and continues. A wrong magic drops the frame
//      without an answer and leaves the CPU alone.
//
//  The console line inside the FPGA runs at CPB + 1 clocks a bit, as
//  `CLKPERBIT in the CPU (constx/consrx). Characters for the CPU are handed
//  over no faster than one every 200 us, as on MiSTer (consrx holds one).
//
//  Structure and the console/autostart logic follow rtl/mister/vax_system.v
//  of the MiSTer port of r-vax (BSD-2-Clause).
//
//  SPDX-License-Identifier: BSD-2-Clause
//  Copyright (c) 2026 Akio Itoh
//============================================================================

`default_nettype none

`ifndef ARTY_MEM_KB
`define ARTY_MEM_KB 256
`endif

module arty_sys #(
	parameter CLK_HZ    = 40000000,
	parameter UART_CLKS = 347,          // 115200 baud at 40 MHz
	parameter CPB       = 16,           // internal console bit period - 1
	parameter CACHEIDX  = 8,            // 4 KB: the memory is block RAM too
	parameter LDR_TIMEOUT = CLK_HZ      // 1 s without a byte ends a frame
) (
`ifdef VAX_EXT_MEM
	// the memory outside (track B: arty_mem_mig), vax_core's xm_* port
	output        xm_req,
	output        xm_we,
	output [22:0] xm_adr,
	output [31:0] xm_dat,
	output  [3:0] xm_sel,
	input         xm_done,
	input         xm_busy,
	input         xm_ready,
	input  [31:0] xm_rdat,
	input   [1:0] xm_ridx,
	input         xm_rstb,
`endif
`ifdef ARTY_SD
	// RP07 unit 0 on the SD card (arty_sdcard.v)
	output       sd_cs_n,
	output       sd_sclk,
	output       sd_mosi,
	input        sd_miso,
	output       sd_initok,
	output       sd_error,
	output       sd_active,
`endif
`ifdef ARTY_DZ
	// DZ11 line 0 (arty_dz11.v): the second terminal
	output       dz_txd,
	input        dz_rxd,
`endif
`ifdef ARTY_BOOTROM
	input        no_autoboot,           // high: no boot ROM after reset
	output reg   reboot_req,            // one clock: reset the system
`endif
	input        clk,
	input        rst,                   // synchronous, active high

	input        uart_rxd,
	output       uart_txd,

	output       cpu_halted,            // in the console monitor
	output       cpu_running,           // out of reset and not halted
	output       ldr_active,            // a download is going on
	output reg   ldr_ok,                // last download: ACK
	output reg   ldr_bad,               // last download: NAK
	output       mem_miss               // cache miss (one clock)
);

	wire mem_ready;
	reg  halt_req;

	// ================================================================ host UART
	wire [7:0] urx_data;
	wire       urx_valid;

	vax_uart_rx #(.CLKS(UART_CLKS)) host_rx (
		.clk   (clk),
		.rst   (rst),
		.rxd   (uart_rxd),
		.data  (urx_data),
		.valid (urx_valid)
	);

	// ================================================================ loader
	localparam [2:0] L_IDLE = 3'd0,
	                 L_MAG  = 3'd1,         // "VXLD"
	                 L_HDR  = 3'd2,         // load, start, len
	                 L_DATA = 3'd3,
	                 L_CRC  = 3'd4,
	                 L_ANS  = 3'd5,         // answer, then let the CPU go
	                 L_ROM  = 3'd6;         // the boot ROM into memory

	reg   [2:0] ls;
	reg   [3:0] lcnt;                       // byte counter in MAG/HDR/CRC
	reg  [31:0] l_load, l_start, l_len, l_crcin;
	reg  [31:0] l_cnt;
	reg  [31:0] crc;
	reg  [31:0] l_tmo;
	reg         l_ack;                      // the answer: 1 ACK, 0 NAK
	reg         ans_stb;                    // answer byte into the host FIFO
	reg         ldr_hold;                   // CPU in reset, memory is ours
	reg         ldr_done;                   // one clock: frame accepted
	reg         rom_done;                   // one clock: boot ROM copied

	// memory write port (vax_core's second master)
	reg         ldr_stb;
	reg  [22:0] ldr_adr;
	reg   [3:0] ldr_sel;
	reg  [31:0] ldr_dat;
	wire        dma_done;

	function [31:0] crc8;                   // zlib CRC-32, one byte, reflected
		input [31:0] c;
		input  [7:0] d;
		integer k;
		reg [31:0] x;
		begin
			x = c ^ {24'd0, d};
			for (k = 0; k < 8; k = k + 1)
				x = x[0] ? (x >> 1) ^ 32'hEDB88320 : (x >> 1);
			crc8 = x;
		end
	endfunction

	wire [7:0] magic = (lcnt == 4'd0) ? "V" : (lcnt == 4'd1) ? "X" :
	                   (lcnt == 4'd2) ? "L" : "D";
	wire [31:0] l_addr = l_load + l_cnt;

	// ---------------------------------------------------- boot ROM
`ifdef ARTY_BOOTROM
`ifndef ARTY_BOOTROM_HEX
`define ARTY_BOOTROM_HEX "bootrom.hex"
`endif
	localparam ROMW = 8192;                 // 32 KB, longwords
	reg  [31:0] rom [0:ROMW-1];
	reg  [31:0] rom_q;
	reg  [12:0] rom_a;
	reg         rom_pend;                   // not copied yet since reset
	reg         rom_ph;                     // 1: rom_q is rom[rom_a]
	reg         rom_cp;                     // L_ROM/L_ANS: the ROM's copy
	initial begin
		rom_pend = 1'b1;
		rom_cp   = 1'b0;
	end
	initial $readmemh(`ARTY_BOOTROM_HEX, rom);
	always @(posedge clk)
		rom_q <= rom[rom_a];
`ifdef ARTY_SD
	wire rom_go = rom_pend && mem_ready && sd_initok && !no_autoboot;
`else
	wire rom_go = rom_pend && mem_ready && !no_autoboot;
`endif
`else
	wire rom_go = 1'b0;
`endif

	initial begin
		ls       = L_IDLE;
		ldr_hold = 1'b0;
		ldr_stb  = 1'b0;
		ldr_done = 1'b0;
		ans_stb  = 1'b0;
		rom_done = 1'b0;
		ldr_ok   = 1'b0;
		ldr_bad  = 1'b0;
	end

	assign ldr_active = (ls != L_IDLE);

	// a byte for the console: everything but STX, Ctrl+P and the frame
	wire urx_console = urx_valid && ls == L_IDLE && urx_data != 8'h02 &&
	                   urx_data != 8'h10;

	always @(posedge clk) begin
		ans_stb  <= 1'b0;
		ldr_done <= 1'b0;
		rom_done <= 1'b0;
		halt_req <= urx_valid && ls == L_IDLE && urx_data == 8'h10;

		if (ldr_stb && dma_done)
			ldr_stb <= 1'b0;

		if (rst) begin
			ls       <= L_IDLE;
			ldr_hold <= 1'b0;
			ldr_stb  <= 1'b0;
`ifdef ARTY_BOOTROM
			rom_pend <= 1'b1;
`endif
		end else begin
			if (ls != L_IDLE && ls != L_ANS) begin
				if (urx_valid)
					l_tmo <= 32'd0;
				else
					l_tmo <= l_tmo + 32'd1;
			end

			case (ls)
			L_IDLE: if (urx_valid && urx_data == 8'h02) begin
				ls    <= L_MAG;
				lcnt  <= 4'd0;
				l_tmo <= 32'd0;
`ifdef ARTY_BOOTROM
				rom_pend <= 1'b0;               // a download first: no ROM
`endif
			end else if (rom_go) begin
				ls       <= L_ROM;
				ldr_hold <= 1'b1;
`ifdef ARTY_BOOTROM
				rom_cp   <= 1'b1;
				rom_a    <= 13'd0;
				rom_ph   <= 1'b0;
`endif
			end

			L_MAG: if (urx_valid) begin
				if (urx_data != magic)
					ls <= L_IDLE;               // not a frame: drop it
				else if (lcnt == 4'd3) begin
					ls       <= L_HDR;
					lcnt     <= 4'd0;
					ldr_hold <= 1'b1;           // CPU into reset from here
				end else
					lcnt <= lcnt + 4'd1;
			end else if (l_tmo == LDR_TIMEOUT)
				ls <= L_IDLE;

			L_HDR: if (urx_valid) begin
				case (lcnt[3:2])
				2'd0: l_load  <= {urx_data, l_load[31:8]};
				2'd1: l_start <= {urx_data, l_start[31:8]};
				default: l_len <= {urx_data, l_len[31:8]};
				endcase
				lcnt <= lcnt + 4'd1;
				if (lcnt == 4'd11) begin
					l_cnt <= 32'd0;
					crc   <= 32'hFFFFFFFF;
					lcnt  <= 4'd0;
					ls    <= ({urx_data, l_len[31:8]} == 32'd0) ? L_CRC : L_DATA;
				end
			end else if (l_tmo == LDR_TIMEOUT) begin
				l_ack <= 1'b0;
				ls    <= L_ANS;
			end

			L_DATA: if (urx_valid) begin
				// one byte a write; a byte takes UART_CLKS * 10 clocks to
				// come, a write a few: the port is always free again
				ldr_adr <= l_addr[24:2];
				ldr_sel <= 4'b0001 << l_addr[1:0];
				ldr_dat <= {4{urx_data}};
				ldr_stb <= 1'b1;
				crc     <= crc8(crc, urx_data);
				l_cnt   <= l_cnt + 32'd1;
				if (l_cnt + 32'd1 == l_len)
					ls <= L_CRC;
			end else if (l_tmo == LDR_TIMEOUT) begin
				l_ack <= 1'b0;
				ls    <= L_ANS;
			end

			L_CRC: if (urx_valid) begin
				l_crcin <= {urx_data, l_crcin[31:8]};
				lcnt    <= lcnt + 4'd1;
				if (lcnt == 4'd3) begin
					l_ack <= ({urx_data, l_crcin[31:8]} == ~crc);
					ls    <= L_ANS;
				end
			end else if (l_tmo == LDR_TIMEOUT) begin
				l_ack <= 1'b0;
				ls    <= L_ANS;
			end

			L_ANS: if (!ldr_stb) begin          // the last write is done
				ldr_hold <= 1'b0;
				ls       <= L_IDLE;
`ifdef ARTY_BOOTROM
				rom_cp <= 1'b0;
				if (rom_cp)                     // the ROM: no answer byte
					rom_done <= 1'b1;
				else
`endif
				begin
					ans_stb  <= 1'b1;
					ldr_ok   <= l_ack;
					ldr_bad  <= !l_ack;
					ldr_done <= l_ack;
				end
			end

`ifdef ARTY_BOOTROM
			L_ROM: if (!ldr_stb) begin
				// a longword a write: rom_a, a clock for rom_q, the write
				if (!rom_ph)
					rom_ph <= 1'b1;
				else begin
					ldr_adr <= {10'd0, rom_a};
					ldr_sel <= 4'b1111;
					ldr_dat <= rom_q;
					ldr_stb <= 1'b1;
					rom_ph  <= 1'b0;
					rom_a   <= rom_a + 13'd1;
					if (rom_a == ROMW - 1) begin
						rom_pend <= 1'b0;
						l_start  <= 32'd2;      // past the entry mask
						ls       <= L_ANS;
						l_ack    <= 1'b1;
					end
				end
			end
`endif

			default: ls <= L_IDLE;
			endcase
		end
	end

	// ================================================================ resets
	reg rst_cpu;
	initial rst_cpu = 1'b1;
	always @(posedge clk)
		rst_cpu <= rst | ~mem_ready | ldr_hold;

	// ================================================================ VAX
	wire tti_rx, tto_tx;
	wire stat_miss;
`ifdef ARTY_SD
	wire [31:0] dk_lba0;
	wire  [1:0] dk_rd, dk_wr, dk_ack, img_mounted;
	wire  [8:0] dk_buff_addr;
	wire  [7:0] dk_buff_dout, dk_buff_din0;
	wire        dk_buff_wr, img_readonly;
	wire [63:0] img_size;
`endif

`ifdef ARTY_DZ
	// the Unibus (VAX_UNIBUS): the DZ11
	wire [17:0] ub_a;
	wire  [1:0] ub_c;
	wire [15:0] ub_d, ub_rd, ub_vec;
	wire        ub_msyn, ub_ssyn, ub_intr, ub_init;
	wire  [3:0] ub_br, ub_bg;
`endif

	// the console's map shows the memory in megabytes (one for the block
	// RAM of track A); above the memory really there, references are
	// non-existent memory (a machine check), as on a VAX with less
	vax_core #(.CLK_HZ(CLK_HZ), .CACHEIDX(CACHEIDX),
	           .MEMMB((`ARTY_MEM_KB + 1023) / 1024), .MEMKB(`ARTY_MEM_KB)) core (
`ifdef VAX_EXT_MEM
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
		.xm_rstb    (xm_rstb),
`endif
		.clk        (clk),
		.rst_mem    (rst),
		.rst_cpu    (rst_cpu),
		.mem_ready  (mem_ready),
		.rdphase    (2'd1),

		.dma_en     (ldr_hold),
		.dma_req    (ldr_stb),
		.dma_we     (1'b1),
		.dma_adr    (ldr_adr),
		.dma_dat    (ldr_dat),
		.dma_sel    (ldr_sel),
		.dma_done   (dma_done),
		.dma_rdat   (),
		.dma_ridx   (),
		.dma_rstb   (),

		.tti_rx     (tti_rx),
		.tto_tx     (tto_tx),
		.halt_req   (halt_req),
		.diag       (2'b00),

		.stat_hit   (),
		.stat_miss  (stat_miss),
		.cpu_halted (cpu_halted),

		.sd_a       (),
		.sd_ba      (),
		.sd_ncs     (),
		.sd_nras    (),
		.sd_ncas    (),
		.sd_nwe     (),
		.sd_dqml    (),
		.sd_dqmh    (),
		.sd_dq_o    (),
		.sd_dq_oe   (),
		.sd_dq_i    (16'd0),

`ifdef ARTY_SD
		.dk_lba0      (dk_lba0),
		.dk_lba1      (),
		.dk_rd        (dk_rd),
		.dk_wr        (dk_wr),
		.dk_ack       (dk_ack),
		.dk_buff_addr (dk_buff_addr),
		.dk_buff_dout (dk_buff_dout),
		.dk_buff_wr   (dk_buff_wr),
		.dk_buff_din0 (dk_buff_din0),
		.dk_buff_din1 (),
		.img_mounted  (img_mounted),
		.img_readonly (img_readonly),
		.img_size     (img_size),
`else
		// no disks on track A
		.dk_lba0      (),
		.dk_lba1      (),
		.dk_rd        (),
		.dk_wr        (),
		.dk_ack       (2'b00),
		.dk_buff_addr (9'd0),
		.dk_buff_dout (8'd0),
		.dk_buff_wr   (1'b0),
		.dk_buff_din0 (),
		.dk_buff_din1 (),
		.img_mounted  (2'b00),
		.img_readonly (1'b0),
		.img_size     (64'd0),
`endif
		.disk_active  ()
`ifdef ARTY_DZ
		,
		.ub_a     (ub_a),
		.ub_c     (ub_c),
		.ub_d     (ub_d),
		.ub_msyn  (ub_msyn),
		.ub_ssyn  (ub_ssyn),
		.ub_rd    (ub_rd),
		.ub_br    (ub_br),
		.ub_bg    (ub_bg),
		.ub_intr  (ub_intr),
		.ub_vec   (ub_vec),
		.ub_init  (ub_init)
`endif
	);

`ifdef ARTY_DZ
	arty_dz11 #(.CLK_HZ(CLK_HZ)) dz0 (
		.clk     (clk),
		.rst     (rst),
		.ub_a    (ub_a),
		.ub_c    (ub_c),
		.ub_d    (ub_d),
		.ub_msyn (ub_msyn),
		.ub_ssyn (ub_ssyn),
		.ub_rd   (ub_rd),
		.ub_br   (ub_br),
		.ub_bg   (ub_bg),
		.ub_intr (ub_intr),
		.ub_vec  (ub_vec),
		.ub_init (ub_init),
		.txd     (dz_txd),
		.rxd     (dz_rxd)
	);
`endif

`ifdef ARTY_SD
	arty_sdcard #(.CLK_HZ(CLK_HZ)) sdcard (
		.clk          (clk),
		.rst          (rst),
		.dk_lba0      (dk_lba0),
		.dk_rd        (dk_rd),
		.dk_wr        (dk_wr),
		.dk_ack       (dk_ack),
		.dk_buff_addr (dk_buff_addr),
		.dk_buff_dout (dk_buff_dout),
		.dk_buff_wr   (dk_buff_wr),
		.dk_buff_din0 (dk_buff_din0),
		.img_mounted  (img_mounted),
		.img_readonly (img_readonly),
		.img_size     (img_size),
		.sd_cs_n      (sd_cs_n),
		.sd_sclk      (sd_sclk),
		.sd_mosi      (sd_mosi),
		.sd_miso      (sd_miso),
		.sd_initok    (sd_initok),
		.sd_error     (sd_error),
		.sd_active    (sd_active)
	);
`endif

`ifdef ARTY_SIM_NXM
	// simulation only: every reference to non-existent memory, with its
	// physical address (vax_io's MEAR) and the clock
	reg [63:0] sim_clk = 0;
	always @(posedge clk) begin
		sim_clk <= sim_clk + 1;
		if (core.io.is_nxm && !core.io.nxm_q)
			$display("NXM %08x we=%0d at clock %0d", core.io.adr_r, core.io.we_r, sim_clk);
	end
`endif

	assign cpu_running = !rst_cpu && !cpu_halted;
	assign mem_miss    = stat_miss;

	// ================================================================ console output
	// internal line -> FIFO -> host UART. The CPU sends much faster than
	// 115200 baud and nothing slows it down: 2 KB absorbs the bursts.
	wire [7:0] tto_data;
	wire       tto_valid;

	vax_uart_rx #(.CLKS(CPB + 1)) tto_rx (
		.clk   (clk),
		.rst   (rst),
		.rxd   (tto_tx),
		.data  (tto_data),
		.valid (tto_valid)
	);

	(* ram_style = "distributed" *)  // the block RAM is all main memory
	reg  [7:0]  ufo [0:2047];
	reg  [10:0] ufo_wp, ufo_rp;
	wire        ufo_empty = (ufo_wp == ufo_rp);
	wire        ufo_full  = (ufo_wp + 11'd1 == ufo_rp);
	wire        utx_busy;
	reg         utx_start;
	reg  [7:0]  utx_byte;

	initial begin
		ufo_wp    = 11'd0;
		ufo_rp    = 11'd0;
		utx_start = 1'b0;
	end

	// the loader's answer and the console never come together (the CPU is
	// in reset during a frame); the answer still wins if they did
`ifdef ARTY_BOOTROM
	// ---------------------------------------------------- reboot
	localparam [31:0] RB_WIN = CLK_HZ;      // 02h, then a halt within 1 s
	reg [31:0] rb_tmr;
	reg        rb_halted;
	initial begin
		reboot_req = 1'b0;
		rb_tmr     = 32'd0;
		rb_halted  = 1'b1;
	end
	always @(posedge clk) begin
		reboot_req <= 1'b0;
		rb_halted  <= cpu_halted;
		if (rst || rst_cpu)
			rb_tmr <= 32'd0;
		else begin
			if (tto_valid)
				rb_tmr <= (tto_data == 8'h02) ? RB_WIN : 32'd0;
			else if (rb_tmr != 32'd0)
				rb_tmr <= rb_tmr - 32'd1;
			if (cpu_halted && !rb_halted && rb_tmr != 32'd0) begin
				reboot_req <= !no_autoboot;
				rb_tmr     <= 32'd0;
			end
		end
	end
`endif

	wire       ufo_in  = ans_stb | tto_valid;
	wire [7:0] ufo_dat = ans_stb ? (l_ack ? 8'h06 : 8'h15) : tto_data;

	always @(posedge clk) begin
		if (rst)
			ufo_wp <= 11'd0;
		else if (ufo_in && !ufo_full) begin
			ufo[ufo_wp] <= ufo_dat;
			ufo_wp      <= ufo_wp + 11'd1;
		end
	end

	always @(posedge clk) begin
		utx_start <= 1'b0;
		if (rst)
			ufo_rp <= 11'd0;
		else if (!ufo_empty && !utx_busy && !utx_start) begin
			utx_byte  <= ufo[ufo_rp];
			utx_start <= 1'b1;
			ufo_rp    <= ufo_rp + 11'd1;
		end
	end

	vax_uart_tx #(.CLKS(UART_CLKS)) host_tx (
		.clk   (clk),
		.rst   (rst),
		.data  (utx_byte),
		.start (utx_start),
		.busy  (utx_busy),
		.txd   (uart_txd)
	);

	// ================================================================ autostart
	/* verilator lint_off WIDTHTRUNC */
	localparam [31:0] AS_DELAY = CLK_HZ / 20;      // 50 ms before the first key
	localparam [31:0] AS_GAP   = CLK_HZ / 2000;    // 0.5 ms between keys
	localparam [15:0] TTI_GAP  = CLK_HZ / 5000;    // 200 us
	/* verilator lint_on WIDTHTRUNC */

	reg        as_run;
	reg  [4:0] as_idx;
	reg [31:0] as_tmr;
	reg        as_valid;
	reg  [7:0] as_data;

	initial begin
		as_run   = 1'b0;
		as_valid = 1'b0;
	end

	function [7:0] hexd;
		input [3:0] v;
		hexd = (v < 4'd10) ? (8'h30 + {4'd0, v}) : (8'h37 + {4'd0, v});
	endfunction

	always @(posedge clk) begin
		as_valid <= 1'b0;
		if (rst) begin
			as_run <= 1'b0;
		end else if (ldr_done || rom_done) begin
			// the ROM's program starts with R10 = R11 = 0 (4.3BSD's boot:
			// boot device hp unit 0, no flags); a download as it was
			as_run <= rom_done || (l_start != 32'hFFFFFFFF);
			as_idx <= rom_done ? 5'd0 : 5'd8;
			as_tmr <= AS_DELAY;
		end else if (as_run && !rst_cpu) begin
			if (as_tmr != 32'd0)
				as_tmr <= as_tmr - 32'd1;
			else begin
				as_valid <= 1'b1;
				as_tmr   <= AS_GAP;
				as_idx   <= as_idx + 5'd1;
				case (as_idx)
				5'd0:  as_data <= "A";
				5'd1:  as_data <= "R";
				5'd2:  as_data <= "0";
				5'd3:  as_data <= 8'h0D;
				5'd4:  as_data <= "B";
				5'd5:  as_data <= "R";
				5'd6:  as_data <= "0";
				5'd7:  as_data <= 8'h0D;
				5'd8:  as_data <= "F";
				5'd9:  as_data <= "R";
				5'd10: as_data <= hexd(l_start[31:28]);
				5'd11: as_data <= hexd(l_start[27:24]);
				5'd12: as_data <= hexd(l_start[23:20]);
				5'd13: as_data <= hexd(l_start[19:16]);
				5'd14: as_data <= hexd(l_start[15:12]);
				5'd15: as_data <= hexd(l_start[11:8]);
				5'd16: as_data <= hexd(l_start[7:4]);
				5'd17: as_data <= hexd(l_start[3:0]);
				5'd18: as_data <= 8'h0D;
				default: begin
					as_data <= "G";
					as_run  <= 1'b0;
				end
				endcase
			end
		end
	end

	// ================================================================ console input
	(* ram_style = "distributed" *)
	reg  [7:0] txf [0:255];
	reg  [7:0] txf_wp, txf_rp;
	wire       txf_empty = (txf_wp == txf_rp);
	wire       txf_full  = (txf_wp + 8'd1 == txf_rp);
	wire       tx_busy;
	reg        tx_start;
	reg  [7:0] tx_byte;
	reg [15:0] tti_gap;
	reg        urx_p;                       // one-entry holding slot
	reg  [7:0] urx_h;

	initial begin
		txf_wp   = 8'd0;
		txf_rp   = 8'd0;
		tx_start = 1'b0;
		tti_gap  = 16'd0;
		urx_p    = 1'b0;
	end

	always @(posedge clk) begin
		if (rst) begin
			txf_wp <= 8'd0;
			urx_p  <= 1'b0;
		end else begin
			if (urx_console) begin
				urx_h <= urx_data;
				urx_p <= 1'b1;
			end
			if (as_valid && !txf_full) begin
				txf[txf_wp] <= as_data;
				txf_wp      <= txf_wp + 8'd1;
			end else if (urx_p && !txf_full) begin
				txf[txf_wp] <= urx_h;
				txf_wp      <= txf_wp + 8'd1;
				if (!urx_console) urx_p <= 1'b0;
			end
		end
	end

	always @(posedge clk) begin
		tx_start <= 1'b0;
		if (rst) begin
			txf_rp  <= 8'd0;
			tti_gap <= 16'd0;
		end else if (tti_gap != 16'd0)
			tti_gap <= tti_gap - 16'd1;
		else if (!txf_empty && !tx_busy && !tx_start) begin
			tx_byte  <= txf[txf_rp];
			tx_start <= 1'b1;
			txf_rp   <= txf_rp + 8'd1;
			tti_gap  <= TTI_GAP;
		end
	end

	vax_uart_tx #(.CLKS(CPB + 1)) tti_tx (
		.clk   (clk),
		.rst   (rst),
		.data  (tx_byte),
		.start (tx_start),
		.busy  (tx_busy),
		.txd   (tti_rx)
	);

endmodule

`default_nettype wire
