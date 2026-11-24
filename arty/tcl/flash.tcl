# flash.tcl - write a bitstream to the Arty S7-50's SPI flash (Micron
# MT25QL128, 16 MB), verify it and boot the FPGA from it: from then on the
# board loads it at power-up by itself (the MODE jumper JP1 on, its
# factory position: boot from the SPI flash).
#
#   vivado -mode batch -nojournal -nolog -source tcl/flash.tcl \
#          -tclargs <file.bit> [<backup.bin>]
#
# With <backup.bin> the whole flash is read into that file first (the
# design there before, to put back with write_cfgmem/program_hw_cfgmem).
# The bitstreams of this project are built for SPI x4 (SPI_BUSWIDTH 4 in
# the XDC); the .mcs goes next to the .bit.
#
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Akio Itoh

if {$argc < 1} { error "flash.tcl <file.bit> \[<backup.bin>\]" }
set bit [file normalize [lindex $argv 0]]
set backup [expr {$argc > 1 ? [file normalize [lindex $argv 1]] : ""}]
if {![file exists $bit]} { error "no bitstream: $bit" }
set mcs "[file rootname $bit].mcs"
write_cfgmem -force -format mcs -size 16 -interface SPIx4 \
    -loadbit "up 0x0 $bit" -file $mcs

open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices xc7s50*] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
create_hw_cfgmem -hw_device $dev \
    [lindex [get_cfgmem_parts {mt25ql128-spi-x1_x2_x4}] 0]
set cm [get_property PROGRAM.HW_CFGMEM $dev]

# the flash is reached through Vivado's own bitstream in the FPGA
create_hw_bitstream -hw_device $dev [get_property PROGRAM.HW_CFGMEM_BITFILE $dev]
program_hw_devices $dev
refresh_hw_device $dev

if {$backup ne ""} {
  file mkdir [file dirname $backup]
  set t0 [clock seconds]
  readback_hw_cfgmem -force -all -format bin -file $backup -hw_cfgmem $cm
  puts "BACKUP: $backup in [expr {[clock seconds] - $t0}] s"
}

set_property PROGRAM.ADDRESS_RANGE          {use_file} $cm
set_property PROGRAM.FILES                  [list $mcs] $cm
set_property PROGRAM.PRM_FILE               {}         $cm
set_property PROGRAM.UNUSED_PIN_TERMINATION {pull-none} $cm
set_property PROGRAM.BLANK_CHECK            0 $cm
set_property PROGRAM.ERASE                  1 $cm
set_property PROGRAM.CFG_PROGRAM            1 $cm
set_property PROGRAM.VERIFY                 1 $cm
set_property PROGRAM.CHECKSUM               0 $cm
set t0 [clock seconds]
program_hw_cfgmem -hw_cfgmem $cm
puts "FLASHED: $bit in [expr {[clock seconds] - $t0}] s (erase, program, verify)"

# and now from the flash, as at power-up
boot_hw_device $dev
after 8000
refresh_hw_device $dev
puts "DONE_PIN: [get_property REGISTER.CONFIG_STATUS.BIT14_DONE_PIN $dev]"
close_hw_target
disconnect_hw_server
close_hw_manager
