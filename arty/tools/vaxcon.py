#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Akio Itoh
"""vaxcon.py - the host side of the Arty S7 console (arty_sys.v), no pyserial.

    vaxcon.py [-p /dev/ttyUSB1] [-f frame.vxld] [-w WAITFOR -k KEYS]...
              [-t SECONDS] [-u UNTIL] [-l LOG]

Opens the UART at 115200 8N1 and prints what the board sends (06 as <ACK>,
15 as <NAK>). With -f it sends a download frame (sw/tools/mkvxld.py) and
waits for the answer; -k then types KEYS ("\\r" = CR, "\\x10" = Ctrl+P),
one character every 2 ms (with -w, once the output contains WAITFOR; the
pairs -w/-k are repeatable, each WAITFOR looked for after the previous one,
and the time each one came is reported on stderr; the n-th -k goes with the
n-th -w, so to type something at once before waiting, give -w "" first).
Ends after -t seconds of silence or when the
output contains UNTIL (-u). Exit status: 0, or 1 on NAK or no answer.
Without -f/-k/-u it just listens (-t 0: until Ctrl+C).
"""
import argparse
import os
import select
import sys
import termios
import time


def open_port(path):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    a = termios.tcgetattr(fd)
    a[0] = 0                                        # iflag: raw
    a[1] = 0                                        # oflag
    a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    a[3] = 0                                        # lflag
    a[4] = a[5] = termios.B115200
    a[6][termios.VMIN] = 0
    a[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, a)
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def unescape(s):
    return s.encode('latin-1').decode('unicode_escape').encode('latin-1')


class Con:
    def __init__(self, fd, log):
        self.fd, self.log = fd, log
        self.text = ''
        self.acks = self.naks = 0
        self.last = time.time()

    def poll(self, dt):
        r, _, _ = select.select([self.fd], [], [], dt)
        if not r:
            return
        d = os.read(self.fd, 4096)
        if not d:
            return
        self.last = time.time()
        out = []
        for b in d:
            if b == 0x06:
                self.acks += 1
                out.append('<ACK>')
            elif b == 0x15:
                self.naks += 1
                out.append('<NAK>')
            else:
                out.append(chr(b & 0x7F))
        s = ''.join(out)
        self.text += s
        sys.stdout.write(s)
        sys.stdout.flush()
        if self.log:
            self.log.write(s)
            self.log.flush()

    def write_all(self, data):
        # the port is non-blocking: os.write takes only what fits in the
        # driver's buffer; go on (reading meanwhile) until all of it is out
        while data:
            try:
                n = os.write(self.fd, data)
                data = data[n:]
            except BlockingIOError:
                n = 0
            if data:
                select.select([], [self.fd], [], 0.05)
                self.poll(0)

    def send(self, data, gap=0.0):
        if gap == 0.0:
            self.write_all(data)
            return
        for b in data:
            self.write_all(bytes([b]))
            self.poll(gap)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('-p', '--port', default='/dev/ttyUSB1')
    ap.add_argument('-f', '--frame')
    ap.add_argument('-k', '--keys', action='append',
                    help='repeatable: typed after the matching -w (or at once)')
    ap.add_argument('-t', '--timeout', type=float, default=5.0,
                    help='seconds of silence that end the run (0: never)')
    ap.add_argument('-w', '--waitfor', action='append',
                    help='repeatable: wait until the output contains this (and 0.2 s), '
                         'then type the -k of the same position; the time is reported')
    ap.add_argument('-u', '--until', help='stop when the output contains this')
    ap.add_argument('-l', '--log')
    a = ap.parse_args()

    log = open(a.log, 'a') if a.log else None
    con = Con(open_port(a.port), log)
    status = 0
    try:
        con.poll(0.2)
        if a.frame:
            data = open(a.frame, 'rb').read()
            t0 = time.time()
            con.send(data)
            # 10 bits a byte at 115200: wait for the line, then the answer
            dl = time.time() + len(data) * 10 / 115200 + 3.0
            while not (con.acks or con.naks) and time.time() < dl:
                con.poll(0.05)
            if not (con.acks or con.naks):
                sys.stdout.write('\n[vaxcon: no answer to the frame]\n')
                status = 1
            elif con.naks:
                status = 1
            else:
                sys.stderr.write('[vaxcon: %d bytes in %.1f s]\n'
                                 % (len(data), time.time() - t0))
        waits = a.waitfor or []
        keys = a.keys or []
        t_start = time.time()
        pos = 0                          # how far into the text matched
        for i in range(max(len(waits), len(keys))):
            if status:
                break
            if i < len(waits):
                while True:
                    k = con.text.find(waits[i], pos)
                    if k >= 0:
                        pos = k + len(waits[i])
                        break
                    con.poll(0.05)
                    if a.timeout and time.time() - con.last > a.timeout:
                        status = 1
                        break
                if status:
                    sys.stderr.write('\n[vaxcon: %r did not come]\n' % waits[i])
                    break
                sys.stderr.write('\n[vaxcon: %r at %.3f s]\n'
                                 % (waits[i], time.time() - t_start))
                # a program may clear its input after the prompt: wait a little
                wait = time.time() + 0.2
                while time.time() < wait:
                    con.poll(0.05)
            elif a.frame:                # let autostart (if any) finish typing
                wait = time.time() + 0.3
                while time.time() < wait:
                    con.poll(0.05)
            if i < len(keys) and keys[i]:
                con.send(unescape(keys[i]), gap=0.002)
        while True:
            con.poll(0.05)
            if a.until and a.until in con.text:
                # take what follows on the same burst
                wait = time.time() + 0.2
                while time.time() < wait:
                    con.poll(0.05)
                break
            if a.timeout and time.time() - con.last > a.timeout:
                break
    except KeyboardInterrupt:
        pass
    sys.stdout.write('\n')
    return status


if __name__ == '__main__':
    sys.exit(main())
