#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Akio Itoh
"""mkvmsboot.py - a download frame that boots VMS through VMB.

    mkvmsboot.py vmb.exe [-u UNIT] [--todr now|none|HEX] -o vmsboot.vxld

VMB.EXE (open-simh's vmb.exe) goes at 200 and a start at 18000 that sets
the registers as the 8600 console does for a Massbus disk (R0=0, R1=8 the
RH780's TR, R2=0, R3=UNIT, R4=0, R5=80 to skip VMB's memory test, SP=200)
and jumps to VMB. The frame (tools/mkvxld.py) starts at 18000.

--todr now (the default) first writes the TODR in VMS's form, as SIMH's
8600 does: 10000000 + hundredths of a second since 1 January, local time,
taken when the frame is made. The board's TODR has no battery and comes up
at a fixed value; VMS asks for the date when that is earlier than the time
it saved at the last shutdown. Make the frame just before sending it.
--todr none leaves the TODR alone; --todr HEX writes that value.
"""
import argparse
import os
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mkvxld import frame  # noqa: E402

VMB_AT = 0x200
START = 0x18000
IPR_TODR = 0x1B


def vms_todr(t=None):
    """The TODR VMS would set for time t (local time, 10 ms units)."""
    if t is None:
        t = time.time()
    lt = time.localtime(t)
    sec = ((lt.tm_yday - 1) * 24 + lt.tm_hour) * 3600 + lt.tm_min * 60 \
        + lt.tm_sec
    return 0x10000000 + sec * 100 + int((t % 1) * 100)


def stub(unit, todr):
    code = b''
    if todr is not None:
        code += b'\xDA\x8F' + struct.pack('<I', todr) + bytes([IPR_TODR])
    code += (b'\xD4\x50'                                  # clrl r0
             b'\xD0\x08\x51'                              # movl #8, r1
             b'\xD4\x52')                                 # clrl r2
    code += b'\xD4\x53' if unit == 0 else b'\xD0' + bytes([unit, 0x53])
    code += (b'\xD4\x54'                                  # clrl r4
             b'\xD0\x8F' + struct.pack('<I', 0x80) + b'\x55'
             b'\xD0\x8F' + struct.pack('<I', VMB_AT) + b'\x5E'
             b'\x17\x9F' + struct.pack('<I', VMB_AT))     # jmp @#200
    return code


def build(vmb, unit=0, todr=None):
    if len(vmb) > START - VMB_AT:
        raise ValueError('VMB is %d bytes, more than fits below %X'
                         % (len(vmb), START))
    data = vmb + bytes(START - VMB_AT - len(vmb)) + stub(unit, todr)
    return frame(data, VMB_AT, START)


def parse_todr(s):
    if s == 'now':
        return vms_todr()
    if s == 'none':
        return None
    return int(s, 16)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('vmb')
    ap.add_argument('-u', '--unit', type=int, default=0,
                    help='RP07 unit (0..63)')
    ap.add_argument('--todr', default='now', help='now, none or hex')
    ap.add_argument('-o', '--output', required=True)
    a = ap.parse_args()
    todr = parse_todr(a.todr)
    with open(a.vmb, 'rb') as f:
        vmb = f.read()
    with open(a.output, 'wb') as f:
        f.write(build(vmb, a.unit, todr))
    print('%s: VMB %d bytes at %X, start %X, unit %d, TODR %s' % (
        a.output, len(vmb), VMB_AT, START, a.unit,
        'unchanged' if todr is None else '%08X' % todr))
    return 0


if __name__ == '__main__':
    sys.exit(main())
