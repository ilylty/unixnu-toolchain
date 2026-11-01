# Templates for the device repository

`docs/porting/packaging.md` fixes how a device builds: one command,
`scripts/package.sh`, which runs the six steps of `unixnu release` and writes
`boot.img`, `payload.img`, `kernel.macho` and `package.manifest.json`.

These two files are what a device repository needs so that the packaging script
can run on a Linux runner with a prebuilt toolchain instead of a macOS runner
with Xcode. They belong in the **device** repository, not here.

## `device-scripts-package.sh` → `<device>/scripts/package.sh`

Do not copy this file. Rule 3 of the packaging document says
`UniXNU/templates/package.sh` is the only source and a device repository copies
it unchanged:

```bash
curl -fsSL https://raw.githubusercontent.com/UniXNU/UniXNU/main/templates/package.sh \
  -o scripts/package.sh
chmod +x scripts/package.sh
```

The file here is the upstream script verbatim plus a comment on each line, so
it is readable as a specification. It is not a fork.

## `device-package.yml` → `<device>/.github/workflows/package.yml`

Copy this one. It is the only file that differs from UniXNU's own device
workflows, because they assume `macos-26` for Xcode while the kernel step also
builds on glibc Linux.

It stays faithful to the document:

- one `scripts/package.sh --os <profile>` invocation, no step order of its own
- the OS profile is the run's parameter, as rule 4 requires
- `UNIXNU_UNIQUE_CHIP_ID` and `UNIXNU_UEFI` come from a secret and a checkout,
  never from a repository, as the interface section requires
- the four documented outputs are uploaded from the documented paths
- the `step <name>` lines `unixnu release` prints are asserted, so a stage that
  silently did not run cannot pass for a build

Two values are per-device and set as repository variables rather than edited
into the file:

| variable | meaning |
| --- | --- |
| `UNIXNU_UEFI_REPOSITORY` | the device's Mu-Silicium platform package; defaults to `UniXNU/uefi-sheng` |

`board.toml`'s `[package] unixnu` must be `../UniXNU` for the checkout layout in
that workflow, which is what the document's example uses.

## What the device `board.toml` needs

```toml
[package]
unixnu = "../UniXNU"
boot_partition_bytes = 100663296      # optional; verify refuses a larger boot.img

[package.defconfig]
"ipados-17.7.11-21H461" = "q706f_defconfig"

[so_overrides."ipados-17.7.11-21H461".kernel]
# ...
```

`boot_partition_bytes` is the guard for this device: `boot_a` and `boot_b` are
both 96 MiB, and `verify` is what rejects an oversized image instead of
`fastboot` failing on the device.
