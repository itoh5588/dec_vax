# build.tcl - Arty S7-50 bitstream of arty_top_b (the DDR3L through the MIG
# as 32 MB of main memory, the SD card, the DZ11, the boot ROM), Vivado
# non-project flow. Run from arty/build/vivado (make bit): rtl -> the core's
# rtl/ there, bootrom.hex copied there; the MIG from build/mig (make mig).
#
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Akio Itoh

set part   xc7s50csga324-1
set top    arty_top_b
set R      rtl
set A      ../../rtl
set clkmhz 40

set fork {
  div.v ucode.v intrpt.v intclk.v constx.v consrx.v console.v argdecode.v
  alu.v vcache.v mmu.v decunit.v fpunit.v cpu.v
  mister/vax_uart.v mister/vax_cache.v mister/vax_sbi.v mister/vax_uba.v
  mister/vax_mba.v mister/vax_rp07.v mister/vax_io.v mister/vax_core.v
}
set ours { arty_mem_mig.v arty_sdcard.v arty_dz11.v arty_sys.v arty_top_b.v }

# Vivado reads all files as one compilation unit: a `default_nettype none in
# one file leaks into the next, and some of the fork's files use untyped
# ANSI ports under it (fine for Quartus and Verilator). Read copies that
# start with `default_nettype wire and do not set none.
proc read_fixed {in out} {
  set f [open $in r]; set body [read $f]; close $f
  regsub -all -line {^\s*`default_nettype\s+none\s*$} $body {} body
  file mkdir [file dirname $out]
  set f [open $out w]; puts $f "`default_nettype wire"; puts -nonewline $f $body; close $f
  read_verilog $out
}
foreach f $fork { read_fixed $R/$f src/$f }
foreach f $ours { read_fixed $A/$f src/arty/$f }
# sdspi (MIT) and the package it uses (slvtypes.vhd, this project's)
read_vhdl [list $A/sdspi/slvtypes.vhd $A/sdspi/sdspi_phy.vhd $A/sdspi/sdspi_ctl.vhd]
read_ip ../mig/ip/mig_ddr3/mig_ddr3.xci
read_xdc ../../xdc/arty_s7_50_b.xdc

set_param general.maxThreads 8
synth_design -top $top -part $part -include_dirs $R \
    -verilog_define [list MISTER=1 CLKPERBIT=16 CACHEIDX=10 CLK_MHZ=$clkmhz VAX_EXT_MEM=1 ARTY_MEM_KB=32768 ARTY_SD=1 ARTY_BOOTROM=1 VAX_UNIBUS=1 ARTY_DZ=1]
write_checkpoint -force syn.dcp
report_utilization -file syn_util.rpt
report_utilization -hierarchical -hierarchical_depth 4 -file syn_util_h.rpt
report_ram_utilization -file syn_ram.rpt

opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force rou.dcp
report_utilization -file rou_util.rpt
report_utilization -hierarchical -hierarchical_depth 4 -file rou_util_h.rpt
report_timing_summary -max_paths 20 -file rou_tim.rpt
report_clock_utilization -file rou_clk.rpt
report_drc -file rou_drc.rpt

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "TIMING WNS $wns WHS $whs"

write_bitstream -force $top.bit
puts "BUILD DONE"
