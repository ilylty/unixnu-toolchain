#!/usr/bin/env python3
"""Derive the release tag for a UniXNU Linux toolchain build.

    toolchain-tag.py --unixnu UniXNU [--extra KEY=VALUE ...]

Prints a tag of the form

    tc-24.04-<16 hex>

where the hex is a digest over everything that changes the bytes of the
installed prefix:

  * the content of UniXNU/scripts/linux (the installer, its six upstream refs
    and the shims it installs)
  * the upstream refs pinned inside setup-toolchain.py, re-read from the file
    so a bump there changes the tag even if nothing else does
  * the host LLVM version, because llvm-config selects the libclang that iig
    links against and the clang that builds the LLVM source tree
  * the Ubuntu release, because the resulting binaries link the runner's glibc

Chromium names its prebuilt clang packages the same way in spirit
(`llvmorg-24-init-14453-ge063be79-1`, where the trailing `-1` is a manual
sub-revision counter bumped whenever the build changes). A content digest is
used here instead of a hand-maintained counter so a forgotten bump cannot
silently serve a stale toolchain under an unchanged tag.
"""
import argparse
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys

REF_PATTERN = re.compile(r'^(LLVM_COMMIT|CCTOOLS_PORT_REF|LIBDISPATCH_REF|BOOTSTRAP_CMDS_TAG|IIG_PORT_COMMIT|LZFSE_COMMIT)\s*=\s*[\'"]([^\'"]+)[\'"]', re.M)


def tree_digest(root: Path) -> tuple[str, list[tuple[str, str]]]:
    """sha256 over every file's path and bytes under root, plus the per-file list."""
    entries = []
    for path in sorted(p for p in root.rglob('*') if p.is_file()):
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        entries.append((path.relative_to(root).as_posix(), digest))
    block = ''.join(f'{name}\0{digest}\n' for name, digest in entries)
    return hashlib.sha256(block.encode()).hexdigest(), entries


def pinned_refs(installer: Path) -> list[tuple[str, str]]:
    return REF_PATTERN.findall(installer.read_text(encoding='utf-8'))


def host_llvm(llvm_config: str | None) -> str:
    config = llvm_config or os.environ.get('LLVM_CONFIG')
    if not config:
        config = subprocess.run(['bash', '-lc', 'command -v llvm-config'],
                                capture_output=True, text=True).stdout.strip()
    if not config or not Path(config).exists():
        return 'unknown'
    version = subprocess.run([config, '--version'], capture_output=True, text=True).stdout.strip()
    return f'{version} at {config}'


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--unixnu', type=Path, default=Path('UniXNU'),
                        help='path to the UniXNU checkout')
    parser.add_argument('--llvm-config', default=None,
                        help='llvm-config that iig and the LLVM build use; or LLVM_CONFIG')
    parser.add_argument('--os-release', default=None,
                        help='override the Ubuntu release component of the tag')
    parser.add_argument('--verbose', '-v', action='store_true')
    args = parser.parse_args(argv)

    linux_dir = args.unixnu / 'scripts/linux'
    installer = linux_dir / 'setup-toolchain.py'
    if not installer.is_file():
        sys.exit(f'{installer} missing: is --unixnu pointing at a UniXNU checkout?')

    scripts_digest, entries = tree_digest(linux_dir)
    refs = pinned_refs(installer)
    llvm = host_llvm(args.llvm_config)
    os_release = args.os_release or f'{os_release_id()}-{os_release_version()}'

    material = [
        f'scripts_linux={scripts_digest}',
        f'os_release={os_release}',
        f'host_llvm={llvm}',
        *(f'{name}={value}' for name, value in refs),
    ]
    combined = hashlib.sha256('\n'.join(material).encode()).hexdigest()
    tag = f'tc-{os_release_version()}-{combined[:16]}'

    if args.verbose:
        print('files under scripts/linux:', file=sys.stderr)
        for name, digest in entries:
            print(f'  {digest[:12]}  {name}', file=sys.stderr)
        print('digest material:', file=sys.stderr)
        for line in material:
            print(f'  {line}', file=sys.stderr)
        print(file=sys.stderr)

    # Machine-readable for the workflow.
    print(tag)
    emit('scripts_hash', scripts_digest)
    emit('os_release', os_release)
    emit('host_llvm', llvm)
    for name, value in refs:
        emit(name.lower(), value)
    return 0


def os_release_id() -> str:
    return os_release_field('ID', 'unknown')


def os_release_version() -> str:
    return os_release_field('VERSION_ID', 'unknown')


def os_release_field(field: str, fallback: str) -> str:
    path = Path('/etc/os-release')
    if not path.is_file():
        return fallback
    for line in path.read_text(encoding='utf-8').splitlines():
        key, _, value = line.partition('=')
        if key == field:
            return value.strip().strip('"')
    return fallback


def emit(name: str, value: str) -> None:
    """Append to $GITHUB_OUTPUT when running under Actions."""
    target = os.environ.get('GITHUB_OUTPUT')
    if target:
        with open(target, 'a', encoding='utf-8') as fh:
            fh.write(f'{name}={value}\n')


if __name__ == '__main__':
    sys.exit(main())
