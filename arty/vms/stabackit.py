#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 Akio Itoh
"""stabackit.py - a standalone BACKUP disk for VAX/VMS V4.6, made on the
host from the distribution tape, with no VMS running.

    stabackit.py --tape vms046.tap [-o stabackup-rp07.dsk] [--work DIR]
    stabackit.py --tape vms046.tap --list REQUIRED

VMS builds this kit with SYS$UPDATE:STABACKIT.COM on a running system.
For a large disk the kit is only files in [SYS0.SYSEXE] (STABACKIT's
STA2$BUILD_LARGE_DISK): SYSBOOT, SYS.EXE, VMB, the drivers and the
CPU-specific SYSLOAxxx, STASYSGEN.EXE as SYSINIT.EXE, STABACKUP.EXE as
STANDALON.EXE, and a VAXVMSSYS.PAR. This script reads them out of the
tape's REQUIRED and LIBRARY save sets and writes them to a new Files-11
RP07 with ods2 (open-simh/simtools, extracters/ods2; $ODS2 or in PATH).

VMB finds SYSBOOT through the directory, so the disk needs no boot block.
The parameter file is the tape's own (the install's defaults): with it
standalone BACKUP stops with %BACKUP-F-CANTLOCK, so boot it
conversationally (R5 = 1) and give SYSBOOT the SET commands of PARAMS,
the values STABACKIT.COM writes. mkvms46.py does that.
"""
import argparse
import os
import shutil
import struct
import subprocess
import sys
import tempfile

# STABACKIT.COM V4.6, STA2$BUILD_LARGE_DISK: the files it copies when
# they exist (and every SYSLOAxxx.EXE), and the two it renames
KIT = '''SYSBOOT.EXE VMB.EXE SYS.EXE SCSLOA.EXE STANDCONF.EXE TTDRIVER.EXE
FPEMUL.EXE VAXEMUL.EXE CVDRIVER.EXE DBDRIVER.EXE DDDRIVER.EXE DLDRIVER.EXE
DMDRIVER.EXE DQDRIVER.EXE DRDRIVER.EXE DUDRIVER.EXE DVDRIVER.EXE
DYDRIVER.EXE LCDRIVER.EXE LIDRIVER.EXE LPDRIVER.EXE PADRIVER.EXE
PUDRIVER.EXE PBDRIVER.EXE TFDRIVER.EXE TMDRIVER.EXE TSDRIVER.EXE
TUDRIVER.EXE TVDRIVER.EXE VAXVMSSYS.PAR'''.split()
RENAME = {'STASYSGEN.EXE': 'SYSINIT.EXE', 'STABACKUP.EXE': 'STANDALON.EXE'}

# STABACKIT.COM's SYSGEN parameters for standalone VMS, as SYSBOOT commands
PARAMS = '''USE DEFAULT
SET BALSETCNT 4
SET BUGREBOOT 0
SET CJFLOAD 0
SET DUMPBUG 1
SET FREELIM 16
SET GBLPAGES 512
SET GBLPAGFIL 128
SET GBLSECTIONS 20
SET INTSTKPAGES 6
SET IRPCOUNT 64
SET IRPCOUNTV 512
SET KFILSTCNT 2
SET LNMPHASHTBL 1
SET LNMSHASHTBL 1
SET LOCKIDTBL 40
SET LOCKIDTBL_MAX 200
SET LRPCOUNT 10
SET LRPCOUNTV 32
SET MAXPROCESSCNT 12
SET MPW_HILIM 8192
SET MPW_LOLIMIT 0
SET MPW_WAITLIM 8192
SET NPAGEDYN 196000
SET NPAGEVIR 512000
SET PAGFILCNT 1
SET PAGEDYN 20480
SET PFCDEFAULT 2
SET PHYSICALPAGES 8192
SET POOLPAGING 0
SET PQL_DASTLM 12
SET PQL_DDIOLM 12
SET PQL_DPGFLQUOTA 4096
SET PQL_DWSDEFAULT 2048
SET PQL_DWSEXTENT 2048
SET PQL_DWSQUOTA 2048
SET RESHASHTBL 10
SET SCSNODE "SABKUP"
SET SCSSYSTEMID 65535
SET SPTREQ 2048
SET SRPCOUNT 24
SET SRPCOUNTV 512
SET SWPFILCNT 0
SET SYSPAGING 0
SET VAXCLUSTER 0
SET VIRTUALPAGECNT 6144
SET WSMAX 2048'''.splitlines()

RP07_BYTES = 516096000


def tape_savesets(path):
    """The ANSI-labelled files of a SIMH tape image: {name: [blocks]}."""
    sets = {}
    name = None
    with open(path, 'rb') as f:
        while True:
            h = f.read(4)
            if len(h) < 4:
                break
            n = struct.unpack('<I', h)[0]
            if n == 0xffffffff:
                break
            if n == 0:                       # tape mark
                continue
            rec = f.read(n)
            f.read(4 + (n & 1))              # trailing length, pad
            if n == 80 and rec[:4] == b'HDR1':
                name = rec[4:21].decode('ascii').strip().rstrip('.')
                sets[name] = []
            elif n == 80 and rec[:4] in (b'HDR2', b'EOF1', b'EOF2', b'VOL1'):
                continue
            elif name is not None:
                sets[name].append(rec)
    return sets


def saveset_files(blocks):
    """The files of a BACKUP save set: [(name, contents)]. A block is a
    256-byte header (BBH) and records, each a 16-byte header (BRH: size,
    type, flags, address) and data: type 3 starts a file and holds its
    attributes (the name is attribute 0x2A), type 4 holds data from
    virtual block 'address' on."""
    out = []
    cur = None
    for b in blocks:
        p = struct.unpack_from('<H', b, 0)[0]
        while p + 16 <= len(b):
            size, rtype, _, addr = struct.unpack_from('<HHII', b, p)
            data = b[p + 16:p + 16 + size]
            p += 16 + size
            if rtype == 3:
                if cur:
                    out.append(cur)
                attrs = {}
                q = 2                         # after the structure level
                while q + 4 <= len(data):
                    asize, atype = struct.unpack_from('<HH', data, q)
                    if asize == 0 and atype == 0:
                        break
                    attrs[atype] = data[q + 4:q + 4 + asize]
                    q += 4 + asize
                cur = [attrs.get(0x2A, b'?').decode('latin-1'), {}]
            elif rtype == 4 and cur:
                cur[1][addr] = data
            elif rtype == 0 and size == 0:
                break
    if cur:
        out.append(cur)
    files = []
    for name, vbns in out:
        body = bytearray()
        for vbn in sorted(vbns):
            off = (vbn - 1) * 512
            if len(body) < off:
                body += bytes(off - len(body))
            body[off:off + len(vbns[vbn])] = vbns[vbn]
        files.append((name, bytes(body)))
    return files


def leaf(name):
    """[SYS0.SYSEXE]SYS.EXE;1 -> SYS.EXE"""
    return name.split(']')[-1].split(';')[0].upper()


def find_ods2():
    for p in (os.environ.get('ODS2'), shutil.which('ods2'),
              os.path.expanduser('~/build/simtools/extracters/ods2/ods2')):
        if p and os.access(p, os.X_OK):
            return p
    sys.exit('stabackit: no ods2 (build open-simh/simtools extracters/ods2, '
             'set $ODS2)')


def build(tape, out, work=None):
    """Write the standalone BACKUP RP07 image to 'out'."""
    ods2 = find_ods2()
    sets = tape_savesets(tape)
    want = set(KIT) | set(RENAME)
    got = {}
    for ss in ('REQUIRED', 'LIBRARY'):
        for name, body in saveset_files(sets.get(ss, [])):
            n = leaf(name)
            if '[SYS0.SYSEXE]' in name.upper() and \
                    (n in want or n.startswith('SYSLOA')):
                got[RENAME.get(n, n)] = body
    for need in ('SYSBOOT.EXE', 'SYS.EXE', 'SYSINIT.EXE', 'STANDALON.EXE',
                 'VAXVMSSYS.PAR', 'DRDRIVER.EXE', 'SYSLOA790.EXE'):
        if need not in got:
            sys.exit('stabackit: %s is not on the tape' % need)
    d = tempfile.mkdtemp(prefix='stabackit-', dir=work)
    try:
        # ods2 takes '/' for a qualifier: plain names, run in the directory
        for n, body in got.items():
            with open(os.path.join(d, n), 'wb') as f:
                f.write(body)
        cmds = ['initialize /image /medium_type=RP07 /noconfirm '
                '/index=beginning sa.dsk STANDBACKUP',
                'create /directory [SYS0.SYSEXE]']
        cmds += ['copy /to_files-11 /binary /record_format=fixed=512 %s '
                 '[SYS0.SYSEXE]%s' % (n, n) for n in sorted(got)]
        cmds += ['dismount A:', 'exit']
        r = subprocess.run([ods2], input='\n'.join(cmds) + '\n', cwd=d,
                           capture_output=True, text=True)
        log = r.stdout + r.stderr
        if log.count('%COPY-I-COPIED, 1 file') != len(got) or \
                '-E-' in log or '-F-' in log:
            sys.exit('stabackit: ods2 failed:\n' + log[-2000:])
        with open(os.path.join(d, 'sa.dsk'), 'ab') as f:   # a full RP07
            f.truncate(RP07_BYTES)
        shutil.move(os.path.join(d, 'sa.dsk'), out)
    finally:
        shutil.rmtree(d, ignore_errors=True)
    return sorted(got)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--tape', required=True, help='BB-BT05D-BE, .tap')
    ap.add_argument('-o', '--output', default='stabackup-rp07.dsk')
    ap.add_argument('--work', default=None)
    ap.add_argument('--list', metavar='SAVESET', help='list a save set')
    a = ap.parse_args()
    if a.list:
        for name, body in saveset_files(tape_savesets(a.tape)[a.list]):
            print('%-48s %8d' % (name, len(body)))
        return
    files = build(a.tape, a.output, a.work)
    print('%s: %d files in [SYS0.SYSEXE]' % (a.output, len(files)))


if __name__ == '__main__':
    main()
