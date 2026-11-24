#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Akio Itoh
"""mkbootrom.py - a program as the boot ROM of arty_sys (ARTY_BOOTROM):
$readmemh text, one little-endian longword a line, padded with zeros to
the ROM's size (8192 longwords). The program is raw, loaded at 0, or an
a.out (OMAGIC 0407 / NMAGIC 0410, as 4.3BSD's /boot): then the 32-byte
header is dropped and text and data are taken as they follow it (OMAGIC:
together, as the a.out says; NMAGIC is refused - its data would move)."""
import argparse, struct, sys

ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
ap.add_argument('bin')
ap.add_argument('-o', '--output', required=True)
ap.add_argument('-w', '--words', type=int, default=8192)
a = ap.parse_args()

d = open(a.bin, 'rb').read()
if len(d) >= 32:
    magic, text, data = struct.unpack('<III', d[:12])
    if magic == 0o407:
        d = d[32:32 + text + data]
        print(f'{a.bin}: a.out 0407, text {text:#x} data {data:#x}', file=sys.stderr)
    elif magic in (0o410, 0o413):
        sys.exit(f'{a.bin}: a.out {magic:o}: text and data apart, not a ROM')
if len(d) > 4 * a.words:
    sys.exit(f'{a.bin}: {len(d)} bytes, the ROM holds {4 * a.words}')
d += bytes(4 * a.words - len(d))
with open(a.output, 'w') as f:
    for i in range(a.words):
        f.write('%08x\n' % struct.unpack_from('<I', d, 4 * i))
print(f'{a.output}: {a.words} longwords', file=sys.stderr)
