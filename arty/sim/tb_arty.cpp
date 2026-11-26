// SPDX-License-Identifier: BSD-2-Clause
// Copyright (c) 2026 Akio Itoh
//
// tb_arty.cpp - Verilator driver for arty_sys.v (track A, below the pins).
//
//   cd build && sim/Varty_sys [frame.vxld|-] [maxclocks]
//
// (from build/: the microcode is read from rtl/uc-*.hex, i.e. build/rtl)
//
// Plays the host on the UART: sends the download frame (sw/tools/mkvxld.py)
// once the console monitor has had time to start, then types KEYS (env,
// "\r" = CR) if given, and prints everything the board sends on stdout
// (06 as <ACK>, 15 as <NAK>). The bench runs with UART_CLKS from the build
// (a fast line: 115200 baud would only slow the simulation down).
//
// Ends when the program the frame started halts again (the CPU back in the
// console monitor after running), after the output has drained; or after
// maxclocks (TIMEOUT). Last lines: "HALTED" or "TIMEOUT", "ACK n NAK n",
// "CLOCKS n".
//
// Environment: KEYS  characters to type after the load (or after reset if
//                    there is no frame), \r for CR, \x10 for Ctrl+P
//              KEYWAIT  type KEYS only once the output contains this (and
//                       200000 clocks later)
//              WAIT  clocks before the frame / keys (default 200000)

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#ifndef TOPCLASS
#define TOPCLASS Varty_sys
#define TOPHDR "Varty_sys.h"
#endif
#include TOPHDR
#include "verilated.h"

#ifndef UART_CLKS
#define UART_CLKS 24
#endif

static TOPCLASS *tb;

#ifdef SD_MODEL
// the SD card of track B (sim/sdspi_model.v): the image file SDIMG, read
// only; blocks written are kept here
#include <map>
static FILE *sdimg;
static bool sdimg_tried;
static std::map<uint32_t, std::vector<uint8_t>> sdw;
static unsigned sd_reads, sd_writes;

extern "C" int sd_rd_byte(int lba, int i) {
	if (i == 0) sd_reads++;
	auto it = sdw.find((uint32_t)lba);
	if (it != sdw.end()) return it->second[i];
	if (!sdimg_tried) {
		sdimg_tried = true;
		if (const char *p = getenv("SDIMG")) {
			sdimg = fopen(p, "rb");
			if (!sdimg) perror(p);
		}
	}
	if (!sdimg) return 0;
	fseek(sdimg, (long)lba * 512 + i, SEEK_SET);
	int c = fgetc(sdimg);
	return c < 0 ? 0 : c;
}

extern "C" void sd_wr_byte(int lba, int i, int v) {
	if (!sdw.count((uint32_t)lba)) {
		// the first write to this block: start from the image's contents
		std::vector<uint8_t> nb(512);
		for (int k = 0; k < 512; k++) nb[k] = sd_rd_byte(lba, k);
		sd_reads--;
		sdw[(uint32_t)lba] = nb;
	}
	if (i == 0) sd_writes++;
	sdw[(uint32_t)lba][i] = v;
}
#endif
static uint64_t cycles = 0;

// ------------------------------------------------ host -> board (uart_rxd)
static std::vector<uint8_t> txq;            // bytes to send
static size_t txpos = 0;
static int tx_bit = -1, tx_cnt = 0;         // -1: idle
static uint16_t tx_sh;
// KEYGAP: clocks of idle line after each typed key (not the frame's
// bytes): a slow program reads one character at a time from RXDB, which
// holds only one
static uint64_t key_gap = 0, tx_hold = 0;
static size_t gap_from = 0;

static void host_tx_step() {
	if (tx_bit < 0) {
		tb->uart_rxd = 1;
		if (tx_hold) {
			tx_hold--;
			return;
		}
		if (txpos < txq.size()) {
			if (txpos >= gap_from)
				tx_hold = key_gap;
			tx_sh = (1u << 9) | ((uint16_t)txq[txpos++] << 1);    // stop, data, start
			tx_bit = 0;
			tx_cnt = UART_CLKS;
		}
		return;
	}
	tb->uart_rxd = (tx_sh >> tx_bit) & 1;
	if (--tx_cnt == 0) {
		tx_cnt = UART_CLKS;
		if (++tx_bit == 10)
			tx_bit = -1;
	}
}

// ------------------------------------------------ board -> host (uart_txd)
static int rx_st = -1, rx_cnt = 0, rx_bits = 0, rx_ch = 0;
static uint64_t last_rx = 0;
static int acks = 0, naks = 0;
static std::string rxtext;             // everything received

static void host_rx_step() {
	int line = tb->uart_txd;
	if (rx_st < 0) {
		if (!line) { rx_st = 0; rx_cnt = UART_CLKS / 2; rx_bits = 0; rx_ch = 0; }
		return;
	}
	if (--rx_cnt > 0)
		return;
	rx_cnt = UART_CLKS;
	if (rx_st == 0) {
		rx_st = line ? -1 : 1;
	} else if (rx_bits < 8) {
		rx_ch |= line << rx_bits++;
	} else {
		if (rx_ch == 0x06) { fputs("<ACK>", stdout); acks++; }
		else if (rx_ch == 0x15) { fputs("<NAK>", stdout); naks++; }
		else { fputc(rx_ch & 0x7F, stdout); rxtext += (char)(rx_ch & 0x7F); }
		fflush(stdout);
		last_rx = cycles;
		rx_st = -1;
	}
}

#ifdef DZ_LINE
// ------------------------------------------------ DZ11 line 0 (dz_txd)
// at 9600 baud of the 40 MHz clock, 10 bits a character (8N1 or 7 bits
// with parity): the low 7 bits into dz.out; dz_rxd stays idle
static FILE *dzf;
static int dz_st = -1, dz_cnt = 0, dz_bits = 0, dz_ch = 0;
static void dz_rx_step() {
	const int DZ_CLKS = 40000000 / 9600;
	int line = tb->dz_txd;
	if (dz_st < 0) {
		if (!line) { dz_st = 0; dz_cnt = DZ_CLKS / 2; dz_bits = 0; dz_ch = 0; }
		return;
	}
	if (--dz_cnt > 0)
		return;
	dz_cnt = DZ_CLKS;
	if (dz_st == 0)
		dz_st = line ? -1 : 1;
	else if (dz_bits < 8)
		dz_ch |= line << dz_bits++;
	else {
		if (!dzf) dzf = fopen("dz.out", "w");
		fputc(dz_ch & 0x7F, dzf);
		fflush(dzf);
		dz_st = -1;
	}
}
#endif

#ifdef TWO_CLOCKS
// track B: the core's clock (40 MHz) and the MIG's ui_clk (83.3 MHz, on
// purpose not a multiple of it), edge by edge in time (picoseconds)
static uint64_t t_core = 0, t_ui = 0;
#endif

static void tick() {
#ifdef TWO_CLOCKS
	int core_edges = 0;
	while (core_edges < 2) {
		if (t_ui < t_core) {
			tb->ui_clk = !tb->ui_clk; tb->eval(); t_ui += 6000;
		} else {
			tb->clk = !tb->clk; tb->eval(); t_core += 12500; core_edges++;
		}
	}
#else
	tb->clk = 1; tb->eval();
	tb->clk = 0; tb->eval();
#endif
	cycles++;
	host_tx_step();
	host_rx_step();
#ifdef DZ_LINE
	dz_rx_step();
#endif
}

static std::string unescape(const char *s) {
	std::string r;
	for (; *s; s++) {
		if (s[0] == '\\' && s[1] == 'r') { r += '\r'; s++; }
		else if (s[0] == '\\' && s[1] == 'x' && s[2] && s[3]) {
			char h[3] = {s[2], s[3], 0};
			r += (char)strtoul(h, 0, 16);
			s += 3;
		} else r += *s;
	}
	return r;
}

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	const char *frame = argc > 1 ? argv[1] : "-";
	uint64_t maxc = argc > 2 ? strtoull(argv[2], 0, 0) : 20000000ULL;
	uint64_t wait = getenv("WAIT") ? strtoull(getenv("WAIT"), 0, 0) : 200000;
	std::string keys = getenv("KEYS") ? unescape(getenv("KEYS")) : "";
	std::string keywait = getenv("KEYWAIT") ? getenv("KEYWAIT") : "";
	key_gap = getenv("KEYGAP") ? strtoull(getenv("KEYGAP"), 0, 0) : 0;
	// KEYSEQ: "wait=>keys|wait=>keys|...", after the frame, step by step:
	// each wait is looked for in the output after the previous one, and
	// its keys are typed 200000 clocks after it came (KEYS/KEYWAIT then
	// are not used)
	std::vector<std::pair<std::string, std::string>> seq;
	size_t seq_i = 0, seq_pos = 0;
	uint64_t seq_at = 0;
	if (const char *ks = getenv("KEYSEQ")) {
		std::string all(ks);
		size_t a = 0;
		while (a <= all.size()) {
			size_t b = all.find('|', a);
			if (b == std::string::npos) b = all.size();
			std::string item = all.substr(a, b - a);
			size_t m = item.find("=>");
			if (m != std::string::npos)
				seq.push_back({item.substr(0, m), unescape(item.substr(m + 2).c_str())});
			a = b + 1;
		}
	}

	std::vector<uint8_t> fr;
	if (strcmp(frame, "-")) {
		FILE *f = fopen(frame, "rb");
		if (!f) { perror(frame); return 1; }
		int c;
		while ((c = fgetc(f)) != EOF) fr.push_back(c);
		fclose(f);
	}
	gap_from = fr.size();

	tb = new TOPCLASS;
	tb->uart_rxd = 1;
#ifdef DZ_LINE
	tb->dz_rxd = 1;
#endif
	tb->clk = 0; tb->rst = 1;
	for (int i = 0; i < 20; i++) tick();
	tb->rst = 0;

	enum { BOOT, LOADING, KEYS_OUT, RUNNING } st = BOOT;
	bool ran = false;
	bool halted_end = false;
	uint64_t halt_at = 0, sent_at = 0, seen_at = 0;

	while (cycles < maxc) {
		tick();
		switch (st) {
		case BOOT:
			if (cycles >= wait) {
				if (!fr.empty()) {
					txq.insert(txq.end(), fr.begin(), fr.end());
					st = LOADING;
				} else {
					txq.insert(txq.end(), keys.begin(), keys.end());
					st = RUNNING;
				}
			}
			break;
		case LOADING:                      // the frame is out
			if (txpos == txq.size() && tx_bit < 0) {
				sent_at = cycles;
				st = KEYS_OUT;
			}
			break;
		case KEYS_OUT:
			// the program started, or it was not going to (load only, a
			// NAK, a dropped frame): then the keys go to the console
			// KEYWAIT: the text, then 200000 clocks more (5 ms: a program
			// may clear its input after the prompt)
			if (keywait.size() && !seen_at && rxtext.find(keywait) != std::string::npos)
				seen_at = cycles;
			if (keywait.size() ? (seen_at && cycles - seen_at > 200000)
			                    : (tb->cpu_running || cycles - sent_at > 300000)) {
				ran = tb->cpu_running;
				txq.insert(txq.end(), keys.begin(), keys.end());
				if (keys.size())
					fprintf(stderr, "\n[tb: %zu key(s) typed at clock %llu, cpu %s]\n", keys.size(),
					        (unsigned long long)cycles, tb->cpu_running ? "running" : "halted/reset");
				st = RUNNING;
			}
			break;
		case RUNNING:
			if (seq_i < seq.size()) {
				size_t k = seq_at ? std::string::npos : rxtext.find(seq[seq_i].first, seq_pos);
				if (!seq_at && k != std::string::npos) {
					seq_at = cycles;
					seq_pos = k + seq[seq_i].first.size();
				}
				if (seq_at && cycles - seq_at > 200000) {
					txq.insert(txq.end(), seq[seq_i].second.begin(), seq[seq_i].second.end());
					fprintf(stderr, "\n[tb: KEYSEQ %zu typed at clock %llu]\n", seq_i,
					        (unsigned long long)cycles);
					seq_i++;
					seq_at = 0;
				}
			}
			if (tb->cpu_running) { ran = true; halt_at = 0; }
			else if (ran && tb->cpu_halted && !halt_at) halt_at = cycles;
			// halted, and nothing more for 20 character times
			if (halt_at && cycles - halt_at > 20000 &&
			    cycles - last_rx > (uint64_t)UART_CLKS * 10 * 20) {
				halted_end = true;
				goto out;
			}
			break;
		}
	}
out:
#ifdef SD_MODEL
	printf("\nSD blocks read %u, written %u\n", sd_reads, sd_writes);
#endif
	printf("\n%s\nACK %d NAK %d\nCPU %s\nCLOCKS %llu\n", halted_end ? "HALTED" : "TIMEOUT",
	       acks, naks, tb->cpu_running ? "running" : tb->cpu_halted ? "halted" : "reset",
	       (unsigned long long)cycles);
	delete tb;
	return halted_end ? 0 : 1;
}
