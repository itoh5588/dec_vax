#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Akio Itoh
"""mkbootrom.py - a program as the boot ROM of arty_sys (ARTY_BOOTROM):
$readmemh text, one little-endian longword a line, padded with zeros to
the ROM's size (20480 longwords, 80 KB). The program is raw, loaded at 0,
or an a.out (OMAGIC 0407 / NMAGIC 0410, as 4.3BSD's /boot): then the
32-byte header is dropped and text and data are taken as they follow it
(OMAGIC: together, as the a.out says; NMAGIC is refused - its data would
move). It must end below 8000.

--vmb VMB.EXE (open-simh's vmb.exe) adds the VMS boot at 8000, where the
ROM starts with SW1 on (rom_vms): VMB at 8200 and, past it, a start that
moves VMB to 200 (MOVC3) and then sets the registers as the 8600's
console does for a Massbus disk and jumps to VMB, as tools/mkvmsboot.py's
frame does, but without the TODR; at 8000 a jump to that start. Give the
VMS disk TIMEPROMPTWAIT 0, and VMS takes the time it saved last instead
of asking for it."""
import argparse
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mkvmsboot  # noqa: E402

VMS_AT = 0x8000         # the VMS start (arty_sys: rom_vms)
VMB_IN_ROM = 0x8200     # VMB in the ROM, moved to mkvmsboot.VMB_AT


def vms_start(vmb_len, unit=0):
    """(entry at VMS_AT, start after VMB). VMB moved to 200 reaches past
    VMS_AT (open-simh's is AE00 bytes), so the entry only jumps to the
    start, which lies past VMB in the ROM, out of the way: mtpr #1F, #IPL
    (the console's G leaves the IPL as it was), movc3 #len, @#VMB_IN_ROM,
    @#VMB_AT (it may overlap, upwards: MOVC3 copies as if through a
    buffer), then the registers and jmp @#VMB_AT (mkvmsboot.stub, no
    TODR)."""
    at = (VMB_IN_ROM + vmb_len + 15) & ~15
    entry = b'\x17\x9F' + struct.pack('<I', at)         # jmp @#at
    start = (b'\xDA\x1F\x12'                            # mtpr #1f, #ipl
             + b'\x28\x8F' + struct.pack('<H', vmb_len)  # movc3 #len,
             + b'\x9F' + struct.pack('<I', VMB_IN_ROM)    #   @#VMB_IN_ROM,
             + b'\x9F' + struct.pack('<I', mkvmsboot.VMB_AT)  # @#200
             + mkvmsboot.stub(unit, None))
    return entry, at, start


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('bin')
    ap.add_argument('-o', '--output', required=True)
    ap.add_argument('-w', '--words', type=int, default=20480)
    ap.add_argument('--vmb', help='VMB.EXE for the VMS boot at 8000')
    ap.add_argument('-u', '--unit', type=int, default=0,
                    help='the VMS system disk: RP07 unit')
    a = ap.parse_args()

    d = open(a.bin, 'rb').read()
    if len(d) >= 32:
        magic, text, data = struct.unpack('<III', d[:12])
        if magic == 0o407:
            d = d[32:32 + text + data]
            print(f'{a.bin}: a.out 0407, text {text:#x} data {data:#x}',
                  file=sys.stderr)
        elif magic in (0o410, 0o413):
            sys.exit(f'{a.bin}: a.out {magic:o}: text and data apart, '
                     'not a ROM')
    if len(d) > VMS_AT:
        sys.exit(f'{a.bin}: {len(d)} bytes, more than fits below {VMS_AT:X}')
    if a.vmb:
        vmb = open(a.vmb, 'rb').read()
        if len(vmb) > 0xFFFF:
            sys.exit('mkbootrom: VMB too large')
        entry, at, start = vms_start(len(vmb), a.unit)
        d += bytes(VMS_AT - len(d)) + entry
        d += bytes(VMB_IN_ROM - len(d)) + vmb
        d += bytes(at - len(d)) + start
        print(f'{a.bin}: VMB {len(vmb)} bytes at {VMB_IN_ROM:X}, entry at '
              f'{VMS_AT:X}, start at {at:X} (moves VMB to '
              f'{mkvmsboot.VMB_AT:X}), unit {a.unit}', file=sys.stderr)
    if len(d) > 4 * a.words:
        sys.exit(f'{a.bin}: {len(d)} bytes, the ROM holds {4 * a.words}')
    d += bytes(4 * a.words - len(d))
    with open(a.output, 'w') as f:
        for i in range(a.words):
            f.write('%08x\n' % struct.unpack_from('<I', d, 4 * i))
    print(f'{a.output}: {a.words} longwords', file=sys.stderr)


if __name__ == '__main__':
    main()
