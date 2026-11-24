#!/usr/bin/env python3
# mktap.py - the 4.3BSD distribution tape as one SIMH .tap file
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Akio Itoh
#
#   mktap.py out.tap   (in the directory that holds dist/)
#
# The files of the TUHS 4.3BSD distribution, in the order of the tape (the
# record sizes of the original: 512 for stand, 10240 for the rest), each
# followed by a tape mark; SIMH .tap format.
import struct, sys
files = [('stand', 512), ('miniroot', 10240), ('rootdump', 10240),
         ('srcsys.tar', 10240), ('usr.tar', 10240), ('vfont.tar', 10240),
         ('src.tar', 10240), ('new.tar', 10240), ('ingres.tar', 10240)]
with open(sys.argv[1], 'wb') as t:
    for name, rec in files:
        d = open('dist/' + name, 'rb').read()
        for i in range(0, len(d), rec):
            r = d[i:i + rec]
            t.write(struct.pack('<I', len(r)) + r + (b'\0' if len(r) & 1 else b'') + struct.pack('<I', len(r)))
        t.write(struct.pack('<I', 0))          # tape mark
        print('%-12s %8d bytes, %5d records of %d' % (name, len(d), (len(d) + rec - 1) // rec, rec))
    t.write(struct.pack('<I', 0))
    t.write(struct.pack('<I', 0xFFFFFFFF))     # end of medium
