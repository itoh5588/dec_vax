# r-vax: DEC VAX Verilog code.

### A VAX 8600-compatible core running 4.3BSD on a small FPGA

> **This fork (branch `arty-s7`): 4.3BSD on a Digilent Arty S7-50.** The
> MiSTer branch's r-vax core, which implements the VAX 8600 as software
> sees it, runs on the Arty S7-50 with DDR3L main memory and an RP07 on a
> microSD card, and boots the unmodified 4.3BSD GENERIC kernel to
> multi-user mode at power-up. 4.3BSD takes it for a VAX 8600. It is not a
> copy of DEC's 8600 hardware, and much slower (about 1.1 MIPS at 40 MHz).
> See [arty/README.md](arty/README.md).
>
> <img src="arty/docs/arty-s7.jpg" alt="The Arty S7-50 with the Pmod MicroSD on JD and a USB-UART on JC" width="400">
>
> ![4.3BSD booting on the Arty S7](arty/docs/boot-43bsd.gif)
>
> Upstream: [Maverick-Shark/dec_vax](https://github.com/Maverick-Shark/dec_vax)
> (MiSTer branch). The text below is upstream's.

This is an basic implementation of the DEC VAX cpu.  It was written by me for a way to learn verilog, hence not pretty.  I also assume it is quite incorrect in quite some places.

It implements the Vax basic instruction set and passes the **EVKAA.EXE** basic instruction set test program.

There are quite some parts missing; for example memory management and floating point instructions.

It runs on the Waveshare Open3S500E Spartan-3 board.  
Code for simulation in Verilator also exist and works.

## MiSTer port

This branch adds a MiSTer (DE10-Nano) version of r-vax: CPU, 32 MB SDRAM,
on-screen VT100-style console terminal and USB keyboard. See
[README_MiSTer.md](README_MiSTer.md).
