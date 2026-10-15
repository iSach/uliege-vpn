#!/usr/bin/env python3
"""Check actual Mach-O requirements, including bundled Python/SSL/Node libraries."""
import argparse
import json
import platform
from pathlib import Path

from macholib.MachO import MachO
from macholib.mach_o import LC_BUILD_VERSION, LC_VERSION_MIN_MACOSX


def version_tuple(value):
    return value >> 16, (value >> 8) & 255, value & 255


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('bundle', type=Path)
    parser.add_argument('--maximum', default='13.5')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    maximum = tuple(map(int, args.maximum.split('.')))
    maximum += (0,) * (3 - len(maximum))
    requirements = []
    magic_values = {bytes.fromhex(value) for value in (
        'cffaedfe', 'cefaedfe', 'feedfacf', 'feedface', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}
    for path in args.bundle.rglob('*'):
        if not path.is_file() or path.is_symlink():
            continue
        with path.open('rb') as stream:
            if stream.read(4) not in magic_values:
                continue
        for header in MachO(str(path)).headers:
            for load, command, _ in header.commands:
                encoded = (command.minos if load.cmd == LC_BUILD_VERSION
                           else command.version if load.cmd == LC_VERSION_MIN_MACOSX else None)
                if encoded:
                    requirements.append((version_tuple(encoded), str(path.relative_to(args.bundle))))
    if not requirements:
        raise SystemExit('No Mach-O runtime files found')
    incompatible = [(version, path) for version, path in requirements if version > maximum]
    if incompatible:
        for version, path in sorted(incompatible, reverse=True):
            print(f'{path} requires macOS {".".join(map(str, version))}')
        raise SystemExit('Bundled runtime exceeds declared macOS support. Select a compatible build Python using PYTHON=...')
    args.output.write_text(json.dumps({
        'python': platform.python_version(), 'architecture': platform.machine(),
        'declared_minimum_macos': args.maximum,
        'highest_library_minimum': '.'.join(map(str, max(version for version, _ in requirements))),
        'checked_macho_slices': len(requirements),
    }, indent=2) + '\n')
    print(f'Checked {len(requirements)} Mach-O slices: all support macOS {args.maximum}')


if __name__ == '__main__':
    main()
