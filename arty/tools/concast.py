#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Akio Itoh
"""concast.py - record the Arty S7 console as an asciinema v2 cast, no pyserial.

    concast.py [-p /dev/ttyUSB1] [-u UNTIL] [-a AFTER] [-t SECONDS] -o boot.cast

Opens the UART at 115200 8N1 and writes everything the board sends, with
the time it came, to the .cast file (the 7-bit characters: 4.3BSD's
parity bit is dropped), and echoes it on stdout. The recording starts with
the first character; it ends AFTER seconds (default 3) after the output
contains UNTIL (default "login: "), or after SECONDS of silence (default
60). Turn into a GIF with agg (github.com/asciinema/agg):

    agg --idle-time-limit 3 boot.cast boot.gif
"""
import argparse
import json
import os
import select
import sys
import termios
import time


def open_port(path):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    a = termios.tcgetattr(fd)
    a[0] = a[1] = a[3] = 0                        # raw: no input/output/local processing
    a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    a[4] = a[5] = termios.B115200
    a[6][termios.VMIN] = 0
    a[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, a)
    termios.tcflush(fd, termios.TCIFLUSH)
    return fd


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('-p', '--port', default='/dev/ttyUSB1')
    ap.add_argument('-o', '--output', required=True)
    ap.add_argument('-u', '--until', default='login: ')
    ap.add_argument('-a', '--after', type=float, default=3.0)
    ap.add_argument('-t', '--silence', type=float, default=60.0)
    ap.add_argument('--cols', type=int, default=80)
    ap.add_argument('--rows', type=int, default=24)
    a = ap.parse_args()

    fd = open_port(a.port)
    out = open(a.output, 'w')
    out.write(json.dumps({'version': 2, 'width': a.cols, 'height': a.rows,
                          'timestamp': int(time.time()),
                          'title': 'r-vax on the Arty S7: 4.3BSD boot'}) + '\n')
    t0 = None
    seen = ''
    end = None
    last = time.time()
    while True:
        now = time.time()
        if end and now >= end:
            break
        if now - last > a.silence:
            print('\n[concast: %g s of silence]' % a.silence, file=sys.stderr)
            break
        r, _, _ = select.select([fd], [], [], 0.05)
        if not r:
            continue
        d = os.read(fd, 4096)
        if not d:
            continue
        last = now
        s = bytes(c & 0x7F for c in d).decode('ascii')
        s = s.replace('\0', '')
        if not s:
            continue
        if t0 is None:
            t0 = now
        out.write(json.dumps([round(now - t0, 4), 'o', s]) + '\n')
        out.flush()
        sys.stdout.write(s)
        sys.stdout.flush()
        if end is None and a.until:
            seen = (seen + s)[-200:]
            if a.until in seen:
                end = now + a.after
    out.close()
    os.close(fd)
    print('\n[concast: %s, %.1f s]' % (a.output, (last - t0) if t0 else 0), file=sys.stderr)


if __name__ == '__main__':
    main()
