#!/usr/bin/env python3
"""Package an Xcode device archive for local re-signing; never sign or upload."""
from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
from pathlib import Path
import struct
import zipfile


def device_macho(data: bytes) -> None:
    """Accept an arm64 iOS device executable, and reject simulator binaries."""
    if len(data) < 32 or data[:4] != b'\xcf\xfa\xed\xfe':
        raise ValueError('Expected a thin 64-bit Mach-O device executable')
    _, cpu, _, _, commands, size, _, _ = struct.unpack_from('<8I', data)
    if cpu != 0x0100000C:
        raise ValueError('Expected arm64, not an Intel simulator executable')
    end = 32 + size
    if end > len(data):
        raise ValueError('Truncated Mach-O load commands')
    platforms = []
    offset = 32
    for _ in range(commands):
        if offset + 8 > end:
            raise ValueError('Truncated Mach-O load command')
        command, length = struct.unpack_from('<II', data, offset)
        if length < 8 or offset + length > end:
            raise ValueError('Invalid Mach-O load command size')
        if command == 0x32:
            if length < 24:
                raise ValueError('Truncated LC_BUILD_VERSION')
            platforms.append(struct.unpack_from('<I', data, offset + 8)[0])
        elif command == 0x25:
            platforms.append(2)  # LC_VERSION_MIN_IPHONEOS, arm64 device.
        offset += length
    if offset != end or platforms != [2]:
        raise ValueError(f'Expected iOS device platform 2, found {platforms}')


def package(archive: Path, output: Path, version: str) -> dict:
    app = archive / 'Products' / 'Applications' / 'EternalMonitor.app'
    if not app.is_dir():
        raise ValueError('Device archive has no EternalMonitor.app')
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    if info.get('CFBundleShortVersionString') != version:
        raise ValueError('App version does not match the selected Windows release')
    if info.get('CFBundleSupportedPlatforms') != ['iPhoneOS'] or 2 not in info.get('UIDeviceFamily', []):
        raise ValueError('Archive is not an iPad device build')
    executable = str(info.get('CFBundleExecutable', ''))
    if not executable or Path(executable).name != executable:
        raise ValueError('Invalid app executable name')
    device_macho((app / executable).read_bytes())
    if not (app / 'PrivacyInfo.xcprivacy').is_file():
        raise ValueError('Archive is missing its privacy manifest')
    files = sorted(item for item in app.rglob('*') if item.is_file())
    for item in files:
        if item.is_symlink():
            raise ValueError('Unexpected symbolic link in the iOS app bundle')
        if item.name == 'embedded.mobileprovision' or '_CodeSignature' in item.relative_to(app).parts:
            raise ValueError('Archive contains signing material; build with CODE_SIGNING_ALLOWED=NO')
        if item.suffix == '.dylib':
            device_macho(item.read_bytes())
        if item.name == 'Info.plist' and item.parent.suffix == '.framework':
            framework = plistlib.loads(item.read_bytes())
            device_macho((item.parent / framework['CFBundleExecutable']).read_bytes())
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix('.ipa.partial')
    with zipfile.ZipFile(temporary, 'w', compression=zipfile.ZIP_DEFLATED) as bundle:
        for item in files:
            entry = zipfile.ZipInfo.from_file(item, 'Payload/EternalMonitor.app/' + item.relative_to(app).as_posix())
            entry.compress_type = zipfile.ZIP_DEFLATED
            bundle.writestr(entry, item.read_bytes())
    with zipfile.ZipFile(temporary) as bundle:
        if bundle.testzip() is not None:
            raise ValueError('IPA ZIP integrity check failed')
        device_macho(bundle.read('Payload/EternalMonitor.app/' + executable))
    temporary.replace(output)
    return {
        'version': version, 'build': str(info['CFBundleVersion']),
        'bundle_id': info['CFBundleIdentifier'], 'platform': 'iOS device arm64',
        'signing': 'unsigned; requires your local certificate and provisioning profile',
        'files': len(files), 'bytes': output.stat().st_size,
        'sha256': hashlib.sha256(output.read_bytes()).hexdigest(),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--version', default='0.3.0')
    args = parser.parse_args()
    result = package(args.archive, args.output, args.version)
    args.output.with_suffix('.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf8')
    print(json.dumps(result))


if __name__ == '__main__':
    main()
