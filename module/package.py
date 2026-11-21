#!/usr/bin/env python3
"""Build the pandora AirDrop KernelSU module zip.

usage: python package.py --inputs DIR [--firmware PATH] [--out DIR] [--strict]

DIR holds the built binaries under these names:
  qca_cld3_peach_v2.ko  wonder.ko  pandora_wonder_bridge.ko  pandora_mhi_fw.ko
  owly-xosd  wonder-init  xos-bridge.zip  Pandora-XOS-Compat.apk
Without --firmware the zip carries no Samsung firmware (the form that may be redistributed); the installer then
looks for the user's own copy on the phone. Each input is compared with the SHA-256 of the build verified on a
Xiaomi 17 / 17 Pro on 2026-11-21; a mismatch is a warning, or an error with --strict.
"""
import argparse
import hashlib
import re
import sys
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIXED_TIME = (2026, 11, 19, 0, 0, 0)
FW_REL = 'firmware/s26u-amss20.bin'
FW_SHA = '71fc5c2eb2df048b6c4b494564cfbef730db879a3d8b4426c31ad23b5d448860'

# payload path -> SHA-256 of the build tested on the phone
BINARIES = {
    'qca_cld3_peach_v2.ko': 'efb43ed8364d1c5b683baf84f7207561525114e1b7628ea763041eaa7b040173',
    'wonder.ko': 'f80f6d8ae9da4df1db3cdc995a283da01d83d09d459c6d3823da25df88bb65ac',
    'pandora_wonder_bridge.ko': '44fc8cc3aa8677503272abc48757299c5d29e6fd9fd5fad0f480fa21e582cd48',
    'pandora_mhi_fw.ko': '02484b332148f09241f02a2f4158075572941d6d3c9065308a3be627a53d698c',
    'owly-xosd': '9da5afa0ef3fa717cb66b4e9d9663c7cdddba61cbd5ca79678e9f839edbbc4f8',
    'wonder-init': '29d9d71fbdd5e0333e41377c1e5128c6c8cb888cbdc0563029a39cdf44a1cbf7',
    'xos-bridge.zip': 'ccc264c972decaeffac4bf6ff207a5209f58ee0c74fb7a212d7ddd3a343e015e',
}
APK = ('Pandora-XOS-Compat.apk', '48121eed5dc761b817c57352e37fb9232d62a2d45363d88a3b1e7bd7efd3f2c8')
# shell scripts that radio.sh's installation.sha256 covers, taken from the runtime source dir
RUNTIME_SCRIPTS = ['radio.sh', 'bridge-supervisor.sh']
MODULE_SCRIPTS = ['customize.sh', 'service.sh', 'action.sh', 'uninstall.sh', 'common.sh']
MODULE_TEXT = ['module.prop', 'README.txt', 'META-INF/com/google/android/updater-script']
UPDATE_BINARY = 'META-INF/com/google/android/update-binary'
EXEC = {'radio.sh', 'bridge-supervisor.sh', 'owly-xosd', 'wonder-init'}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def lf(data):
    return data.replace(b'\r\n', b'\n')


def add(zf, name, data, mode):
    info = zipfile.ZipInfo(name, date_time=FIXED_TIME)
    info.external_attr = (0o100000 | mode) << 16
    info.compress_type = zipfile.ZIP_DEFLATED
    zf.writestr(info, data)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--inputs', required=True, type=Path)
    ap.add_argument('--runtime', type=Path, default=HERE.parent / 'runtime', help='dir with radio.sh, bridge-supervisor.sh')
    ap.add_argument('--firmware', type=Path, help='Samsung S26U amss20.bin to bundle (private builds only)')
    ap.add_argument('--out', type=Path, default=HERE.parent / 'dist')
    ap.add_argument('--strict', action='store_true', help='fail when an input differs from the tested build')
    a = ap.parse_args()

    def check(name, data, want):
        got = sha(data)
        if got != want:
            msg = f'{name}: sha256 {got} differs from the tested build {want}'
            if a.strict:
                sys.exit(msg)
            print('warning:', msg)

    payload = {}
    for s in RUNTIME_SCRIPTS:
        payload[s] = lf((a.runtime / s).read_bytes())
    if b'R=/data/local/tmp/xos/owly' not in payload['radio.sh']:
        sys.exit('radio.sh: runtime path is not /data/local/tmp/xos/owly')
    for name, want in BINARIES.items():
        data = (a.inputs / name).read_bytes()
        check(name, data, want)
        payload[name] = data
    apk = (a.inputs / APK[0]).read_bytes()
    check(APK[0], apk, APK[1])
    fw = None
    if a.firmware:
        fw = a.firmware.read_bytes()
        if sha(fw) != FW_SHA:
            sys.exit(f'{a.firmware}: not the expected S948BXXS6BZK1 amss20.bin ({FW_SHA})')

    # radio.sh checks every listed file, the firmware included, so its line is always present.
    manifest = ''.join(f'{sha(d)}  {k}\n' for k, d in payload.items()) + f'{FW_SHA}  {FW_REL}\n'
    prop = (HERE / 'module.prop').read_text(encoding='utf-8')
    version = re.search(r'^version=(\S+)', prop, re.M).group(1)
    a.out.mkdir(parents=True, exist_ok=True)
    zpath = a.out / f'pandora-airdrop-{version}{"-with-firmware" if fw else ""}.zip'
    with zipfile.ZipFile(zpath, 'w') as zf:
        add(zf, UPDATE_BINARY, lf((HERE / UPDATE_BINARY).read_bytes()), 0o755)
        for t in MODULE_TEXT:
            add(zf, t, lf((HERE / t).read_bytes()), 0o644)
        for s in MODULE_SCRIPTS:
            add(zf, s, lf((HERE / s).read_bytes()), 0o755)
        for k, data in payload.items():
            add(zf, f'payload/{k}', data, 0o755 if k in EXEC else 0o644)
        if fw:
            add(zf, f'payload/{FW_REL}', fw, 0o644)
        add(zf, 'payload/installation.sha256', manifest.encode(), 0o644)
        add(zf, f'apks/{APK[0]}', apk, 0o644)
        add(zf, 'apks/APKS.sha256', f'{sha(apk)}  {APK[0]}\n'.encode(), 0o644)
    print(zpath)
    print(manifest, end='')
    print('zip sha256', sha(zpath.read_bytes()), zpath.stat().st_size, 'bytes')


if __name__ == '__main__':
    main()
