#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Akio Itoh
#
# make43.sh - 4.3BSD on an RP07 for the Arty S7, installed with SIMH's
# vax8600 from the original distribution (TUHS), all unattended:
#
#   ./make43.sh [workdir]          (default: ./work)
#
# Needs: curl, gunzip, python3, and SIMH's vax8600 (open-simh), in PATH or
# as $VAX8600. About 110 MB of distribution and 1.5 GB of disk images.
#
# Out, in workdir:
#   43bsd-rp07.dsk   the disk (raw RP07, 516,096,000 bytes): dd it to the
#                    SD card from sector 0
#   boot.aout        4.3BSD's /boot from that disk: the FPGA's boot ROM
#                    (make bootrom)
#
# Steps (each a SIMH script here, run with expect/send):
#   inst1.ini  the miniroot from the tape's stand boot, xtr: the root file
#              system onto hp0a
#   inst2.ini  newfs hp0h, /usr and /usr/sys from the tape
#   inst3.ini  for the Arty S7: /etc/fstab, the DZ11's tty00 (tty01-07
#              off), and /boot written to a tape to take out
set -e
here=$(cd "$(dirname "$0")" && pwd)
work=${1:-$here/work}
sim=${VAX8600:-$(command -v vax8600 || echo "$HOME/build/open-simh/BIN/vax8600")}
[ -x "$sim" ] || { echo "make43.sh: no SIMH vax8600 (set VAX8600)" >&2; exit 1; }
url=https://www.tuhs.org/Archive/Distributions/UCB/4BSD/4.3BSD

mkdir -p "$work/dist" "$work/stand"
cd "$work"

# 1. the distribution
for f in stand miniroot rootdump srcsys.tar usr.tar vfont.tar src.tar new.tar ingres.tar; do
	[ -s dist/$f ] && continue
	echo "fetch $f"
	curl -fsSL -o dist/$f.gz "$url/$f.gz"
	gunzip -f dist/$f.gz
done

# 2. the tape, and the standalone boot from its first file (tp format:
#    the directory says block 63, but the blocks count from 7 later; boot
#    is 25124 bytes, raw, loaded at 0 and started at 2)
python3 "$here/mktap.py" 43.tap
python3 - <<'EOF'
d = open('dist/stand', 'rb').read()
b = d[70 * 512:70 * 512 + 25124]
assert b[:6] == bytes.fromhex('0000da1f12d0'), 'stand: no boot at block 70'
open('stand/boot', 'wb').write(b)
EOF

# 3. the install
cp dist/miniroot miniroot.rp07
rm -f disk0.rp07 boot.tap
for s in inst1 inst2 inst3; do
	echo "== $s"
	timeout 3600 "$sim" "$here/$s.ini" > $s.log 2>&1 || { tail -20 $s.log; exit 1; }
	grep -q "${s}: DONE" $s.log || { echo "$s: did not finish, see $work/$s.log" >&2; tail -20 $s.log; exit 1; }
done

# 4. /boot off the tape inst3 wrote
python3 - <<'EOF'
import struct
d = open('boot.tap', 'rb').read(); o = b''; i = 0
while i + 4 <= len(d):
    n = struct.unpack('<I', d[i:i + 4])[0]; i += 4
    if n in (0, 0xFFFFFFFF):
        continue
    o += d[i:i + n]; i += n + (n & 1) + 4
magic, text, data = struct.unpack('<III', o[:12])
assert magic == 0o407, 'boot.tap: not an a.out 0407'
o = o[:32 + text + data]
open('boot.aout', 'wb').write(o)
print('boot.aout: text %#x data %#x' % (text, data))
EOF
mv disk0.rp07 43bsd-rp07.dsk
ls -l 43bsd-rp07.dsk boot.aout
