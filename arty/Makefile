# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Akio Itoh
#
# The r-vax VAX 8600 on the Digilent Arty S7-50, booting 4.3BSD: DDR3L
# (32 MB through the Xilinx MIG) as main memory, an RP07 on a microSD card
# (Pmod MicroSD on JD), a DZ11 line on Pmod JC, and 4.3BSD's /boot in a
# boot ROM. Run make here, in arty/; see README.md.
#
#   make disk      4.3BSD on an RP07 image, installed with SIMH (43bsd/)
#   make bootrom   the boot ROM from that disk's /boot -> build/bootrom.hex
#                  (VMB=vmb.exe: also VMS's VMB, booted with SW1 on)
#   make mig       the MIG for the DDR3L (Vivado) -> build/mig
#   make bit       the bitstream -> build/vivado/arty_top_b.bit
#   make program   load it over JTAG (volatile)
#   make flash     write it to the SPI flash (boots at power-up)
#   make simb      Verilator bench: the same system, MIG and SD as models
#   make simboot   the bench boots 4.3BSD from the disk image (slow)
#   make vms46     VAX/VMS V4.6 on an RP07 image (vms/; TAPE= [HELPER=])

SHELL   = /bin/bash
R       = ../rtl
CLK_MHZ = 40
VIVADO_SETTINGS ?= $(HOME)/Xilinx-2025.2/2025.2/Vivado/settings64.sh
WORK    ?= 43bsd/work
DISK     = $(WORK)/43bsd-rp07.dsk
BOOTAOUT = $(WORK)/boot.aout

RVAX   = div.v ucode.v intrpt.v intclk.v constx.v consrx.v console.v mmu.v \
         argdecode.v alu.v vcache.v decunit.v fpunit.v cpu.v
MISTER = vax_uart.v vax_cache.v vax_sbi.v vax_uba.v vax_mba.v vax_rp07.v \
         vax_io.v vax_core.v
CORE   = $(addprefix $(R)/,$(RVAX)) $(addprefix $(R)/mister/,$(MISTER))
OURS   = rtl/arty_sys.v rtl/arty_mem_mig.v rtl/arty_sdcard.v rtl/arty_dz11.v
SDSPI  = rtl/sdspi/slvtypes.vhd rtl/sdspi/sdspi_phy.vhd rtl/sdspi/sdspi_ctl.vhd

.PHONY: disk bootrom mig bit program flash simb simboot vms46 clean

# ---------------------------------------------------------------- 4.3BSD
disk: $(DISK)

$(DISK) $(BOOTAOUT):
	sh 43bsd/make43.sh $(abspath $(WORK))

bootrom: build/bootrom.hex

# VMB= open-simh's VAX/vmb.exe: the boot ROM also boots VMS, at 8000
VMB ?=
build/bootrom.hex: $(BOOTAOUT) tools/mkbootrom.py tools/mkvmsboot.py $(VMB)
	mkdir -p build
	python3 tools/mkbootrom.py $< $(if $(VMB),--vmb $(VMB)) -o $@

# ---------------------------------------------------------------- VMS
# VAX/VMS V4.6 from its distribution tape (vms/mkvms46.py): TAPE= the
# tape image BB-BT05D-BE (.tap or .tap.gz); $$VMS_PASSWORD (the new
# system's) in the environment; ods2 (open-simh simtools) for the
# standalone BACKUP. Or HELPER= an RP07 image with a VMS that has BACKUP
# (it is copied) and $$HELPER_PASSWORD (its SYSTEM).
VMSWORK ?= vms/work
vms46: $(VMSWORK)/vms46-rp07.dsk

$(VMSWORK)/vms46-rp07.dsk:
	@test -n "$(TAPE)" || \
	  { echo "make vms46 TAPE=<tape image> [HELPER=<RP07 image with VMS>]"; exit 1; }
	python3 vms/mkvms46.py --tape $(TAPE) $(if $(HELPER),--helper $(HELPER)) \
	  --work $(VMSWORK) -o $@

# ---------------------------------------------------------------- Vivado
mig: build/mig/ip/mig_ddr3/mig_ddr3.xci

build/mig/ip/mig_ddr3/mig_ddr3.xci: tcl/mig.tcl tcl/mkmigprj.py
	mkdir -p build/mig
	cd build/mig && . $(VIVADO_SETTINGS) && \
	  vivado -mode batch -nojournal -log mig.log -source ../../tcl/mig.tcl

# build/vivado/rtl -> the core's rtl/ (the microcode's $readmemh paths
# start with rtl/)
bit: build/vivado/arty_top_b.bit

build/vivado/arty_top_b.bit: $(CORE) $(OURS) rtl/arty_top_b.v $(SDSPI) \
      xdc/arty_s7_50_b.xdc tcl/build.tcl build/mig/ip/mig_ddr3/mig_ddr3.xci build/bootrom.hex
	mkdir -p build/vivado
	ln -sfn ../../$(R) build/vivado/rtl
	cp build/bootrom.hex build/vivado/bootrom.hex
	cd build/vivado && . $(VIVADO_SETTINGS) && \
	  vivado -mode batch -nojournal -log vivado.log -source ../../tcl/build.tcl

program: build/vivado/arty_top_b.bit
	. $(VIVADO_SETTINGS) && vivado -mode batch -nojournal -nolog \
	  -source tcl/program.tcl -tclargs $<

flash: build/vivado/arty_top_b.bit
	. $(VIVADO_SETTINGS) && vivado -mode batch -nojournal -nolog \
	  -source tcl/flash.tcl -tclargs $<

# ---------------------------------------------------------------- bench
# the UART fast on the bench (the protocol is the same)
SIM_UART_CLKS = 24
SIMB_SRC = $(CORE) $(OURS) sim/mig_ui_model.v sim/sdspi_model.v sim/sim_b_top.v

# make simb BOOTROM=0: no boot ROM, in build/simb0 (for a download frame
# such as VMB's, tools/mkvmsboot.py); SIM_DEFS adds defines (-DVAX_WATCH;
# -DSIM_ROM_VMS: SW1 on, the boot ROM boots VMS)
ifeq ($(BOOTROM),0)
SIMB_DIR = build/simb0
SIMB_ROM =
SIMB_DEP =
else
SIMB_DIR = build/simb
SIMB_ROM = -DARTY_BOOTROM -DARTY_BOOTROM_HEX='"$(CURDIR)/build/bootrom.hex"'
SIMB_DEP = build/bootrom.hex
endif

simb: $(SIMB_DIR)/Vsim_b_top

$(SIMB_DIR)/Vsim_b_top: $(SIMB_SRC) sim/tb_arty.cpp $(SIMB_DEP)
	verilator --cc --exe --build -j 4 -O2 -Wno-fatal -Wno-WIDTH -Wno-TIMESCALEMOD \
	  -DMISTER -DCLKPERBIT=16 -DCACHEIDX=10 -DCLK_MHZ=$(CLK_MHZ) -DVAX_EXT_MEM \
	  -DARTY_MEM_KB=32768 -DARTY_SD -DVAX_UNIBUS -DARTY_DZ $(SIMB_ROM) $(SIM_DEFS) \
	  -GCLK_HZ=$(CLK_MHZ)000000 -GUART_CLKS=$(SIM_UART_CLKS) \
	  -I$(R) --top-module sim_b_top -Mdir $(SIMB_DIR) $(SIMB_SRC) $(CURDIR)/sim/tb_arty.cpp \
	  -CFLAGS "-O1 -w -DUART_CLKS=$(SIM_UART_CLKS) -DTWO_CLOCKS -DSD_MODEL -DDZ_LINE -DTOPCLASS=Vsim_b_top -DTOPHDR='\"Vsim_b_top.h\"'" \
	  -o Vsim_b_top

# from build/ (rtl -> the core's rtl/, for the microcode); no download:
# the boot ROM loads /boot, /boot the kernel, which comes up; runs for
# SIMCLOCKS clocks (the disk image is only read: blocks written stay in
# the bench)
SIMCLOCKS ?= 400000000
simboot: build/simb/Vsim_b_top $(DISK)
	ln -sfn ../$(R) build/rtl
	-cd build && SDIMG=$(abspath $(DISK)) simb/Vsim_b_top - $(SIMCLOCKS)

clean:
	rm -rf build/simb build/vivado build/bootrom.hex
