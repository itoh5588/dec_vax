#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Akio Itoh
"""vmscast.py - boot OpenVMS on the Arty S7 and record the console as an
asciinema v2 cast, no pyserial.

    vmscast.py [-p /dev/ttyUSB1] (-f vmsboot.vxld | --vmb vmb.exe [-u UNIT])
               [-w WAIT -k KEYS]...
               [-a AFTER] [-t SECONDS] -o boot.cast

Opens the UART at 115200 8N1, sends the download frame (tools/mkvxld.py:
VMB and its start: tools/mkvmsboot.py), and writes everything the
board sends, with the time it came, to the .cast file (and to stdout). The
pairs -w/-k type KEYS ("\\r" = CR) once the output contains WAIT, each WAIT
looked for after the previous one, one character every 20 ms (the console
holds one character). The recording ends AFTER seconds (default 3) after
the last -w was seen and its keys typed and the output went quiet for
AFTER seconds, or after SECONDS of silence (default 300).

--vmb makes the frame (tools/mkvmsboot.py) just before sending it, with
the TODR set to the time then: VMS does not ask for the date.

The frame's answer (06/15) and NULs are left out of the cast. Turn it into a
GIF with agg (github.com/asciinema/agg):

    agg --idle-time-limit 2 vms.cast vms.gif
"""
import argparse
import json
import os
import select
import sys
import termios
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mkvmsboot  # noqa: E402


def open_port(path):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    a = termios.tcgetattr(fd)
    a[0] = a[1] = a[3] = 0                        # raw
    a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    a[4] = a[5] = termios.B115200
    a[6][termios.VMIN] = 0
    a[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, a)
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def write_all(fd, data):
    # the port is non-blocking: os.write takes only what fits in the
    # driver's buffer
    while data:
        try:
            n = os.write(fd, data)
        except BlockingIOError:
            n = 0
        data = data[n:]
        if data:
            select.select([], [fd], [], 1.0)


def unescape(s):
    return s.encode('latin-1').decode('unicode_escape').encode('latin-1')


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('-p', '--port', default='/dev/ttyUSB1')
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument('-f', '--frame')
    src.add_argument('--vmb', help='VMB.EXE: make the frame, TODR = now')
    ap.add_argument('-u', '--unit', type=int, default=0, help='RP07 unit (--vmb)')
    ap.add_argument('-w', '--waitfor', action='append', default=[])
    ap.add_argument('-k', '--keys', action='append', default=[])
    ap.add_argument('-o', '--output', required=True)
    ap.add_argument('-a', '--after', type=float, default=3.0)
    ap.add_argument('-t', '--silence', type=float, default=300.0)
    ap.add_argument('--title', default='r-vax on the Arty S7: OpenVMS VAX V7.3 boot')
    ap.add_argument('--cols', type=int, default=80)
    ap.add_argument('--rows', type=int, default=24)
    a = ap.parse_args()
    if len(a.waitfor) != len(a.keys):
        sys.exit('vmscast: give -w and -k in pairs')
    steps = [(w, unescape(k)) for w, k in zip(a.waitfor, a.keys)]

    fd = open_port(a.port)
    out = open(a.output, 'w')
    out.write(json.dumps({'version': 2, 'width': a.cols, 'height': a.rows,
                          'timestamp': int(time.time()), 'title': a.title}) + '\n')
    # the console monitor's prompt first (after a reset or a new bitstream
    # the board drops what comes before it): a CR, until '>' comes back
    buf = b''
    tw = time.time()
    while b'>' not in buf:
        if time.time() - tw > 30:
            sys.exit('vmscast: no console monitor prompt')
        os.write(fd, b'\r')
        r, _, _ = select.select([fd], [], [], 1.0)
        if r:
            buf += os.read(fd, 4096)
    time.sleep(0.2)
    termios.tcflush(fd, termios.TCIFLUSH)
    if a.vmb:
        todr = mkvmsboot.vms_todr()
        frame = mkvmsboot.build(open(a.vmb, 'rb').read(), a.unit, todr)
        print('[vmscast: TODR %08X]' % todr, file=sys.stderr)
    else:
        frame = open(a.frame, 'rb').read()
    write_all(fd, frame)
    t0 = time.time()
    seen = ''
    step = 0
    typing = b''
    next_key = 0.0
    done_at = None
    last = time.time()
    while True:
        now = time.time()
        if typing and now >= next_key:
            os.write(fd, typing[:1])
            typing = typing[1:]
            next_key = now + 0.02
        if step == len(steps) and not typing and done_at is None:
            done_at = now
        if done_at is not None and now - last > a.after and now - done_at > a.after:
            break
        if now - last > a.silence:
            print('\n[vmscast: %g s of silence]' % a.silence, file=sys.stderr)
            break
        r, _, _ = select.select([fd], [], [], 0.01)
        if not r:
            continue
        d = os.read(fd, 4096)
        if not d:
            continue
        last = now
        s = d.decode('latin-1').replace('\0', '').replace('\x06', '').replace('\x15', '')
        if not s:
            continue
        out.write(json.dumps([round(now - t0, 4), 'o', s]) + '\n')
        out.flush()
        sys.stdout.write(s)
        sys.stdout.flush()
        seen += s
        if step < len(steps) and not typing:
            i = seen.find(steps[step][0])
            if i >= 0:
                typing = steps[step][1]
                next_key = now + 0.3
                seen = seen[i + len(steps[step][0]):]
                step += 1
        seen = seen[-4000:]
    out.close()
    os.close(fd)
    print('\n[vmscast: %s, %.1f s]' % (a.output, last - t0), file=sys.stderr)


if __name__ == '__main__':
    main()
