# mig.tcl - generate and synthesize the MIG (mig_7series) for the DDR3L of
# the Arty S7-50, out of context, from the project file of tcl/mkmigprj.py.
# Run from build/mig (make mig); the result is ip/mig_ddr3/mig_ddr3.xci
# with its synthesized checkpoint, read by tcl/build_b.tcl.
#
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Akio Itoh

set part xc7s50csga324-1
create_project -in_memory -part $part
set_property target_language Verilog [current_project]

set vlnv [lindex [get_ipdefs "xilinx.com:ip:mig_7series:*"] 0]
puts "MIG: $vlnv"
file mkdir ip
create_ip -vlnv $vlnv -module_name mig_ddr3 -dir ip

set ip_dir [get_property IP_DIR [get_ips mig_ddr3]]
exec python3 ../../tcl/mkmigprj.py $ip_dir/mig_arty_s7.prj
set_property -dict [list \
    CONFIG.XML_INPUT_FILE mig_arty_s7.prj \
    CONFIG.RESET_BOARD_INTERFACE {Custom} \
    CONFIG.MIG_DONT_TOUCH_PARAM {Custom} \
    CONFIG.BOARD_MIG_PARAM {Custom}] [get_ips mig_ddr3]

generate_target all [get_ips mig_ddr3]
set_param general.maxThreads 8
synth_ip [get_ips mig_ddr3]
puts "MIG DONE: [get_files -of_objects [get_ips mig_ddr3] *.veo]"
