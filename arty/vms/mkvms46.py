#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Akio Itoh
"""mkvms46.py - VAX/VMS V4.6 on an RP07 for the Arty S7, installed with
SIMH's vax8600 from the distribution tape, unattended.

    VMS_PASSWORD=... \\
    mkvms46.py --tape BB-BT05D-BE_VMS_4.6_87.tap[.gz] \\
               [--work DIR] [-o vms46-rp07.dsk] [--helper some-vms-rp07.dsk]

The tape (BB-BT05D-BE, a SIMH tape image) holds four save sets: VMS046.A
(an update kit), REQUIRED (an image save set of the system disk),
LIBRARY and OPTIONAL. The standalone BACKUP that restores REQUIRED came
on the 8600 console's own medium, not on this tape; vms/stabackit.py
builds one from the tape's own files on the host (needs ods2 from
open-simh/simtools, $ODS2).

  1. SIMH boots the standalone BACKUP disk from RP07 unit 0, with the new
     disk on unit 1 and the tape on TU0: conversationally, with
     STABACKIT.COM's SYSGEN parameters typed to SYSBOOT. It restores
     REQUIRED to the new disk: backup/image/verify mta0:required/save_set
     dra1:. Then SIMH stops it.

     Or, with --helper: an RP07 image with a VMS that boots in SIMH's
     vax8600 and has BACKUP (OpenVMS VAX 7.3 does), copied first and never
     changed, does the restore; its SYSTEM password from $HELPER_PASSWORD
     (--helper-user for another account with the privileges for
     BACKUP/IMAGE and MOUNT/FOREIGN).
  2. boot rp1: VAX/VMS V4.6 goes on with the install: the date, MTA0 for
     the kit, no to the cluster questions; it restores LIBRARY and
     OPTIONAL, asks for the SYSTEM, SYSTEST and FIELD passwords (all
     $VMS_PASSWORD), runs AUTOGEN and reboots itself.
  3. Log in, set DUMPBUG and TIMEPROMPTWAIT to 0 (SYSGEN, and
     MODPARAMS.DAT for AUTOGEN), show system, and shut down. With DUMPBUG
     1 every shutdown ends by writing a 32 MB crash dump, minutes on the
     SD card; TIMEPROMPTWAIT 0 lets the boot ROM's VMS boot (SW1) come up
     without a date: the board's TODR has no battery, and VMS takes the
     time it saved last.

A prompt it does not know stops the run with the prompt shown; the whole
console is in WORK/mkvms46.log. Needs python3 and SIMH's vax8600
(open-simh), in PATH or as $VAX8600. About 3 minutes.

Out: the disk (raw RP07, 516,096,000 bytes), to dd to the SD card from
sector 0. It boots with tools/vmscast.py --vmb as DRA0.
"""
import argparse
import gzip
import os
import pty
import re
import select
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import stabackit  # noqa: E402

DATE = lambda: time.strftime('%d-%b-%Y %H:%M').upper()
PROMPT = r'[\r\n]\$ '


class Sim:
    """SIMH on a pty: send keys, wait for patterns, everything to a log."""

    def __init__(self, sim, ini, log, cwd):
        m, s = pty.openpty()
        self.p = subprocess.Popen([sim, ini], stdin=s, stdout=s, stderr=s,
                                  cwd=cwd, close_fds=True)
        os.close(s)
        self.fd = m
        self.seen = ''
        self.log = open(log, 'a')
        self.last = time.time()
        self.closed = False

    def pump(self, t):
        end = time.time() + t
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], 0.05)
            if not r:
                continue
            try:
                d = os.read(self.fd, 4096)
            except OSError:          # SIMH has exited
                self.closed = True
                return
            s = d.decode('latin-1').replace('\0', '')
            self.log.write(s)
            self.log.flush()
            self.seen = (self.seen + s)[-100000:]
            self.last = time.time()

    def send(self, keys):
        for ch in keys.encode('latin-1'):
            os.write(self.fd, bytes([ch]))
            self.pump(0.02)

    def expect(self, pats, t=600):
        """Wait for one of the patterns; its index. Consumes the output."""
        if isinstance(pats, str):
            pats = [pats]
        end = time.time() + t
        while time.time() < end and not self.closed:
            for i, p in enumerate(pats):
                m = re.search(p, self.seen)
                if m:
                    self.seen = self.seen[m.end():]
                    self.pump(0.3)
                    return i
            self.pump(0.1)
        self.fail('SIMH exited' if self.closed else
                  'waited %d s for %r' % (t, pats))

    def tail(self, n=300):
        return self.seen[-n:]

    def fail(self, why):
        print('\nmkvms46: %s; the console ends with:\n%s' % (why, self.tail(600)),
              file=sys.stderr)
        self.kill()
        raise SystemExit(1)

    def kill(self):
        try:
            self.p.kill()    # SIMH ignores SIGTERM
            self.p.wait(5)
        except Exception:
            pass


def step(msg):
    print('[%s] %s' % (time.strftime('%H:%M:%S'), msg), flush=True)


def login(s, user, pw, t=900):
    """Boot to the end of STARTUP (the date if asked), then log in. Only
    after "job terminated": with OpenVMS 7.3 the audit server's message
    during STARTUP has a "Username:" too."""
    while s.expect([r'job terminated', r'(?i)enter (the )?date and time',
                    r'HALT instruction'], t) != 0:
        if 'HALT' in s.tail(400):
            s.fail('the processor halted')
        s.send(DATE() + '\r')
    s.pump(2)
    s.send('\r')
    s.expect(r'Username: $', 60)
    s.send(user + '\r')
    s.expect(r'Password: $', 60)
    s.send(pw + '\r')
    if s.expect([PROMPT, r'(?i)user authorization failure|invalid'], 120) == 1:
        s.fail('login as %s failed' % user)


def dcl(s, cmd, t=600):
    s.send(cmd + '\r')
    s.expect(PROMPT, t)


def shutdown(s):
    """@sys$system:shutdown with the defaults, to SYSTEM SHUTDOWN COMPLETE."""
    s.send('@sys$system:shutdown\r')
    s.expect(r'How many minutes', 120)
    s.send('0\r')
    s.expect(r'Reason for shutdown', 60)
    s.send('mkvms46\r')
    end = time.time() + 900
    while not re.search(r'(?i)system shutdown complete', s.seen):
        if time.time() > end:
            s.fail('no SYSTEM SHUTDOWN COMPLETE')
        s.pump(1)
        t = s.seen[-200:].rstrip(' ')
        if time.time() - s.last > 1.5 and re.search(r'(\]:|\]\?|\?)$', t):
            s.seen += '\n'
            s.send('\r')
    s.pump(3)


def no_dump(s):
    """From the next boot on: no crash dump at shutdown (DUMPBUG 0), and
    no date asked for when the TODR is not valid (TIMEPROMPTWAIT 0)."""
    s.send('run sys$system:sysgen\r')
    s.expect(r'SYSGEN> ', 60)
    for c in ('use current', 'set dumpbug 0', 'set timepromptwait 0',
              'write current'):
        s.send(c + '\r')
        s.expect(r'SYSGEN> ', 60)
    s.send('exit\r')
    s.expect(PROMPT, 60)
    for c in ('open/append m sys$system:modparams.dat', 'write m "DUMPBUG=0"',
              'write m "TIMEPROMPTWAIT=0"', 'close m'):
        dcl(s, c)


def helper_restore(s, user):
    """Boot the helper VMS from rp0 and restore REQUIRED to DRA1."""
    s.send('boot rp0\r')
    login(s, user, os.environ['HELPER_PASSWORD'])
    for c in ('mount/foreign mta0:', 'mount/foreign dra1:'):
        dcl(s, c)
    s.send('backup/image/verify mta0:required/save_set/rewind dra1:\r')
    s.expect(PROMPT, 1800)
    if re.search(r'%BACKUP-F-|%BACKUP-E-(?!NOBADDATA)', s.log_text()):
        s.fail('BACKUP failed')
    for c in ('dismount dra1:', 'dismount/nounload mta0:'):
        dcl(s, c)
    shutdown(s)
    to_simh(s)


def standalone_restore(s):
    """Boot standalone BACKUP from rp0 and restore REQUIRED to DRA1.
    Standalone VMS keeps SIMH from seeing ^E, so an EXPECT rule stops
    SIMH when BACKUP is done and asks whether to do another."""
    s.send("expect 'Enter \"YES\" to continue: '\r")
    s.expect(r'sim> $', 30)
    s.send('boot rp0/R5:1\r')                 # SYSBOOT's prompt
    s.expect(r'SYSBOOT> *$', 120)
    for c in stabackit.PARAMS:
        s.send(c + '\r')
        s.expect(r'SYSBOOT> *$', 30)
    s.send('continue\r')
    s.expect(r'Stand-alone BACKUP', 300)
    s.expect(PROMPT, 60)
    s.send('backup/image/verify mta0:required/save_set/rewind dra1:\r')
    s.expect(r'Enter "YES" to continue: sim> $', 1800)
    if re.search(r'%BACKUP-F-|%BACKUP-E-(?!NOBADDATA)', s.log_text()):
        s.fail('BACKUP failed')


def to_simh(s):
    """Back to sim> (the shut down VMS loops, or SIMH stopped on it)."""
    if not re.search(r'sim> $', s.seen):
        s.send('\x05')
    s.expect(r'sim> ', 60)


INSTALL = [   # VAX/VMS V4.6 install, after boot rp1
    (r'(?i)enter the date and time.*: $', lambda: DATE()),
    (r'(?i)drive holding distribution kit.*: $', lambda: 'MTA0'),
    (r'(?i)more about cluster system disks.*\? $', lambda: 'N'),
    (r'(?i)generate a cluster common system disk.*\? $', lambda: 'N'),
    (r'(?i)(new password for account|password for account \w+ for verification).*: $',
     lambda: os.environ['VMS_PASSWORD']),
]


def install(s):
    """Answer the install's questions until AUTOGEN reboots the system."""
    end = time.time() + 3600
    while True:
        if time.time() > end:
            s.fail('the install took more than an hour')
        s.pump(0.5)
        if re.search(r'job terminated', s.seen) and re.search(r'AUTOGEN', s.log_text()):
            return
        if re.search(r'HALT instruction|sim> $', s.seen):
            s.fail('the processor halted')
        if time.time() - s.last < 3:
            continue
        t = s.seen[-300:]
        for pat, ans in INSTALL:
            if re.search(pat, t):
                a = ans()
                step('  %s -> %s' % (re.sub(r'\s+', ' ', t.strip().splitlines()[-1])[:60],
                                     '***' if 'password' in pat else a))
                s.seen = ''
                s.send(a + '\r')
                break
        else:
            if re.search(r'(:|\?|\]) ?$', t.rstrip('\r\n')) and time.time() - s.last > 20:
                s.fail('a question this script does not know')


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--tape', required=True, help='BB-BT05D-BE, .tap or .tap.gz')
    ap.add_argument('--helper',
                    help='an RP07 image with a VMS that has BACKUP (copied); '
                    'without it a standalone BACKUP made from the tape')
    ap.add_argument('--helper-user', default='SYSTEM')
    ap.add_argument('--work', default='vms46-work')
    ap.add_argument('-o', '--output', default='vms46-rp07.dsk')
    a = ap.parse_args()
    for v in ('HELPER_PASSWORD', 'VMS_PASSWORD') if a.helper else ('VMS_PASSWORD',):
        if not os.environ.get(v):
            sys.exit('mkvms46: set $%s' % v)
    sim = os.environ.get('VAX8600') or shutil.which('vax8600') or \
        os.path.expanduser('~/build/open-simh/BIN/vax8600')
    if not os.access(sim, os.X_OK):
        sys.exit('mkvms46: no SIMH vax8600 (set VAX8600)')

    work = os.path.abspath(a.work)
    os.makedirs(work, exist_ok=True)
    tape = os.path.join(work, 'vms046.tap')
    if a.tape.endswith('.gz'):
        step('unpack the tape')
        with gzip.open(a.tape) as f, open(tape, 'wb') as g:
            shutil.copyfileobj(f, g)
    else:
        shutil.copyfile(a.tape, tape)
    if a.helper:
        step('copy the helper disk')
        shutil.copyfile(a.helper, os.path.join(work, 'helper.dsk'))
    else:
        step('build the standalone BACKUP disk from the tape')
        stabackit.find_ods2()
        stabackit.build(tape, os.path.join(work, 'helper.dsk'), work)
    out = os.path.join(work, 'vms46-rp07.dsk')
    if os.path.exists(out):
        os.remove(out)
    with open(out, 'wb') as f:      # a new RP07, all zero
        f.truncate(516096000)
    with open(os.path.join(work, 'mkvms46.ini'), 'w') as f:
        f.write('set cpu 32m\nset rp0 rp07\nset rp1 rp07\n'
                'attach rp0 helper.dsk\nattach rp1 vms46-rp07.dsk\n'
                'set tu enabled\nattach -r tu0 vms046.tap\n'
                'set rq dis\nset tq dis\nset ts dis\nset rl dis\nset ry dis\n'
                'set cr dis\nset lpt dis\n')
    log = os.path.join(work, 'mkvms46.log')
    open(log, 'w').close()
    s = Sim(sim, 'mkvms46.ini', log, work)
    s.log_text = lambda: open(log, encoding='latin-1').read()[-20000:]
    try:
        if s.expect([r'sim> ', r'Overwrite last track\? \[N\]'], 60) == 1:
            s.send('N\r')
            s.expect(r'sim> ', 60)

        if not a.helper:
            step('1. boot standalone BACKUP, restore REQUIRED to the new disk')
            standalone_restore(s)
        else:
            step('1. boot the helper, restore REQUIRED to the new disk')
            helper_restore(s, a.helper_user)

        step('2. boot the new disk: the VAX/VMS V4.6 install')
        s.seen = ''
        s.send('boot rp1\r')
        install(s)

        step('3. log in, DUMPBUG and TIMEPROMPTWAIT 0, show system, shut down')
        s.seen = ''
        s.pump(2)
        s.send('\r')
        s.expect(r'Username: $', 60)
        s.send('SYSTEM\r')
        s.expect(r'Password: $', 60)
        s.send(os.environ['VMS_PASSWORD'] + '\r')
        s.expect(PROMPT, 120)
        no_dump(s)
        dcl(s, 'show system')
        shutdown(s)
        to_simh(s)
        s.send('quit\r')
        s.pump(3)
        if not s.closed:
            s.fail('SIMH did not quit')
    finally:
        s.kill()
    os.replace(out, os.path.abspath(a.output))
    os.remove(os.path.join(work, 'helper.dsk'))
    step('done: %s' % a.output)


if __name__ == '__main__':
    main()
