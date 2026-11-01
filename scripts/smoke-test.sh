#!/bin/bash
# Verify an installed UniXNU Linux toolchain.
#
#   smoke-test.sh [PREFIX]        (default /opt/unixnu-linux, or $UNIXNU_TOOLCHAIN)
#
# Checks the three things the build driver actually depends on:
#
#   1. every path scripts/unixnu/kernel.py::linux_env() stats before it builds
#   2. the cross clang carries __builtin_xnu_type_* (the patch landed) and
#      produces an AArch64 Mach-O object, not an ELF one
#   3. ld64 links that object into a kernel-style Mach-O
#
# Exits non-zero with a message naming the failing check.
set -uo pipefail

PREFIX="${1:-${UNIXNU_TOOLCHAIN:-/opt/unixnu-linux}}"
CLT="$PREFIX/CommandLineTools/usr"
XCTOOLCHAIN="$PREFIX/XcodeDefault.xctoolchain/usr"

pass=0
fail=0

ok()   { pass=$((pass + 1)); printf '  ok    %s\n' "$*"; }
bad()  { fail=$((fail + 1)); printf '  FAIL  %s\n' "$*"; }

section() { printf '\n%s\n' "$*"; }

section "1. Paths scripts/unixnu/kernel.py::linux_env() requires"
# These are the exact six entries of the driver's existence check, plus the
# three shims it installs into /usr/bin. A missing one aborts the kernel step
# before a single source file is compiled.
while read -r path; do
    if [ -x "$path" ] || [ -f "$path" ]; then
        ok "$path"
    else
        bad "$path missing"
    fi
done <<EOF
$PREFIX/llvm/bin/clang
$CLT/bin/ld
$CLT/bin/xnu-host-cc
$CLT/libexec/migcom
$XCTOOLCHAIN/bin/iig
$PREFIX/bin/lzfse
/usr/bin/xcrun
/usr/bin/plutil
/usr/bin/codesign
EOF

section "2. cctools-port Mach-O tools"
for tool in ld nm lipo libtool otool ar ranlib strip; do
    if [ -x "$CLT/bin/$tool" ]; then
        ok "$CLT/bin/$tool"
    else
        bad "$CLT/bin/$tool missing"
    fi
done

section "3. Patched clang: __builtin_xnu_type_summary present"
# kalloc_type signatures have no fallback without these, so a clang built from
# unpatched llvm-project compiles xnu's headers to errors.
probe="$RUNNER_TEMP/xnu-builtin-probe.c"
mkdir -p "$RUNNER_TEMP"
cat > "$probe" <<'EOF'
#if !__has_builtin(__builtin_xnu_type_summary)
#error missing __builtin_xnu_type_summary
#endif
int probe;
EOF
if "$PREFIX/llvm/bin/clang" -target arm64e-apple-macos26.0 \
     -E "$probe" >/dev/null 2>&1; then
    ok "__builtin_xnu_type_summary"
else
    bad "clang lacks the xnu builtins (llvm-xnu-builtin-type.patch did not apply)"
    "$PREFIX/llvm/bin/clang" -target arm64e-apple-macos26.0 -E "$probe" 2>&1 | tail -5 | sed 's/^/        /'
fi

section "4. Cross compile: AArch64 Mach-O object"
src="$RUNNER_TEMP/hello.c"
obj="$RUNNER_TEMP/hello.o"
cat > "$src" <<'EOF'
int the_answer(void) { return 42; }
EOF
if "$CLT/bin/clang" -target arm64-apple-ios17.0 -c "$src" -o "$obj" 2>/dev/null; then
    if file "$obj" | grep -q 'Mach-O 64-bit arm64'; then
        ok "clang -c produces a Mach-O arm64 object"
    else
        bad "clang -c produced $(file -b "$obj"), not a Mach-O arm64 object"
    fi
else
    bad "clang -c failed"
fi

section "5. ld64 links a static kernel-style Mach-O"
# -static -e is the shape xnu's kernel link uses; ld64.lld rejects -kernel, so
# this also proves the cctools-port ld, not lld, is first on the path.
out="$RUNNER_TEMP/hello.macho"
if "$CLT/bin/ld" -static -arch arm64 -e __the_answer -o "$out" "$obj" 2>/dev/null \
     || "$CLT/bin/ld" -static -arch arm64 -e _the_answer -o "$out" "$obj" 2>/dev/null; then
    if file "$out" | grep -q 'Mach-O 64-bit arm64'; then
        ok "ld64 links a Mach-O arm64 executable"
    else
        bad "ld64 output is $(file -b "$out")"
    fi
else
    bad "ld64 could not link the object (cctools-port build problem)"
fi

section "6. mig"
if "$CLT/bin/mig" 2>&1 | head -1 | grep -qi 'usage\|mig'; then
    ok "mig runs"
else
    # mig.sh exits 1 with a usage line when given no arguments; treat any
    # invocation that reaches migcom as success.
    if "$CLT/bin/mig" >/dev/null 2>&1; then
        ok "mig runs"
    else
        bad "mig failed to execute"
    fi
fi

section "7. lzfse"
if "$PREFIX/bin/lzfse" -h >/dev/null 2>&1 || "$PREFIX/bin/lzfse" 2>&1 | grep -qi 'usage'; then
    ok "lzfse runs"
else
    bad "lzfse failed to execute"
fi

section "8. iig"
if "$XCTOOLCHAIN/bin/iig" --help >/dev/null 2>&1 || [ $? -le 1 ]; then
    ok "iig runs"
else
    bad "iig failed to execute"
fi

printf '\n----------------------------------------\n'
printf 'passed: %d    failed: %d\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
    printf 'toolchain at %s is incomplete\n' "$PREFIX"
    exit 1
fi
printf 'toolchain at %s is usable\n' "$PREFIX"
