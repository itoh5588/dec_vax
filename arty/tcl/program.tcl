# program.tcl - load a bitstream into the Arty S7-50 over JTAG (volatile:
# the FPGA forgets it at power-off; the SPI flash is not touched).
#
#   vivado -mode batch -nojournal -nolog -source tcl/program.tcl -tclargs <file.bit>
#
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Akio Itoh

set bit [file normalize [lindex $argv 0]]
open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices xc7s50*] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
puts "PROGRAMMED $dev with $bit"
close_hw_target
disconnect_hw_server
close_hw_manager
