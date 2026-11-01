# UniXNU Linux toolchain

Prebuilt, published-once toolchain for building XNU and UniXNU kernel images on
glibc Linux. Removes the 1-2 hour `scripts/linux/setup-toolchain.py` run from
every consumer build.

## Why this exists

`UniXNU/UniXNU/scripts/linux/setup-toolchain.py` builds, from source:

| component | upstream | pin |
| --- | --- | --- |
| clang + resource headers | `llvm/llvm-project` | `58c46bae21181fb4240cf964461bea738d96d50e` + `llvm-xnu-builtin-type.patch` |
| `ld` `nm` `lipo` `libtool` `otool` | `tpoechtrager/cctools-port` | `1030.6.3-ld64-956.6` |
| libdispatch, BlocksRuntime | `swiftlang/swift-corelibs-libdispatch` | `swift-6.4.0-RELEASE` |
| `mig`, `migcom` | `apple-oss-distributions/bootstrap_cmds` | `bootstrap_cmds-138` |
| `iig` | `Nyktis/iig-port` | `ea6d147d…` |
| `lzfse` | `lzfse/lzfse` | `e634ca58…` |

The LLVM build dominates at roughly an hour. UniXNU's own Linux workflows put
the result in `actions/cache`, which is per-repository: `Asultop/UniXNU-NX769J`
and `ahzcpp/UniXNU-vermeer` each store ~53 MB under a different key, having each
compiled it once. `actions/cache` is also evicted after 7 days without access,
capped at 10 GB per repository, and not readable from a fork's PR. A release
asset has none of those limits.

## Using it

In a device repository's `.github/workflows/package.yml`, before the packaging
step. The device workflow itself is `templates/device-package.yml` from this
repository -- see `templates/README.md`.

```yaml
- uses: actions/checkout@v4
  with: { repository: ilylty/unixnu-toolchain, path: toolchain }

- name: Install the toolchain
  env:
    GH_TOKEN: ${{ github.token }}
    TOOLCHAIN_REPOSITORY: ilylty/unixnu-toolchain
  run: bash toolchain/scripts/fetch-toolchain.sh /opt/unixnu-linux

# scripts/unixnu/kernel.py checks /usr/bin/xcrun. The tarball cannot carry it,
# so let the (idempotent) installer place the three shims; already-built
# components are skipped, so this is seconds.
- name: Install the /usr/bin shims
  run: |
    sudo env UNIXNU_TOOLCHAIN=/opt/unixnu-linux \
      python3 UniXNU/scripts/linux/setup-toolchain.py /opt/unixnu-linux
    sudo chown -R "$(id -u):$(id -g)" /opt/unixnu-linux

- name: Verify
  run: bash toolchain/scripts/smoke-test.sh /opt/unixnu-linux
```

Then run the packaging script the way `docs/porting/packaging.md` requires --
one command, six fixed steps, everything else from `board.toml`:

```bash
scripts/package.sh --os "$PROFILE" --uefi ../uefi-firmware
```

That writes `out/<device>/<os_profile>/<config>/` with `boot/boot.img`,
`payload/payload.img`, `kernel/kernel.macho` and `package.manifest.json`.

To regenerate `toolchain.lock` after a new release:

```bash
scripts/fetch-toolchain.sh --print-lock > toolchain.lock
```

## Publishing a new toolchain

`Actions → Build Linux toolchain → Run workflow`.

The tag is derived, not chosen: `scripts/toolchain-tag.py` digests the content of
`UniXNU/scripts/linux`, the six upstream refs read out of
`setup-toolchain.py`, the host LLVM version and the Ubuntu release. A rerun with
unchanged inputs finds the existing release and does nothing; `force: true`
rebuilds and replaces it.

Chromium solves the same problem with a hand-bumped counter
(`clang-llvmorg-24-init-14453-ge063be79-1`). A content digest is used here
because a forgotten bump cannot then serve a stale toolchain under an unchanged
tag.

### What a prefix can and cannot be moved to

The archive is rooted at the prefix's basename, so unpacking into any parent
works:

```bash
tar -C "$HOME" --zstd -xf unixnu-linux-toolchain-*.tar.zst   # -> $HOME/unixnu-linux
export UNIXNU_TOOLCHAIN="$HOME/unixnu-linux"
```

Two things stay absolute because `setup-toolchain.py` expands them at install
time:

- `CommandLineTools/usr/bin/xnu-host-cc` bakes in the clang and include paths
- `/usr/bin/{xcrun,plutil,codesign}` are written unconditionally

Re-running the installer in the new location is idempotent — every already
built component is skipped — and repairs both.

## What is inside

```
<prefix>/
  llvm/bin/clang                      patched clang, AArch64 target only
  llvm/lib/clang/<v>/include/         resource headers
  CommandLineTools/usr/bin/           ld ld64 nm lipo libtool otool ar ranlib
                                      strip mig clang clang++ cc install gm4
                                      xnu-host-cc
  CommandLineTools/usr/libexec/migcom
  CommandLineTools/usr/lib/           libmacho.a libstuff.a libdispatch.so
  CommandLineTools/SDKs/MacOSX.sdk/usr/include/foreign/   Darwin headers
  XcodeDefault.xctoolchain/usr/bin/iig
  bin/lzfse
```

The installed tree is tens of megabytes because the build runs
`ninja install-clang install-clang-resource-headers`; libclang's static
libraries and the rest of LLVM are never installed.

## Caveats

- **Ubuntu 24.04 / x86_64 only.** The binaries link the runner's glibc.
- **`/usr/bin` must be writable.** Because of that, `fetch-toolchain.sh` cannot
  be a `sudo`-free operation end to end; the shim install is separate and
  documented above.
- **The build strips nothing.** Assertions are on
  (`-DLLVM_ENABLE_ASSERTIONS=ON`), matching what `setup-toolchain.py` produces.
- **No macOS path.** UniXNU's official `macos.yml` uses Xcode and does not need
  this toolchain.
- **This repository is not a device repository.** It holds no `board.toml` and
  no `scripts/package.sh`. The device side is a copy of
  `UniXNU/templates/package.sh` plus `templates/device-package.yml` from here.
  `docs/porting/packaging.md` rule 3 makes that split mandatory: a device
  changes `board.toml`, never the packaging script.
- **`pack` runs in CI, not locally.** `unixnu release` packs the boot image from
  the firmware volume, the device tree and the payload, and then `verify`s it
  against `package.manifest.json`. An earlier draft of this repository assumed
  the boot image would be assembled on the developer's machine; the packaging
  document makes it the fifth of six fixed steps.
