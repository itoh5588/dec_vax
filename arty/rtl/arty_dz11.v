//============================================================================
//  arty_dz11.v - a DZ11 (8 asynchronous lines) on the DW780's Unibus of the
//  r-vax core (vax_core with VAX_UNIBUS), for 4.3BSD's dz driver. Line 0 is
//  a real serial line (txd/rxd, at the speed, character length and parity
//  its LPR sets); lines 1-7 have their registers only: what is written to
//  them is gone after a character time, nothing comes in.
//
//  Registers (BASE, 760100 as 4.3BSD's GENERIC has dz0; words, DATOB of a
//  byte where it means something):
//
//    +0 CSR   <15> TRDY (RO), <14> TIE, <13> SA (RO), <12> SAE,
//             <10:8> TLINE (RO), <7> RDONE (RO), <6> RIE, <5> MSE,
//             <4> CLR (master clear, reads 0), <3> MAINT (kept, no loop);
//             <0> reads 0 (the DZ32 test of dzprobe: a DZ11)
//    +2 RBUF  read: <15> DVAL, <14> OVRN, <13> FE, <12> PE, <10:8> line,
//             <7:0> the character; reading takes it out of the silo (64)
//       LPR   write: <12> receiver on, <11:8> speed, <7> odd parity,
//             <6> parity enable, <5> two stop bits, <4:3> character
//             length 5-8, <2:0> line
//    +4 TCR   <15:8> DTR, <7:0> line enable (bytes)
//    +6 MSR   read: <15:8> CO (carrier: the DTR, a null modem), <7:0> RI 0
//       TDR   write: <15:8> BRK (kept), <7:0> the character for TLINE
//
//  The transmitter scanner (MSE set) looks for an enabled line whose
//  buffer is empty and shows it as TLINE with TRDY; writing TDR gives that
//  line its character and lets the scan go on. The receiver puts what
//  comes in on a line with its receiver on into the silo; RDONE says it
//  is not empty, SA that 16 came in since RBUF was last read.
//
//  Interrupts on BR5 (ub_br[1]), one for each time its condition becomes
//  true (a request flip-flop, cleared by the bus grant, as DEC's devices
//  do): receive at VEC when RIE and (SAE ? SA : RDONE), transmit at VEC + 4
//  when TIE and TRDY; receive first when both. Not a level: dzprobe's
//  catcher only notes the vector and returns, the condition still true
//  (dzprobe takes the vector of the transmit interrupt and subtracts 4).
//
//  Speeds (DZ11 code: baud): 0 50, 1 75, 2 110, 3 134.5, 4 150, 5 300,
//  6 600, 7 1200, 8 1800, 9 2000, 10 2400, 11 3600, 12 4800, 13 7200,
//  14 9600, 15 19200 (4.3BSD's EXTA).
//
//  SPDX-License-Identifier: BSD-2-Clause
//  Copyright (c) 2026 Akio Itoh
//============================================================================

`default_nettype none

module arty_dz11 #(
	parameter        CLK_HZ = 40000000,
	parameter [17:0] BASE   = 18'o760100,
	parameter [15:0] VEC    = 16'o300
) (
	input             clk,
	input             rst,

	// the Unibus, device side (vax_uba.v)
	input      [17:0] ub_a,
	input       [1:0] ub_c,
	input      [15:0] ub_d,
	input             ub_msyn,
	output reg        ub_ssyn,
	output reg [15:0] ub_rd,
	output      [3:0] ub_br,
	input       [3:0] ub_bg,
	output reg        ub_intr,
	output reg [15:0] ub_vec,
	input             ub_init,

	// line 0
	output            txd,
	input             rxd
);

	// ------------------------------------------------------------ speeds
	function [31:0] bitclks;
		input [3:0] code;
		case (code)
		4'd0:  bitclks = CLK_HZ / 50;
		4'd1:  bitclks = CLK_HZ / 75;
		4'd2:  bitclks = CLK_HZ / 110;
		4'd3:  bitclks = (CLK_HZ * 2) / 269;
		4'd4:  bitclks = CLK_HZ / 150;
		4'd5:  bitclks = CLK_HZ / 300;
		4'd6:  bitclks = CLK_HZ / 600;
		4'd7:  bitclks = CLK_HZ / 1200;
		4'd8:  bitclks = CLK_HZ / 1800;
		4'd9:  bitclks = CLK_HZ / 2000;
		4'd10: bitclks = CLK_HZ / 2400;
		4'd11: bitclks = CLK_HZ / 3600;
		4'd12: bitclks = CLK_HZ / 4800;
		4'd13: bitclks = CLK_HZ / 7200;
		4'd14: bitclks = CLK_HZ / 9600;
		default: bitclks = CLK_HZ / 19200;
		endcase
	endfunction

	// ------------------------------------------------------------ registers
	reg        tie, sae, rie, mse, maint;
	reg  [7:0] lenab, dtr, brk;
	reg        trdy;
	reg  [2:0] tline;
	reg        sa;
	reg  [4:0] sacnt;                       // characters since RBUF read

	// line 0's parameters (LPR); the receivers of the others are only kept
	reg  [7:0] rcvon;
	reg  [3:0] l0_speed;
	reg  [1:0] l0_len;                      // 0: 5 bits .. 3: 8 bits
	reg        l0_stop2, l0_pen, l0_odd;
	wire [31:0] l0_clks = bitclks(l0_speed);

	// the silo: {OVRN, FE, PE, line, char}, 64 deep
	reg [13:0] silo [0:63];
	reg  [5:0] s_wp, s_rp;
	reg  [6:0] s_n;
	wire       rdone = (s_n != 7'd0);
	reg        ovrn_next;

	// ------------------------------------------------------------ line 0: transmitter
	reg  [7:0] tx_ch;
	reg        tx_go;                       // one clock: start tx_ch
	reg        tx_busy;
	reg [31:0] tx_t;
	reg  [3:0] tx_n;                        // bits left, start and stop included
	reg [11:0] tx_sh;
	reg        txd_r;
	assign txd = txd_r;

	function par7;                          // even parity of the used bits
		input [7:0] c;
		input [1:0] len;
		case (len)
		2'd0: par7 = ^c[4:0];
		2'd1: par7 = ^c[5:0];
		2'd2: par7 = ^c[6:0];
		default: par7 = ^c[7:0];
		endcase
	endfunction

	// the frame, LSB first: start, 5-8 data, parity, 1-2 stop
	reg [11:0] frame;
	reg  [3:0] frame_n;
	always @(*) begin
		frame = 12'hFFF;
		frame_n = 4'd0;
		case (l0_len)
		2'd0: begin frame[5:0] = {tx_ch[4:0], 1'b0}; frame_n = 4'd6; end
		2'd1: begin frame[6:0] = {tx_ch[5:0], 1'b0}; frame_n = 4'd7; end
		2'd2: begin frame[7:0] = {tx_ch[6:0], 1'b0}; frame_n = 4'd8; end
		default: begin frame[8:0] = {tx_ch[7:0], 1'b0}; frame_n = 4'd9; end
		endcase
		if (l0_pen) begin
			frame[frame_n] = par7(tx_ch, l0_len) ^ l0_odd;
			frame_n = frame_n + 4'd1;
		end
		frame_n = frame_n + (l0_stop2 ? 4'd2 : 4'd1);   // the stop bits are 1s
	end

	initial begin
		txd_r = 1'b1; tx_busy = 1'b0;
	end

	always @(posedge clk) begin
		if (rst || ub_init) begin
			txd_r   <= 1'b1;
			tx_busy <= 1'b0;
		end else if (tx_go) begin
			tx_sh   <= frame >> 1;
			txd_r   <= frame[0];
			tx_n    <= frame_n - 4'd1;
			tx_t    <= l0_clks;
			tx_busy <= 1'b1;
		end else if (tx_busy) begin
			if (tx_t > 32'd1)
				tx_t <= tx_t - 32'd1;
			else if (tx_n == 4'd0) begin
				tx_busy <= 1'b0;
				txd_r   <= 1'b1;
			end else begin
				txd_r <= tx_sh[0];
				tx_sh <= {1'b1, tx_sh[11:1]};
				tx_n  <= tx_n - 4'd1;
				tx_t  <= l0_clks;
			end
		end
	end

	// lines 1-7: busy for a character time at 9600 baud
	localparam [31:0] CHCLKS = (CLK_HZ / 9600) * 10;
	reg  [7:0] obusy;                       // <0> unused
	reg [31:0] o_t [1:7];
	integer k;

	// ------------------------------------------------------------ line 0: receiver
	reg  [2:0] rx_s;                        // synchronizer
	wire       rx = rx_s[2];
	reg        rx_on;                       // in a frame
	reg [31:0] rx_t;
	reg  [3:0] rx_i;                        // bit index: 0 start, 1.. data
	reg  [7:0] rx_c;
	reg        rx_p;
	reg        rx_done;                     // one clock: a character
	reg  [7:0] rx_ch;
	reg        rx_fe, rx_pe;
	wire [3:0] rx_dbits = {2'b00, l0_len} + 4'd5;

	initial begin
		rx_s = 3'b111; rx_on = 1'b0; rx_done = 1'b0;
	end

	always @(posedge clk) begin
		rx_s    <= {rx_s[1:0], rxd};
		rx_done <= 1'b0;
		if (rst || ub_init)
			rx_on <= 1'b0;
		else if (!rx_on) begin
			if (!rx) begin                  // start bit: sample in its middle
				rx_on <= 1'b1;
				rx_t  <= l0_clks >> 1;
				rx_i  <= 4'd0;
				rx_c  <= 8'd0;
			end
		end else if (rx_t > 32'd1)
			rx_t <= rx_t - 32'd1;
		else begin
			rx_t <= l0_clks;
			rx_i <= rx_i + 4'd1;
			if (rx_i == 4'd0) begin
				if (rx)
					rx_on <= 1'b0;          // a glitch, no start bit
			end else if (rx_i <= rx_dbits)
				rx_c[rx_i - 4'd1] <= rx;
			else if (l0_pen && rx_i == rx_dbits + 4'd1)
				rx_p <= rx;
			else begin                      // the stop bit
				rx_on   <= 1'b0;
				rx_done <= 1'b1;
				rx_ch   <= rx_c;
				rx_fe   <= !rx;
				rx_pe   <= l0_pen && (par7(rx_c, l0_len) ^ l0_odd ^ rx_p);
			end
		end
	end

	// ------------------------------------------------------------ the bus
	wire       sel = ub_msyn && (ub_a[17:3] == BASE[17:3]);
	reg  [3:0] s_t;
	wire       wr  = ub_c[1];               // DATO, DATOB
	wire       wlo = wr && (!ub_c[0] || !ub_a[0]);
	wire       whi = wr && (!ub_c[0] ||  ub_a[0]);

	wire [15:0] csr_r = {trdy, tie, sa, sae, 1'b0, tline, rdone, rie, mse,
	                     1'b0, maint, 3'b000};
	wire [13:0] s_head = silo[s_rp];
	wire [15:0] rbuf_r = rdone ? {1'b1, s_head[13:11], 1'b0, s_head[10:0]}
	                           : 16'd0;

	// interrupts
	wire rx_cond = rie && (sae ? sa : rdone);
	wire tx_cond = tie && trdy;
	reg  rx_cond_q, tx_cond_q;
	reg  rx_req, tx_req;
	reg  bg_wait;                           // INTR given: until BG drops
	assign ub_br = (rx_req || tx_req) ? 4'b0010 : 4'b0000;   // BR5

	// the scanner
	reg  [2:0] scan;
	wire [7:0] lbusy = {obusy[7:1], tx_busy};

	initial begin
		ub_ssyn = 1'b0; ub_intr = 1'b0;
		tie = 1'b0; sae = 1'b0; rie = 1'b0; mse = 1'b0; maint = 1'b0;
		lenab = 8'd0; dtr = 8'd0; brk = 8'd0; trdy = 1'b0; tline = 3'd0;
		sa = 1'b0; sacnt = 5'd0; rcvon = 8'd0;
		l0_speed = 4'd14; l0_len = 2'd3; l0_stop2 = 1'b0; l0_pen = 1'b0;
		l0_odd = 1'b0; s_wp = 6'd0; s_rp = 6'd0; s_n = 7'd0;
		ovrn_next = 1'b0; tx_go = 1'b0; obusy = 8'd0; scan = 3'd0;
		rx_cond_q = 1'b0; tx_cond_q = 1'b0; rx_req = 1'b0; tx_req = 1'b0;
		bg_wait = 1'b0; s_t = 4'd0;
	end

	// pop and clr: within the clock only (blocking, on purpose)
	/* verilator lint_off BLKSEQ */
	reg pop;                                // RBUF read this clock
	reg clr;                                // master clear this clock

	always @(posedge clk) begin
		ub_intr <= 1'b0;
		tx_go   <= 1'b0;
		pop      = 1'b0;
		clr      = 1'b0;

		if (rst || ub_init) begin
			ub_ssyn <= 1'b0;
			s_t     <= 4'd0;
			tie <= 1'b0; sae <= 1'b0; rie <= 1'b0; mse <= 1'b0; maint <= 1'b0;
			lenab <= 8'd0; dtr <= 8'd0; brk <= 8'd0;
			trdy <= 1'b0; sa <= 1'b0; sacnt <= 5'd0; rcvon <= 8'd0;
			s_wp <= 6'd0; s_rp <= 6'd0; s_n <= 7'd0; ovrn_next <= 1'b0;
			obusy <= 8'd0;
			rx_cond_q <= 1'b0; tx_cond_q <= 1'b0;
			rx_req <= 1'b0; tx_req <= 1'b0; bg_wait <= 1'b0;
		end else begin
			// ------------------------------------------------ registers
			if (!sel) begin
				ub_ssyn <= 1'b0;
				s_t     <= 4'd0;
			end else if (!ub_ssyn) begin
				if (s_t != 4'd10)
					s_t <= s_t + 4'd1;     // 250 ns to answer
				else begin
					ub_ssyn <= 1'b1;
					case (ub_a[2:1])
					2'd0: ub_rd <= csr_r;
					2'd1: ub_rd <= rbuf_r;
					2'd2: ub_rd <= {dtr, lenab};
					default: ub_rd <= {dtr, 8'd0};   // CO = DTR, RI none
					endcase
					case (ub_a[2:1])
					2'd0: begin             // CSR
						if (wlo) begin
							rie   <= ub_d[6];
							mse   <= ub_d[5];
							maint <= ub_d[3];
							if (ub_d[4]) clr = 1'b1;
						end
						if (whi) begin
							tie <= ub_d[14];
							sae <= ub_d[12];
						end
					end
					2'd1: begin             // RBUF / LPR
						if (!wr)
							pop = 1'b1;
						else if (!ub_c[0]) begin
							rcvon[ub_d[2:0]] <= ub_d[12];
							if (ub_d[2:0] == 3'd0) begin
								l0_speed <= ub_d[11:8];
								l0_odd   <= ub_d[7];
								l0_pen   <= ub_d[6];
								l0_stop2 <= ub_d[5];
								l0_len   <= ub_d[4:3];
							end
						end
					end
					2'd2: begin             // TCR
						if (wlo) lenab <= ub_d[7:0];
						if (whi) dtr   <= ub_d[15:8];
					end
					default: begin          // TDR
						if (wlo && trdy) begin
							if (tline == 3'd0)
								tx_go <= 1'b1;
							else
								obusy[tline] <= 1'b1;
							trdy <= 1'b0;
						end
						if (whi) brk <= ub_d[15:8];
					end
					endcase
				end
			end

			// ------------------------------------------------ the silo
			if (pop) begin
				sa    <= 1'b0;
				sacnt <= 5'd0;
			end
			if (clr) begin
				// master clear: CSR, silo, receivers (TCR stays)
				tie <= 1'b0; sae <= 1'b0; rie <= 1'b0; mse <= 1'b0; maint <= 1'b0;
				trdy <= 1'b0; sa <= 1'b0; sacnt <= 5'd0; rcvon <= 8'd0;
				s_wp <= 6'd0; s_rp <= 6'd0; s_n <= 7'd0; ovrn_next <= 1'b0;
			end else begin
				if (rx_done && rcvon[0] && mse) begin
					if (s_n == 7'd64 && !pop)
						ovrn_next <= 1'b1;  // full: lost, said with the next
					else begin
						silo[s_wp] <= {ovrn_next, rx_fe, rx_pe, 3'd0, rx_ch};
						s_wp       <= s_wp + 6'd1;
						ovrn_next  <= 1'b0;
						if (!pop && sacnt != 5'd16) begin
							sacnt <= sacnt + 5'd1;
							if (sacnt == 5'd15)
								sa <= 1'b1;
						end
					end
				end
				if (pop && rdone)
					s_rp <= s_rp + 6'd1;
				s_n <= s_n
				     + ((rx_done && rcvon[0] && mse && !(s_n == 7'd64 && !pop)) ? 7'd1 : 7'd0)
				     - ((pop && rdone) ? 7'd1 : 7'd0);
			end

			// ------------------------------------------------ the scanner
			if (!mse || clr)
				trdy <= 1'b0;
			else if (trdy) begin
				if (!lenab[tline])
					trdy <= 1'b0;           // its line was disabled
			end else if (!(sel && ub_ssyn && ub_a[2:1] == 2'd3)) begin
				scan <= scan + 3'd1;
				if (lenab[scan] && !lbusy[scan] && !(tx_go && scan == 3'd0)) begin
					trdy  <= 1'b1;
					tline <= scan;
				end
			end

			// lines 1-7 finish their characters
			for (k = 1; k < 8; k = k + 1)
				if (obusy[k]) begin
					if (o_t[k] >= CHCLKS) begin
						obusy[k] <= 1'b0;
						o_t[k]   <= 32'd0;
					end else
						o_t[k] <= o_t[k] + 32'd1;
				end else
					o_t[k] <= 32'd0;

			// ------------------------------------------------ interrupts
			rx_cond_q <= rx_cond;
			tx_cond_q <= tx_cond;
			if (rx_cond && !rx_cond_q) rx_req <= 1'b1;
			if (tx_cond && !tx_cond_q) tx_req <= 1'b1;
			if (!rie) rx_req <= 1'b0;       // enable off: taken back
			if (!tie) tx_req <= 1'b0;
			if (!ub_bg[1])
				bg_wait <= 1'b0;
			if ((rx_req || tx_req) && ub_bg[1] && !bg_wait) begin
				ub_intr <= 1'b1;
				bg_wait <= 1'b1;
				if (rx_req) begin
					ub_vec <= VEC;
					rx_req <= 1'b0;
				end else begin
					ub_vec <= VEC + 16'd4;
					tx_req <= 1'b0;
				end
			end
		end
	end

	/* verilator lint_on BLKSEQ */

	// line 0's character: the low byte of the TDR write that starts it
	always @(posedge clk)
		if (sel && !ub_ssyn && s_t == 4'd10 && ub_a[2:1] == 2'd3 && wlo &&
		    trdy && tline == 3'd0)
			tx_ch <= ub_d[7:0];

endmodule

`default_nettype wire
