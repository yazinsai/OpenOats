#!/usr/bin/env python3
"""Check deployment metadata and optionally the packaged executable's min OS."""
import plistlib
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent


def version(value):
    return tuple(int(part) for part in value.split('.'))


def check(app=None):
    with (ROOT / 'OpenOats/Sources/OpenOats/Info.plist').open('rb') as file:
        minimum = plistlib.load(file)['LSMinimumSystemVersion']
    manifest = (ROOT / 'OpenOats/Package.swift').read_text()
    assert f'.macOS("{minimum}")' in manifest, 'SwiftPM and app minimum OS differ'
    with (ROOT / 'UITests/OpenOatsUITestHost/Info.plist').open('rb') as file:
        assert plistlib.load(file)['LSMinimumSystemVersion'] == minimum, 'UI host minimum OS differs'
    project = (ROOT / 'UITests/OpenOatsUITestHost.xcodeproj/project.pbxproj').read_text()
    targets = re.findall(r'MACOSX_DEPLOYMENT_TARGET = ([\d.]+);', project)
    assert targets and all(target == minimum for target in targets), 'Xcode targets differ'
    if app is not None:
        app = Path(app)
        with (app / 'Contents/Info.plist').open('rb') as file:
            assert plistlib.load(file)['LSMinimumSystemVersion'] == minimum, 'Built bundle differs'
        binary = app / 'Contents/MacOS/OpenOats'
        output = subprocess.check_output(['otool', '-l', str(binary)], text=True)
        binary_minima = re.findall(r'\bminos ([\d.]+)', output)
        assert binary_minima, 'Executable has no LC_BUILD_VERSION minimum OS'
        assert all(version(item) <= version(minimum) for item in binary_minima), (
            f'Executable requires {binary_minima}, bundle advertises {minimum}'
        )
    print(f'macOS deployment metadata verified: {minimum}+')


if __name__ == '__main__':
    check(sys.argv[1] if len(sys.argv) > 1 else None)
