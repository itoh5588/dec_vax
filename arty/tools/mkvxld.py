#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Akio Itoh
"""mkvxld.py - wrap a binary image in a download frame for arty_sys.v.

    mkvxld.py prog.bin [-l LOAD] [-s START | -n] -o prog.vxld

Frame (little endian):  02 "VXLD" load(4) start(4) len(4) data crc32(4)
crc32 as zlib.crc32 over data. start FFFFFFFF (-n): load only, the CPU
stays in the console monitor. The default load and start address is 1000.
The board answers 06 (ACK) or 15 (NAK).
"""
import argparse
import struct
import sys
import zlib


def frame(data, load, start):
    return (b'\x02VXLD' + struct.pack('<III', load, start, len(data)) + data
            + struct.pack('<I', zlib.crc32(data) & 0xFFFFFFFF))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('bin')
    ap.add_argument('-l', '--load', default='1000', help='load address (hex)')
    ap.add_argument('-s', '--start', help='start address (hex; default: load)')
    ap.add_argument('-n', '--nostart', action='store_true', help='load only')
    ap.add_argument('-o', '--output', required=True)
    a = ap.parse_args()
    data = open(a.bin, 'rb').read()
    load = int(a.load, 16)
    start = 0xFFFFFFFF if a.nostart else int(a.start or a.load, 16)
    with open(a.output, 'wb') as f:
        f.write(frame(data, load, start))
    print('%s: %d bytes at %X, start %s' % (
        a.output, len(data), load, 'none' if a.nostart else '%X' % start))
    return 0


if __name__ == '__main__':
    sys.exit(main())
