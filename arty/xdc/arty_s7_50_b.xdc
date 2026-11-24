# arty_s7_50_b.xdc - Digilent Arty S7-50 constraints for arty_top_b.v (track B:
# the DDR3L through the MIG; the MIG brings the constraints of its own pins).
# Pin locations as in Digilent's Arty-S7-50 master XDC; port names as there.
#
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Akio Itoh

# ---------------------------------------------------------------- config
set_property CFGBVS VCCO        [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE      [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4      [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33       [current_design]
set_property BITSTREAM.CONFIG.USR_ACCESS TIMESTAMP [current_design]

# ---------------------------------------------------------------- clock
# 100 MHz on bank 34 (the DDR3L bank, 1.35 V): SSTL135, with the bank's
# reference generated inside (no external VREF needed for this input)
set_property -dict { PACKAGE_PIN R2 IOSTANDARD SSTL135 } [get_ports CLK100MHZ]
set_property INTERNAL_VREF 0.675 [get_iobanks 34]
create_clock -name clk100 -period 10.000 [get_ports CLK100MHZ]

# ---------------------------------------------------------------- reset
set_property -dict { PACKAGE_PIN C18 IOSTANDARD LVCMOS33 } [get_ports ck_rst]

# ---------------------------------------------------------------- USB UART
set_property -dict { PACKAGE_PIN V12 IOSTANDARD LVCMOS33 } [get_ports uart_txd_in]
set_property -dict { PACKAGE_PIN R12 IOSTANDARD LVCMOS33 } [get_ports uart_rxd_out]

# ---------------------------------------------------------------- LEDs
set_property -dict { PACKAGE_PIN E18 IOSTANDARD LVCMOS33 } [get_ports {led[0]}]
set_property -dict { PACKAGE_PIN F13 IOSTANDARD LVCMOS33 } [get_ports {led[1]}]
set_property -dict { PACKAGE_PIN E13 IOSTANDARD LVCMOS33 } [get_ports {led[2]}]
set_property -dict { PACKAGE_PIN H15 IOSTANDARD LVCMOS33 } [get_ports {led[3]}]
set_property -dict { PACKAGE_PIN J15 IOSTANDARD LVCMOS33 } [get_ports led0_r]
set_property -dict { PACKAGE_PIN G17 IOSTANDARD LVCMOS33 } [get_ports led0_g]
set_property -dict { PACKAGE_PIN F15 IOSTANDARD LVCMOS33 } [get_ports led0_b]

set_property -dict { PACKAGE_PIN E15 IOSTANDARD LVCMOS33 } [get_ports led1_r]
set_property -dict { PACKAGE_PIN F18 IOSTANDARD LVCMOS33 } [get_ports led1_g]
set_property -dict { PACKAGE_PIN E14 IOSTANDARD LVCMOS33 } [get_ports led1_b]

# Pmod JC: the DZ11's line 0 to a USB-UART (JC1 TX out, JC2 RX in, JC5 GND)
set_property -dict { PACKAGE_PIN U15   IOSTANDARD LVCMOS33 DRIVE 8 } [get_ports jc_txd]
set_property -dict { PACKAGE_PIN V16   IOSTANDARD LVCMOS33 PULLUP true } [get_ports jc_rxd]

# SW0: on = no boot from the boot ROM after reset
set_property -dict { PACKAGE_PIN H14   IOSTANDARD LVCMOS33 } [get_ports { sw[0] }]

# ---------------------------------------------------------------- Pmod SD
# Pmod MicroSD at JD (SPI mode): CS JD1, MOSI JD2, MISO JD3, SCLK JD4
set_property -dict { PACKAGE_PIN V15 IOSTANDARD LVCMOS33 } [get_ports sd_cs_n]
set_property -dict { PACKAGE_PIN U12 IOSTANDARD LVCMOS33 } [get_ports sd_mosi]
set_property -dict { PACKAGE_PIN V13 IOSTANDARD LVCMOS33 } [get_ports sd_miso]
set_property -dict { PACKAGE_PIN T12 IOSTANDARD LVCMOS33 } [get_ports sd_sclk]
set_property PULLUP true [get_ports sd_miso]
set_property DRIVE 8 [get_ports {sd_cs_n sd_mosi sd_sclk}]

# ---------------------------------------------------------------- timing
# asynchronous inputs (synchronized inside), slow outputs
set_false_path -from [get_ports {ck_rst uart_txd_in sw[0] jc_rxd}]
set_false_path -to   [get_ports {uart_rxd_out jc_txd led[*] led0_r led0_g led0_b led1_r led1_g led1_b}]
set_false_path -to   [get_ports {sd_cs_n sd_mosi sd_sclk}]
set_false_path -from [get_ports sd_miso]

# ---------------------------------------------------------------- track B
# the core (40 MHz) and the MIG's ui_clk are unrelated: arty_mem_mig.v
# hands requests over by toggles through two flip-flops, the data next to
# them being stable by then
set_clock_groups -asynchronous \
    -group [get_clocks -of_objects [get_nets clk]] \
    -group [get_clocks -of_objects [get_nets ui_clk]]
